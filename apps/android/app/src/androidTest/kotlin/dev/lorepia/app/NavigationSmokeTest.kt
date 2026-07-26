package dev.lorepia.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import dev.lorepia.app.app.LorepiaApp
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.CoreHealthStatus
import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.ChatEventBatch
import dev.lorepia.app.bridge.ChatMessage
import dev.lorepia.app.bridge.ConversationSummary
import dev.lorepia.app.bridge.CoreVersionInfo
import dev.lorepia.app.bridge.DatabaseStats
import dev.lorepia.app.bridge.ImportInspection
import dev.lorepia.app.bridge.ProviderProfile
import dev.lorepia.app.platform.credentials.CredentialStore
import org.junit.Rule
import org.junit.Test

class NavigationSmokeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun primaryDestinationsAreReachable() {
        composeRule.setContent {
            LorepiaApp(
                coreClientFactory = { InstrumentedFakeCoreClient() },
                credentialStore = InstrumentedCredentialStore,
            )
        }

        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("서재").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("채팅").performClick()
        composeRule.onNodeWithText("열린 대화가 없습니다").assertIsDisplayed()

        composeRule.onNodeWithText("설정").performClick()
        composeRule.onNodeWithText("이 기기에 저장됨").assertIsDisplayed()
    }

    @Test
    fun libraryCharacterOpensCharacterChat() {
        composeRule.setContent {
            LorepiaApp(
                coreClientFactory = { InstrumentedFakeCoreClient() },
                credentialStore = InstrumentedCredentialStore,
            )
        }

        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("합성 캐릭터").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("합성 캐릭터").performClick()
        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText(
                "메시지를 보내려면 설정에서 provider profile을 만들고 선택하세요.",
            ).fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText(
            "메시지를 보내려면 설정에서 provider profile을 만들고 선택하세요.",
        ).assertIsDisplayed()
    }
}

private class InstrumentedFakeCoreClient : CoreClient {
    private val health = CoreHealthStatus(
        coreVersion = "instrumented-test",
        databaseOpen = true,
        schemaVersion = 1,
        dataRootWritable = true,
        stagingWritable = true,
        recoveryPending = false,
        activeJobs = 0,
    )
    private val character = CharacterSummary(
        id = "character-1",
        name = "합성 캐릭터",
        description = "합성 설명",
        sourceHash = "a".repeat(64),
    )
    private val conversations = mutableListOf<ConversationSummary>()

    override suspend fun coreVersion(): String = health.coreVersion

    override suspend fun healthCheck(): CoreHealthStatus = health

    override suspend fun versionInfo(): CoreVersionInfo = CoreVersionInfo(
        coreVersion = health.coreVersion,
        coreApiVersion = 3u,
        bindingApiVersion = 3u,
        chatEventVersion = 2u,
    )

    override suspend fun databaseStats(): DatabaseStats =
        DatabaseStats(0uL, 0uL, 0uL, 0uL)

    override suspend fun listCharacters(): List<CharacterSummary> = listOf(character)

    override suspend fun getCharacter(characterId: String): CharacterSummary =
        character.takeIf { it.id == characterId } ?: error("Character not found.")

    override suspend fun inspectImport(stagedPath: String): ImportInspection =
        error("The navigation smoke test does not select a document.")

    override suspend fun commitImport(inspectionId: String): CharacterSummary =
        error("The navigation smoke test does not commit an import.")

    override suspend fun discardImport(inspectionId: String) = Unit

    override suspend fun listConversations(): List<ConversationSummary> =
        conversations.toList()

    override suspend fun openConversation(characterId: String): ConversationSummary =
        ConversationSummary(
            id = "conversation-${conversations.size + 1}",
            characterId = characterId,
            title = character.name,
            createdAt = "2026-01-01T00:00:00Z",
            updatedAt = "2026-01-01T00:00:00Z",
        ).also(conversations::add)

    override suspend fun listMessages(conversationId: String): List<ChatMessage> = emptyList()

    override suspend fun sendMessage(
        conversationId: String,
        text: String,
        providerProfileId: String,
        credential: String?,
    ): String = error("No provider is configured.")

    override suspend fun cancelGeneration(generationId: String) = Unit

    override suspend fun pollEvents(maxEvents: UInt): ChatEventBatch =
        ChatEventBatch(emptyList(), 0uL)

    override suspend fun getSettings(): AppSettings = AppSettings(false, null)

    override suspend fun updateSettings(settings: AppSettings): AppSettings = settings

    override suspend fun listProviderProfiles(): List<ProviderProfile> = emptyList()

    override suspend fun upsertProviderProfile(profile: ProviderProfile): ProviderProfile = profile

    override suspend fun deleteProviderProfile(profileId: String) = Unit

    override fun close() = Unit
}

private object InstrumentedCredentialStore : CredentialStore {
    override suspend fun read(providerProfileId: String): String? = null

    override suspend fun write(providerProfileId: String, credential: String) = Unit

    override suspend fun delete(providerProfileId: String) = Unit
}
