package dev.lorepia.app

import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollToNode
import androidx.compose.ui.test.hasText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class MainActivityLaunchTest {
    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun realApplicationCoreLaunchesAndReportsSettingsHealth() {
        val application = InstrumentationRegistry.getInstrumentation()
            .targetContext
            .applicationContext
        assertTrue(application is LorepiaApplication)

        composeRule.waitUntil(timeoutMillis = 10_000) {
            composeRule.onAllNodesWithText("서재").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule.onNodeWithText("설정").performClick()
        composeRule.waitUntil(timeoutMillis = 10_000) {
            composeRule.onAllNodesWithText("AI 연결").fetchSemanticsNodes().isNotEmpty()
        }
        composeRule
            .onNodeWithTag("settings-content")
            .performScrollToNode(hasText("코어 버전"))

        composeRule.onNodeWithText("코어 버전").assertIsDisplayed()
        composeRule.onNodeWithText("정상").assertIsDisplayed()
        composeRule.onNodeWithText("열림").assertIsDisplayed()
    }
}
