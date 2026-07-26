package dev.lorepia.app.bridge

import dev.lorepia.core.FfiAppSettings
import dev.lorepia.core.FfiCharacter
import dev.lorepia.core.FfiChatEvent
import dev.lorepia.core.FfiConversation
import dev.lorepia.core.FfiCoreConfig
import dev.lorepia.core.FfiException
import dev.lorepia.core.FfiImportInspection
import dev.lorepia.core.FfiMessage
import dev.lorepia.core.FfiProviderProfile
import dev.lorepia.core.LorepiaCore
import dev.lorepia.core.coreVersion as ffiCoreVersion
import dev.lorepia.core.versionInfo as ffiVersionInfo
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Thin coroutine-friendly adapter around the generated UniFFI API.
 *
 * This class deliberately performs no product logic. The generated source is
 * supplied by `bindings/uniffi` and remains read-only.
 */
class UniFfiCoreClient private constructor(
    private val core: LorepiaCore,
    private val ioDispatcher: CoroutineDispatcher,
) : CoreClient {
    override suspend fun coreVersion(): String = onIo { ffiCoreVersion() }

    override suspend fun versionInfo(): CoreVersionInfo = onIo {
        val info = ffiVersionInfo()
        CoreVersionInfo(
            coreVersion = info.coreVersion,
            coreApiVersion = info.coreApiVersion,
            bindingApiVersion = info.bindingApiVersion,
            chatEventVersion = info.chatEventVersion,
        )
    }

    override suspend fun healthCheck(): CoreHealthStatus = onIo {
        val report = core.healthCheck()
        CoreHealthStatus(
            coreVersion = report.coreVersion,
            databaseOpen = report.databaseOpen,
            schemaVersion = report.schemaVersion.toLong(),
            dataRootWritable = report.dataRootWritable,
            stagingWritable = report.stagingWritable,
            recoveryPending = report.recoveryPending,
            activeJobs = report.activeJobs.toLong(),
        )
    }

    override suspend fun databaseStats(): DatabaseStats = onIo {
        val stats = core.databaseStats()
        DatabaseStats(
            characters = stats.characters,
            conversations = stats.conversations,
            messages = stats.messages,
            pendingImports = stats.pendingImports,
        )
    }

    override suspend fun listCharacters(): List<CharacterSummary> =
        onIo { core.listCharacters().map(FfiCharacter::toAppModel) }

    override suspend fun getCharacter(characterId: String): CharacterSummary = onIo {
        requireNotBlank(characterId, "character ID")
        core.getCharacter(characterId).toAppModel()
    }

    override suspend fun inspectImport(stagedPath: String): ImportInspection = onIo {
        require(File(stagedPath).isAbsolute) { "The staged import path must be absolute." }
        core.inspectImport(stagedPath).toAppModel()
    }

    override suspend fun commitImport(inspectionId: String): CharacterSummary = onIo {
        requireNotBlank(inspectionId, "inspection ID")
        core.commitImport(inspectionId).toAppModel()
    }

    override suspend fun discardImport(inspectionId: String) = onIo {
        requireNotBlank(inspectionId, "inspection ID")
        core.discardImport(inspectionId)
    }

    override suspend fun listConversations(): List<ConversationSummary> =
        onIo { core.listConversations().map(FfiConversation::toAppModel) }

    override suspend fun openConversation(characterId: String): ConversationSummary = onIo {
        requireNotBlank(characterId, "character ID")
        core.openConversation(characterId).toAppModel()
    }

    override suspend fun listMessages(conversationId: String): List<ChatMessage> = onIo {
        requireNotBlank(conversationId, "conversation ID")
        core.listMessages(conversationId).map(FfiMessage::toAppModel)
    }

    override suspend fun sendMessage(
        conversationId: String,
        text: String,
        providerProfileId: String,
        credential: String?,
    ): String = onIo {
        requireNotBlank(conversationId, "conversation ID")
        require(text.isNotBlank()) { "The message must not be blank." }
        requireNotBlank(providerProfileId, "provider profile ID")
        core.sendMessage(
            conversationId = conversationId,
            text = text,
            providerProfileId = providerProfileId,
            credential = credential?.takeIf(String::isNotBlank),
        )
    }

    override suspend fun cancelGeneration(generationId: String) = onIo {
        requireNotBlank(generationId, "generation ID")
        core.cancelGeneration(generationId)
    }

    override suspend fun pollEvents(maxEvents: UInt): ChatEventBatch = onIo {
        require(maxEvents in 1u..256u) { "Event batch size must be between 1 and 256." }
        val batch = core.pollEvents(maxEvents)
        ChatEventBatch(
            events = batch.events.map(FfiChatEvent::toAppModel),
            droppedEventCount = batch.droppedEventCount,
        )
    }

    override suspend fun getSettings(): AppSettings =
        onIo { core.getSettings().toAppModel() }

    override suspend fun updateSettings(settings: AppSettings): AppSettings = onIo {
        core.updateSettings(settings.toFfiModel()).toAppModel()
    }

    override suspend fun listProviderProfiles(): List<ProviderProfile> =
        onIo { core.listProviderProfiles().map(FfiProviderProfile::toAppModel) }

    override suspend fun upsertProviderProfile(profile: ProviderProfile): ProviderProfile = onIo {
        core.upsertProviderProfile(profile.toFfiModel()).toAppModel()
    }

    override suspend fun deleteProviderProfile(profileId: String) = onIo {
        requireNotBlank(profileId, "provider profile ID")
        core.deleteProviderProfile(profileId)
    }

    override fun close() {
        core.close()
    }

    private suspend fun <T> onIo(block: () -> T): T = try {
        withContext(ioDispatcher) { block() }
    } catch (error: FfiException.Core) {
        throw error.toAppModel()
    }

    companion object {
        fun open(
            dataRoot: File,
            ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
        ): UniFfiCoreClient {
            require(dataRoot.isAbsolute) { "The core data root must be an absolute path." }
            val core = try {
                LorepiaCore.open(FfiCoreConfig(dataRoot = dataRoot.absolutePath))
            } catch (error: FfiException.Core) {
                throw error.toAppModel()
            }
            return UniFfiCoreClient(core, ioDispatcher)
        }
    }
}

private fun requireNotBlank(value: String, fieldName: String) {
    require(value.isNotBlank()) { "The $fieldName must not be blank." }
}

private fun FfiCharacter.toAppModel(): CharacterSummary = CharacterSummary(
    id = id,
    name = name,
    description = description,
    sourceHash = sourceHash,
    avatarAssetHash = avatarAssetHash,
    createdAt = createdAt,
)

private fun FfiImportInspection.toAppModel(): ImportInspection = ImportInspection(
    id = id,
    contentKind = contentKind,
    displayName = displayName,
    description = description,
    sourceSha256 = sourceSha256,
    sourceSize = sourceSize,
    estimatedStoredSize = estimatedStoredSize,
    assetCount = assetCount,
    warnings = warnings.map { ImportWarning(code = it.code, message = it.message) },
    blockedReasons = blockedReasons.toList(),
    isAllowed = isAllowed,
    representativeImage = representativeImage?.let { image ->
        ImportImagePreview(
            logicalAssetId = image.logicalAssetId,
            mediaType = image.mediaType,
            sizeBytes = image.sizeBytes,
        )
    },
    unsupportedOptionalFields = unsupportedOptionalFields.toList(),
)

private fun FfiConversation.toAppModel(): ConversationSummary = ConversationSummary(
    id = id,
    characterId = characterId,
    title = title,
    createdAt = createdAt,
    updatedAt = updatedAt,
)

private fun FfiMessage.toAppModel(): ChatMessage = ChatMessage(
    id = id,
    conversationId = conversationId,
    parentId = parentId,
    role = role,
    content = content,
    status = status,
    generationId = generationId,
    createdAt = createdAt,
)

private fun FfiChatEvent.toAppModel(): ChatEvent = ChatEvent(
    eventVersion = eventVersion,
    generationId = generationId,
    conversationId = conversationId,
    sequence = sequence,
    emittedAt = emittedAt,
    kind = kind,
    text = text,
    messageId = messageId,
    messageStatus = messageStatus,
    errorCode = errorCode,
    errorMessage = errorMessage,
    usageInputTokens = usageInputTokens,
    usageOutputTokens = usageOutputTokens,
)

private fun FfiAppSettings.toAppModel(): AppSettings = AppSettings(
    preservePartialGenerations = preservePartialGenerations,
    selectedProviderProfileId = selectedProviderProfileId,
)

private fun AppSettings.toFfiModel(): FfiAppSettings = FfiAppSettings(
    preservePartialGenerations = preservePartialGenerations,
    selectedProviderProfileId = selectedProviderProfileId,
)

private fun FfiProviderProfile.toAppModel(): ProviderProfile = ProviderProfile(
    id = id,
    displayName = displayName,
    baseUrl = baseUrl,
    model = model,
    timeoutSeconds = timeoutSeconds,
)

private fun ProviderProfile.toFfiModel(): FfiProviderProfile = FfiProviderProfile(
    id = id,
    displayName = displayName,
    baseUrl = baseUrl,
    model = model,
    timeoutSeconds = timeoutSeconds,
)

private fun FfiException.Core.toAppModel(): CoreFailure = CoreFailure(
    code = code,
    detail = detail,
    recoverable = recoverable,
    operationId = operationId,
)
