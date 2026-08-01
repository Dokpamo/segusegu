package dev.lorepia.app.feature.chat

import dev.lorepia.app.bridge.ChatMessage
import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.ConversationSummary
import dev.lorepia.app.bridge.GenerationPreset
import dev.lorepia.app.bridge.ModelRoute
import dev.lorepia.app.bridge.ProviderConnection
import dev.lorepia.app.platform.credentials.CredentialRecordStatus

data class SelectedGenerationConfiguration(
    val connection: ProviderConnection,
    val modelRoute: ModelRoute,
    val preset: GenerationPreset,
    val credentialRecordStatus: CredentialRecordStatus? = null,
)

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
        val selectedGeneration: SelectedGenerationConfiguration?,
        val activeGenerationId: String? = null,
        val streamedText: String = "",
        val isSubmitting: Boolean = false,
        val isCancelling: Boolean = false,
        val notice: String? = null,
    ) : ChatUiState {
        val canSend: Boolean
            get() = activeGenerationId == null &&
                !isSubmitting &&
                selectedGeneration?.modelRoute?.availability !in setOf(
                    null,
                    "retired",
                    "deprecated",
                    "access_denied",
                    "missing_temporarily",
                ) &&
                (
                    selectedGeneration?.connection?.credentialSlotReady != true ||
                        selectedGeneration.credentialRecordStatus ==
                        CredentialRecordStatus.Available
                    )
    }

    data class Error(
        val cause: Throwable,
    ) : ChatUiState
}
