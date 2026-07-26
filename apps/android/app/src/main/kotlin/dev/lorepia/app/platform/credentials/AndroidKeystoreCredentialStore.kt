package dev.lorepia.app.platform.credentials

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Stores only AES-GCM ciphertext in the app's no-backup directory. The
 * non-exportable encryption key remains in Android Keystore.
 */
class AndroidKeystoreCredentialStore(
    context: Context,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : CredentialStore {
    private val directory = context.noBackupFilesDir
        .resolve("provider-credentials")
        .absoluteFile
    private val lock = Any()

    override suspend fun read(providerProfileId: String): String? = withContext(ioDispatcher) {
        validateProfileId(providerProfileId)
        synchronized(lock) {
            val file = credentialFile(providerProfileId)
            if (!file.baseFile.isFile) return@synchronized null
            check(file.baseFile.length() <= MAXIMUM_CIPHERTEXT_BYTES + 128L) {
                "Credential record is too large."
            }
            val encoded = file.readFully()
            try {
                check(encoded.size <= MAXIMUM_CIPHERTEXT_BYTES + 128) {
                    "Credential record is too large."
                }
                decode(providerProfileId, encoded)
            } finally {
                encoded.fill(0)
            }
        }
    }

    override suspend fun write(providerProfileId: String, credential: String) =
        withContext(ioDispatcher) {
            validateProfileId(providerProfileId)
            require(credential.isNotBlank()) { "The credential must not be blank." }
            synchronized(lock) {
                check(directory.mkdirs() || directory.isDirectory) {
                    "Could not create the credential directory."
                }
                val encoded = encode(providerProfileId, credential)
                val file = credentialFile(providerProfileId)
                val stream = file.startWrite()
                try {
                    stream.write(encoded)
                    file.finishWrite(stream)
                } catch (error: Throwable) {
                    file.failWrite(stream)
                    throw error
                } finally {
                    encoded.fill(0)
                }
            }
        }

    override suspend fun delete(providerProfileId: String) = withContext(ioDispatcher) {
        validateProfileId(providerProfileId)
        synchronized(lock) {
            credentialFile(providerProfileId).delete()
        }
    }

    private fun encode(providerProfileId: String, credential: String): ByteArray {
        val plaintext = credential.toByteArray(Charsets.UTF_8)
        return try {
            require(plaintext.size <= MAXIMUM_PLAINTEXT_BYTES) {
                "The credential is too large."
            }
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKey())
            cipher.updateAAD(providerProfileId.toByteArray(Charsets.UTF_8))
            val encrypted = cipher.doFinal(plaintext)
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
            plaintext.fill(0)
        }
    }

    private fun decode(providerProfileId: String, encoded: ByteArray): String {
        val plaintext = DataInputStream(ByteArrayInputStream(encoded)).use { input ->
            check(input.readInt() == FILE_VERSION) { "Unsupported credential record version." }
            val ivLength = input.readInt()
            check(ivLength in 12..32) { "Invalid credential nonce." }
            val iv = ByteArray(ivLength)
            input.readFully(iv)
            val ciphertextLength = input.readInt()
            check(ciphertextLength in 1..MAXIMUM_CIPHERTEXT_BYTES) {
                "Invalid credential record length."
            }
            val ciphertext = ByteArray(ciphertextLength)
            input.readFully(ciphertext)
            check(input.read() == -1) { "Trailing data in credential record." }

            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, getOrCreateKey(), GCMParameterSpec(GCM_TAG_BITS, iv))
            cipher.updateAAD(providerProfileId.toByteArray(Charsets.UTF_8))
            cipher.doFinal(ciphertext)
        }
        return try {
            plaintext.toString(Charsets.UTF_8)
        } finally {
            plaintext.fill(0)
        }
    }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
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

    private fun credentialFile(providerProfileId: String): AtomicFile {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(providerProfileId.toByteArray(Charsets.UTF_8))
            .joinToString(separator = "") { byte ->
                (byte.toInt() and 0xff).toString(16).padStart(2, '0')
            }
        return AtomicFile(directory.resolve("$digest.credential"))
    }

    private fun validateProfileId(providerProfileId: String) {
        require(providerProfileId.isNotBlank()) { "The provider profile ID must not be blank." }
        require(providerProfileId.length <= 256) { "The provider profile ID is too long." }
    }

    companion object {
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "dev.lorepia.provider-credentials.v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_BITS = 128
        private const val FILE_VERSION = 1
        private const val MAXIMUM_PLAINTEXT_BYTES = 32 * 1024
        private const val MAXIMUM_CIPHERTEXT_BYTES = 64 * 1024
    }
}
