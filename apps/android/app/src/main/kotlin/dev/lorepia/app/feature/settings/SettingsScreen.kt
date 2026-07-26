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
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import dev.lorepia.app.R
import dev.lorepia.app.bridge.CoreHealthStatus
import dev.lorepia.app.bridge.ProviderProfile

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    uiState: SettingsUiState,
    onRefresh: () -> Unit,
    onBeginAddProfile: () -> Unit,
    onBeginEditProfile: (String) -> Unit,
    onUpdateEditor: (ProviderEditor) -> Unit,
    onCancelEditor: () -> Unit,
    onSaveProfile: () -> Unit,
    onSelectProfile: (String) -> Unit,
    onDeleteProfile: (String) -> Unit,
    onClearCredential: () -> Unit,
    onPreservePartialChanged: (Boolean) -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    var pendingDelete by remember { mutableStateOf<ProviderProfile?>(null) }
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
                    IconButton(
                        onClick = onRefresh,
                        enabled = uiState !is SettingsUiState.Loading,
                    ) {
                        Icon(
                            imageVector = Icons.Outlined.Refresh,
                            contentDescription = stringResource(R.string.refresh_status),
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
                state = uiState,
                onBeginAddProfile = onBeginAddProfile,
                onBeginEditProfile = onBeginEditProfile,
                onUpdateEditor = onUpdateEditor,
                onCancelEditor = onCancelEditor,
                onSaveProfile = onSaveProfile,
                onSelectProfile = onSelectProfile,
                onRequestDelete = { pendingDelete = it },
                onClearCredential = onClearCredential,
                onPreservePartialChanged = onPreservePartialChanged,
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

    pendingDelete?.let { profile ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(stringResource(R.string.delete_provider_title)) },
            text = {
                Text(stringResource(R.string.delete_provider_body, profile.displayName))
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDelete = null
                        onDeleteProfile(profile.id)
                    },
                ) {
                    Text(stringResource(R.string.delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

@Composable
private fun SettingsContent(
    state: SettingsUiState.Ready,
    onBeginAddProfile: () -> Unit,
    onBeginEditProfile: (String) -> Unit,
    onUpdateEditor: (ProviderEditor) -> Unit,
    onCancelEditor: () -> Unit,
    onSaveProfile: () -> Unit,
    onSelectProfile: (String) -> Unit,
    onRequestDelete: (ProviderProfile) -> Unit,
    onClearCredential: () -> Unit,
    onPreservePartialChanged: (Boolean) -> Unit,
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
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = stringResource(R.string.provider_profiles),
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.semantics { heading() },
                )
                IconButton(
                    onClick = onBeginAddProfile,
                    enabled = !state.isSaving && state.editor == null,
                ) {
                    Icon(
                        imageVector = Icons.Outlined.Add,
                        contentDescription = stringResource(R.string.add_provider),
                    )
                }
            }
        }

        if (state.profiles.isEmpty() && state.editor == null) {
            item {
                Card(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(stringResource(R.string.no_provider_profiles))
                        Button(onClick = onBeginAddProfile) {
                            Text(stringResource(R.string.add_provider))
                        }
                    }
                }
            }
        }

        state.profiles.forEach { profile ->
            item(key = profile.id) {
                ProviderCard(
                    profile = profile,
                    selected = state.settings.selectedProviderProfileId == profile.id,
                    enabled = !state.isSaving,
                    onSelect = { onSelectProfile(profile.id) },
                    onEdit = { onBeginEditProfile(profile.id) },
                    onDelete = { onRequestDelete(profile) },
                )
            }
        }

        state.editor?.let { editor ->
            item(key = "provider-editor") {
                ProviderEditorCard(
                    editor = editor,
                    enabled = !state.isSaving,
                    onChange = onUpdateEditor,
                    onSave = onSaveProfile,
                    onCancel = onCancelEditor,
                    onClearCredential = onClearCredential,
                )
            }
        }

        item {
            Card(modifier = Modifier.fillMaxWidth()) {
                Row(
                    modifier = Modifier.padding(18.dp),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            text = stringResource(R.string.preserve_partial_title),
                            style = MaterialTheme.typography.titleMedium,
                        )
                        Text(
                            text = stringResource(R.string.preserve_partial_body),
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    Switch(
                        checked = state.settings.preservePartialGenerations,
                        onCheckedChange = onPreservePartialChanged,
                        enabled = !state.isSaving,
                    )
                }
            }
        }

        state.notice?.let { notice ->
            item {
                Text(
                    text = notice,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.semantics {
                        liveRegion = LiveRegionMode.Polite
                    },
                )
            }
        }
        state.error?.let { error ->
            item {
                Text(
                    text = error,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.semantics {
                        liveRegion = LiveRegionMode.Assertive
                    },
                )
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
            HealthCard(state.health)
        }
    }
}

@Composable
private fun ProviderCard(
    profile: ProviderProfile,
    selected: Boolean,
    enabled: Boolean,
    onSelect: () -> Unit,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(14.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth(),
            ) {
                RadioButton(
                    selected = selected,
                    onClick = onSelect,
                    enabled = enabled,
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(profile.displayName, style = MaterialTheme.typography.titleMedium)
                    Text(
                        stringResource(
                            R.string.provider_model_timeout,
                            profile.model,
                            profile.timeoutSeconds.toInt(),
                        ),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                    Text(
                        profile.baseUrl,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
                IconButton(onClick = onEdit, enabled = enabled) {
                    Icon(
                        imageVector = Icons.Outlined.Edit,
                        contentDescription = stringResource(R.string.edit_provider),
                    )
                }
                IconButton(onClick = onDelete, enabled = enabled) {
                    Icon(
                        imageVector = Icons.Outlined.Delete,
                        contentDescription = stringResource(R.string.delete_provider),
                    )
                }
            }
        }
    }
}

@Composable
private fun ProviderEditorCard(
    editor: ProviderEditor,
    enabled: Boolean,
    onChange: (ProviderEditor) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
    onClearCredential: () -> Unit,
) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                text = stringResource(
                    if (editor.isExisting) R.string.edit_provider else R.string.add_provider,
                ),
                style = MaterialTheme.typography.titleMedium,
            )
            OutlinedTextField(
                value = editor.displayName,
                onValueChange = { onChange(editor.copy(displayName = it)) },
                enabled = enabled,
                label = { Text(stringResource(R.string.provider_name)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = editor.baseUrl,
                onValueChange = { onChange(editor.copy(baseUrl = it)) },
                enabled = enabled,
                label = { Text(stringResource(R.string.provider_base_url)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = editor.model,
                onValueChange = { onChange(editor.copy(model = it)) },
                enabled = enabled,
                label = { Text(stringResource(R.string.provider_model)) },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = editor.timeoutSeconds,
                onValueChange = { value ->
                    if (value.all(Char::isDigit)) {
                        onChange(editor.copy(timeoutSeconds = value))
                    }
                },
                enabled = enabled,
                label = { Text(stringResource(R.string.provider_timeout)) },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = editor.credential,
                onValueChange = { onChange(editor.copy(credential = it)) },
                enabled = enabled,
                label = { Text(stringResource(R.string.provider_credential)) },
                supportingText = {
                    Text(
                        stringResource(
                            if (editor.isExisting) {
                                R.string.credential_replace_hint
                            } else {
                                R.string.credential_keystore_hint
                            },
                        ),
                    )
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
                visualTransformation = PasswordVisualTransformation(),
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            if (editor.isExisting) {
                OutlinedButton(
                    onClick = onClearCredential,
                    enabled = enabled,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.clear_credential))
                }
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            ) {
                TextButton(onClick = onCancel, enabled = enabled) {
                    Text(stringResource(R.string.cancel))
                }
                Button(onClick = onSave, enabled = enabled) {
                    Text(stringResource(R.string.save))
                }
            }
        }
    }
}

@Composable
private fun HealthCard(health: CoreHealthStatus) {
    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(vertical = 8.dp)) {
            StatusRow(
                label = stringResource(R.string.core_status),
                value = stringResource(
                    if (health.isHealthy) R.string.core_ready else R.string.core_error,
                ),
            )
            StatusRow(stringResource(R.string.core_version), health.coreVersion)
            StatusRow(
                stringResource(R.string.database_status),
                stringResource(
                    if (health.databaseOpen) R.string.database_open else R.string.database_closed,
                ),
            )
            StatusRow(stringResource(R.string.schema_version), health.schemaVersion.toString())
            StatusRow(
                stringResource(R.string.data_root_status),
                availabilityLabel(health.dataRootWritable),
            )
            StatusRow(
                stringResource(R.string.staging_status),
                availabilityLabel(health.stagingWritable),
            )
            StatusRow(
                stringResource(R.string.recovery_pending),
                if (health.recoveryPending) "1" else "0",
            )
            StatusRow(stringResource(R.string.active_jobs), health.activeJobs.toString())
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
