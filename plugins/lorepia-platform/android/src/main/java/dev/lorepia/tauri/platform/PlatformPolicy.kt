package dev.lorepia.tauri.platform

import java.security.MessageDigest

internal object PlatformPolicy {
    const val MAXIMUM_REFERENCE_BYTES = 256
    const val MAXIMUM_CREDENTIAL_READ_BYTES = 32 * 1024
    const val MAXIMUM_CREDENTIAL_WRITE_BYTES = 16 * 1024
    const val MAXIMUM_IMPORT_BYTES = 50L * 1024L * 1024L
    const val COPY_BUFFER_BYTES = 64 * 1024
    const val MAXIMUM_DISPLAY_NAME_CHARACTERS = 255
    const val OWNED_STAGING_PREFIX = "lorepia-tauri-"
    const val ABANDONED_STAGING_AGE_MILLIS = 24L * 60L * 60L * 1_000L

    fun validateReference(reference: String) {
        require(reference.isNotBlank()) { "invalid reference" }
        val encoded = reference.toByteArray(Charsets.UTF_8)
        try {
            require(encoded.size <= MAXIMUM_REFERENCE_BYTES) { "invalid reference" }
        } finally {
            encoded.fill(0)
        }
    }

    fun validateCredentialForWrite(value: String): ByteArray {
        require(value.isNotBlank()) { "invalid credential" }
        return value.toByteArray(Charsets.UTF_8).also {
            require(it.size <= MAXIMUM_CREDENTIAL_WRITE_BYTES) {
                it.fill(0)
                "invalid credential"
            }
        }
    }

    fun validateCredentialForRead(value: ByteArray) {
        require(value.isNotEmpty() && value.size <= MAXIMUM_CREDENTIAL_READ_BYTES) {
            "invalid credential"
        }
    }

    fun credentialFileName(reference: String): String {
        val referenceBytes = reference.toByteArray(Charsets.UTF_8)
        val digest = try {
            MessageDigest.getInstance("SHA-256").digest(referenceBytes)
        } finally {
            referenceBytes.fill(0)
        }
        return try {
            buildString(digest.size * 2 + CREDENTIAL_SUFFIX.length) {
                for (byte in digest) {
                    append(HEX[(byte.toInt() ushr 4) and 0x0f])
                    append(HEX[byte.toInt() and 0x0f])
                }
                append(CREDENTIAL_SUFFIX)
            }
        } finally {
            digest.fill(0)
        }
    }

    fun sanitizeDisplayName(value: String?): String {
        val sanitized = value
            ?.take(MAXIMUM_DISPLAY_NAME_CHARACTERS)
            ?.map { character -> if (character.isISOControl()) '\uFFFD' else character }
            ?.joinToString(separator = "")
            ?.takeIf(String::isNotBlank)
        return sanitized ?: "selected-file"
    }

    fun stagingSuffix(displayName: String): String =
        when (displayName.substringAfterLast('.', "").lowercase()) {
            "charx" -> ".charx"
            "json" -> ".json"
            "zip" -> ".zip"
            else -> ".pending"
        }

    fun shouldRemoveAbandonedStagingFile(
        name: String,
        isRegularFile: Boolean,
        lastModifiedMillis: Long,
        nowMillis: Long,
    ): Boolean =
        name.startsWith(OWNED_STAGING_PREFIX) &&
            isRegularFile &&
            lastModifiedMillis > 0L &&
            nowMillis >= lastModifiedMillis &&
            nowMillis - lastModifiedMillis >= ABANDONED_STAGING_AGE_MILLIS

    private const val CREDENTIAL_SUFFIX = ".credential"
    private const val HEX = "0123456789abcdef"
}
