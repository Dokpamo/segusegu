package dev.lorepia.app

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import dev.lorepia.app.bridge.ChatMessage
import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.ConversationSummary
import dev.lorepia.app.bridge.ProviderProfile
import dev.lorepia.app.feature.chat.ChatScreen
import dev.lorepia.app.feature.chat.ChatUiState
import dev.lorepia.app.ui.theme.LorepiaTheme
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

class ChatScreenTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun persistedMessagesCanBeReadAndNewMessageCanBeSent() {
        var sent = ""
        composeRule.setContent {
            LorepiaTheme {
                ChatScreen(
                    uiState = readyState(),
                    onOpenLibrary = {},
                    onOpenSettings = {},
                    onRetry = {},
                    onSelectConversation = {},
                    onNewConversation = {},
                    onSend = { sent = it },
                    onCancel = {},
                    contentPadding = PaddingValues(),
                )
            }
        }

        composeRule.onNodeWithText("저장된 응답").assertIsDisplayed()
        composeRule.onNodeWithText("메시지").performTextInput("새 메시지")
        composeRule.onNodeWithText("보내기").performClick()

        assertEquals("새 메시지", sent)
    }

    @Test
    fun activeGenerationExposesCancelAction() {
        var cancelled = false
        composeRule.setContent {
            LorepiaTheme {
                ChatScreen(
                    uiState = readyState().copy(
                        activeGenerationId = "generation-1",
                        streamedText = "생성 중인 응답",
                    ),
                    onOpenLibrary = {},
                    onOpenSettings = {},
                    onRetry = {},
                    onSelectConversation = {},
                    onNewConversation = {},
                    onSend = {},
                    onCancel = { cancelled = true },
                    contentPadding = PaddingValues(),
                )
            }
        }

        composeRule.onNodeWithText("생성 중인 응답").assertIsDisplayed()
        composeRule.onNodeWithText("생성 취소").performClick()
        assertTrue(cancelled)
    }
}

private fun readyState(): ChatUiState.Ready {
    val character = CharacterSummary(
        id = "character-1",
        name = "합성 캐릭터",
        description = "",
        sourceHash = "a".repeat(64),
    )
    val conversation = ConversationSummary(
        id = "conversation-1",
        characterId = character.id,
        title = character.name,
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:01Z",
    )
    val profile = ProviderProfile(
        id = "provider-1",
        displayName = "합성 Provider",
        baseUrl = "https://example.invalid/v1",
        model = "test-model",
        timeoutSeconds = 30u,
    )
    return ChatUiState.Ready(
        character = character,
        conversation = conversation,
        messages = listOf(
            ChatMessage(
                id = "assistant-1",
                conversationId = conversation.id,
                parentId = "user-1",
                role = "assistant",
                content = "저장된 응답",
                status = "complete",
                generationId = "generation-0",
                createdAt = "2026-01-01T00:00:01Z",
            ),
        ),
        providerProfiles = listOf(profile),
        selectedProvider = profile,
    )
}
