package dev.lorepia.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.lorepia.app.bridge.UniFfiCoreClient
import java.util.UUID
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UniFfiCoreClientSmokeTest {
    @Test
    fun generatedBindingOpensCoreAndReturnsHealth() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val dataRoot = context.filesDir.resolve("ffi-smoke-${UUID.randomUUID()}")
        val core = UniFfiCoreClient.open(dataRoot)
        try {
            val version = core.coreVersion()
            val health = core.healthCheck()

            assertTrue(version.isNotBlank())
            assertEquals(version, health.coreVersion)
            assertTrue(health.dataRootWritable)
            assertTrue(health.stagingWritable)
        } finally {
            core.close()
            dataRoot.deleteRecursively()
        }
    }

    @Test
    fun syntheticPackageInspectsCommitsAndAppearsInLibrary() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val runId = UUID.randomUUID()
        val dataRoot = context.filesDir.resolve("ffi-import-$runId")
        val stagingDirectory = context.cacheDir.resolve("ffi-import-$runId").apply {
            check(mkdirs() || isDirectory)
        }
        val stagedFile = stagingDirectory.resolve("minimal.charx")
        instrumentation.context.assets.open("minimal.charx").use { source ->
            stagedFile.outputStream().use(source::copyTo)
        }

        val core = UniFfiCoreClient.open(dataRoot)
        try {
            assertTrue(core.listCharacters().isEmpty())

            val inspection = core.inspectImport(stagedFile.absolutePath)
            assertTrue(inspection.id.isNotBlank())
            assertTrue(inspection.displayName.isNotBlank())
            assertFalse(inspection.isBlocked)
            assertTrue(inspection.sourceSize > 0u)

            val imported = core.commitImport(inspection.id)
            val library = core.listCharacters()

            assertEquals(inspection.displayName, imported.name)
            assertTrue(library.any { character -> character.id == imported.id })
        } finally {
            core.close()
            dataRoot.deleteRecursively()
            stagingDirectory.deleteRecursively()
        }
    }
}
