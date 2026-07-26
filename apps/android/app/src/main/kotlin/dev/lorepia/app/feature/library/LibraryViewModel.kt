package dev.lorepia.app.feature.library

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

class LibraryViewModel(
    private val coreClient: CoreClient,
) : ViewModel() {
    private val _uiState = MutableStateFlow<LibraryUiState>(LibraryUiState.Loading)
    val uiState: StateFlow<LibraryUiState> = _uiState.asStateFlow()
    private var refreshJob: Job? = null

    init {
        refresh()
    }

    fun refresh() {
        refreshJob?.cancel()
        _uiState.value = LibraryUiState.Loading
        refreshJob = viewModelScope.launch {
            try {
                val version = coreClient.coreVersion()
                val characters = coreClient.listCharacters()
                _uiState.value = if (characters.isEmpty()) {
                    LibraryUiState.Empty(version)
                } else {
                    LibraryUiState.Content(version, characters)
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                _uiState.value = LibraryUiState.Error(error)
            }
        }
    }

    companion object {
        fun factory(coreClient: CoreClient): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                LibraryViewModel(coreClient)
            }
        }
    }
}
