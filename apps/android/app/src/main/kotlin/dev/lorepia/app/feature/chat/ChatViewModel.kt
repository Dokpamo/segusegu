package dev.lorepia.app.feature.chat

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

class ChatViewModel(
    private val coreClient: CoreClient,
) : ViewModel() {
    private val _uiState = MutableStateFlow<ChatUiState>(ChatUiState.Loading)
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()
    private var loadJob: Job? = null

    init {
        load()
    }

    fun retry() {
        load()
    }

    private fun load() {
        loadJob?.cancel()
        _uiState.value = ChatUiState.Loading
        loadJob = viewModelScope.launch {
            try {
                _uiState.value = ChatUiState.Empty(coreClient.coreVersion())
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                _uiState.value = ChatUiState.Error(error)
            }
        }
    }

    companion object {
        fun factory(coreClient: CoreClient): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                ChatViewModel(coreClient)
            }
        }
    }
}
