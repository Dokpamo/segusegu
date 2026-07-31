package dev.lorepia.app.feature.chat

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.lorepia.app.bridge.ChatEvent
import dev.lorepia.app.bridge.ConversationSummary
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.platform.credentials.CredentialStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

class ChatViewModel(
    private val coreClient: CoreClient,
    private val credentialStore: CredentialStore,
    private val requestedCharacterId: String? = null,
    private val requestedConversationId: String? = null,
    private val pollIntervalMillis: Long = DEFAULT_POLL_INTERVAL_MILLIS,
    private val emptyBatchesBeforeReconcile: Int = DEFAULT_EMPTY_BATCHES_BEFORE_RECONCILE,
) : ViewModel() {
    private val _uiState = MutableStateFlow<ChatUiState>(ChatUiState.Loading)
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()
    private var loadJob: Job? = null
    private var pollingJob: Job? = null
    private var routeReconciliationJob: Job? = null
    private var supportedEventVersion: UInt = 2u
    private var lastSequence = 0uL
    private var routeActive = true

    init {
        require(emptyBatchesBeforeReconcile > 0) {
            "The empty batch reconciliation threshold must be positive."
        }
        load()
    }

    fun retry() {
        load()
    }

    fun refreshConfiguration() {
        val state = _uiState.value as? ChatUiState.Ready ?: return
        viewModelScope.launch {
            try {
                val settings = coreClient.getSettings()
                val profiles = coreClient.listProviderProfiles()
                val latest = _uiState.value as? ChatUiState.Ready ?: return@launch
                if (latest.conversation.id == state.conversation.id) {
                    _uiState.value = latest.copy(
                        providerProfiles = profiles,
                        selectedProvider = profiles.firstOrNull {
                            it.id == settings.selectedProviderProfileId
                        },
                    )
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                val latest = _uiState.value as? ChatUiState.Ready ?: return@launch
                _uiState.value = latest.copy(notice = error.userFacingMessage())
            }
        }
    }

    fun setRouteActive(active: Boolean) {
        routeActive = active
        routeReconciliationJob?.cancel()
        routeReconciliationJob = null
        if (active) {
            val state = _uiState.value as? ChatUiState.Ready
            val generationId = state?.activeGenerationId
            if (generationId != null) {
                routeReconciliationJob = viewModelScope.launch {
                    try {
                        reconcilePersistedGeneration(generationId)
                    } catch (cancellation: CancellationException) {
                        throw cancellation
                    } catch (error: Throwable) {
                        val latest = _uiState.value as? ChatUiState.Ready
                        if (latest?.activeGenerationId == generationId) {
                            _uiState.value = latest.copy(notice = error.userFacingMessage())
                        }
                    }
                    val latest = _uiState.value as? ChatUiState.Ready
                    if (routeActive && latest?.activeGenerationId == generationId) {
                        startPolling()
                    }
                }
            }
        } else {
            pollingJob?.cancel()
            pollingJob = null
        }
    }

    fun startNewConversation() {
        val state = _uiState.value as? ChatUiState.ChooseConversation ?: return
        val characterId = state.character?.id ?: return
        if (state.isCreating) return
        _uiState.value = state.copy(isCreating = true, error = null)
        viewModelScope.launch {
            try {
                openReady(coreClient.openConversation(characterId))
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                _uiState.value = state.copy(error = error)
            }
        }
    }

    fun send(text: String) {
        val state = _uiState.value as? ChatUiState.Ready ?: return
        val provider = state.selectedProvider ?: return
        val trimmed = text.trim()
        if (trimmed.isEmpty() || state.activeGenerationId != null || state.isSubmitting) return

        _uiState.value = state.copy(isSubmitting = true, notice = null)
        viewModelScope.launch {
            try {
                val credential = credentialStore.read(provider.id)
                val generationId = coreClient.sendMessage(
                    conversationId = state.conversation.id,
                    text = trimmed,
                    providerProfileId = provider.id,
                    credential = credential,
                )
                lastSequence = 0uL
                val messages = coreClient.listMessages(state.conversation.id)
                _uiState.value = state.copy(
                    messages = messages,
                    activeGenerationId = generationId,
                    streamedText = "",
                    isSubmitting = false,
                    notice = null,
                )
                if (routeActive) startPolling()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                val latest = _uiState.value as? ChatUiState.Ready ?: return@launch
                _uiState.value = latest.copy(
                    isSubmitting = false,
                    notice = error.userFacingMessage(),
                )
            }
        }
    }

    fun cancel() {
        val state = _uiState.value as? ChatUiState.Ready ?: return
        val generationId = state.activeGenerationId ?: return
        if (state.isCancelling) return
        _uiState.value = state.copy(isCancelling = true)
        viewModelScope.launch {
            try {
                coreClient.cancelGeneration(generationId)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                val latest = _uiState.value as? ChatUiState.Ready ?: return@launch
                _uiState.value = latest.copy(
                    isCancelling = false,
                    notice = error.userFacingMessage(),
                )
            }
        }
    }

    private fun load() {
        loadJob?.cancel()
        pollingJob?.cancel()
        routeReconciliationJob?.cancel()
        _uiState.value = ChatUiState.Loading
        loadJob = viewModelScope.launch {
            try {
                supportedEventVersion = coreClient.versionInfo().chatEventVersion
                val conversations = coreClient.listConversations()
                when {
                    requestedConversationId != null -> {
                        val selected = conversations.firstOrNull {
                            it.id == requestedConversationId
                        } ?: error("The selected conversation no longer exists.")
                        openReady(selected)
                    }

                    requestedCharacterId != null -> {
                        val character = coreClient.getCharacter(requestedCharacterId)
                        val matching = conversations.filter {
                            it.characterId == requestedCharacterId
                        }
                        if (matching.isEmpty()) {
                            openReady(coreClient.openConversation(requestedCharacterId))
                        } else {
                            _uiState.value = ChatUiState.ChooseConversation(
                                character = character,
                                conversations = matching,
                            )
                        }
                    }

                    conversations.isEmpty() -> {
                        _uiState.value = ChatUiState.Empty(coreClient.coreVersion())
                    }

                    else -> {
                        _uiState.value = ChatUiState.ChooseConversation(
                            character = null,
                            conversations = conversations,
                        )
                    }
                }
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                _uiState.value = ChatUiState.Error(error)
            }
        }
    }

    private suspend fun openReady(conversation: ConversationSummary) {
        val character = coreClient.getCharacter(conversation.characterId)
        val messages = coreClient.listMessages(conversation.id)
        val settings = coreClient.getSettings()
        val profiles = coreClient.listProviderProfiles()
        _uiState.value = ChatUiState.Ready(
            character = character,
            conversation = conversation,
            messages = messages,
            providerProfiles = profiles,
            selectedProvider = profiles.firstOrNull {
                it.id == settings.selectedProviderProfileId
            },
        )
    }

    private fun startPolling() {
        pollingJob?.cancel()
        pollingJob = viewModelScope.launch {
            var consecutiveEmptyBatches = 0
            while (isActive) {
                val state = _uiState.value as? ChatUiState.Ready ?: break
                val generationId = state.activeGenerationId ?: break
                try {
                    val batch = coreClient.pollEvents(EVENT_BATCH_SIZE)
                    if (batch.droppedEventCount > 0uL) {
                        consecutiveEmptyBatches = 0
                        reconcilePersistedGeneration(generationId)
                    } else if (batch.events.isEmpty()) {
                        consecutiveEmptyBatches += 1
                        if (consecutiveEmptyBatches >= emptyBatchesBeforeReconcile) {
                            consecutiveEmptyBatches = 0
                            reconcilePersistedGeneration(generationId)
                        }
                    } else {
                        consecutiveEmptyBatches = 0
                    }
                    batch.events.forEach { event ->
                        applyEvent(event, generationId)
                    }
                } catch (cancellation: CancellationException) {
                    throw cancellation
                } catch (error: Throwable) {
                    val latest = _uiState.value as? ChatUiState.Ready ?: break
                    _uiState.value = latest.copy(notice = error.userFacingMessage())
                }
                delay(pollIntervalMillis)
            }
        }
    }

    private suspend fun applyEvent(event: ChatEvent, activeGenerationId: String) {
        val state = _uiState.value as? ChatUiState.Ready ?: return
        if (state.activeGenerationId != activeGenerationId ||
            event.eventVersion != supportedEventVersion ||
            event.conversationId != state.conversation.id ||
            event.generationId != activeGenerationId ||
            event.sequence <= lastSequence
        ) {
            return
        }
        lastSequence = event.sequence
        when (event.kind) {
            "text_delta" -> {
                if (!state.isCancelling) {
                    _uiState.value = state.copy(
                        streamedText = state.streamedText + event.text.orEmpty(),
                    )
                }
            }

            "message_committed" -> refreshPersistedMessages()
            "generation_finished" -> finishGeneration(null)
            "generation_cancelled" -> finishGeneration("응답 생성을 취소했습니다.")
            "generation_failed" -> finishGeneration(
                event.errorMessage ?: "응답 생성에 실패했습니다.",
            )
        }
    }

    private suspend fun refreshPersistedMessages() {
        val state = _uiState.value as? ChatUiState.Ready ?: return
        val messages = coreClient.listMessages(state.conversation.id)
        val latest = _uiState.value as? ChatUiState.Ready ?: return
        if (latest.conversation.id == state.conversation.id) {
            _uiState.value = latest.copy(messages = messages)
        }
    }

    private suspend fun reconcilePersistedGeneration(expectedGenerationId: String) {
        val state = _uiState.value as? ChatUiState.Ready ?: return
        if (state.activeGenerationId != expectedGenerationId) return
        val messages = coreClient.listMessages(state.conversation.id)
        val latest = _uiState.value as? ChatUiState.Ready ?: return
        if (latest.conversation.id != state.conversation.id ||
            latest.activeGenerationId != expectedGenerationId
        ) {
            return
        }
        val isStillPending = messages.any { message ->
            message.generationId == expectedGenerationId && message.status == "pending"
        }
        _uiState.value = if (isStillPending) {
            latest.copy(messages = messages)
        } else {
            latest.copy(
                messages = messages,
                activeGenerationId = null,
                streamedText = "",
                isCancelling = false,
            )
        }
    }

    private suspend fun finishGeneration(notice: String?) {
        refreshPersistedMessages()
        val latest = _uiState.value as? ChatUiState.Ready ?: return
        _uiState.value = latest.copy(
            activeGenerationId = null,
            streamedText = "",
            isCancelling = false,
            notice = notice,
        )
    }

    companion object {
        private const val DEFAULT_POLL_INTERVAL_MILLIS = 100L
        private const val DEFAULT_EMPTY_BATCHES_BEFORE_RECONCILE = 10
        private const val EVENT_BATCH_SIZE = 64u

        fun factory(
            coreClient: CoreClient,
            credentialStore: CredentialStore,
            characterId: String? = null,
            conversationId: String? = null,
        ): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                ChatViewModel(
                    coreClient = coreClient,
                    credentialStore = credentialStore,
                    requestedCharacterId = characterId,
                    requestedConversationId = conversationId,
                )
            }
        }
    }
}

private fun Throwable.userFacingMessage(): String =
    message?.takeIf(String::isNotBlank) ?: "요청을 완료하지 못했습니다."
