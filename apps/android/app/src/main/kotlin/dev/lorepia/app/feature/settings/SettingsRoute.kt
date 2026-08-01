package dev.lorepia.app.feature.settings

import android.content.ContentResolver
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.platform.credentials.CredentialStore
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val catalogDocumentLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        scope.launch {
            try {
                val bytes = withContext(Dispatchers.IO) {
                    readBoundedCatalogDocument(context.contentResolver, uri)
                }
                viewModel.prepareCatalogImport(bytes)
            } catch (error: Throwable) {
                viewModel.reportCatalogDocumentError(
                    error.message ?: "선택한 catalog 문서를 읽지 못했습니다.",
                )
            }
        }
    }
    val onCatalogAction: (ProviderCatalogUiAction) -> Unit = { action ->
        when (action) {
            ProviderCatalogUiAction.Refresh -> viewModel.refreshCatalog()
            ProviderCatalogUiAction.ChooseSignedDocument ->
                catalogDocumentLauncher.launch(
                    arrayOf("application/json", "application/octet-stream", "text/plain"),
                )
            ProviderCatalogUiAction.ActivateImport -> viewModel.activateCatalogImport()
            ProviderCatalogUiAction.CancelImport -> viewModel.cancelCatalogImport()
            is ProviderCatalogUiAction.PrepareRollback ->
                viewModel.prepareCatalogRollback(action.revision)
            ProviderCatalogUiAction.ActivateRollback -> viewModel.activateCatalogRollback()
            ProviderCatalogUiAction.CancelRollback -> viewModel.cancelCatalogRollback()
        }
    }

    SettingsScreen(
        uiState = uiState,
        onRefresh = viewModel::refresh,
        onBeginAddConnection = viewModel::beginAddConnection,
        onChooseSetupKind = viewModel::chooseSetupKind,
        onChooseKnownTemplate = viewModel::chooseKnownTemplate,
        onUpdateSetup = viewModel::updateSetup,
        onSubmitSetupDetails = viewModel::submitSetupDetails,
        onDiscoveryAction = viewModel::handleDiscoveryUiAction,
        onCatalogAction = onCatalogAction,
        onApproveCredentialOrigin = viewModel::approveCredentialOrigin,
        onCommitSetup = viewModel::commitSetup,
        onCancelSetup = viewModel::cancelSetup,
        onRetrySetup = viewModel::retrySetup,
        onBeginEditConnection = viewModel::beginEditConnection,
        onUpdateConnectionEditor = viewModel::updateConnectionEditor,
        onCancelConnectionEditor = viewModel::cancelConnectionEditor,
        onSaveConnectionEditor = viewModel::saveConnectionEditor,
        onDeleteConnection = viewModel::deleteConnection,
        onStartModelSync = viewModel::startModelSync,
        onApproveModelSync = viewModel::approveModelSync,
        onCancelModelSync = viewModel::cancelModelSync,
        onDismissModelSync = viewModel::dismissModelSync,
        onSelectGenerationPreset = viewModel::selectGenerationPreset,
        onBeginAddPreset = viewModel::beginAddPreset,
        onBeginEditPreset = viewModel::beginEditPreset,
        onUpdatePresetEditor = viewModel::updatePresetEditor,
        onCancelPresetEditor = viewModel::cancelPresetEditor,
        onSavePreset = viewModel::savePreset,
        onDeletePreset = viewModel::deletePreset,
        onPreservePartialChanged = viewModel::setPreservePartialGenerations,
        contentPadding = contentPadding,
    )
}

private fun readBoundedCatalogDocument(
    contentResolver: ContentResolver,
    uri: Uri,
): ByteArray {
    val stream = checkNotNull(contentResolver.openInputStream(uri)) {
        "선택한 catalog 문서를 열 수 없습니다."
    }
    return stream.use { input ->
        val output = ByteArrayOutputStream()
        val buffer = ByteArray(8 * 1024)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read < 0) break
            total += read
            require(total <= PROVIDER_CATALOG_MAX_DOCUMENT_BYTES) {
                "Catalog 문서는 최대 2 MiB까지 가져올 수 있습니다."
            }
            output.write(buffer, 0, read)
        }
        require(total > 0) { "빈 catalog 문서는 가져올 수 없습니다." }
        output.toByteArray()
    }
}
