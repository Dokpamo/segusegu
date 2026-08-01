package dev.lorepia.app.app

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.MainDispatcherRule
import dev.lorepia.app.healthyCoreStatus
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AppViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `connect exposes the real core version and health`() = runTest {
        val health = healthyCoreStatus().copy(coreVersion = "0.1.0")
        val core = FakeCoreClient(version = "0.1.0", health = health)

        val viewModel = AppViewModel(
            coreClientFactory = { core },
            ioDispatcher = mainDispatcherRule.testDispatcher,
        )
        advanceUntilIdle()

        assertEquals(AppUiState.Ready("0.1.0", health), viewModel.uiState.value)
        assertSame(core, viewModel.coreClient)
        assertEquals(1, core.versionInfoCalls)
        assertEquals(0, core.coreVersionCalls)
        assertEquals(1, core.healthCheckCalls)
    }

    @Test
    fun `connection failure is recoverable`() = runTest {
        val failingCore = FakeCoreClient(versionError = IllegalStateException("offline"))
        val healthyCore = FakeCoreClient()
        var attempts = 0
        val viewModel = AppViewModel(
            coreClientFactory = {
                attempts += 1
                if (attempts == 1) failingCore else healthyCore
            },
            ioDispatcher = mainDispatcherRule.testDispatcher,
        )
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value is AppUiState.Error)
        assertTrue(failingCore.closed)

        viewModel.retry()
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value is AppUiState.Ready)
        assertSame(healthyCore, viewModel.coreClient)
    }

    @Test
    fun `startup fails closed when core binding or event contracts drift`() = runTest {
        val mismatches = listOf(
            FakeCoreClient(coreApiVersion = 9u),
            FakeCoreClient(bindingApiVersion = 9u),
            FakeCoreClient(chatEventVersion = 5u),
        )

        mismatches.forEach { core ->
            val viewModel = AppViewModel(
                coreClientFactory = { core },
                ioDispatcher = mainDispatcherRule.testDispatcher,
            )
            advanceUntilIdle()

            assertTrue(viewModel.uiState.value is AppUiState.Error)
            assertTrue(core.closed)
            assertEquals(0, core.healthCheckCalls)
        }
    }
}
