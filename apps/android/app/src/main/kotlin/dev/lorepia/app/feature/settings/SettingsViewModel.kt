package dev.lorepia.app.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.lorepia.app.bridge.CoreClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class SettingsViewModel(
    private val coreClient: CoreClient,
) : ViewModel() {
    private val _uiState = MutableStateFlow<SettingsUiState>(SettingsUiState.Loading)
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()
    private var refreshJob: Job? = null

    init {
        refresh()
    }

    fun refresh() {
        refreshJob?.cancel()
        _uiState.value = SettingsUiState.Loading
        refreshJob = viewModelScope.launch {
            try {
                _uiState.value = SettingsUiState.Ready(coreClient.healthCheck())
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                _uiState.value = SettingsUiState.Error(error)
            }
        }
    }

    companion object {
        fun factory(coreClient: CoreClient): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                SettingsViewModel(coreClient)
            }
        }
    }
}
