package dev.lorepia.app.feature.importreview

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.platform.files.StagedDocument
import java.io.File

@Composable
fun ImportReviewRoute(
    coreClient: CoreClient,
    document: StagedDocument,
    stagingDirectory: File,
    contentPadding: PaddingValues,
    onImported: (CharacterSummary) -> Unit,
    onNavigateBack: () -> Unit,
) {
    val viewModel: ImportReviewViewModel = viewModel(
        factory = ImportReviewViewModel.factory(
            coreClient = coreClient,
            document = document,
            stagingDirectory = stagingDirectory,
        ),
    )
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    val isBusy = uiState is ImportReviewUiState.Loading ||
        (uiState as? ImportReviewUiState.Ready)?.isCommitting == true
    val closeReview = {
        viewModel.discard()
        onNavigateBack()
    }

    LaunchedEffect(uiState) {
        val imported = uiState as? ImportReviewUiState.Imported
        if (imported != null) {
            onImported(imported.character)
        }
    }

    BackHandler {
        if (!isBusy) {
            closeReview()
        }
    }

    ImportReviewScreen(
        uiState = uiState,
        onCommit = viewModel::commit,
        onClose = closeReview,
        contentPadding = contentPadding,
    )
}
