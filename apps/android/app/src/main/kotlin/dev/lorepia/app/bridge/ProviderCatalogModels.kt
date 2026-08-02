package dev.lorepia.app.bridge

data class ProviderCatalogStatus(
    val statusSchemaVersion: UInt,
    val stateVersion: ULong,
    val activeRevision: ULong,
    val activeSnapshotSha256: String,
    val bundledBaselineSha256: String,
    val snapshotCount: UInt,
    val signedUpdateCount: UInt,
    val highestAcceptedRevision: ULong,
    val latestIssuedAt: String?,
    val activeSignedRevisions: List<ULong>,
)

data class ProviderCatalogRevision(
    val revision: ULong,
    val capturedAt: String,
    val snapshotSha256: String,
    val signedRevisions: List<ULong>,
    val active: Boolean,
)

data class ProviderCatalogActivation(
    val actionId: String,
    val stateVersion: ULong,
    val kind: String,
    val fromRevision: ULong?,
    val toRevision: ULong,
    val activatedAt: String,
    val diff: ProviderCatalogDiff,
)

data class ProviderCatalogHistory(
    val historySchemaVersion: UInt,
    val activeRevision: ULong,
    val revisions: List<ProviderCatalogRevision>,
    val activations: List<ProviderCatalogActivation>,
    val nextBeforeRevision: ULong?,
    val nextBeforeStateVersion: ULong?,
)

data class ProviderCatalogManifestChange(
    val providerTemplateId: String,
    val previousManifestVersion: UInt?,
    val nextManifestVersion: UInt?,
    val previousSha256: String?,
    val nextSha256: String?,
    val changedSections: List<String>,
)

data class ProviderCatalogModelChange(
    val modelEntryId: String,
    val providerTemplateId: String,
    val previousMetadataVersion: UInt?,
    val nextMetadataVersion: UInt?,
    val previousSha256: String?,
    val nextSha256: String?,
    val changedSections: List<String>,
)

data class ProviderCatalogDiff(
    val diffSchemaVersion: UInt,
    val fromRevision: ULong,
    val toRevision: ULong,
    val addedProviderTemplates: List<ProviderCatalogManifestChange>,
    val changedProviderTemplates: List<ProviderCatalogManifestChange>,
    val removedProviderTemplates: List<ProviderCatalogManifestChange>,
    val addedModels: List<ProviderCatalogModelChange>,
    val changedModels: List<ProviderCatalogModelChange>,
    val removedModels: List<ProviderCatalogModelChange>,
)

data class ProviderCatalogImportReview(
    val planSchemaVersion: UInt,
    val actionId: String,
    val expectedStateVersion: ULong,
    val expectedActiveRevision: ULong,
    val expectedActiveSnapshotSha256: String,
    val expectedHighestAcceptedRevision: ULong,
    val envelopeByteCount: ULong,
    val envelopeSha256: String,
    val signingKeyId: String,
    val payloadSha256: String,
    val signedCatalogRevision: ULong,
    val candidateRevision: ULong,
    val candidateSnapshotSha256: String,
    val preparedAt: String,
    val expiresAt: String,
    val diff: ProviderCatalogDiff,
)

data class ProviderCatalogImportPlan(
    val review: ProviderCatalogImportReview,
    val planSha256: String,
    val opaquePlanJson: String,
)

data class ProviderCatalogImportResult(
    val signedCatalogRevision: ULong,
    val activatedRevision: ULong,
    val diff: ProviderCatalogDiff,
    val status: ProviderCatalogStatus,
)

data class ProviderCatalogRollbackPlan(
    val planSchemaVersion: UInt,
    val actionId: String,
    val expectedStateVersion: ULong,
    val planSha256: String,
    val fromRevision: ULong,
    val toRevision: ULong,
    val createdAt: String,
    val expiresAt: String,
    val diff: ProviderCatalogDiff,
    val opaquePlanJson: String,
)

data class ProviderCatalogRollbackResult(
    val fromRevision: ULong,
    val activatedRevision: ULong,
    val status: ProviderCatalogStatus,
)
