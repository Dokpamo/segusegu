package dev.lorepia.app.platform.paths

import android.content.Context
import java.io.File

data class AppDirectories(
    val dataRoot: File,
    val staging: File,
) {
    fun deleteStaleStagingFiles(
        nowMillis: Long = System.currentTimeMillis(),
        maximumAgeMillis: Long = DEFAULT_STAGING_MAXIMUM_AGE_MILLIS,
    ) {
        if (maximumAgeMillis <= 0) return
        staging.listFiles()
            ?.asSequence()
            ?.filter(File::isFile)
            ?.filter { file -> nowMillis - file.lastModified() > maximumAgeMillis }
            ?.forEach(File::delete)
    }

    companion object {
        fun create(context: Context): AppDirectories {
            val dataRoot = File(context.filesDir, "lorepia-data").apply {
                check(mkdirs() || isDirectory) { "Could not create the LorePia data directory." }
            }
            val staging = File(context.cacheDir, "import-staging").apply {
                check(mkdirs() || isDirectory) { "Could not create the import staging directory." }
            }
            return AppDirectories(
                dataRoot = dataRoot.absoluteFile,
                staging = staging.absoluteFile,
            )
        }

        private const val DEFAULT_STAGING_MAXIMUM_AGE_MILLIS = 24L * 60L * 60L * 1_000L
    }
}
