package dev.lorepia.app.platform.credentials

/**
 * Native credential boundary. Provider secrets never enter Rust persistence,
 * application preferences, saved instance state, or logs.
 */
interface CredentialStore {
    /**
     * [credentialRef] is the immutable provider connection ID. Keeping the
     * legacy ID-shaped alias preserves existing Android Keystore records during
     * the ProviderProfile migration.
     */
    suspend fun read(credentialRef: String): String?

    /**
     * Verifies that a record exists and can be decrypted without returning the
     * credential to UI or diagnostic code.
     */
    suspend fun inspect(credentialRef: String): CredentialRecordStatus

    suspend fun write(credentialRef: String, credential: String)

    /**
     * One-shot binary boundary for cURL credential handoff. Implementations
     * copy and clear their internal plaintext; the caller must clear [credential]
     * in `finally` immediately after this method returns.
     */
    suspend fun writeBytes(credentialRef: String, credential: ByteArray)

    suspend fun delete(credentialRef: String)
}

enum class CredentialRecordStatus {
    Available,
    Missing,
    Unreadable,
}
