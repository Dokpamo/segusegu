package dev.lorepia.app

import dev.lorepia.app.bridge.CoreClient
import dev.lorepia.app.bridge.CoreHealthStatus
import dev.lorepia.app.bridge.CharacterSummary
import dev.lorepia.app.bridge.ImportInspection

class FakeCoreClient(
    var version: String = "test-core",
    var health: CoreHealthStatus = healthyCoreStatus(),
    var characters: List<CharacterSummary> = emptyList(),
    var inspection: ImportInspection = syntheticInspection(),
    var versionError: Throwable? = null,
    var healthError: Throwable? = null,
    var inspectionError: Throwable? = null,
    var commitError: Throwable? = null,
) : CoreClient {
    var coreVersionCalls = 0
        private set
    var healthCheckCalls = 0
        private set
    var listCharactersCalls = 0
        private set
    var inspectImportCalls = 0
        private set
    var commitImportCalls = 0
        private set
    var closed = false
        private set

    override suspend fun coreVersion(): String {
        coreVersionCalls += 1
        versionError?.let { throw it }
        return version
    }

    override suspend fun healthCheck(): CoreHealthStatus {
        healthCheckCalls += 1
        healthError?.let { throw it }
        return health
    }

    override suspend fun listCharacters(): List<CharacterSummary> {
        listCharactersCalls += 1
        return characters
    }

    override suspend fun inspectImport(stagedPath: String): ImportInspection {
        inspectImportCalls += 1
        inspectionError?.let { throw it }
        return inspection
    }

    override suspend fun commitImport(inspectionId: String): CharacterSummary {
        commitImportCalls += 1
        commitError?.let { throw it }
        return CharacterSummary(
            id = "character-$inspectionId",
            name = inspection.displayName,
            description = inspection.description,
            sourceHash = inspection.sourceSha256,
        ).also { character ->
            characters = characters + character
        }
    }

    override fun close() {
        closed = true
    }
}

fun healthyCoreStatus(): CoreHealthStatus = CoreHealthStatus(
    coreVersion = "test-core",
    databaseOpen = true,
    schemaVersion = 1,
    dataRootWritable = true,
    stagingWritable = true,
    recoveryPending = false,
    activeJobs = 0,
)

fun syntheticInspection(): ImportInspection = ImportInspection(
    id = "inspection-1",
    contentKind = "charx",
    displayName = "합성 캐릭터",
    description = "테스트 전용 합성 설명",
    sourceSha256 = "a".repeat(64),
    sourceSize = 128u,
    assetCount = 1u,
    warnings = emptyList(),
    blockedReasons = emptyList(),
)
