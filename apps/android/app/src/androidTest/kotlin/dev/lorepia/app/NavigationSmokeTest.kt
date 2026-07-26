package dev.lorepia.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import dev.lorepia.app.app.LorepiaApp
import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.CoreHealthStatus
import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.ImportInspection
import org.junit.Rule
import org.junit.Test

class NavigationSmokeTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun primaryDestinationsAreReachable() {
        composeRule.setContent {
            LorepiaApp(coreClientFactory = { InstrumentedFakeCoreClient() })
        }

        composeRule.waitUntil(timeoutMillis = 5_000) {
            composeRule.onAllNodesWithText("서재").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("채팅").performClick()
        composeRule.onNodeWithText("열린 대화가 없습니다").assertIsDisplayed()

        composeRule.onNodeWithText("설정").performClick()
        composeRule.onNodeWithText("이 기기에 저장됨").assertIsDisplayed()
    }
}

private class InstrumentedFakeCoreClient : CoreClient {
    private val health = CoreHealthStatus(
        coreVersion = "instrumented-test",
        databaseOpen = true,
        schemaVersion = 1,
        dataRootWritable = true,
        stagingWritable = true,
        recoveryPending = false,
        activeJobs = 0,
    )

    override suspend fun coreVersion(): String = health.coreVersion

    override suspend fun healthCheck(): CoreHealthStatus = health

    override suspend fun listCharacters(): List<CharacterSummary> = emptyList()

    override suspend fun inspectImport(stagedPath: String): ImportInspection =
        error("The navigation smoke test does not select a document.")

    override suspend fun commitImport(inspectionId: String): CharacterSummary =
        error("The navigation smoke test does not commit an import.")

    override fun close() = Unit
}
