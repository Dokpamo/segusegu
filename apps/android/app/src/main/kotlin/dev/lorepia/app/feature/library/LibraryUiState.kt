package dev.lorepia.app.feature.library

import dev.lorepia.app.bridge.CharacterSummary

sealed interface LibraryUiState {
    data object Loading : LibraryUiState

    data class Empty(
        val coreVersion: String,
    ) : LibraryUiState

    data class Content(
        val coreVersion: String,
        val characters: List<CharacterSummary>,
    ) : LibraryUiState

    data class Error(
        val cause: Throwable,
    ) : LibraryUiState
}
