package dev.lorepia.app.feature.chat

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.FakeCredentialStore
import dev.lorepia.app.MainDispatcherRule
import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.ChatEvent
import dev.lorepia.app.bridge.ChatMessage
import dev.lorepia.app.bridge.ConversationSummary
import dev.lorepia.app.bridge.ProviderProfile
import dev.lorepia.app.syntheticCharacter
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
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
        val profile = syntheticProvider()
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            messages = mutableMapOf(conversation.id to mutableListOf()),
            profiles = mutableListOf(profile),
            settings = AppSettings(false, profile.id),
        )
        val credentials = FakeCredentialStore().apply {
            values[profile.id] = "test-secret"
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
    fun `active generation can be cancelled`() = runTest {
        val character = syntheticCharacter()
        val conversation = syntheticConversation(character.id)
        val profile = syntheticProvider()
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            profiles = mutableListOf(profile),
            settings = AppSettings(false, profile.id),
        )
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore(),
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
        val profile = syntheticProvider()
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            messages = mutableMapOf(conversation.id to mutableListOf()),
            profiles = mutableListOf(profile),
            settings = AppSettings(false, profile.id),
        )
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore(),
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
        val profile = syntheticProvider()
        val core = FakeCoreClient(
            characters = listOf(character),
            conversations = mutableListOf(conversation),
            messages = mutableMapOf(conversation.id to mutableListOf()),
            profiles = mutableListOf(profile),
            settings = AppSettings(false, profile.id),
        )
        val viewModel = ChatViewModel(
            coreClient = core,
            credentialStore = FakeCredentialStore(),
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

private fun syntheticConversation(characterId: String) = ConversationSummary(
    id = "conversation-1",
    characterId = characterId,
    title = "합성 대화",
    createdAt = "2026-01-01T00:00:00Z",
    updatedAt = "2026-01-01T00:00:00Z",
)

private fun syntheticProvider() = ProviderProfile(
    id = "provider-1",
    displayName = "합성 Provider",
    baseUrl = "https://example.invalid/v1",
    model = "test-model",
    timeoutSeconds = 30u,
)

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
    eventVersion = 1u,
    generationId = generationId,
    conversationId = conversationId,
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
