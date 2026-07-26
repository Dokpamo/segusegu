package dev.lorepia.app.feature.library

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.MainDispatcherRule
import dev.lorepia.app.bridge.CharacterSummary
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class LibraryViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `a connected empty library exposes the empty state`() = runTest {
        val core = FakeCoreClient(version = "0.1.0")

        val viewModel = LibraryViewModel(core)
        advanceUntilIdle()

        assertEquals(LibraryUiState.Empty("0.1.0"), viewModel.uiState.value)
        assertEquals(1, core.coreVersionCalls)
        assertEquals(1, core.listCharactersCalls)
    }

    @Test
    fun `imported characters are returned by the Rust-backed library`() = runTest {
        val character = CharacterSummary(
            id = "character-1",
            name = "합성 캐릭터",
            description = "합성 설명",
            sourceHash = "a".repeat(64),
        )
        val core = FakeCoreClient(characters = listOf(character))

        val viewModel = LibraryViewModel(core)
        advanceUntilIdle()

        assertEquals(
            LibraryUiState.Content("test-core", listOf(character)),
            viewModel.uiState.value,
        )
    }

    @Test
    fun `core failure exposes a retryable error`() = runTest {
        val core = FakeCoreClient(versionError = IllegalStateException("not loaded"))

        val viewModel = LibraryViewModel(core)
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value is LibraryUiState.Error)
    }
}
