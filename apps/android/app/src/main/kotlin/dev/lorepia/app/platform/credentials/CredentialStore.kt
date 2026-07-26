package dev.lorepia.app.platform.credentials

/**
 * Native credential boundary. Provider secrets never enter Rust persistence,
 * application preferences, saved instance state, or logs.
 */
interface CredentialStore {
    suspend fun read(providerProfileId: String): String?

    suspend fun write(providerProfileId: String, credential: String)

    suspend fun delete(providerProfileId: String)
}
