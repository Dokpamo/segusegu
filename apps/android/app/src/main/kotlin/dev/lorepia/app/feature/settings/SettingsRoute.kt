package dev.lorepia.app.feature.settings

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.platform.credentials.CredentialStore

@Composable
fun SettingsRoute(
    coreClient: CoreClient,
    credentialStore: CredentialStore,
    contentPadding: PaddingValues,
) {
    val viewModel: SettingsViewModel = viewModel(
        factory = SettingsViewModel.factory(coreClient, credentialStore),
    )
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    SettingsScreen(
        uiState = uiState,
        onRefresh = viewModel::refresh,
        onBeginAddProfile = viewModel::beginAddProfile,
        onBeginEditProfile = viewModel::beginEditProfile,
        onUpdateEditor = viewModel::updateEditor,
        onCancelEditor = viewModel::cancelEditor,
        onSaveProfile = viewModel::saveProfile,
        onSelectProfile = viewModel::selectProfile,
        onDeleteProfile = viewModel::deleteProfile,
        onClearCredential = viewModel::clearCredential,
        onPreservePartialChanged = viewModel::setPreservePartialGenerations,
        contentPadding = contentPadding,
    )
}
