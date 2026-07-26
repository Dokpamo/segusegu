package dev.lorepia.app.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import dev.lorepia.app.R
import dev.lorepia.app.bridge.CoreHealthStatus

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    uiState: SettingsUiState,
    onRefresh: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                windowInsets = WindowInsets(0, 0, 0, 0),
                title = {
                    Text(
                        text = stringResource(R.string.settings_title),
                        modifier = Modifier.semantics { heading() },
                    )
                },
                actions = {
                    TextButton(
                        onClick = onRefresh,
                        enabled = uiState !is SettingsUiState.Loading,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Refresh,
                            contentDescription = null,
                        )
                        Text(
                            text = stringResource(R.string.refresh_status),
                            modifier = Modifier.padding(start = 8.dp),
                        )
                    }
                },
            )
        },
    ) { scaffoldPadding ->
        when (uiState) {
            SettingsUiState.Loading -> Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(scaffoldPadding)
                    .padding(contentPadding),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                CircularProgressIndicator()
            }

            is SettingsUiState.Ready -> SettingsContent(
                health = uiState.health,
                padding = PaddingValues(
                    start = 20.dp,
                    top = scaffoldPadding.calculateTopPadding() + 12.dp,
                    end = 20.dp,
                    bottom = contentPadding.calculateBottomPadding() + 20.dp,
                ),
            )

            is SettingsUiState.Error -> SettingsError(
                onRefresh = onRefresh,
                padding = PaddingValues(
                    start = 24.dp,
                    top = scaffoldPadding.calculateTopPadding(),
                    end = 24.dp,
                    bottom = contentPadding.calculateBottomPadding(),
                ),
            )
        }
    }
}

@Composable
private fun SettingsContent(
    health: CoreHealthStatus,
    padding: PaddingValues,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = padding,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = stringResource(R.string.settings_local_first_title),
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.semantics { heading() },
                    )
                    Text(
                        text = stringResource(R.string.settings_local_first_body),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        item {
            Text(
                text = stringResource(R.string.core_status),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
        }

        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(vertical = 8.dp)) {
                    StatusRow(
                        label = stringResource(R.string.core_status),
                        value = stringResource(
                            if (health.isHealthy) R.string.core_ready else R.string.core_error,
                        ),
                    )
                    StatusRow(
                        label = stringResource(R.string.core_version),
                        value = health.coreVersion,
                    )
                    StatusRow(
                        label = stringResource(R.string.database_status),
                        value = stringResource(
                            if (health.databaseOpen) {
                                R.string.database_open
                            } else {
                                R.string.database_closed
                            },
                        ),
                    )
                    StatusRow(
                        label = stringResource(R.string.schema_version),
                        value = health.schemaVersion.toString(),
                    )
                    StatusRow(
                        label = stringResource(R.string.data_root_status),
                        value = availabilityLabel(health.dataRootWritable),
                    )
                    StatusRow(
                        label = stringResource(R.string.staging_status),
                        value = availabilityLabel(health.stagingWritable),
                    )
                    StatusRow(
                        label = stringResource(R.string.recovery_pending),
                        value = if (health.recoveryPending) "1" else "0",
                    )
                    StatusRow(
                        label = stringResource(R.string.active_jobs),
                        value = health.activeJobs.toString(),
                    )
                }
            }
        }
    }
}

@Composable
private fun availabilityLabel(available: Boolean): String =
    stringResource(if (available) R.string.available else R.string.unavailable)

@Composable
private fun StatusRow(
    label: String,
    value: String,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 20.dp, vertical = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            text = label,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.weight(1f),
        )
        Text(
            text = value,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(start = 16.dp),
        )
    }
}

@Composable
private fun SettingsError(
    onRefresh: () -> Unit,
    padding: PaddingValues,
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(padding),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = stringResource(R.string.core_unavailable_title),
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.semantics { heading() },
        )
        TextButton(onClick = onRefresh) {
            Text(stringResource(R.string.retry))
        }
    }
}
