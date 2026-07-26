package dev.lorepia.app.app

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.lorepia.app.bridge.CoreClient
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.viewModelScope

class AppViewModel(
    private val coreClientFactory: () -> CoreClient,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
    private val releaseCoreClient: (CoreClient) -> Unit = CoreClient::close,
) : ViewModel() {
    private val _uiState = MutableStateFlow<AppUiState>(AppUiState.Loading)
    val uiState: StateFlow<AppUiState> = _uiState.asStateFlow()

    var coreClient: CoreClient? = null
        private set
    private var connectJob: Job? = null

    init {
        connect()
    }

    fun retry() {
        coreClient?.let(releaseCoreClient)
        coreClient = null
        connect()
    }

    private fun connect() {
        connectJob?.cancel()
        _uiState.value = AppUiState.Loading
        connectJob = viewModelScope.launch {
            var openedClient: CoreClient? = null
            try {
                openedClient = withContext(ioDispatcher) {
                    coreClientFactory()
                }
                val version = openedClient.coreVersion()
                val health = openedClient.healthCheck()
                coreClient = openedClient
                openedClient = null
                _uiState.value = AppUiState.Ready(version, health)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                coreClient?.let(releaseCoreClient)
                coreClient = null
                _uiState.value = AppUiState.Error(error)
            } finally {
                openedClient?.let(releaseCoreClient)
            }
        }
    }

    override fun onCleared() {
        coreClient?.let(releaseCoreClient)
        coreClient = null
        super.onCleared()
    }

    companion object {
        fun factory(
            coreClientFactory: () -> CoreClient,
            releaseCoreClient: (CoreClient) -> Unit,
        ): ViewModelProvider.Factory =
            viewModelFactory {
                initializer {
                    AppViewModel(
                        coreClientFactory = coreClientFactory,
                        releaseCoreClient = releaseCoreClient,
                    )
                }
            }
    }
}
