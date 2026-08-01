//! `SQLite` and content-addressed file persistence.

mod catalog;
mod database;
mod discovery;
mod discovery_repository;
mod model_sync;

pub use catalog::{
    CatalogActivationKind, CatalogActivationRecord, CatalogImportCommit, CatalogRollbackCommit,
    CatalogSnapshotSource, CatalogStateExpectation, CatalogStorageError, NewCatalogSnapshot,
    NewSignedCatalogUpdate, StoredCatalogActiveSnapshot, StoredCatalogRevisionGuard,
    StoredCatalogSnapshot, StoredCatalogState, StoredSignedCatalogUpdate,
};
pub use database::{
    DatabaseStats, MessageGenerationAction, MessageGenerationActionContext, StagedAssetImport,
    Storage,
};
pub use discovery::{DurableOperationOutcome, PersistDiscoveryTransition};
pub use discovery_repository::{
    DiscoveredProviderGraph, DiscoveryActionReplay, DiscoveryCommitAttemptRecord,
    DiscoveryCommitPhase, DiscoveryCompensationRecord, DiscoveryCompensationStatus,
    DiscoveryCompletedOperationWrite, DiscoveryEvidenceKind, DiscoveryEvidenceRecord,
    DiscoveryJsonUpdate, DiscoveryOperationRecord, DiscoveryOperationStatus, DiscoveryOutboxEvent,
    DiscoveryRecoveryResult, DiscoverySessionSnapshot, DiscoveryTransitionWrite,
    PreparedDiscoveryCommit, PreparedDiscoveryCompensationStep, StoredDiscoveryCandidate,
};
pub use model_sync::validate_provider_api_route_metadata;
