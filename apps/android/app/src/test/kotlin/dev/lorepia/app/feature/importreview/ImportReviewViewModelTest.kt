package dev.lorepia.app.feature.importreview

import dev.lorepia.app.FakeCoreClient
import dev.lorepia.app.MainDispatcherRule
import dev.lorepia.app.bridge.ImportWarning
import dev.lorepia.app.platform.files.StagedDocument
import dev.lorepia.app.syntheticInspection
import java.nio.file.Files
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ImportReviewViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun `Rust inspection warnings and block reasons remain visible`() = runTest {
        val fixture = stagedFixture()
        val inspection = syntheticInspection().copy(
            warnings = listOf(ImportWarning("synthetic_warning", "합성 테스트 경고")),
            blockedReasons = listOf("합성 차단 사유"),
            isAllowed = false,
        )
        val core = FakeCoreClient(inspection = inspection)

        val viewModel = ImportReviewViewModel(
            coreClient = core,
            document = fixture.document,
            stagingDirectory = fixture.directory,
        )
        advanceUntilIdle()

        val state = viewModel.uiState.value as ImportReviewUiState.Ready
        assertEquals(inspection, state.inspection)
        assertTrue(state.inspection.isBlocked)
        assertEquals(
            "assets/avatar.png",
            state.inspection.representativeImage?.logicalAssetId,
        )
        assertEquals(
            listOf("alternate_greetings", "creator"),
            state.inspection.unsupportedOptionalFields,
        )
        assertEquals(1, core.inspectImportCalls)
    }

    @Test
    fun `approved inspection commits in core then removes staged file`() = runTest {
        val fixture = stagedFixture()
        val core = FakeCoreClient()
        val viewModel = ImportReviewViewModel(
            coreClient = core,
            document = fixture.document,
            stagingDirectory = fixture.directory,
        )
        advanceUntilIdle()

        viewModel.commit()
        advanceUntilIdle()

        assertTrue(viewModel.uiState.value is ImportReviewUiState.Imported)
        assertEquals(1, core.commitImportCalls)
        assertFalse(fixture.file.exists())
    }

    @Test
    fun `blocked inspection cannot be committed`() = runTest {
        val fixture = stagedFixture()
        val core = FakeCoreClient(
            inspection = syntheticInspection().copy(
                blockedReasons = listOf("차단됨"),
            ),
        )
        val viewModel = ImportReviewViewModel(
            coreClient = core,
            document = fixture.document,
            stagingDirectory = fixture.directory,
        )
        advanceUntilIdle()

        viewModel.commit()
        advanceUntilIdle()

        assertEquals(0, core.commitImportCalls)
        assertFalse(fixture.file.exists())
    }

    @Test
    fun `discard deletes only a direct child of staging`() = runTest {
        val fixture = stagedFixture()
        val core = FakeCoreClient()
        val viewModel = ImportReviewViewModel(
            coreClient = core,
            document = fixture.document,
            stagingDirectory = fixture.directory,
        )
        advanceUntilIdle()

        viewModel.discard()
        advanceUntilIdle()

        assertFalse(fixture.file.exists())
        assertEquals(1, core.discardImportCalls)
    }

    private fun stagedFixture(): Fixture {
        val directory = Files.createTempDirectory("lorepia-review").toFile()
        val file = directory.resolve("synthetic.pending").apply {
            writeText("synthetic")
        }
        return Fixture(
            directory = directory,
            file = file,
            document = StagedDocument(
                path = file.absolutePath,
                displayName = "synthetic.charx",
                sizeBytes = file.length(),
            ),
        )
    }

    private data class Fixture(
        val directory: java.io.File,
        val file: java.io.File,
        val document: StagedDocument,
    )
}
