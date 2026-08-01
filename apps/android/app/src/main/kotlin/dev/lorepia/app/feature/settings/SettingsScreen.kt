package dev.lorepia.app.feature.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
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
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.progressBarRangeInfo
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import dev.lorepia.app.R
import dev.lorepia.app.bridge.CapabilityObservation
import dev.lorepia.app.bridge.ConnectionFieldSpec
import dev.lorepia.app.bridge.ConnectionFieldType
import dev.lorepia.app.bridge.CoreHealthStatus
import dev.lorepia.app.bridge.DiscoveryActionRequired
import dev.lorepia.app.bridge.DiscoveryApprovalGrant
import dev.lorepia.app.bridge.DiscoveryAssistantConfidenceLevel
import dev.lorepia.app.bridge.DiscoveryAssistantConflictDisposition
import dev.lorepia.app.bridge.DiscoveryAssistantDraftField
import dev.lorepia.app.bridge.DiscoveryAssistantOutcome
import dev.lorepia.app.bridge.DiscoveryAssistantResumeAction
import dev.lorepia.app.bridge.DiscoveryCandidateSummary
import dev.lorepia.app.bridge.DiscoveryProbeBudget
import dev.lorepia.app.bridge.DiscoveryUnknownOutcomeResolution
import dev.lorepia.app.bridge.GenerationPreset
import dev.lorepia.app.bridge.ParameterLiteral
import dev.lorepia.app.bridge.ParameterSpec
import dev.lorepia.app.bridge.ParameterType
import dev.lorepia.app.bridge.ProviderConnection
import dev.lorepia.app.bridge.ProviderNetworkMode
import dev.lorepia.app.bridge.ProviderTemplate
import dev.lorepia.app.bridge.ToolPolicy
import dev.lorepia.app.bridge.UiParameterLevel
import dev.lorepia.app.platform.credentials.CredentialRecordStatus
import java.math.BigInteger

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    uiState: SettingsUiState,
    onRefresh: () -> Unit,
    onBeginAddConnection: () -> Unit,
    onChooseSetupKind: (ProviderSetupKind) -> Unit,
    onChooseKnownTemplate: (String) -> Unit,
    onUpdateSetup: (ProviderSetupState) -> Unit,
    onSubmitSetupDetails: (String, String) -> Unit,
    onDiscoveryAction: (ProviderDiscoveryUiAction) -> Unit,
    onCatalogAction: (ProviderCatalogUiAction) -> Unit,
    onApproveCredentialOrigin: () -> Unit,
    onCommitSetup: () -> Unit,
    onCancelSetup: () -> Unit,
    onRetrySetup: () -> Unit,
    onBeginEditConnection: (String) -> Unit,
    onUpdateConnectionEditor: (ConnectionEditor) -> Unit,
    onCancelConnectionEditor: () -> Unit,
    onSaveConnectionEditor: (String) -> Unit,
    onDeleteConnection: (String) -> Unit,
    onStartModelSync: (String) -> Unit,
    onApproveModelSync: (String, String) -> Unit,
    onCancelModelSync: (String) -> Unit,
    onDismissModelSync: () -> Unit,
    onSelectGenerationPreset: (String, String) -> Unit,
    onBeginAddPreset: (String) -> Unit,
    onBeginEditPreset: (String) -> Unit,
    onUpdatePresetEditor: (PresetEditor) -> Unit,
    onCancelPresetEditor: () -> Unit,
    onSavePreset: () -> Unit,
    onDeletePreset: (String) -> Unit,
    onPreservePartialChanged: (Boolean) -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    var pendingConnectionDelete by remember { mutableStateOf<ProviderConnection?>(null) }
    var pendingPresetDelete by remember { mutableStateOf<GenerationPreset?>(null) }
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
                        enabled = uiState !is SettingsUiState.Loading &&
                            (uiState as? SettingsUiState.Ready)?.isBusy != true,
                        modifier = Modifier.testTag("settings-refresh"),
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
            SettingsUiState.Loading -> LoadingContent(scaffoldPadding, contentPadding)
            is SettingsUiState.Error -> SettingsError(
                onRefresh = onRefresh,
                padding = PaddingValues(
                    start = 24.dp,
                    top = scaffoldPadding.calculateTopPadding(),
                    end = 24.dp,
                    bottom = contentPadding.calculateBottomPadding(),
                ),
            )

            is SettingsUiState.Ready -> SettingsContent(
                state = uiState,
                onBeginAddConnection = onBeginAddConnection,
                onChooseSetupKind = onChooseSetupKind,
                onChooseKnownTemplate = onChooseKnownTemplate,
                onUpdateSetup = onUpdateSetup,
                onSubmitSetupDetails = onSubmitSetupDetails,
                onDiscoveryAction = onDiscoveryAction,
                onCatalogAction = onCatalogAction,
                onApproveCredentialOrigin = onApproveCredentialOrigin,
                onCommitSetup = onCommitSetup,
                onCancelSetup = onCancelSetup,
                onRetrySetup = onRetrySetup,
                onBeginEditConnection = onBeginEditConnection,
                onUpdateConnectionEditor = onUpdateConnectionEditor,
                onCancelConnectionEditor = onCancelConnectionEditor,
                onSaveConnectionEditor = onSaveConnectionEditor,
                onRequestDeleteConnection = { pendingConnectionDelete = it },
                onStartModelSync = onStartModelSync,
                onApproveModelSync = onApproveModelSync,
                onCancelModelSync = onCancelModelSync,
                onDismissModelSync = onDismissModelSync,
                onSelectGenerationPreset = onSelectGenerationPreset,
                onBeginAddPreset = onBeginAddPreset,
                onBeginEditPreset = onBeginEditPreset,
                onUpdatePresetEditor = onUpdatePresetEditor,
                onCancelPresetEditor = onCancelPresetEditor,
                onSavePreset = onSavePreset,
                onRequestDeletePreset = { pendingPresetDelete = it },
                onPreservePartialChanged = onPreservePartialChanged,
                padding = PaddingValues(
                    start = 20.dp,
                    top = scaffoldPadding.calculateTopPadding() + 12.dp,
                    end = 20.dp,
                    bottom = contentPadding.calculateBottomPadding() + 20.dp,
                ),
            )
        }
    }

    pendingConnectionDelete?.let { connection ->
        AlertDialog(
            onDismissRequest = { pendingConnectionDelete = null },
            title = { Text("AI 연결을 삭제할까요?") },
            text = {
                Text(
                    "${connection.displayName}의 route, preset, capability 근거와 " +
                        "Android Keystore 자격증명을 함께 삭제합니다.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingConnectionDelete = null
                        onDeleteConnection(connection.id)
                    },
                    modifier = Modifier.testTag("confirm-delete-connection"),
                ) {
                    Text(stringResource(R.string.delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingConnectionDelete = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    pendingPresetDelete?.let { preset ->
        AlertDialog(
            onDismissRequest = { pendingPresetDelete = null },
            title = { Text("Preset을 삭제할까요?") },
            text = { Text("${preset.displayName} 설정을 삭제합니다.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingPresetDelete = null
                        onDeletePreset(preset.id)
                    },
                    modifier = Modifier.testTag("confirm-delete-preset"),
                ) {
                    Text(stringResource(R.string.delete))
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingPresetDelete = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

@Composable
private fun LoadingContent(
    scaffoldPadding: PaddingValues,
    contentPadding: PaddingValues,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(scaffoldPadding)
            .padding(contentPadding)
            .testTag("settings-loading"),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun SettingsContent(
    state: SettingsUiState.Ready,
    onBeginAddConnection: () -> Unit,
    onChooseSetupKind: (ProviderSetupKind) -> Unit,
    onChooseKnownTemplate: (String) -> Unit,
    onUpdateSetup: (ProviderSetupState) -> Unit,
    onSubmitSetupDetails: (String, String) -> Unit,
    onDiscoveryAction: (ProviderDiscoveryUiAction) -> Unit,
    onCatalogAction: (ProviderCatalogUiAction) -> Unit,
    onApproveCredentialOrigin: () -> Unit,
    onCommitSetup: () -> Unit,
    onCancelSetup: () -> Unit,
    onRetrySetup: () -> Unit,
    onBeginEditConnection: (String) -> Unit,
    onUpdateConnectionEditor: (ConnectionEditor) -> Unit,
    onCancelConnectionEditor: () -> Unit,
    onSaveConnectionEditor: (String) -> Unit,
    onRequestDeleteConnection: (ProviderConnection) -> Unit,
    onStartModelSync: (String) -> Unit,
    onApproveModelSync: (String, String) -> Unit,
    onCancelModelSync: (String) -> Unit,
    onDismissModelSync: () -> Unit,
    onSelectGenerationPreset: (String, String) -> Unit,
    onBeginAddPreset: (String) -> Unit,
    onBeginEditPreset: (String) -> Unit,
    onUpdatePresetEditor: (PresetEditor) -> Unit,
    onCancelPresetEditor: () -> Unit,
    onSavePreset: () -> Unit,
    onRequestDeletePreset: (GenerationPreset) -> Unit,
    onPreservePartialChanged: (Boolean) -> Unit,
    padding: PaddingValues,
) {
    LazyColumn(
        modifier = Modifier
            .fillMaxSize()
            .testTag("settings-content"),
        contentPadding = padding,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        if (state.isBusy) {
            item(key = "busy") {
                LinearProgressIndicator(
                    modifier = Modifier
                        .fillMaxWidth()
                        .semantics {
                            contentDescription = "설정 변경 진행 중"
                        }
                        .testTag("settings-busy"),
                )
            }
        }

        item(key = "local-first") {
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
                    Text(
                        text = "API 키는 Android Keystore에만 보관하며, 승인한 API origin " +
                            "외에는 전송하지 않습니다.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        item(key = "connection-heading") {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "AI 연결",
                    style = MaterialTheme.typography.titleLarge,
                    modifier = Modifier.semantics { heading() },
                )
                IconButton(
                    onClick = onBeginAddConnection,
                    enabled = !state.isBusy &&
                        state.setup == null &&
                        state.connectionEditor == null &&
                        state.presetEditor == null,
                    modifier = Modifier.testTag("add-provider-connection"),
                ) {
                    Icon(Icons.Outlined.Add, contentDescription = "새 AI 연결")
                }
            }
        }

        state.setup?.let { setup ->
            item(key = "provider-setup") {
                ProviderSetupCard(
                    setup = setup,
                    templates = state.templates,
                    assistantTarget = state.activeSetupAssistantTarget(),
                    enabled = !state.isBusy,
                    onChooseKind = onChooseSetupKind,
                    onChooseTemplate = onChooseKnownTemplate,
                    onChange = onUpdateSetup,
                    onContinue = onSubmitSetupDetails,
                    onDiscoveryAction = onDiscoveryAction,
                    onApproveOrigin = onApproveCredentialOrigin,
                    onCommit = onCommitSetup,
                    onCancel = onCancelSetup,
                    onRetry = onRetrySetup,
                )
            }
        }

        state.connectionEditor?.let { editor ->
            item(key = "connection-editor") {
                val details = state.connections.firstOrNull {
                    it.connection.id == editor.original.id
                }
                ConnectionEditorCard(
                    editor = editor,
                    template = details?.template,
                    enabled = !state.isBusy,
                    onChange = onUpdateConnectionEditor,
                    onSave = onSaveConnectionEditor,
                    onCancel = onCancelConnectionEditor,
                )
            }
        }

        if (state.connections.isEmpty() && state.setup == null) {
            item(key = "empty-connections") {
                OutlinedCard(
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("no-provider-connections"),
                ) {
                    Column(
                        modifier = Modifier.padding(18.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text("아직 AI 연결이 없습니다.")
                        Text(
                            "알려진 provider는 API 키만으로 시작할 수 있고, 다른 서비스는 " +
                                "사이트 주소나 cURL 예제로 찾을 수 있습니다.",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Button(
                            onClick = onBeginAddConnection,
                            modifier = Modifier.testTag("empty-add-provider-connection"),
                        ) {
                            Text("새 AI 연결")
                        }
                    }
                }
            }
        }

        state.connections.forEach { details ->
            item(key = "connection-${details.connection.id}") {
                val modelSyncIsActionable = state.modelSync.hasActionableModelSync()
                ProviderConnectionCard(
                    details = details,
                    settings = state.settings,
                    enabled = !state.isBusy && !modelSyncIsActionable,
                    onEdit = { onBeginEditConnection(details.connection.id) },
                    onDelete = { onRequestDeleteConnection(details.connection) },
                    onSync = { onStartModelSync(details.connection.id) },
                    onSelectPreset = onSelectGenerationPreset,
                    onAddPreset = onBeginAddPreset,
                    onEditPreset = onBeginEditPreset,
                    onDeletePreset = onRequestDeletePreset,
                )
            }
        }

        state.modelSync?.let { sync ->
            item(key = "model-sync") {
                ModelSyncCard(
                    state = sync,
                    actionsEnabled = !state.isBusy ||
                        sync.actionableJobs().any { it is ModelSyncUiState.Running } &&
                        state.busyOperation == BusyOperation.SynchronizingModels,
                    onApprove = onApproveModelSync,
                    onCancel = onCancelModelSync,
                    onDismiss = onDismissModelSync,
                )
            }
        }

        state.presetEditor?.let { editor ->
            item(key = "preset-editor") {
                PresetEditorCard(
                    editor = editor,
                    reviewPrepared = state.presetReview != null,
                    controls = state.presetControls,
                    credentialBearingConnection =
                        state.isCredentialBearingRoute(editor.modelRouteId),
                    enabled = !state.isBusy,
                    onChange = onUpdatePresetEditor,
                    onSave = onSavePreset,
                    onCancel = onCancelPresetEditor,
                )
            }
        }

        item(key = "partial-generation") {
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
                        enabled = !state.isBusy,
                        modifier = Modifier
                            .testTag("preserve-partial-switch")
                            .semantics {
                                contentDescription =
                                    "부분 생성 응답 보존"
                            },
                    )
                }
            }
        }

        state.notice?.let { notice ->
            item(key = "notice") {
                Text(
                    text = notice,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .semantics { liveRegion = LiveRegionMode.Polite }
                        .testTag("settings-notice"),
                )
            }
        }
        state.error?.let { error ->
            item(key = "error") {
                Text(
                    text = error,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier
                        .semantics { liveRegion = LiveRegionMode.Assertive }
                        .testTag("settings-error"),
                )
            }
        }

        item(key = "provider-catalog") {
            ProviderCatalogSection(
                state = state.catalog,
                onRefresh = { onCatalogAction(ProviderCatalogUiAction.Refresh) },
                onChooseSignedCatalogDocument = {
                    onCatalogAction(ProviderCatalogUiAction.ChooseSignedDocument)
                },
                onActivateImport = {
                    onCatalogAction(ProviderCatalogUiAction.ActivateImport)
                },
                onCancelImport = {
                    onCatalogAction(ProviderCatalogUiAction.CancelImport)
                },
                onPrepareRollback = { revision ->
                    onCatalogAction(ProviderCatalogUiAction.PrepareRollback(revision))
                },
                onActivateRollback = {
                    onCatalogAction(ProviderCatalogUiAction.ActivateRollback)
                },
                onCancelRollback = {
                    onCatalogAction(ProviderCatalogUiAction.CancelRollback)
                },
            )
        }

        item(key = "health-heading") {
            Text(
                text = stringResource(R.string.core_status),
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
        }
        item(key = "health") {
            HealthCard(state.health)
        }
    }
}

@Composable
private fun ProviderSetupCard(
    setup: ProviderSetupState,
    templates: List<ProviderTemplate>,
    assistantTarget: SetupAssistantTarget?,
    enabled: Boolean,
    onChooseKind: (ProviderSetupKind) -> Unit,
    onChooseTemplate: (String) -> Unit,
    onChange: (ProviderSetupState) -> Unit,
    onContinue: (String, String) -> Unit,
    onDiscoveryAction: (ProviderDiscoveryUiAction) -> Unit,
    onApproveOrigin: () -> Unit,
    onCommit: () -> Unit,
    onCancel: () -> Unit,
    onRetry: () -> Unit,
) {
    var pendingCredential by remember(setup.connectionId) { mutableStateOf("") }
    var pendingCurl by remember(setup.connectionId) { mutableStateOf("") }
    LaunchedEffect(setup.step) {
        if (setup.step != ProviderSetupStep.EnterDetails) {
            pendingCredential = ""
            pendingCurl = ""
        }
    }
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-setup-${setup.step.name.lowercase()}"),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        ),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                "새 AI 연결",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
            SetupStepIndicator(setup.step)
            when (setup.step) {
                ProviderSetupStep.ChooseMethod -> SetupMethodChooser(onChooseKind)
                ProviderSetupStep.EnterDetails -> SetupDetails(
                    setup = setup,
                    templates = templates,
                    assistantTarget = assistantTarget,
                    enabled = enabled,
                    onChooseTemplate = onChooseTemplate,
                    onChange = onChange,
                    credential = pendingCredential,
                    onCredentialChange = { pendingCredential = it },
                    pastedCurl = pendingCurl,
                    onPastedCurlChange = { pendingCurl = it },
                )

                ProviderSetupStep.Discovering,
                ProviderSetupStep.ApproveCredentialOrigin,
                ProviderSetupStep.Review,
                ProviderSetupStep.Committing,
                -> DiscoverySnapshotContent(
                    setup = setup,
                    assistantTarget = assistantTarget,
                    enabled = enabled,
                    onApproveOrigin = onApproveOrigin,
                    onAction = onDiscoveryAction,
                )

                ProviderSetupStep.Completed -> Text("연결을 저장했습니다.")
                ProviderSetupStep.Failed -> {
                    Text(
                        setup.error ?: "자동 설정을 완료하지 못했습니다.",
                        color = MaterialTheme.colorScheme.error,
                        modifier = Modifier.semantics {
                            liveRegion = LiveRegionMode.Assertive
                        },
                    )
                }

                ProviderSetupStep.Cancelled -> Text("자동 설정을 취소했습니다.")
            }

            setup.error?.takeIf { setup.step != ProviderSetupStep.Failed }?.let {
                Text(it, color = MaterialTheme.colorScheme.error)
            }

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            ) {
                if (setup.step != ProviderSetupStep.Completed) {
                    TextButton(
                        onClick = onCancel,
                        enabled = enabled,
                        modifier = Modifier.testTag("cancel-provider-setup"),
                    ) {
                        Text(stringResource(R.string.cancel))
                    }
                }
                when (setup.step) {
                    ProviderSetupStep.EnterDetails -> Button(
                        onClick = { onContinue(pendingCredential, pendingCurl) },
                        enabled = enabled && setup.kind != null,
                        modifier = Modifier.testTag("continue-provider-setup"),
                    ) {
                        Text(
                            if (setup.kind == ProviderSetupKind.KnownProvider) {
                                "검토"
                            } else {
                                "자동 설정"
                            },
                        )
                    }

                    ProviderSetupStep.Review -> Button(
                        onClick = onCommit,
                        enabled = enabled &&
                            setup.discovery?.reviewProposal != null,
                        modifier = Modifier.testTag("commit-provider-setup"),
                    ) {
                        Text("연결 저장")
                    }

                    ProviderSetupStep.Failed,
                    ProviderSetupStep.Cancelled,
                    -> OutlinedButton(
                        onClick = onRetry,
                        enabled = enabled,
                        modifier = Modifier.testTag("retry-provider-setup"),
                    ) {
                        Text(stringResource(R.string.retry))
                    }

                    else -> Unit
                }
            }
        }
    }
}

@Composable
private fun SetupStepIndicator(step: ProviderSetupStep) {
    val labels = listOf("입력", "탐색", "호스트 승인", "검토", "저장")
    val current = when (step) {
        ProviderSetupStep.ChooseMethod,
        ProviderSetupStep.EnterDetails,
        -> 0
        ProviderSetupStep.Discovering -> 1
        ProviderSetupStep.ApproveCredentialOrigin -> 2
        ProviderSetupStep.Review -> 3
        ProviderSetupStep.Committing,
        ProviderSetupStep.Completed,
        -> 4
        ProviderSetupStep.Failed,
        ProviderSetupStep.Cancelled,
        -> 0
    }
    Text(
        labels.mapIndexed { index, label ->
            if (index == current) "[$label]" else label
        }.joinToString("  ›  "),
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.semantics {
            stateDescription = "${current + 1}/${labels.size} ${labels[current]}"
        },
    )
}

@Composable
private fun SetupMethodChooser(
    onChooseKind: (ProviderSetupKind) -> Unit,
) {
    Text("어떤 서비스에 연결할까요?")
    SetupMethodButton(
        title = "알려진 provider",
        body = "OpenAI, Anthropic, Gemini, OpenRouter, Ollama 등",
        tag = "setup-known-provider",
        onClick = { onChooseKind(ProviderSetupKind.KnownProvider) },
    )
    SetupMethodButton(
        title = "다른 서비스 사이트",
        body = "API 키를 발급받은 사이트 주소로 공식 문서와 API 서버 찾기",
        tag = "setup-unknown-site",
        onClick = { onChooseKind(ProviderSetupKind.UnknownSite) },
    )
    SetupMethodButton(
        title = "로컬 서버",
        body = "이 기기의 loopback 또는 정확히 승인한 사설 IP의 API 탐색",
        tag = "setup-local-server",
        onClick = { onChooseKind(ProviderSetupKind.LocalServer) },
    )
    SetupMethodButton(
        title = "cURL 예제",
        body = "공식 API 문서의 cURL을 secret 제거 후 분석",
        tag = "setup-curl-example",
        onClick = { onChooseKind(ProviderSetupKind.CurlExample) },
    )
}

@Composable
private fun SetupMethodButton(
    title: String,
    body: String,
    tag: String,
    onClick: () -> Unit,
) {
    OutlinedButton(
        onClick = onClick,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag),
        contentPadding = PaddingValues(14.dp),
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            Text(title, fontWeight = FontWeight.SemiBold)
            Text(
                body,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun SetupDetails(
    setup: ProviderSetupState,
    templates: List<ProviderTemplate>,
    assistantTarget: SetupAssistantTarget?,
    enabled: Boolean,
    onChooseTemplate: (String) -> Unit,
    onChange: (ProviderSetupState) -> Unit,
    credential: String,
    onCredentialChange: (String) -> Unit,
    pastedCurl: String,
    onPastedCurlChange: (String) -> Unit,
) {
    SetupAssistantTargetContent(assistantTarget)
    when (setup.kind) {
        ProviderSetupKind.KnownProvider -> {
            Text("Provider 선택", fontWeight = FontWeight.SemiBold)
            templates.forEach { template ->
                FilterChip(
                    selected = setup.templateId == template.id,
                    onClick = { onChooseTemplate(template.id) },
                    enabled = enabled,
                    label = { Text(template.displayName) },
                    modifier = Modifier.testTag("provider-template-${template.id}"),
                )
            }
            val selected = templates.firstOrNull { it.id == setup.templateId }
            if (selected != null) {
                CommonConnectionFields(
                    setup = setup,
                    template = selected,
                    enabled = enabled,
                    onChange = onChange,
                    credential = credential,
                    onCredentialChange = onCredentialChange,
                )
            }
        }

        ProviderSetupKind.UnknownSite,
        ProviderSetupKind.LocalServer,
        -> {
            DiscoveryConnectionFields(setup, enabled, onChange)
            OutlinedTextField(
                value = setup.siteUrl,
                onValueChange = { onChange(setup.copy(siteUrl = it)) },
                enabled = enabled,
                label = {
                    Text(
                        if (setup.kind == ProviderSetupKind.LocalServer) {
                            "로컬 API URL"
                        } else {
                            "API 키를 발급받은 사이트"
                        },
                    )
                },
                placeholder = {
                    Text(
                        if (setup.kind == ProviderSetupKind.LocalServer) {
                            "http://127.0.0.1:11434"
                        } else {
                            "https://console.example.ai/api-keys"
                        },
                    )
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("discovery-site-url"),
            )
            CredentialField(
                value = credential,
                enabled = enabled,
                onValueChange = onCredentialChange,
            )
            Text(
                "LorePia가 bounded 탐색으로 공식 문서와 API 서버를 찾습니다. " +
                    "API 키는 문서나 setup LLM에 보내지 않습니다.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        ProviderSetupKind.CurlExample -> {
            DiscoveryConnectionFields(setup, enabled, onChange)
            OutlinedTextField(
                value = pastedCurl,
                onValueChange = onPastedCurlChange,
                enabled = enabled,
                label = { Text("공식 문서의 cURL 예제") },
                minLines = 6,
                maxLines = 12,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("discovery-curl"),
            )
            Text(
                "원문은 저장하지 않고, credential 값은 parsing 직후 placeholder로 " +
                    "치환되어야 합니다.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }

        null -> Unit
    }
}

@Composable
private fun SetupAssistantTargetContent(
    target: SetupAssistantTarget?,
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("setup-assistant-target"),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("필요할 때 사용할 setup assistant", fontWeight = FontWeight.SemiBold)
            if (target == null) {
                Text(
                    "현재 실행 가능한 기본 모델과 preset이 없습니다. 자동 탐색은 계속할 수 " +
                        "있지만 LLM 보완은 사용할 수 없습니다. 먼저 기존 연결에서 모델과 " +
                        "preset을 선택해 주세요.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag("setup-assistant-unavailable"),
                )
            } else {
                Text(
                    "${target.modelDisplayName} · ${target.generationPresetDisplayName}",
                    modifier = Modifier.testTag("setup-assistant-selected"),
                )
                Text(
                    "${target.connectionDisplayName} 연결 · route ${target.modelRouteId}",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
                Text(
                    "탐색 시작 시 이 모델 route를 고정합니다. assistant 실행에는 표시된 " +
                        "현재 preset을 사용하며, 전송 문서와 호출 한도를 먼저 승인합니다.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
        }
    }
}

@Composable
private fun DiscoveryConnectionFields(
    setup: ProviderSetupState,
    enabled: Boolean,
    onChange: (ProviderSetupState) -> Unit,
) {
    OutlinedTextField(
        value = setup.displayName,
        onValueChange = { onChange(setup.copy(displayName = it)) },
        enabled = enabled,
        label = { Text("연결 이름") },
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("discovery-display-name"),
    )
    OutlinedTextField(
        value = setup.docsUrl,
        onValueChange = { onChange(setup.copy(docsUrl = it)) },
        enabled = enabled &&
            setup.networkMode != ProviderNetworkMode.ApprovedLocalNetwork,
        label = { Text("공식 API 문서 URL (선택)") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("discovery-docs-url"),
    )
    Text("네트워크 범위", fontWeight = FontWeight.SemiBold)
    ProviderNetworkMode.entries
        .filterNot {
            setup.kind == ProviderSetupKind.LocalServer &&
                it == ProviderNetworkMode.Public
        }
        .forEach { mode ->
            FilterChip(
                selected = setup.networkMode == mode,
                onClick = {
                    onChange(
                        setup.copy(
                            networkMode = mode,
                            docsUrl = if (mode == ProviderNetworkMode.ApprovedLocalNetwork) {
                                ""
                            } else {
                                setup.docsUrl
                            },
                            localNetworkOrigin = "",
                            localNetworkAddresses = "",
                        ),
                    )
                },
                enabled = enabled,
                label = {
                    Text(
                        when (mode) {
                            ProviderNetworkMode.Public -> "공개 인터넷"
                            ProviderNetworkMode.LocalLoopback -> "이 기기 loopback"
                            ProviderNetworkMode.ApprovedLocalNetwork ->
                                "승인한 로컬 네트워크"
                        },
                    )
                },
                modifier = Modifier.testTag(
                    "discovery-network-${mode.name.lowercase()}",
                ),
            )
        }
    if (setup.networkMode == ProviderNetworkMode.ApprovedLocalNetwork) {
        Text(
            "승인한 LAN에서는 별도 문서 읽기 승인이 없으므로 URL fetch를 하지 않습니다. " +
                "공식 cURL 예제 방식으로 설정하세요.",
            style = MaterialTheme.typography.bodySmall,
        )
        OutlinedTextField(
            value = setup.localNetworkOrigin,
            onValueChange = { onChange(setup.copy(localNetworkOrigin = it)) },
            enabled = enabled,
            label = { Text("승인할 exact origin") },
            supportingText = { Text("scheme, host/IP, port를 모두 확인하세요.") },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("discovery-local-origin"),
        )
        OutlinedTextField(
            value = setup.localNetworkAddresses,
            onValueChange = { onChange(setup.copy(localNetworkAddresses = it)) },
            enabled = enabled,
            label = { Text("승인할 사설 IP 주소") },
            supportingText = {
                Text("DNS 이름이 아니라 확인한 IP를 줄바꿈 또는 쉼표로 최대 16개 입력합니다.")
            },
            minLines = 2,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("discovery-local-addresses"),
        )
    }
    OutlinedTextField(
        value = setup.timeoutSeconds,
        onValueChange = { onChange(setup.copy(timeoutSeconds = it)) },
        enabled = enabled,
        label = { Text("요청 제한 시간(초)") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("discovery-timeout"),
    )
}

@Composable
private fun CommonConnectionFields(
    setup: ProviderSetupState,
    template: ProviderTemplate,
    enabled: Boolean,
    onChange: (ProviderSetupState) -> Unit,
    credential: String,
    onCredentialChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = setup.displayName,
        onValueChange = { onChange(setup.copy(displayName = it)) },
        enabled = enabled,
        label = { Text("연결 이름") },
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("connection-display-name"),
    )
    if (template.defaultApiOrigin == null) {
        OutlinedTextField(
            value = setup.apiOrigin,
            onValueChange = { onChange(setup.copy(apiOrigin = it)) },
            enabled = enabled,
            label = { Text("API origin") },
            supportingText = { Text("scheme, host, port만 입력합니다.") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .testTag("connection-api-origin"),
        )
    }
    template.connectionFields
        .filterNot { it.valueType == ConnectionFieldType.Credential }
        .forEach { field ->
            ConnectionFieldInput(
                field = field,
                value = setup.connectionValues[field.key].orEmpty(),
                valueIsPresent = setup.connectionValues.containsKey(field.key),
                onValueChange = { value ->
                    onChange(
                        setup.copy(
                            connectionValues = if (value == null) {
                                setup.connectionValues - field.key
                            } else {
                                setup.connectionValues + (field.key to value)
                            },
                        ),
                    )
                },
                enabled = enabled,
            )
        }
    if (template.requiresCredential) {
        CredentialField(
            value = credential,
            enabled = enabled,
            onValueChange = onCredentialChange,
        )
    }
    OutlinedTextField(
        value = setup.timeoutSeconds,
        onValueChange = { value ->
            if (value.all(Char::isDigit)) onChange(setup.copy(timeoutSeconds = value))
        },
        enabled = enabled,
        label = { Text("제한 시간(초)") },
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("connection-timeout"),
    )
}

@Composable
private fun ConnectionFieldInput(
    field: ConnectionFieldSpec,
    value: String,
    valueIsPresent: Boolean,
    enabled: Boolean,
    onValueChange: (String?) -> Unit,
) {
    if (field.valueType == ConnectionFieldType.Boolean) {
        OutlinedCard(
            modifier = Modifier
                .fillMaxWidth()
                .testTag("connection-field-${field.key}"),
        ) {
            Column(
                modifier = Modifier.padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    humanizeKey(field.labelKey) + if (field.required) " (필수)" else "",
                    fontWeight = FontWeight.SemiBold,
                )
                field.descriptionKey?.let {
                    Text(
                        humanizeKey(it),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (!field.required) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("직접 설정", modifier = Modifier.weight(1f))
                        Switch(
                            checked = valueIsPresent,
                            onCheckedChange = { explicit ->
                                onValueChange(if (explicit) "false" else null)
                            },
                            enabled = enabled,
                            modifier = Modifier.semantics {
                                contentDescription =
                                    "${humanizeKey(field.labelKey)} 직접 설정"
                            },
                        )
                    }
                }
                if (valueIsPresent || field.required) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            if (value.equals("true", ignoreCase = true)) "켬" else "끔",
                            modifier = Modifier.weight(1f),
                        )
                        Switch(
                            checked = value.equals("true", ignoreCase = true),
                            onCheckedChange = { onValueChange(it.toString()) },
                            enabled = enabled,
                            modifier = Modifier.testTag(
                                "connection-field-${field.key}-value",
                            ),
                        )
                    }
                } else {
                    Text(
                        "Provider 기본값을 유지합니다.",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
        return
    }

    OutlinedTextField(
        value = value,
        onValueChange = { changed ->
            if (field.valueType != ConnectionFieldType.Integer ||
                changed.isEmpty() ||
                changed == "-" ||
                changed.toLongOrNull() != null
            ) {
                onValueChange(changed)
            }
        },
        enabled = enabled,
        label = {
            Text(humanizeKey(field.labelKey) + if (field.required) " (필수)" else "")
        },
        supportingText = field.descriptionKey?.let { description ->
            { Text(humanizeKey(description)) }
        },
        keyboardOptions = KeyboardOptions(
            keyboardType = if (field.valueType == ConnectionFieldType.Integer) {
                KeyboardType.Number
            } else {
                KeyboardType.Text
            },
        ),
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("connection-field-${field.key}"),
    )
}

@Composable
private fun CredentialField(
    value: String,
    enabled: Boolean,
    onValueChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onValueChange,
        enabled = enabled,
        label = { Text("API 자격증명") },
        supportingText = {
            Text("Android Keystore로 암호화하며 화면 밖에는 저장하지 않습니다.")
        },
        keyboardOptions = KeyboardOptions(
            keyboardType = KeyboardType.Password,
            autoCorrectEnabled = false,
        ),
        visualTransformation = PasswordVisualTransformation(),
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("connection-credential")
            .semantics {
                contentDescription = "API 자격증명 보안 입력"
            },
    )
}

@Composable
private fun DiscoveryProgressContent(progress: DiscoveryProgress?) {
    val value = progress?.let {
        if (it.totalSteps > 0) it.completedSteps.toFloat() / it.totalSteps else 0f
    } ?: 0f
    LinearProgressIndicator(
        progress = { value.coerceIn(0f, 1f) },
        modifier = Modifier
            .fillMaxWidth()
            .semantics {
                progressBarRangeInfo = androidx.compose.ui.semantics.ProgressBarRangeInfo(
                    value.coerceIn(0f, 1f),
                    0f..1f,
                )
            }
            .testTag("provider-discovery-progress"),
    )
    Text(progress?.currentLabel ?: "공식 API 정보를 찾는 중입니다.")
}

@Composable
private fun DiscoverySnapshotContent(
    setup: ProviderSetupState,
    assistantTarget: SetupAssistantTarget?,
    enabled: Boolean,
    onApproveOrigin: () -> Unit,
    onAction: (ProviderDiscoveryUiAction) -> Unit,
) {
    val snapshot = setup.discovery
    if (snapshot == null) {
        DiscoveryProgressContent(setup.progress)
        return
    }
    var documentUrl by remember(snapshot.sessionId, snapshot.revision) {
        mutableStateOf("")
    }
    var curlEvidence by remember(snapshot.sessionId, snapshot.revision) {
        mutableStateOf("")
    }
    val currentAssistantTarget = assistantTarget?.takeIf {
        setup.preferredAssistantModelRouteId != null &&
            it.modelRouteId == setup.preferredAssistantModelRouteId
    }
    val assistantTargetIsCurrent = currentAssistantTarget != null
    Text(
        "Core discovery · ${snapshot.state.replace('_', ' ')}",
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier
            .semantics { liveRegion = LiveRegionMode.Polite }
            .testTag("discovery-state"),
    )
    snapshot.steps.forEach { step ->
        Text(
            "${if (step.state == "completed") "✓" else "•"} " +
                "${step.titleKey.replace('_', ' ')} · ${step.state}",
            style = MaterialTheme.typography.bodySmall,
        )
    }
    snapshot.failure?.let { failure ->
        Text(
            "${failure.code}: ${failure.messageKey.replace('_', ' ')}",
            color = MaterialTheme.colorScheme.error,
        )
    }

    when (val required = snapshot.actionRequired) {
        DiscoveryActionRequired.SelectTemplate -> {
            Text("Provider template 후보", fontWeight = FontWeight.SemiBold)
            snapshot.candidates.forEach { candidate ->
                val summary = candidate.summary.discoveryCandidateLabel()
                OutlinedButton(
                    onClick = {
                        onAction(ProviderDiscoveryUiAction.SelectCandidate(candidate.id))
                    },
                    enabled = enabled,
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("select-discovery-candidate-${candidate.id}"),
                ) {
                    Column(modifier = Modifier.fillMaxWidth()) {
                        Text(summary, fontWeight = FontWeight.SemiBold)
                        Text(
                            "근거 ${candidate.evidenceIds.joinToString().ifBlank { "없음" }}",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
            TextButton(
                onClick = {
                    onAction(ProviderDiscoveryUiAction.ContinueWithoutTemplate)
                },
                enabled = enabled,
                modifier = Modifier.testTag("continue-without-template"),
            ) {
                Text("Template 없이 공식 근거 탐색 계속")
            }
        }

        DiscoveryActionRequired.SupplyMoreEvidence -> {
            Text("추가 공식 근거가 필요합니다.", fontWeight = FontWeight.SemiBold)
            OutlinedTextField(
                value = documentUrl,
                onValueChange = { documentUrl = it },
                enabled = enabled,
                label = { Text("공식 문서 URL") },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("additional-discovery-document"),
            )
            Button(
                onClick = {
                    onAction(ProviderDiscoveryUiAction.SupplyDocument(documentUrl))
                    documentUrl = ""
                },
                enabled = enabled && documentUrl.isNotBlank(),
                modifier = Modifier.testTag("supply-discovery-document"),
            ) {
                Text("문서 근거 추가")
            }
            OutlinedTextField(
                value = curlEvidence,
                onValueChange = { curlEvidence = it },
                enabled = enabled,
                label = { Text("추가 cURL 근거") },
                minLines = 4,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("additional-discovery-curl"),
            )
            Button(
                onClick = {
                    val submittedCurl = curlEvidence
                    curlEvidence = ""
                    onAction(ProviderDiscoveryUiAction.SupplyCurl(submittedCurl))
                },
                enabled = enabled && curlEvidence.isNotBlank(),
                modifier = Modifier.testTag("supply-discovery-curl"),
            ) {
                Text("cURL 근거 추가")
            }
            OutlinedButton(
                onClick = { onAction(ProviderDiscoveryUiAction.RequestAssistant) },
                enabled = enabled && assistantTargetIsCurrent,
                modifier = Modifier.testTag("request-discovery-assistant"),
            ) {
                Text("Setup assistant 사용 검토")
            }
            if (currentAssistantTarget != null) {
                Text(
                    "사용 모델: ${currentAssistantTarget.modelDisplayName} · " +
                        currentAssistantTarget.generationPresetDisplayName,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag("discovery-assistant-target"),
                )
            } else {
                Text(
                    "탐색 시작 때 고정한 모델/preset을 사용할 수 없습니다. 자동 탐색에 " +
                        "공식 근거를 더 제공하거나, 이 탐색을 취소하고 모델을 선택한 뒤 " +
                        "다시 시작해 주세요.",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag("discovery-assistant-unavailable"),
                )
            }
        }

        DiscoveryActionRequired.ApproveAssistant -> {
            val proposal = snapshot.approvalProposal
            val grant = proposal?.grant as? DiscoveryApprovalGrant.AssistantConsent
            if (proposal == null || grant == null) {
                Text("Assistant 승인 제안이 없습니다.", color = MaterialTheme.colorScheme.error)
            } else {
                Text("Setup assistant 동의", fontWeight = FontWeight.SemiBold)
                ReviewRow("모델 route", grant.assistantModelRouteId)
                ReviewRow(
                    "허용 문서 origin",
                    grant.allowedDocumentOrigins.joinToString().ifBlank { "없음" },
                )
                ReviewRow("근거 ID", grant.evidenceIds.joinToString().ifBlank { "없음" })
                ReviewRow(
                    "한도",
                    "${grant.maxCalls} calls · input ${grant.maxInputTokens} · " +
                        "output ${grant.maxOutputTokens} · tools ${grant.maxToolCalls} · " +
                        "retry ${grant.maxRetries} · cost ${grant.maxCostMicroUnits} µunit",
                )
                Text("승인 해시 ${proposal.grantSha256}", style = MaterialTheme.typography.bodySmall)
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = {
                            onAction(ProviderDiscoveryUiAction.ApproveAssistant)
                        },
                        enabled = enabled &&
                            assistantTargetIsCurrent &&
                            setup.preferredAssistantModelRouteId ==
                                grant.assistantModelRouteId,
                        modifier = Modifier.testTag("approve-discovery-assistant"),
                    ) {
                        Text("정확한 범위 승인")
                    }
                    OutlinedButton(
                        onClick = {
                            onAction(ProviderDiscoveryUiAction.DeclineAssistant)
                        },
                        enabled = enabled,
                    ) {
                        Text("거절")
                    }
                }
                if (
                    !assistantTargetIsCurrent ||
                    setup.preferredAssistantModelRouteId != grant.assistantModelRouteId
                ) {
                    Text(
                        "승인 제안의 모델 route가 현재 실행 가능한 선택과 일치하지 않아 " +
                            "모델 호출을 차단했습니다.",
                        color = MaterialTheme.colorScheme.error,
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.testTag("assistant-approval-target-mismatch"),
                    )
                }
            }
        }

        DiscoveryActionRequired.ApproveCredentialOrigin -> {
            val grant = snapshot.approvalProposal?.grant
                as? DiscoveryApprovalGrant.CredentialOrigin
            if (grant == null) {
                Text("Credential origin 제안이 없습니다.", color = MaterialTheme.colorScheme.error)
            } else {
                Text("API 키 전송 대상", fontWeight = FontWeight.SemiBold)
                ReviewRow("Exact origin", grant.origin)
                ReviewRow("인증 방식", grant.authBinding.toString())
                ReviewRow("Manifest", grant.manifestSha256)
                Text(
                    "이 origin 외의 문서, assistant, redirect에는 자격증명을 보내지 않습니다.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Button(
                    onClick = onApproveOrigin,
                    enabled = enabled,
                    modifier = Modifier.testTag("approve-credential-origin"),
                ) {
                    Text("이 exact origin만 승인")
                }
            }
        }

        DiscoveryActionRequired.ApproveProbes -> {
            val grant = snapshot.approvalProposal?.grant
                as? DiscoveryApprovalGrant.CapabilityProbe
            if (grant == null) {
                Text("Probe 승인 제안이 없습니다.", color = MaterialTheme.colorScheme.error)
            } else {
                Text("Capability probe 검토", fontWeight = FontWeight.SemiBold)
                ReviewRow("Model routes", grant.modelRouteIds.joinToString())
                ReviewRow(
                    "요청 한도",
                    "${grant.budget.maxRequests} requests · " +
                        "${grant.budget.maxCallsPerRequest} calls/request · " +
                        "${grant.budget.maxTotalTokensPerRequest} tokens/request · " +
                        "${grant.budget.maxOutputTokensPerRequest} output/request · " +
                        "${grant.budget.maxDurationMillisPerRequest} ms/request · " +
                        "${grant.budget.maxCostMicroUsdPerRequest} µUSD/request",
                )
                ReviewRow(
                    "전체 승인 상한",
                    grant.budget.aggregateCeilingLabel(),
                )
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(
                        onClick = { onAction(ProviderDiscoveryUiAction.ApproveProbes) },
                        enabled = enabled,
                        modifier = Modifier.testTag("approve-discovery-probes"),
                    ) {
                        Text("Probe 승인")
                    }
                    OutlinedButton(
                        onClick = { onAction(ProviderDiscoveryUiAction.SkipProbes) },
                        enabled = enabled,
                    ) {
                        Text("건너뛰기")
                    }
                }
            }
        }

        DiscoveryActionRequired.Review -> DiscoveryReviewContent(snapshot)

        is DiscoveryActionRequired.RestartInterrupted -> {
            Text("중단된 작업: ${required.operation}")
            Button(
                onClick = { onAction(ProviderDiscoveryUiAction.RestartInterrupted) },
                enabled = enabled,
                modifier = Modifier.testTag("restart-interrupted-discovery"),
            ) {
                Text("중단 지점에서 명시적으로 재시작")
            }
        }

        is DiscoveryActionRequired.ReconcileUnknownOutcome -> {
            Text(
                "네이티브 부작용 결과를 자동 재실행할 수 없습니다: ${required.operation}",
                color = MaterialTheme.colorScheme.error,
            )
            val grant = snapshot.approvalProposal?.grant
                as? DiscoveryApprovalGrant.UnknownOutcomeResolution
            if (grant != null) {
                ReviewRow("검증된 해결", grant.resolution.discoveryResolutionLabel())
                Button(
                    onClick = {
                        onAction(
                            ProviderDiscoveryUiAction.ResolveUnknownOutcome(
                                grant.resolution,
                            ),
                        )
                    },
                    enabled = enabled,
                    modifier = Modifier.testTag("resolve-discovery-unknown-outcome"),
                ) {
                    Text("이 해결 결과 기록")
                }
            }
        }

        null -> {
            if (snapshot.state == "compensating") {
                Button(
                    onClick = { onAction(ProviderDiscoveryUiAction.ResumeCompensation) },
                    enabled = enabled,
                    modifier = Modifier.testTag("resume-discovery-compensation"),
                ) {
                    Text("보상 작업 명시적 재개")
                }
            } else {
                DiscoveryProgressContent(setup.progress)
            }
        }
    }

    when (snapshot.assistantResumeBoundary?.action) {
        DiscoveryAssistantResumeAction.RunAssistant -> {
            Button(
                onClick = { onAction(ProviderDiscoveryUiAction.RunAssistant) },
                enabled = enabled && assistantTargetIsCurrent,
                modifier = Modifier.testTag("run-discovery-assistant"),
            ) {
                Text("승인한 setup assistant 실행")
            }
            if (!assistantTargetIsCurrent) {
                Text(
                    "승인한 모델/preset이 현재 선택과 달라 모델 호출을 차단했습니다.",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.testTag("assistant-run-target-mismatch"),
                )
            }
        }
        DiscoveryAssistantResumeAction.ApproveRetry -> {
            Button(
                onClick = { onAction(ProviderDiscoveryUiAction.ApproveAssistantRetry) },
                enabled = enabled,
                modifier = Modifier.testTag("approve-discovery-assistant-retry"),
            ) {
                Text("Setup assistant 재시도 승인")
            }
        }
        DiscoveryAssistantResumeAction.ResumeCoreHostAction -> {
            Button(
                onClick = {
                    onAction(ProviderDiscoveryUiAction.ResumeAssistantCoreHostAction)
                },
                enabled = enabled,
                modifier = Modifier.testTag("resume-discovery-assistant-core-host-action"),
            ) {
                Text("Core 내부 assistant 작업 재개")
            }
        }
        DiscoveryAssistantResumeAction.WaitForAssistantOutcome -> Text(
            "Setup assistant 작업 결과를 확인 중입니다. 앱을 종료해 결과가 불명확하면 " +
                "Core가 명시적 재시작 또는 조정 단계로 전환합니다.",
            style = MaterialTheme.typography.bodySmall,
        )
        else -> Unit
    }

    when (val outcome = setup.assistantOutcome) {
        is DiscoveryAssistantOutcome.MoreEvidenceRequired -> {
            Text("Assistant 질문", fontWeight = FontWeight.SemiBold)
            outcome.questions.forEach { question ->
                OutlinedCard(modifier = Modifier.fillMaxWidth()) {
                    Column(
                        modifier = Modifier.padding(10.dp),
                        verticalArrangement = Arrangement.spacedBy(4.dp),
                    ) {
                        Text(question.question)
                        Text(
                            "필요 근거: ${question.requiredEvidence}",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }
        }
        is DiscoveryAssistantOutcome.DraftReadyForReview -> {
            val review = outcome.review
            Text("Assistant manifest 초안", fontWeight = FontWeight.SemiBold)
            Text(review.draft.summary)
            ReviewRow("API family", review.draft.manifest.apiFamily)
            ReviewRow(
                "Default origin",
                review.draft.manifest.defaultApiOrigin ?: "없음",
            )
            ReviewRow(
                "Generate endpoint",
                "${review.draft.manifest.generateEndpoint.method} " +
                    review.draft.manifest.generateEndpoint.path,
            )
            review.draft.manifest.sources.forEach { source ->
                Text(
                    "• ${source.kind}: ${source.url} · ${source.contentSha256 ?: "hash 없음"}",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            review.draft.evidenceMappings.forEach { mapping ->
                Text(
                    "• ${mapping.field.discoveryDraftFieldLabel()}: " +
                        "${mapping.evidenceIds.joinToString()} · ${mapping.explanation}",
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            review.draft.conflicts.forEach { conflict ->
                Text(
                    "• 충돌 ${conflict.field.discoveryDraftFieldLabel()}: " +
                        conflict.disposition.discoveryDispositionLabel(),
                    color = if (
                        conflict.disposition is DiscoveryAssistantConflictDisposition.Unresolved
                    ) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurface
                    },
                )
            }
            review.draft.confidence.forEach { confidence ->
                Text(
                    "• ${confidence.field.discoveryDraftFieldLabel()}: " +
                        "${confidence.level.name.lowercase()} · ${confidence.rationale}",
                    color = if (confidence.level == DiscoveryAssistantConfidenceLevel.Low) {
                        MaterialTheme.colorScheme.error
                    } else {
                        MaterialTheme.colorScheme.onSurfaceVariant
                    },
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            ReviewRow(
                "필수 검사",
                review.requiredChecks.joinToString { it.name },
            )
            ReviewRow(
                "영구 저장",
                "Rust 검사와 사용자 review 통과 전 차단",
            )
            if (review.unresolvedConflicts.isNotEmpty()) {
                ReviewRow(
                    "미해결 충돌",
                    review.unresolvedConflicts.joinToString {
                        it.discoveryDraftFieldLabel()
                    },
                )
            }
            Button(
                onClick = { onAction(ProviderDiscoveryUiAction.AcceptAssistantDraft) },
                enabled = enabled &&
                    review.unresolvedConflicts.isEmpty() &&
                    review.draft.unresolvedQuestions.isEmpty(),
                modifier = Modifier.testTag("accept-discovery-assistant-draft"),
            ) {
                Text(
                    if (
                        review.unresolvedConflicts.isEmpty() &&
                        review.draft.unresolvedQuestions.isEmpty()
                    ) {
                        "검증 단계로 초안 전달"
                    } else {
                        "미해결 항목 때문에 저장 불가"
                    },
                )
            }
        }
        null -> Unit
    }
}

@Composable
private fun DiscoveryReviewContent(
    snapshot: dev.lorepia.app.bridge.ProviderDiscoverySnapshot,
) {
    val proposal = snapshot.reviewProposal
    if (proposal == null) {
        Text("Core review proposal이 없습니다.", color = MaterialTheme.colorScheme.error)
        return
    }
    Text("저장 전 exact review", fontWeight = FontWeight.SemiBold)
    ReviewRow("Review SHA-256", proposal.review.sha256)
    ReviewRow("Graph SHA-256", proposal.review.graphSha256)
    ReviewRow("Commit plan SHA-256", proposal.commitPlanSha256)
    ReviewRow("Commit attempt", proposal.commitAttemptId)
    ReviewRow("경고", proposal.review.warningCount.toString())
    ReviewRow("미해결 질문", proposal.review.unresolvedQuestionCount.toString())
    proposal.review.changes.forEach { change ->
        Text(
            "• ${change.kind} ${change.targetKind}/${change.targetId}: " +
                "${change.summaryKey} · 근거 ${change.evidenceIds.joinToString()}",
        )
    }
    proposal.requestPreview?.let { preview ->
        OutlinedCard(modifier = Modifier.fillMaxWidth()) {
            Column(
                modifier = Modifier.padding(10.dp),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text("Redacted request preview", fontWeight = FontWeight.SemiBold)
                Text("${preview.method} ${preview.origin}${preview.path}")
                Text("Headers: ${preview.headerNames.joinToString()}")
                Text("Query names: ${preview.queryParameterNames.joinToString()}")
                preview.bodyShape?.let { Text("Body shape: ${it.displayLabel()}") }
                Text("Redaction v${preview.redactionVersion}")
            }
        }
    }
}

private fun DiscoveryCandidateSummary.discoveryCandidateLabel(): String = when (this) {
    is DiscoveryCandidateSummary.ProviderTemplate ->
        "$templateId v$templateVersion"
    is DiscoveryCandidateSummary.ApiOrigin -> "API origin $origin"
    is DiscoveryCandidateSummary.OfficialDocument -> "공식 문서 $contentSha256"
    is DiscoveryCandidateSummary.ModelRoute -> "Model $modelId"
    is DiscoveryCandidateSummary.ManifestDraft -> "Manifest v$schemaVersion $manifestSha256"
}

private fun DiscoveryUnknownOutcomeResolution.discoveryResolutionLabel(): String = when (this) {
    DiscoveryUnknownOutcomeResolution.ConfirmedNoEffect -> "부작용 없음 확인"
    is DiscoveryUnknownOutcomeResolution.ConfirmedCommitCompleted ->
        "Commit 완료 확인: $connectionId"
    DiscoveryUnknownOutcomeResolution.ConfirmedCompensated -> "보상 완료 확인"
    DiscoveryUnknownOutcomeResolution.ManuallyReconciledAsFailed -> "수동 실패 정합화"
}

private fun DiscoveryAssistantDraftField.discoveryDraftFieldLabel(): String = when (this) {
    DiscoveryAssistantDraftField.ApiFamily -> "API family"
    DiscoveryAssistantDraftField.DefaultApiOrigin -> "default origin"
    DiscoveryAssistantDraftField.Auth -> "authentication"
    DiscoveryAssistantDraftField.GenerateEndpoint -> "generate endpoint"
    DiscoveryAssistantDraftField.ModelsEndpoint -> "models endpoint"
    DiscoveryAssistantDraftField.ResponseDecoder -> "response decoder"
    DiscoveryAssistantDraftField.StreamingDecoder -> "streaming decoder"
    is DiscoveryAssistantDraftField.Parameter -> "parameter $parameterId"
}

private fun DiscoveryAssistantConflictDisposition.discoveryDispositionLabel(): String =
    when (this) {
        DiscoveryAssistantConflictDisposition.Unresolved -> "미해결"
        is DiscoveryAssistantConflictDisposition.Resolved ->
            "근거 $selectedEvidenceId 선택 · $rationale"
    }

@Composable
private fun CredentialOriginApproval(
    setup: ProviderSetupState,
    enabled: Boolean,
    onApprove: () -> Unit,
) {
    Text(
        "API 키 전송 대상",
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { heading() },
    )
    Text(
        setup.apiOrigin,
        style = MaterialTheme.typography.bodyLarge,
        fontWeight = FontWeight.Bold,
        modifier = Modifier.testTag("credential-origin"),
    )
    Text(
        "이 exact origin에만 자격증명 전송을 허용합니다. 문서 host, setup LLM, " +
            "다른 redirect origin에는 전송하지 않습니다.",
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
    Button(
        onClick = onApprove,
        enabled = enabled,
        modifier = Modifier
            .fillMaxWidth()
            .testTag("approve-credential-origin"),
    ) {
        Text("이 origin에만 허용")
    }
}

@Composable
private fun ProviderReview(review: ProviderSetupReview?) {
    if (review == null) {
        Text("검토 정보를 불러오지 못했습니다.", color = MaterialTheme.colorScheme.error)
        return
    }
    Text(
        "저장 전 검토",
        style = MaterialTheme.typography.titleMedium,
        modifier = Modifier.semantics { heading() },
    )
    ReviewRow("연결", review.providerName)
    ReviewRow("API 서버", review.apiOrigin)
    ReviewRow("API 키 전송 대상", review.credentialOrigin ?: "자격증명 없음")
    ReviewRow("API 형식", review.apiFamily)
    ReviewRow(
        "모델",
        review.models.takeIf(List<String>::isNotEmpty)?.joinToString()
            ?: "연결 저장 후 검토 기반 동기화 필요",
    )
    review.capabilitySummary.forEach { Text("• $it") }
    Text(
        "근거",
        style = MaterialTheme.typography.titleSmall,
        modifier = Modifier.semantics { heading() },
    )
    review.evidenceSummary.forEach { Text("• $it") }
    OutlinedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text("Redacted request preview", fontWeight = FontWeight.SemiBold)
            Text(
                review.redactedRequestPreview
                    ?: "코어가 생성한 preview가 제공되지 않아 요청 본문을 표시하지 않습니다.",
                style = MaterialTheme.typography.bodySmall,
                modifier = Modifier.testTag("redacted-request-preview"),
            )
            Text(
                "자격증명 값은 preview에 포함되지 않습니다.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.labelSmall,
            )
        }
    }
}

@Composable
private fun ConnectionEditorCard(
    editor: ConnectionEditor,
    template: ProviderTemplate?,
    enabled: Boolean,
    onChange: (ConnectionEditor) -> Unit,
    onSave: (String) -> Unit,
    onCancel: () -> Unit,
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("connection-editor"),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text(
                "연결 편집",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            ReviewRow("API origin (변경 불가)", editor.original.apiOrigin)
            editor.original.apiBasePath?.let {
                ReviewRow("API base path (변경 불가)", it)
            }
            ReviewRow(
                "네트워크 정책 (변경 불가)",
                humanizeKey(editor.original.networkMode.name),
            )
            OutlinedTextField(
                value = editor.displayName,
                onValueChange = { onChange(editor.copy(displayName = it)) },
                enabled = enabled,
                label = { Text("연결 이름") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            template?.connectionFields
                ?.filterNot { it.valueType == ConnectionFieldType.Credential }
                ?.forEach { field ->
                    ReviewRow(
                        "${field.labelKey} (변경 불가)",
                        editor.values[field.key] ?: "설정 없음",
                    )
                }
            ReviewRow(
                "제한 시간 (변경 불가)",
                "${editor.original.timeoutSeconds}초",
            )
            if (editor.original.credentialSlotReady) {
                Text(
                    "기존 API 자격증명은 그대로 유지됩니다. 자격증명이나 계정을 바꾸려면 " +
                        "provider-native reasoning 상태가 섞이지 않도록 새 AI 연결을 만드세요.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.testTag("credential-replacement-requires-new-connection"),
                )
            }
            Text(
                "API endpoint와 연결 옵션을 바꾸려면 새 AI 연결을 만드세요.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            ) {
                TextButton(onClick = onCancel, enabled = enabled) {
                    Text(stringResource(R.string.cancel))
                }
                Button(
                    onClick = { onSave("") },
                    enabled = enabled,
                    modifier = Modifier.testTag("save-connection-editor"),
                ) {
                    Text(stringResource(R.string.save))
                }
            }
        }
    }
}

@Composable
private fun ProviderConnectionCard(
    details: ProviderConnectionDetails,
    settings: dev.lorepia.app.bridge.AppSettings,
    enabled: Boolean,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onSync: () -> Unit,
    onSelectPreset: (String, String) -> Unit,
    onAddPreset: (String) -> Unit,
    onEditPreset: (String) -> Unit,
    onDeletePreset: (GenerationPreset) -> Unit,
) {
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("provider-connection-${details.connection.id}"),
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.Top,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        details.connection.displayName,
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.semantics { heading() },
                    )
                    Text(
                        details.template?.displayName ?: details.connection.templateId,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (details.template == null) {
                        Text(
                            "고정된 template v${details.connection.templateVersion} schema를 " +
                                "현재 catalog에서 찾을 수 없어 편집을 잠갔습니다.",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    Text(
                        details.connection.apiOrigin,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    val scopeIsExact = details.connection.credentialScope?.allowedOrigins
                        ?.distinct() == listOf(details.connection.apiOrigin) &&
                        details.connection.approvedCredentialOrigins.distinct() ==
                        listOf(details.connection.apiOrigin)
                    val credentialStatus = when {
                        !details.connection.credentialSlotReady -> "자격증명 없음"
                        !scopeIsExact -> "자격증명 scope 차단됨"
                        details.credentialRecordStatus ==
                            CredentialRecordStatus.Available -> "Keystore 연결됨"
                        details.credentialRecordStatus ==
                            CredentialRecordStatus.Missing -> "Keystore 레코드 없음"
                        details.credentialRecordStatus ==
                            CredentialRecordStatus.Unreadable -> "Keystore 레코드 손상"
                        else -> "Keystore 상태 미확인"
                    }
                    Text(
                        "상태 ${humanizeKey(details.connection.status)} · " +
                            credentialStatus,
                        style = MaterialTheme.typography.labelMedium,
                    )
                    details.connection.credentialScope?.let { scope ->
                        Text(
                            "자격증명 origin: ${scope.allowedOrigins.joinToString()}",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            "인증 ${authBindingLabel(scope.authBinding)} · redirect " +
                                humanizeKey(scope.redirectPolicy.name),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    if (details.connection.credentialSlotReady && !scopeIsExact) {
                        Text(
                            "자격증명 scope가 exact API origin과 일치하지 않아 사용이 차단됩니다.",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier.semantics {
                                liveRegion = LiveRegionMode.Assertive
                            },
                        )
                    } else if (details.credentialRecordStatus in setOf(
                            CredentialRecordStatus.Missing,
                            CredentialRecordStatus.Unreadable,
                        )
                    ) {
                        Text(
                            "저장된 자격증명을 사용할 수 없습니다. 연결 편집에서 다시 입력해 주세요.",
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.labelMedium,
                            modifier = Modifier.semantics {
                                liveRegion = LiveRegionMode.Assertive
                            },
                        )
                    }
                }
                IconButton(
                    onClick = onEdit,
                    enabled = enabled && details.template != null,
                    modifier = Modifier.testTag("edit-connection-${details.connection.id}"),
                ) {
                    Icon(Icons.Outlined.Edit, contentDescription = "연결 편집")
                }
                IconButton(
                    onClick = onDelete,
                    enabled = enabled,
                    modifier = Modifier.testTag("delete-connection-${details.connection.id}"),
                ) {
                    Icon(Icons.Outlined.Delete, contentDescription = "연결 삭제")
                }
            }
            if (details.template?.supportsModelListing == true) {
                val credentialReady = !details.connection.credentialSlotReady ||
                    details.credentialRecordStatus == CredentialRecordStatus.Available
                OutlinedButton(
                    onClick = onSync,
                    enabled = enabled && credentialReady,
                    modifier = Modifier
                        .fillMaxWidth()
                        .testTag("sync-models-${details.connection.id}"),
                ) {
                    Text("모델 및 기능 새로고침")
                }
            } else {
                Text(
                    "이 template은 provider model-list API를 지원하지 않습니다.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (details.routes.isEmpty()) {
                Text(
                    "아직 동기화된 model route가 없습니다.",
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            details.routes.forEach { route ->
                HorizontalDivider()
                ModelRouteContent(
                    details = route,
                    selectedPresetId = settings.selectedGenerationPresetId
                        .takeIf { settings.selectedModelRouteId == route.route.id },
                    enabled = enabled,
                    onSelectPreset = onSelectPreset,
                    onAddPreset = onAddPreset,
                    onEditPreset = onEditPreset,
                    onDeletePreset = onDeletePreset,
                )
            }
        }
    }
}

@Composable
private fun ModelRouteContent(
    details: ModelRouteDetails,
    selectedPresetId: String?,
    enabled: Boolean,
    onSelectPreset: (String, String) -> Unit,
    onAddPreset: (String) -> Unit,
    onEditPreset: (String) -> Unit,
    onDeletePreset: (GenerationPreset) -> Unit,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("model-route-${details.route.id}"),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    details.route.displayName ?: details.route.modelId,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "${details.route.apiFamily} · ${humanizeKey(details.route.availability)}" +
                        if (details.route.missCount > 0u) {
                            " · ${details.route.missCount}회 연속 미확인"
                        } else {
                            ""
                        },
                    style = MaterialTheme.typography.bodySmall,
                    color = availabilityColor(details.route.availability),
                )
                details.route.lastSeenAt?.let {
                    Text(
                        "마지막 확인 $it",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                details.route.metadataObservedAt?.let {
                    Text(
                        "Metadata ${sourceLabel(details.route.metadataSource)} · $it",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            IconButton(
                onClick = { onAddPreset(details.route.id) },
                enabled = enabled,
                modifier = Modifier.testTag("add-preset-${details.route.id}"),
            ) {
                Icon(Icons.Outlined.Add, contentDescription = "Preset 추가")
            }
        }
        if (details.capabilities.isNotEmpty()) {
            Text("Capability 근거", style = MaterialTheme.typography.titleSmall)
            details.capabilities.forEach { capability ->
                CapabilityRow(capability)
            }
        }
        if (details.presets.isEmpty()) {
            Text(
                "사용할 preset을 만들어야 이 모델을 선택할 수 있습니다.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                style = MaterialTheme.typography.bodySmall,
            )
        }
        details.presets.forEach { preset ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("preset-${preset.id}"),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(
                    selected = preset.id == selectedPresetId,
                    onClick = { onSelectPreset(details.route.id, preset.id) },
                    enabled = enabled && details.route.availability !in setOf(
                        "retired",
                        "access_denied",
                    ),
                    modifier = Modifier
                        .testTag("select-preset-${preset.id}")
                        .semantics {
                            contentDescription = "${preset.displayName} preset 선택"
                        },
                )
                Column(modifier = Modifier.weight(1f)) {
                    Text(preset.displayName)
                    Text(
                        "${preset.values.count { it.state is dev.lorepia.app.bridge.ParameterValueState.Explicit }}개 직접 설정 · " +
                            "추론 ${humanizeKey(preset.reasoningMode)} · " +
                            "캐시 ${humanizeKey(preset.promptCacheMode)}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    details.presetPreviews[preset.id]
                        ?.takeIf { it.isSafeToDisplay }
                        ?.let { preview ->
                            Text(
                                "${preview.method} ${preview.origin}${preview.path} · " +
                                    "redaction v${preview.redactionVersion}",
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.testTag("preset-preview-${preset.id}"),
                            )
                        }
                }
                IconButton(
                    onClick = { onEditPreset(preset.id) },
                    enabled = enabled,
                    modifier = Modifier.testTag("edit-preset-${preset.id}"),
                ) {
                    Icon(Icons.Outlined.Edit, contentDescription = "Preset 편집")
                }
                IconButton(
                    onClick = { onDeletePreset(preset) },
                    enabled = enabled,
                    modifier = Modifier.testTag("delete-preset-${preset.id}"),
                ) {
                    Icon(Icons.Outlined.Delete, contentDescription = "Preset 삭제")
                }
            }
        }
    }
}

@Composable
private fun CapabilityRow(details: CapabilityDetails) {
    val selected = details.effective?.selected
    OutlinedCard(modifier = Modifier.fillMaxWidth()) {
        Column(
            modifier = Modifier.padding(10.dp),
            verticalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(humanizeKey(details.key), fontWeight = FontWeight.SemiBold)
                Text(
                    selected?.status?.let(::humanizeKey) ?: "확인되지 않음",
                    color = capabilityStatusColor(selected?.status),
                    style = MaterialTheme.typography.labelMedium,
                )
            }
            if (selected != null) {
                CapabilityObservationDetails("선택", selected)
            }
            if (details.effective?.selectedIsStale == true) {
                Text(
                    "오래된 근거",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.labelMedium,
                )
            }
            if (details.effective?.hasConflict == true) {
                Text(
                    "근거가 서로 충돌합니다. 대안 ${details.effective.alternatives.size}개",
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.labelMedium,
                    modifier = Modifier.semantics {
                        contentDescription = "${details.key} capability 근거 충돌"
                    },
                )
                details.effective.alternatives.forEachIndexed { index, alternative ->
                    CapabilityObservationDetails("대안 ${index + 1}", alternative)
                }
            }
        }
    }
}

@Composable
private fun CapabilityObservationDetails(
    label: String,
    observation: CapabilityObservation,
) {
    Text(
        "$label · ${capabilityValueLabel(observation)} · " +
            "${humanizeKey(observation.status)} · ${sourceLabel(observation.source)} · " +
            "신뢰도 ${humanizeKey(observation.confidence)}",
        style = MaterialTheme.typography.bodySmall,
    )
    Text(
        buildString {
            append("관측 ")
            append(observation.observedAt)
            observation.expiresAt?.let {
                append(" · 만료 ")
                append(it)
            }
            observation.evidenceRef?.let {
                append(" · 근거 ")
                append(it)
            }
        },
        style = MaterialTheme.typography.labelSmall,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
private fun ModelSyncCard(
    state: ModelSyncUiState,
    actionsEnabled: Boolean,
    onApprove: (String, String) -> Unit,
    onCancel: (String) -> Unit,
    onDismiss: () -> Unit,
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("model-sync-state"),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                "모델 및 기능 동기화",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.semantics { heading() },
            )
            ModelSyncStateContent(
                state = state,
                actionsEnabled = actionsEnabled,
                onApprove = onApprove,
                onCancel = onCancel,
            )
            if (state is ModelSyncUiState.Failed) {
                TextButton(
                    onClick = onDismiss,
                    enabled = actionsEnabled,
                    modifier = Modifier.align(Alignment.End),
                ) {
                    Text("닫기")
                }
            }
        }
    }
}

@Composable
private fun ModelSyncStateContent(
    state: ModelSyncUiState,
    actionsEnabled: Boolean,
    onApprove: (String, String) -> Unit,
    onCancel: (String) -> Unit,
) {
    when (state) {
        is ModelSyncUiState.MultipleActive -> {
            Text(
                "복구된 동기화 작업 ${state.jobs.size}개를 모두 정리해야 새 동기화를 시작할 수 있습니다.",
                color = MaterialTheme.colorScheme.error,
            )
            state.jobs.forEachIndexed { index, job ->
                if (index > 0) {
                    HorizontalDivider()
                }
                Text("작업 ${index + 1} · ${job.connectionId}")
                ModelSyncStateContent(
                    state = job,
                    actionsEnabled = actionsEnabled,
                    onApprove = onApprove,
                    onCancel = onCancel,
                )
            }
        }

        is ModelSyncUiState.Blocked -> {
            Text(state.message, color = MaterialTheme.colorScheme.error)
            OutlinedButton(
                onClick = { onCancel(state.jobId) },
                enabled = actionsEnabled,
                modifier = Modifier.testTag("cancel-blocked-model-sync-${state.jobId}"),
            ) {
                Text("손상된 동기화 취소")
            }
        }

        is ModelSyncUiState.Interrupted -> {
            Text(
                "이전 provider 요청이 중단되었습니다.",
                color = MaterialTheme.colorScheme.error,
            )
            Text(
                "자격증명이 필요한 네트워크 요청은 자동으로 재개되지 않습니다. " +
                    "중단 작업을 취소한 뒤 모델 새로고침을 직접 다시 시작해 주세요.",
            )
            OutlinedButton(
                onClick = { onCancel(state.jobId) },
                enabled = actionsEnabled,
                modifier = Modifier.testTag(
                    "cancel-interrupted-model-sync-${state.jobId}",
                ),
            ) {
                Text("중단 작업 취소")
            }
        }

        is ModelSyncUiState.Running -> {
            DiscoveryProgressContent(state.progress)
            if (state.jobId.isNotBlank()) {
                OutlinedButton(
                    onClick = { onCancel(state.jobId) },
                    enabled = actionsEnabled,
                    modifier = Modifier.testTag("cancel-model-sync"),
                ) {
                    Text("동기화 취소")
                }
            }
        }

        is ModelSyncUiState.AwaitingReview -> {
            Text("적용 전 변경 검토")
            Text("대상: ${state.targetSummary}")
            state.addedModels.forEach { Text("+ 새 모델 $it") }
            state.changedModels.forEach { Text("~ 변경 $it") }
            state.missingModels.forEach { Text("! 이번 조회에서 보이지 않음 $it") }
            state.capabilityChanges.forEach { Text("~ capability 관측 $it") }
            state.initialPresets.forEach { Text("+ 초기 preset $it") }
            state.routesRequiringPresetConfiguration.forEach {
                Text("! 승인 후 preset 설정 필요 $it")
            }
            state.provenance.forEach { Text("근거: $it") }
            Text("Review hash ${state.reviewHash}", style = MaterialTheme.typography.labelSmall)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(
                    onClick = { onCancel(state.jobId) },
                    enabled = actionsEnabled,
                    modifier = Modifier.testTag("cancel-model-sync-review"),
                ) {
                    Text(stringResource(R.string.cancel))
                }
                Button(
                    onClick = { onApprove(state.jobId, state.reviewHash) },
                    enabled = actionsEnabled,
                    modifier = Modifier.testTag("approve-model-sync"),
                ) {
                    Text("변경 적용")
                }
            }
        }

        is ModelSyncUiState.Failed -> Text(
            state.message,
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.semantics { liveRegion = LiveRegionMode.Assertive },
        )
    }
}

@Composable
private fun PresetEditorCard(
    editor: PresetEditor,
    reviewPrepared: Boolean,
    controls: PresetControls?,
    credentialBearingConnection: Boolean,
    enabled: Boolean,
    onChange: (PresetEditor) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("preset-editor"),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceContainerHigh,
        ),
    ) {
        Column(
            modifier = Modifier.padding(18.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text(
                if (editor.isExisting) "Preset 편집" else "새 Preset",
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
            OutlinedTextField(
                value = editor.displayName,
                onValueChange = { onChange(editor.copy(displayName = it)) },
                enabled = enabled,
                label = { Text("Preset 이름") },
                singleLine = true,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("preset-name"),
            )

            Text("표시할 파라미터", style = MaterialTheme.typography.titleSmall)
            ChoiceChips(
                choices = listOf(
                    UiParameterLevel.Basic to "기본",
                    UiParameterLevel.Advanced to "고급",
                    UiParameterLevel.Expert to "전문가",
                ),
                selected = editor.visibleLevel,
                enabled = enabled,
                tagPrefix = "parameter-level",
                onSelect = { onChange(editor.copy(visibleLevel = it)) },
            )
            editor.parameterSpecs
                .filter { it.level.ordinal <= editor.visibleLevel.ordinal }
                .filter { isParameterVisible(it, editor.explicitValues) }
                .forEach { spec ->
                    ParameterEditor(
                        spec = spec,
                        value = editor.explicitValues[spec.id],
                        enabled = enabled,
                        onValue = { value ->
                            onChange(
                                editor.copy(
                                    explicitValues = if (value == null) {
                                        editor.explicitValues - spec.id
                                    } else {
                                        editor.explicitValues + (spec.id to value)
                                    },
                                ),
                            )
                        },
                    )
                }

            if (controls == null) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    CircularProgressIndicator()
                    Text("Route별 추론 및 cache 제어 확인 중")
                }
            } else {
                val reasoning = controls.reasoning
                if (reasoning.state != "hidden") {
                    HorizontalDivider()
                    Text(
                        "추론",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.semantics { heading() },
                    )
                    ChoiceChips(
                        choices = reasoning.allowedModes.map { it to humanizeKey(it) },
                        selected = editor.reasoningMode,
                        enabled = enabled,
                        tagPrefix = "reasoning-mode",
                        onSelect = { mode ->
                            onChange(
                                editor.copy(
                                    reasoningMode = mode,
                                    reasoningEffort = null,
                                    reasoningBudgetTokens = "",
                                    reasoningSummary = when (mode) {
                                        "disabled" -> "disabled"
                                        else -> "provider_default"
                                    },
                                    preserveOpaqueReasoningState =
                                        editor.preserveOpaqueReasoningState &&
                                            reasoning.preserveOpaqueState &&
                                            !credentialBearingConnection &&
                                            mode != "disabled",
                                ),
                            )
                        },
                    )
                    if (reasoning.effortField != "hidden") {
                        Text(
                            "추론 effort" +
                                if (reasoning.effortField == "required") " (필수)" else "",
                            style = MaterialTheme.typography.titleSmall,
                        )
                        ChoiceChips(
                            choices = (
                                if (reasoning.effortField == "required") {
                                    emptyList()
                                } else {
                                    listOf(null to "Provider 기본값")
                                }
                                ) +
                                reasoning.allowedEfforts.map {
                                    it to humanizeKey(it)
                                },
                            selected = editor.reasoningEffort,
                            enabled = enabled,
                            tagPrefix = "reasoning-effort",
                            onSelect = {
                                onChange(editor.copy(reasoningEffort = it))
                            },
                        )
                    }
                    if (reasoning.budgetField != "hidden") {
                        OutlinedTextField(
                            value = editor.reasoningBudgetTokens,
                            onValueChange = { value ->
                                if (value.all(Char::isDigit)) {
                                    onChange(editor.copy(reasoningBudgetTokens = value))
                                }
                            },
                            enabled = enabled,
                            label = {
                                Text(
                                    "추론 토큰 예산" +
                                        if (reasoning.budgetField == "required") {
                                            " (필수)"
                                        } else {
                                            ""
                                        },
                                )
                            },
                            supportingText = {
                                Text(
                                    listOfNotNull(
                                        reasoning.minimumBudgetTokens?.let { "min $it" },
                                        reasoning.maximumBudgetTokens?.let { "max $it" },
                                    ).joinToString(" · "),
                                )
                            },
                            keyboardOptions =
                                KeyboardOptions(keyboardType = KeyboardType.Number),
                            singleLine = true,
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag("reasoning-budget"),
                        )
                    }
                    if (reasoning.summaryField != "hidden") {
                        Text(
                            "추론 요약" +
                                if (reasoning.summaryField == "required") " (필수)" else "",
                            style = MaterialTheme.typography.titleSmall,
                        )
                        ChoiceChips(
                            choices = reasoning.allowedSummaries
                                .filterNot {
                                    reasoning.summaryField == "required" &&
                                        it == "provider_default"
                                }
                                .map { it to humanizeKey(it) },
                            selected = editor.reasoningSummary,
                            enabled = enabled,
                            tagPrefix = "reasoning-summary",
                            onSelect = {
                                onChange(editor.copy(reasoningSummary = it))
                            },
                        )
                    }
                    if (
                        editor.reasoningMode != "disabled" &&
                        reasoning.preserveOpaqueState &&
                        !credentialBearingConnection
                    ) {
                        val opaqueStateAvailable = reasoning.preserveOpaqueState
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Checkbox(
                                checked = editor.preserveOpaqueReasoningState &&
                                    opaqueStateAvailable,
                                onCheckedChange = {
                                    if (opaqueStateAvailable) {
                                        onChange(
                                            editor.copy(
                                                preserveOpaqueReasoningState = it,
                                            ),
                                        )
                                    }
                                },
                                enabled = enabled && opaqueStateAvailable,
                                modifier = Modifier
                                    .testTag("opaque-reasoning-state")
                                    .semantics {
                                        contentDescription =
                                            "같은 provider route model의 opaque reasoning state 유지"
                                    },
                            )
                            Text(
                                "같은 provider·route·model에서 opaque reasoning state 유지",
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                    reasoning.issues.forEach {
                        Text(
                            it.message,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }

                val cache = controls.promptCache
                if (cache.state != "hidden") {
                    HorizontalDivider()
                    Text(
                        "Prompt cache",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.semantics { heading() },
                    )
                    ChoiceChips(
                        choices = cache.allowedModes.map { it to humanizeKey(it) },
                        selected = editor.promptCacheMode,
                        enabled = enabled,
                        tagPrefix = "cache-mode",
                        onSelect = { mode ->
                            onChange(
                                editor.copy(
                                    promptCacheMode = mode,
                                    promptCacheTtl = "provider_default",
                                    promptCacheCustomTtlSeconds = "",
                                    promptCacheContextReference =
                                        editor.promptCacheContextReference
                                            .takeIf { mode == "explicit_context" }
                                            .orEmpty(),
                                ),
                            )
                        },
                    )
                    if (cache.ttlField != "hidden") {
                        Text(
                            "Cache TTL" +
                                if (cache.ttlField == "required") " (필수)" else "",
                            style = MaterialTheme.typography.titleSmall,
                        )
                        ChoiceChips(
                            choices = (
                                cache.allowedTtls +
                                    if (cache.supportsCustomTtl) {
                                        listOf("custom_seconds")
                                    } else {
                                        emptyList()
                                    }
                                )
                                .distinct()
                                .filterNot {
                                    cache.ttlField == "required" &&
                                        it == "provider_default"
                                }
                                .map { it to humanizeKey(it) },
                            selected = editor.promptCacheTtl,
                            enabled = enabled,
                            tagPrefix = "cache-ttl",
                            onSelect = {
                                onChange(
                                    editor.copy(
                                        promptCacheTtl = it,
                                        promptCacheCustomTtlSeconds =
                                            editor.promptCacheCustomTtlSeconds
                                                .takeIf { _ -> it == "custom_seconds" }
                                                .orEmpty(),
                                    ),
                                )
                            },
                        )
                        if (editor.promptCacheTtl == "custom_seconds") {
                            OutlinedTextField(
                                value = editor.promptCacheCustomTtlSeconds,
                                onValueChange = { value ->
                                    if (value.all(Char::isDigit)) {
                                        onChange(
                                            editor.copy(
                                                promptCacheCustomTtlSeconds = value,
                                            ),
                                        )
                                    }
                                },
                                enabled = enabled,
                                label = { Text("TTL 초") },
                                supportingText = {
                                    Text(
                                        listOfNotNull(
                                            cache.minimumCustomTtlSeconds?.let {
                                                "min $it"
                                            },
                                            cache.maximumCustomTtlSeconds?.let {
                                                "max $it"
                                            },
                                        ).joinToString(" · "),
                                    )
                                },
                                keyboardOptions =
                                    KeyboardOptions(keyboardType = KeyboardType.Number),
                                singleLine = true,
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .testTag("cache-custom-ttl"),
                            )
                        }
                    }
                    if (cache.contextReferenceField != "hidden") {
                        OutlinedTextField(
                            value = editor.promptCacheContextReference,
                            onValueChange = {
                                onChange(editor.copy(promptCacheContextReference = it))
                            },
                            enabled = enabled,
                            label = {
                                Text(
                                    "Cached context resource" +
                                        if (cache.contextReferenceField == "required") {
                                            " (필수)"
                                        } else {
                                            ""
                                        },
                                )
                            },
                            supportingText = { Text("예: cachedContents/my-context") },
                            singleLine = true,
                            modifier = Modifier
                                .fillMaxWidth()
                                .testTag("cache-context-reference"),
                        )
                    }
                    cache.issues.forEach {
                        Text(
                            it.message,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                }
            }

            OutlinedCard(modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(12.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text("Redacted request preview", fontWeight = FontWeight.SemiBold)
                    Text(
                        editor.redactedRequestPreview
                            ?: "코어 preview가 제공되지 않아 요청을 추측해 표시하지 않습니다.",
                        style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.testTag("preset-redacted-preview"),
                    )
                }
            }
            editor.validationMessages.distinct().forEach {
                Text(
                    it,
                    color = MaterialTheme.colorScheme.error,
                    style = MaterialTheme.typography.bodySmall,
                )
            }
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End),
            ) {
                TextButton(onClick = onCancel, enabled = enabled) {
                    Text(stringResource(R.string.cancel))
                }
                Button(
                    onClick = onSave,
                    enabled = enabled &&
                        editor.validationMessages.isEmpty() &&
                        controls?.let {
                            validatePresetControls(
                                editor,
                                it,
                                credentialBearingConnection,
                            ).isEmpty()
                        } == true,
                    modifier = Modifier.testTag("save-preset"),
                ) {
                    Text(
                        if (reviewPrepared) {
                            "확인 후 저장"
                        } else {
                            "검증 및 미리보기"
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun ParameterEditor(
    spec: ParameterSpec,
    value: ParameterLiteral?,
    enabled: Boolean,
    onValue: (ParameterLiteral?) -> Unit,
) {
    val required =
        spec.defaultMode == dev.lorepia.app.bridge.ParameterDefaultMode.ExplicitRequired
    OutlinedCard(
        modifier = Modifier
            .fillMaxWidth()
            .testTag("parameter-${spec.id}"),
    ) {
        Column(
            modifier = Modifier.padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        humanizeKey(spec.labelKey) + if (required) " (필수)" else "",
                        fontWeight = FontWeight.SemiBold,
                    )
                    spec.descriptionKey?.let {
                        Text(
                            humanizeKey(it),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                if (!required) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            "Provider 기본값",
                            style = MaterialTheme.typography.labelSmall,
                        )
                        Switch(
                            checked = value == null,
                            onCheckedChange = { inherit ->
                                onValue(if (inherit) null else defaultEditorLiteral(spec))
                            },
                            enabled = enabled,
                            modifier = Modifier
                                .testTag("parameter-inherit-${spec.id}")
                                .semantics {
                                    contentDescription =
                                        "${humanizeKey(spec.labelKey)} provider 기본값 사용"
                                },
                        )
                    }
                }
            }
            if (value != null) {
                ParameterLiteralControl(spec, value, enabled, onValue)
            } else if (required) {
                Text(
                    "Provider 값을 추측하지 않습니다. 값을 직접 선택해 주세요.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error,
                )
                RequiredParameterLiteralControl(spec, enabled, onValue)
            } else {
                Text(
                    "요청에서 이 필드를 생략합니다.",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
private fun ParameterLiteralControl(
    spec: ParameterSpec,
    value: ParameterLiteral,
    enabled: Boolean,
    onValue: (ParameterLiteral?) -> Unit,
) {
    when {
        spec.valueType == ParameterType.Boolean && value is ParameterLiteral.Boolean -> {
            Switch(
                checked = value.value,
                onCheckedChange = { onValue(ParameterLiteral.Boolean(it)) },
                enabled = enabled,
                modifier = Modifier
                    .testTag("parameter-value-${spec.id}")
                    .semantics {
                        contentDescription = humanizeKey(spec.labelKey)
                    },
            )
        }

        spec.valueType == ParameterType.Integer && value is ParameterLiteral.Integer -> {
            NumericParameterField(
                text = value.value.toString(),
                spec = spec,
                enabled = enabled,
                decimal = false,
                tag = "parameter-value-${spec.id}",
            ) { parsed ->
                val number = parsed.toLongOrNull()
                if (number != null) {
                    onValue(ParameterLiteral.Integer(number))
                } else if (parsed.isBlank() || parsed == "-") {
                    onValue(null)
                }
            }
        }

        spec.valueType == ParameterType.Number && value is ParameterLiteral.Number -> {
            NumericParameterField(
                text = value.value.toString(),
                spec = spec,
                enabled = enabled,
                decimal = true,
                tag = "parameter-value-${spec.id}",
            ) { parsed ->
                val number = parsed.toDoubleOrNull()
                if (number != null) {
                    onValue(ParameterLiteral.Number(number))
                } else if (parsed.isBlank() || parsed == "-") {
                    onValue(null)
                }
            }
        }

        spec.valueType == ParameterType.Enum && value is ParameterLiteral.EnumValue -> {
            spec.allowedValues.forEachIndexed { index, choice ->
                val enum = choice.value as? ParameterLiteral.EnumValue
                    ?: return@forEachIndexed
                FilterChip(
                    selected = enum.value == value.value,
                    onClick = { onValue(enum) },
                    enabled = enabled,
                    label = { Text(humanizeKey(choice.labelKey)) },
                    modifier = Modifier.testTag("parameter-value-${spec.id}-$index"),
                )
            }
        }

        spec.valueType == ParameterType.ToolPolicy &&
            value is ParameterLiteral.ToolPolicyValue -> {
            listOf(ToolPolicy.None, ToolPolicy.Auto, ToolPolicy.Required)
                .forEachIndexed { index, policy ->
                    FilterChip(
                        selected = policy == value.value,
                        onClick = { onValue(ParameterLiteral.ToolPolicyValue(policy)) },
                        enabled = enabled,
                        label = { Text(policy.name) },
                        modifier = Modifier.testTag("parameter-value-${spec.id}-$index"),
                    )
                }
        }

        else -> {
            val text = literalText(value)
            var editorText by remember(spec.id, value) { mutableStateOf(text) }
            OutlinedTextField(
                value = editorText,
                onValueChange = { changed ->
                    editorText = changed
                    if (spec.defaultMode ==
                        dev.lorepia.app.bridge.ParameterDefaultMode.ExplicitRequired &&
                        changed.isBlank()
                    ) {
                        onValue(null)
                    } else {
                        parseTextLiteral(spec.valueType, changed)?.let(onValue)
                    }
                },
                enabled = enabled,
                label = {
                    Text(
                        if (spec.valueType in setOf(
                                ParameterType.StringList,
                                ParameterType.StopSequenceList,
                            )
                        ) {
                            "쉼표로 구분"
                        } else {
                            humanizeKey(spec.labelKey)
                        },
                    )
                },
                minLines = if (spec.valueType == ParameterType.JsonSchema) 4 else 1,
                singleLine = spec.valueType != ParameterType.JsonSchema,
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("parameter-value-${spec.id}"),
            )
        }
    }
}

@Composable
private fun RequiredParameterLiteralControl(
    spec: ParameterSpec,
    enabled: Boolean,
    onValue: (ParameterLiteral?) -> Unit,
) {
    when (spec.valueType) {
        ParameterType.Boolean -> {
            listOf(false to "끔", true to "켬").forEachIndexed { index, (value, label) ->
                FilterChip(
                    selected = false,
                    onClick = { onValue(ParameterLiteral.Boolean(value)) },
                    enabled = enabled,
                    label = { Text(label) },
                    modifier = Modifier.testTag("parameter-value-${spec.id}-$index"),
                )
            }
        }

        ParameterType.Enum -> {
            spec.allowedValues.forEachIndexed { index, choice ->
                FilterChip(
                    selected = false,
                    onClick = { onValue(choice.value) },
                    enabled = enabled,
                    label = { Text(humanizeKey(choice.labelKey)) },
                    modifier = Modifier.testTag("parameter-value-${spec.id}-$index"),
                )
            }
        }

        ParameterType.ToolPolicy -> {
            listOf(ToolPolicy.None, ToolPolicy.Auto, ToolPolicy.Required)
                .forEachIndexed { index, policy ->
                    FilterChip(
                        selected = false,
                        onClick = {
                            onValue(ParameterLiteral.ToolPolicyValue(policy))
                        },
                        enabled = enabled,
                        label = { Text(policy.name) },
                        modifier = Modifier.testTag("parameter-value-${spec.id}-$index"),
                    )
                }
        }

        else -> {
            var editorText by remember(spec.id) { mutableStateOf("") }
            OutlinedTextField(
                value = editorText,
                onValueChange = { changed ->
                    val accepted = when (spec.valueType) {
                        ParameterType.Integer ->
                            changed.isEmpty() || changed == "-" ||
                                changed.toLongOrNull() != null
                        ParameterType.Number ->
                            changed.isEmpty() || changed == "-" ||
                                changed.toDoubleOrNull() != null
                        else -> true
                    }
                    if (accepted) {
                        editorText = changed
                        val parsed = when (spec.valueType) {
                            ParameterType.Integer -> changed.toLongOrNull()?.let {
                                ParameterLiteral.Integer(it)
                            }
                            ParameterType.Number -> changed.toDoubleOrNull()?.let {
                                ParameterLiteral.Number(it)
                            }
                            else -> parseTextLiteral(spec.valueType, changed)
                        }
                        val meaningful = when (parsed) {
                            is ParameterLiteral.StringValue -> parsed.value.isNotBlank()
                            is ParameterLiteral.StringList -> parsed.values.isNotEmpty()
                            is ParameterLiteral.JsonSchema -> parsed.value.isNotBlank()
                            is ParameterLiteral.StopSequenceList -> parsed.values.isNotEmpty()
                            null -> false
                            else -> true
                        }
                        if (meaningful) onValue(parsed)
                    }
                },
                enabled = enabled,
                label = { Text(humanizeKey(spec.labelKey) + " (필수)") },
                minLines = if (spec.valueType == ParameterType.JsonSchema) 4 else 1,
                singleLine = spec.valueType != ParameterType.JsonSchema,
                keyboardOptions = KeyboardOptions(
                    keyboardType = when (spec.valueType) {
                        ParameterType.Integer -> KeyboardType.Number
                        ParameterType.Number -> KeyboardType.Decimal
                        else -> KeyboardType.Text
                    },
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .testTag("parameter-value-${spec.id}"),
            )
        }
    }
}

@Composable
private fun NumericParameterField(
    text: String,
    spec: ParameterSpec,
    enabled: Boolean,
    decimal: Boolean,
    tag: String,
    onText: (String) -> Unit,
) {
    var editorText by remember(spec.id, text) { mutableStateOf(text) }
    OutlinedTextField(
        value = editorText,
        onValueChange = { value ->
            val parsed = if (decimal) value.toDoubleOrNull() else value.toLongOrNull()
            if (value.isEmpty() || value == "-" || parsed != null) {
                editorText = value
                onText(value)
            }
        },
        enabled = enabled,
        label = { Text(humanizeKey(spec.labelKey)) },
        supportingText = {
            Text(
                listOfNotNull(
                    spec.minimum?.let { "min $it" },
                    spec.maximum?.let { "max $it" },
                    spec.step?.let { "step $it" },
                ).joinToString(" · "),
            )
        },
        keyboardOptions = KeyboardOptions(
            keyboardType = if (decimal) KeyboardType.Decimal else KeyboardType.Number,
        ),
        singleLine = true,
        modifier = Modifier
            .fillMaxWidth()
            .testTag(tag),
    )
}

@Composable
private fun <T> ChoiceChips(
    choices: List<Pair<T, String>>,
    selected: T,
    enabled: Boolean,
    tagPrefix: String,
    onSelect: (T) -> Unit,
) {
    choices.forEachIndexed { index, (value, label) ->
        FilterChip(
            selected = value == selected,
            onClick = { onSelect(value) },
            enabled = enabled,
            label = { Text(label) },
            modifier = Modifier.testTag("$tagPrefix-$index"),
        )
    }
}

private fun literalText(value: ParameterLiteral): String = when (value) {
    is ParameterLiteral.StringValue -> value.value
    is ParameterLiteral.StringList -> value.values.joinToString(", ")
    is ParameterLiteral.JsonSchema -> value.value
    is ParameterLiteral.StopSequenceList -> value.values.joinToString(", ")
    is ParameterLiteral.EnumValue -> value.value
    is ParameterLiteral.Integer -> value.value.toString()
    is ParameterLiteral.Number -> value.value.toString()
    is ParameterLiteral.Boolean -> value.value.toString()
    is ParameterLiteral.ToolPolicyValue -> value.value.name
}

private fun parseTextLiteral(type: ParameterType, value: String): ParameterLiteral? = when (type) {
    ParameterType.String -> ParameterLiteral.StringValue(value)
    ParameterType.StringList -> ParameterLiteral.StringList(splitEditorList(value))
    ParameterType.JsonSchema -> ParameterLiteral.JsonSchema(value)
    ParameterType.StopSequenceList -> ParameterLiteral.StopSequenceList(splitEditorList(value))
    else -> null
}

private fun splitEditorList(value: String): List<String> =
    value.split(',').map(String::trim).filter(String::isNotEmpty)

@Composable
private fun ReviewRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text(
            label,
            modifier = Modifier.weight(0.38f),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            style = MaterialTheme.typography.bodySmall,
        )
        Text(
            value,
            modifier = Modifier.weight(0.62f),
            style = MaterialTheme.typography.bodySmall,
        )
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
private fun StatusRow(label: String, value: String) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
    ) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, fontWeight = FontWeight.Medium)
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
            .padding(padding)
            .testTag("settings-load-error"),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            text = "설정을 불러오지 못했습니다.",
            style = MaterialTheme.typography.titleMedium,
        )
        Spacer(Modifier.height(12.dp))
        Button(onClick = onRefresh) {
            Text(stringResource(R.string.retry))
        }
    }
}

@Composable
private fun availabilityLabel(value: Boolean): String =
    stringResource(if (value) R.string.available else R.string.unavailable)

@Composable
private fun availabilityColor(status: String) = when (status) {
    "available" -> MaterialTheme.colorScheme.primary
    "deprecated", "missing_temporarily" -> MaterialTheme.colorScheme.tertiary
    "retired", "access_denied" -> MaterialTheme.colorScheme.error
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

@Composable
private fun capabilityStatusColor(status: String?) = when (status) {
    "verified" -> MaterialTheme.colorScheme.primary
    "unsupported" -> MaterialTheme.colorScheme.error
    "documented", "inferred", "conditional" -> MaterialTheme.colorScheme.tertiary
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}

private fun capabilityValueLabel(observation: CapabilityObservation): String =
    when (observation.value.kind) {
        "boolean" -> observation.value.booleanValue.toString()
        "integer" -> observation.value.integerValue.toString()
        "enum_values" -> observation.value.enumValues.joinToString()
        "structured" -> "구조화된 provider metadata"
        else -> "알 수 없는 값"
    }

private fun sourceLabel(source: String): String = when (source) {
    "provider_api" -> "Provider API"
    "official_documentation" -> "공식 문서"
    "signed_catalog" -> "서명 카탈로그"
    "signed_lorepia_catalog" -> "서명 LorePia 카탈로그"
    "capability_probe" -> "실제 capability 검사"
    "user_override" -> "사용자 override"
    "llm_inference" -> "LLM 추론"
    else -> humanizeKey(source)
}

private fun DiscoveryProbeBudget.aggregateCeilingLabel(): String {
    val requests = BigInteger(maxRequests.toString())
    fun total(perRequest: ULong): BigInteger =
        requests.multiply(BigInteger(perRequest.toString()))
    val calls = requests.multiply(BigInteger(maxCallsPerRequest.toString()))
    return "$maxRequests requests · $calls calls · " +
        "${total(maxTotalTokensPerRequest)} tokens · " +
        "${total(maxOutputTokensPerRequest)} output tokens · " +
        "${total(maxDurationMillisPerRequest)} ms · " +
        "${total(maxCostMicroUsdPerRequest)} µUSD"
}

private fun authBindingLabel(
    binding: dev.lorepia.app.bridge.AuthBinding,
): String = when (binding) {
    dev.lorepia.app.bridge.AuthBinding.None -> "없음"
    dev.lorepia.app.bridge.AuthBinding.BearerHeader -> "Bearer header"
    is dev.lorepia.app.bridge.AuthBinding.HeaderApiKey ->
        "API key header ${binding.headerName}"
}

private fun humanizeKey(value: String): String =
    value.replace('_', ' ').replaceFirstChar(Char::uppercase)
