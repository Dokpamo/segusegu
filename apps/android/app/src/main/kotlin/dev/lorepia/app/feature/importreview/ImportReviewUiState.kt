package dev.lorepia.app.feature.importreview

import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.ImportInspection
import dev.lorepia.app.platform.files.StagedDocument

sealed interface ImportReviewUiState {
    data class Loading(
        val document: StagedDocument,
    ) : ImportReviewUiState

    data class Ready(
        val document: StagedDocument,
        val inspection: ImportInspection,
        val isCommitting: Boolean = false,
        val isDiscarding: Boolean = false,
        val commitError: Throwable? = null,
    ) : ImportReviewUiState

    data class Imported(
        val character: CharacterSummary,
    ) : ImportReviewUiState

    data class Error(
        val cause: Throwable,
    ) : ImportReviewUiState
}
