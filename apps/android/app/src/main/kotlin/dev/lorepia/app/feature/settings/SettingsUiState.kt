package dev.lorepia.app.feature.settings

import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.CoreHealthStatus
import dev.lorepia.app.bridge.ProviderProfile

sealed interface SettingsUiState {
    data object Loading : SettingsUiState

    data class Ready(
        val health: CoreHealthStatus,
        val settings: AppSettings,
        val profiles: List<ProviderProfile>,
        val editor: ProviderEditor? = null,
        val isSaving: Boolean = false,
        val notice: String? = null,
        val error: String? = null,
    ) : SettingsUiState

    data class Error(
        val cause: Throwable,
    ) : SettingsUiState
}

data class ProviderEditor(
    val id: String,
    val displayName: String = "",
    val baseUrl: String = "https://api.openai.com/v1",
    val model: String = "",
    val timeoutSeconds: String = "60",
    val credential: String = "",
    val isExisting: Boolean = false,
)
