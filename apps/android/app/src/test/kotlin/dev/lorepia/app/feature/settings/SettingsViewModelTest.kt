package dev.lorepia.app.feature.settings

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.FakeCredentialStore
import dev.lorepia.app.MainDispatcherRule
import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.ProviderProfile
import dev.lorepia.app.healthyCoreStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `refresh loads health settings and provider profiles`() = runTest {
        val health = healthyCoreStatus().copy(
            schemaVersion = 7,
            recoveryPending = true,
            activeJobs = 2,
        )
        val profile = syntheticProvider()
        val settings = AppSettings(true, profile.id)
        val core = FakeCoreClient(
            health = health,
            profiles = mutableListOf(profile),
            settings = settings,
        )

        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        assertEquals(
            SettingsUiState.Ready(
                health = health,
                settings = settings,
                profiles = listOf(profile),
            ),
            viewModel.uiState.value,
        )
        assertEquals(1, core.healthCheckCalls)
    }

    @Test
    fun `new profile stores credential outside core and becomes selected`() = runTest {
        val core = FakeCoreClient()
        val credentials = FakeCredentialStore()
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.beginAddProfile()
        val editor = (viewModel.uiState.value as SettingsUiState.Ready).editor!!
        viewModel.updateEditor(
            editor.copy(
                displayName = "로컬 테스트",
                baseUrl = "https://example.invalid/v1",
                model = "test-model",
                timeoutSeconds = "45",
                credential = "secret-value",
            ),
        )
        viewModel.saveProfile()
        advanceUntilIdle()

        val state = viewModel.uiState.value as SettingsUiState.Ready
        assertEquals(1, state.profiles.size)
        assertEquals(state.profiles.single().id, state.settings.selectedProviderProfileId)
        assertEquals("secret-value", credentials.values[state.profiles.single().id])
    }

    @Test
    fun `partial preservation and provider deletion update persisted settings`() = runTest {
        val profile = syntheticProvider()
        val core = FakeCoreClient(
            profiles = mutableListOf(profile),
            settings = AppSettings(false, profile.id),
        )
        val credentials = FakeCredentialStore().apply {
            values[profile.id] = "secret"
        }
        val viewModel = SettingsViewModel(core, credentials)
        advanceUntilIdle()

        viewModel.setPreservePartialGenerations(true)
        advanceUntilIdle()
        assertTrue(core.settings.preservePartialGenerations)

        viewModel.deleteProfile(profile.id)
        advanceUntilIdle()

        assertTrue(core.profiles.isEmpty())
        assertNull(core.settings.selectedProviderProfileId)
        assertFalse(credentials.values.containsKey(profile.id))
    }

    @Test
    fun `health failure is represented without crashing`() = runTest {
        val core = FakeCoreClient(healthError = IllegalStateException("database unavailable"))

        val viewModel = SettingsViewModel(core, FakeCredentialStore())
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value is SettingsUiState.Error)
    }
}

private fun syntheticProvider() = ProviderProfile(
    id = "provider-1",
    displayName = "테스트 Provider",
    baseUrl = "https://example.invalid/v1",
    model = "test-model",
    timeoutSeconds = 30u,
)
