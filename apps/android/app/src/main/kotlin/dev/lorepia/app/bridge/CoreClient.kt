package dev.lorepia.app.bridge

/**
 * Kotlin-facing boundary for the platform-independent Rust core.
 *
 * UI and ViewModel code depend on this interface instead of generated UniFFI
 * classes. The adapter contains mapping only; product decisions stay in Rust
 * or in the native UI layer that owns them.
 */
interface CoreClient : AutoCloseable {
    suspend fun coreVersion(): String

    suspend fun versionInfo(): CoreVersionInfo

    suspend fun healthCheck(): CoreHealthStatus

    suspend fun databaseStats(): DatabaseStats

    suspend fun listCharacters(): List<CharacterSummary>

    suspend fun getCharacter(characterId: String): CharacterSummary

    suspend fun inspectImport(stagedPath: String): ImportInspection

    suspend fun commitImport(inspectionId: String): CharacterSummary

    suspend fun discardImport(inspectionId: String)

    suspend fun listConversations(): List<ConversationSummary>

    suspend fun openConversation(characterId: String): ConversationSummary

    suspend fun listMessages(conversationId: String): List<ChatMessage>

    suspend fun sendMessage(
        conversationId: String,
        text: String,
        providerProfileId: String,
        credential: String?,
    ): String

    suspend fun cancelGeneration(generationId: String)

    suspend fun pollEvents(maxEvents: UInt = 64u): ChatEventBatch

    suspend fun getSettings(): AppSettings

    suspend fun updateSettings(settings: AppSettings): AppSettings

    suspend fun listProviderProfiles(): List<ProviderProfile>

    suspend fun upsertProviderProfile(profile: ProviderProfile): ProviderProfile

    suspend fun deleteProviderProfile(profileId: String)
}

class CoreFailure(
    val code: String,
    detail: String,
    val recoverable: Boolean,
    val operationId: String,
) : RuntimeException(detail)

data class CoreVersionInfo(
    val coreVersion: String,
    val coreApiVersion: UInt,
    val bindingApiVersion: UInt,
    val chatEventVersion: UInt,
)

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

data class DatabaseStats(
    val characters: ULong,
    val conversations: ULong,
    val messages: ULong,
    val pendingImports: ULong,
)

data class CharacterSummary(
    val id: String,
    val name: String,
    val description: String,
    val sourceHash: String,
    val avatarAssetHash: String? = null,
    val createdAt: String = "",
)

data class ImportWarning(
    val code: String,
    val message: String,
)

data class ImportImagePreview(
    val logicalAssetId: String,
    val mediaType: String,
    val sizeBytes: ULong,
)

data class ImportInspection(
    val id: String,
    val contentKind: String,
    val displayName: String,
    val description: String,
    val sourceSha256: String,
    val sourceSize: ULong,
    val estimatedStoredSize: ULong,
    val assetCount: UInt,
    val warnings: List<ImportWarning>,
    val blockedReasons: List<String>,
    val isAllowed: Boolean,
    val representativeImage: ImportImagePreview? = null,
    val unsupportedOptionalFields: List<String> = emptyList(),
) {
    val isBlocked: Boolean
        get() = !isAllowed || blockedReasons.isNotEmpty()
}

data class ConversationSummary(
    val id: String,
    val characterId: String,
    val title: String,
    val createdAt: String,
    val updatedAt: String,
)

data class ChatMessage(
    val id: String,
    val conversationId: String,
    val parentId: String?,
    val role: String,
    val content: String,
    val status: String,
    val generationId: String?,
    val createdAt: String,
)

data class ChatEvent(
    val eventVersion: UInt,
    val generationId: String,
    val conversationId: String,
    val branchId: String?,
    val assistantMessageId: String?,
    val sequence: ULong,
    val emittedAt: String,
    val kind: String,
    val text: String?,
    val messageId: String?,
    val messageStatus: String?,
    val errorCode: String?,
    val errorMessage: String?,
    val usageInputTokens: ULong?,
    val usageOutputTokens: ULong?,
)

data class ChatEventBatch(
    val events: List<ChatEvent>,
    val droppedEventCount: ULong,
)

data class ProviderProfile(
    val id: String,
    val displayName: String,
    val baseUrl: String,
    val model: String,
    val timeoutSeconds: UInt,
)

data class AppSettings(
    val preservePartialGenerations: Boolean,
    val selectedProviderProfileId: String?,
)
