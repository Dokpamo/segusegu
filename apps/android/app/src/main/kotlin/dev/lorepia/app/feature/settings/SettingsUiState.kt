package dev.lorepia.app.feature.settings

import dev.lorepia.app.bridge.CoreHealthStatus

sealed interface SettingsUiState {
    data object Loading : SettingsUiState

    data class Ready(
        val health: CoreHealthStatus,
    ) : SettingsUiState

    data class Error(
        val cause: Throwable,
    ) : SettingsUiState
}
