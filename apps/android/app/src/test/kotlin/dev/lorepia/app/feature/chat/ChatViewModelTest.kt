package dev.lorepia.app.feature.chat

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.MainDispatcherRule
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ChatViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `chat starts with an accessible empty state when no conversation is open`() = runTest {
        val core = FakeCoreClient(version = "0.1.0")

        val viewModel = ChatViewModel(core)
        advanceUntilIdle()

        assertEquals(ChatUiState.Empty("0.1.0"), viewModel.uiState.value)
    }
}
