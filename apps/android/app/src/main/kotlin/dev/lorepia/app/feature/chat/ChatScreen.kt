package dev.lorepia.app.feature.chat

import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.AddComment
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
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
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import dev.lorepia.app.R
import dev.lorepia.app.bridge.ChatMessage
import dev.lorepia.app.bridge.ConversationSummary

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    uiState: ChatUiState,
    onOpenLibrary: () -> Unit,
    onOpenSettings: () -> Unit,
    onRetry: () -> Unit,
    onSelectConversation: (String) -> Unit,
    onNewConversation: () -> Unit,
    onSend: (String) -> Unit,
    onCancel: () -> Unit,
    contentPadding: PaddingValues,
    modifier: Modifier = Modifier,
) {
    val title = (uiState as? ChatUiState.Ready)?.character?.name
        ?: (uiState as? ChatUiState.ChooseConversation)?.character?.name
        ?: stringResource(R.string.chat_title)
    Scaffold(
        modifier = modifier,
        topBar = {
            TopAppBar(
                windowInsets = WindowInsets(0, 0, 0, 0),
                title = {
                    Text(
                        text = title,
                        modifier = Modifier.semantics { heading() },
                    )
                },
            )
        },
    ) { scaffoldPadding ->
        val bodyPadding = PaddingValues(
            start = 20.dp,
            top = scaffoldPadding.calculateTopPadding() + 8.dp,
            end = 20.dp,
            bottom = contentPadding.calculateBottomPadding() + 12.dp,
        )
        when (uiState) {
            ChatUiState.Loading -> LoadingChat(scaffoldPadding, contentPadding)
            is ChatUiState.Empty -> EmptyChat(onOpenLibrary, scaffoldPadding, contentPadding)
            is ChatUiState.ChooseConversation -> ConversationChooser(
                state = uiState,
                onSelectConversation = onSelectConversation,
                onNewConversation = onNewConversation,
                onOpenLibrary = onOpenLibrary,
                contentPadding = bodyPadding,
            )

            is ChatUiState.Ready -> ActiveChat(
                state = uiState,
                onOpenSettings = onOpenSettings,
                onSend = onSend,
                onCancel = onCancel,
                contentPadding = bodyPadding,
            )

            is ChatUiState.Error -> ChatError(onRetry, scaffoldPadding, contentPadding)
        }
    }
}

@Composable
private fun LoadingChat(
    scaffoldPadding: PaddingValues,
    contentPadding: PaddingValues,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(scaffoldPadding)
            .padding(contentPadding),
        contentAlignment = Alignment.Center,
    ) {
        CircularProgressIndicator()
    }
}

@Composable
private fun EmptyChat(
    onOpenLibrary: () -> Unit,
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
            text = stringResource(R.string.chat_empty_title),
            style = MaterialTheme.typography.headlineSmall,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        Text(
            text = stringResource(R.string.chat_empty_body),
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(top = 8.dp, bottom = 16.dp),
        )
        Button(onClick = onOpenLibrary) {
            Text(stringResource(R.string.go_to_library))
        }
    }
}

@Composable
private fun ConversationChooser(
    state: ChatUiState.ChooseConversation,
    onSelectConversation: (String) -> Unit,
    onNewConversation: () -> Unit,
    onOpenLibrary: () -> Unit,
    contentPadding: PaddingValues,
) {
    LazyColumn(
        modifier = Modifier.fillMaxSize(),
        contentPadding = contentPadding,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        item {
            Text(
                text = if (state.character == null) {
                    stringResource(R.string.choose_conversation)
                } else {
                    stringResource(R.string.continue_or_new_conversation)
                },
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.semantics { heading() },
            )
        }
        items(
            items = state.conversations,
            key = ConversationSummary::id,
        ) { conversation ->
            Card(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { onSelectConversation(conversation.id) },
            ) {
                Column(
                    modifier = Modifier.padding(18.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    Text(
                        text = conversation.title,
                        style = MaterialTheme.typography.titleMedium,
                    )
                    Text(
                        text = conversation.updatedAt,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }
        }
        item {
            if (state.character != null) {
                Button(
                    onClick = onNewConversation,
                    enabled = !state.isCreating,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (state.isCreating) {
                        CircularProgressIndicator(
                            modifier = Modifier
                                .padding(end = 8.dp)
                                .height(18.dp),
                            strokeWidth = 2.dp,
                        )
                    } else {
                        androidx.compose.material3.Icon(
                            imageVector = Icons.Outlined.AddComment,
                            contentDescription = null,
                            modifier = Modifier.padding(end = 8.dp),
                        )
                    }
                    Text(stringResource(R.string.new_conversation))
                }
            } else {
                OutlinedButton(
                    onClick = onOpenLibrary,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(stringResource(R.string.start_from_library))
                }
            }
        }
        if (state.error != null) {
            item {
                Text(
                    text = state.error.message ?: stringResource(R.string.request_failed),
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.semantics {
                        liveRegion = LiveRegionMode.Assertive
                    },
                )
            }
        }
    }
}

@Composable
private fun ActiveChat(
    state: ChatUiState.Ready,
    onOpenSettings: () -> Unit,
    onSend: (String) -> Unit,
    onCancel: () -> Unit,
    contentPadding: PaddingValues,
) {
    var draft by remember(state.conversation.id) { mutableStateOf("") }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(contentPadding),
    ) {
        if (state.selectedProvider == null) {
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(
                    modifier = Modifier.padding(16.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(
                        text = stringResource(R.string.provider_required),
                        color = MaterialTheme.colorScheme.error,
                    )
                    TextButton(onClick = onOpenSettings) {
                        Text(stringResource(R.string.open_settings))
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        } else {
            Text(
                text = stringResource(
                    R.string.using_provider,
                    state.selectedProvider.displayName,
                    state.selectedProvider.model,
                ),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(8.dp))
        }

        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            items(items = state.messages, key = ChatMessage::id) { message ->
                MessageBubble(message)
            }
            if (state.streamedText.isNotEmpty()) {
                item(key = "streaming") {
                    AssistantBubble(
                        text = state.streamedText,
                        status = stringResource(R.string.generating_response),
                    )
                }
            }
        }

        state.notice?.let { notice ->
            Text(
                text = notice,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 6.dp)
                    .semantics { liveRegion = LiveRegionMode.Assertive },
            )
        }

        if (state.activeGenerationId != null) {
            OutlinedButton(
                onClick = onCancel,
                enabled = !state.isCancelling,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    if (state.isCancelling) {
                        stringResource(R.string.cancelling_generation)
                    } else {
                        stringResource(R.string.cancel_generation)
                    },
                )
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(top = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                label = { Text(stringResource(R.string.message_input)) },
                enabled = state.activeGenerationId == null && !state.isSubmitting,
                maxLines = 5,
                modifier = Modifier.weight(1f),
            )
            Button(
                onClick = {
                    val outgoing = draft
                    draft = ""
                    onSend(outgoing)
                },
                enabled = state.canSend && draft.isNotBlank(),
            ) {
                Text(stringResource(R.string.send_message))
            }
        }
    }
}

@Composable
private fun MessageBubble(message: ChatMessage) {
    if (message.role == "user") {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End,
        ) {
            Surface(
                color = MaterialTheme.colorScheme.primaryContainer,
                shape = MaterialTheme.shapes.large,
                modifier = Modifier.widthIn(max = 320.dp),
            ) {
                Text(
                    text = message.content,
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                )
            }
        }
    } else if (message.content.isNotBlank()) {
        AssistantBubble(
            text = message.content,
            status = if (message.status == "cancelled") {
                stringResource(R.string.partial_response)
            } else {
                null
            },
        )
    }
}

@Composable
private fun AssistantBubble(
    text: String,
    status: String?,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.Start,
    ) {
        Surface(
            color = MaterialTheme.colorScheme.surfaceVariant,
            shape = MaterialTheme.shapes.large,
            modifier = Modifier.widthIn(max = 320.dp),
        ) {
            Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp)) {
                Text(text = text)
                status?.let {
                    Text(
                        text = it,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 4.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun ChatError(
    onRetry: () -> Unit,
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
            text = stringResource(R.string.core_unavailable_title),
            style = MaterialTheme.typography.titleLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier.semantics { heading() },
        )
        TextButton(onClick = onRetry) {
            androidx.compose.material3.Icon(
                imageVector = Icons.Outlined.Refresh,
                contentDescription = null,
            )
            Text(
                text = stringResource(R.string.retry),
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
}
