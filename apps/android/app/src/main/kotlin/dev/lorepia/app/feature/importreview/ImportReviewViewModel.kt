package dev.lorepia.app.feature.importreview

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.platform.files.StagedDocument
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * Coordinates the high-level Rust inspection and commit operations while
 * Android retains responsibility for the staged file's lifetime.
 */
class ImportReviewViewModel(
    private val coreClient: CoreClient,
    private val document: StagedDocument,
    private val stagingDirectory: File,
) : ViewModel() {
    private val _uiState = MutableStateFlow<ImportReviewUiState>(
        ImportReviewUiState.Loading(document),
    )
    val uiState: StateFlow<ImportReviewUiState> = _uiState.asStateFlow()

    init {
        inspect()
    }

    fun commit() {
        val ready = _uiState.value as? ImportReviewUiState.Ready ?: return
        if (ready.inspection.isBlocked || ready.isCommitting) return

        _uiState.value = ready.copy(isCommitting = true, commitError = null)
        viewModelScope.launch {
            try {
                val character = coreClient.commitImport(ready.inspection.id)
                deleteStagedDocument()
                _uiState.value = ImportReviewUiState.Imported(character)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                _uiState.value = ready.copy(commitError = error)
            }
        }
    }

    fun discard(onFinished: () -> Unit = {}) {
        val ready = _uiState.value as? ImportReviewUiState.Ready
        if (ready == null) {
            deleteStagedDocument()
            onFinished()
            return
        }
        if (ready.isCommitting || ready.isDiscarding) return
        _uiState.value = ready.copy(isDiscarding = true)
        viewModelScope.launch {
            try {
                coreClient.discardImport(ready.inspection.id)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (_: Throwable) {
                // The Rust core also clears abandoned snapshots during recovery.
            } finally {
                deleteStagedDocument()
                onFinished()
            }
        }
    }

    private fun inspect() {
        viewModelScope.launch {
            try {
                require(isInsideStagingDirectory(document.path)) {
                    "The staged document is outside the app staging directory."
                }
                require(document.sizeBytes >= 0) { "The staged document size is invalid." }
                val inspection = coreClient.inspectImport(document.path)
                deleteStagedDocument()
                _uiState.value = ImportReviewUiState.Ready(
                    document = document,
                    inspection = inspection,
                )
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                _uiState.value = ImportReviewUiState.Error(error)
            }
        }
    }

    private fun deleteStagedDocument() {
        runCatching {
            if (isInsideStagingDirectory(document.path)) {
                File(document.path).delete()
            }
        }
    }

    private fun isInsideStagingDirectory(path: String): Boolean {
        val root = stagingDirectory.canonicalFile
        val candidate = File(path).canonicalFile
        return candidate.parentFile == root
    }

    companion object {
        fun factory(
            coreClient: CoreClient,
            document: StagedDocument,
            stagingDirectory: File,
        ): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                ImportReviewViewModel(coreClient, document, stagingDirectory)
            }
        }
    }
}
