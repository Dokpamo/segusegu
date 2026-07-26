package dev.lorepia.app.platform.files

import android.content.ContentResolver
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.coroutines.coroutineContext

data class StagedDocument(
    val path: String,
    val displayName: String,
    val sizeBytes: Long,
)

class DocumentTooLargeException(
    val maximumBytes: Long,
) : IOException("The selected document exceeds the $maximumBytes byte staging limit.")

/**
 * Copies a content URI to an app-owned staging directory.
 *
 * The original name is display-only: a random filename is used on disk. This
 * layer applies a hard byte limit and performs no package parsing.
 */
class DocumentStager(
    private val contentResolver: ContentResolver,
    private val stagingDirectory: File,
    private val maximumBytes: Long = DEFAULT_MAXIMUM_BYTES,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    suspend fun stage(uri: Uri): StagedDocument = withContext(ioDispatcher) {
        require(maximumBytes > 0) { "The staging limit must be positive." }
        check(stagingDirectory.mkdirs() || stagingDirectory.isDirectory) {
            "Could not create the import staging directory."
        }

        val metadata = queryMetadata(uri)
        if (metadata.sizeBytes != null && metadata.sizeBytes > maximumBytes) {
            throw DocumentTooLargeException(maximumBytes)
        }

        val destination = File(
            stagingDirectory,
            "${UUID.randomUUID()}${stagingSuffix(metadata.displayName)}",
        )
        try {
            val source = contentResolver.openInputStream(uri)
                ?: throw IOException("The selected document could not be opened.")
            var copied = 0L
            source.use { input ->
                destination.outputStream().buffered().use { output ->
                    val buffer = ByteArray(COPY_BUFFER_BYTES)
                    while (true) {
                        coroutineContext.ensureActive()
                        val count = input.read(buffer)
                        if (count < 0) break
                        copied += count
                        if (copied > maximumBytes) {
                            throw DocumentTooLargeException(maximumBytes)
                        }
                        output.write(buffer, 0, count)
                    }
                }
            }
            StagedDocument(
                path = destination.absolutePath,
                displayName = metadata.displayName,
                sizeBytes = copied,
            )
        } catch (error: Throwable) {
            destination.delete()
            throw error
        }
    }

    private fun queryMetadata(uri: Uri): DocumentMetadata {
        var displayName: String? = null
        var sizeBytes: Long? = null
        contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIndex = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIndex >= 0 && !cursor.isNull(nameIndex)) {
                    displayName = cursor.getString(nameIndex)
                }
                if (sizeIndex >= 0 && !cursor.isNull(sizeIndex)) {
                    sizeBytes = cursor.getLong(sizeIndex)
                }
            }
        }
        return DocumentMetadata(
            displayName = displayName
                ?.replace(CONTROL_CHARACTER, "\uFFFD")
                ?.take(MAXIMUM_DISPLAY_NAME_LENGTH)
                ?.takeIf(String::isNotBlank)
                ?: "선택한 파일",
            sizeBytes = sizeBytes,
        )
    }

    private data class DocumentMetadata(
        val displayName: String,
        val sizeBytes: Long?,
    )

    private fun stagingSuffix(displayName: String): String {
        val extension = displayName
            .substringAfterLast('.', missingDelimiterValue = "")
            .lowercase()
        return when (extension) {
            "charx", "zip", "json" -> ".$extension"
            else -> ".pending"
        }
    }

    companion object {
        const val DEFAULT_MAXIMUM_BYTES: Long = 50L * 1024L * 1024L
        private const val COPY_BUFFER_BYTES = 64 * 1024
        private const val MAXIMUM_DISPLAY_NAME_LENGTH = 255
        private val CONTROL_CHARACTER = Regex("\\p{C}")
    }
}
