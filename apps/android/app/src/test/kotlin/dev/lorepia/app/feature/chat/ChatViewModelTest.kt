package dev.lorepia.app.feature.chat

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.FakeCredentialStore
import dev.lorepia.app.MainDispatcherRule
import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.AuthBinding
import dev.lorepia.app.bridge.ChatEvent
import dev.lorepia.app.bridge.ChatMessage
import dev.lorepia.app.bridge.ConversationSummary
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.GenerationPreset
import dev.lorepia.app.bridge.CredentialRedirectPolicy
import dev.lorepia.app.bridge.CredentialScope
import dev.lorepia.app.bridge.ModelRoute
import dev.lorepia.app.bridge.ModelRouteConfig
import dev.lorepia.app.bridge.ProviderConnection
import dev.lorepia.app.bridge.ProviderNetworkMode
import dev.lorepia.app.syntheticCharacter
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `chat starts empty when no persisted conversation exists`() = runTest {
        val core = FakeCoreClient(version = "0.1.0")

        val viewModel = ChatViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        assertEquals(ChatUiState.Empty("0.1.0"), viewModel.uiState.value)
    }

    @Test
    fun `character route creates first conversation and restores persisted messages`() = runTest {
        val character = syntheticCharacter()
        val core = FakeCoreClient(characters = listOf(character))

        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore(),
            requestedCharacterId = character.id,
        )
        advanceUntilIdle()

        val state = viewModel.uiState.value as ChatUiState.Ready
        assertEquals(character.id, state.conversation.characterId)
        assertTrue(core.conversations.any { it.id == state.conversation.id })
        assertTrue(state.messages.isEmpty())
    }

    @Test
    fun `existing conversation is selected without creating a duplicate`() = runTest {
        val character = syntheticCharacter()
        val conversation = syntheticConversation(character.id)
        val persisted = syntheticAssistant(conversation.id, "다시 만났네요.")
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            messages = mutableMapOf(conversation.id to mutableListOf(persisted)),
        )
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore(),
            requestedCharacterId = character.id,
        )
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value is ChatUiState.ChooseConversation)
        val restoredViewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore(),
            requestedConversationId = conversation.id,
        )
        advanceUntilIdle()

        val state = restoredViewModel.uiState.value as ChatUiState.Ready
        assertEquals(listOf(persisted), state.messages)
        assertEquals(1, core.conversations.size)
    }

    @Test
    fun `send uses Keystore credential and filters event generation and sequence`() = runTest {
        val character = syntheticCharacter()
        val conversation = syntheticConversation(character.id)
        val generation = syntheticGeneration()
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            messages = mutableMapOf(conversation.id to mutableListOf()),
            providerConnections = mutableListOf(generation.connection),
            modelRoutes = mutableMapOf(
                generation.connection.id to mutableListOf(generation.route),
            ),
            generationPresets = mutableMapOf(
                generation.route.id to mutableListOf(generation.preset),
            ),
            settings = generation.settings,
        )
        val credentials = FakeCredentialStore().apply {
            values[generation.connection.id] = "test-secret"
        }
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = credentials,
            requestedConversationId = conversation.id,
            pollIntervalMillis = 1,
        )
        advanceUntilIdle()

        core.queuedEvents += event(
            generationId = "another-generation",
            conversationId = conversation.id,
            sequence = 1u,
            kind = "text_delta",
            text = "무시",
        )
        core.queuedEvents += event(
            generationId = "generation-1",
            conversationId = conversation.id,
            sequence = 1u,
            kind = "text_delta",
            text = "안",
        )
        core.queuedEvents += event(
            generationId = "generation-1",
            conversationId = conversation.id,
            sequence = 1u,
            kind = "text_delta",
            text = "중복",
        )
        core.queuedEvents += event(
            generationId = "generation-1",
            conversationId = conversation.id,
            sequence = 2u,
            kind = "text_delta",
            text = "녕",
        )

        viewModel.send("안녕하세요")
        runCurrent()

        val streaming = viewModel.uiState.value as ChatUiState.Ready
        assertEquals("안녕", streaming.streamedText)
        assertEquals("test-secret", core.lastCredential)
        assertEquals(generation.route.id, core.lastGenerationTarget?.modelRouteId)
        assertEquals(generation.preset.id, core.lastGenerationTarget?.generationPresetId)

        core.messages.getValue(conversation.id) += syntheticAssistant(
            conversation.id,
            "안녕",
        )
        core.queuedEvents += event(
            generationId = "generation-1",
            conversationId = conversation.id,
            sequence = 3u,
            kind = "message_committed",
        )
        core.queuedEvents += event(
            generationId = "generation-1",
            conversationId = conversation.id,
            sequence = 4u,
            kind = "generation_finished",
        )
        advanceTimeBy(2)
        runCurrent()

        val finished = viewModel.uiState.value as ChatUiState.Ready
        assertNull(finished.activeGenerationId)
        assertEquals("안녕", finished.messages.last().content)
    }

    @Test
    fun `send resolves the latest paired target before reading its credential`() = runTest {
        val character = syntheticCharacter()
        val conversation = syntheticConversation(character.id)
        val old = syntheticGeneration("old")
        val current = syntheticGeneration("current")
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            providerConnections = mutableListOf(old.connection, current.connection),
            modelRoutes = mutableMapOf(
                old.connection.id to mutableListOf(old.route),
                current.connection.id to mutableListOf(current.route),
            ),
            generationPresets = mutableMapOf(
                old.route.id to mutableListOf(old.preset),
                current.route.id to mutableListOf(current.preset),
            ),
            settings = old.settings,
        )
        val credentials = FakeCredentialStore().apply {
            values[old.connection.id] = "old-secret"
            values[current.connection.id] = "current-secret"
        }
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = credentials,
            requestedConversationId = conversation.id,
        )
        advanceUntilIdle()
        core.settings = current.settings

        viewModel.send("최신 설정으로 보내 줘")
        runCurrent()

        assertEquals("current-secret", core.lastCredential)
        assertEquals(current.route.id, core.lastGenerationTarget?.modelRouteId)
        assertEquals(
            listOf("credential:read:${current.connection.id}"),
            credentials.operations,
        )
        val ready = viewModel.uiState.value as ChatUiState.Ready
        assertEquals(current.preset.id, ready.selectedGeneration?.preset?.id)
        viewModel.setRouteActive(false)
    }

    @Test
    fun `later configuration refresh wins even when an older same conversation read finishes last`() =
        runTest {
            val character = syntheticCharacter()
            val conversation = syntheticConversation(character.id)
            val old = syntheticGeneration("old-refresh")
            val current = syntheticGeneration("current-refresh")
            val delegate = FakeCoreClient(
                characters = listOf(character),
                conversations = mutableListOf(conversation),
                providerConnections = mutableListOf(old.connection, current.connection),
                modelRoutes = mutableMapOf(
                    old.connection.id to mutableListOf(old.route),
                    current.connection.id to mutableListOf(current.route),
                ),
                generationPresets = mutableMapOf(
                    old.route.id to mutableListOf(old.preset),
                    current.route.id to mutableListOf(current.preset),
                ),
                settings = old.settings,
            )
            val core = ConfigurationRaceCore(delegate)
            val credentials = FakeCredentialStore().apply {
                values[old.connection.id] = "old-secret"
                values[current.connection.id] = "current-secret"
            }
            val viewModel = ChatViewModel(
                coreClient = core,
                credentialStore = credentials,
                requestedConversationId = conversation.id,
            )
            advanceUntilIdle()

            core.settingsResponses.addAll(
                listOf(
                    old.settings,
                    current.settings,
                    current.settings,
                    old.settings,
                ),
            )
            core.gateFirstConnectionRead = true
            viewModel.refreshConfiguration()
            runCurrent()
            core.firstConnectionReadStarted.await()

            viewModel.refreshConfiguration()
            runCurrent()
            assertEquals(
                current.preset.id,
                (viewModel.uiState.value as ChatUiState.Ready).selectedGeneration?.preset?.id,
            )

            core.releaseFirstConnectionRead.complete(Unit)
            advanceUntilIdle()

            val ready = viewModel.uiState.value as ChatUiState.Ready
            assertEquals(current.route.id, ready.selectedGeneration?.modelRoute?.id)
            assertEquals(current.preset.id, ready.selectedGeneration?.preset?.id)
        }

    @Test
    fun `configuration hydration retries when the selected route preset pair changes`() =
        runTest {
            val character = syntheticCharacter()
            val conversation = syntheticConversation(character.id)
            val old = syntheticGeneration("old-pair")
            val current = syntheticGeneration("current-pair")
            val delegate = FakeCoreClient(
                characters = listOf(character),
                conversations = mutableListOf(conversation),
                providerConnections = mutableListOf(old.connection, current.connection),
                modelRoutes = mutableMapOf(
                    old.connection.id to mutableListOf(old.route),
                    current.connection.id to mutableListOf(current.route),
                ),
                generationPresets = mutableMapOf(
                    old.route.id to mutableListOf(old.preset),
                    current.route.id to mutableListOf(current.preset),
                ),
                settings = old.settings,
            )
            val core = ConfigurationRaceCore(delegate).apply {
                settingsResponses.addAll(
                    listOf(
                        old.settings,
                        current.settings,
                        current.settings,
                    ),
                )
            }
            val viewModel = ChatViewModel(
                coreClient = core,
                credentialStore = FakeCredentialStore(),
                requestedConversationId = conversation.id,
            )
            advanceUntilIdle()

            core.settingsResponses.addAll(
                listOf(
                    old.settings,
                    current.settings,
                    current.settings,
                ),
            )
            viewModel.refreshConfiguration()
            advanceUntilIdle()

            val ready = viewModel.uiState.value as ChatUiState.Ready
            assertEquals(current.route.id, ready.selectedGeneration?.modelRoute?.id)
            assertEquals(current.preset.id, ready.selectedGeneration?.preset?.id)
        }

    @Test
    fun `cross-wired credential reference fails before Keystore read or send`() = runTest {
        val character = syntheticCharacter()
        val conversation = syntheticConversation(character.id)
        val valid = syntheticGeneration()
        val corrupt = valid.copy(
            connection = valid.connection.copy(
                credentialScope = valid.connection.credentialScope?.copy(
                    allowedOrigins = listOf("https://other.example.invalid"),
                ),
            ),
        )
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            providerConnections = mutableListOf(corrupt.connection),
            modelRoutes = mutableMapOf(
                corrupt.connection.id to mutableListOf(corrupt.route),
            ),
            generationPresets = mutableMapOf(
                corrupt.route.id to mutableListOf(corrupt.preset),
            ),
            settings = corrupt.settings,
        )
        val credentials = FakeCredentialStore().apply {
            values["another-connection"] = "must-not-be-read"
        }
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = credentials,
            requestedConversationId = conversation.id,
        )
        advanceUntilIdle()

        viewModel.send("보내면 안 돼")
        runCurrent()

        assertTrue(credentials.operations.isEmpty())
        assertEquals(0, core.sendMessageCalls)
        val ready = viewModel.uiState.value as ChatUiState.Ready
        assertTrue(ready.notice!!.contains("credential reference"))
    }

    @Test
    fun `active generation can be cancelled`() = runTest {
        val character = syntheticCharacter()
        val conversation = syntheticConversation(character.id)
        val generation = syntheticGeneration()
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            providerConnections = mutableListOf(generation.connection),
            modelRoutes = mutableMapOf(
                generation.connection.id to mutableListOf(generation.route),
            ),
            generationPresets = mutableMapOf(
                generation.route.id to mutableListOf(generation.preset),
            ),
            settings = generation.settings,
        )
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore().apply {
                values[generation.connection.id] = "synthetic-secret"
            },
            requestedConversationId = conversation.id,
            pollIntervalMillis = 1,
        )
        advanceUntilIdle()

        viewModel.send("취소해 줘")
        runCurrent()
        viewModel.cancel()
        runCurrent()

        assertEquals(1, core.cancelGenerationCalls)

        core.queuedEvents += event(
            generationId = "generation-1",
            conversationId = conversation.id,
            sequence = 1u,
            kind = "text_delta",
            text = "취소 뒤 늦은 조각",
        )
        advanceTimeBy(2)
        runCurrent()
        val cancelling = viewModel.uiState.value as ChatUiState.Ready
        assertTrue(cancelling.isCancelling)
        assertTrue(cancelling.streamedText.isEmpty())

        core.queuedEvents += event(
            generationId = "generation-1",
            conversationId = conversation.id,
            sequence = 2u,
            kind = "generation_cancelled",
        )
        advanceTimeBy(2)
        runCurrent()
        assertNull((viewModel.uiState.value as ChatUiState.Ready).activeGenerationId)
    }

    @Test
    fun `empty event batches reconcile a generation completed by another consumer`() = runTest {
        val character = syntheticCharacter()
        val conversation = syntheticConversation(character.id)
        val generation = syntheticGeneration()
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            messages = mutableMapOf(conversation.id to mutableListOf()),
            providerConnections = mutableListOf(generation.connection),
            modelRoutes = mutableMapOf(
                generation.connection.id to mutableListOf(generation.route),
            ),
            generationPresets = mutableMapOf(
                generation.route.id to mutableListOf(generation.preset),
            ),
            settings = generation.settings,
        )
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore().apply {
                values[generation.connection.id] = "synthetic-secret"
            },
            requestedConversationId = conversation.id,
            pollIntervalMillis = 1,
            emptyBatchesBeforeReconcile = 2,
        )
        advanceUntilIdle()

        viewModel.send("다른 화면에서도 보이게 해 줘")
        runCurrent()
        core.messages.getValue(conversation.id).removeAll {
            it.generationId == "generation-1"
        }
        core.messages.getValue(conversation.id) += syntheticAssistant(
            conversation.id,
            "다른 이벤트 소비자가 완료했어요.",
        )

        advanceTimeBy(2)
        runCurrent()

        val reconciled = viewModel.uiState.value as ChatUiState.Ready
        assertNull(reconciled.activeGenerationId)
        assertTrue(reconciled.streamedText.isEmpty())
        assertEquals("다른 이벤트 소비자가 완료했어요.", reconciled.messages.last().content)
    }

    @Test
    fun `route resume reconciles a generation completed while inactive`() = runTest {
        val character = syntheticCharacter()
        val conversation = syntheticConversation(character.id)
        val generation = syntheticGeneration()
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            messages = mutableMapOf(conversation.id to mutableListOf()),
            providerConnections = mutableListOf(generation.connection),
            modelRoutes = mutableMapOf(
                generation.connection.id to mutableListOf(generation.route),
            ),
            generationPresets = mutableMapOf(
                generation.route.id to mutableListOf(generation.preset),
            ),
            settings = generation.settings,
        )
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore().apply {
                values[generation.connection.id] = "synthetic-secret"
            },
            requestedConversationId = conversation.id,
            pollIntervalMillis = 1,
        )
        advanceUntilIdle()

        viewModel.send("잠깐 다른 화면에 다녀올게")
        runCurrent()
        viewModel.setRouteActive(false)
        core.messages.getValue(conversation.id).removeAll {
            it.generationId == "generation-1"
        }
        core.messages.getValue(conversation.id) += syntheticAssistant(
            conversation.id,
            "돌아오기 전에 완료했어요.",
        )

        viewModel.setRouteActive(true)
        runCurrent()

        val reconciled = viewModel.uiState.value as ChatUiState.Ready
        assertNull(reconciled.activeGenerationId)
        assertTrue(reconciled.streamedText.isEmpty())
        assertEquals("돌아오기 전에 완료했어요.", reconciled.messages.last().content)
    }
}

private class ConfigurationRaceCore(
    private val delegate: FakeCoreClient,
) : CoreClient by delegate {
    val settingsResponses = ArrayDeque<AppSettings>()
    val firstConnectionReadStarted = CompletableDeferred<Unit>()
    val releaseFirstConnectionRead = CompletableDeferred<Unit>()
    var gateFirstConnectionRead = false

    override suspend fun getSettings(): AppSettings = withContext(NonCancellable) {
        settingsResponses.removeFirstOrNull() ?: delegate.getSettings()
    }

    override suspend fun listProviderConnections(): List<ProviderConnection> =
        withContext(NonCancellable) {
            val snapshot = delegate.listProviderConnections()
            if (gateFirstConnectionRead) {
                gateFirstConnectionRead = false
                firstConnectionReadStarted.complete(Unit)
                releaseFirstConnectionRead.await()
            }
            snapshot
        }

    override suspend fun listModelRoutes(connectionId: String): List<ModelRoute> =
        withContext(NonCancellable) { delegate.listModelRoutes(connectionId) }

    override suspend fun listGenerationPresets(modelRouteId: String): List<GenerationPreset> =
        withContext(NonCancellable) { delegate.listGenerationPresets(modelRouteId) }
}

private fun syntheticConversation(characterId: String) = ConversationSummary(
    id = "conversation-1",
    characterId = characterId,
    title = "합성 대화",
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-01T00:00:00Z",
)

private data class SyntheticGeneration(
    val connection: ProviderConnection,
    val route: ModelRoute,
    val preset: GenerationPreset,
) {
    val settings = AppSettings(
        preservePartialGenerations = false,
        selectedProviderProfileId = null,
        selectedModelRouteId = route.id,
        selectedGenerationPresetId = preset.id,
    )
}

private fun syntheticGeneration(suffix: String = "1"): SyntheticGeneration {
    val origin = "https://$suffix.example.invalid"
    val connection = ProviderConnection(
        id = "connection-$suffix",
        templateId = "template-$suffix",
        templateVersion = 1u,
        displayName = "합성 Provider",
        apiOrigin = origin,
        apiBasePath = "/v1",
        networkMode = ProviderNetworkMode.Public,
        values = emptyList(),
        credentialSlotReady = true,
        credentialScope = CredentialScope(
            allowedOrigins = listOf(origin),
            authBinding = AuthBinding.BearerHeader,
            redirectPolicy = CredentialRedirectPolicy.Deny,
        ),
        approvedCredentialOrigins = listOf(origin),
        timeoutSeconds = 30u,
        status = "connected",
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:00Z",
    )
    val route = ModelRoute(
        id = "route-$suffix",
        connectionId = connection.id,
        apiFamily = "openai_chat_completions",
        modelId = "test-model-$suffix",
        displayName = "Test Model",
        routeConfig = ModelRouteConfig(null, null, null, emptyList()),
        availability = "available",
        firstSeenAt = "2026-01-01T00:00:00Z",
        lastSeenAt = "2026-01-01T00:00:00Z",
    )
    val preset = GenerationPreset(
        id = "preset-$suffix",
        modelRouteId = route.id,
        displayName = "기본",
        values = emptyList(),
        reasoningMode = "provider_default",
        reasoningEffort = null,
        reasoningBudgetTokens = null,
        reasoningSummary = "provider_default",
        preserveOpaqueReasoningState = false,
        promptCacheMode = "provider_default",
        promptCacheTtl = "provider_default",
        promptCacheCustomTtlSeconds = null,
        promptCacheContextReference = null,
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:00Z",
    )
    return SyntheticGeneration(connection, route, preset)
}

private fun syntheticAssistant(conversationId: String, text: String) = ChatMessage(
    id = "assistant-$text",
    conversationId = conversationId,
    parentId = "user-1",
    role = "assistant",
    content = text,
    status = "complete",
    generationId = "generation-1",
    createdAt = "2026-01-01T00:00:01Z",
)

private fun event(
    generationId: String,
    conversationId: String,
    sequence: ULong,
    kind: String,
    text: String? = null,
) = ChatEvent(
    eventVersion = 4u,
    generationId = generationId,
    conversationId = conversationId,
    branchId = "branch-1",
    assistantMessageId = "assistant-1",
    sequence = sequence,
    emittedAt = "2026-01-01T00:00:01Z",
    kind = kind,
    text = text,
    messageId = null,
    messageStatus = null,
    errorCode = null,
    errorMessage = null,
    usageInputTokens = null,
    usageOutputTokens = null,
)
