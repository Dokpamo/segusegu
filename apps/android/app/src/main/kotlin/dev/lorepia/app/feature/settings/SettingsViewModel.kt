package dev.lorepia.app.feature.settings

import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.initializer
import androidx.lifecycle.viewmodel.viewModelFactory
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.ProviderProfile
import dev.lorepia.app.platform.credentials.CredentialStore
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

class SettingsViewModel(
    private val coreClient: CoreClient,
    private val credentialStore: CredentialStore,
) : ViewModel() {
    private val _uiState = MutableStateFlow<SettingsUiState>(SettingsUiState.Loading)
    val uiState: StateFlow<SettingsUiState> = _uiState.asStateFlow()
    private var refreshJob: Job? = null

    init {
        refresh()
    }

    fun refresh() {
        refreshJob?.cancel()
        _uiState.value = SettingsUiState.Loading
        refreshJob = viewModelScope.launch {
            try {
                loadReady()
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                _uiState.value = SettingsUiState.Error(error)
            }
        }
    }

    fun beginAddProfile() {
        updateReady {
            it.copy(
                editor = ProviderEditor(id = UUID.randomUUID().toString()),
                notice = null,
                error = null,
            )
        }
    }

    fun beginEditProfile(profileId: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val profile = state.profiles.firstOrNull { it.id == profileId } ?: return
        _uiState.value = state.copy(
            editor = ProviderEditor(
                id = profile.id,
                displayName = profile.displayName,
                baseUrl = profile.baseUrl,
                model = profile.model,
                timeoutSeconds = profile.timeoutSeconds.toString(),
                isExisting = true,
            ),
            notice = null,
            error = null,
        )
    }

    fun updateEditor(editor: ProviderEditor) {
        updateReady { state ->
            if (state.editor?.id == editor.id) {
                state.copy(editor = editor, notice = null, error = null)
            } else {
                state
            }
        }
    }

    fun cancelEditor() {
        updateReady { it.copy(editor = null, notice = null, error = null) }
    }

    fun saveProfile() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val editor = state.editor ?: return
        if (state.isSaving) return
        val timeout = editor.timeoutSeconds.toUIntOrNull()
        if (editor.displayName.isBlank() ||
            editor.baseUrl.isBlank() ||
            editor.model.isBlank() ||
            timeout == null
        ) {
            _uiState.value = state.copy(
                notice = null,
                error = "프로필 입력값을 확인해 주세요.",
            )
            return
        }

        _uiState.value = state.copy(isSaving = true, notice = null, error = null)
        viewModelScope.launch {
            try {
                val saved = coreClient.upsertProviderProfile(
                    ProviderProfile(
                        id = editor.id,
                        displayName = editor.displayName.trim(),
                        baseUrl = editor.baseUrl.trim(),
                        model = editor.model.trim(),
                        timeoutSeconds = timeout,
                    ),
                )
                if (editor.credential.isNotBlank()) {
                    credentialStore.write(saved.id, editor.credential)
                }
                if (state.settings.selectedProviderProfileId == null) {
                    coreClient.updateSettings(
                        state.settings.copy(selectedProviderProfileId = saved.id),
                    )
                }
                loadReady(notice = "프로필을 저장했습니다.")
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                _uiState.value = latest.copy(
                    isSaving = false,
                    notice = null,
                    error = error.userFacingMessage(),
                )
            }
        }
    }

    fun selectProfile(profileId: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (state.isSaving || state.settings.selectedProviderProfileId == profileId) return
        _uiState.value = state.copy(isSaving = true, notice = null, error = null)
        viewModelScope.launch {
            try {
                val settings = coreClient.updateSettings(
                    state.settings.copy(selectedProviderProfileId = profileId),
                )
                val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                _uiState.value = latest.copy(
                    settings = settings,
                    isSaving = false,
                    notice = "사용할 프로필을 선택했습니다.",
                    error = null,
                )
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                restoreWithError(error)
            }
        }
    }

    fun setPreservePartialGenerations(enabled: Boolean) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (state.isSaving || state.settings.preservePartialGenerations == enabled) return
        _uiState.value = state.copy(isSaving = true, notice = null, error = null)
        viewModelScope.launch {
            try {
                val settings = coreClient.updateSettings(
                    state.settings.copy(preservePartialGenerations = enabled),
                )
                val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                _uiState.value = latest.copy(settings = settings, isSaving = false)
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                restoreWithError(error)
            }
        }
    }

    fun deleteProfile(profileId: String) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (state.isSaving) return
        _uiState.value = state.copy(isSaving = true, notice = null, error = null)
        viewModelScope.launch {
            try {
                credentialStore.delete(profileId)
                coreClient.deleteProviderProfile(profileId)
                loadReady(notice = "프로필을 삭제했습니다.")
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                restoreWithError(error)
            }
        }
    }

    fun clearCredential() {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        val editor = state.editor ?: return
        if (!editor.isExisting || state.isSaving) return
        _uiState.value = state.copy(isSaving = true, notice = null, error = null)
        viewModelScope.launch {
            try {
                credentialStore.delete(editor.id)
                val latest = _uiState.value as? SettingsUiState.Ready ?: return@launch
                _uiState.value = latest.copy(
                    isSaving = false,
                    editor = latest.editor?.copy(credential = ""),
                    notice = "저장된 자격증명을 삭제했습니다.",
                    error = null,
                )
            } catch (cancellation: CancellationException) {
                throw cancellation
            } catch (error: Throwable) {
                restoreWithError(error)
            }
        }
    }

    private suspend fun loadReady(notice: String? = null) {
        _uiState.value = SettingsUiState.Ready(
            health = coreClient.healthCheck(),
            settings = coreClient.getSettings(),
            profiles = coreClient.listProviderProfiles(),
            notice = notice,
        )
    }

    private fun restoreWithError(error: Throwable) {
        val latest = _uiState.value as? SettingsUiState.Ready ?: return
        _uiState.value = latest.copy(
            isSaving = false,
            notice = null,
            error = error.userFacingMessage(),
        )
    }

    private inline fun updateReady(transform: (SettingsUiState.Ready) -> SettingsUiState.Ready) {
        val state = _uiState.value as? SettingsUiState.Ready ?: return
        if (!state.isSaving) _uiState.value = transform(state)
    }

    companion object {
        fun factory(
            coreClient: CoreClient,
            credentialStore: CredentialStore,
        ): ViewModelProvider.Factory = viewModelFactory {
            initializer {
                SettingsViewModel(coreClient, credentialStore)
            }
        }
    }
}

private fun Throwable.userFacingMessage(): String =
    message?.takeIf(String::isNotBlank) ?: "설정을 저장하지 못했습니다."
