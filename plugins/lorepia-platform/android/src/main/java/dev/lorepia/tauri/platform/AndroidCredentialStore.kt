package dev.lorepia.tauri.platform

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.FileNotFoundException
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal enum class NativeCredentialStatus(val wireValue: String) {
    MISSING("missing"),
    AVAILABLE("available"),
    UNREADABLE("unreadable"),
}

internal class CredentialRecoveryRequiredException(cause: Throwable) :
    Exception("credential recovery required", cause)

internal class AndroidCredentialStore(context: Context) {
    private val directory = context.noBackupFilesDir
        .resolve(CREDENTIAL_DIRECTORY)
        .absoluteFile

    fun status(reference: String): NativeCredentialStatus {
        PlatformPolicy.validateReference(reference)
        synchronized(PROCESS_LOCK) {
            val file = credentialFile(reference)
            return try {
                val plaintext = readPlaintext(reference, file)
                plaintext.fill(0)
                NativeCredentialStatus.AVAILABLE
            } catch (_: FileNotFoundException) {
                if (file.baseFile.exists()) {
                    NativeCredentialStatus.UNREADABLE
                } else {
                    NativeCredentialStatus.MISSING
                }
            } catch (_: Exception) {
                NativeCredentialStatus.UNREADABLE
            }
        }
    }

    fun read(reference: String): String? {
        PlatformPolicy.validateReference(reference)
        synchronized(PROCESS_LOCK) {
            val file = credentialFile(reference)
            val plaintext = try {
                readPlaintext(reference, file)
            } catch (error: FileNotFoundException) {
                if (file.baseFile.exists()) {
                    throw error
                }
                return null
            }
            return try {
                decodeUtf8(plaintext).also {
                    require(it.isNotBlank()) { "credential unavailable" }
                }
            } finally {
                plaintext.fill(0)
            }
        }
    }

    fun store(reference: String, value: String) {
        PlatformPolicy.validateReference(reference)
        val plaintext = PlatformPolicy.validateCredentialForWrite(value)
        try {
            synchronized(PROCESS_LOCK) {
                check(directory.mkdirs() || directory.isDirectory) {
                    "credential unavailable"
                }
                val encoded = encode(reference, plaintext)
                var previousRecord: ByteArray? = null
                try {
                    val file = credentialFile(reference)
                    previousRecord = try {
                        readEncoded(file)
                    } catch (_: FileNotFoundException) {
                        null
                    }
                    val stream = file.startWrite()
                    try {
                        stream.write(encoded)
                        stream.fd.sync()
                        file.finishWrite(stream)
                    } catch (error: Exception) {
                        file.failWrite(stream)
                        throw error
                    }

                    try {
                        val verified = readPlaintext(reference, file)
                        try {
                            check(MessageDigest.isEqual(plaintext, verified)) {
                                "credential unavailable"
                            }
                        } finally {
                            verified.fill(0)
                        }
                    } catch (error: Exception) {
                        try {
                            restoreRecord(file, previousRecord)
                        } catch (restoreError: Exception) {
                            val recoveryError =
                                CredentialRecoveryRequiredException(error)
                            recoveryError.addSuppressed(restoreError)
                            throw recoveryError
                        }
                        throw error
                    }
                } finally {
                    encoded.fill(0)
                    previousRecord?.fill(0)
                }
            }
        } finally {
            plaintext.fill(0)
        }
    }

    fun delete(reference: String) {
        PlatformPolicy.validateReference(reference)
        synchronized(PROCESS_LOCK) {
            credentialFile(reference).delete()
        }
    }

    private fun readPlaintext(reference: String, file: AtomicFile): ByteArray {
        val encoded = readEncoded(file)
        return try {
            val plaintext = decode(reference, encoded)
            try {
                PlatformPolicy.validateCredentialForRead(plaintext)
                plaintext
            } catch (error: Exception) {
                plaintext.fill(0)
                throw error
            }
        } finally {
            encoded.fill(0)
        }
    }

    private fun readEncoded(file: AtomicFile): ByteArray =
        file.openRead().use { input ->
            ByteArrayOutputStream().use { output ->
                val buffer = ByteArray(RECORD_READ_BUFFER_BYTES)
                var total = 0L
                try {
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) {
                            break
                        }
                        total = Math.addExact(total, count.toLong())
                        check(total <= MAXIMUM_RECORD_BYTES) {
                            "credential unavailable"
                        }
                        output.write(buffer, 0, count)
                    }
                    output.toByteArray()
                } finally {
                    buffer.fill(0)
                }
            }
        }

    private fun restoreRecord(file: AtomicFile, record: ByteArray?) {
        if (record == null) {
            file.delete()
            check(!file.baseFile.exists()) {
                "credential unavailable"
            }
            return
        }

        val stream = file.startWrite()
        try {
            stream.write(record)
            stream.fd.sync()
            file.finishWrite(stream)
        } catch (error: Exception) {
            file.failWrite(stream)
            throw error
        }

        val restored = readEncoded(file)
        try {
            check(MessageDigest.isEqual(record, restored)) {
                "credential unavailable"
            }
        } finally {
            restored.fill(0)
        }
    }

    private fun encode(reference: String, plaintext: ByteArray): ByteArray {
        require(plaintext.size <= PlatformPolicy.MAXIMUM_CREDENTIAL_WRITE_BYTES) {
            "invalid credential"
        }
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
        updateAssociatedData(cipher, reference)
        val encrypted = cipher.doFinal(plaintext)
        return try {
            ByteArrayOutputStream().use { bytes ->
                DataOutputStream(bytes).use { output ->
                    output.writeInt(FILE_VERSION)
                    output.writeInt(cipher.iv.size)
                    output.write(cipher.iv)
                    output.writeInt(encrypted.size)
                    output.write(encrypted)
                }
                bytes.toByteArray()
            }
        } finally {
            encrypted.fill(0)
        }
    }

    private fun decode(reference: String, encoded: ByteArray): ByteArray =
        DataInputStream(ByteArrayInputStream(encoded)).use { input ->
            check(input.readInt() == FILE_VERSION) { "credential unavailable" }
            val ivLength = input.readInt()
            check(ivLength in MINIMUM_IV_BYTES..MAXIMUM_IV_BYTES) {
                "credential unavailable"
            }
            val iv = ByteArray(ivLength)
            val ciphertext: ByteArray
            try {
                input.readFully(iv)
                val ciphertextLength = input.readInt()
                check(ciphertextLength in 1..MAXIMUM_LEGACY_CIPHERTEXT_BYTES) {
                    "credential unavailable"
                }
                ciphertext = ByteArray(ciphertextLength)
                input.readFully(ciphertext)
                check(input.read() == -1) { "credential unavailable" }
            } catch (error: Exception) {
                iv.fill(0)
                throw error
            }

            try {
                val key = getExistingKey() ?: error("credential unavailable")
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(
                    Cipher.DECRYPT_MODE,
                    key,
                    GCMParameterSpec(GCM_TAG_BITS, iv),
                )
                updateAssociatedData(cipher, reference)
                cipher.doFinal(ciphertext)
            } finally {
                iv.fill(0)
                ciphertext.fill(0)
            }
        }

    private fun updateAssociatedData(cipher: Cipher, reference: String) {
        val associatedData = reference.toByteArray(Charsets.UTF_8)
        try {
            cipher.updateAAD(associatedData)
        } finally {
            associatedData.fill(0)
        }
    }

    private fun getExistingKey(): SecretKey? {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        return keyStore.getKey(KEY_ALIAS, null) as? SecretKey
    }

    private fun getOrCreateKey(): SecretKey {
        getExistingKey()?.let { return it }
        val generator = KeyGenerator.getInstance(
            KeyProperties.KEY_ALGORITHM_AES,
            KEYSTORE_PROVIDER,
        )
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun credentialFile(reference: String): AtomicFile =
        AtomicFile(directory.resolve(PlatformPolicy.credentialFileName(reference)))

    private fun decodeUtf8(value: ByteArray): String =
        Charsets.UTF_8
            .newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(value))
            .toString()

    private companion object {
        const val CREDENTIAL_DIRECTORY = "provider-credentials"
        const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        const val KEY_ALIAS = "dev.lorepia.provider-credentials.v1"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val GCM_TAG_BITS = 128
        const val FILE_VERSION = 1
        const val MINIMUM_IV_BYTES = 12
        const val MAXIMUM_IV_BYTES = 32
        const val MAXIMUM_LEGACY_CIPHERTEXT_BYTES = 64 * 1024
        const val MAXIMUM_RECORD_BYTES = MAXIMUM_LEGACY_CIPHERTEXT_BYTES + 128L
        const val RECORD_READ_BUFFER_BYTES = 8 * 1024
        val PROCESS_LOCK = Any()
    }
}
