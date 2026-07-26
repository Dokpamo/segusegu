package dev.lorepia.app.feature.chat

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import dev.lorepia.app.bridge.CoreClient

@Composable
fun ChatRoute(
    coreClient: CoreClient,
    contentPadding: PaddingValues,
    onOpenLibrary: () -> Unit,
) {
    val viewModel: ChatViewModel = viewModel(
        factory = ChatViewModel.factory(coreClient),
    )
    val uiState by viewModel.uiState.collectAsStateWithLifecycle()

    ChatScreen(
        uiState = uiState,
        onOpenLibrary = onOpenLibrary,
        onRetry = viewModel::retry,
        contentPadding = contentPadding,
    )
}
