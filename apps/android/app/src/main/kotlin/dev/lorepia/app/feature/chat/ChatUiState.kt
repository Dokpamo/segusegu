package dev.lorepia.app.feature.chat

import dev.lorepia.app.bridge.ChatMessage
import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.ConversationSummary
import dev.lorepia.app.bridge.ProviderProfile

sealed interface ChatUiState {
    data object Loading : ChatUiState

    data class Empty(
        val coreVersion: String,
    ) : ChatUiState

    data class ChooseConversation(
        val character: CharacterSummary?,
        val conversations: List<ConversationSummary>,
        val isCreating: Boolean = false,
        val error: Throwable? = null,
    ) : ChatUiState

    data class Ready(
        val character: CharacterSummary,
        val conversation: ConversationSummary,
        val messages: List<ChatMessage>,
        val providerProfiles: List<ProviderProfile>,
        val selectedProvider: ProviderProfile?,
        val activeGenerationId: String? = null,
        val streamedText: String = "",
        val isSubmitting: Boolean = false,
        val isCancelling: Boolean = false,
        val notice: String? = null,
    ) : ChatUiState {
        val canSend: Boolean
            get() = activeGenerationId == null && !isSubmitting && selectedProvider != null
    }

    data class Error(
        val cause: Throwable,
    ) : ChatUiState
}
