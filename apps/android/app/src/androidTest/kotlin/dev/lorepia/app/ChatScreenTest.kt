package dev.lorepia.app

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import dev.lorepia.app.bridge.*
import dev.lorepia.app.feature.chat.ChatScreen
import dev.lorepia.app.feature.chat.ChatUiState
import dev.lorepia.app.feature.chat.SelectedGenerationConfiguration
import dev.lorepia.app.platform.credentials.CredentialRecordStatus
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

    @Test
    fun missingCredentialShowsRepairAction() {
        var openedSettings = false
        val ready = readyState()
        composeRule.setContent {
            LorepiaTheme {
                ChatScreen(
                    uiState = ready.copy(
                        selectedGeneration = ready.selectedGeneration?.copy(
                            credentialRecordStatus = CredentialRecordStatus.Missing,
                        ),
                    ),
                    onOpenLibrary = {},
                    onOpenSettings = { openedSettings = true },
                    onRetry = {},
                    onSelectConversation = {},
                    onNewConversation = {},
                    onSend = {},
                    onCancel = {},
                    contentPadding = PaddingValues(),
                )
            }
        }

        composeRule.onNodeWithText(
            "저장된 자격증명을 사용할 수 없습니다. 설정에서 다시 입력해 주세요.",
        ).assertIsDisplayed()
        composeRule.onNodeWithText("설정 열기").performClick()
        assertTrue(openedSettings)
    }

    @Test
    fun deprecatedRouteShowsReplacementAction() {
        val ready = readyState()
        val selected = checkNotNull(ready.selectedGeneration)
        composeRule.setContent {
            LorepiaTheme {
                ChatScreen(
                    uiState = ready.copy(
                        selectedGeneration = selected.copy(
                            modelRoute = selected.modelRoute.copy(
                                availability = "deprecated",
                            ),
                        ),
                    ),
                    onOpenLibrary = {},
                    onOpenSettings = {},
                    onRetry = {},
                    onSelectConversation = {},
                    onNewConversation = {},
                    onSend = {},
                    onCancel = {},
                    contentPadding = PaddingValues(),
                )
            }
        }

        composeRule.onNodeWithText(
            "선택한 모델은 deprecated 상태여서 새 메시지를 보낼 수 없습니다.",
        ).assertIsDisplayed()
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
    val connection = ProviderConnection(
        id = "connection-1",
        templateId = "template-1",
        templateVersion = 1u,
        displayName = "합성 Provider",
        apiOrigin = "https://example.invalid",
        apiBasePath = "/v1",
        networkMode = ProviderNetworkMode.Public,
        values = emptyList(),
        credentialSlotReady = true,
        credentialScope = CredentialScope(
            allowedOrigins = listOf("https://example.invalid"),
            authBinding = AuthBinding.BearerHeader,
            redirectPolicy = CredentialRedirectPolicy.Deny,
        ),
        approvedCredentialOrigins = listOf("https://example.invalid"),
        timeoutSeconds = 30u,
        status = "connected",
        createdAt = "2026-01-01T00:00:00Z",
        updatedAt = "2026-01-01T00:00:00Z",
    )
    val route = ModelRoute(
        id = "route-1",
        connectionId = connection.id,
        apiFamily = "openai_chat_completions",
        modelId = "test-model",
        displayName = "Test Model",
        routeConfig = ModelRouteConfig(null, null, null, emptyList()),
        availability = "available",
        firstSeenAt = "2026-01-01T00:00:00Z",
        lastSeenAt = "2026-01-01T00:00:00Z",
    )
    val preset = GenerationPreset(
        id = "preset-1",
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
        selectedGeneration = SelectedGenerationConfiguration(
            connection,
            route,
            preset,
            CredentialRecordStatus.Available,
        ),
    )
}
