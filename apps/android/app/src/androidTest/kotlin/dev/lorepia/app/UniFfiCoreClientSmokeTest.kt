package dev.lorepia.app

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import dev.lorepia.app.bridge.AppSettings
import dev.lorepia.app.bridge.CoreFailure
import dev.lorepia.app.bridge.ProviderProfile
import dev.lorepia.app.bridge.UniFfiCoreClient
import java.io.ByteArrayOutputStream
import java.io.FileOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class UniFfiCoreClientSmokeTest {
    @Test
    fun closedAdapterRejectsFurtherCoreCalls() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val dataRoot = context.filesDir.resolve("ffi-closed-${UUID.randomUUID()}")
        val core = UniFfiCoreClient.open(dataRoot)

        core.close()
        val failure = runCatching { core.healthCheck() }.exceptionOrNull()

        assertTrue(failure is IllegalStateException)
        assertEquals("LorepiaCore object has already been destroyed", failure?.message)
        dataRoot.deleteRecursively()
        Unit
    }

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
    fun bindingContractRoundTripsLargeUnicodeNullEnumsEmptyListsAndErrors() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val runId = UUID.randomUUID()
        val dataRoot = context.filesDir.resolve("ffi-contract-$runId")
        val source = context.cacheDir.resolve("바인딩-계약-$runId.json")
        val name = "세구 😀 e\u0301"
        val description = "큰문자열😀".repeat(8_192)
        source.writeText(
            """{"spec":"chara_card_v3","data":{
                "name":"$name",
                "description":"$description",
                "personality":"Unused fallback",
                "creator":"Synthetic"
            }}""".trimIndent(),
            Charsets.UTF_8,
        )

        val core = UniFfiCoreClient.open(dataRoot)
        try {
            val versions = core.versionInfo()
            assertEquals(core.coreVersion(), versions.coreVersion)
            assertEquals(4u, versions.coreApiVersion)
            assertEquals(4u, versions.bindingApiVersion)
            assertEquals(2u, versions.chatEventVersion)
            assertTrue(core.listCharacters().isEmpty())
            assertTrue(core.listConversations().isEmpty())
            assertTrue(core.listProviderProfiles().isEmpty())
            assertEquals(null, core.getSettings().selectedProviderProfileId)
            assertTrue(core.pollEvents().events.isEmpty())

            val inspection = core.inspectImport(source.absolutePath)
            assertEquals("character_card_v3", inspection.contentKind)
            assertEquals(name, inspection.displayName)
            assertEquals(description, inspection.description)
            assertTrue(inspection.warnings.isEmpty())
            assertTrue(inspection.blockedReasons.isEmpty())
            assertEquals(null, inspection.representativeImage)
            assertEquals(
                listOf("creator", "personality"),
                inspection.unsupportedOptionalFields,
            )

            val character = core.commitImport(inspection.id)
            assertEquals(name, character.name)
            assertEquals(description, character.description)
            assertEquals(null, character.avatarAssetHash)
            val conversation = core.openConversation(character.id)
            assertEquals(name, conversation.title)
            assertTrue(core.listMessages(conversation.id).isEmpty())

            val missingFailure =
                runCatching { core.getCharacter("없는-캐릭터") }.exceptionOrNull()
            assertTrue(missingFailure is CoreFailure)
            missingFailure as CoreFailure
            assertEquals("not_found", missingFailure.code)
            assertFalse(missingFailure.recoverable)
            assertTrue(missingFailure.operationId.isNotBlank())

            val cancellationFailure =
                runCatching { core.cancelGeneration("없는-생성") }.exceptionOrNull()
            assertTrue(cancellationFailure is CoreFailure)
            cancellationFailure as CoreFailure
            assertEquals("not_found", cancellationFailure.code)
        } finally {
            core.close()
            dataRoot.deleteRecursively()
            source.delete()
        }
    }

    @Test
    fun importReviewMapsRepresentativeImageToTheCommittedAvatarCandidate() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val runId = UUID.randomUUID()
        val dataRoot = context.filesDir.resolve("ffi-avatar-$runId")
        val source = context.cacheDir.resolve("ffi-avatar-$runId.charx")
        ZipOutputStream(FileOutputStream(source)).use { archive ->
            archive.putNextEntry(ZipEntry("card.json"))
            archive.write(
                """{"spec":"chara_card_v3","data":{
                    "name":"Avatar",
                    "description":"Synthetic",
                    "creator":"Test"
                }}""".trimIndent().toByteArray(),
            )
            archive.closeEntry()
            archive.putNextEntry(ZipEntry("Assets/Avatar.PNG"))
            archive.write(
                byteArrayOf(
                    0x89.toByte(),
                    0x50,
                    0x4E,
                    0x47,
                    0x0D,
                    0x0A,
                    0x1A,
                    0x0A,
                ),
            )
            archive.closeEntry()
        }

        val core = UniFfiCoreClient.open(dataRoot)
        try {
            val inspection = core.inspectImport(source.absolutePath)
            val image = checkNotNull(inspection.representativeImage)
            assertEquals("assets/avatar.png", image.logicalAssetId)
            assertEquals("image/png", image.mediaType)
            assertEquals(8uL, image.sizeBytes)
            assertEquals(listOf("creator"), inspection.unsupportedOptionalFields)

            val character = core.commitImport(inspection.id)
            assertTrue(character.avatarAssetHash?.isNotBlank() == true)
        } finally {
            core.close()
            dataRoot.deleteRecursively()
            source.delete()
        }
    }

    @Test
    fun liveEventsRemainOrderedAndCancellationIsTerminal() = runBlocking {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val runId = UUID.randomUUID()
        val dataRoot = context.filesDir.resolve("ffi-events-$runId")
        val source = context.cacheDir.resolve("ffi-events-$runId.json")
        source.writeText(
            """{"spec":"chara_card_v3","data":{"name":"이벤트 테스트","description":"Synthetic"}}""",
            Charsets.UTF_8,
        )

        StallingSseServer().use { server ->
            val core = UniFfiCoreClient.open(dataRoot)
            try {
                val character = core.commitImport(core.inspectImport(source.absolutePath).id)
                val conversation = core.openConversation(character.id)
                val profile = core.upsertProviderProfile(
                    ProviderProfile(
                        id = "cancellation-$runId",
                        displayName = "Cancellation test",
                        baseUrl = server.baseUrl,
                        model = "synthetic",
                        timeoutSeconds = 5u,
                    ),
                )
                val generationId = core.sendMessage(
                    conversationId = conversation.id,
                    text = "중지해",
                    providerProfileId = profile.id,
                    credential = null,
                )
                assertTrue(server.awaitStreaming())

                val events = mutableListOf<dev.lorepia.app.bridge.ChatEvent>()
                val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
                while (events.none { it.kind == "text_delta" }) {
                    events += core.pollEvents(64u).events.filter {
                        it.generationId == generationId
                    }
                    assertTrue("text delta did not arrive", System.nanoTime() < deadline)
                    Thread.sleep(10)
                }

                core.cancelGeneration(generationId)
                while (events.none { it.kind == "generation_cancelled" }) {
                    events += core.pollEvents(64u).events.filter {
                        it.generationId == generationId
                    }
                    assertTrue("cancellation did not arrive", System.nanoTime() < deadline)
                    Thread.sleep(10)
                }

                assertEquals("generation_started", events.first().kind)
                assertEquals("부분😀", events.first { it.kind == "text_delta" }.text)
                assertEquals("generation_cancelled", events.last().kind)
                assertTrue(events.all { it.branchId != null })
                assertTrue(events.all { it.assistantMessageId != null })
                assertTrue(
                    events.zipWithNext().all { (earlier, later) ->
                        earlier.sequence < later.sequence
                    },
                )
                val messages = core.listMessages(conversation.id)
                assertEquals("부분😀", messages[1].content)
                assertEquals("cancelled", messages[1].status)
                assertEquals(null, messages[0].parentId)
                assertEquals(null, messages[0].generationId)
            } finally {
                core.close()
                dataRoot.deleteRecursively()
                source.delete()
            }
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

    @Test
    fun providerSettingsAndConversationSurviveCoreRestart() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val runId = UUID.randomUUID()
        val dataRoot = context.filesDir.resolve("ffi-restart-$runId")
        val stagedFile = context.cacheDir.resolve("ffi-restart-$runId.charx")
        instrumentation.context.assets.open("minimal.charx").use { source ->
            stagedFile.outputStream().use(source::copyTo)
        }
        val profile = ProviderProfile(
            id = "provider-$runId",
            displayName = "Synthetic provider",
            baseUrl = "https://example.invalid/v1",
            model = "synthetic-model",
            timeoutSeconds = 30u,
        )

        var core = UniFfiCoreClient.open(dataRoot)
        try {
            val imported = core.commitImport(
                core.inspectImport(stagedFile.absolutePath).id,
            )
            val savedProfile = core.upsertProviderProfile(profile)
            core.updateSettings(
                AppSettings(
                    preservePartialGenerations = true,
                    selectedProviderProfileId = savedProfile.id,
                ),
            )
            val conversation = core.openConversation(imported.id)
            core.close()

            core = UniFfiCoreClient.open(dataRoot)
            assertTrue(core.listCharacters().any { it.id == imported.id })
            assertTrue(core.listProviderProfiles().any { it.id == savedProfile.id })
            assertEquals(savedProfile.id, core.getSettings().selectedProviderProfileId)
            assertTrue(core.getSettings().preservePartialGenerations)
            assertTrue(core.listConversations().any { it.id == conversation.id })
            assertTrue(core.listMessages(conversation.id).isEmpty())
        } finally {
            core.close()
            dataRoot.deleteRecursively()
            stagedFile.delete()
        }
    }

    private class StallingSseServer : AutoCloseable {
        private val listener = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        private val streaming = CountDownLatch(1)
        private val release = CountDownLatch(1)
        @Volatile
        private var serverFailure: Throwable? = null
        private val serverThread = Thread {
            try {
                listener.accept().use { socket ->
                    readRequest(socket)
                    val event =
                        """data: {"choices":[{"delta":{"content":"부분😀"}}]}

"""
                    val eventBytes = event.toByteArray(StandardCharsets.UTF_8)
                    val headers =
                        "HTTP/1.1 200 OK\r\n" +
                            "Content-Type: text/event-stream\r\n" +
                            "Transfer-Encoding: chunked\r\n" +
                            "Connection: close\r\n\r\n" +
                            "${eventBytes.size.toString(16)}\r\n"
                    socket.getOutputStream().apply {
                        write(headers.toByteArray(StandardCharsets.US_ASCII))
                        write(eventBytes)
                        write("\r\n".toByteArray(StandardCharsets.US_ASCII))
                        flush()
                        streaming.countDown()
                        release.await(5, TimeUnit.SECONDS)
                        write("0\r\n\r\n".toByteArray(StandardCharsets.US_ASCII))
                        flush()
                    }
                }
            } catch (error: Throwable) {
                if (release.count > 0) {
                    serverFailure = error
                }
                streaming.countDown()
            }
        }.apply {
            name = "lorepia-android-test-sse"
            isDaemon = true
            start()
        }

        val baseUrl: String = "http://127.0.0.1:${listener.localPort}/v1"

        fun awaitStreaming(): Boolean =
            streaming.await(5, TimeUnit.SECONDS) && serverFailure == null

        override fun close() {
            release.countDown()
            listener.close()
            serverThread.join(TimeUnit.SECONDS.toMillis(5))
        }

        private fun readRequest(socket: Socket) {
            socket.soTimeout = TimeUnit.SECONDS.toMillis(5).toInt()
            val bytes = ByteArrayOutputStream()
            val buffer = ByteArray(4_096)
            var expectedSize: Int? = null
            while (expectedSize == null || bytes.size() < expectedSize) {
                val count = socket.getInputStream().read(buffer)
                if (count <= 0) {
                    return
                }
                bytes.write(buffer, 0, count)
                if (expectedSize == null) {
                    val request = bytes.toString(StandardCharsets.UTF_8.name())
                    val headerEnd = request.indexOf("\r\n\r\n")
                    if (headerEnd >= 0) {
                        val contentLength = request
                            .substring(0, headerEnd)
                            .lineSequence()
                            .firstOrNull { line ->
                                line.startsWith("content-length:", ignoreCase = true)
                            }
                            ?.substringAfter(':')
                            ?.trim()
                            ?.toIntOrNull()
                            ?: 0
                        expectedSize = headerEnd + 4 + contentLength
                    }
                }
            }
        }
    }
}
