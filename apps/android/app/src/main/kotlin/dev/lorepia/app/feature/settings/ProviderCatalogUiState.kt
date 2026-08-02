package dev.lorepia.app.feature.settings

import dev.lorepia.app.bridge.ProviderCatalogDiff
import dev.lorepia.app.bridge.ProviderCatalogHistory
import dev.lorepia.app.bridge.ProviderCatalogImportPlan
import dev.lorepia.app.bridge.ProviderCatalogImportReview
import dev.lorepia.app.bridge.ProviderCatalogRollbackPlan
import dev.lorepia.app.bridge.ProviderCatalogStatus

/** Maximum number of bytes the document reader may hand to Core. */
const val PROVIDER_CATALOG_MAX_DOCUMENT_BYTES: Long = 2L * 1024L * 1024L

sealed interface ProviderCatalogUiState {
    data object Loading : ProviderCatalogUiState

    data class Ready(
        val status: ProviderCatalogStatus,
        val history: ProviderCatalogHistory,
        val pendingReview: ProviderCatalogPendingReview? = null,
        val busyOperation: ProviderCatalogBusyOperation? = null,
        val notice: String? = null,
        val error: String? = null,
    ) : ProviderCatalogUiState {
        val isBusy: Boolean
            get() = busyOperation != null

        val pendingImportReview: ProviderCatalogPendingReview.Import?
            get() = pendingReview as? ProviderCatalogPendingReview.Import

        val pendingRollbackReview: ProviderCatalogPendingReview.Rollback?
            get() = pendingReview as? ProviderCatalogPendingReview.Rollback
    }

    data class Error(
        val message: String,
        val canRetry: Boolean = true,
    ) : ProviderCatalogUiState
}

enum class ProviderCatalogBusyOperation {
    Refreshing,
    PreparingImport,
    ActivatingImport,
    PreparingRollback,
    ActivatingRollback,
}

/**
 * Reader-safe projection of a prepared Core plan.
 *
 * The exact Core plan and selected import bytes stay private to the live
 * ViewModel. In particular, opaque plan JSON is never placed in Compose state.
 */
sealed interface ProviderCatalogPendingReview {
    val actionId: String
    val planSha256: String
    val expiresAt: String
    val diff: ProviderCatalogDiff

    data class Import(
        val review: ProviderCatalogImportReview,
        override val planSha256: String,
    ) : ProviderCatalogPendingReview {
        override val actionId: String
            get() = review.actionId

        override val expiresAt: String
            get() = review.expiresAt

        override val diff: ProviderCatalogDiff
            get() = review.diff
    }

    data class Rollback(
        val planSchemaVersion: UInt,
        override val actionId: String,
        val expectedStateVersion: ULong,
        override val planSha256: String,
        val fromRevision: ULong,
        val toRevision: ULong,
        val createdAt: String,
        override val expiresAt: String,
        override val diff: ProviderCatalogDiff,
    ) : ProviderCatalogPendingReview
}

fun ProviderCatalogImportPlan.toUiReview(): ProviderCatalogPendingReview.Import =
    ProviderCatalogPendingReview.Import(
        review = review,
        planSha256 = planSha256,
    )

fun ProviderCatalogRollbackPlan.toUiReview(): ProviderCatalogPendingReview.Rollback =
    ProviderCatalogPendingReview.Rollback(
        planSchemaVersion = planSchemaVersion,
        actionId = actionId,
        expectedStateVersion = expectedStateVersion,
        planSha256 = planSha256,
        fromRevision = fromRevision,
        toRevision = toRevision,
        createdAt = createdAt,
        expiresAt = expiresAt,
        diff = diff,
    )
