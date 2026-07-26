package dev.lorepia.app.feature.settings

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.lorepia.app.bridge.CoreClient

@Composable
fun SettingsRoute(
    coreClient: CoreClient,
    contentPadding: PaddingValues,
) {
    val viewModel: SettingsViewModel = viewModel(
        factory = SettingsViewModel.factory(coreClient),
    )
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    SettingsScreen(
        uiState = uiState,
        onRefresh = viewModel::refresh,
        contentPadding = contentPadding,
    )
}
