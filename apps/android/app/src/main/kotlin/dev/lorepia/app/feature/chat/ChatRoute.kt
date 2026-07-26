package dev.lorepia.app.feature.chat

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.platform.credentials.CredentialStore

@Composable
fun ChatRoute(
    coreClient: CoreClient,
    credentialStore: CredentialStore,
    characterId: String?,
    conversationId: String?,
    contentPadding: PaddingValues,
    onOpenLibrary: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenConversation: (String) -> Unit,
) {
    val viewModel: ChatViewModel = viewModel(
        key = "chat:${characterId.orEmpty()}:${conversationId.orEmpty()}",
        factory = ChatViewModel.factory(
            coreClient = coreClient,
            credentialStore = credentialStore,
            characterId = characterId,
            conversationId = conversationId,
        ),
    )
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()
    DisposableEffect(viewModel) {
        viewModel.setRouteActive(true)
        onDispose {
            viewModel.setRouteActive(false)
        }
    }
    LaunchedEffect(Unit) {
        viewModel.refreshConfiguration()
    }

    ChatScreen(
        uiState = uiState,
        onOpenLibrary = onOpenLibrary,
        onOpenSettings = onOpenSettings,
        onRetry = viewModel::retry,
        onSelectConversation = onOpenConversation,
        onNewConversation = viewModel::startNewConversation,
        onSend = viewModel::send,
        onCancel = viewModel::cancel,
        contentPadding = contentPadding,
    )
}
