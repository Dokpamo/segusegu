package dev.lorepia.app.app

import dev.lorepia.app.bridge.CoreHealthStatus

sealed interface AppUiState {
    data object Loading : AppUiState

    data class Ready(
        val coreVersion: String,
        val health: CoreHealthStatus,
    ) : AppUiState

    data class Error(
        val cause: Throwable,
    ) : AppUiState
}
