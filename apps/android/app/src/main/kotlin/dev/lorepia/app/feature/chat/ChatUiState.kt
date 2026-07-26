package dev.lorepia.app.feature.chat

sealed interface ChatUiState {
    data object Loading : ChatUiState

    data class Empty(
        val coreVersion: String,
    ) : ChatUiState

    data class Error(
        val cause: Throwable,
    ) : ChatUiState
}
