package dev.lorepia.app.feature.settings

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.MainDispatcherRule
import dev.lorepia.app.healthyCoreStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `refresh maps every core health field`() = runTest {
        val health = healthyCoreStatus().copy(
            schemaVersion = 7,
            recoveryPending = true,
            activeJobs = 2,
        )
        val core = FakeCoreClient(health = health)

        val viewModel = SettingsViewModel(core)
        advanceUntilIdle()

        assertEquals(SettingsUiState.Ready(health), viewModel.uiState.value)
        assertEquals(1, core.healthCheckCalls)
    }

    @Test
    fun `health failure is represented without crashing`() = runTest {
        val core = FakeCoreClient(healthError = IllegalStateException("database unavailable"))

        val viewModel = SettingsViewModel(core)
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value is SettingsUiState.Error)
    }
}
