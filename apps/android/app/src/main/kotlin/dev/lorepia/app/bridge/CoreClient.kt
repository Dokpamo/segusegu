package dev.lorepia.app.bridge

/**
 * Kotlin-facing boundary for the platform-independent Rust core.
 *
 * UI and ViewModel code depend on this interface instead of generated UniFFI
 * classes. This keeps generated code out of product UI and makes state handling
 * deterministic in unit tests.
 */
interface CoreClient : AutoCloseable {
    suspend fun coreVersion(): String

    suspend fun healthCheck(): CoreHealthStatus

    suspend fun listCharacters(): List<CharacterSummary>

    suspend fun inspectImport(stagedPath: String): ImportInspection

    suspend fun commitImport(inspectionId: String): CharacterSummary
}

data class CoreHealthStatus(
    val coreVersion: String,
    val databaseOpen: Boolean,
    val schemaVersion: Long,
    val dataRootWritable: Boolean,
    val stagingWritable: Boolean,
    val recoveryPending: Boolean,
    val activeJobs: Long,
) {
    val isHealthy: Boolean
        get() = databaseOpen && dataRootWritable && stagingWritable
}

data class CharacterSummary(
    val id: String,
    val name: String,
    val description: String,
    val sourceHash: String,
)

data class ImportInspection(
    val id: String,
    val contentKind: String,
    val displayName: String,
    val description: String,
    val sourceSha256: String,
    val sourceSize: ULong,
    val assetCount: UInt,
    val warnings: List<String>,
    val blockedReasons: List<String>,
) {
    val isBlocked: Boolean
        get() = blockedReasons.isNotEmpty()
}
