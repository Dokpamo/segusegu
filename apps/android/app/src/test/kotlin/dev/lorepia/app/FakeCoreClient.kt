package dev.lorepia.app

import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.ChatEvent
import dev.lorepia.app.bridge.ChatEventBatch
import dev.lorepia.app.bridge.ChatMessage
import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.ConversationSummary
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.CoreHealthStatus
import dev.lorepia.app.bridge.CoreVersionInfo
import dev.lorepia.app.bridge.DatabaseStats
import dev.lorepia.app.bridge.ImportImagePreview
import dev.lorepia.app.bridge.ImportInspection
import dev.lorepia.app.bridge.ProviderProfile
import dev.lorepia.app.platform.credentials.CredentialStore

class FakeCoreClient(
    var version: String = "test-core",
    var health: CoreHealthStatus = healthyCoreStatus(),
    var characters: List<CharacterSummary> = emptyList(),
    var inspection: ImportInspection = syntheticInspection(),
    var conversations: MutableList<ConversationSummary> = mutableListOf(),
    var messages: MutableMap<String, MutableList<ChatMessage>> = mutableMapOf(),
    var profiles: MutableList<ProviderProfile> = mutableListOf(),
    var settings: AppSettings = AppSettings(
        preservePartialGenerations = false,
        selectedProviderProfileId = null,
    ),
    var versionError: Throwable? = null,
    var healthError: Throwable? = null,
    var inspectionError: Throwable? = null,
    var commitError: Throwable? = null,
) : CoreClient {
    val queuedEvents = ArrayDeque<ChatEvent>()
    var coreVersionCalls = 0
        private set
    var healthCheckCalls = 0
        private set
    var listCharactersCalls = 0
        private set
    var inspectImportCalls = 0
        private set
    var commitImportCalls = 0
        private set
    var discardImportCalls = 0
        private set
    var sendMessageCalls = 0
        private set
    var cancelGenerationCalls = 0
        private set
    var lastCredential: String? = null
        private set
    var closed = false
        private set

    override suspend fun coreVersion(): String {
        coreVersionCalls += 1
        versionError?.let { throw it }
        return version
    }

    override suspend fun versionInfo(): CoreVersionInfo = CoreVersionInfo(
        coreVersion = version,
        coreApiVersion = 3u,
        bindingApiVersion = 3u,
        chatEventVersion = 2u,
    )

    override suspend fun healthCheck(): CoreHealthStatus {
        healthCheckCalls += 1
        healthError?.let { throw it }
        return health
    }

    override suspend fun databaseStats(): DatabaseStats = DatabaseStats(
        characters = characters.size.toULong(),
        conversations = conversations.size.toULong(),
        messages = messages.values.sumOf { it.size }.toULong(),
        pendingImports = 0uL,
    )

    override suspend fun listCharacters(): List<CharacterSummary> {
        listCharactersCalls += 1
        return characters
    }

    override suspend fun getCharacter(characterId: String): CharacterSummary =
        characters.first { it.id == characterId }

    override suspend fun inspectImport(stagedPath: String): ImportInspection {
        inspectImportCalls += 1
        inspectionError?.let { throw it }
        return inspection
    }

    override suspend fun commitImport(inspectionId: String): CharacterSummary {
        commitImportCalls += 1
        commitError?.let { throw it }
        return CharacterSummary(
            id = "character-$inspectionId",
            name = inspection.displayName,
            description = inspection.description,
            sourceHash = inspection.sourceSha256,
        ).also { character ->
            characters = characters + character
        }
    }

    override suspend fun discardImport(inspectionId: String) {
        discardImportCalls += 1
    }

    override suspend fun listConversations(): List<ConversationSummary> =
        conversations.toList()

    override suspend fun openConversation(characterId: String): ConversationSummary {
        val character = getCharacter(characterId)
        val next = ConversationSummary(
            id = "conversation-${conversations.size + 1}",
            characterId = characterId,
            title = character.name,
            createdAt = "2026-01-01T00:00:00Z",
            updatedAt = "2026-01-01T00:00:00Z",
        )
        conversations += next
        messages[next.id] = mutableListOf()
        return next
    }

    override suspend fun listMessages(conversationId: String): List<ChatMessage> =
        messages[conversationId]?.toList().orEmpty()

    override suspend fun sendMessage(
        conversationId: String,
        text: String,
        providerProfileId: String,
        credential: String?,
    ): String {
        sendMessageCalls += 1
        lastCredential = credential
        val generationId = "generation-$sendMessageCalls"
        messages.getOrPut(conversationId, ::mutableListOf) += ChatMessage(
            id = "user-$sendMessageCalls",
            conversationId = conversationId,
            parentId = null,
            role = "user",
            content = text,
            status = "complete",
            generationId = null,
            createdAt = "2026-01-01T00:00:00Z",
        )
        messages.getValue(conversationId) += ChatMessage(
            id = "assistant-$sendMessageCalls",
            conversationId = conversationId,
            parentId = "user-$sendMessageCalls",
            role = "assistant",
            content = "",
            status = "pending",
            generationId = generationId,
            createdAt = "2026-01-01T00:00:01Z",
        )
        return generationId
    }

    override suspend fun cancelGeneration(generationId: String) {
        cancelGenerationCalls += 1
    }

    override suspend fun pollEvents(maxEvents: UInt): ChatEventBatch {
        val drained = buildList {
            repeat(minOf(maxEvents.toInt(), queuedEvents.size)) {
                add(queuedEvents.removeFirst())
            }
        }
        return ChatEventBatch(drained, droppedEventCount = 0uL)
    }

    override suspend fun getSettings(): AppSettings = settings

    override suspend fun updateSettings(settings: AppSettings): AppSettings {
        this.settings = settings
        return settings
    }

    override suspend fun listProviderProfiles(): List<ProviderProfile> = profiles.toList()

    override suspend fun upsertProviderProfile(profile: ProviderProfile): ProviderProfile {
        profiles.removeAll { it.id == profile.id }
        profiles += profile
        return profile
    }

    override suspend fun deleteProviderProfile(profileId: String) {
        profiles.removeAll { it.id == profileId }
        if (settings.selectedProviderProfileId == profileId) {
            settings = settings.copy(selectedProviderProfileId = null)
        }
    }

    override fun close() {
        closed = true
    }
}

class FakeCredentialStore : CredentialStore {
    val values = mutableMapOf<String, String>()

    override suspend fun read(providerProfileId: String): String? = values[providerProfileId]

    override suspend fun write(providerProfileId: String, credential: String) {
        values[providerProfileId] = credential
    }

    override suspend fun delete(providerProfileId: String) {
        values.remove(providerProfileId)
    }
}

fun healthyCoreStatus(): CoreHealthStatus = CoreHealthStatus(
    coreVersion = "test-core",
    databaseOpen = true,
    schemaVersion = 1,
    dataRootWritable = true,
    stagingWritable = true,
    recoveryPending = false,
    activeJobs = 0,
)

fun syntheticCharacter(id: String = "character-1"): CharacterSummary = CharacterSummary(
    id = id,
    name = "합성 캐릭터",
    description = "테스트 전용 합성 설명",
    sourceHash = "a".repeat(64),
)

fun syntheticInspection(): ImportInspection = ImportInspection(
    id = "inspection-1",
    contentKind = "charx",
    displayName = "합성 캐릭터",
    description = "테스트 전용 합성 설명",
    sourceSha256 = "a".repeat(64),
    sourceSize = 128u,
    estimatedStoredSize = 256u,
    assetCount = 1u,
    warnings = emptyList(),
    blockedReasons = emptyList(),
    isAllowed = true,
    representativeImage = ImportImagePreview(
        logicalAssetId = "assets/avatar.png",
        mediaType = "image/png",
        sizeBytes = 70u,
    ),
    unsupportedOptionalFields = listOf("alternate_greetings", "creator"),
)
