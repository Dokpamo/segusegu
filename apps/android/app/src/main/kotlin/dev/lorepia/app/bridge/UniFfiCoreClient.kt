package dev.lorepia.app.bridge

import dev.lorepia.core.FfiCoreConfig
import dev.lorepia.core.FfiCharacter
import dev.lorepia.core.FfiImportInspection
import dev.lorepia.core.LorepiaCore
import dev.lorepia.core.coreVersion as ffiCoreVersion
import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Thin coroutine-friendly adapter around the generated UniFFI API.
 *
 * This class deliberately performs no product logic. The generated source is
 * supplied by `bindings/uniffi` and remains read-only.
 */
class UniFfiCoreClient private constructor(
    private val core: LorepiaCore,
    private val ioDispatcher: CoroutineDispatcher,
) : CoreClient {
    override suspend fun coreVersion(): String = withContext(ioDispatcher) {
        ffiCoreVersion()
    }

    override suspend fun healthCheck(): CoreHealthStatus = withContext(ioDispatcher) {
        val report = core.healthCheck()
        CoreHealthStatus(
            coreVersion = report.coreVersion,
            databaseOpen = report.databaseOpen,
            schemaVersion = report.schemaVersion.toLong(),
            dataRootWritable = report.dataRootWritable,
            stagingWritable = report.stagingWritable,
            recoveryPending = report.recoveryPending,
            activeJobs = report.activeJobs.toLong(),
        )
    }

    override suspend fun listCharacters(): List<CharacterSummary> = withContext(ioDispatcher) {
        core.listCharacters().map(FfiCharacter::toAppModel)
    }

    override suspend fun inspectImport(stagedPath: String): ImportInspection =
        withContext(ioDispatcher) {
            require(File(stagedPath).isAbsolute) {
                "The staged import path must be absolute."
            }
            core.inspectImport(stagedPath).toAppModel()
        }

    override suspend fun commitImport(inspectionId: String): CharacterSummary =
        withContext(ioDispatcher) {
            require(inspectionId.isNotBlank()) { "The inspection ID must not be blank." }
            core.commitImport(inspectionId).toAppModel()
        }

    override fun close() {
        core.close()
    }

    companion object {
        fun open(
            dataRoot: File,
            ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
        ): UniFfiCoreClient {
            require(dataRoot.isAbsolute) { "The core data root must be an absolute path." }
            val core = LorepiaCore.open(
                FfiCoreConfig(dataRoot = dataRoot.absolutePath),
            )
            return UniFfiCoreClient(core, ioDispatcher)
        }
    }
}

private fun FfiCharacter.toAppModel(): CharacterSummary = CharacterSummary(
    id = id,
    name = name,
    description = description,
    sourceHash = sourceHash,
)

private fun FfiImportInspection.toAppModel(): ImportInspection = ImportInspection(
    id = id,
    contentKind = contentKind,
    displayName = displayName,
    description = description,
    sourceSha256 = sourceSha256,
    sourceSize = sourceSize,
    assetCount = assetCount,
    warnings = warnings.toList(),
    blockedReasons = blockedReasons.toList(),
)
