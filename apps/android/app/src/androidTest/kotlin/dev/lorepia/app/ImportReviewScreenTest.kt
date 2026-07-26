package dev.lorepia.app

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onNodeWithText
import dev.lorepia.app.feature.importreview.ImportReviewScreen
import dev.lorepia.app.feature.importreview.ImportReviewUiState
import dev.lorepia.app.bridge.ImportInspection
import dev.lorepia.app.platform.files.StagedDocument
import dev.lorepia.app.ui.theme.LorepiaTheme
import org.junit.Rule
import org.junit.Test

class ImportReviewScreenTest {
    @get:Rule
    val composeRule = createComposeRule()

    @Test
    fun warningAndBlockReasonAreAnnouncedAsText() {
        composeRule.setContent {
            LorepiaTheme {
                ImportReviewScreen(
                    uiState = ImportReviewUiState.Ready(
                        document = StagedDocument(
                            path = "/app/staging/synthetic.pending",
                            displayName = "synthetic.charx",
                            sizeBytes = 128,
                        ),
                        inspection = ImportInspection(
                            id = "inspection-1",
                            contentKind = "charx",
                            displayName = "합성 캐릭터",
                            description = "합성 설명",
                            sourceSha256 = "a".repeat(64),
                            sourceSize = 128u,
                            assetCount = 1u,
                            warnings = emptyList(),
                            blockedReasons = listOf(
                                "경로 충돌이 발견되었습니다.",
                            ),
                        ),
                    ),
                    onCommit = {},
                    onClose = {},
                    contentPadding = PaddingValues(),
                )
            }
        }

        composeRule.onNodeWithText("경로 충돌이 발견되었습니다.").assertIsDisplayed()
        composeRule.onNodeWithText("이 파일은 가져올 수 없습니다.").assertIsDisplayed()
    }
}
