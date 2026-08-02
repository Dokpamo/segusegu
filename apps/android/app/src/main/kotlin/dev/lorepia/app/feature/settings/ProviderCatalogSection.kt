package dev.lorepia.app.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.lorepia.app.bridge.ProviderCatalogActivation
import dev.lorepia.app.bridge.ProviderCatalogDiff
import dev.lorepia.app.bridge.ProviderCatalogHistory
import dev.lorepia.app.bridge.ProviderCatalogManifestChange
import dev.lorepia.app.bridge.ProviderCatalogModelChange
import dev.lorepia.app.bridge.ProviderCatalogRevision
import dev.lorepia.app.bridge.ProviderCatalogStatus

/**
 * Renders signed provider catalog state and review-only mutation controls.
 *
 * Document reading and exact plan ownership belong to the caller. This
 * component only requests a document and returns approval or cancellation
 * intent for an already-prepared typed review.
 */
@Composable
fun ProviderCatalogSection(
    state: ProviderCatalogUiState,
    onRefresh: () -> Unit,
    onChooseSignedCatalogDocument: () -> Unit,
    onActivateImport: () -> Unit,
    onCancelImport: () -> Unit,
    onPrepareRollback: (ULong) -> Unit,
    onActivateRollback: () -> Unit,
    onCancelRollback: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .testTag("provider-catalog-section"),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainer,
        ),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            CatalogHeading(
                state = state,
                onRefresh = onRefresh,
            )
            when (state) {
                ProviderCatalogUiState.Loading -> CatalogLoading()
                is ProviderCatalogUiState.Error -> CatalogError(
                    state = state,
                    onRefresh = onRefresh,
                )

                is ProviderCatalogUiState.Ready -> CatalogReady(
                    state = state,
                    onChooseSignedCatalogDocument = onChooseSignedCatalogDocument,
                    onActivateImport = onActivateImport,
                    onCancelImport = onCancelImport,
                    onPrepareRollback = onPrepareRollback,
                    onActivateRollback = onActivateRollback,
                    onCancelRollback = onCancelRollback,
                )
            }
        }
    }
}

@Composable
private fun CatalogHeading(
    state: ProviderCatalogUiState,
    onRefresh: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = "Provider catalog",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = "서명된 provider와 model 메타데이터를 기기에서 검토하고 적용합니다.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        TextButton(
            onClick = onRefresh,
            enabled = when (state) {
                ProviderCatalogUiState.Loading -> false
                is ProviderCatalogUiState.Error -> state.canRetry
                is ProviderCatalogUiState.Ready -> !state.isBusy
            },
            modifier = Modifier.testTag("provider-catalog-refresh"),
        ) {
            Text("새로고침")
        }
    }
}

@Composable
private fun CatalogLoading() {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-loading"),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        CircularProgressIndicator()
        Text("서명 catalog 현황과 이력을 불러오는 중입니다.")
    }
}

@Composable
private fun CatalogError(
    state: ProviderCatalogUiState.Error,
    onRefresh: () -> Unit,
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-error"),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = state.message,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.semantics {
                    liveRegion = LiveRegionMode.Assertive
                },
            )
            if (state.canRetry) {
                OutlinedButton(
                    onClick = onRefresh,
                    modifier = Modifier.testTag("provider-catalog-retry"),
                ) {
                    Text("다시 시도")
                }
            }
        }
    }
}

@Composable
private fun CatalogReady(
    state: ProviderCatalogUiState.Ready,
    onChooseSignedCatalogDocument: () -> Unit,
    onActivateImport: () -> Unit,
    onCancelImport: () -> Unit,
    onPrepareRollback: (ULong) -> Unit,
    onActivateRollback: () -> Unit,
    onCancelRollback: () -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-ready"),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        if (state.isBusy) {
            LinearProgressIndicator(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("provider-catalog-busy"),
            )
            Text(
                text = state.busyOperation.displayLabel(),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        CatalogStatusCard(state.status)

        when (val review = state.pendingReview) {
            is ProviderCatalogPendingReview.Import -> ImportReviewCard(
                review = review,
                enabled = !state.isBusy,
                onActivate = onActivateImport,
                onCancel = onCancelImport,
            )

            is ProviderCatalogPendingReview.Rollback -> RollbackReviewCard(
                review = review,
                enabled = !state.isBusy,
                onActivate = onActivateRollback,
                onCancel = onCancelRollback,
            )

            null -> SignedCatalogImportCard(
                enabled = !state.isBusy,
                onChooseDocument = onChooseSignedCatalogDocument,
            )
        }

        CatalogHistoryCard(
            history = state.history,
            actionsEnabled = !state.isBusy && state.pendingReview == null,
            onPrepareRollback = onPrepareRollback,
        )

        state.notice?.let { notice ->
            Text(
                text = notice,
                color = MaterialTheme.colorScheme.primary,
                modifier = Modifier
                    .semantics { liveRegion = LiveRegionMode.Polite }
                    .testTag("provider-catalog-notice"),
            )
        }
        state.error?.let { error ->
            Text(
                text = error,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .semantics { liveRegion = LiveRegionMode.Assertive }
                    .testTag("provider-catalog-ready-error"),
            )
        }
    }
}

@Composable
private fun CatalogStatusCard(status: ProviderCatalogStatus) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-status"),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(7.dp),
        ) {
            Text(
                text = "현재 catalog",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            CatalogFact("활성 revision", status.activeRevision.toString())
            CatalogFact("상태 version", status.stateVersion.toString())
            CatalogFact("활성 snapshot SHA-256", status.activeSnapshotSha256, monospace = true)
            CatalogFact(
                "Bundled baseline SHA-256",
                status.bundledBaselineSha256,
                monospace = true,
            )
            CatalogFact("저장된 snapshot", status.snapshotCount.toString())
            CatalogFact("수락한 서명 update", status.signedUpdateCount.toString())
            CatalogFact(
                "최고 수락 signed revision",
                status.highestAcceptedRevision.toString(),
            )
            CatalogFact("최근 발행 시각", status.latestIssuedAt ?: "없음")
            CatalogFact(
                "활성 signed revision",
                status.activeSignedRevisions.joinToString()
                    .ifEmpty { "없음" },
            )
            Text(
                text = "Status schema v${status.statusSchemaVersion}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SignedCatalogImportCard(
    enabled: Boolean,
    onChooseDocument: () -> Unit,
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-import"),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = "서명 catalog 가져오기",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = "선택한 문서는 먼저 서명, revision, hash와 변경 사항을 검증합니다. " +
                    "검토 후 승인하기 전에는 활성 catalog가 바뀌지 않습니다.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(
                text = "최대 ${PROVIDER_CATALOG_MAX_DOCUMENT_BYTES / (1024L * 1024L)} MiB",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Button(
                onClick = onChooseDocument,
                enabled = enabled,
                modifier = Modifier.testTag("provider-catalog-choose-document"),
            ) {
                Text("서명 문서 선택")
            }
        }
    }
}

@Composable
private fun ImportReviewCard(
    review: ProviderCatalogPendingReview.Import,
    enabled: Boolean,
    onActivate: () -> Unit,
    onCancel: () -> Unit,
) {
    val details = review.review
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-import-review"),
        colors = CardDefaults.outlinedCardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer,
        ),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(
                text = "서명 catalog 적용 검토",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            CatalogFact("Action ID", details.actionId, monospace = true)
            CatalogFact("Plan SHA-256", review.planSha256, monospace = true)
            CatalogFact("Signing key", details.signingKeyId, monospace = true)
            CatalogFact("Signed catalog revision", details.signedCatalogRevision.toString())
            CatalogFact("후보 revision", details.candidateRevision.toString())
            CatalogFact(
                "현재 revision",
                details.expectedActiveRevision.toString(),
            )
            CatalogFact(
                "현재 snapshot SHA-256",
                details.expectedActiveSnapshotSha256,
                monospace = true,
            )
            CatalogFact(
                "후보 snapshot SHA-256",
                details.candidateSnapshotSha256,
                monospace = true,
            )
            CatalogFact("Envelope SHA-256", details.envelopeSha256, monospace = true)
            CatalogFact("Payload SHA-256", details.payloadSha256, monospace = true)
            CatalogFact("Envelope bytes", details.envelopeByteCount.toString())
            CatalogFact(
                "예상 state version",
                details.expectedStateVersion.toString(),
            )
            CatalogFact(
                "기존 최고 signed revision",
                details.expectedHighestAcceptedRevision.toString(),
            )
            CatalogFact("준비 시각", details.preparedAt)
            CatalogFact("만료 시각", details.expiresAt)
            Text(
                text = "Plan schema v${details.planSchemaVersion}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            HorizontalDivider()
            CatalogDiffReview(
                diff = details.diff,
                tagPrefix = "provider-catalog-import-diff",
            )
            CatalogReviewActions(
                enabled = enabled,
                activateLabel = "이 변경 적용",
                activateTag = "provider-catalog-import-activate",
                cancelTag = "provider-catalog-import-cancel",
                onActivate = onActivate,
                onCancel = onCancel,
            )
        }
    }
}

@Composable
private fun RollbackReviewCard(
    review: ProviderCatalogPendingReview.Rollback,
    enabled: Boolean,
    onActivate: () -> Unit,
    onCancel: () -> Unit,
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-rollback-review"),
        colors = CardDefaults.outlinedCardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer,
        ),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(
                text = "Catalog rollback 검토",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = "아래 변경으로 활성 catalog를 되돌립니다. 현재 연결이나 API 키는 " +
                    "이 작업에 포함되지 않습니다.",
                color = MaterialTheme.colorScheme.onErrorContainer,
            )
            CatalogFact("Action ID", review.actionId, monospace = true)
            CatalogFact("Plan SHA-256", review.planSha256, monospace = true)
            CatalogFact("현재 revision", review.fromRevision.toString())
            CatalogFact("대상 revision", review.toRevision.toString())
            CatalogFact("예상 state version", review.expectedStateVersion.toString())
            CatalogFact("준비 시각", review.createdAt)
            CatalogFact("만료 시각", review.expiresAt)
            Text(
                text = "Plan schema v${review.planSchemaVersion}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            HorizontalDivider()
            CatalogDiffReview(
                diff = review.diff,
                tagPrefix = "provider-catalog-rollback-diff",
            )
            CatalogReviewActions(
                enabled = enabled,
                activateLabel = "이 revision으로 되돌리기",
                activateTag = "provider-catalog-rollback-activate",
                cancelTag = "provider-catalog-rollback-cancel",
                onActivate = onActivate,
                onCancel = onCancel,
            )
        }
    }
}

@Composable
private fun CatalogReviewActions(
    enabled: Boolean,
    activateLabel: String,
    activateTag: String,
    cancelTag: String,
    onActivate: () -> Unit,
    onCancel: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(
            onClick = onCancel,
            enabled = enabled,
            modifier = Modifier.testTag(cancelTag),
        ) {
            Text("취소")
        }
        Button(
            onClick = onActivate,
            enabled = enabled,
            modifier = Modifier.testTag(activateTag),
        ) {
            Text(activateLabel)
        }
    }
}

@Composable
private fun CatalogHistoryCard(
    history: ProviderCatalogHistory,
    actionsEnabled: Boolean,
    onPrepareRollback: (ULong) -> Unit,
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-history"),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                text = "Catalog 이력",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            Text(
                text = "활성 revision ${history.activeRevision}",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (history.revisions.isEmpty()) {
                Text(
                    text = "저장된 revision 이력이 없습니다.",
                    modifier = Modifier.testTag("provider-catalog-history-empty"),
                )
            } else {
                history.revisions.forEachIndexed { index, revision ->
                    if (index > 0) HorizontalDivider()
                    CatalogRevisionRow(
                        revision = revision,
                        activeRevision = history.activeRevision,
                        actionsEnabled = actionsEnabled,
                        onPrepareRollback = onPrepareRollback,
                    )
                }
            }

            HorizontalDivider()
            Text(
                text = "적용 기록",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
            )
            if (history.activations.isEmpty()) {
                Text(
                    text = "적용 기록이 없습니다.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("provider-catalog-activations-empty"),
                )
            } else {
                history.activations.forEachIndexed { index, activation ->
                    if (index > 0) HorizontalDivider()
                    CatalogActivationRow(
                        activation = activation,
                        index = index,
                    )
                }
            }
            if (history.nextBeforeRevision != null ||
                history.nextBeforeStateVersion != null
            ) {
                Text(
                    text = "이전 이력이 더 있습니다.",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("provider-catalog-history-has-more"),
                )
            }
            Text(
                text = "History schema v${history.historySchemaVersion}",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun CatalogRevisionRow(
    revision: ProviderCatalogRevision,
    activeRevision: ULong,
    actionsEnabled: Boolean,
    onPrepareRollback: (ULong) -> Unit,
) {
    val isActive = revision.active || revision.revision == activeRevision
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-revision-${revision.revision}"),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Revision ${revision.revision}${if (isActive) " · 활성" else ""}",
                fontWeight = FontWeight.SemiBold,
            )
            if (!isActive) {
                OutlinedButton(
                    onClick = { onPrepareRollback(revision.revision) },
                    enabled = actionsEnabled,
                    modifier = Modifier.testTag(
                        "provider-catalog-prepare-rollback-${revision.revision}",
                    ),
                ) {
                    Text("Rollback 검토")
                }
            }
        }
        CatalogFact("저장 시각", revision.capturedAt)
        CatalogFact("Snapshot SHA-256", revision.snapshotSha256, monospace = true)
        CatalogFact(
            "Signed revisions",
            revision.signedRevisions.joinToString().ifEmpty { "없음" },
        )
    }
}

@Composable
private fun CatalogActivationRow(
    activation: ProviderCatalogActivation,
    index: Int,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-catalog-activation-$index"),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(
            text = "${activation.kind}: " +
                "${activation.fromRevision?.toString() ?: "없음"} → ${activation.toRevision}",
            fontWeight = FontWeight.SemiBold,
        )
        CatalogFact("적용 시각", activation.activatedAt)
        CatalogFact("Action ID", activation.actionId, monospace = true)
        CatalogFact("적용 state version", activation.stateVersion.toString())
        CatalogDiffCounts(activation.diff)
    }
}

@Composable
private fun CatalogDiffReview(
    diff: ProviderCatalogDiff,
    tagPrefix: String,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tagPrefix),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            text = "변경 사항 · revision ${diff.fromRevision} → ${diff.toRevision}",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = "Diff schema v${diff.diffSchemaVersion}",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        ManifestChangeBucket(
            title = "추가 provider template",
            changes = diff.addedProviderTemplates,
            tag = "$tagPrefix-added-provider-templates",
        )
        ManifestChangeBucket(
            title = "변경 provider template",
            changes = diff.changedProviderTemplates,
            tag = "$tagPrefix-changed-provider-templates",
        )
        ManifestChangeBucket(
            title = "제거 provider template",
            changes = diff.removedProviderTemplates,
            tag = "$tagPrefix-removed-provider-templates",
        )
        ModelChangeBucket(
            title = "추가 model",
            changes = diff.addedModels,
            tag = "$tagPrefix-added-models",
        )
        ModelChangeBucket(
            title = "변경 model",
            changes = diff.changedModels,
            tag = "$tagPrefix-changed-models",
        )
        ModelChangeBucket(
            title = "제거 model",
            changes = diff.removedModels,
            tag = "$tagPrefix-removed-models",
        )
    }
}

@Composable
private fun ManifestChangeBucket(
    title: String,
    changes: List<ProviderCatalogManifestChange>,
    tag: String,
) {
    CatalogChangeBucket(
        title = title,
        count = changes.size,
        tag = tag,
    ) {
        changes.forEachIndexed { index, change ->
            CatalogChangeItem(
                title = change.providerTemplateId,
                versionLabel = "Manifest version",
                previousVersion = change.previousManifestVersion?.toString(),
                nextVersion = change.nextManifestVersion?.toString(),
                previousSha256 = change.previousSha256,
                nextSha256 = change.nextSha256,
                changedSections = change.changedSections,
                tag = "$tag-item-$index",
            )
        }
    }
}

@Composable
private fun ModelChangeBucket(
    title: String,
    changes: List<ProviderCatalogModelChange>,
    tag: String,
) {
    CatalogChangeBucket(
        title = title,
        count = changes.size,
        tag = tag,
    ) {
        changes.forEachIndexed { index, change ->
            CatalogChangeItem(
                title = change.modelEntryId,
                subtitle = "Provider template: ${change.providerTemplateId}",
                versionLabel = "Metadata version",
                previousVersion = change.previousMetadataVersion?.toString(),
                nextVersion = change.nextMetadataVersion?.toString(),
                previousSha256 = change.previousSha256,
                nextSha256 = change.nextSha256,
                changedSections = change.changedSections,
                tag = "$tag-item-$index",
            )
        }
    }
}

@Composable
private fun CatalogChangeBucket(
    title: String,
    count: Int,
    tag: String,
    content: @Composable () -> Unit,
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(
                text = "$title ($count)",
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
            )
            if (count == 0) {
                Text(
                    text = "없음",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                content()
            }
        }
    }
}

@Composable
private fun CatalogChangeItem(
    title: String,
    versionLabel: String,
    previousVersion: String?,
    nextVersion: String?,
    previousSha256: String?,
    nextSha256: String?,
    changedSections: List<String>,
    tag: String,
    subtitle: String? = null,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            text = title,
            fontWeight = FontWeight.SemiBold,
        )
        subtitle?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        CatalogFact(
            versionLabel,
            "${previousVersion ?: "없음"} → ${nextVersion ?: "없음"}",
        )
        CatalogFact(
            "SHA-256",
            "${previousSha256 ?: "없음"} → ${nextSha256 ?: "없음"}",
            monospace = true,
        )
        CatalogFact(
            "변경 section",
            changedSections.joinToString().ifEmpty { "없음" },
        )
    }
}

@Composable
private fun CatalogDiffCounts(diff: ProviderCatalogDiff) {
    Text(
        text = "Provider +${diff.addedProviderTemplates.size} " +
            "~${diff.changedProviderTemplates.size} -${diff.removedProviderTemplates.size} · " +
            "Model +${diff.addedModels.size} " +
            "~${diff.changedModels.size} -${diff.removedModels.size}",
        style = MaterialTheme.typography.bodySmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun CatalogFact(
    label: String,
    value: String,
    monospace: Boolean = false,
) {
    Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value,
            style = MaterialTheme.typography.bodySmall.copy(
                fontFamily = if (monospace) FontFamily.Monospace else FontFamily.Default,
            ),
        )
    }
}

private fun ProviderCatalogBusyOperation?.displayLabel(): String = when (this) {
    ProviderCatalogBusyOperation.Refreshing -> "Catalog 현황과 이력을 새로 고치는 중입니다."
    ProviderCatalogBusyOperation.PreparingImport -> "서명 문서를 검증하고 변경 계획을 준비하는 중입니다."
    ProviderCatalogBusyOperation.ActivatingImport -> "검토한 서명 catalog를 적용하는 중입니다."
    ProviderCatalogBusyOperation.PreparingRollback -> "Rollback 변경 계획을 준비하는 중입니다."
    ProviderCatalogBusyOperation.ActivatingRollback -> "검토한 revision을 활성화하는 중입니다."
    null -> ""
}
