package dev.lorepia.app.feature.importreview

import android.text.format.Formatter
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.lorepia.app.R
import dev.lorepia.app.bridge.ImportInspection

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ImportReviewScreen(
    uiState: ImportReviewUiState,
    onCommit: () -> Unit,
    onClose: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    val isBusy = uiState is ImportReviewUiState.Loading ||
        (uiState as? ImportReviewUiState.Ready)?.isCommitting == true
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                windowInsets = WindowInsets(0, 0, 0, 0),
                title = {
                    Text(
                        text = stringResource(R.string.import_review_title),
                        modifier = Modifier.semantics { heading() },
                    )
                },
                navigationIcon = {
                    IconButton(
                        onClick = onClose,
                        enabled = !isBusy,
                    ) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Outlined.ArrowBack,
                            contentDescription = stringResource(R.string.navigate_back),
                        )
                    }
                },
            )
        },
    ) { scaffoldPadding ->
        when (uiState) {
            is ImportReviewUiState.Loading -> Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(scaffoldPadding)
                    .padding(contentPadding),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.semantics {
                        liveRegion = LiveRegionMode.Polite
                    },
                )
            }

            is ImportReviewUiState.Ready -> ReviewContent(
                state = uiState,
                onCommit = onCommit,
                onClose = onClose,
                contentPadding = PaddingValues(
                    start = 20.dp,
                    top = scaffoldPadding.calculateTopPadding() + 12.dp,
                    end = 20.dp,
                    bottom = contentPadding.calculateBottomPadding() + 20.dp,
                ),
            )

            is ImportReviewUiState.Imported -> Unit
            is ImportReviewUiState.Error -> ReviewError(
                onClose = onClose,
                scaffoldPadding = scaffoldPadding,
                contentPadding = contentPadding,
            )
        }
    }
}

@Composable
private fun ReviewContent(
    state: ImportReviewUiState.Ready,
    onCommit: () -> Unit,
    onClose: () -> Unit,
    contentPadding: PaddingValues,
) {
    val context = LocalContext.current
    val inspection = state.inspection
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = contentPadding,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Text(
                text = stringResource(R.string.not_saved_yet),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
        }
        item {
            Text(
                text = inspection.description.ifBlank {
                    stringResource(R.string.review_explanation)
                },
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        item {
            InspectionMetadata(
                inspection = inspection,
                stagedFileSize = state.document.sizeBytes,
                formatBytes = { bytes -> Formatter.formatShortFileSize(context, bytes) },
            )
        }
        item {
            Text(
                text = stringResource(R.string.warnings_title),
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
        }
        if (inspection.warnings.isEmpty() && inspection.blockedReasons.isEmpty()) {
            item {
                Text(
                    text = stringResource(R.string.no_warnings),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        } else {
            items(
                items = inspection.warnings,
            ) { warning ->
                WarningCard(message = warning, blocksImport = false)
            }
            items(
                items = inspection.blockedReasons,
            ) { reason ->
                WarningCard(message = reason, blocksImport = true)
            }
        }
        if (inspection.isBlocked) {
            item {
                Text(
                    text = stringResource(R.string.blocked_import),
                    color = MaterialTheme.colorScheme.error,
                    fontWeight = FontWeight.Bold,
                )
            }
        }
        if (state.commitError != null) {
            item {
                Text(
                    text = stringResource(R.string.import_failed),
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.semantics {
                        liveRegion = LiveRegionMode.Assertive
                    },
                )
            }
        }
        item {
            Button(
                onClick = onCommit,
                enabled = !inspection.isBlocked && !state.isCommitting,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (state.isCommitting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        color = MaterialTheme.colorScheme.onPrimary,
                        strokeWidth = 2.dp,
                    )
                    Text(
                        text = stringResource(R.string.importing),
                        modifier = Modifier.padding(start = 8.dp),
                    )
                } else {
                    Text(stringResource(R.string.confirm_import))
                }
            }
        }
        item {
            Button(
                onClick = onClose,
                enabled = !state.isCommitting,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(stringResource(R.string.finish_review))
            }
        }
    }
}

@Composable
private fun InspectionMetadata(
    inspection: ImportInspection,
    stagedFileSize: Long,
    formatBytes: (Long) -> String,
) {
    val sourceSize = if (inspection.sourceSize > Long.MAX_VALUE.toULong()) {
        Long.MAX_VALUE
    } else {
        inspection.sourceSize.toLong()
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            MetadataRow(
                label = stringResource(R.string.character_name),
                value = inspection.displayName,
            )
            MetadataRow(
                label = stringResource(R.string.content_kind),
                value = inspection.contentKind,
            )
            MetadataRow(
                label = stringResource(R.string.file_size),
                value = formatBytes(if (sourceSize > 0) sourceSize else stagedFileSize),
            )
            MetadataRow(
                label = stringResource(R.string.asset_count),
                value = inspection.assetCount.toString(),
            )
            MetadataRow(
                label = stringResource(R.string.source_hash),
                value = inspection.sourceSha256,
            )
        }
    }
}

@Composable
private fun MetadataRow(
    label: String,
    value: String,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.Top,
    ) {
        Text(
            text = label,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Text(
            text = value,
            fontWeight = FontWeight.Medium,
            modifier = Modifier
                .padding(start = 16.dp)
                .weight(1f, fill = false),
        )
    }
}

@Composable
private fun WarningCard(
    message: String,
    blocksImport: Boolean,
) {
    val contentColor = if (blocksImport) {
        MaterialTheme.colorScheme.error
    } else {
        MaterialTheme.colorScheme.onSurface
    }
    Card(modifier = Modifier.fillMaxWidth()) {
        Row(
            modifier = Modifier.padding(16.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                imageVector = Icons.Outlined.WarningAmber,
                contentDescription = null,
                tint = contentColor,
            )
            Text(
                text = message,
                color = contentColor,
            )
        }
    }
}

@Composable
private fun ReviewError(
    onClose: () -> Unit,
    scaffoldPadding: PaddingValues,
    contentPadding: PaddingValues,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(scaffoldPadding)
            .padding(contentPadding)
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = stringResource(R.string.staging_failed),
            color = MaterialTheme.colorScheme.error,
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.semantics { heading() },
        )
        Button(
            onClick = onClose,
            modifier = Modifier.padding(top = 16.dp),
        ) {
            Text(stringResource(R.string.finish_review))
        }
    }
}
