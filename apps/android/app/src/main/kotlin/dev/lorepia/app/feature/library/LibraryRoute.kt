package dev.lorepia.app.feature.library

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.platform.files.DocumentStager
import dev.lorepia.app.platform.files.StagedDocument
import dev.lorepia.app.platform.files.rememberCharacterDocumentPicker
import dev.lorepia.app.platform.paths.AppDirectories
import java.io.File
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

@Composable
fun LibraryRoute(
    coreClient: CoreClient,
    contentPadding: PaddingValues,
    refreshSignal: Int,
    onReviewImport: (StagedDocument) -> Unit,
) {
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    val stager = remember(context) {
        DocumentStager(
            contentResolver = context.contentResolver,
            stagingDirectory = AppDirectories.create(context).staging,
        )
    }
    val viewModel: LibraryViewModel = viewModel(
        factory = LibraryViewModel.factory(coreClient),
    )
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    var isStaging by remember { mutableStateOf(false) }
    var stagingError by remember { mutableStateOf(false) }

    LaunchedEffect(refreshSignal) {
        if (refreshSignal > 0) {
            viewModel.refresh()
        }
    }

    val openPicker = rememberCharacterDocumentPicker { uri ->
        if (uri != null) {
            isStaging = true
            stagingError = false
            coroutineScope.launch {
                var stagedDocument: StagedDocument? = null
                try {
                    stagedDocument = stager.stage(uri)
                    onReviewImport(stagedDocument)
                    stagedDocument = null
                } catch (cancellation: CancellationException) {
                    stagedDocument?.let { document ->
                        File(document.path).delete()
                    }
                    throw cancellation
                } catch (_: Throwable) {
                    stagedDocument?.let { document ->
                        File(document.path).delete()
                    }
                    stagingError = true
                } finally {
                    isStaging = false
                }
            }
        }
    }

    LibraryScreen(
        uiState = uiState,
        isStaging = isStaging,
        stagingError = stagingError,
        onImport = openPicker,
        onRetry = viewModel::refresh,
        contentPadding = contentPadding,
    )
}
