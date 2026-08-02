//! Typed repository facade for durable provider discovery.
//!
//! The lower-level [`crate::discovery`] module owns the `SQLite` state-machine
//! primitives. This module is the product-facing boundary: it hydrates domain
//! aggregates, validates bounded redacted payloads, and keeps provider graph
//! publication in the same transaction as discovery commit bookkeeping.

use std::collections::BTreeSet;

use chrono::{DateTime, Utc};
use lorepia_domain::{
    ApiFamily, AuthBinding, CanonicalOrigin, CapabilityObservation, Confidence,
    ConnectionConfigValue, CoreError, CoreErrorCode, CoreResult, CredentialRedirectPolicy,
    DiscoverySessionId, EndpointPath, EvidenceId, GenerationPreset, HeaderName, HttpMethod,
    HttpUrl, ModelMetadataSource, ModelRoute, ObservationSource, ProviderConnection,
    ProviderNetworkMode, ProviderTemplate, SupportStatus, TemplateSource,
    discovery::{
        DiscoveryActionEnvelope, DiscoveryActionId, DiscoveryActionReceipt,
        DiscoveryApprovalBinding, DiscoveryApprovalDecision, DiscoveryApprovalGrant,
        DiscoveryApprovalId, DiscoveryApprovalRecord, DiscoveryCandidate, DiscoveryCandidateId,
        DiscoveryCommitAttemptId, DiscoveryCommitPhase as DomainCommitPhase, DiscoveryCommitPlan,
        DiscoveryCompensationKind, DiscoveryCompensationStatus as DomainCompensationStatus,
        DiscoveryCompensationStep, DiscoveryCompensationTarget, DiscoveryContractError,
        DiscoveryEffect, DiscoveryEventId, DiscoveryInterruptionOutcome, DiscoveryOperationId,
        DiscoveryOperationKind, DiscoveryPreviousSelection, DiscoveryProbeBudget,
        DiscoveryRecoveryCheckpoint, DiscoveryReviewDiff, DiscoverySideEffectClass, DiscoveryState,
        DiscoveryTransition, DiscoveryUnknownOutcomeResolution, PROVIDER_DISCOVERY_EVENT_VERSION,
        ProviderDiscoveryAction, ProviderDiscoveryEvent, ProviderDiscoverySession,
        SanitizedDiscoveryInput,
    },
};
use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior, params};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};

#[cfg(test)]
use crate::discovery::NewDiscoverySession;
use crate::{
    Storage,
    database::{
        StoredDiscoveredProviderGraphRows, clear_provider_selections_for_connection,
        load_discovered_provider_graph_rows, load_discovery_previous_selection,
        restore_discovery_provider_selection, write_discovered_provider_graph_rows,
    },
    discovery::{
        self, CompletedDiscoveryOperation, DiscoveryRecoveryDisposition, DiscoveryStorageError,
        DurableDiscoveryEffect, DurableDiscoveryTransition, DurableOperationOutcome,
        NewDiscoveryApproval, NewDiscoveryCommitAttempt, NewDiscoveryCompensationStep,
        NewDiscoveryOperation, PersistDiscoveryTransition,
    },
    validate_provider_api_route_metadata,
};

const MAX_DISCOVERY_ROWS: u32 = 1_000;
const MAX_DISCOVERY_JSON_BYTES: usize = 1024 * 1024;
const MAX_DISCOVERY_JSON_CHARS: usize = 512 * 1024;
const MAX_DISCOVERY_JSON_DEPTH: usize = 24;
const MAX_DISCOVERY_JSON_NODES: usize = 16_384;
const DETERMINISTIC_DISCOVERY_SCHEMA_VERSION: u32 = 1;
const DISCOVERY_REDACTION_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitialDeterministicDiscoveryOutput {
    schema_version: u32,
    selected_template: Option<ProviderTemplate>,
    evidence: Vec<InitialRedactedDiscoveryEvidence>,
    family_candidates: Vec<InitialDiscoveryFamilyCandidate>,
    manifest_candidates: Vec<InitialDiscoveryManifestCandidate>,
    connection_hints: Vec<InitialDiscoveryConnectionHint>,
    fetch_issues: Vec<InitialDiscoveryFetchIssue>,
    fetch_stopped_by_budget: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitialRedactedDiscoveryEvidence {
    kind: String,
    source_origin: CanonicalOrigin,
    content_sha256: String,
    extracted_json: Value,
    redaction_version: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum InitialDiscoveryCandidateConfidence {
    Structural,
    ExactCompiledProvider,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitialDiscoveryFamilyCandidate {
    api_family: ApiFamily,
    confidence: InitialDiscoveryCandidateConfidence,
    evidence_indices: Vec<usize>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitialDiscoveryManifestCandidate {
    template: ProviderTemplate,
    manifest_sha256: String,
    confidence: InitialDiscoveryCandidateConfidence,
    generation_endpoint_evidenced: bool,
    model_endpoint_evidenced: bool,
    auth_evidenced: bool,
    evidence_indices: Vec<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum InitialConnectionOriginHintSource {
    CompiledProviderDefault,
    OpenApiServer,
    SanitizedCurlRequest,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitialDiscoveryConnectionHint {
    api_family: ApiFamily,
    api_origin: CanonicalOrigin,
    api_base_path: Option<EndpointPath>,
    network_mode: ProviderNetworkMode,
    auth: AuthBinding,
    requires_credential_origin_approval: bool,
    source: InitialConnectionOriginHintSource,
    evidence_indices: Vec<usize>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitialDiscoveryFetchIssue {
    source_origin: CanonicalOrigin,
    source_path_sha256: String,
    source_path_is_root: bool,
    kind: String,
    http_status: Option<u16>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum InitialCurlAuthHint {
    BearerHeader,
    AuthorizationHeader,
    ApiKeyHeader { header_name: HeaderName },
    CookieHeader { header_name: HeaderName },
    ApiKeyQuery { parameter_name: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
enum InitialJsonShape {
    Null,
    Boolean,
    Number,
    String,
    Array { items: Vec<Self>, truncated: bool },
    Object { fields: Vec<InitialJsonFieldShape> },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitialJsonFieldShape {
    name: String,
    shape: InitialJsonShape,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct InitialSanitizedCurlEvidence {
    method: HttpMethod,
    origin: CanonicalOrigin,
    source_path_sha256: String,
    source_path_is_root: bool,
    query_parameter_names: Vec<String>,
    header_names: Vec<HeaderName>,
    auth_hints: Vec<InitialCurlAuthHint>,
    body_json_shape: Option<InitialJsonShape>,
    stream_hint: Option<bool>,
    api_family_candidates: Vec<ApiFamily>,
    trust: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoverySessionSnapshot {
    pub session: ProviderDiscoverySession,
    pub active_operation_id: Option<DiscoveryOperationId>,
    pub draft_json: Option<Value>,
    pub review: Option<DiscoveryReviewDiff>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiscoveryJsonUpdate<T> {
    Preserve,
    Clear,
    Replace(T),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryEvidenceKind {
    HtmlDocument,
    JsonDocument,
    YamlDocument,
    XmlDocument,
    PlainTextDocument,
    JsonSchema,
    OpenApi,
}

impl DiscoveryEvidenceKind {
    const fn as_str(self) -> &'static str {
        match self {
            Self::HtmlDocument => "html_document",
            Self::JsonDocument => "json_document",
            Self::YamlDocument => "yaml_document",
            Self::XmlDocument => "xml_document",
            Self::PlainTextDocument => "plain_text_document",
            Self::JsonSchema => "json_schema",
            Self::OpenApi => "open_api",
        }
    }

    fn parse(value: &str) -> CoreResult<Self> {
        match value {
            "html_document" => Ok(Self::HtmlDocument),
            "json_document" => Ok(Self::JsonDocument),
            "yaml_document" => Ok(Self::YamlDocument),
            "xml_document" => Ok(Self::XmlDocument),
            "plain_text_document" => Ok(Self::PlainTextDocument),
            "json_schema" => Ok(Self::JsonSchema),
            "open_api" => Ok(Self::OpenApi),
            _ => Err(corrupted("stored discovery evidence kind is invalid")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryEvidenceRecord {
    pub id: EvidenceId,
    pub session_id: DiscoverySessionId,
    pub kind: DiscoveryEvidenceKind,
    pub source_url: HttpUrl,
    pub content_sha256: String,
    pub extracted_json: Value,
    pub fetched_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredDiscoveryCandidate {
    pub candidate: DiscoveryCandidate,
    pub proposed_revision: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryOperationStatus {
    Prepared,
    Started,
    Succeeded,
    Failed,
    Interrupted,
    OutcomeUnknown,
}

impl DiscoveryOperationStatus {
    fn parse(value: &str) -> CoreResult<Self> {
        match value {
            "prepared" => Ok(Self::Prepared),
            "started" => Ok(Self::Started),
            "succeeded" => Ok(Self::Succeeded),
            "failed" => Ok(Self::Failed),
            "interrupted" => Ok(Self::Interrupted),
            "outcome_unknown" => Ok(Self::OutcomeUnknown),
            _ => Err(corrupted("stored discovery operation status is invalid")),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryOperationRecord {
    pub id: DiscoveryOperationId,
    pub session_id: DiscoverySessionId,
    pub kind: DiscoveryOperationKind,
    pub side_effect_class: DiscoverySideEffectClass,
    pub status: DiscoveryOperationStatus,
    pub action_id: DiscoveryActionId,
    pub expected_revision: u64,
    pub request_sha256: String,
    pub approval: Option<DiscoveryApprovalBinding>,
    pub started_at: Option<DateTime<Utc>>,
    pub finished_at: Option<DateTime<Utc>>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryOutboxEvent {
    pub event: ProviderDiscoveryEvent,
    pub delivery_attempts: u32,
    pub available_at: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryCommitPhase {
    Prepared,
    DatabaseApplied,
    CredentialReferenceApplied,
    Completed,
    CompensationRequired,
    Compensating,
    Compensated,
    OutcomeUnknown,
}

impl DiscoveryCommitPhase {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Prepared => "prepared",
            Self::DatabaseApplied => "database_applied",
            Self::CredentialReferenceApplied => "credential_reference_applied",
            Self::Completed => "completed",
            Self::CompensationRequired => "compensation_required",
            Self::Compensating => "compensating",
            Self::Compensated => "compensated",
            Self::OutcomeUnknown => "outcome_unknown",
        }
    }

    fn parse(value: &str) -> CoreResult<Self> {
        match value {
            "prepared" => Ok(Self::Prepared),
            "database_applied" => Ok(Self::DatabaseApplied),
            "credential_reference_applied" => Ok(Self::CredentialReferenceApplied),
            "completed" => Ok(Self::Completed),
            "compensation_required" => Ok(Self::CompensationRequired),
            "compensating" => Ok(Self::Compensating),
            "compensated" => Ok(Self::Compensated),
            "outcome_unknown" => Ok(Self::OutcomeUnknown),
            _ => Err(corrupted("stored discovery commit phase is invalid")),
        }
    }
}

impl From<DomainCommitPhase> for DiscoveryCommitPhase {
    fn from(value: DomainCommitPhase) -> Self {
        match value {
            DomainCommitPhase::Prepared => Self::Prepared,
            DomainCommitPhase::DatabaseApplied => Self::DatabaseApplied,
            DomainCommitPhase::CredentialReferenceApplied => Self::CredentialReferenceApplied,
            DomainCommitPhase::Completed => Self::Completed,
            DomainCommitPhase::CompensationRequired => Self::CompensationRequired,
            DomainCommitPhase::Compensating => Self::Compensating,
            DomainCommitPhase::Compensated => Self::Compensated,
            DomainCommitPhase::OutcomeUnknown => Self::OutcomeUnknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryCommitAttemptRecord {
    pub id: DiscoveryCommitAttemptId,
    pub session_id: DiscoverySessionId,
    pub attempt_number: u32,
    pub action_id: DiscoveryActionId,
    pub expected_revision: u64,
    pub plan_sha256: String,
    pub plan: DiscoveryCommitPlan,
    pub phase: DiscoveryCommitPhase,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoveryCompensationStatus {
    Pending,
    InProgress,
    Completed,
    Failed,
    OutcomeUnknown,
}

impl DiscoveryCompensationStatus {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "pending",
            Self::InProgress => "in_progress",
            Self::Completed => "completed",
            Self::Failed => "failed",
            Self::OutcomeUnknown => "outcome_unknown",
        }
    }

    fn parse(value: &str) -> CoreResult<Self> {
        match value {
            "pending" => Ok(Self::Pending),
            "in_progress" => Ok(Self::InProgress),
            "completed" => Ok(Self::Completed),
            "failed" => Ok(Self::Failed),
            "outcome_unknown" => Ok(Self::OutcomeUnknown),
            _ => Err(corrupted("stored discovery compensation status is invalid")),
        }
    }
}

impl From<DomainCompensationStatus> for DiscoveryCompensationStatus {
    fn from(value: DomainCompensationStatus) -> Self {
        match value {
            DomainCompensationStatus::Pending => Self::Pending,
            DomainCompensationStatus::InProgress => Self::InProgress,
            DomainCompensationStatus::Completed => Self::Completed,
            DomainCompensationStatus::Failed => Self::Failed,
            DomainCompensationStatus::OutcomeUnknown => Self::OutcomeUnknown,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryCompensationRecord {
    pub id: String,
    pub commit_attempt_id: DiscoveryCommitAttemptId,
    pub ordinal: u32,
    pub action_id: DiscoveryActionId,
    pub kind: DiscoveryCompensationKind,
    pub step: DiscoveryCompensationStep,
    pub status: DiscoveryCompensationStatus,
    pub attempt_count: u32,
    pub last_failure: Option<lorepia_domain::discovery::DiscoveryFailure>,
    pub created_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedDiscoveryCompensationStep {
    pub id: String,
    pub step: DiscoveryCompensationStep,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedDiscoveryCommit {
    pub plan: DiscoveryCommitPlan,
    pub plan_sha256: String,
    pub attempt_number: u32,
    pub reuse_existing: bool,
    pub compensation_steps: Vec<PreparedDiscoveryCompensationStep>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DiscoveredProviderGraph {
    pub plan: DiscoveryCommitPlan,
    pub plan_sha256: String,
    pub template: ProviderTemplate,
    pub connection: ProviderConnection,
    pub routes: Vec<ModelRoute>,
    pub observations: Vec<CapabilityObservation>,
    pub presets: Vec<GenerationPreset>,
}

impl DiscoveredProviderGraph {
    pub fn ownership_sha256(&self) -> CoreResult<String> {
        provider_graph_ownership_hash(
            &self.template,
            &self.connection,
            &self.routes,
            &self.observations,
            &self.presets,
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryCompletedOperationWrite {
    pub id: DiscoveryOperationId,
    pub outcome: DurableOperationOutcome,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DiscoveryTransitionWrite {
    pub transition: DiscoveryTransition,
    pub draft: DiscoveryJsonUpdate<Value>,
    pub review: DiscoveryJsonUpdate<DiscoveryReviewDiff>,
    pub new_evidence: Vec<DiscoveryEvidenceRecord>,
    pub new_candidates: Vec<StoredDiscoveryCandidate>,
    pub approval: Option<DiscoveryApprovalRecord>,
    pub new_operation_id: Option<DiscoveryOperationId>,
    pub completed_operation: Option<DiscoveryCompletedOperationWrite>,
    pub prepared_commit: Option<PreparedDiscoveryCommit>,
    pub provider_graph: Option<DiscoveredProviderGraph>,
    pub occurred_at: DateTime<Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryRecoveryResult {
    pub operation_id: DiscoveryOperationId,
    pub session_id: DiscoverySessionId,
    pub state: DiscoveryState,
    pub event: ProviderDiscoveryEvent,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiscoveryActionReplay {
    pub receipt: DiscoveryActionReceipt,
    pub transition: DiscoveryTransition,
}

fn is_pristine_discovery_session(session: &ProviderDiscoverySession) -> bool {
    session.state == DiscoveryState::Draft
        && session.revision == 0
        && session.next_event_sequence == 1
        && session.recovery.is_none()
        && session.unknown_operation.is_none()
        && session.manifest_sha256.is_none()
        && session.commit_plan_sha256.is_none()
        && session.commit_attempt_id.is_none()
        && session.committed_connection_id.is_none()
        && !session.cancellation_pending
        && session.active_effect_approval.is_none()
        && session.failure.is_none()
}

impl Storage {
    #[cfg(test)]
    fn create_discovery_session(
        &self,
        session: &ProviderDiscoverySession,
        created_at: DateTime<Utc>,
    ) -> CoreResult<()> {
        session.validate().map_err(contract_error)?;
        validate_sanitized_input(&session.input)?;
        if !is_pristine_discovery_session(session) {
            return Err(CoreError::invalid(
                "a new discovery session must be a pristine draft",
            ));
        }
        validate_identifier("discovery session id", session.id.as_str(), 128)?;
        let mut connection = self.connection()?;
        discovery::insert_discovery_session(
            &mut connection,
            &NewDiscoverySession {
                id: session.id.as_str(),
                input: &session.input,
                created_at: &created_at.to_rfc3339(),
            },
        )
        .map_err(discovery_error)
    }

    pub fn get_discovery_session(
        &self,
        session_id: &DiscoverySessionId,
    ) -> CoreResult<DiscoverySessionSnapshot> {
        let connection = self.connection()?;
        load_session_snapshot(&connection, session_id.as_str())?.ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "provider discovery session was not found",
                false,
            )
        })
    }

    pub fn list_discovery_sessions(&self, limit: u32) -> CoreResult<Vec<DiscoverySessionSnapshot>> {
        validate_limit(limit)?;
        let connection = self.connection()?;
        let ids = {
            let mut statement = connection
                .prepare(
                    "SELECT id
                     FROM provider_discovery_sessions
                     ORDER BY updated_at DESC, id
                     LIMIT ?1",
                )
                .map_err(database_error)?;
            statement
                .query_map([limit], |row| row.get::<_, String>(0))
                .map_err(database_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(database_error)?
        };
        ids.into_iter()
            .map(|id| {
                load_session_snapshot(&connection, &id)?.ok_or_else(|| {
                    corrupted("discovery session disappeared while it was being listed")
                })
            })
            .collect()
    }

    #[cfg(test)]
    fn save_discovery_evidence(&self, evidence: &DiscoveryEvidenceRecord) -> CoreResult<()> {
        validate_discovery_evidence(evidence)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        require_session(&transaction, evidence.session_id.as_str())?;
        let extracted_json = encode_redacted_json(&evidence.extracted_json, "discovery evidence")?;
        let existing = transaction
            .query_row(
                "SELECT session_id, kind, source_url, content_sha256, extracted_json, fetched_at
                 FROM provider_discovery_evidence
                 WHERE id = ?1",
                [evidence.id.as_str()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, String>(5)?,
                    ))
                },
            )
            .optional()
            .map_err(database_error)?;
        let expected = (
            evidence.session_id.as_str(),
            evidence.kind.as_str(),
            evidence.source_url.as_str(),
            evidence.content_sha256.as_str(),
            extracted_json.as_str(),
            evidence.fetched_at.to_rfc3339(),
        );
        if let Some(existing) = existing {
            if existing.0 == expected.0
                && existing.1 == expected.1
                && existing.2 == expected.2
                && existing.3 == expected.3
                && existing.4 == expected.4
                && existing.5 == expected.5
            {
                return Ok(());
            }
            return Err(CoreError::invalid(
                "discovery evidence identifiers are immutable",
            ));
        }
        transaction
            .execute(
                "INSERT INTO provider_discovery_evidence (
                     id, session_id, kind, source_url, content_sha256,
                     extracted_json, redaction_version, fetched_at
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7)",
                params![
                    evidence.id.as_str(),
                    evidence.session_id.as_str(),
                    evidence.kind.as_str(),
                    evidence.source_url.as_str(),
                    evidence.content_sha256,
                    extracted_json,
                    evidence.fetched_at.to_rfc3339(),
                ],
            )
            .map_err(database_error)?;
        transaction.commit().map_err(database_error)
    }

    pub fn list_discovery_evidence(
        &self,
        session_id: &DiscoverySessionId,
        limit: u32,
    ) -> CoreResult<Vec<DiscoveryEvidenceRecord>> {
        validate_limit(limit)?;
        let connection = self.connection()?;
        require_session(&connection, session_id.as_str())?;
        let mut statement = connection
            .prepare(
                "SELECT id, session_id, kind, source_url, content_sha256,
                        extracted_json, fetched_at
                 FROM provider_discovery_evidence
                 WHERE session_id = ?1
                 ORDER BY fetched_at, id
                 LIMIT ?2",
            )
            .map_err(database_error)?;
        statement
            .query_map(params![session_id.as_str(), limit], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                ))
            })
            .map_err(database_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(database_error)?
            .into_iter()
            .map(decode_evidence_row)
            .collect()
    }

    pub fn list_discovery_candidates(
        &self,
        session_id: &DiscoverySessionId,
        limit: u32,
    ) -> CoreResult<Vec<StoredDiscoveryCandidate>> {
        validate_limit(limit)?;
        let connection = self.connection()?;
        require_session(&connection, session_id.as_str())?;
        let mut statement = connection
            .prepare(
                "SELECT id, session_id, candidate_kind, summary_json, evidence_ids_json,
                        proposed_revision, created_at
                 FROM provider_discovery_candidates
                 WHERE session_id = ?1
                 ORDER BY proposed_revision, created_at, id
                 LIMIT ?2",
            )
            .map_err(database_error)?;
        statement
            .query_map(params![session_id.as_str(), limit], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, u64>(5)?,
                    row.get::<_, String>(6)?,
                ))
            })
            .map_err(database_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(database_error)?
            .into_iter()
            .map(decode_candidate_row)
            .collect()
    }

    pub fn list_discovery_approvals(
        &self,
        session_id: &DiscoverySessionId,
        limit: u32,
    ) -> CoreResult<Vec<DiscoveryApprovalRecord>> {
        validate_limit(limit)?;
        let connection = self.connection()?;
        require_session(&connection, session_id.as_str())?;
        let mut statement = connection
            .prepare(
                "SELECT id, session_id, approval_kind, candidate_id, decision,
                        grant_json, session_revision, grant_sha256, created_at
                 FROM provider_discovery_approvals
                 WHERE session_id = ?1
                 ORDER BY session_revision, created_at, id
                 LIMIT ?2",
            )
            .map_err(database_error)?;
        statement
            .query_map(params![session_id.as_str(), limit], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, u64>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, String>(8)?,
                ))
            })
            .map_err(database_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(database_error)?
            .into_iter()
            .map(decode_approval_row)
            .collect()
    }

    pub fn get_discovery_review(
        &self,
        session_id: &DiscoverySessionId,
    ) -> CoreResult<Option<DiscoveryReviewDiff>> {
        Ok(self.get_discovery_session(session_id)?.review)
    }

    pub fn get_current_discovery_operation(
        &self,
        session_id: &DiscoverySessionId,
    ) -> CoreResult<Option<DiscoveryOperationRecord>> {
        let connection = self.connection()?;
        let snapshot =
            load_session_snapshot(&connection, session_id.as_str())?.ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::NotFound,
                    "provider discovery session was not found",
                    false,
                )
            })?;
        snapshot
            .active_operation_id
            .as_ref()
            .map(|operation_id| load_operation_by_id(&connection, operation_id))
            .transpose()
    }

    pub fn mark_discovery_operation_started(
        &self,
        operation_id: &DiscoveryOperationId,
        started_at: DateTime<Utc>,
    ) -> CoreResult<bool> {
        let mut connection = self.connection()?;
        discovery::mark_discovery_operation_started(
            &mut connection,
            operation_id.as_str(),
            &started_at.to_rfc3339(),
        )
        .map_err(discovery_error)
    }

    pub fn poll_discovery_events(
        &self,
        limit: u32,
        available_at: DateTime<Utc>,
    ) -> CoreResult<Vec<DiscoveryOutboxEvent>> {
        validate_limit(limit)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let rows = load_pollable_outbox_rows(&transaction, limit, available_at)?;
        for row in &rows {
            transaction
                .execute(
                    "UPDATE provider_discovery_event_outbox
                     SET delivery_attempts = delivery_attempts + 1
                     WHERE id = ?1 AND delivered_at IS NULL",
                    [row.event.id.as_str()],
                )
                .map_err(database_error)?;
        }
        transaction.commit().map_err(database_error)?;
        Ok(rows
            .into_iter()
            .map(|mut row| {
                row.delivery_attempts += 1;
                row
            })
            .collect())
    }

    pub fn ack_discovery_event(
        &self,
        event_id: &DiscoveryEventId,
        delivered_at: DateTime<Utc>,
    ) -> CoreResult<bool> {
        let changed = self
            .connection()?
            .execute(
                "UPDATE provider_discovery_event_outbox
                 SET delivered_at = ?2
                 WHERE id = ?1
                   AND delivered_at IS NULL
                   AND delivery_attempts > 0
                   AND ?2 >= available_at
                   AND NOT EXISTS (
                       SELECT 1
                       FROM provider_discovery_event_outbox AS earlier
                       WHERE earlier.session_id =
                             provider_discovery_event_outbox.session_id
                         AND earlier.delivered_at IS NULL
                         AND earlier.sequence <
                             provider_discovery_event_outbox.sequence
                   )",
                params![event_id.as_str(), delivered_at.to_rfc3339()],
            )
            .map_err(database_error)?;
        Ok(changed == 1)
    }

    pub fn persist_discovery_transition(
        &self,
        write: &DiscoveryTransitionWrite,
    ) -> CoreResult<PersistDiscoveryTransition> {
        if write
            .provider_graph
            .as_ref()
            .is_some_and(|graph| graph.plan.credential_ref.is_some())
        {
            return Err(CoreError::invalid(
                "credentialed provider graphs require native credential confirmation",
            ));
        }
        validate_transition_write(write)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let result = persist_transition_in_transaction(&transaction, write)?;
        transaction.commit().map_err(database_error)?;
        Ok(result)
    }

    /// Creates the draft row and applies `Begin` in one `SQLite` transaction.
    ///
    /// This prevents a process crash from leaving an invisible draft without
    /// its first operation, action receipt, and outbox event.
    pub fn begin_discovery_session(
        &self,
        initial_session: &ProviderDiscoverySession,
        write: &DiscoveryTransitionWrite,
    ) -> CoreResult<PersistDiscoveryTransition> {
        initial_session.validate().map_err(contract_error)?;
        validate_sanitized_input(&initial_session.input)?;
        if !is_pristine_discovery_session(initial_session)
            || write.transition.previous_revision != 0
            || write.transition.session.id != initial_session.id
            || write.transition.receipt.action_kind != "begin"
        {
            return Err(CoreError::invalid(
                "atomic discovery begin requires a pristine matching draft and Begin transition",
            ));
        }
        validate_identifier("discovery session id", initial_session.id.as_str(), 128)?;
        let begun = &write.transition.session;
        if begun.input != initial_session.input
            || begun.state != DiscoveryState::ResolvingKnownProvider
            || begun.revision != 1
            || begun.next_event_sequence != 2
            || begun.recovery.is_some()
            || begun.unknown_operation.is_some()
            || begun.manifest_sha256.is_some()
            || begun.commit_plan_sha256.is_some()
            || begun.commit_attempt_id.is_some()
            || begun.committed_connection_id.is_some()
            || begun.cancellation_pending
            || begun.active_effect_approval.is_some()
            || begun.failure.is_some()
            || write.transition.effect != DiscoveryEffect::ResolveKnownProvider
            || write.transition.event.progress.is_some()
            || write.transition.event.action_required.is_some()
            || write.transition.event.warning.is_some()
            || write.transition.event.failure.is_some()
        {
            return Err(CoreError::invalid(
                "atomic discovery begin transition contains non-begin state",
            ));
        }
        if !write.new_evidence.is_empty()
            || !write.new_candidates.is_empty()
            || write.approval.is_some()
            || write.prepared_commit.is_some()
            || write.provider_graph.is_some()
            || write.completed_operation.is_some()
            || matches!(write.draft, DiscoveryJsonUpdate::Clear)
            || matches!(write.review, DiscoveryJsonUpdate::Replace(_))
        {
            return Err(CoreError::invalid(
                "atomic discovery begin cannot publish later-stage artifacts",
            ));
        }
        if let DiscoveryJsonUpdate::Replace(draft) = &write.draft {
            validate_initial_discovery_draft(draft, &initial_session.input)?;
        }
        validate_transition_write(write)?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let session_exists = transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM provider_discovery_sessions WHERE id = ?1
                 )",
                [initial_session.id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if session_exists {
            let stored = load_session_snapshot(&transaction, initial_session.id.as_str())?
                .ok_or_else(|| corrupted("existing discovery session disappeared"))?;
            if stored.session.input != initial_session.input
                || stored.created_at != write.occurred_at
                || (stored.session.revision == 0 && stored.session != *initial_session)
            {
                return Err(CoreError::invalid(
                    "existing discovery session does not match the atomic Begin request",
                ));
            }
        } else {
            insert_session_in_transaction(&transaction, initial_session, write.occurred_at)?;
        }
        let result = persist_transition_in_transaction(&transaction, write)?;
        transaction.commit().map_err(database_error)?;
        Ok(result)
    }

    pub fn find_discovery_action_replay(
        &self,
        session_id: &DiscoverySessionId,
        action_id: &DiscoveryActionId,
        request_sha256: &str,
        action_kind: &str,
    ) -> CoreResult<Option<DiscoveryActionReplay>> {
        validate_sha256("discovery action request hash", request_sha256)?;
        validate_identifier("discovery action kind", action_kind, 128)?;
        let row = self
            .connection()?
            .query_row(
                "SELECT session_id, action_kind, request_sha256, expected_revision,
                        resulting_revision, event_sequence, outcome, response_json
                 FROM provider_discovery_action_receipts
                 WHERE action_id = ?1",
                [action_id.as_str()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, u64>(3)?,
                        row.get::<_, u64>(4)?,
                        row.get::<_, u64>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, String>(7)?,
                    ))
                },
            )
            .optional()
            .map_err(database_error)?;
        let Some(row) = row else {
            return Ok(None);
        };
        if row.0 != session_id.as_str() || row.1 != action_kind || row.2 != request_sha256 {
            return Err(CoreError::invalid(
                "discovery action identifier was reused with a different request",
            ));
        }
        let transition = serde_json::from_str::<DiscoveryTransition>(&row.7)
            .map_err(|_| corrupted("stored discovery action response is invalid"))?;
        let receipt = DiscoveryActionReceipt {
            action_id: action_id.clone(),
            session_id: session_id.clone(),
            action_kind: row.1,
            request_sha256: row.2,
            expected_revision: row.3,
            resulting_revision: row.4,
            event_sequence: row.5,
            outcome: serde_json::from_value(Value::String(row.6))
                .map_err(|_| corrupted("stored discovery receipt outcome is invalid"))?,
        };
        if transition.receipt != receipt {
            return Err(corrupted(
                "stored discovery replay response does not match its receipt",
            ));
        }
        Ok(Some(DiscoveryActionReplay {
            receipt,
            transition,
        }))
    }

    /// Finalizes a credential-confirmed discovery commit in one `SQLite`
    /// transaction. Until this transaction commits, no provider graph row is
    /// visible to connection, route, preset, model-sync, or generation readers.
    #[allow(clippy::too_many_lines)]
    pub fn persist_credential_confirmed_discovery_commit(
        &self,
        write: &DiscoveryTransitionWrite,
    ) -> CoreResult<PersistDiscoveryTransition> {
        validate_transition_write(write)?;
        let transition = &write.transition;
        let graph = write.provider_graph.as_ref().ok_or_else(|| {
            CoreError::invalid("credential-confirmed commit requires its exact provider graph")
        })?;
        if graph.plan.credential_ref.is_none()
            || graph.connection.credential_ref != graph.plan.credential_ref
            || transition.receipt.action_kind != "commit_succeeded"
            || transition.session.state != DiscoveryState::Ready
            || transition.session.commit_attempt_id.as_ref() != Some(&graph.plan.attempt_id)
            || transition.session.commit_plan_sha256.as_deref() != Some(graph.plan_sha256.as_str())
            || transition.session.committed_connection_id.as_ref()
                != Some(&graph.plan.connection_id)
            || transition.effect != DiscoveryEffect::None
            || write.new_operation_id.is_some()
            || write
                .completed_operation
                .as_ref()
                .is_none_or(|completed| completed.outcome != DurableOperationOutcome::Succeeded)
        {
            return Err(CoreError::invalid(
                "credential-confirmed commit does not match the exact ready transition",
            ));
        }

        let mut transition_only = write.clone();
        transition_only.provider_graph = None;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let receipt_exists = transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM provider_discovery_action_receipts
                     WHERE action_id = ?1
                 )",
                [transition.receipt.action_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if !receipt_exists {
            apply_provider_graph_in_transaction(
                &transaction,
                graph,
                transition.previous_revision,
                write.occurred_at,
            )?;
            let changed = transaction
                .execute(
                    "UPDATE provider_discovery_commit_attempts
                     SET phase = 'credential_reference_applied',
                         updated_at = ?3,
                         completed_at = NULL
                     WHERE id = ?1
                       AND session_id = ?2
                       AND plan_sha256 = ?4
                       AND phase = 'database_applied'",
                    params![
                        graph.plan.attempt_id.as_str(),
                        graph.plan.session_id.as_str(),
                        write.occurred_at.to_rfc3339(),
                        graph.plan_sha256.as_str(),
                    ],
                )
                .map_err(database_error)?;
            if changed != 1 {
                return Err(CoreError::invalid(
                    "credential-confirmed commit phase changed concurrently",
                ));
            }
        }

        let result = persist_transition_in_transaction(&transaction, &transition_only)?;
        let stored = transaction
            .query_row(
                "SELECT session.state, session.revision,
                        session.commit_attempt_id, session.commit_plan_sha256,
                        session.committed_connection_id, session.active_operation_id,
                        attempt.phase, attempt.completed_at
                 FROM provider_discovery_sessions AS session
                 JOIN provider_discovery_commit_attempts AS attempt
                   ON attempt.id = session.commit_attempt_id
                  AND attempt.session_id = session.id
                 WHERE session.id = ?1",
                [transition.session.id.as_str()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, u64>(1)?,
                        row.get::<_, Option<String>>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, Option<String>>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, Option<String>>(7)?,
                    ))
                },
            )
            .optional()
            .map_err(database_error)?
            .ok_or_else(|| corrupted("finalized discovery commit binding disappeared"))?;
        if stored.0 != "ready"
            || stored.1 != transition.session.revision
            || stored.2.as_deref() != Some(graph.plan.attempt_id.as_str())
            || stored.3.as_deref() != Some(graph.plan_sha256.as_str())
            || stored.4.as_deref() != Some(graph.plan.connection_id.as_str())
            || stored.5.is_some()
            || stored.6 != "completed"
            || stored.7.is_none()
        {
            return Err(corrupted(
                "credential-confirmed provider graph was not finalized atomically",
            ));
        }
        let stored_graph = load_discovered_provider_graph_rows(
            &transaction,
            &graph.plan.template_id,
            graph.plan.template_version,
            &graph.plan.connection_id,
        )?
        .ok_or_else(|| corrupted("finalized discovery provider graph is missing"))?;
        if stored_provider_graph_ownership_hash(&stored_graph)? != graph.plan.graph_sha256
            || graph_ownership_audit_hash(&transaction, &graph.plan.session_id)?
                != graph.plan.graph_sha256
        {
            return Err(corrupted(
                "finalized discovery provider graph differs from its approved ownership",
            ));
        }
        transaction.commit().map_err(database_error)?;
        Ok(result)
    }

    pub fn get_discovery_commit_attempt(
        &self,
        attempt_id: &DiscoveryCommitAttemptId,
    ) -> CoreResult<DiscoveryCommitAttemptRecord> {
        let connection = self.connection()?;
        load_commit_attempt(&connection, attempt_id)
    }

    /// Classifies unfinished work after a crash and records interruption
    /// transitions. This method never executes or replays an external effect.
    pub fn recover_unfinished_discovery_operations(
        &self,
        recovered_at: DateTime<Utc>,
    ) -> CoreResult<Vec<DiscoveryRecoveryResult>> {
        self.recover_unfinished_discovery_operations_except(recovered_at, &BTreeSet::new())
    }

    /// Recovers every unfinished operation except an exact Core-classified set
    /// of durably resumable operation identifiers.
    ///
    /// Storage never infers resumability from opaque draft JSON. The caller
    /// must derive this set from a validated product snapshot, and every
    /// preserved identifier is still checked against the session's active
    /// operation before it is left untouched.
    pub fn recover_unfinished_discovery_operations_except(
        &self,
        recovered_at: DateTime<Utc>,
        resumable_operation_ids: &BTreeSet<DiscoveryOperationId>,
    ) -> CoreResult<Vec<DiscoveryRecoveryResult>> {
        let unfinished = {
            let connection = self.connection()?;
            discovery::list_unfinished_discovery_operations(&connection).map_err(discovery_error)?
        };
        let mut recovered = Vec::with_capacity(unfinished.len());
        for unfinished_operation in unfinished {
            let session_id = DiscoverySessionId::from(unfinished_operation.session_id);
            let operation_id =
                DiscoveryOperationId::parse(unfinished_operation.id).map_err(contract_error)?;
            let snapshot = self.get_discovery_session(&session_id)?;
            if snapshot.active_operation_id.as_ref() != Some(&operation_id) {
                return Err(corrupted(
                    "unfinished discovery operation is not the session's active operation",
                ));
            }
            let operation = self
                .get_current_discovery_operation(&session_id)?
                .ok_or_else(|| corrupted("unfinished discovery operation cannot be hydrated"))?;
            if resumable_operation_ids.contains(&operation_id) {
                if operation.kind != DiscoveryOperationKind::BuildAssistantManifestDraft
                    || unfinished_operation.operation_kind != "build_assistant_manifest_draft"
                {
                    return Err(corrupted(
                        "only setup assistant operations may bypass startup recovery",
                    ));
                }
                continue;
            }
            let compensation_already_durable = operation.kind
                == DiscoveryOperationKind::Compensation
                && self.compensation_completion_is_durable(&snapshot)?;
            let interruption = match unfinished_operation.disposition {
                DiscoveryRecoveryDisposition::MarkInterrupted => {
                    DiscoveryInterruptionOutcome::ConfirmedNoExternalEffect
                }
                DiscoveryRecoveryDisposition::MarkUnknownOutcome => {
                    DiscoveryInterruptionOutcome::ExternalOutcomeUnknown
                }
            };
            let action = if compensation_already_durable {
                ProviderDiscoveryAction::CompensationSucceeded
            } else {
                ProviderDiscoveryAction::Interrupt {
                    operation: operation.kind,
                    outcome: interruption,
                }
            };
            let request_json =
                canonical_json_result(serde_json::to_value(&action), "discovery recovery action")?;
            let envelope = DiscoveryActionEnvelope {
                id: DiscoveryActionId::new(),
                expected_revision: snapshot.session.revision,
                request_sha256: sha256_hex(request_json.as_bytes()),
                action,
            };
            let transition = snapshot.session.apply(&envelope).map_err(|error| {
                CoreError::invalid(format!("recovery transition failed: {error}"))
            })?;
            let completed_outcome = if compensation_already_durable {
                DurableOperationOutcome::Succeeded
            } else {
                match unfinished_operation.disposition {
                    DiscoveryRecoveryDisposition::MarkInterrupted => {
                        DurableOperationOutcome::Interrupted
                    }
                    DiscoveryRecoveryDisposition::MarkUnknownOutcome => {
                        DurableOperationOutcome::OutcomeUnknown
                    }
                }
            };
            let write = DiscoveryTransitionWrite {
                transition,
                draft: DiscoveryJsonUpdate::Preserve,
                review: DiscoveryJsonUpdate::Preserve,
                new_evidence: Vec::new(),
                new_candidates: Vec::new(),
                approval: None,
                new_operation_id: None,
                completed_operation: Some(DiscoveryCompletedOperationWrite {
                    id: operation_id.clone(),
                    outcome: completed_outcome,
                }),
                prepared_commit: None,
                provider_graph: None,
                occurred_at: recovered_at,
            };
            self.persist_discovery_transition(&write)?;
            recovered.push(DiscoveryRecoveryResult {
                operation_id,
                session_id,
                state: write.transition.session.state,
                event: write.transition.event,
            });
        }
        Ok(recovered)
    }

    fn compensation_completion_is_durable(
        &self,
        snapshot: &DiscoverySessionSnapshot,
    ) -> CoreResult<bool> {
        let attempt_id = snapshot
            .session
            .commit_attempt_id
            .as_ref()
            .ok_or_else(|| corrupted("compensation recovery has no commit attempt"))?;
        let phase = self.get_discovery_commit_attempt(attempt_id)?.phase;
        if phase == DiscoveryCommitPhase::Compensated {
            return Ok(true);
        }
        if phase != DiscoveryCommitPhase::Compensating {
            return Ok(false);
        }
        let steps = self.list_discovery_compensation_steps(attempt_id)?;
        Ok(!steps.is_empty()
            && steps
                .iter()
                .all(|step| step.status == DiscoveryCompensationStatus::Completed))
    }
}

impl Storage {
    /// Captures the exact route-and-preset selection for an immutable commit
    /// plan. Both identifiers are read under the same storage lock.
    pub fn current_discovery_previous_selection(&self) -> CoreResult<DiscoveryPreviousSelection> {
        let connection = self.connection()?;
        load_discovery_previous_selection(&connection)
    }

    pub fn list_discovery_compensation_steps(
        &self,
        attempt_id: &DiscoveryCommitAttemptId,
    ) -> CoreResult<Vec<DiscoveryCompensationRecord>> {
        let connection = self.connection()?;
        let attempt = load_commit_attempt(&connection, attempt_id)?;
        let mut statement = connection
            .prepare(
                "SELECT id, commit_attempt_id, ordinal, action_id, step_kind, step_json,
                        status, attempt_count, last_failure_json, created_at,
                        updated_at, completed_at
                 FROM provider_discovery_compensation_steps
                 WHERE commit_attempt_id = ?1
                 ORDER BY ordinal DESC, id",
            )
            .map_err(database_error)?;
        statement
            .query_map([attempt_id.as_str()], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, u32>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, u32>(7)?,
                    row.get::<_, Option<String>>(8)?,
                    row.get::<_, String>(9)?,
                    row.get::<_, String>(10)?,
                    row.get::<_, Option<String>>(11)?,
                ))
            })
            .map_err(database_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(database_error)?
            .into_iter()
            .map(|row| decode_compensation_row(row, &attempt.plan))
            .collect()
    }

    /// Advances a compensation step without splitting failure state.
    ///
    /// A failed or unknown step must use the matching atomic transition API so
    /// the step, commit attempt, operation, session, receipt, audit, and outbox
    /// event commit together.
    #[allow(clippy::too_many_lines)]
    pub fn update_discovery_compensation_status(
        &self,
        step_id: &str,
        expected: DiscoveryCompensationStatus,
        next: DiscoveryCompensationStatus,
        failure: Option<&lorepia_domain::discovery::DiscoveryFailure>,
        updated_at: DateTime<Utc>,
    ) -> CoreResult<()> {
        validate_identifier("discovery compensation step id", step_id, 128)?;
        if matches!(
            next,
            DiscoveryCompensationStatus::Failed | DiscoveryCompensationStatus::OutcomeUnknown
        ) || failure.is_some()
        {
            return Err(CoreError::invalid(
                "compensation failures and unknown outcomes require their atomic step-and-session APIs",
            ));
        }
        if !compensation_status_transition_allowed(expected, next) {
            return Err(CoreError::invalid(
                "invalid discovery compensation status transition",
            ));
        }
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let context = transaction
            .query_row(
                "SELECT attempt.session_id, session.revision, attempt.phase,
                        session.state, step.step_kind, step.ordinal, attempt.id,
                        step.step_json
                 FROM provider_discovery_compensation_steps AS step
                 JOIN provider_discovery_commit_attempts AS attempt
                   ON attempt.id = step.commit_attempt_id
                 JOIN provider_discovery_sessions AS session
                   ON session.id = attempt.session_id
                 WHERE step.id = ?1 AND step.status = ?2",
                params![step_id, expected.as_str()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, u64>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                        row.get::<_, String>(4)?,
                        row.get::<_, u32>(5)?,
                        row.get::<_, String>(6)?,
                        row.get::<_, String>(7)?,
                    ))
                },
            )
            .optional()
            .map_err(database_error)?
            .ok_or_else(|| {
                CoreError::invalid("compensation step was missing or changed concurrently")
            })?;
        if context.2 != "compensating" || context.3 != "compensating" {
            return Err(CoreError::invalid(
                "compensation step work is not authorized by the active commit and session",
            ));
        }
        require_started_session_operation(
            &transaction,
            &DiscoverySessionId::from(context.0.clone()),
            "compensation",
        )?;
        let attempt_id =
            DiscoveryCommitAttemptId::parse(context.6.clone()).map_err(contract_error)?;
        let attempt = load_commit_attempt(&transaction, &attempt_id)?;
        let step = serde_json::from_str::<DiscoveryCompensationStep>(&context.7)
            .map_err(|_| corrupted("stored compensation step is invalid"))?;
        step.validate_against(&attempt.plan)
            .map_err(|_| corrupted("stored compensation target differs from its commit plan"))?;
        let stored_kind = enum_wire_result(
            serde_json::to_value(step.kind),
            "stored discovery compensation kind",
        )?;
        if stored_kind != context.4 || step.ordinal != context.5 {
            return Err(corrupted(
                "stored compensation columns differ from their typed step",
            ));
        }
        if next == DiscoveryCompensationStatus::Completed
            && step.kind != DiscoveryCompensationKind::RemoveCredentialSlot
        {
            return Err(CoreError::invalid(
                "only native credential removal may use generic compensation completion",
            ));
        }
        if next == DiscoveryCompensationStatus::InProgress {
            let higher_step_incomplete = transaction
                .query_row(
                    "SELECT EXISTS(
                         SELECT 1
                         FROM provider_discovery_compensation_steps
                         WHERE commit_attempt_id = ?1
                           AND ordinal > ?2
                           AND status <> 'completed'
                     )",
                    params![attempt.id.as_str(), context.5],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(database_error)?;
            if higher_step_incomplete {
                return Err(CoreError::invalid(
                    "compensation steps must start in reverse ordinal order",
                ));
            }
        }
        let completed_at =
            (next == DiscoveryCompensationStatus::Completed).then(|| updated_at.to_rfc3339());
        let changed = transaction
            .execute(
                "UPDATE provider_discovery_compensation_steps
                 SET status = ?2,
                     attempt_count = attempt_count + CASE WHEN ?2 = 'in_progress' THEN 1 ELSE 0 END,
                     last_failure_json = ?3,
                     updated_at = ?4,
                     completed_at = ?5
                 WHERE id = ?1 AND status = ?6",
                params![
                    step_id,
                    next.as_str(),
                    Option::<String>::None,
                    updated_at.to_rfc3339(),
                    completed_at,
                    expected.as_str(),
                ],
            )
            .map_err(database_error)?;
        if changed != 1 {
            return Err(CoreError::invalid("compensation step changed concurrently"));
        }
        if next == DiscoveryCompensationStatus::InProgress {
            append_audit(
                &transaction,
                &context.0,
                context.1,
                "compensation_started",
                None,
                Some(step_id),
                "discovery.audit.compensation_started",
                updated_at,
            )?;
        }
        transaction.commit().map_err(database_error)
    }

    /// Atomically records a compensation-step failure and its domain
    /// transition. This prevents a crash from leaving a failed step without
    /// the session failure that makes `ResumeCompensation` reachable.
    #[allow(clippy::too_many_lines)]
    pub fn fail_discovery_compensation_and_persist_transition(
        &self,
        step_id: &str,
        write: &DiscoveryTransitionWrite,
    ) -> CoreResult<PersistDiscoveryTransition> {
        validate_identifier("discovery compensation step id", step_id, 128)?;
        validate_transition_write(write)?;
        let transition = &write.transition;
        let failure =
            transition.session.failure.as_ref().ok_or_else(|| {
                CoreError::invalid("compensation failure transition has no failure")
            })?;
        failure.validate().map_err(contract_error)?;
        if transition.receipt.action_kind != "compensation_failed"
            || transition.session.state != DiscoveryState::Compensating
            || transition.event.failure.as_ref() != Some(failure)
            || write
                .completed_operation
                .as_ref()
                .is_none_or(|completed| completed.outcome != DurableOperationOutcome::Failed)
        {
            return Err(CoreError::invalid(
                "atomic compensation failure requires the exact failed operation transition",
            ));
        }
        let failure_json =
            encode_json_result(serde_json::to_value(failure), "compensation failure")?;
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let receipt_exists = transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM provider_discovery_action_receipts
                     WHERE action_id = ?1
                 )",
                [transition.receipt.action_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if !receipt_exists {
            let context = transaction
                .query_row(
                    "SELECT attempt.session_id, session.revision, attempt.phase,
                            session.state, step.step_kind, step.ordinal, attempt.id,
                            step.step_json, session.commit_attempt_id,
                            session.commit_plan_sha256
                     FROM provider_discovery_compensation_steps AS step
                     JOIN provider_discovery_commit_attempts AS attempt
                       ON attempt.id = step.commit_attempt_id
                     JOIN provider_discovery_sessions AS session
                       ON session.id = attempt.session_id
                     WHERE step.id = ?1 AND step.status = 'in_progress'",
                    [step_id],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, u64>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, String>(3)?,
                            row.get::<_, String>(4)?,
                            row.get::<_, u32>(5)?,
                            row.get::<_, String>(6)?,
                            row.get::<_, String>(7)?,
                            row.get::<_, Option<String>>(8)?,
                            row.get::<_, Option<String>>(9)?,
                        ))
                    },
                )
                .optional()
                .map_err(database_error)?
                .ok_or_else(|| {
                    CoreError::invalid(
                        "compensation step was missing, not in progress, or changed concurrently",
                    )
                })?;
            if context.0 != transition.session.id.as_str()
                || context.2 != "compensating"
                || context.3 != "compensating"
                || context.8.as_deref() != Some(context.6.as_str())
                || context.9.as_deref() != transition.session.commit_plan_sha256.as_deref()
            {
                return Err(CoreError::invalid(
                    "compensation failure does not match the active session and commit",
                ));
            }
            require_started_session_operation(
                &transaction,
                &transition.session.id,
                "compensation",
            )?;
            let attempt_id =
                DiscoveryCommitAttemptId::parse(context.6.clone()).map_err(contract_error)?;
            let attempt = load_commit_attempt(&transaction, &attempt_id)?;
            if attempt.session_id != transition.session.id
                || attempt.plan_sha256 != context.9.as_deref().unwrap_or_default()
            {
                return Err(corrupted(
                    "compensation failure commit binding is inconsistent",
                ));
            }
            let step = serde_json::from_str::<DiscoveryCompensationStep>(&context.7)
                .map_err(|_| corrupted("stored compensation step is invalid"))?;
            step.validate_against(&attempt.plan).map_err(|_| {
                corrupted("stored compensation target differs from its commit plan")
            })?;
            let stored_kind = enum_wire_result(
                serde_json::to_value(step.kind),
                "stored discovery compensation kind",
            )?;
            if stored_kind != context.4 || step.ordinal != context.5 {
                return Err(corrupted(
                    "stored compensation columns differ from their typed step",
                ));
            }
            let changed = transaction
                .execute(
                    "UPDATE provider_discovery_compensation_steps
                     SET status = 'failed',
                         last_failure_json = ?2,
                         updated_at = ?3,
                         completed_at = NULL
                     WHERE id = ?1 AND status = 'in_progress'",
                    params![step_id, failure_json, write.occurred_at.to_rfc3339()],
                )
                .map_err(database_error)?;
            if changed != 1 {
                return Err(CoreError::invalid("compensation step changed concurrently"));
            }
        }

        let result = persist_transition_in_transaction(&transaction, write)?;
        let stored = transaction
            .query_row(
                "SELECT step.status, step.last_failure_json, attempt.session_id,
                        session.commit_attempt_id, session.commit_plan_sha256,
                        step.step_kind, step.ordinal, step.step_json, attempt.id
                 FROM provider_discovery_compensation_steps AS step
                 JOIN provider_discovery_commit_attempts AS attempt
                   ON attempt.id = step.commit_attempt_id
                 JOIN provider_discovery_sessions AS session
                   ON session.id = attempt.session_id
                 WHERE step.id = ?1",
                [step_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, u32>(6)?,
                        row.get::<_, String>(7)?,
                        row.get::<_, String>(8)?,
                    ))
                },
            )
            .optional()
            .map_err(database_error)?
            .ok_or_else(|| corrupted("atomically failed compensation step disappeared"))?;
        if stored.0 != "failed"
            || stored.1.as_deref() != Some(failure_json.as_str())
            || stored.2 != transition.session.id.as_str()
            || stored.3.as_deref() != Some(stored.8.as_str())
            || stored.4.as_deref() != transition.session.commit_plan_sha256.as_deref()
        {
            return Err(corrupted(
                "atomically failed compensation step does not match its transition",
            ));
        }
        let attempt_id = DiscoveryCommitAttemptId::parse(stored.8).map_err(contract_error)?;
        let attempt = load_commit_attempt(&transaction, &attempt_id)?;
        let step = serde_json::from_str::<DiscoveryCompensationStep>(&stored.7)
            .map_err(|_| corrupted("stored compensation step is invalid"))?;
        step.validate_against(&attempt.plan)
            .map_err(|_| corrupted("stored compensation target differs from its commit plan"))?;
        let stored_kind = enum_wire_result(
            serde_json::to_value(step.kind),
            "stored discovery compensation kind",
        )?;
        if stored_kind != stored.5 || step.ordinal != stored.6 {
            return Err(corrupted(
                "stored compensation columns differ from their typed step",
            ));
        }
        transaction.commit().map_err(database_error)?;
        Ok(result)
    }

    /// Atomically records an unknown compensation outcome across the step,
    /// commit attempt, operation, session, receipt, and event outbox.
    #[allow(clippy::too_many_lines)]
    pub fn mark_discovery_compensation_unknown_and_persist_transition(
        &self,
        step_id: &str,
        write: &DiscoveryTransitionWrite,
    ) -> CoreResult<PersistDiscoveryTransition> {
        validate_identifier("discovery compensation step id", step_id, 128)?;
        validate_transition_write(write)?;
        let transition = &write.transition;
        if transition.receipt.action_kind != "external_outcome_became_unknown"
            || transition.session.state != DiscoveryState::UnknownOutcome
            || transition.session.unknown_operation != Some(DiscoveryOperationKind::Compensation)
            || transition.session.failure.is_some()
            || write.completed_operation.as_ref().is_none_or(|completed| {
                completed.outcome != DurableOperationOutcome::OutcomeUnknown
            })
        {
            return Err(CoreError::invalid(
                "atomic compensation unknown outcome requires the exact persistent transition",
            ));
        }

        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let receipt_exists = transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM provider_discovery_action_receipts
                     WHERE action_id = ?1
                 )",
                [transition.receipt.action_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if !receipt_exists {
            let context = transaction
                .query_row(
                    "SELECT attempt.session_id, attempt.phase, session.state,
                            step.step_kind, step.ordinal, attempt.id, step.step_json,
                            session.commit_attempt_id, session.commit_plan_sha256
                     FROM provider_discovery_compensation_steps AS step
                     JOIN provider_discovery_commit_attempts AS attempt
                       ON attempt.id = step.commit_attempt_id
                     JOIN provider_discovery_sessions AS session
                       ON session.id = attempt.session_id
                     WHERE step.id = ?1 AND step.status = 'in_progress'",
                    [step_id],
                    |row| {
                        Ok((
                            row.get::<_, String>(0)?,
                            row.get::<_, String>(1)?,
                            row.get::<_, String>(2)?,
                            row.get::<_, String>(3)?,
                            row.get::<_, u32>(4)?,
                            row.get::<_, String>(5)?,
                            row.get::<_, String>(6)?,
                            row.get::<_, Option<String>>(7)?,
                            row.get::<_, Option<String>>(8)?,
                        ))
                    },
                )
                .optional()
                .map_err(database_error)?
                .ok_or_else(|| {
                    CoreError::invalid(
                        "compensation step was missing, not in progress, or changed concurrently",
                    )
                })?;
            if context.0 != transition.session.id.as_str()
                || context.1 != "compensating"
                || context.2 != "compensating"
                || context.7.as_deref() != Some(context.5.as_str())
                || context.8.as_deref() != transition.session.commit_plan_sha256.as_deref()
            {
                return Err(CoreError::invalid(
                    "unknown compensation outcome does not match the active session and commit",
                ));
            }
            require_started_session_operation(
                &transaction,
                &transition.session.id,
                "compensation",
            )?;
            let attempt_id =
                DiscoveryCommitAttemptId::parse(context.5.clone()).map_err(contract_error)?;
            let attempt = load_commit_attempt(&transaction, &attempt_id)?;
            if attempt.session_id != transition.session.id
                || attempt.plan_sha256 != context.8.as_deref().unwrap_or_default()
            {
                return Err(corrupted(
                    "unknown compensation outcome commit binding is inconsistent",
                ));
            }
            let step = serde_json::from_str::<DiscoveryCompensationStep>(&context.6)
                .map_err(|_| corrupted("stored compensation step is invalid"))?;
            step.validate_against(&attempt.plan).map_err(|_| {
                corrupted("stored compensation target differs from its commit plan")
            })?;
            let stored_kind = enum_wire_result(
                serde_json::to_value(step.kind),
                "stored discovery compensation kind",
            )?;
            if stored_kind != context.3 || step.ordinal != context.4 {
                return Err(corrupted(
                    "stored compensation columns differ from their typed step",
                ));
            }
        }

        let result = persist_transition_in_transaction(&transaction, write)?;
        let stored = transaction
            .query_row(
                "SELECT step.status, attempt.phase, session.state,
                        session.unknown_operation, session.active_operation_id,
                        attempt.session_id, session.commit_attempt_id,
                        session.commit_plan_sha256, attempt.plan_sha256
                 FROM provider_discovery_compensation_steps AS step
                 JOIN provider_discovery_commit_attempts AS attempt
                   ON attempt.id = step.commit_attempt_id
                 JOIN provider_discovery_sessions AS session
                   ON session.id = attempt.session_id
                 WHERE step.id = ?1",
                [step_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, Option<String>>(3)?,
                        row.get::<_, Option<String>>(4)?,
                        row.get::<_, String>(5)?,
                        row.get::<_, Option<String>>(6)?,
                        row.get::<_, Option<String>>(7)?,
                        row.get::<_, String>(8)?,
                    ))
                },
            )
            .optional()
            .map_err(database_error)?
            .ok_or_else(|| corrupted("unknown compensation step disappeared"))?;
        if stored.0 != "outcome_unknown"
            || stored.1 != "outcome_unknown"
            || stored.2 != "unknown_outcome"
            || stored.3.as_deref() != Some("compensation")
            || stored.4.is_some()
            || stored.5 != transition.session.id.as_str()
            || stored.6.as_deref()
                != transition
                    .session
                    .commit_attempt_id
                    .as_ref()
                    .map(DiscoveryCommitAttemptId::as_str)
            || stored.7.as_deref() != Some(stored.8.as_str())
        {
            return Err(corrupted(
                "unknown compensation outcome was not recorded atomically",
            ));
        }
        transaction.commit().map_err(database_error)?;
        Ok(result)
    }

    #[allow(clippy::too_many_lines)]
    pub fn restore_discovery_previous_selection(
        &self,
        attempt_id: &DiscoveryCommitAttemptId,
        completed_at: DateTime<Utc>,
    ) -> CoreResult<()> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let attempt = load_commit_attempt(&transaction, attempt_id)?;
        if attempt.phase != DiscoveryCommitPhase::Compensating {
            return Err(CoreError::invalid(
                "selection restoration requires the compensating phase",
            ));
        }
        let state = transaction
            .query_row(
                "SELECT state
                 FROM provider_discovery_sessions
                 WHERE id = ?1 AND commit_attempt_id = ?2",
                params![attempt.session_id.as_str(), attempt.id.as_str()],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(database_error)?
            .ok_or_else(|| corrupted("compensating commit is detached from its session"))?;
        if state != "compensating" {
            return Err(CoreError::invalid(
                "selection restoration requires a compensating discovery session",
            ));
        }
        require_started_session_operation(&transaction, &attempt.session_id, "compensation")?;
        let rows = {
            let mut statement = transaction
                .prepare(
                    "SELECT id, ordinal, step_json, status
                     FROM provider_discovery_compensation_steps
                     WHERE commit_attempt_id = ?1
                       AND step_kind = 'restore_previous_selection'
                     ORDER BY ordinal, id",
                )
                .map_err(database_error)?;
            statement
                .query_map([attempt.id.as_str()], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, u32>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                })
                .map_err(database_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(database_error)?
        };
        let [(step_id, ordinal, step_json, status)] = rows.as_slice() else {
            return Err(corrupted(
                "compensation requires exactly one restore-previous-selection step",
            ));
        };
        if status == "completed" {
            transaction.commit().map_err(database_error)?;
            return Ok(());
        }
        if status != "in_progress" {
            return Err(CoreError::invalid(
                "selection restoration step must be in progress",
            ));
        }
        let step = serde_json::from_str::<DiscoveryCompensationStep>(step_json)
            .map_err(|_| corrupted("stored selection restoration step is invalid"))?;
        step.validate_against(&attempt.plan)
            .map_err(|_| corrupted("selection restoration target differs from its commit plan"))?;
        let DiscoveryCompensationTarget::RestorePreviousSelection { previous_selection } =
            &step.target
        else {
            return Err(corrupted(
                "selection restoration step has the wrong typed target",
            ));
        };
        let higher_step_incomplete = transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1
                     FROM provider_discovery_compensation_steps
                     WHERE commit_attempt_id = ?1
                       AND ordinal > ?2
                       AND status <> 'completed'
                 )",
                params![attempt.id.as_str(), ordinal],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if higher_step_incomplete {
            return Err(CoreError::invalid(
                "selection restoration must follow reverse recipe order",
            ));
        }
        restore_discovery_provider_selection(&transaction, previous_selection)?;
        let changed = transaction
            .execute(
                "UPDATE provider_discovery_compensation_steps
                 SET status = 'completed',
                     last_failure_json = NULL,
                     updated_at = ?2,
                     completed_at = ?2
                 WHERE id = ?1
                   AND step_kind = 'restore_previous_selection'
                   AND status = 'in_progress'",
                params![step_id, completed_at.to_rfc3339()],
            )
            .map_err(database_error)?;
        if changed != 1 {
            return Err(CoreError::invalid(
                "selection restoration step changed concurrently",
            ));
        }
        transaction.commit().map_err(database_error)
    }

    /// Removes exactly the graph named by a compensating commit plan.
    ///
    /// Foreign keys deliberately make this fail if any generation has begun to
    /// depend on the graph. Credential-vault deletion remains a separate native
    /// compensation step and is never attempted here.
    #[allow(clippy::too_many_lines)]
    pub fn compensate_discovered_provider_graph(
        &self,
        attempt_id: &DiscoveryCommitAttemptId,
        completed_at: DateTime<Utc>,
    ) -> CoreResult<()> {
        let mut connection = self.connection()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(database_error)?;
        let attempt = load_commit_attempt(&transaction, attempt_id)?;
        if attempt.phase != DiscoveryCommitPhase::Compensating {
            return Err(CoreError::invalid(
                "provider graph compensation requires the compensating phase",
            ));
        }
        let state = transaction
            .query_row(
                "SELECT state
                 FROM provider_discovery_sessions
                 WHERE id = ?1 AND commit_attempt_id = ?2",
                params![attempt.session_id.as_str(), attempt.id.as_str()],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(database_error)?
            .ok_or_else(|| corrupted("compensating commit is detached from its session"))?;
        if state != "compensating" {
            return Err(CoreError::invalid(
                "provider graph compensation requires a compensating discovery session",
            ));
        }
        require_started_session_operation(&transaction, &attempt.session_id, "compensation")?;
        let graph_steps = {
            let mut statement = transaction
                .prepare(
                    "SELECT id, status, ordinal, step_json
                     FROM provider_discovery_compensation_steps
                     WHERE commit_attempt_id = ?1
                       AND step_kind = 'remove_connection_graph'
                     ORDER BY ordinal, id",
                )
                .map_err(database_error)?;
            statement
                .query_map([attempt.id.as_str()], |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, u32>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                })
                .map_err(database_error)?
                .collect::<Result<Vec<_>, _>>()
                .map_err(database_error)?
        };
        let [(step_id, step_status, step_ordinal, step_json)] = graph_steps.as_slice() else {
            return Err(corrupted(
                "compensation requires exactly one remove-connection-graph step",
            ));
        };
        let step = serde_json::from_str::<DiscoveryCompensationStep>(step_json)
            .map_err(|_| corrupted("stored graph compensation step is invalid"))?;
        step.validate_against(&attempt.plan)
            .map_err(|_| corrupted("graph compensation target differs from its commit plan"))?;
        if !matches!(
            &step.target,
            DiscoveryCompensationTarget::RemoveConnectionGraph { connection_id }
                if connection_id == &attempt.plan.connection_id
        ) {
            return Err(corrupted(
                "graph compensation step has the wrong typed target",
            ));
        }
        let higher_step_incomplete = transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1
                     FROM provider_discovery_compensation_steps
                     WHERE commit_attempt_id = ?1
                       AND ordinal > ?2
                       AND status <> 'completed'
                 )",
                params![attempt.id.as_str(), step_ordinal],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if higher_step_incomplete {
            return Err(CoreError::invalid(
                "provider graph compensation must follow reverse recipe order",
            ));
        }
        let stored_graph = load_discovered_provider_graph_rows(
            &transaction,
            &attempt.plan.template_id,
            attempt.plan.template_version,
            &attempt.plan.connection_id,
        )?;
        if stored_graph.is_none() {
            let planned_route_remains =
                attempt
                    .plan
                    .model_route_ids
                    .iter()
                    .try_fold(false, |found, route_id| {
                        if found {
                            return Ok(true);
                        }
                        transaction
                            .query_row(
                                "SELECT EXISTS(SELECT 1 FROM provider_models WHERE id = ?1)",
                                [route_id.as_str()],
                                |row| row.get::<_, bool>(0),
                            )
                            .map_err(database_error)
                    })?;
            if planned_route_remains {
                return Err(corrupted(
                    "compensated connection is absent but one of its planned routes remains",
                ));
            }
            if step_status == "completed" {
                transaction.commit().map_err(database_error)?;
                return Ok(());
            }
            if step_status != "in_progress" {
                return Err(CoreError::invalid(
                    "provider graph compensation step must be in progress",
                ));
            }
            mark_connection_graph_step_completed(&transaction, step_id, completed_at)?;
            transaction.commit().map_err(database_error)?;
            return Ok(());
        }
        if step_status != "in_progress" {
            return Err(CoreError::invalid(
                "provider graph compensation step must be in progress",
            ));
        }
        let Some(stored_graph) = stored_graph else {
            return Err(corrupted("provider graph disappeared during compensation"));
        };
        let expected_ownership_hash =
            graph_ownership_audit_hash(&transaction, &attempt.session_id)?;
        if stored_provider_graph_ownership_hash(&stored_graph)? != expected_ownership_hash {
            return Err(CoreError::invalid(
                "refusing to compensate a provider graph changed after discovery commit",
            ));
        }
        let stored_routes = stored_graph
            .routes
            .iter()
            .map(|route| route.id.as_str().to_owned())
            .collect::<BTreeSet<_>>();
        let planned_routes = attempt
            .plan
            .model_route_ids
            .iter()
            .map(|id| id.as_str().to_owned())
            .collect::<BTreeSet<_>>();
        if stored_routes != planned_routes {
            return Err(CoreError::invalid(
                "refusing to compensate a provider graph that changed after commit",
            ));
        }
        clear_provider_selections_for_connection(
            &transaction,
            attempt.plan.connection_id.as_str(),
        )?;
        transaction
            .execute(
                "DELETE FROM generation_presets
                 WHERE model_route_id IN (
                     SELECT id FROM provider_models WHERE connection_id = ?1
                 )",
                [attempt.plan.connection_id.as_str()],
            )
            .map_err(database_error)?;
        transaction
            .execute(
                "DELETE FROM model_capability_observations
                 WHERE model_route_id IN (
                     SELECT id FROM provider_models WHERE connection_id = ?1
                 )",
                [attempt.plan.connection_id.as_str()],
            )
            .map_err(database_error)?;
        transaction
            .execute(
                "DELETE FROM provider_models WHERE connection_id = ?1",
                [attempt.plan.connection_id.as_str()],
            )
            .map_err(database_error)?;
        let deleted = transaction
            .execute(
                "DELETE FROM provider_connections
                 WHERE id = ?1 AND template_id = ?2 AND template_version = ?3",
                params![
                    attempt.plan.connection_id.as_str(),
                    attempt.plan.template_id.as_str(),
                    attempt.plan.template_version,
                ],
            )
            .map_err(database_error)?;
        if deleted != 1 {
            return Err(CoreError::invalid(
                "committed provider connection was missing or changed",
            ));
        }
        if graph_template_was_created(&transaction, &attempt.session_id)? {
            transaction
                .execute(
                    "DELETE FROM provider_templates
                     WHERE id = ?1 AND version = ?2 AND source_kind = 'user_discovered'
                       AND NOT EXISTS (
                           SELECT 1 FROM provider_connections
                           WHERE template_id = ?1 AND template_version = ?2
                       )",
                    params![
                        attempt.plan.template_id.as_str(),
                        attempt.plan.template_version
                    ],
                )
                .map_err(database_error)?;
        }
        ensure_foreign_keys_clean(&transaction)?;
        mark_connection_graph_step_completed(&transaction, step_id, completed_at)?;
        transaction.commit().map_err(database_error)
    }
}

fn mark_connection_graph_step_completed(
    transaction: &Transaction<'_>,
    step_id: &str,
    completed_at: DateTime<Utc>,
) -> CoreResult<()> {
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_compensation_steps
             SET status = 'completed',
                 last_failure_json = NULL,
                 updated_at = ?2,
                 completed_at = ?2
             WHERE id = ?1
               AND step_kind = 'remove_connection_graph'
               AND status = 'in_progress'",
            params![step_id, completed_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "provider graph compensation step changed concurrently",
        ));
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn persist_transition_in_transaction(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<PersistDiscoveryTransition> {
    let transition = &write.transition;
    let session_id = transition.session.id.as_str();
    let (stored_draft, stored_review) = transaction
        .query_row(
            "SELECT draft_json, review_diff_json
             FROM provider_discovery_sessions
             WHERE id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "provider discovery session was not found",
                false,
            )
        })?;

    let draft_json = resolve_draft_update(&write.draft, stored_draft)?;
    let review_json = resolve_review_update(&write.review, stored_review)?;
    let error_json = transition
        .session
        .failure
        .as_ref()
        .map(|failure| encode_json_result(serde_json::to_value(failure), "discovery failure"))
        .transpose()?;
    let recovery_json = transition
        .session
        .recovery
        .as_ref()
        .map(|recovery| {
            encode_json_result(
                serde_json::to_value(recovery),
                "discovery recovery checkpoint",
            )
        })
        .transpose()?;
    let state = enum_wire_result(
        serde_json::to_value(transition.session.state),
        "discovery state",
    )?;
    let unknown_operation = transition
        .session
        .unknown_operation
        .map(|operation| {
            enum_wire_result(
                serde_json::to_value(operation),
                "discovery unknown operation",
            )
        })
        .transpose()?;
    let event_json =
        encode_json_result(serde_json::to_value(&transition.event), "discovery event")?;
    let response_json = encode_json_result(
        serde_json::to_value(transition),
        "discovery action response",
    )?;
    let receipt_outcome = enum_wire_result(
        serde_json::to_value(transition.receipt.outcome),
        "discovery receipt outcome",
    )?;
    let occurred_at = write.occurred_at.to_rfc3339();

    let approval_json = write
        .approval
        .as_ref()
        .map(|approval| encode_approval_grant(&approval.grant))
        .transpose()?;
    let approval_kind = write
        .approval
        .as_ref()
        .map(|approval| approval_kind(&approval.grant));
    let approval_decision = write
        .approval
        .as_ref()
        .map(|approval| {
            enum_wire_result(
                serde_json::to_value(approval.decision),
                "discovery approval decision",
            )
        })
        .transpose()?;
    let approval_candidate_id =
        write
            .approval
            .as_ref()
            .and_then(|approval| match &approval.grant {
                DiscoveryApprovalGrant::TemplateSelection { candidate_id } => {
                    Some(candidate_id.as_str())
                }
                _ => None,
            });
    let approval = write.approval.as_ref().map(|record| NewDiscoveryApproval {
        id: record.id.as_str(),
        approval_kind: approval_kind.expect("approval kind exists with record"),
        candidate_id: approval_candidate_id,
        decision: approval_decision
            .as_deref()
            .expect("approval decision exists with record"),
        grant_json: approval_json
            .as_deref()
            .expect("approval JSON exists with record"),
    });

    let (durable_effect, operation_kind, operation_approval) =
        map_discovery_effect(&transition.effect);
    let operation_kind_wire = operation_kind
        .map(|kind| enum_wire_result(serde_json::to_value(kind), "discovery operation kind"))
        .transpose()?;
    let side_effect_wire = operation_kind
        .map(|kind| {
            enum_wire_result(
                serde_json::to_value(kind.side_effect_class()),
                "discovery side-effect class",
            )
        })
        .transpose()?;
    let operation = write
        .new_operation_id
        .as_ref()
        .map(|operation_id| NewDiscoveryOperation {
            id: operation_id.as_str(),
            operation_kind: operation_kind_wire
                .as_deref()
                .expect("operation kind exists with operation id"),
            side_effect_class: side_effect_wire
                .as_deref()
                .expect("side-effect class exists with operation id"),
            approval_id: operation_approval.map(|binding| binding.approval_id.as_str()),
            approval_grant_sha256: operation_approval.map(|binding| binding.grant_sha256.as_str()),
        });
    let completed_operation =
        write
            .completed_operation
            .as_ref()
            .map(|completed| CompletedDiscoveryOperation {
                id: completed.id.as_str(),
                outcome: completed.outcome,
            });

    let prepared_plan_json = write
        .prepared_commit
        .as_ref()
        .map(|commit| encode_commit_plan_json(&commit.plan))
        .transpose()?;
    let prepared_steps_json = write
        .prepared_commit
        .as_ref()
        .map(|commit| {
            commit
                .compensation_steps
                .iter()
                .map(|step| {
                    encode_json_result(
                        serde_json::to_value(&step.step),
                        "discovery compensation step",
                    )
                })
                .collect::<CoreResult<Vec<_>>>()
        })
        .transpose()?
        .unwrap_or_default();
    let prepared_step_kinds = write
        .prepared_commit
        .as_ref()
        .map(|commit| {
            commit
                .compensation_steps
                .iter()
                .map(|step| {
                    enum_wire_result(
                        serde_json::to_value(step.step.kind),
                        "discovery compensation kind",
                    )
                })
                .collect::<CoreResult<Vec<_>>>()
        })
        .transpose()?
        .unwrap_or_default();
    let prepared_steps = write
        .prepared_commit
        .as_ref()
        .map(|commit| {
            commit
                .compensation_steps
                .iter()
                .zip(prepared_steps_json.iter())
                .zip(prepared_step_kinds.iter())
                .map(
                    |((step, step_json), step_kind)| NewDiscoveryCompensationStep {
                        id: &step.id,
                        ordinal: step.step.ordinal,
                        action_id: step.step.action_id.as_str(),
                        step_kind,
                        step_json,
                    },
                )
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let prepared_commit = write
        .prepared_commit
        .as_ref()
        .map(|commit| NewDiscoveryCommitAttempt {
            id: commit.plan.attempt_id.as_str(),
            attempt_number: commit.attempt_number,
            plan_sha256: &commit.plan_sha256,
            plan_json: prepared_plan_json
                .as_deref()
                .expect("commit JSON exists with commit"),
            reuse_existing: commit.reuse_existing,
            compensation_steps: &prepared_steps,
        });

    let durable = DurableDiscoveryTransition {
        session_id,
        expected_revision: transition.previous_revision,
        resulting_revision: transition.session.revision,
        event_sequence: transition.event.sequence,
        next_event_sequence: transition.session.next_event_sequence,
        state: &state,
        draft_json: draft_json.as_deref(),
        review_diff_json: review_json.as_deref(),
        error_json: error_json.as_deref(),
        recovery_json: recovery_json.as_deref(),
        unknown_operation: unknown_operation.as_deref(),
        manifest_sha256: transition.session.manifest_sha256.as_deref(),
        commit_plan_sha256: transition.session.commit_plan_sha256.as_deref(),
        commit_attempt_id: transition
            .session
            .commit_attempt_id
            .as_ref()
            .map(DiscoveryCommitAttemptId::as_str),
        committed_connection_id: transition
            .session
            .committed_connection_id
            .as_ref()
            .map(lorepia_domain::ProviderConnectionId::as_str),
        cancellation_pending: transition.session.cancellation_pending,
        event_id: transition.event.id.as_str(),
        event_version: transition.event.version,
        event_json: &event_json,
        effect: durable_effect,
        action_id: transition.receipt.action_id.as_str(),
        action_kind: &transition.receipt.action_kind,
        action_approval_id: write.approval.as_ref().map(|record| record.id.as_str()),
        request_sha256: &transition.receipt.request_sha256,
        response_json: &response_json,
        receipt_outcome: &receipt_outcome,
        audit_kind: audit_kind_for_action(&transition.receipt.action_kind),
        audit_summary_key: "discovery.audit.transition_applied",
        occurred_at: &occurred_at,
        operation,
        completed_operation,
        approval,
        commit: prepared_commit,
    };
    let receipt_exists = transaction
        .query_row(
            "SELECT EXISTS(
                 SELECT 1
                 FROM provider_discovery_action_receipts
                 WHERE action_id = ?1
             )",
            [transition.receipt.action_id.as_str()],
            |row| row.get::<_, bool>(0),
        )
        .map_err(database_error)?;
    if receipt_exists {
        return discovery::persist_discovery_transition_in_transaction(transaction, &durable)
            .map_err(discovery_error);
    }
    validate_completed_operation_binding(transaction, write)?;
    for evidence in &write.new_evidence {
        insert_evidence_in_transaction(transaction, evidence)?;
    }
    for candidate in &write.new_candidates {
        insert_candidate_in_transaction(transaction, candidate, transition.previous_revision)?;
    }
    if let DiscoveryJsonUpdate::Replace(review) = &write.review {
        validate_review_evidence_references(transaction, &transition.session.id, review)?;
    }
    if let Some(approval) = &write.approval {
        validate_approval_references(transaction, approval)?;
    }
    if let Some(commit) = &write.prepared_commit {
        validate_prepared_commit_session_binding(transaction, commit)?;
    }
    if let Some(graph) = &write.provider_graph {
        apply_provider_graph_in_transaction(
            transaction,
            graph,
            transition.previous_revision,
            write.occurred_at,
        )?;
    }
    finalize_commit_failed_before_apply(transaction, write)?;
    reconcile_discovery_saga_ledger(transaction, write)?;
    validate_terminal_compensation_transition(transaction, write)?;
    let result = discovery::persist_discovery_transition_in_transaction(transaction, &durable)
        .map_err(discovery_error)?;
    if transition.session.state == DiscoveryState::Ready {
        complete_commit_attempt_for_ready_transition(transaction, transition, write.occurred_at)?;
    }
    Ok(result)
}

fn validate_initial_discovery_draft(
    value: &Value,
    input: &SanitizedDiscoveryInput,
) -> CoreResult<()> {
    const EXPECTED_KEYS: [&str; 15] = [
        "schema_version",
        "source",
        "deterministic",
        "evidence_ids",
        "extra_evidence_ids",
        "selected_candidate_id",
        "template",
        "connection",
        "routes",
        "observations",
        "presets",
        "credential_approval_id",
        "probe_route_ids",
        "probe_failure_count",
        "assistant",
    ];
    validate_redacted_value(value)?;
    let object = value
        .as_object()
        .ok_or_else(|| CoreError::invalid("initial discovery draft must be a JSON object"))?;
    if object.len() != EXPECTED_KEYS.len()
        || EXPECTED_KEYS.iter().any(|key| !object.contains_key(*key))
        || object.get("schema_version").and_then(Value::as_u64) != Some(1)
        || object.get("probe_failure_count").and_then(Value::as_u64) != Some(0)
        || ["selected_candidate_id", "template", "connection"]
            .into_iter()
            .chain(["credential_approval_id", "assistant"])
            .any(|key| !object[key].is_null())
        || [
            "evidence_ids",
            "extra_evidence_ids",
            "routes",
            "observations",
            "presets",
            "probe_route_ids",
        ]
        .into_iter()
        .any(|key| {
            object[key]
                .as_array()
                .is_none_or(|values| !values.is_empty())
        })
    {
        return Err(CoreError::invalid(
            "initial discovery draft must contain only pristine source intent",
        ));
    }
    let source = object["source"]
        .as_object()
        .ok_or_else(|| CoreError::invalid("initial discovery source intent is invalid"))?;
    match source.get("kind").and_then(Value::as_str) {
        Some("site") if source.len() == 1 && object["deterministic"].is_null() => Ok(()),
        Some("curl") if source.len() == 1 => {
            validate_initial_curl_deterministic_output(&object["deterministic"], input)
        }
        Some("known_provider") if source.len() == 2 => {
            if !object["deterministic"].is_null() {
                return Err(CoreError::invalid(
                    "known-provider discovery cannot begin with transient deterministic output",
                ));
            }
            let template_id = source
                .get("template_id")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    CoreError::invalid("known-provider source intent has no template identifier")
                })?;
            validate_identifier("known-provider source template id", template_id, 256)?;
            if looks_like_secret(template_id) {
                return Err(CoreError::invalid(
                    "known-provider source template id resembles credential material",
                ));
            }
            Ok(())
        }
        _ => Err(CoreError::invalid(
            "initial discovery source intent is unsupported or contains payload data",
        )),
    }
}

#[allow(clippy::too_many_lines)]
fn validate_initial_curl_deterministic_output(
    value: &Value,
    input: &SanitizedDiscoveryInput,
) -> CoreResult<()> {
    let output = serde_json::from_value::<InitialDeterministicDiscoveryOutput>(value.clone())
        .map_err(|_| {
            CoreError::invalid("initial cURL deterministic output has an invalid schema")
        })?;
    let canonical = serde_json::to_value(&output)
        .map_err(|_| CoreError::internal("cannot canonicalize cURL deterministic output"))?;
    if canonical != *value {
        return Err(CoreError::invalid(
            "initial cURL deterministic output contains non-canonical fields",
        ));
    }
    if output.schema_version != DETERMINISTIC_DISCOVERY_SCHEMA_VERSION
        || output.evidence.len() != 1
        || output.family_candidates.len() > 5
        || output.manifest_candidates.len() > 5
        || output.connection_hints.len() > 5
        || !output.fetch_issues.is_empty()
        || output.fetch_stopped_by_budget
    {
        return Err(CoreError::invalid(
            "initial cURL deterministic output violates its bounded contract",
        ));
    }

    let input_origin = CanonicalOrigin::parse(input.site_url.as_str())
        .map_err(|_| CoreError::invalid("initial cURL input site URL is not an origin"))?;
    let evidence = &output.evidence[0];
    if evidence.kind != "sanitized_curl_request"
        || evidence.source_origin != input_origin
        || evidence.redaction_version != DISCOVERY_REDACTION_VERSION
    {
        return Err(CoreError::invalid(
            "initial cURL evidence is not bound to the sanitized input origin",
        ));
    }
    validate_sha256(
        "initial cURL evidence content hash",
        &evidence.content_sha256,
    )?;
    let extracted =
        serde_json::from_value::<InitialSanitizedCurlEvidence>(evidence.extracted_json.clone())
            .map_err(|_| {
                CoreError::invalid("initial cURL evidence has an invalid sanitized shape")
            })?;
    let canonical_extracted = serde_json::to_value(&extracted)
        .map_err(|_| CoreError::internal("cannot canonicalize sanitized cURL evidence"))?;
    if canonical_extracted != evidence.extracted_json {
        return Err(CoreError::invalid(
            "initial cURL evidence contains non-canonical fields",
        ));
    }
    let extracted_bytes = serde_json::to_vec(&evidence.extracted_json)
        .map_err(|_| CoreError::internal("cannot hash sanitized cURL evidence"))?;
    let extracted_sha256 = format!("{:x}", Sha256::digest(extracted_bytes));
    if evidence.content_sha256 != extracted_sha256
        || extracted.origin != evidence.source_origin
        || extracted.trust != "sanitized_curl_structure"
    {
        return Err(CoreError::invalid(
            "initial cURL evidence content hash or provenance is invalid",
        ));
    }
    validate_sha256(
        "initial cURL source path hash",
        &extracted.source_path_sha256,
    )?;
    if extracted.query_parameter_names.len() > 64
        || extracted.header_names.len() > 64
        || extracted.auth_hints.len() > 64
        || extracted.api_family_candidates.len() > 5
    {
        return Err(CoreError::invalid(
            "initial cURL evidence exceeds parser collection bounds",
        ));
    }
    for name in &extracted.query_parameter_names {
        validate_identifier("initial cURL query parameter name", name, 256)?;
    }
    for hint in &extracted.auth_hints {
        if let InitialCurlAuthHint::ApiKeyQuery { parameter_name } = hint {
            validate_identifier(
                "initial cURL authentication query parameter name",
                parameter_name,
                256,
            )?;
        }
    }

    for (index, candidate) in output.family_candidates.iter().enumerate() {
        if candidate.confidence != InitialDiscoveryCandidateConfidence::Structural
            || candidate.evidence_indices.as_slice() != [0]
            || !extracted
                .api_family_candidates
                .contains(&candidate.api_family)
            || output.family_candidates[..index]
                .iter()
                .any(|previous| previous.api_family == candidate.api_family)
        {
            return Err(CoreError::invalid(
                "initial cURL family candidate has invalid evidence provenance",
            ));
        }
    }
    for (index, candidate) in output.manifest_candidates.iter().enumerate() {
        validate_sha256(
            "initial cURL manifest candidate hash",
            &candidate.manifest_sha256,
        )?;
        let manifest_json = canonical_json_result(
            serde_json::to_value(&candidate.template.default_manifest),
            "initial cURL provider manifest",
        )?;
        let actual_manifest_sha256 = sha256_hex(manifest_json.as_bytes());
        let expected_template_id = format!("discovered-{}", candidate.manifest_sha256);
        if candidate.confidence != InitialDiscoveryCandidateConfidence::Structural
            || !candidate.generation_endpoint_evidenced
            || candidate.model_endpoint_evidenced
            || candidate.evidence_indices.as_slice() != [0]
            || candidate.manifest_sha256 != actual_manifest_sha256
            || candidate.template.id.as_str() != expected_template_id
            || candidate.template.manifest_version != 1
            || candidate.template.source != TemplateSource::UserDiscovered
            || candidate.template.api_family != candidate.template.default_manifest.api_family
            || !output
                .family_candidates
                .iter()
                .any(|family| family.api_family == candidate.template.api_family)
            || output.manifest_candidates[..index]
                .iter()
                .any(|previous| previous.manifest_sha256 == candidate.manifest_sha256)
        {
            return Err(CoreError::invalid(
                "initial cURL manifest candidate has invalid deterministic provenance",
            ));
        }
        let default_origin = candidate
            .template
            .default_manifest
            .default_api_origin
            .as_ref();
        if input.connection_options.network_mode == ProviderNetworkMode::ApprovedLocalNetwork {
            if default_origin.is_some() || !candidate.template.default_manifest.sources.is_empty() {
                return Err(CoreError::invalid(
                    "initial LAN cURL manifest promoted connection-specific authority",
                ));
            }
        } else if default_origin != Some(&evidence.source_origin) {
            return Err(CoreError::invalid(
                "initial cURL manifest origin does not match sanitized evidence",
            ));
        }
    }

    for (index, hint) in output.connection_hints.iter().enumerate() {
        if hint.source != InitialConnectionOriginHintSource::SanitizedCurlRequest
            || hint.api_origin != evidence.source_origin
            || hint.network_mode != input.connection_options.network_mode
            || hint.evidence_indices.as_slice() != [0]
            || hint.requires_credential_origin_approval != (hint.auth != AuthBinding::None)
            || !output
                .manifest_candidates
                .iter()
                .any(|candidate| candidate.template.api_family == hint.api_family)
            || output.connection_hints[..index].iter().any(|previous| {
                previous.api_family == hint.api_family
                    && previous.api_origin == hint.api_origin
                    && previous.api_base_path == hint.api_base_path
            })
        {
            return Err(CoreError::invalid(
                "initial cURL connection hint has invalid deterministic provenance",
            ));
        }
    }

    let expected_selected = if output.manifest_candidates.len() == 1 {
        Some(&output.manifest_candidates[0].template)
    } else {
        None
    };
    if output.selected_template.as_ref() != expected_selected {
        return Err(CoreError::invalid(
            "initial cURL selected template is not bound to the candidate set",
        ));
    }
    Ok(())
}

fn validate_transition_write(write: &DiscoveryTransitionWrite) -> CoreResult<()> {
    let transition = &write.transition;
    transition.session.validate().map_err(contract_error)?;
    if transition.event.version != PROVIDER_DISCOVERY_EVENT_VERSION
        || transition.receipt.outcome
            != lorepia_domain::discovery::DiscoveryActionReceiptOutcome::Applied
        || transition.session.revision != transition.previous_revision.saturating_add(1)
        || transition.event.session_id != transition.session.id
        || transition.event.session_revision != transition.session.revision
        || transition.event.state != transition.session.state
        || transition.event.failure != transition.session.failure
        || transition.event.sequence.saturating_add(1) != transition.session.next_event_sequence
        || transition.event.action_id != transition.receipt.action_id
        || transition.receipt.session_id != transition.session.id
        || transition.receipt.expected_revision != transition.previous_revision
        || transition.receipt.resulting_revision != transition.session.revision
        || transition.receipt.event_sequence != transition.event.sequence
    {
        return Err(CoreError::invalid(
            "discovery transition aggregate fields do not agree",
        ));
    }
    let (_, operation_kind, _) = map_discovery_effect(&transition.effect);
    if operation_kind.is_some() != write.new_operation_id.is_some() {
        return Err(CoreError::invalid(
            "discovery external effects require exactly one prepared operation id",
        ));
    }
    if let Some(approval) = &write.approval {
        approval.validate().map_err(contract_error)?;
        if approval.session_id != transition.session.id
            || approval.session_revision != transition.previous_revision
            || approval.created_at != write.occurred_at
        {
            return Err(CoreError::invalid(
                "discovery approval must match the transition session, revision, and time",
            ));
        }
    }
    validate_prepared_commit(write)?;
    validate_provider_graph_publication(write)?;
    for evidence in &write.new_evidence {
        if evidence.session_id != transition.session.id {
            return Err(CoreError::invalid(
                "transition evidence must belong to the discovery session",
            ));
        }
        validate_discovery_evidence(evidence)?;
    }
    for candidate in &write.new_candidates {
        if candidate.candidate.session_id != transition.session.id {
            return Err(CoreError::invalid(
                "transition candidates must belong to the discovery session",
            ));
        }
        candidate.candidate.validate().map_err(contract_error)?;
    }
    Ok(())
}

fn validate_provider_graph_publication(write: &DiscoveryTransitionWrite) -> CoreResult<()> {
    let transition = &write.transition;
    let Some(graph) = &write.provider_graph else {
        if transition.receipt.action_kind == "commit_succeeded" {
            return Err(CoreError::invalid(
                "a successful discovery commit must publish its exact provider graph atomically",
            ));
        }
        return Ok(());
    };
    validate_provider_graph(graph)?;
    if transition.receipt.action_kind != "commit_succeeded"
        || transition.session.state != DiscoveryState::Ready
        || transition.effect != DiscoveryEffect::None
        || write.new_operation_id.is_some()
        || write.prepared_commit.is_some()
        || write.approval.is_some()
        || !write.new_evidence.is_empty()
        || !write.new_candidates.is_empty()
        || write
            .completed_operation
            .as_ref()
            .is_none_or(|completed| completed.outcome != DurableOperationOutcome::Succeeded)
        || transition.session.commit_attempt_id.as_ref() != Some(&graph.plan.attempt_id)
        || transition.session.commit_plan_sha256.as_deref() != Some(graph.plan_sha256.as_str())
        || transition.session.committed_connection_id.as_ref() != Some(&graph.plan.connection_id)
        || graph.plan.session_id != transition.session.id
        || graph.plan.expected_revision >= transition.previous_revision
    {
        return Err(CoreError::invalid(
            "provider graph publication must be the exact atomic Ready transition",
        ));
    }
    Ok(())
}

fn validate_completed_operation_binding(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<()> {
    let active_operation_id = transaction
        .query_row(
            "SELECT active_operation_id
             FROM provider_discovery_sessions
             WHERE id = ?1",
            [write.transition.session.id.as_str()],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "provider discovery session was not found",
                false,
            )
        })?;
    let action_kind = write.transition.receipt.action_kind.as_str();
    let expected_outcome = match action_kind {
        "known_provider_candidates_resolved"
        | "documents_fetched"
        | "evidence_extracted"
        | "manifest_draft_built"
        | "assistant_requested_more_evidence"
        | "assistant_resumed_with_evidence"
        | "manifest_validated"
        | "models_listed"
        | "probes_completed"
        | "commit_succeeded"
        | "compensation_succeeded" => Some(DurableOperationOutcome::Succeeded),
        "fail" | "commit_failed_before_apply" | "compensation_required" | "compensation_failed" => {
            active_operation_id
                .as_ref()
                .map(|_| DurableOperationOutcome::Failed)
        }
        "external_outcome_became_unknown" => Some(DurableOperationOutcome::OutcomeUnknown),
        "interrupt" => Some(
            if write.transition.session.state == DiscoveryState::UnknownOutcome {
                DurableOperationOutcome::OutcomeUnknown
            } else {
                DurableOperationOutcome::Interrupted
            },
        ),
        _ => None,
    };
    match (
        active_operation_id.as_deref(),
        expected_outcome,
        write.completed_operation.as_ref(),
    ) {
        (None | Some(_), None, None) => Ok(()),
        (Some(active_id), Some(expected), Some(completed))
            if completed.id.as_str() == active_id && completed.outcome == expected =>
        {
            Ok(())
        }
        _ => Err(CoreError::invalid(
            "completed discovery operation does not match the domain action outcome",
        )),
    }
}

fn resolve_draft_update(
    update: &DiscoveryJsonUpdate<Value>,
    stored: Option<String>,
) -> CoreResult<Option<String>> {
    match update {
        DiscoveryJsonUpdate::Preserve => Ok(stored),
        DiscoveryJsonUpdate::Clear => Ok(None),
        DiscoveryJsonUpdate::Replace(value) => {
            encode_redacted_json(value, "discovery draft").map(Some)
        }
    }
}

fn resolve_review_update(
    update: &DiscoveryJsonUpdate<DiscoveryReviewDiff>,
    stored: Option<String>,
) -> CoreResult<Option<String>> {
    match update {
        DiscoveryJsonUpdate::Preserve => Ok(stored),
        DiscoveryJsonUpdate::Clear => Ok(None),
        DiscoveryJsonUpdate::Replace(review) => {
            review.validate().map_err(contract_error)?;
            encode_json_result(serde_json::to_value(review), "discovery review").map(Some)
        }
    }
}

fn approval_kind(grant: &DiscoveryApprovalGrant) -> &'static str {
    match grant {
        DiscoveryApprovalGrant::TemplateSelection { .. } => "template_selection",
        DiscoveryApprovalGrant::AssistantConsent { .. } => "assistant_consent",
        DiscoveryApprovalGrant::CredentialOrigin { .. } => "credential_origin",
        DiscoveryApprovalGrant::CapabilityProbe { .. } => "capability_probe",
        DiscoveryApprovalGrant::Review { .. } => "review",
        DiscoveryApprovalGrant::UnknownOutcomeResolution { .. } => "unknown_outcome_resolution",
    }
}

fn map_discovery_effect(
    effect: &lorepia_domain::discovery::DiscoveryEffect,
) -> (
    DurableDiscoveryEffect,
    Option<DiscoveryOperationKind>,
    Option<&DiscoveryApprovalBinding>,
) {
    use lorepia_domain::discovery::DiscoveryEffect;
    match effect {
        DiscoveryEffect::None => (DurableDiscoveryEffect::None, None, None),
        DiscoveryEffect::ResolveKnownProvider => (
            DurableDiscoveryEffect::ResolveKnownProvider,
            Some(DiscoveryOperationKind::ResolveKnownProvider),
            None,
        ),
        DiscoveryEffect::FetchDocuments => (
            DurableDiscoveryEffect::FetchDocuments,
            Some(DiscoveryOperationKind::FetchDocuments),
            None,
        ),
        DiscoveryEffect::ExtractEvidence => (
            DurableDiscoveryEffect::ExtractEvidence,
            Some(DiscoveryOperationKind::ExtractEvidence),
            None,
        ),
        DiscoveryEffect::BuildDeterministicManifestDraft => (
            DurableDiscoveryEffect::BuildDeterministicManifestDraft,
            Some(DiscoveryOperationKind::BuildDeterministicManifestDraft),
            None,
        ),
        DiscoveryEffect::BuildAssistantManifestDraft { approval } => (
            DurableDiscoveryEffect::BuildAssistantManifestDraft,
            Some(DiscoveryOperationKind::BuildAssistantManifestDraft),
            Some(approval),
        ),
        DiscoveryEffect::ValidateManifest => (
            DurableDiscoveryEffect::ValidateManifest,
            Some(DiscoveryOperationKind::ValidateManifest),
            None,
        ),
        DiscoveryEffect::ListModels => (
            DurableDiscoveryEffect::ListModels,
            Some(DiscoveryOperationKind::ListModels),
            None,
        ),
        DiscoveryEffect::ProbeCapabilities { approval } => (
            DurableDiscoveryEffect::ProbeCapabilities,
            Some(DiscoveryOperationKind::ProbeCapabilities),
            Some(approval),
        ),
        DiscoveryEffect::RequestCancellation { .. } => {
            (DurableDiscoveryEffect::RequestCancellation, None, None)
        }
        DiscoveryEffect::CommitAtomically { .. } => (
            DurableDiscoveryEffect::CommitAtomically,
            Some(DiscoveryOperationKind::AtomicCommit),
            None,
        ),
        DiscoveryEffect::RunCompensation { .. } => (
            DurableDiscoveryEffect::RunCompensation,
            Some(DiscoveryOperationKind::Compensation),
            None,
        ),
    }
}

fn audit_kind_for_action(action_kind: &str) -> &'static str {
    match action_kind {
        "resolve_unknown_outcome" => "unknown_outcome_reconciled",
        "compensation_required" => "compensation_started",
        _ => "transition_applied",
    }
}

fn validate_prepared_commit(write: &DiscoveryTransitionWrite) -> CoreResult<()> {
    let Some(commit) = &write.prepared_commit else {
        return Ok(());
    };
    commit.plan.validate().map_err(contract_error)?;
    if commit.attempt_number == 0
        || commit.plan.session_id != write.transition.session.id
        || (!commit.reuse_existing
            && commit.plan.expected_revision != write.transition.previous_revision)
        || (commit.reuse_existing
            && commit.plan.expected_revision > write.transition.previous_revision)
        || write.transition.session.commit_attempt_id.as_ref() != Some(&commit.plan.attempt_id)
        || write.transition.session.commit_plan_sha256.as_deref()
            != Some(commit.plan_sha256.as_str())
    {
        return Err(CoreError::invalid(
            "prepared discovery commit does not match its transition",
        ));
    }
    let plan_json = encode_commit_plan_json(&commit.plan)?;
    if sha256_hex(plan_json.as_bytes()) != commit.plan_sha256 {
        return Err(CoreError::invalid(
            "discovery commit plan hash does not match its canonical plan",
        ));
    }
    if commit.reuse_existing {
        if !commit.compensation_steps.is_empty() {
            return Err(CoreError::invalid(
                "reused discovery commits must reuse their stored compensation recipe",
            ));
        }
        return Ok(());
    }
    let mut ids = BTreeSet::new();
    let mut ordinals = BTreeSet::new();
    let mut action_ids = BTreeSet::new();
    let mut credential_steps = 0_usize;
    let mut graph_steps = 0_usize;
    let mut selection_steps = 0_usize;
    for step in &commit.compensation_steps {
        validate_identifier("compensation step id", &step.id, 128)?;
        step.step
            .validate_against(&commit.plan)
            .map_err(contract_error)?;
        if step.step.status != DomainCompensationStatus::Pending
            || !ids.insert(step.id.as_str())
            || !ordinals.insert(step.step.ordinal)
            || !action_ids.insert(step.step.action_id.as_str())
        {
            return Err(CoreError::invalid(
                "prepared compensation steps must be unique pending steps",
            ));
        }
        match step.step.kind {
            DiscoveryCompensationKind::RemoveCredentialSlot => credential_steps += 1,
            DiscoveryCompensationKind::RemoveConnectionGraph => graph_steps += 1,
            DiscoveryCompensationKind::RestorePreviousSelection => selection_steps += 1,
        }
    }
    let expected_ordinals = (0..u32::try_from(commit.compensation_steps.len())
        .map_err(|_| CoreError::invalid("discovery compensation recipe is too large"))?)
        .collect::<BTreeSet<_>>();
    if ordinals != expected_ordinals
        || graph_steps != 1
        || credential_steps != usize::from(commit.plan.credential_ref.is_some())
        || selection_steps != 1
    {
        return Err(CoreError::invalid(
            "fresh discovery commit requires a complete contiguous compensation recipe",
        ));
    }
    Ok(())
}

fn validate_prepared_commit_session_binding(
    transaction: &Transaction<'_>,
    commit: &PreparedDiscoveryCommit,
) -> CoreResult<()> {
    let input_json = transaction
        .query_row(
            "SELECT sanitized_input_json
             FROM provider_discovery_sessions
             WHERE id = ?1",
            [commit.plan.session_id.as_str()],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| corrupted("prepared commit discovery session is missing"))?;
    let input = serde_json::from_str::<SanitizedDiscoveryInput>(&input_json)
        .map_err(|_| corrupted("stored discovery input is invalid"))?;
    input
        .validate()
        .map_err(|_| corrupted("stored discovery input violates its contract"))?;
    validate_sanitized_input(&input)
        .map_err(|_| corrupted("stored discovery input contains forbidden data"))?;
    if commit.plan.connection_id != input.connection_id
        || commit.plan.credential_ref != input.credential_ref
    {
        return Err(CoreError::invalid(
            "commit plan connection identity differs from its sanitized input",
        ));
    }
    let current_selection = load_discovery_previous_selection(transaction)?;
    if commit.plan.previous_selection != current_selection {
        return Err(CoreError::invalid(
            "commit plan previous selection is not the current atomic snapshot",
        ));
    }
    Ok(())
}

fn insert_session_in_transaction(
    transaction: &Transaction<'_>,
    session: &ProviderDiscoverySession,
    created_at: DateTime<Utc>,
) -> CoreResult<()> {
    let input_json = canonical_json_result(
        serde_json::to_value(&session.input),
        "sanitized discovery input",
    )?;
    transaction
        .execute(
            "INSERT INTO provider_discovery_sessions (
                 id, state, revision, next_event_sequence, sanitized_input_json,
                 cancellation_pending, redaction_version, created_at, updated_at
             ) VALUES (?1, 'draft', 0, 1, ?2, 0, 1, ?3, ?3)",
            params![session.id.as_str(), input_json, created_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    append_audit(
        transaction,
        session.id.as_str(),
        0,
        "session_created",
        None,
        Some(session.id.as_str()),
        "discovery.audit.session_created",
        created_at,
    )
}

fn insert_evidence_in_transaction(
    transaction: &Transaction<'_>,
    evidence: &DiscoveryEvidenceRecord,
) -> CoreResult<()> {
    validate_discovery_evidence(evidence)?;
    require_session(transaction, evidence.session_id.as_str())?;
    let extracted_json = encode_redacted_json(&evidence.extracted_json, "discovery evidence")?;
    let existing = transaction
        .query_row(
            "SELECT session_id, kind, source_url, content_sha256, extracted_json, fetched_at
             FROM provider_discovery_evidence WHERE id = ?1",
            [evidence.id.as_str()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?;
    let fetched_at = evidence.fetched_at.to_rfc3339();
    if let Some(existing) = existing {
        if existing
            == (
                evidence.session_id.as_str().to_owned(),
                evidence.kind.as_str().to_owned(),
                evidence.source_url.as_str().to_owned(),
                evidence.content_sha256.clone(),
                extracted_json,
                fetched_at,
            )
        {
            return Ok(());
        }
        return Err(CoreError::invalid(
            "discovery evidence identifiers are immutable",
        ));
    }
    transaction
        .execute(
            "INSERT INTO provider_discovery_evidence (
                 id, session_id, kind, source_url, content_sha256,
                 extracted_json, redaction_version, fetched_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7)",
            params![
                evidence.id.as_str(),
                evidence.session_id.as_str(),
                evidence.kind.as_str(),
                evidence.source_url.as_str(),
                evidence.content_sha256,
                extracted_json,
                fetched_at,
            ],
        )
        .map_err(database_error)?;
    Ok(())
}

fn insert_candidate_in_transaction(
    transaction: &Transaction<'_>,
    candidate: &StoredDiscoveryCandidate,
    expected_revision: u64,
) -> CoreResult<()> {
    candidate.candidate.validate().map_err(contract_error)?;
    if candidate.proposed_revision != expected_revision {
        return Err(CoreError::invalid(
            "transition candidate revision does not match the source revision",
        ));
    }
    validate_candidate_evidence_references(transaction, candidate)?;
    let summary_json = encode_json_result(
        serde_json::to_value(&candidate.candidate.summary),
        "discovery candidate summary",
    )?;
    let evidence_ids_json = encode_json_result(
        serde_json::to_value(&candidate.candidate.evidence_ids),
        "candidate evidence references",
    )?;
    let kind = candidate_kind(&candidate.candidate);
    let created_at = candidate.candidate.created_at.to_rfc3339();
    let existing = transaction
        .query_row(
            "SELECT session_id, candidate_kind, summary_json, evidence_ids_json,
                    proposed_revision, created_at
             FROM provider_discovery_candidates WHERE id = ?1",
            [candidate.candidate.id.as_str()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, u64>(4)?,
                    row.get::<_, String>(5)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?;
    if let Some(existing) = existing {
        if existing
            == (
                candidate.candidate.session_id.as_str().to_owned(),
                kind.to_owned(),
                summary_json,
                evidence_ids_json,
                candidate.proposed_revision,
                created_at,
            )
        {
            return Ok(());
        }
        return Err(CoreError::invalid(
            "discovery candidate identifiers are immutable",
        ));
    }
    transaction
        .execute(
            "INSERT INTO provider_discovery_candidates (
                 id, session_id, candidate_kind, summary_json, evidence_ids_json,
                 proposed_revision, redaction_version, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, 1, ?7)",
            params![
                candidate.candidate.id.as_str(),
                candidate.candidate.session_id.as_str(),
                kind,
                summary_json,
                evidence_ids_json,
                candidate.proposed_revision,
                created_at,
            ],
        )
        .map_err(database_error)?;
    append_audit(
        transaction,
        candidate.candidate.session_id.as_str(),
        candidate.proposed_revision,
        "candidate_recorded",
        None,
        Some(candidate.candidate.id.as_str()),
        "discovery.audit.candidate_recorded",
        candidate.candidate.created_at,
    )
}

fn require_started_session_operation(
    transaction: &Transaction<'_>,
    session_id: &DiscoverySessionId,
    expected_kind: &str,
) -> CoreResult<DiscoveryOperationId> {
    let row = transaction
        .query_row(
            "SELECT session.active_operation_id, operation.operation_kind,
                    operation.side_effect_class, operation.status
             FROM provider_discovery_sessions AS session
             LEFT JOIN provider_discovery_operations AS operation
               ON operation.id = session.active_operation_id
              AND operation.session_id = session.id
             WHERE session.id = ?1",
            [session_id.as_str()],
            |row| {
                Ok((
                    row.get::<_, Option<String>>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "provider discovery session was not found",
                false,
            )
        })?;
    let (Some(operation_id), Some(kind), Some(side_effect_class), Some(status)) = row else {
        return Err(corrupted(
            "discovery session has no durable active operation",
        ));
    };
    if kind != expected_kind || side_effect_class != "persistent" || status != "started" {
        return Err(CoreError::invalid(
            "persistent discovery work requires its exact durable operation to be started",
        ));
    }
    DiscoveryOperationId::parse(operation_id).map_err(contract_error)
}

fn ensure_provider_graph_ids_vacant(
    transaction: &Transaction<'_>,
    graph: &DiscoveredProviderGraph,
) -> CoreResult<()> {
    let connection_exists = transaction
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM provider_connections WHERE id = ?1)",
            [graph.connection.id.as_str()],
            |row| row.get::<_, bool>(0),
        )
        .map_err(database_error)?;
    if connection_exists {
        return Err(CoreError::invalid(
            "discovery commit connection identifier already belongs to another graph",
        ));
    }
    for route in &graph.routes {
        if transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM provider_models WHERE id = ?1)",
                [route.id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?
        {
            return Err(CoreError::invalid(
                "discovery commit model route identifier already exists",
            ));
        }
    }
    for observation in &graph.observations {
        if transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1 FROM model_capability_observations WHERE id = ?1
                 )",
                [observation.id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?
        {
            return Err(CoreError::invalid(
                "discovery commit capability observation identifier already exists",
            ));
        }
    }
    for preset in &graph.presets {
        if transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM generation_presets WHERE id = ?1)",
                [preset.id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?
        {
            return Err(CoreError::invalid(
                "discovery commit generation preset identifier already exists",
            ));
        }
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn apply_provider_graph_in_transaction(
    transaction: &Transaction<'_>,
    graph: &DiscoveredProviderGraph,
    expected_session_revision: u64,
    applied_at: DateTime<Utc>,
) -> CoreResult<()> {
    validate_provider_graph(graph)?;
    let plan_json = encode_commit_plan_json(&graph.plan)?;
    if sha256_hex(plan_json.as_bytes()) != graph.plan_sha256 {
        return Err(CoreError::invalid(
            "provider graph plan hash does not match its canonical plan",
        ));
    }
    let session = transaction
        .query_row(
            "SELECT state, revision, commit_attempt_id, commit_plan_sha256,
                    sanitized_input_json
             FROM provider_discovery_sessions
             WHERE id = ?1",
            [graph.plan.session_id.as_str()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, u64>(1)?,
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                    row.get::<_, String>(4)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "provider discovery session was not found",
                false,
            )
        })?;
    if session.0 != "committing"
        || session.1 != expected_session_revision
        || session.2.as_deref() != Some(graph.plan.attempt_id.as_str())
        || session.3.as_deref() != Some(graph.plan_sha256.as_str())
        || graph.plan.expected_revision >= expected_session_revision
    {
        return Err(CoreError::invalid(
            "provider graph commit does not match the active discovery revision",
        ));
    }
    let input = serde_json::from_str::<SanitizedDiscoveryInput>(&session.4)
        .map_err(|_| corrupted("committing discovery input is invalid"))?;
    input
        .validate()
        .map_err(|_| corrupted("committing discovery input violates its contract"))?;
    validate_sanitized_input(&input)
        .map_err(|_| corrupted("committing discovery input contains forbidden data"))?;
    if graph.connection.id != input.connection_id
        || graph.connection.display_name != input.display_name
        || graph.connection.credential_ref != input.credential_ref
    {
        return Err(CoreError::invalid(
            "provider graph connection differs from the user-selected identity",
        ));
    }
    require_started_session_operation(transaction, &graph.plan.session_id, "atomic_commit")?;
    let attempt = transaction
        .query_row(
            "SELECT plan_sha256, plan_json, phase
             FROM provider_discovery_commit_attempts
             WHERE id = ?1 AND session_id = ?2",
            params![
                graph.plan.attempt_id.as_str(),
                graph.plan.session_id.as_str()
            ],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| corrupted("active discovery commit attempt is missing"))?;
    if attempt.0 != graph.plan_sha256 || attempt.1 != plan_json {
        return Err(CoreError::invalid(
            "provider graph differs from its immutable commit attempt",
        ));
    }
    if !matches!(attempt.2.as_str(), "prepared" | "database_applied") {
        return Err(CoreError::invalid(
            "provider graph can only be applied from the prepared phase",
        ));
    }
    validate_review_approval(transaction, &graph.plan)?;
    validate_credential_approval(transaction, graph)?;
    validate_graph_evidence_references(transaction, graph)?;
    let requested_ownership_hash = provider_graph_ownership_hash(
        &graph.template,
        &graph.connection,
        &graph.routes,
        &graph.observations,
        &graph.presets,
    )?;
    if requested_ownership_hash != graph.plan.graph_sha256 {
        return Err(CoreError::invalid(
            "provider graph differs from the graph digest approved in the immutable commit plan",
        ));
    }
    if attempt.2 == "database_applied" {
        let stored_graph = load_discovered_provider_graph_rows(
            transaction,
            &graph.plan.template_id,
            graph.plan.template_version,
            &graph.plan.connection_id,
        )?
        .ok_or_else(|| corrupted("database-applied discovery graph is missing"))?;
        if stored_provider_graph_ownership_hash(&stored_graph)? != requested_ownership_hash
            || graph_ownership_audit_hash(transaction, &graph.plan.session_id)?
                != requested_ownership_hash
        {
            return Err(CoreError::invalid(
                "database-applied discovery graph differs from its immutable ownership record",
            ));
        }
        return Ok(());
    }
    ensure_provider_graph_ids_vacant(transaction, graph)?;
    let template_existed = transaction
        .query_row(
            "SELECT EXISTS(
                 SELECT 1 FROM provider_templates WHERE id = ?1 AND version = ?2
             )",
            params![graph.plan.template_id.as_str(), graph.plan.template_version,],
            |row| row.get::<_, bool>(0),
        )
        .map_err(database_error)?;
    write_discovered_provider_graph_rows(
        transaction,
        &graph.template,
        &graph.connection,
        &graph.routes,
        &graph.observations,
        &graph.presets,
    )?;
    let stored_graph = load_discovered_provider_graph_rows(
        transaction,
        &graph.plan.template_id,
        graph.plan.template_version,
        &graph.plan.connection_id,
    )?
    .ok_or_else(|| corrupted("newly applied discovery graph is missing"))?;
    if stored_provider_graph_ownership_hash(&stored_graph)? != requested_ownership_hash {
        return Err(corrupted(
            "newly applied discovery graph does not match its requested rows",
        ));
    }
    append_audit(
        transaction,
        graph.plan.session_id.as_str(),
        expected_session_revision,
        "transition_applied",
        None,
        Some(&requested_ownership_hash),
        "discovery.audit.provider_graph_applied",
        applied_at,
    )?;
    append_audit(
        transaction,
        graph.plan.session_id.as_str(),
        expected_session_revision,
        "transition_applied",
        None,
        Some(if template_existed {
            "reused"
        } else {
            "created"
        }),
        "discovery.audit.provider_template_ownership",
        applied_at,
    )?;
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_commit_attempts
             SET phase = 'database_applied', updated_at = ?2
             WHERE id = ?1 AND phase = 'prepared'",
            params![graph.plan.attempt_id.as_str(), applied_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "discovery commit phase changed concurrently",
        ));
    }
    Ok(())
}

fn validate_graph_evidence_references(
    transaction: &Transaction<'_>,
    graph: &DiscoveredProviderGraph,
) -> CoreResult<()> {
    for evidence_id in graph
        .observations
        .iter()
        .filter_map(|observation| observation.evidence_ref.as_ref())
    {
        let belongs = transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1
                     FROM provider_discovery_evidence
                     WHERE id = ?1 AND session_id = ?2
                 )",
                params![evidence_id.as_str(), graph.plan.session_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if !belongs {
            return Err(CoreError::invalid(
                "capability observation evidence must belong to the committing discovery session",
            ));
        }
    }
    Ok(())
}

fn provider_graph_ownership_hash(
    template: &ProviderTemplate,
    connection: &ProviderConnection,
    routes: &[ModelRoute],
    observations: &[CapabilityObservation],
    presets: &[GenerationPreset],
) -> CoreResult<String> {
    let mut routes = routes.to_vec();
    routes.sort_by(|left, right| left.id.as_str().cmp(right.id.as_str()));
    let mut observations = observations.to_vec();
    observations.sort_by(|left, right| left.id.as_str().cmp(right.id.as_str()));
    let mut presets = presets.to_vec();
    presets.sort_by(|left, right| left.id.as_str().cmp(right.id.as_str()));
    let canonical = canonical_typed_json_result(
        serde_json::to_value((template, connection, routes, observations, presets)),
        "discovered provider graph ownership",
    )?;
    Ok(sha256_hex(canonical.as_bytes()))
}

fn stored_provider_graph_ownership_hash(
    graph: &StoredDiscoveredProviderGraphRows,
) -> CoreResult<String> {
    provider_graph_ownership_hash(
        &graph.template,
        &graph.connection,
        &graph.routes,
        &graph.observations,
        &graph.presets,
    )
}

fn graph_ownership_audit_hash(
    transaction: &Transaction<'_>,
    session_id: &DiscoverySessionId,
) -> CoreResult<String> {
    let hashes = {
        let mut statement = transaction
            .prepare(
                "SELECT subject_id
                 FROM provider_discovery_audit_log
                 WHERE session_id = ?1
                   AND summary_key = 'discovery.audit.provider_graph_applied'
                 ORDER BY audit_sequence",
            )
            .map_err(database_error)?;
        statement
            .query_map([session_id.as_str()], |row| row.get::<_, Option<String>>(0))
            .map_err(database_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(database_error)?
    };
    if hashes.len() != 1 {
        return Err(corrupted(
            "discovery commit must have exactly one provider graph ownership record",
        ));
    }
    let hash = hashes
        .into_iter()
        .next()
        .flatten()
        .ok_or_else(|| corrupted("provider graph ownership record has no digest"))?;
    validate_sha256("provider graph ownership digest", &hash)
        .map_err(|_| corrupted("provider graph ownership digest is invalid"))?;
    Ok(hash)
}

fn graph_template_was_created(
    transaction: &Transaction<'_>,
    session_id: &DiscoverySessionId,
) -> CoreResult<bool> {
    let records = {
        let mut statement = transaction
            .prepare(
                "SELECT subject_id
                 FROM provider_discovery_audit_log
                 WHERE session_id = ?1
                   AND summary_key = 'discovery.audit.provider_template_ownership'
                 ORDER BY audit_sequence",
            )
            .map_err(database_error)?;
        statement
            .query_map([session_id.as_str()], |row| row.get::<_, Option<String>>(0))
            .map_err(database_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(database_error)?
    };
    match records.as_slice() {
        [Some(value)] if value == "created" => Ok(true),
        [Some(value)] if value == "reused" => Ok(false),
        _ => Err(corrupted(
            "discovery commit has an invalid provider template ownership record",
        )),
    }
}

#[allow(clippy::too_many_lines)]
fn validate_provider_graph(graph: &DiscoveredProviderGraph) -> CoreResult<()> {
    graph.plan.validate().map_err(contract_error)?;
    validate_sha256("provider graph plan hash", &graph.plan_sha256)?;
    if let Some(reference) = &graph.plan.credential_ref {
        validate_opaque_credential_reference(reference.as_str())?;
    }
    validate_graph_component(serde_json::to_value(&graph.template), "provider template")?;
    validate_graph_component(
        serde_json::to_value(&graph.connection),
        "provider connection",
    )?;
    for route in &graph.routes {
        validate_graph_component(serde_json::to_value(route), "model route")?;
    }
    for preset in &graph.presets {
        validate_graph_component(serde_json::to_value(preset), "generation preset")?;
    }
    validate_persistable_discovery_url(
        graph.connection.api_origin.as_str(),
        "provider connection origin",
    )?;
    if graph.template.id != graph.plan.template_id
        || graph.template.manifest_version != graph.plan.template_version
        || graph.connection.id != graph.plan.connection_id
        || graph.connection.template_id != graph.plan.template_id
        || graph.connection.template_version != graph.plan.template_version
        || graph.connection.credential_ref != graph.plan.credential_ref
    {
        return Err(CoreError::invalid(
            "provider graph identities do not match the discovery commit plan",
        ));
    }
    let manifest_json = canonical_json_result(
        serde_json::to_value(&graph.template.default_manifest),
        "provider manifest",
    )?;
    if sha256_hex(manifest_json.as_bytes()) != graph.plan.manifest_sha256 {
        return Err(CoreError::invalid(
            "provider graph manifest does not match the validated manifest hash",
        ));
    }
    for route in &graph.routes {
        validate_discovery_route_metadata(route)?;
    }
    for observation in graph
        .observations
        .iter()
        .filter(|observation| observation.source == ObservationSource::ProviderApi)
    {
        let route = graph
            .routes
            .iter()
            .find(|route| route.id == observation.model_route_id)
            .ok_or_else(|| {
                CoreError::invalid(
                    "provider API capability observation references a route outside the graph",
                )
            })?;
        if route.metadata_source != ModelMetadataSource::ProviderApi
            || route.metadata_observed_at != Some(observation.observed_at)
            || observation.confidence != Confidence::High
            || !matches!(
                observation.status,
                SupportStatus::Verified | SupportStatus::Unsupported
            )
            || observation.evidence_ref.is_some()
            || observation
                .expires_at
                .is_none_or(|expires_at| expires_at <= observation.observed_at)
        {
            return Err(CoreError::invalid(
                "provider API capability observation provenance differs from its route metadata",
            ));
        }
    }
    for entry in &graph.connection.config.values {
        if let ConnectionConfigValue::Text(value) = &entry.value
            && looks_like_secret(value)
        {
            return Err(CoreError::invalid(
                "discovered provider connection configuration contains credential-like material",
            ));
        }
    }
    for route in &graph.routes {
        for entry in &route.route_config.values {
            if let ConnectionConfigValue::Text(value) = &entry.value
                && looks_like_secret(value)
            {
                return Err(CoreError::invalid(
                    "discovered model route configuration contains credential-like material",
                ));
            }
        }
    }
    for observation in &graph.observations {
        let value = serde_json::to_value(&observation.value)
            .map_err(|_| CoreError::internal("cannot inspect discovered capability value"))?;
        validate_redacted_value(&value)?;
    }
    let planned = graph.plan.model_route_ids.iter().collect::<BTreeSet<_>>();
    let actual = graph
        .routes
        .iter()
        .map(|route| &route.id)
        .collect::<BTreeSet<_>>();
    if planned.len() != graph.plan.model_route_ids.len()
        || actual.len() != graph.routes.len()
        || planned != actual
        || graph
            .routes
            .iter()
            .any(|route| route.connection_id != graph.connection.id)
        || graph
            .observations
            .iter()
            .any(|observation| !actual.contains(&observation.model_route_id))
        || graph
            .presets
            .iter()
            .any(|preset| !actual.contains(&preset.model_route_id))
    {
        return Err(CoreError::invalid(
            "provider graph routes and dependants do not match the commit plan",
        ));
    }
    Ok(())
}

fn validate_discovery_route_metadata(route: &ModelRoute) -> CoreResult<()> {
    if route.last_reconciled_sync_job_id.is_some() || route.metadata_sync_job_id.is_some() {
        return Err(CoreError::invalid(
            "initial discovery routes cannot claim model synchronization provenance",
        ));
    }
    match (
        route.raw_metadata.as_ref(),
        route.metadata_source,
        route.metadata_observed_at,
    ) {
        (Some(metadata), ModelMetadataSource::ProviderApi, Some(observed_at)) => {
            if route.miss_count != 0
                || route.first_seen_at != observed_at
                || route.last_seen_at != Some(observed_at)
            {
                return Err(CoreError::invalid(
                    "discovered provider API route metadata has inconsistent observation times",
                ));
            }
            validate_provider_api_route_metadata(Some(metadata))
        }
        (None, ModelMetadataSource::Legacy | ModelMetadataSource::UserOverride, None) => {
            if route.miss_count != 0 {
                return Err(CoreError::invalid(
                    "initial discovery routes cannot carry model synchronization miss counts",
                ));
            }
            Ok(())
        }
        _ => Err(CoreError::invalid(
            "discovered route metadata must be absent or a normalized provider API projection",
        )),
    }
}

fn validate_graph_component(
    component: Result<Value, serde_json::Error>,
    label: &str,
) -> CoreResult<()> {
    let value = component.map_err(|_| CoreError::internal(format!("cannot inspect {label}")))?;
    validate_redacted_value(&value)
        .map_err(|_| CoreError::invalid(format!("{label} contains forbidden data")))
}

fn validate_review_approval(
    transaction: &Transaction<'_>,
    plan: &DiscoveryCommitPlan,
) -> CoreResult<()> {
    let review_json = transaction
        .query_row(
            "SELECT review_diff_json
             FROM provider_discovery_sessions
             WHERE id = ?1",
            [plan.session_id.as_str()],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(database_error)?
        .flatten()
        .ok_or_else(|| CoreError::invalid("provider graph requires a persisted review"))?;
    let review = serde_json::from_str::<DiscoveryReviewDiff>(&review_json)
        .map_err(|_| corrupted("stored provider discovery review is invalid"))?;
    review
        .validate()
        .map_err(|_| corrupted("stored provider discovery review digest is invalid"))?;
    validate_review_evidence_references(transaction, &plan.session_id, &review)?;
    if review.sha256 != plan.review_sha256 || review.graph_sha256 != plan.graph_sha256 {
        return Err(CoreError::invalid(
            "provider graph commit plan differs from the approved review and graph digest",
        ));
    }
    let grants = {
        let mut statement = transaction
            .prepare(
                "SELECT grant_json
                 FROM provider_discovery_approvals
                 WHERE session_id = ?1
                   AND approval_kind = 'review'
                   AND decision = 'approved'",
            )
            .map_err(database_error)?;
        statement
            .query_map([plan.session_id.as_str()], |row| row.get::<_, String>(0))
            .map_err(database_error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(database_error)?
    };
    let approved = grants.into_iter().any(|grant_json| {
        serde_json::from_str::<DiscoveryApprovalGrant>(&grant_json)
            .ok()
            .is_some_and(|grant| {
                matches!(
                    grant,
                    DiscoveryApprovalGrant::Review {
                        review_sha256,
                        graph_sha256,
                    } if review_sha256 == plan.review_sha256
                        && graph_sha256 == plan.graph_sha256
                )
            })
    });
    if !approved {
        return Err(CoreError::invalid(
            "provider graph requires an exact approved review hash",
        ));
    }
    Ok(())
}

fn validate_credential_approval(
    transaction: &Transaction<'_>,
    graph: &DiscoveredProviderGraph,
) -> CoreResult<()> {
    let (Some(credential_ref), Some(approval_id)) = (
        &graph.plan.credential_ref,
        &graph.plan.credential_approval_id,
    ) else {
        if graph.connection.credential_ref.is_some() || graph.connection.credential_scope.is_some()
        {
            return Err(CoreError::invalid(
                "credential-free commit plans cannot publish credential references",
            ));
        }
        return Ok(());
    };
    if graph.connection.credential_ref.as_ref() != Some(credential_ref) {
        return Err(CoreError::invalid(
            "provider connection credential reference differs from its commit plan",
        ));
    }
    let grant_json = transaction
        .query_row(
            "SELECT grant_json
             FROM provider_discovery_approvals
             WHERE id = ?1
               AND session_id = ?2
               AND approval_kind = 'credential_origin'
               AND decision = 'approved'",
            params![approval_id.as_str(), graph.plan.session_id.as_str()],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| {
            CoreError::invalid("provider graph credential approval was not persisted")
        })?;
    let grant = serde_json::from_str::<DiscoveryApprovalGrant>(&grant_json)
        .map_err(|_| corrupted("stored credential-origin grant is invalid"))?;
    let DiscoveryApprovalGrant::CredentialOrigin {
        origin,
        auth_binding,
        manifest_sha256,
    } = grant
    else {
        return Err(corrupted(
            "stored credential approval has the wrong typed grant",
        ));
    };
    let scope =
        graph.connection.credential_scope.as_ref().ok_or_else(|| {
            CoreError::invalid("credential reference requires a credential scope")
        })?;
    if origin != graph.connection.api_origin
        || auth_binding != scope.auth_binding
        || manifest_sha256 != graph.plan.manifest_sha256
        || scope.allowed_origins.as_slice() != [origin]
        || scope.redirect_policy != CredentialRedirectPolicy::Deny
    {
        return Err(CoreError::invalid(
            "provider credential scope differs from its approved origin grant",
        ));
    }
    Ok(())
}

fn finalize_commit_failed_before_apply(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<()> {
    if write.transition.receipt.action_kind != "commit_failed_before_apply" {
        return Ok(());
    }
    let attempt_id = write
        .transition
        .session
        .commit_attempt_id
        .as_ref()
        .ok_or_else(|| corrupted("failed-before-apply transition has no commit attempt"))?;
    let attempt = load_commit_attempt(transaction, attempt_id)?;
    let session_owns_attempt = transaction
        .query_row(
            "SELECT commit_attempt_id = ?2
             FROM provider_discovery_sessions
             WHERE id = ?1",
            params![write.transition.session.id.as_str(), attempt.id.as_str(),],
            |row| row.get::<_, bool>(0),
        )
        .optional()
        .map_err(database_error)?
        .unwrap_or(false);
    if attempt.session_id != write.transition.session.id
        || !session_owns_attempt
        || attempt.phase != DiscoveryCommitPhase::Prepared
    {
        return Err(CoreError::invalid(
            "failed-before-apply requires the session's own prepared commit attempt",
        ));
    }
    if load_discovered_provider_graph_rows(
        transaction,
        &attempt.plan.template_id,
        attempt.plan.template_version,
        &attempt.plan.connection_id,
    )?
    .is_some()
    {
        return Err(CoreError::invalid(
            "failed-before-apply cannot finalize after provider graph publication",
        ));
    }
    for route_id in &attempt.plan.model_route_ids {
        let route_exists = transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM provider_models WHERE id = ?1)",
                [route_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if route_exists {
            return Err(CoreError::invalid(
                "failed-before-apply found a planned route already persisted",
            ));
        }
    }
    if attempt.plan.credential_ref.is_some() {
        return Err(CoreError::invalid(
            "failed-before-apply cannot attest native credential cleanup",
        ));
    }
    restore_discovery_provider_selection(transaction, &attempt.plan.previous_selection)?;
    transaction
        .execute(
            "UPDATE provider_discovery_compensation_steps
             SET status = 'completed',
                 last_failure_json = NULL,
                 updated_at = ?2,
                 completed_at = ?2
             WHERE commit_attempt_id = ?1
               AND status <> 'completed'",
            params![attempt.id.as_str(), write.occurred_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_commit_attempts
             SET phase = 'compensated', updated_at = ?2, completed_at = ?2
             WHERE id = ?1 AND phase = 'prepared'",
            params![attempt.id.as_str(), write.occurred_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "failed-before-apply commit attempt changed concurrently",
        ));
    }
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn reconcile_discovery_saga_ledger(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<()> {
    let action_kind = write.transition.receipt.action_kind.as_str();
    if write.transition.session.state == DiscoveryState::Compensating
        && matches!(
            action_kind,
            "commit_succeeded" | "compensation_required" | "restart_interrupted"
        )
    {
        prepare_compensation_ledger(transaction, write)?;
        return Ok(());
    }
    if action_kind == "resume_compensation"
        && write.transition.session.state == DiscoveryState::Compensating
    {
        reset_failed_compensation_steps(transaction, write)?;
        return Ok(());
    }
    if matches!(action_kind, "interrupt" | "external_outcome_became_unknown")
        && write.transition.session.state == DiscoveryState::UnknownOutcome
    {
        let operation = write
            .transition
            .session
            .unknown_operation
            .ok_or_else(|| corrupted("unknown-outcome transition has no operation"))?;
        if matches!(
            operation,
            DiscoveryOperationKind::AtomicCommit | DiscoveryOperationKind::Compensation
        ) {
            record_persistent_unknown_outcome(transaction, write, operation)?;
        }
        return Ok(());
    }
    if action_kind == "compensation_failed" {
        return validate_failed_compensation_ledger(transaction, write);
    }
    if action_kind != "resolve_unknown_outcome" {
        if write.approval.as_ref().is_some_and(|approval| {
            matches!(
                approval.grant,
                DiscoveryApprovalGrant::UnknownOutcomeResolution { .. }
            )
        }) {
            return Err(CoreError::invalid(
                "unknown-outcome approval must accompany its reconciliation action",
            ));
        }
        return Ok(());
    }
    let approval = write.approval.as_ref().ok_or_else(|| {
        CoreError::invalid("unknown-outcome reconciliation requires an approval record")
    })?;
    if approval.decision != DiscoveryApprovalDecision::Approved {
        return Err(CoreError::invalid(
            "unknown-outcome reconciliation requires an approved grant",
        ));
    }
    let DiscoveryApprovalGrant::UnknownOutcomeResolution {
        operation,
        resolution,
    } = &approval.grant
    else {
        return Err(CoreError::invalid(
            "unknown-outcome reconciliation has the wrong approval grant",
        ));
    };
    let stored = transaction
        .query_row(
            "SELECT state, unknown_operation, commit_attempt_id
             FROM provider_discovery_sessions
             WHERE id = ?1",
            [write.transition.session.id.as_str()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, Option<String>>(2)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| corrupted("unknown-outcome discovery session is missing"))?;
    let stored_operation = stored.1.as_deref().map(parse_operation_kind).transpose()?;
    if stored.0 != "unknown_outcome" || stored_operation.as_ref() != Some(operation) {
        return Err(CoreError::invalid(
            "unknown-outcome approval does not match the durable operation",
        ));
    }
    if !matches!(
        operation,
        DiscoveryOperationKind::AtomicCommit | DiscoveryOperationKind::Compensation
    ) {
        return match resolution {
            DiscoveryUnknownOutcomeResolution::ConfirmedCommitCompleted { .. }
            | DiscoveryUnknownOutcomeResolution::ConfirmedCompensated => Err(CoreError::invalid(
                "non-persistent work cannot use a commit reconciliation",
            )),
            DiscoveryUnknownOutcomeResolution::ConfirmedNoEffect
            | DiscoveryUnknownOutcomeResolution::ManuallyReconciledAsFailed => Ok(()),
        };
    }
    let attempt_id = stored
        .2
        .as_deref()
        .map(DiscoveryCommitAttemptId::parse)
        .transpose()
        .map_err(contract_error)?
        .ok_or_else(|| corrupted("persistent unknown outcome has no commit attempt"))?;
    let attempt = load_commit_attempt(transaction, &attempt_id)?;
    if attempt.session_id != write.transition.session.id
        || write.transition.session.commit_attempt_id.as_ref() != Some(&attempt.id)
    {
        return Err(corrupted(
            "persistent unknown outcome is detached from its commit attempt",
        ));
    }
    match resolution {
        DiscoveryUnknownOutcomeResolution::ConfirmedNoEffect => {
            reconcile_confirmed_no_effect(transaction, write, &attempt, *operation)
        }
        DiscoveryUnknownOutcomeResolution::ConfirmedCommitCompleted { connection_id } => {
            if *operation != DiscoveryOperationKind::AtomicCommit
                || connection_id != &attempt.plan.connection_id
                || attempt.phase != DiscoveryCommitPhase::OutcomeUnknown
            {
                return Err(CoreError::invalid(
                    "confirmed commit completion does not match the unknown attempt",
                ));
            }
            verify_discovery_attempt_graph(transaction, &attempt)?;
            let next_phase = match write.transition.session.state {
                DiscoveryState::Ready => {
                    if attempt.plan.credential_ref.is_some() {
                        DiscoveryCommitPhase::CredentialReferenceApplied
                    } else {
                        DiscoveryCommitPhase::DatabaseApplied
                    }
                }
                DiscoveryState::Compensating => DiscoveryCommitPhase::CompensationRequired,
                _ => {
                    return Err(CoreError::invalid(
                        "confirmed commit completion produced an invalid session state",
                    ));
                }
            };
            set_commit_phase_from_unknown(transaction, &attempt, next_phase, write.occurred_at)
        }
        DiscoveryUnknownOutcomeResolution::ConfirmedCompensated => {
            reconcile_confirmed_compensation_in_transaction(transaction, write)
        }
        DiscoveryUnknownOutcomeResolution::ManuallyReconciledAsFailed => {
            if attempt.plan.credential_ref.is_some() {
                return Err(CoreError::invalid(
                    "manual failure cannot attest native credential deletion",
                ));
            }
            reconcile_confirmed_compensation_in_transaction(transaction, write)
        }
    }
}

fn reset_failed_compensation_steps(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<()> {
    let attempt_id = write
        .transition
        .session
        .commit_attempt_id
        .as_ref()
        .ok_or_else(|| corrupted("resumed compensation has no commit attempt"))?;
    let attempt = load_commit_attempt(transaction, attempt_id)?;
    if attempt.session_id != write.transition.session.id
        || attempt.phase != DiscoveryCommitPhase::Compensating
    {
        return Err(CoreError::invalid(
            "compensation resume does not match the durable attempt",
        ));
    }
    let unresolved = transaction
        .query_row(
            "SELECT EXISTS(
                 SELECT 1 FROM provider_discovery_compensation_steps
                 WHERE commit_attempt_id = ?1
                   AND status IN ('in_progress', 'outcome_unknown')
             )",
            [attempt.id.as_str()],
            |row| row.get::<_, bool>(0),
        )
        .map_err(database_error)?;
    if unresolved {
        return Err(CoreError::invalid(
            "compensation resume requires every prior step outcome to be known",
        ));
    }
    transaction
        .execute(
            "UPDATE provider_discovery_compensation_steps
             SET status = 'pending',
                 last_failure_json = NULL,
                 updated_at = ?2,
                 completed_at = NULL
             WHERE commit_attempt_id = ?1 AND status = 'failed'",
            params![attempt.id.as_str(), write.occurred_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    Ok(())
}

fn prepare_compensation_ledger(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<()> {
    let attempt_id = write
        .transition
        .session
        .commit_attempt_id
        .as_ref()
        .ok_or_else(|| corrupted("compensating transition has no commit attempt"))?;
    let attempt = load_commit_attempt(transaction, attempt_id)?;
    if attempt.session_id != write.transition.session.id {
        return Err(CoreError::invalid(
            "compensation commit attempt belongs to another discovery session",
        ));
    }
    if write.transition.receipt.action_kind == "restart_interrupted"
        && matches!(
            attempt.phase,
            DiscoveryCommitPhase::CompensationRequired | DiscoveryCommitPhase::Compensating
        )
    {
        return Ok(());
    }
    if !(matches!(
        attempt.phase,
        DiscoveryCommitPhase::DatabaseApplied | DiscoveryCommitPhase::CredentialReferenceApplied
    ) || (attempt.phase == DiscoveryCommitPhase::Prepared
        && matches!(
            write.transition.receipt.action_kind.as_str(),
            "compensation_required" | "restart_interrupted"
        )))
    {
        return Err(CoreError::invalid(
            "compensation can start only after a durably applied commit phase",
        ));
    }
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_commit_attempts
             SET phase = 'compensation_required', updated_at = ?2, completed_at = NULL
             WHERE id = ?1 AND phase = ?3",
            params![
                attempt.id.as_str(),
                write.occurred_at.to_rfc3339(),
                attempt.phase.as_str(),
            ],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "compensation commit attempt changed concurrently",
        ));
    }
    Ok(())
}

fn record_persistent_unknown_outcome(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
    operation: DiscoveryOperationKind,
) -> CoreResult<()> {
    let attempt_id = write
        .transition
        .session
        .commit_attempt_id
        .as_ref()
        .ok_or_else(|| corrupted("persistent unknown outcome has no commit attempt"))?;
    let attempt = load_commit_attempt(transaction, attempt_id)?;
    if attempt.session_id != write.transition.session.id {
        return Err(corrupted(
            "persistent unknown outcome has a foreign commit attempt",
        ));
    }
    let allowed_phase = match operation {
        DiscoveryOperationKind::AtomicCommit => matches!(
            attempt.phase,
            DiscoveryCommitPhase::Prepared
                | DiscoveryCommitPhase::DatabaseApplied
                | DiscoveryCommitPhase::CredentialReferenceApplied
        ),
        DiscoveryOperationKind::Compensation => matches!(
            attempt.phase,
            DiscoveryCommitPhase::CompensationRequired | DiscoveryCommitPhase::Compensating
        ),
        _ => false,
    };
    if !allowed_phase {
        return Err(CoreError::invalid(
            "persistent operation cannot become unknown from its durable commit phase",
        ));
    }
    if operation == DiscoveryOperationKind::Compensation {
        let in_progress_steps = transaction
            .query_row(
                "SELECT COUNT(*)
                 FROM provider_discovery_compensation_steps
                 WHERE commit_attempt_id = ?1 AND status = 'in_progress'",
                [attempt.id.as_str()],
                |row| row.get::<_, u32>(0),
            )
            .map_err(database_error)?;
        if in_progress_steps > 1 {
            return Err(corrupted("more than one compensation step was in progress"));
        }
        transaction
            .execute(
                "UPDATE provider_discovery_compensation_steps
                 SET status = 'outcome_unknown',
                     updated_at = ?2
                 WHERE commit_attempt_id = ?1 AND status = 'in_progress'",
                params![attempt.id.as_str(), write.occurred_at.to_rfc3339()],
            )
            .map_err(database_error)?;
    }
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_commit_attempts
             SET phase = 'outcome_unknown', updated_at = ?2, completed_at = NULL
             WHERE id = ?1 AND phase = ?3",
            params![
                attempt.id.as_str(),
                write.occurred_at.to_rfc3339(),
                attempt.phase.as_str(),
            ],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "unknown-outcome commit attempt changed concurrently",
        ));
    }
    Ok(())
}

fn reconcile_confirmed_no_effect(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
    attempt: &DiscoveryCommitAttemptRecord,
    operation: DiscoveryOperationKind,
) -> CoreResult<()> {
    if attempt.phase != DiscoveryCommitPhase::OutcomeUnknown {
        return Err(CoreError::invalid(
            "confirmed no-effect resolution requires an unknown commit phase",
        ));
    }
    match operation {
        DiscoveryOperationKind::AtomicCommit => {
            ensure_discovery_attempt_graph_absent(transaction, attempt)?;
            let touched_steps = transaction
                .query_row(
                    "SELECT COUNT(*)
                     FROM provider_discovery_compensation_steps
                     WHERE commit_attempt_id = ?1 AND status <> 'pending'",
                    [attempt.id.as_str()],
                    |row| row.get::<_, u32>(0),
                )
                .map_err(database_error)?;
            if touched_steps != 0 {
                return Err(CoreError::invalid(
                    "no-effect commit has already touched its compensation recipe",
                ));
            }
            match write.transition.session.state {
                DiscoveryState::Interrupted => {
                    let next_phase =
                        if write
                            .transition
                            .session
                            .recovery
                            .as_ref()
                            .is_some_and(|checkpoint| {
                                checkpoint.operation == DiscoveryOperationKind::Compensation
                            })
                        {
                            DiscoveryCommitPhase::CompensationRequired
                        } else {
                            DiscoveryCommitPhase::Prepared
                        };
                    set_commit_phase_from_unknown(
                        transaction,
                        attempt,
                        next_phase,
                        write.occurred_at,
                    )
                }
                DiscoveryState::Cancelled => {
                    restore_discovery_provider_selection(
                        transaction,
                        &attempt.plan.previous_selection,
                    )?;
                    complete_no_effect_recipe(transaction, attempt, write.occurred_at)
                }
                _ => Err(CoreError::invalid(
                    "confirmed no-effect commit produced an invalid session state",
                )),
            }
        }
        DiscoveryOperationKind::Compensation => {
            transaction
                .execute(
                    "UPDATE provider_discovery_compensation_steps
                     SET status = 'pending',
                         last_failure_json = NULL,
                         updated_at = ?2,
                         completed_at = NULL
                     WHERE commit_attempt_id = ?1 AND status = 'outcome_unknown'",
                    params![attempt.id.as_str(), write.occurred_at.to_rfc3339()],
                )
                .map_err(database_error)?;
            let in_progress = transaction
                .query_row(
                    "SELECT EXISTS(
                         SELECT 1 FROM provider_discovery_compensation_steps
                         WHERE commit_attempt_id = ?1 AND status = 'in_progress'
                     )",
                    [attempt.id.as_str()],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(database_error)?;
            if in_progress {
                return Err(corrupted(
                    "confirmed no-effect compensation left a step in progress",
                ));
            }
            if write.transition.session.state != DiscoveryState::Interrupted {
                return Err(CoreError::invalid(
                    "incomplete compensation cannot be terminalized as no-effect",
                ));
            }
            set_commit_phase_from_unknown(
                transaction,
                attempt,
                DiscoveryCommitPhase::Compensating,
                write.occurred_at,
            )
        }
        _ => Err(CoreError::invalid(
            "confirmed no-effect ledger reconciliation requires persistent work",
        )),
    }
}

fn set_commit_phase_from_unknown(
    transaction: &Transaction<'_>,
    attempt: &DiscoveryCommitAttemptRecord,
    next: DiscoveryCommitPhase,
    updated_at: DateTime<Utc>,
) -> CoreResult<()> {
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_commit_attempts
             SET phase = ?2, updated_at = ?3, completed_at = NULL
             WHERE id = ?1 AND phase = 'outcome_unknown'",
            params![attempt.id.as_str(), next.as_str(), updated_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "unknown commit attempt changed concurrently",
        ));
    }
    Ok(())
}

fn complete_no_effect_recipe(
    transaction: &Transaction<'_>,
    attempt: &DiscoveryCommitAttemptRecord,
    completed_at: DateTime<Utc>,
) -> CoreResult<()> {
    transaction
        .execute(
            "UPDATE provider_discovery_compensation_steps
             SET status = 'completed',
                 last_failure_json = NULL,
                 updated_at = ?2,
                 completed_at = ?2
             WHERE commit_attempt_id = ?1",
            params![attempt.id.as_str(), completed_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_commit_attempts
             SET phase = 'compensated', updated_at = ?2, completed_at = ?2
             WHERE id = ?1 AND phase = 'outcome_unknown'",
            params![attempt.id.as_str(), completed_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "no-effect commit attempt changed concurrently",
        ));
    }
    Ok(())
}

fn validate_failed_compensation_ledger(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<()> {
    let attempt_id = write
        .transition
        .session
        .commit_attempt_id
        .as_ref()
        .ok_or_else(|| corrupted("failed compensation has no commit attempt"))?;
    let attempt = load_commit_attempt(transaction, attempt_id)?;
    if attempt.session_id != write.transition.session.id
        || write.transition.session.commit_plan_sha256.as_deref()
            != Some(attempt.plan_sha256.as_str())
    {
        return Err(CoreError::invalid(
            "failed compensation does not own its commit attempt",
        ));
    }
    if attempt.phase != DiscoveryCommitPhase::Compensating {
        return Err(CoreError::invalid(
            "failed compensation requires the compensating commit phase",
        ));
    }
    let unresolved_step = transaction
        .query_row(
            "SELECT EXISTS(
                 SELECT 1 FROM provider_discovery_compensation_steps
                 WHERE commit_attempt_id = ?1
                   AND status IN ('in_progress', 'outcome_unknown')
             )",
            [attempt.id.as_str()],
            |row| row.get::<_, bool>(0),
        )
        .map_err(database_error)?;
    if unresolved_step {
        return Err(CoreError::invalid(
            "failed compensation must first durably fail its active step",
        ));
    }
    Ok(())
}

fn ensure_discovery_attempt_graph_absent(
    transaction: &Transaction<'_>,
    attempt: &DiscoveryCommitAttemptRecord,
) -> CoreResult<()> {
    if load_discovered_provider_graph_rows(
        transaction,
        &attempt.plan.template_id,
        attempt.plan.template_version,
        &attempt.plan.connection_id,
    )?
    .is_some()
    {
        return Err(CoreError::invalid(
            "commit graph must be absent before this ledger transition",
        ));
    }
    for route_id in &attempt.plan.model_route_ids {
        let exists = transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM provider_models WHERE id = ?1)",
                [route_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if exists {
            return Err(corrupted(
                "commit graph is absent but a planned route remains",
            ));
        }
    }
    Ok(())
}

fn verify_discovery_attempt_graph(
    transaction: &Transaction<'_>,
    attempt: &DiscoveryCommitAttemptRecord,
) -> CoreResult<()> {
    let graph = load_discovered_provider_graph_rows(
        transaction,
        &attempt.plan.template_id,
        attempt.plan.template_version,
        &attempt.plan.connection_id,
    )?
    .ok_or_else(|| CoreError::invalid("confirmed commit graph is missing"))?;
    let ownership = stored_provider_graph_ownership_hash(&graph)?;
    if ownership != attempt.plan.graph_sha256
        || graph_ownership_audit_hash(transaction, &attempt.session_id)? != ownership
    {
        return Err(CoreError::invalid(
            "confirmed commit graph differs from its approved ownership digest",
        ));
    }
    Ok(())
}

fn validate_terminal_compensation_transition(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<()> {
    let action_is_success = write.transition.receipt.action_kind == "compensation_succeeded";
    let result_is_terminal_failure = matches!(
        write.transition.session.state,
        DiscoveryState::Cancelled | DiscoveryState::Failed
    );
    if !action_is_success
        && (!result_is_terminal_failure || write.transition.session.commit_attempt_id.is_none())
    {
        return Ok(());
    }
    let attempt_id = write
        .transition
        .session
        .commit_attempt_id
        .as_ref()
        .ok_or_else(|| corrupted("terminal compensation transition has no commit attempt"))?;
    let attempt = load_commit_attempt(transaction, attempt_id)?;
    if attempt.session_id != write.transition.session.id {
        return Err(corrupted(
            "terminal compensation commit attempt belongs to another session",
        ));
    }
    if action_is_success && attempt.phase == DiscoveryCommitPhase::Compensating {
        validate_commit_phase_preconditions(
            transaction,
            &attempt,
            DiscoveryCommitPhase::Compensated,
        )?;
        let changed = transaction
            .execute(
                "UPDATE provider_discovery_commit_attempts
                 SET phase = 'compensated', updated_at = ?2, completed_at = ?2
                 WHERE id = ?1 AND phase = 'compensating'",
                params![attempt.id.as_str(), write.occurred_at.to_rfc3339()],
            )
            .map_err(database_error)?;
        if changed != 1 {
            return Err(CoreError::invalid(
                "terminal compensation attempt changed concurrently",
            ));
        }
    } else if attempt.phase != DiscoveryCommitPhase::Compensated {
        return Err(CoreError::invalid(
            "terminal discovery transition would abandon an incomplete compensation recipe",
        ));
    }
    Ok(())
}

fn reconcile_confirmed_compensation_in_transaction(
    transaction: &Transaction<'_>,
    write: &DiscoveryTransitionWrite,
) -> CoreResult<()> {
    let attempt_id = write
        .transition
        .session
        .commit_attempt_id
        .as_ref()
        .ok_or_else(|| corrupted("confirmed compensation has no commit attempt"))?;
    let attempt = load_commit_attempt(transaction, attempt_id)?;
    if attempt.session_id != write.transition.session.id
        || !matches!(
            attempt.phase,
            DiscoveryCommitPhase::Compensating | DiscoveryCommitPhase::OutcomeUnknown
        )
    {
        return Err(CoreError::invalid(
            "confirmed compensation does not match an unresolved durable attempt",
        ));
    }
    let graph = load_discovered_provider_graph_rows(
        transaction,
        &attempt.plan.template_id,
        attempt.plan.template_version,
        &attempt.plan.connection_id,
    )?;
    if graph.is_some() {
        return Err(CoreError::invalid(
            "cannot confirm compensation while the provider graph still exists",
        ));
    }
    for route_id in &attempt.plan.model_route_ids {
        let route_exists = transaction
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM provider_models WHERE id = ?1)",
                [route_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if route_exists {
            return Err(corrupted(
                "confirmed compensation left a planned model route behind",
            ));
        }
    }
    restore_discovery_provider_selection(transaction, &attempt.plan.previous_selection)?;
    transaction
        .execute(
            "UPDATE provider_discovery_compensation_steps
             SET status = 'completed',
                 last_failure_json = NULL,
                 updated_at = ?2,
                 completed_at = ?2
             WHERE commit_attempt_id = ?1
               AND status <> 'completed'",
            params![attempt.id.as_str(), write.occurred_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_commit_attempts
             SET phase = 'compensated', updated_at = ?2, completed_at = ?2
             WHERE id = ?1 AND phase IN ('compensating', 'outcome_unknown')",
            params![attempt.id.as_str(), write.occurred_at.to_rfc3339()],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "confirmed compensation attempt changed concurrently",
        ));
    }
    Ok(())
}

fn complete_commit_attempt_for_ready_transition(
    transaction: &Transaction<'_>,
    transition: &DiscoveryTransition,
    completed_at: DateTime<Utc>,
) -> CoreResult<()> {
    let attempt_id = transition
        .session
        .commit_attempt_id
        .as_ref()
        .ok_or_else(|| corrupted("ready discovery session has no commit attempt"))?;
    let (phase, plan_sha256, plan_json) = transaction
        .query_row(
            "SELECT phase, plan_sha256, plan_json
             FROM provider_discovery_commit_attempts
             WHERE id = ?1 AND session_id = ?2",
            params![attempt_id.as_str(), transition.session.id.as_str()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| corrupted("ready discovery commit attempt is missing"))?;
    if phase == "completed" {
        return Ok(());
    }
    let plan = serde_json::from_str::<DiscoveryCommitPlan>(&plan_json)
        .map_err(|_| corrupted("stored discovery commit plan is invalid"))?;
    plan.validate()
        .map_err(|_| corrupted("stored discovery commit plan violates its contract"))?;
    if sha256_hex(plan_json.as_bytes()) != plan_sha256
        || transition.session.commit_plan_sha256.as_deref() != Some(plan_sha256.as_str())
        || transition.session.committed_connection_id.as_ref() != Some(&plan.connection_id)
    {
        return Err(CoreError::invalid(
            "ready discovery session does not match its immutable commit plan",
        ));
    }
    let required_phase = if plan.credential_ref.is_some() {
        "credential_reference_applied"
    } else {
        "database_applied"
    };
    if phase != required_phase {
        return Err(CoreError::invalid(
            "discovery commit cannot finish before all durable phases are applied",
        ));
    }
    let changed = transaction
        .execute(
            "UPDATE provider_discovery_commit_attempts
             SET phase = 'completed', updated_at = ?2, completed_at = ?2
             WHERE id = ?1 AND phase = ?3",
            params![
                attempt_id.as_str(),
                completed_at.to_rfc3339(),
                required_phase
            ],
        )
        .map_err(database_error)?;
    if changed != 1 {
        return Err(CoreError::invalid(
            "discovery commit phase changed concurrently",
        ));
    }
    Ok(())
}

fn load_commit_attempt(
    connection: &Connection,
    attempt_id: &DiscoveryCommitAttemptId,
) -> CoreResult<DiscoveryCommitAttemptRecord> {
    let row = connection
        .query_row(
            "SELECT id, session_id, attempt_number, action_id, expected_revision,
                    plan_sha256, plan_json, phase, created_at, updated_at, completed_at
             FROM provider_discovery_commit_attempts
             WHERE id = ?1",
            [attempt_id.as_str()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, u32>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, u64>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, String>(9)?,
                    row.get::<_, Option<String>>(10)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "discovery commit attempt was not found",
                false,
            )
        })?;
    let plan = serde_json::from_str::<DiscoveryCommitPlan>(&row.6)
        .map_err(|_| corrupted("stored discovery commit plan is invalid"))?;
    plan.validate()
        .map_err(|_| corrupted("stored discovery commit plan violates its contract"))?;
    if plan.attempt_id.as_str() != row.0
        || plan.session_id.as_str() != row.1
        || plan.expected_revision != row.4
        || sha256_hex(row.6.as_bytes()) != row.5
    {
        return Err(corrupted(
            "stored discovery commit attempt does not match its plan",
        ));
    }
    Ok(DiscoveryCommitAttemptRecord {
        id: DiscoveryCommitAttemptId::parse(row.0).map_err(contract_error)?,
        session_id: DiscoverySessionId::from(row.1),
        attempt_number: row.2,
        action_id: DiscoveryActionId::parse(row.3).map_err(contract_error)?,
        expected_revision: row.4,
        plan_sha256: row.5,
        plan,
        phase: DiscoveryCommitPhase::parse(&row.7)?,
        created_at: parse_timestamp(&row.8, "commit attempt created_at")?,
        updated_at: parse_timestamp(&row.9, "commit attempt updated_at")?,
        completed_at: row
            .10
            .as_deref()
            .map(|value| parse_timestamp(value, "commit attempt completed_at"))
            .transpose()?,
    })
}

fn validate_commit_phase_preconditions(
    transaction: &Transaction<'_>,
    attempt: &DiscoveryCommitAttemptRecord,
    next: DiscoveryCommitPhase,
) -> CoreResult<()> {
    let session_state = transaction
        .query_row(
            "SELECT state
             FROM provider_discovery_sessions
             WHERE id = ?1 AND commit_attempt_id = ?2",
            params![attempt.session_id.as_str(), attempt.id.as_str()],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| corrupted("commit attempt is detached from its discovery session"))?;
    match next {
        DiscoveryCommitPhase::CredentialReferenceApplied => {
            if attempt.plan.credential_ref.is_none() || session_state != "committing" {
                return Err(CoreError::invalid(
                    "credential confirmation requires a credential-bearing active commit",
                ));
            }
            require_started_session_operation(transaction, &attempt.session_id, "atomic_commit")?;
            verify_discovery_attempt_graph(transaction, attempt)
        }
        DiscoveryCommitPhase::Compensated => {
            if session_state != "compensating" {
                return Err(CoreError::invalid(
                    "compensated phase requires a compensating discovery session",
                ));
            }
            require_started_session_operation(transaction, &attempt.session_id, "compensation")?;
            let (total_steps, incomplete_steps) = transaction
                .query_row(
                    "SELECT COUNT(*),
                            COALESCE(SUM(
                                CASE WHEN status = 'completed' THEN 0 ELSE 1 END
                            ), 0)
                     FROM provider_discovery_compensation_steps
                     WHERE commit_attempt_id = ?1",
                    [attempt.id.as_str()],
                    |row| Ok((row.get::<_, u32>(0)?, row.get::<_, u32>(1)?)),
                )
                .map_err(database_error)?;
            ensure_discovery_attempt_graph_absent(transaction, attempt)?;
            if total_steps == 0 || incomplete_steps != 0 {
                return Err(CoreError::invalid(
                    "compensated phase requires every recipe step to be complete",
                ));
            }
            Ok(())
        }
        _ => Err(CoreError::internal(
            "unsupported standalone discovery commit phase validation",
        )),
    }
}

type CompensationRow = (
    String,
    String,
    u32,
    String,
    String,
    String,
    String,
    u32,
    Option<String>,
    String,
    String,
    Option<String>,
);

fn decode_compensation_row(
    row: CompensationRow,
    plan: &DiscoveryCommitPlan,
) -> CoreResult<DiscoveryCompensationRecord> {
    let kind = serde_json::from_value(Value::String(row.4))
        .map_err(|_| corrupted("stored discovery compensation kind is invalid"))?;
    let mut step = serde_json::from_str::<DiscoveryCompensationStep>(&row.5)
        .map_err(|_| corrupted("stored discovery compensation step is invalid"))?;
    step.validate_against(plan)
        .map_err(|_| corrupted("stored compensation target differs from its commit plan"))?;
    if step.status != DomainCompensationStatus::Pending {
        return Err(corrupted(
            "stored immutable compensation recipe is not pending",
        ));
    }
    let status = DiscoveryCompensationStatus::parse(&row.6)?;
    if step.ordinal != row.2 || step.action_id.as_str() != row.3 || step.kind != kind {
        return Err(corrupted(
            "stored compensation columns differ from their typed step",
        ));
    }
    step.status = match status {
        DiscoveryCompensationStatus::Pending => DomainCompensationStatus::Pending,
        DiscoveryCompensationStatus::InProgress => DomainCompensationStatus::InProgress,
        DiscoveryCompensationStatus::Completed => DomainCompensationStatus::Completed,
        DiscoveryCompensationStatus::Failed => DomainCompensationStatus::Failed,
        DiscoveryCompensationStatus::OutcomeUnknown => DomainCompensationStatus::OutcomeUnknown,
    };
    let last_failure = row
        .8
        .as_deref()
        .map(|json| {
            let failure = serde_json::from_str(json)
                .map_err(|_| corrupted("stored compensation failure is invalid"))?;
            lorepia_domain::discovery::DiscoveryFailure::validate(&failure)
                .map_err(|_| corrupted("stored compensation failure is invalid"))?;
            Ok(failure)
        })
        .transpose()?;
    Ok(DiscoveryCompensationRecord {
        id: row.0,
        commit_attempt_id: DiscoveryCommitAttemptId::parse(row.1).map_err(contract_error)?,
        ordinal: row.2,
        action_id: DiscoveryActionId::parse(row.3).map_err(contract_error)?,
        kind,
        step,
        status,
        attempt_count: row.7,
        last_failure,
        created_at: parse_timestamp(&row.9, "compensation created_at")?,
        updated_at: parse_timestamp(&row.10, "compensation updated_at")?,
        completed_at: row
            .11
            .as_deref()
            .map(|value| parse_timestamp(value, "compensation completed_at"))
            .transpose()?,
    })
}

const fn compensation_status_transition_allowed(
    expected: DiscoveryCompensationStatus,
    next: DiscoveryCompensationStatus,
) -> bool {
    matches!(
        (expected, next),
        (
            DiscoveryCompensationStatus::Pending,
            DiscoveryCompensationStatus::InProgress
        ) | (
            DiscoveryCompensationStatus::InProgress,
            DiscoveryCompensationStatus::Completed
                | DiscoveryCompensationStatus::Failed
                | DiscoveryCompensationStatus::OutcomeUnknown
        )
    )
}

fn ensure_foreign_keys_clean(connection: &Connection) -> CoreResult<()> {
    let violation = {
        let mut statement = connection
            .prepare("PRAGMA foreign_key_check")
            .map_err(database_error)?;
        statement
            .query_row([], |_| Ok(()))
            .optional()
            .map_err(database_error)?
            .is_some()
    };
    if violation {
        Err(corrupted(
            "provider graph compensation created a foreign-key violation",
        ))
    } else {
        Ok(())
    }
}

type SessionRow = (
    String,
    String,
    u64,
    u64,
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    bool,
    Option<String>,
    Option<String>,
    String,
    String,
);

fn load_session_snapshot(
    connection: &Connection,
    session_id: &str,
) -> CoreResult<Option<DiscoverySessionSnapshot>> {
    let row = connection
        .query_row(
            "SELECT id, state, revision, next_event_sequence, sanitized_input_json,
                    draft_json, review_diff_json, error_json, recovery_json,
                    unknown_operation, manifest_sha256, commit_plan_sha256,
                    commit_attempt_id, committed_connection_id, cancellation_pending,
                    active_operation_id, active_effect_approval_json,
                    created_at, updated_at
             FROM provider_discovery_sessions
             WHERE id = ?1",
            [session_id],
            |row| {
                Ok((
                    row.get(0)?,
                    row.get(1)?,
                    row.get(2)?,
                    row.get(3)?,
                    row.get(4)?,
                    row.get(5)?,
                    row.get(6)?,
                    row.get(7)?,
                    row.get(8)?,
                    row.get(9)?,
                    row.get(10)?,
                    row.get(11)?,
                    row.get(12)?,
                    row.get(13)?,
                    row.get(14)?,
                    row.get(15)?,
                    row.get(16)?,
                    row.get(17)?,
                    row.get(18)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?;
    row.map(|row| decode_session_row(connection, row))
        .transpose()
}

#[allow(clippy::too_many_lines)]
fn decode_session_row(
    connection: &Connection,
    row: SessionRow,
) -> CoreResult<DiscoverySessionSnapshot> {
    let input = serde_json::from_str::<SanitizedDiscoveryInput>(&row.4)
        .map_err(|_| corrupted("stored discovery input is invalid"))?;
    input
        .validate()
        .map_err(|_| corrupted("stored discovery input violates its contract"))?;
    validate_sanitized_input(&input)
        .map_err(|_| corrupted("stored discovery input contains credential-like material"))?;
    let state = parse_discovery_state(&row.1)?;
    let recovery = row
        .8
        .as_deref()
        .map(|json| {
            serde_json::from_str::<DiscoveryRecoveryCheckpoint>(json)
                .map_err(|_| corrupted("stored discovery recovery checkpoint is invalid"))
        })
        .transpose()?;
    let unknown_operation = row.9.as_deref().map(parse_operation_kind).transpose()?;
    let failure = row
        .7
        .as_deref()
        .map(|json| {
            serde_json::from_str(json).map_err(|_| corrupted("stored discovery failure is invalid"))
        })
        .transpose()?;
    let active_operation_id = row
        .15
        .map(DiscoveryOperationId::parse)
        .transpose()
        .map_err(contract_error)?;
    let active_effect_approval = row
        .16
        .as_deref()
        .map(|json| {
            let binding = serde_json::from_str::<DiscoveryApprovalBinding>(json)
                .map_err(|_| corrupted("stored active discovery approval is invalid"))?;
            binding
                .validate()
                .map_err(|_| corrupted("stored active discovery approval is invalid"))?;
            if serde_json::to_string(&binding)
                .map_err(|_| corrupted("stored active discovery approval cannot be encoded"))?
                != json
            {
                return Err(corrupted(
                    "stored active discovery approval is not canonical",
                ));
            }
            Ok(binding)
        })
        .transpose()?;
    if let Some(operation_id) = &active_operation_id {
        let operation = load_operation_by_id(connection, operation_id)?;
        if operation.session_id.as_str() != row.0
            || state.operation() != Some(operation.kind)
            || operation.approval != active_effect_approval
            || !matches!(
                operation.status,
                DiscoveryOperationStatus::Prepared | DiscoveryOperationStatus::Started
            )
        {
            return Err(corrupted(
                "active discovery operation does not match the session binding",
            ));
        }
        if let Some(binding) = &operation.approval {
            validate_recovery_approval_binding(connection, &row.0, binding, operation.kind)?;
        }
    } else if let Some(binding) = &active_effect_approval {
        let recoverable_operation = match state {
            DiscoveryState::Interrupted => recovery.as_ref().map(|checkpoint| checkpoint.operation),
            DiscoveryState::UnknownOutcome => unknown_operation,
            _ => None,
        };
        let Some(operation) = recoverable_operation.filter(|operation| {
            matches!(
                operation,
                DiscoveryOperationKind::BuildAssistantManifestDraft
                    | DiscoveryOperationKind::ProbeCapabilities
            )
        }) else {
            return Err(corrupted(
                "active discovery approval exists without recoverable billable work",
            ));
        };
        validate_recovery_approval_binding(connection, &row.0, binding, operation)?;
    }
    let session = ProviderDiscoverySession {
        id: DiscoverySessionId::from(row.0),
        input,
        state,
        revision: row.2,
        next_event_sequence: row.3,
        recovery,
        unknown_operation,
        manifest_sha256: row.10,
        commit_plan_sha256: row.11,
        commit_attempt_id: row
            .12
            .map(DiscoveryCommitAttemptId::parse)
            .transpose()
            .map_err(contract_error)?,
        committed_connection_id: row.13.map(Into::into),
        cancellation_pending: row.14,
        active_effect_approval,
        failure,
    };
    session
        .validate()
        .map_err(|_| corrupted("stored discovery session violates its domain contract"))?;
    if let Some(attempt_id) = &session.commit_attempt_id {
        let attempt = load_commit_attempt(connection, attempt_id).map_err(|error| {
            if error.code == CoreErrorCode::NotFound {
                corrupted("stored discovery session references a missing commit attempt")
            } else {
                error
            }
        })?;
        if attempt.session_id != session.id
            || session.commit_plan_sha256.as_deref() != Some(attempt.plan_sha256.as_str())
        {
            return Err(corrupted(
                "stored discovery session commit binding does not match its attempt",
            ));
        }
    }
    let draft_json = row
        .5
        .as_deref()
        .map(|json| decode_redacted_json(json, "stored discovery draft"))
        .transpose()?;
    let review = row
        .6
        .as_deref()
        .map(|json| {
            let review = serde_json::from_str::<DiscoveryReviewDiff>(json)
                .map_err(|_| corrupted("stored discovery review is invalid"))?;
            review
                .validate()
                .map_err(|_| corrupted("stored discovery review violates its contract"))?;
            Ok(review)
        })
        .transpose()?;
    if let Some(review) = &review {
        validate_review_evidence_references(connection, &session.id, review)
            .map_err(|_| corrupted("stored discovery review has invalid evidence references"))?;
    }
    Ok(DiscoverySessionSnapshot {
        session,
        active_operation_id,
        draft_json,
        review,
        created_at: parse_timestamp(&row.17, "discovery created_at")?,
        updated_at: parse_timestamp(&row.18, "discovery updated_at")?,
    })
}

fn decode_evidence_row(
    row: (String, String, String, String, String, String, String),
) -> CoreResult<DiscoveryEvidenceRecord> {
    let evidence = DiscoveryEvidenceRecord {
        id: EvidenceId::from(row.0),
        session_id: DiscoverySessionId::from(row.1),
        kind: DiscoveryEvidenceKind::parse(&row.2)?,
        source_url: HttpUrl::parse(&row.3)
            .map_err(|_| corrupted("stored discovery evidence URL is invalid"))?,
        content_sha256: row.4,
        extracted_json: decode_redacted_json(&row.5, "stored discovery evidence")?,
        fetched_at: parse_timestamp(&row.6, "discovery evidence fetched_at")?,
    };
    validate_discovery_evidence(&evidence)
        .map_err(|_| corrupted("stored discovery evidence violates its contract"))?;
    Ok(evidence)
}

#[allow(clippy::too_many_lines)]
fn validate_recovery_approval_binding(
    connection: &Connection,
    session_id: &str,
    binding: &DiscoveryApprovalBinding,
    operation: DiscoveryOperationKind,
) -> CoreResult<()> {
    let row = connection
        .query_row(
            "SELECT approval_kind, decision, grant_json, grant_sha256
             FROM provider_discovery_approvals
             WHERE id = ?1 AND session_id = ?2",
            params![binding.approval_id.as_str(), session_id],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| corrupted("recoverable billable approval record is missing"))?;
    if row.1 != "approved"
        || row.3 != binding.grant_sha256
        || sha256_hex(row.2.as_bytes()) != binding.grant_sha256
    {
        return Err(corrupted(
            "recoverable billable approval binding does not match its immutable grant",
        ));
    }
    let grant = serde_json::from_str::<DiscoveryApprovalGrant>(&row.2)
        .map_err(|_| corrupted("recoverable billable approval grant is invalid"))?;
    grant
        .validate()
        .map_err(|_| corrupted("recoverable billable approval grant is invalid"))?;
    if serde_json::to_string(&grant)
        .map_err(|_| corrupted("recoverable billable approval grant cannot be encoded"))?
        != row.2
    {
        return Err(corrupted(
            "recoverable billable approval grant is not canonical",
        ));
    }
    match &grant {
        DiscoveryApprovalGrant::AssistantConsent {
            assistant_route_id,
            evidence_ids,
            ..
        } => {
            let typed_session_id = DiscoverySessionId::from(session_id);
            validate_session_evidence_ids(
                connection,
                &typed_session_id,
                evidence_ids,
                "recoverable assistant consent",
            )
            .map_err(|_| {
                corrupted("recoverable assistant approval has invalid evidence references")
            })?;
            let route_exists = connection
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM provider_models WHERE id = ?1)",
                    [assistant_route_id.as_str()],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(database_error)?;
            if !route_exists {
                return Err(corrupted("recoverable assistant approval route is missing"));
            }
        }
        DiscoveryApprovalGrant::CapabilityProbe {
            model_route_ids,
            budget,
        } => {
            validate_capability_probe_grant(
                connection,
                &DiscoverySessionId::from(session_id),
                model_route_ids,
                *budget,
            )
            .map_err(|_| {
                corrupted("recoverable capability approval differs from its durable proposal")
            })?;
        }
        _ => {}
    }
    let expected_kind = match operation {
        DiscoveryOperationKind::BuildAssistantManifestDraft => "assistant_consent",
        DiscoveryOperationKind::ProbeCapabilities => "capability_probe",
        _ => {
            return Err(corrupted(
                "non-billable operation carried a recovery approval",
            ));
        }
    };
    let grant_matches = matches!(
        (operation, &grant),
        (
            DiscoveryOperationKind::BuildAssistantManifestDraft,
            DiscoveryApprovalGrant::AssistantConsent { .. }
        ) | (
            DiscoveryOperationKind::ProbeCapabilities,
            DiscoveryApprovalGrant::CapabilityProbe { .. }
        )
    );
    if row.0 != expected_kind || !grant_matches {
        return Err(corrupted(
            "recoverable billable approval has the wrong grant type",
        ));
    }
    Ok(())
}

fn decode_candidate_row(
    row: (String, String, String, String, String, u64, String),
) -> CoreResult<StoredDiscoveryCandidate> {
    let summary = serde_json::from_str(&row.3)
        .map_err(|_| corrupted("stored discovery candidate summary is invalid"))?;
    let candidate = DiscoveryCandidate {
        id: DiscoveryCandidateId::parse(row.0).map_err(contract_error)?,
        session_id: DiscoverySessionId::from(row.1),
        summary,
        evidence_ids: serde_json::from_str(&row.4)
            .map_err(|_| corrupted("stored candidate evidence references are invalid"))?,
        created_at: parse_timestamp(&row.6, "discovery candidate created_at")?,
    };
    candidate
        .validate()
        .map_err(|_| corrupted("stored discovery candidate violates its contract"))?;
    if candidate_kind(&candidate) != row.2 {
        return Err(corrupted(
            "stored discovery candidate kind does not match its typed summary",
        ));
    }
    Ok(StoredDiscoveryCandidate {
        candidate,
        proposed_revision: row.5,
    })
}

type ApprovalRow = (
    String,
    String,
    String,
    Option<String>,
    String,
    String,
    u64,
    String,
    String,
);

fn decode_approval_row(row: ApprovalRow) -> CoreResult<DiscoveryApprovalRecord> {
    let decision = parse_approval_decision(&row.4)?;
    let grant = serde_json::from_str::<DiscoveryApprovalGrant>(&row.5)
        .map_err(|_| corrupted("stored discovery approval grant is invalid"))?;
    let canonical_grant = encode_approval_grant(&grant)
        .map_err(|_| corrupted("stored discovery approval grant is not canonical"))?;
    let expected_candidate_id = match &grant {
        DiscoveryApprovalGrant::TemplateSelection { candidate_id } => Some(candidate_id.as_str()),
        _ => None,
    };
    if row.2 != approval_kind(&grant)
        || row.3.as_deref() != expected_candidate_id
        || row.5 != canonical_grant
        || row.7 != sha256_hex(canonical_grant.as_bytes())
    {
        return Err(corrupted(
            "stored discovery approval columns do not match its typed grant",
        ));
    }
    let approval = DiscoveryApprovalRecord {
        id: DiscoveryApprovalId::parse(row.0).map_err(contract_error)?,
        session_id: DiscoverySessionId::from(row.1),
        session_revision: row.6,
        decision,
        grant,
        created_at: parse_timestamp(&row.8, "discovery approval created_at")?,
    };
    approval
        .validate()
        .map_err(|_| corrupted("stored discovery approval violates its contract"))?;
    Ok(approval)
}

fn load_operation_by_id(
    connection: &Connection,
    operation_id: &DiscoveryOperationId,
) -> CoreResult<DiscoveryOperationRecord> {
    let row = connection
        .query_row(
            "SELECT id, session_id, operation_kind, side_effect_class, status,
                    action_id, expected_revision, request_sha256, approval_id,
                    approval_grant_sha256, started_at, finished_at, created_at, updated_at
             FROM provider_discovery_operations
             WHERE id = ?1",
            [operation_id.as_str()],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                    row.get::<_, String>(5)?,
                    row.get::<_, u64>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, Option<String>>(8)?,
                    row.get::<_, Option<String>>(9)?,
                    row.get::<_, Option<String>>(10)?,
                    row.get::<_, Option<String>>(11)?,
                    row.get::<_, String>(12)?,
                    row.get::<_, String>(13)?,
                ))
            },
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| corrupted("active discovery operation is missing"))?;
    decode_operation_row(row)
}

type OperationRow = (
    String,
    String,
    String,
    String,
    String,
    String,
    u64,
    String,
    Option<String>,
    Option<String>,
    Option<String>,
    Option<String>,
    String,
    String,
);

fn decode_operation_row(row: OperationRow) -> CoreResult<DiscoveryOperationRecord> {
    let approval = match (row.8, row.9) {
        (None, None) => None,
        (Some(approval_id), Some(grant_sha256)) => Some(DiscoveryApprovalBinding {
            approval_id: DiscoveryApprovalId::parse(approval_id).map_err(contract_error)?,
            grant_sha256,
        }),
        _ => {
            return Err(corrupted(
                "stored discovery operation has a partial approval binding",
            ));
        }
    };
    if let Some(binding) = &approval {
        binding
            .validate()
            .map_err(|_| corrupted("stored operation approval binding is invalid"))?;
    }
    let kind = parse_operation_kind(&row.2)?;
    let side_effect_class = parse_side_effect_class(&row.3)?;
    if kind.side_effect_class() != side_effect_class {
        return Err(corrupted(
            "stored discovery operation side-effect class does not match its kind",
        ));
    }
    Ok(DiscoveryOperationRecord {
        id: DiscoveryOperationId::parse(row.0).map_err(contract_error)?,
        session_id: DiscoverySessionId::from(row.1),
        kind,
        side_effect_class,
        status: DiscoveryOperationStatus::parse(&row.4)?,
        action_id: DiscoveryActionId::parse(row.5).map_err(contract_error)?,
        expected_revision: row.6,
        request_sha256: row.7,
        approval,
        started_at: row
            .10
            .as_deref()
            .map(|value| parse_timestamp(value, "discovery operation started_at"))
            .transpose()?,
        finished_at: row
            .11
            .as_deref()
            .map(|value| parse_timestamp(value, "discovery operation finished_at"))
            .transpose()?,
        created_at: parse_timestamp(&row.12, "discovery operation created_at")?,
        updated_at: parse_timestamp(&row.13, "discovery operation updated_at")?,
    })
}

fn load_pollable_outbox_rows(
    transaction: &Transaction<'_>,
    limit: u32,
    available_at: DateTime<Utc>,
) -> CoreResult<Vec<DiscoveryOutboxEvent>> {
    let mut statement = transaction
        .prepare(
            "SELECT event.id, event.session_id, event.sequence, event.event_version,
                    event.session_revision, event.state, event.event_json,
                    event.delivery_attempts, event.available_at, event.created_at
             FROM provider_discovery_event_outbox AS event
             WHERE event.delivered_at IS NULL
               AND event.available_at <= ?1
               AND NOT EXISTS (
                   SELECT 1
                   FROM provider_discovery_event_outbox AS earlier
                   WHERE earlier.session_id = event.session_id
                     AND earlier.delivered_at IS NULL
                     AND earlier.sequence < event.sequence
               )
             ORDER BY event.available_at, event.session_id, event.sequence
             LIMIT ?2",
        )
        .map_err(database_error)?;
    statement
        .query_map(params![available_at.to_rfc3339(), limit], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, u64>(2)?,
                row.get::<_, u32>(3)?,
                row.get::<_, u64>(4)?,
                row.get::<_, String>(5)?,
                row.get::<_, String>(6)?,
                row.get::<_, u32>(7)?,
                row.get::<_, String>(8)?,
                row.get::<_, String>(9)?,
            ))
        })
        .map_err(database_error)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(database_error)?
        .into_iter()
        .map(decode_outbox_row)
        .collect()
}

type OutboxRow = (
    String,
    String,
    u64,
    u32,
    u64,
    String,
    String,
    u32,
    String,
    String,
);

fn decode_outbox_row(row: OutboxRow) -> CoreResult<DiscoveryOutboxEvent> {
    let event = serde_json::from_str::<ProviderDiscoveryEvent>(&row.6)
        .map_err(|_| corrupted("stored discovery outbox event is invalid"))?;
    if event.id.as_str() != row.0
        || event.session_id.as_str() != row.1
        || event.sequence != row.2
        || event.version != row.3
        || event.session_revision != row.4
        || enum_wire_result(serde_json::to_value(event.state), "discovery event state")? != row.5
    {
        return Err(corrupted(
            "stored discovery outbox columns do not match the typed event",
        ));
    }
    Ok(DiscoveryOutboxEvent {
        event,
        delivery_attempts: row.7,
        available_at: parse_timestamp(&row.8, "discovery event available_at")?,
        created_at: parse_timestamp(&row.9, "discovery event created_at")?,
    })
}

fn validate_limit(limit: u32) -> CoreResult<()> {
    if limit == 0 || limit > MAX_DISCOVERY_ROWS {
        return Err(CoreError::invalid(
            "discovery list limit must be from 1 to 1000",
        ));
    }
    Ok(())
}

fn validate_identifier(label: &str, value: &str, maximum: usize) -> CoreResult<()> {
    if value.is_empty()
        || value.len() > maximum
        || value.trim() != value
        || value.chars().any(char::is_control)
    {
        return Err(CoreError::invalid(format!(
            "{label} must be a bounded trimmed opaque identifier"
        )));
    }
    Ok(())
}

fn validate_sha256(label: &str, value: &str) -> CoreResult<()> {
    if value.len() != 64
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        return Err(CoreError::invalid(format!(
            "{label} must be a lowercase SHA-256 digest"
        )));
    }
    Ok(())
}

fn validate_discovery_evidence(evidence: &DiscoveryEvidenceRecord) -> CoreResult<()> {
    validate_identifier("discovery evidence id", evidence.id.as_str(), 256)?;
    validate_identifier(
        "discovery evidence session id",
        evidence.session_id.as_str(),
        128,
    )?;
    validate_sha256("discovery evidence content hash", &evidence.content_sha256)?;
    validate_persistable_discovery_url(
        evidence.source_url.as_str(),
        "discovery evidence source URL",
    )?;
    if !evidence.extracted_json.is_object() {
        return Err(CoreError::invalid(
            "discovery evidence extraction must be a JSON object",
        ));
    }
    encode_redacted_json(&evidence.extracted_json, "discovery evidence")?;
    Ok(())
}

fn validate_sanitized_input(input: &SanitizedDiscoveryInput) -> CoreResult<()> {
    if looks_like_secret(input.connection_id.as_str()) || looks_like_secret(&input.display_name) {
        return Err(CoreError::invalid(
            "discovery connection identity contains credential-like material",
        ));
    }
    validate_persistable_discovery_url(input.site_url.as_str(), "discovery site URL")?;
    if let Some(docs_url) = &input.docs_url {
        validate_persistable_discovery_url(docs_url.as_str(), "discovery docs URL")?;
    }
    if let Some(reference) = &input.credential_ref {
        validate_opaque_credential_reference(reference.as_str())?;
    }
    Ok(())
}

fn validate_persistable_discovery_url(value: &str, label: &str) -> CoreResult<()> {
    let parsed =
        url::Url::parse(value).map_err(|_| CoreError::invalid(format!("{label} is invalid")))?;
    if parsed.query().is_some()
        || parsed.fragment().is_some()
        || !parsed.username().is_empty()
        || parsed.password().is_some()
    {
        return Err(CoreError::invalid(format!(
            "{label} must not contain user information, a query, or a fragment"
        )));
    }
    if parsed.host_str().is_some_and(looks_like_secret) {
        return Err(CoreError::invalid(format!(
            "{label} contains credential-like host material"
        )));
    }
    for segment in parsed.path().split('/') {
        let mut decoded = segment.to_owned();
        for _ in 0..4 {
            if !decoded.as_bytes().contains(&b'%') {
                break;
            }
            let next = percent_decode_path_segment(&decoded).ok_or_else(|| {
                CoreError::invalid(format!("{label} contains invalid path encoding"))
            })?;
            if next == decoded {
                break;
            }
            decoded = next;
        }
        if decoded.as_bytes().contains(&b'%') {
            return Err(CoreError::invalid(format!(
                "{label} contains excessively nested path encoding"
            )));
        }
        if looks_like_secret(&decoded) {
            return Err(CoreError::invalid(format!(
                "{label} contains credential-like path material"
            )));
        }
    }
    Ok(())
}

fn percent_decode_path_segment(segment: &str) -> Option<String> {
    let bytes = segment.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0_usize;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let high = *bytes.get(index + 1)?;
            let low = *bytes.get(index + 2)?;
            decoded.push(hex_nibble(high)?.checked_mul(16)? + hex_nibble(low)?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

const fn hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn validate_opaque_credential_reference(reference: &str) -> CoreResult<()> {
    let lower = reference.to_ascii_lowercase();
    if reference.is_empty()
        || reference.len() > 256
        || reference.trim() != reference
        || reference.chars().any(char::is_control)
        || reference.contains("://")
        || reference.contains('?')
        || reference.contains('#')
        || reference.contains('=')
        || lower.contains("secret")
        || lower.contains("password")
        || lower.contains("api-key")
        || lower.contains("apikey")
        || lower.contains("token")
        || looks_like_secret(reference)
    {
        return Err(CoreError::invalid(
            "discovery credential_ref must be an opaque broker reference, not credential material",
        ));
    }
    Ok(())
}

fn encode_redacted_json(value: &Value, label: &str) -> CoreResult<String> {
    if !value.is_object() {
        return Err(CoreError::invalid(format!("{label} must be a JSON object")));
    }
    validate_redacted_value(value)?;
    let json = serde_json::to_string(value)
        .map_err(|_| CoreError::internal(format!("cannot encode {label}")))?;
    if json.len() > MAX_DISCOVERY_JSON_BYTES || json.chars().count() > MAX_DISCOVERY_JSON_CHARS {
        return Err(CoreError::invalid(format!(
            "{label} exceeds the persistence bound"
        )));
    }
    Ok(json)
}

fn decode_redacted_json(json: &str, label: &str) -> CoreResult<Value> {
    if json.len() > MAX_DISCOVERY_JSON_BYTES || json.chars().count() > MAX_DISCOVERY_JSON_CHARS {
        return Err(corrupted(format!("{label} exceeds its storage bound")));
    }
    let value =
        serde_json::from_str(json).map_err(|_| corrupted(format!("{label} is invalid JSON")))?;
    validate_redacted_value(&value)
        .map_err(|_| corrupted(format!("{label} contains forbidden data")))?;
    Ok(value)
}

fn validate_redacted_value(value: &Value) -> CoreResult<()> {
    let mut nodes = 0_usize;
    validate_redacted_value_inner(value, 0, &mut nodes)
}

fn validate_redacted_value_inner(value: &Value, depth: usize, nodes: &mut usize) -> CoreResult<()> {
    *nodes = nodes.saturating_add(1);
    if depth > MAX_DISCOVERY_JSON_DEPTH || *nodes > MAX_DISCOVERY_JSON_NODES {
        return Err(CoreError::invalid(
            "redacted discovery JSON exceeds structural bounds",
        ));
    }
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                let normalized = key
                    .bytes()
                    .filter(u8::is_ascii_alphanumeric)
                    .map(|byte| byte.to_ascii_lowercase())
                    .collect::<Vec<_>>();
                if matches!(
                    normalized.as_slice(),
                    b"apikey"
                        | b"apikeyvalue"
                        | b"authorization"
                        | b"authorizationvalue"
                        | b"proxyauthorization"
                        | b"cookie"
                        | b"setcookie"
                        | b"password"
                        | b"secret"
                        | b"clientsecret"
                        | b"clientsecretvalue"
                        | b"token"
                        | b"bearertoken"
                        | b"idtoken"
                        | b"sessiontoken"
                        | b"credential"
                        | b"credentials"
                        | b"accesstoken"
                        | b"refreshtoken"
                        | b"credentialvalue"
                        | b"rawcredential"
                        | b"requestheaders"
                        | b"responseheaders"
                        | b"headers"
                        | b"documentbody"
                        | b"rawdocument"
                        | b"rawbody"
                        | b"rawrequest"
                        | b"rawresponse"
                        | b"rawcurl"
                        | b"pastedcurl"
                ) {
                    return Err(CoreError::invalid(
                        "redacted discovery JSON contains a forbidden sensitive field",
                    ));
                }
                if normalized.as_slice() == b"sourceurl"
                    && let Some(source_url) = child.as_str()
                {
                    validate_persistable_discovery_url(source_url, "source_url")?;
                }
                validate_redacted_value_inner(child, depth + 1, nodes)?;
            }
        }
        Value::Array(values) => {
            for child in values {
                validate_redacted_value_inner(child, depth + 1, nodes)?;
            }
        }
        Value::String(value) => {
            if value.chars().count() > MAX_DISCOVERY_JSON_CHARS {
                return Err(CoreError::invalid(
                    "redacted discovery JSON contains an oversized string",
                ));
            }
            if looks_like_secret(value) {
                return Err(CoreError::invalid(
                    "redacted discovery JSON contains credential-like material",
                ));
            }
            if value.contains("://")
                && let Ok(url) = url::Url::parse(value)
                && (!url.username().is_empty() || url.password().is_some())
            {
                return Err(CoreError::invalid(
                    "redacted discovery JSON contains URL user information",
                ));
            }
        }
        _ => {}
    }
    Ok(())
}

fn looks_like_secret(value: &str) -> bool {
    const SECRET_PREFIXES: [&str; 10] = [
        "sk-proj-",
        "sk-ant-",
        "sk-or-",
        "sk-",
        "AIza",
        "xoxb-",
        "xoxp-",
        "ghp_",
        "github_pat_",
        "AKIA",
    ];
    let trimmed = value.trim();
    let lower = trimmed.to_ascii_lowercase();
    if lower.starts_with("bearer ")
        || lower.starts_with("basic ")
        || lower.contains("api_key=")
        || lower.contains("apikey=")
        || lower.contains("access_token=")
        || lower.contains("secret=")
        || lower.contains("password=")
        || lower.contains("-----begin private key-----")
        || lower.contains("-----begin rsa private key-----")
        || lower.contains("sk-proj-")
        || lower.contains("sk-ant-")
        || lower.contains("sk-or-")
        || lower.contains("github_pat_")
    {
        return true;
    }
    if SECRET_PREFIXES
        .iter()
        .any(|prefix| trimmed.starts_with(prefix))
    {
        return true;
    }
    let jwt_parts = trimmed.split('.').collect::<Vec<_>>();
    jwt_parts.len() == 3
        && jwt_parts[0].starts_with("eyJ")
        && jwt_parts[1].starts_with("eyJ")
        && jwt_parts.iter().all(|part| {
            part.len() >= 8
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
        })
}

fn encode_json_result(value: Result<Value, serde_json::Error>, label: &str) -> CoreResult<String> {
    let value = value.map_err(|_| CoreError::internal(format!("cannot encode {label}")))?;
    validate_redacted_value(&value)?;
    let json = serde_json::to_string(&value)
        .map_err(|_| CoreError::internal(format!("cannot encode {label}")))?;
    if json.len() > MAX_DISCOVERY_JSON_BYTES || json.chars().count() > MAX_DISCOVERY_JSON_CHARS {
        return Err(CoreError::invalid(format!(
            "{label} exceeds the persistence bound"
        )));
    }
    Ok(json)
}

fn encode_approval_grant(grant: &DiscoveryApprovalGrant) -> CoreResult<String> {
    let json = serde_json::to_string(grant)
        .map_err(|_| CoreError::internal("cannot encode discovery approval grant"))?;
    let value = serde_json::from_str(&json)
        .map_err(|_| CoreError::internal("cannot inspect discovery approval grant"))?;
    validate_redacted_value(&value)?;
    if json.len() > MAX_DISCOVERY_JSON_BYTES || json.chars().count() > MAX_DISCOVERY_JSON_CHARS {
        return Err(CoreError::invalid(
            "discovery approval grant exceeds the persistence bound",
        ));
    }
    Ok(json)
}

fn encode_commit_plan_json(plan: &DiscoveryCommitPlan) -> CoreResult<String> {
    plan.validate().map_err(contract_error)?;
    if let Some(reference) = &plan.credential_ref {
        validate_opaque_credential_reference(reference.as_str())?;
    }
    let json = serde_json::to_string(plan)
        .map_err(|_| CoreError::internal("cannot encode discovery commit plan"))?;
    if json.len() > MAX_DISCOVERY_JSON_BYTES || json.chars().count() > MAX_DISCOVERY_JSON_CHARS {
        return Err(CoreError::invalid(
            "discovery commit plan exceeds the persistence bound",
        ));
    }
    Ok(json)
}

fn candidate_kind(candidate: &DiscoveryCandidate) -> &'static str {
    match candidate.summary {
        lorepia_domain::discovery::DiscoveryCandidateSummary::ProviderTemplate { .. } => {
            "provider_template"
        }
        lorepia_domain::discovery::DiscoveryCandidateSummary::ApiOrigin { .. } => "api_origin",
        lorepia_domain::discovery::DiscoveryCandidateSummary::OfficialDocument { .. } => {
            "official_document"
        }
        lorepia_domain::discovery::DiscoveryCandidateSummary::ModelRoute { .. } => "model_route",
        lorepia_domain::discovery::DiscoveryCandidateSummary::ManifestDraft { .. } => {
            "manifest_draft"
        }
    }
}

fn validate_candidate_evidence_references(
    transaction: &Transaction<'_>,
    candidate: &StoredDiscoveryCandidate,
) -> CoreResult<()> {
    let mut unique = BTreeSet::new();
    for evidence_id in &candidate.candidate.evidence_ids {
        if !unique.insert(evidence_id.as_str()) {
            return Err(CoreError::invalid(
                "discovery candidate evidence references must be unique",
            ));
        }
        let belongs = transaction
            .query_row(
                "SELECT EXISTS(
                     SELECT 1
                     FROM provider_discovery_evidence
                     WHERE id = ?1 AND session_id = ?2
                 )",
                params![
                    evidence_id.as_str(),
                    candidate.candidate.session_id.as_str()
                ],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if !belongs {
            return Err(CoreError::invalid(
                "candidate evidence must exist in the same discovery session",
            ));
        }
    }
    Ok(())
}

fn validate_session_evidence_ids<'a>(
    connection: &Connection,
    session_id: &DiscoverySessionId,
    evidence_ids: impl IntoIterator<Item = &'a EvidenceId>,
    label: &str,
) -> CoreResult<()> {
    let mut unique = BTreeSet::new();
    for evidence_id in evidence_ids {
        if !unique.insert(evidence_id.as_str()) {
            return Err(CoreError::invalid(format!(
                "{label} evidence references must be unique"
            )));
        }
        let belongs = connection
            .query_row(
                "SELECT EXISTS(
                     SELECT 1
                     FROM provider_discovery_evidence
                     WHERE id = ?1 AND session_id = ?2
                 )",
                params![evidence_id.as_str(), session_id.as_str()],
                |row| row.get::<_, bool>(0),
            )
            .map_err(database_error)?;
        if !belongs {
            return Err(CoreError::invalid(format!(
                "{label} evidence must exist in the same discovery session"
            )));
        }
    }
    Ok(())
}

fn validate_review_evidence_references(
    connection: &Connection,
    session_id: &DiscoverySessionId,
    review: &DiscoveryReviewDiff,
) -> CoreResult<()> {
    for change in &review.changes {
        validate_session_evidence_ids(
            connection,
            session_id,
            &change.evidence_ids,
            "discovery review change",
        )?;
    }
    Ok(())
}

fn validate_approval_references(
    transaction: &Transaction<'_>,
    approval: &DiscoveryApprovalRecord,
) -> CoreResult<()> {
    match &approval.grant {
        DiscoveryApprovalGrant::AssistantConsent {
            assistant_route_id,
            evidence_ids,
            ..
        } => {
            validate_session_evidence_ids(
                transaction,
                &approval.session_id,
                evidence_ids,
                "assistant consent",
            )?;
            let route_exists = transaction
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM provider_models WHERE id = ?1)",
                    [assistant_route_id.as_str()],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(database_error)?;
            if !route_exists {
                return Err(CoreError::invalid(
                    "assistant consent route must exist before approval",
                ));
            }
        }
        DiscoveryApprovalGrant::CapabilityProbe {
            model_route_ids,
            budget,
        } => {
            let state = transaction
                .query_row(
                    "SELECT state FROM provider_discovery_sessions WHERE id = ?1",
                    [approval.session_id.as_str()],
                    |row| row.get::<_, String>(0),
                )
                .map_err(database_error)?;
            if state != "awaiting_probe_consent" {
                return Err(CoreError::invalid(
                    "capability probe approval requires the consent state",
                ));
            }
            validate_capability_probe_grant(
                transaction,
                &approval.session_id,
                model_route_ids,
                *budget,
            )?;
        }
        _ => {}
    }
    Ok(())
}

fn validate_capability_probe_grant(
    connection: &Connection,
    session_id: &DiscoverySessionId,
    model_route_ids: &[lorepia_domain::ModelRouteId],
    budget: DiscoveryProbeBudget,
) -> CoreResult<()> {
    let draft_json = connection
        .query_row(
            "SELECT draft_json
             FROM provider_discovery_sessions
             WHERE id = ?1",
            [session_id.as_str()],
            |row| row.get::<_, Option<String>>(0),
        )
        .optional()
        .map_err(database_error)?
        .flatten()
        .ok_or_else(|| CoreError::invalid("capability probe proposal has no durable draft"))?;
    let draft = decode_redacted_json(&draft_json, "stored discovery draft")?;
    let probe_routes = draft
        .get("probe_route_ids")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::invalid("durable probe route proposal is missing"))?;
    let mut expected = probe_routes
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| CoreError::invalid("durable probe route identifier is invalid"))
        })
        .collect::<CoreResult<Vec<_>>>()?;
    expected.sort();
    expected.dedup();
    if expected.is_empty() {
        return Err(CoreError::invalid(
            "durable probe route proposal must not be empty",
        ));
    }
    let graph_route_ids = draft
        .get("routes")
        .and_then(Value::as_array)
        .ok_or_else(|| CoreError::invalid("durable discovery graph routes are missing"))?
        .iter()
        .map(|route| {
            route
                .get("id")
                .and_then(Value::as_str)
                .ok_or_else(|| CoreError::invalid("durable discovery route is invalid"))
        })
        .collect::<CoreResult<BTreeSet<_>>>()?;
    if expected
        .iter()
        .any(|route_id| !graph_route_ids.contains(route_id.as_str()))
    {
        return Err(CoreError::invalid(
            "durable probe proposal references a route outside its graph",
        ));
    }
    let actual = model_route_ids
        .iter()
        .map(|route_id| route_id.as_str().to_owned())
        .collect::<Vec<_>>();
    let expected_budget =
        DiscoveryProbeBudget::standard_for_route_count(expected.len()).map_err(contract_error)?;
    if actual != expected || budget != expected_budget {
        return Err(CoreError::invalid(
            "capability probe approval differs from its durable proposal",
        ));
    }
    Ok(())
}

fn current_session_revision(connection: &Connection, session_id: &str) -> CoreResult<u64> {
    connection
        .query_row(
            "SELECT revision FROM provider_discovery_sessions WHERE id = ?1",
            [session_id],
            |row| row.get(0),
        )
        .optional()
        .map_err(database_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "provider discovery session was not found",
                false,
            )
        })
}

fn require_session(connection: &Connection, session_id: &str) -> CoreResult<()> {
    current_session_revision(connection, session_id).map(|_| ())
}

#[allow(clippy::too_many_arguments)]
fn append_audit(
    transaction: &Transaction<'_>,
    session_id: &str,
    revision: u64,
    kind: &str,
    action_id: Option<&str>,
    subject_id: Option<&str>,
    summary_key: &str,
    created_at: DateTime<Utc>,
) -> CoreResult<()> {
    let sequence = transaction
        .query_row(
            "SELECT COALESCE(MAX(audit_sequence), 0) + 1
             FROM provider_discovery_audit_log
             WHERE session_id = ?1",
            [session_id],
            |row| row.get::<_, u64>(0),
        )
        .map_err(database_error)?;
    transaction
        .execute(
            "INSERT INTO provider_discovery_audit_log (
                 session_id, audit_sequence, session_revision, audit_kind,
                 action_id, subject_id, summary_key, created_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                session_id,
                sequence,
                revision,
                kind,
                action_id,
                subject_id,
                summary_key,
                created_at.to_rfc3339(),
            ],
        )
        .map_err(database_error)?;
    Ok(())
}

fn parse_timestamp(value: &str, label: &str) -> CoreResult<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|_| corrupted(format!("stored {label} is invalid")))
}

fn parse_discovery_state(value: &str) -> CoreResult<DiscoveryState> {
    serde_json::from_value(Value::String(value.to_owned()))
        .map_err(|_| corrupted("stored discovery state is invalid"))
}

fn parse_operation_kind(value: &str) -> CoreResult<DiscoveryOperationKind> {
    serde_json::from_value(Value::String(value.to_owned()))
        .map_err(|_| corrupted("stored discovery operation kind is invalid"))
}

fn parse_side_effect_class(value: &str) -> CoreResult<DiscoverySideEffectClass> {
    serde_json::from_value(Value::String(value.to_owned()))
        .map_err(|_| corrupted("stored discovery side-effect class is invalid"))
}

fn parse_approval_decision(value: &str) -> CoreResult<DiscoveryApprovalDecision> {
    serde_json::from_value(Value::String(value.to_owned()))
        .map_err(|_| corrupted("stored discovery approval decision is invalid"))
}

fn json_enum_wire(value: Value, label: &str) -> CoreResult<String> {
    value
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| CoreError::internal(format!("{label} did not serialize as a string")))
}

fn enum_wire_result(value: Result<Value, serde_json::Error>, label: &str) -> CoreResult<String> {
    json_enum_wire(
        value.map_err(|_| CoreError::internal(format!("cannot encode {label}")))?,
        label,
    )
}

fn canonical_json_result(
    value: Result<Value, serde_json::Error>,
    label: &str,
) -> CoreResult<String> {
    let value = value.map_err(|_| CoreError::internal(format!("cannot encode {label}")))?;
    validate_redacted_value(&value)?;
    canonical_typed_value(value, label)
}

fn canonical_typed_json_result(
    value: Result<Value, serde_json::Error>,
    label: &str,
) -> CoreResult<String> {
    let value = value.map_err(|_| CoreError::internal(format!("cannot encode {label}")))?;
    canonical_typed_value(value, label)
}

fn canonical_typed_value(value: Value, label: &str) -> CoreResult<String> {
    let mut output = String::new();
    write_canonical_json(&value, &mut output)?;
    if output.len() > MAX_DISCOVERY_JSON_BYTES || output.chars().count() > MAX_DISCOVERY_JSON_CHARS
    {
        return Err(CoreError::invalid(format!(
            "{label} exceeds the persistence bound"
        )));
    }
    Ok(output)
}

fn write_canonical_json(value: &Value, output: &mut String) -> CoreResult<()> {
    match value {
        Value::Null => output.push_str("null"),
        Value::Bool(value) => output.push_str(if *value { "true" } else { "false" }),
        Value::Number(value) => {
            if value.as_f64().is_some_and(|value| value == 0.0) {
                output.push('0');
            } else {
                output.push_str(&value.to_string());
            }
        }
        Value::String(value) => output.push_str(
            &serde_json::to_string(value)
                .map_err(|_| CoreError::internal("cannot encode canonical JSON string"))?,
        ),
        Value::Array(values) => {
            output.push('[');
            for (index, value) in values.iter().enumerate() {
                if index != 0 {
                    output.push(',');
                }
                write_canonical_json(value, output)?;
            }
            output.push(']');
        }
        Value::Object(values) => {
            output.push('{');
            let mut keys = values.keys().collect::<Vec<_>>();
            keys.sort_unstable();
            for (index, key) in keys.into_iter().enumerate() {
                if index != 0 {
                    output.push(',');
                }
                output.push_str(
                    &serde_json::to_string(key)
                        .map_err(|_| CoreError::internal("cannot encode canonical JSON key"))?,
                );
                output.push(':');
                write_canonical_json(&values[key], output)?;
            }
            output.push('}');
        }
    }
    Ok(())
}

fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

fn contract_error(error: DiscoveryContractError) -> CoreError {
    CoreError::invalid(format!("invalid provider discovery contract: {error}"))
}

fn database_error(error: rusqlite::Error) -> CoreError {
    CoreError::new(
        CoreErrorCode::StorageUnavailable,
        format!("SQLite discovery operation failed: {error}"),
        true,
    )
}

fn discovery_error(error: DiscoveryStorageError) -> CoreError {
    match error {
        DiscoveryStorageError::Database(error) => database_error(error),
        DiscoveryStorageError::SessionNotFound(_) => CoreError::new(
            CoreErrorCode::NotFound,
            "provider discovery session was not found",
            false,
        ),
        DiscoveryStorageError::RevisionConflict { expected, actual } => CoreError::invalid(
            format!("discovery revision conflict: expected {expected}, current {actual}"),
        ),
        DiscoveryStorageError::IdempotencyConflict { .. } => {
            CoreError::invalid("discovery action identifier was reused with a different request")
        }
        DiscoveryStorageError::InvalidTransition(reason) => {
            CoreError::invalid(format!("invalid durable discovery transition: {reason}"))
        }
    }
}

fn corrupted(message: impl Into<String>) -> CoreError {
    CoreError::new(CoreErrorCode::StorageCorrupted, message, false)
}

#[cfg(test)]
mod tests {
    use chrono::{TimeZone, Utc};
    use lorepia_domain::{
        CanonicalOrigin, CoreErrorCode, CredentialRef, DiscoverySessionId, EvidenceId, HttpUrl,
        ModelRouteId, ProviderConnectionId, ProviderProfile, ProviderTemplateId,
        discovery::{
            DiscoveryActionEnvelope, DiscoveryActionId, DiscoveryApprovalBinding,
            DiscoveryApprovalGrant, DiscoveryApprovalId, DiscoveryCommitAttemptId,
            DiscoveryCommitPlan, DiscoveryCompensationKind, DiscoveryCompensationStatus,
            DiscoveryCompensationStep, DiscoveryCompensationTarget, DiscoveryFailure,
            DiscoveryOperationId, DiscoveryPreviousSelection, DiscoveryState,
            ProviderDiscoveryAction, ProviderDiscoveryConnectionOptions, ProviderDiscoverySession,
            SanitizedDiscoveryInput,
        },
    };
    use serde_json::{Value, json};
    use tempfile::tempdir;

    use super::{
        DiscoveryCompletedOperationWrite, DiscoveryEvidenceKind, DiscoveryEvidenceRecord,
        DiscoveryJsonUpdate, DiscoveryTransitionWrite, PersistDiscoveryTransition, Storage,
        sha256_hex,
    };

    fn now() -> chrono::DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 31, 12, 0, 0)
            .single()
            .expect("valid test time")
    }

    fn draft_session(id: &str) -> ProviderDiscoverySession {
        ProviderDiscoverySession::new(
            DiscoverySessionId::from(id),
            SanitizedDiscoveryInput {
                connection_id: ProviderConnectionId::from(format!("{id}-connection")),
                display_name: "Test provider".to_owned(),
                site_url: HttpUrl::parse("https://provider.example/").expect("site URL"),
                docs_url: Some(HttpUrl::parse("https://provider.example/docs").expect("docs URL")),
                credential_ref: None,
                preferred_assistant: None,
                connection_options: ProviderDiscoveryConnectionOptions::default(),
                supplied_evidence_ids: Vec::new(),
            },
        )
        .expect("draft discovery session")
    }

    fn initial_working_draft(source: Value) -> Value {
        json!({
            "schema_version": 1,
            "source": source,
            "deterministic": null,
            "evidence_ids": [],
            "extra_evidence_ids": [],
            "selected_candidate_id": null,
            "template": null,
            "connection": null,
            "routes": [],
            "observations": [],
            "presets": [],
            "credential_approval_id": null,
            "probe_route_ids": [],
            "probe_failure_count": 0,
            "assistant": null
        })
    }

    fn initial_sanitized_curl_output() -> Value {
        let extracted = json!({
            "method": "POST",
            "origin": "https://provider.example",
            "source_path_sha256": "1".repeat(64),
            "source_path_is_root": false,
            "query_parameter_names": [],
            "header_names": [],
            "auth_hints": [],
            "body_json_shape": null,
            "stream_hint": null,
            "api_family_candidates": [],
            "trust": "sanitized_curl_structure"
        });
        let content_sha256 =
            sha256_hex(&serde_json::to_vec(&extracted).expect("sanitized cURL JSON"));
        json!({
            "schema_version": 1,
            "selected_template": null,
            "evidence": [{
                "kind": "sanitized_curl_request",
                "source_origin": "https://provider.example",
                "content_sha256": content_sha256,
                "extracted_json": extracted,
                "redaction_version": 1
            }],
            "family_candidates": [],
            "manifest_candidates": [],
            "connection_hints": [],
            "fetch_issues": [],
            "fetch_stopped_by_budget": false
        })
    }

    fn apply(
        session: &ProviderDiscoverySession,
        action: ProviderDiscoveryAction,
        hash_byte: char,
    ) -> lorepia_domain::discovery::DiscoveryTransition {
        session
            .apply(&DiscoveryActionEnvelope {
                id: DiscoveryActionId::new(),
                expected_revision: session.revision,
                request_sha256: std::iter::repeat_n(hash_byte, 64).collect(),
                action,
            })
            .expect("valid discovery action")
    }

    fn write(
        transition: lorepia_domain::discovery::DiscoveryTransition,
        new_operation_id: Option<DiscoveryOperationId>,
        completed_operation: Option<DiscoveryCompletedOperationWrite>,
    ) -> DiscoveryTransitionWrite {
        DiscoveryTransitionWrite {
            transition,
            draft: DiscoveryJsonUpdate::Preserve,
            review: DiscoveryJsonUpdate::Preserve,
            new_evidence: Vec::new(),
            new_candidates: Vec::new(),
            approval: None,
            new_operation_id,
            completed_operation,
            prepared_commit: None,
            provider_graph: None,
            occurred_at: now(),
        }
    }

    #[test]
    fn cancel_reopen_automatically_interrupts_and_finishes_cancellation() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-cancel-reopen");
        let begin = apply(&draft, ProviderDiscoveryAction::Begin, 'a');
        let operation_id = DiscoveryOperationId::parse("operation-resolve").expect("operation id");
        storage
            .begin_discovery_session(&draft, &write(begin, Some(operation_id.clone()), None))
            .expect("persist begin");
        assert!(
            storage
                .mark_discovery_operation_started(&operation_id, now())
                .expect("mark operation started")
        );

        let resolving = storage
            .get_discovery_session(&draft.id)
            .expect("load resolving session");
        let cancel = apply(&resolving.session, ProviderDiscoveryAction::Cancel, 'b');
        storage
            .persist_discovery_transition(&write(cancel, None, None))
            .expect("persist cancellation request");
        drop(storage);

        let reopened = Storage::open(root.path()).expect("reopen storage");
        let terminal = reopened
            .get_discovery_session(&draft.id)
            .expect("hydrate automatically recovered session");
        assert_eq!(
            terminal.session.state,
            lorepia_domain::discovery::DiscoveryState::Cancelled
        );
        assert!(!terminal.session.cancellation_pending);
        assert!(terminal.active_operation_id.is_none());
        assert!(
            reopened
                .get_current_discovery_operation(&draft.id)
                .expect("query current operation")
                .is_none()
        );
    }

    #[test]
    fn unfinished_discovery_blocks_provider_archive_until_cancelled() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-archive-guard");
        let connection_id = draft.input.connection_id.clone();
        let profile = ProviderProfile {
            id: connection_id.as_str().to_owned(),
            display_name: "Discovery archive guard".to_owned(),
            base_url: "https://provider.example/v1".to_owned(),
            model: "synthetic".to_owned(),
            timeout_seconds: 30,
        };
        storage
            .save_provider_profile(&profile)
            .expect("save provider");
        let begin = apply(&draft, ProviderDiscoveryAction::Begin, 'f');
        let operation_id =
            DiscoveryOperationId::parse("operation-archive-guard").expect("operation id");
        storage
            .begin_discovery_session(&draft, &write(begin, Some(operation_id), None))
            .expect("persist begin");

        let error = storage
            .delete_provider_profile(&profile.id)
            .expect_err("unfinished discovery must block provider archive");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert!(error.recoverable);
        assert_eq!(
            error.message,
            "provider connection cannot be archived while provider discovery is unfinished"
        );
        assert_eq!(
            storage
                .get_provider_profile(&profile.id)
                .expect("provider remains active after rejected archive"),
            profile
        );

        let resolving = storage
            .get_discovery_session(&draft.id)
            .expect("load resolving session");
        let cancel = apply(&resolving.session, ProviderDiscoveryAction::Cancel, '0');
        storage
            .persist_discovery_transition(&write(cancel, None, None))
            .expect("persist cancellation request");
        drop(storage);

        let reopened = Storage::open(root.path()).expect("reopen storage");
        assert_eq!(
            reopened
                .get_discovery_session(&draft.id)
                .expect("load cancelled discovery")
                .session
                .state,
            DiscoveryState::Cancelled
        );
        reopened
            .delete_provider_profile(&profile.id)
            .expect("terminal discovery permits provider archive");
        assert_eq!(
            reopened
                .get_provider_connection(&connection_id)
                .expect_err("archived provider is hidden")
                .code,
            CoreErrorCode::NotFound
        );
        assert_eq!(
            reopened
                .get_discovery_session(&draft.id)
                .expect("terminal discovery history remains readable")
                .session
                .state,
            DiscoveryState::Cancelled
        );
    }

    #[test]
    fn nonterminal_discovery_committed_reference_blocks_provider_archive() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let connection_id = ProviderConnectionId::from("committed-archive-guard");
        storage
            .save_provider_profile(&ProviderProfile {
                id: connection_id.as_str().to_owned(),
                display_name: "Committed discovery archive guard".to_owned(),
                base_url: "https://provider.example/v1".to_owned(),
                model: "synthetic".to_owned(),
                timeout_seconds: 30,
            })
            .expect("save provider");
        let unrelated = draft_session("session-committed-reference");
        let input_json =
            serde_json::to_string(&unrelated.input).expect("encode sanitized discovery input");
        storage
            .connection()
            .expect("database connection")
            .execute(
                "INSERT INTO provider_discovery_sessions (
                     id, state, sanitized_input_json, unknown_operation,
                     committed_connection_id, created_at, updated_at
                 ) VALUES (
                     ?1, 'unknown_outcome', ?2, 'atomic_commit', ?3, ?4, ?4
                 )",
                rusqlite::params![
                    unrelated.id.as_str(),
                    input_json,
                    connection_id.as_str(),
                    now().to_rfc3339(),
                ],
            )
            .expect("seed nonterminal committed discovery reference");
        let snapshot = storage
            .get_discovery_session(&unrelated.id)
            .expect("hydrate nonterminal committed discovery");
        assert_eq!(snapshot.session.state, DiscoveryState::UnknownOutcome);
        assert_eq!(
            snapshot.session.committed_connection_id.as_ref(),
            Some(&connection_id)
        );
        assert_ne!(snapshot.session.input.connection_id, connection_id);

        let error = storage
            .delete_provider_connection(&connection_id)
            .expect_err("committed nonterminal discovery must block provider archive");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert!(error.recoverable);
        assert_eq!(
            error.message,
            "provider connection cannot be archived while provider discovery is unfinished"
        );
        assert!(
            storage.get_provider_connection(&connection_id).is_ok(),
            "provider remains active after rejected archive"
        );
    }

    #[test]
    fn every_current_discovery_state_obeys_archive_terminal_boundary() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let mut nonterminal_count = 0;

        for state in DiscoveryState::ALL {
            let serialized_state = serde_json::to_value(state).expect("serialize discovery state");
            let state_label = serialized_state
                .as_str()
                .expect("discovery state serializes as text");
            let session_id = format!("archive-discovery-{state_label}");
            let draft = draft_session(&session_id);
            let connection_id = draft.input.connection_id.clone();
            storage
                .save_provider_profile(&ProviderProfile {
                    id: connection_id.as_str().to_owned(),
                    display_name: format!("Archive boundary {state_label}"),
                    base_url: "https://provider.example/v1".to_owned(),
                    model: "boundary-model".to_owned(),
                    timeout_seconds: 30,
                })
                .expect("seed provider");
            let input_json =
                serde_json::to_string(&draft.input).expect("encode sanitized discovery input");
            let requires_commit_plan = matches!(
                state,
                DiscoveryState::Committing | DiscoveryState::Compensating
            );
            let recovery_json = (state == DiscoveryState::Interrupted).then_some("{}");
            let unknown_operation =
                (state == DiscoveryState::UnknownOutcome).then_some("atomic_commit");
            let commit_plan_sha256 = requires_commit_plan.then(|| "0".repeat(64));
            let commit_attempt_id = requires_commit_plan.then(|| format!("attempt-{state_label}"));
            let committed_connection_id =
                (state == DiscoveryState::Ready).then_some(connection_id.as_str());
            let failure_json = (state == DiscoveryState::Failed).then(|| {
                serde_json::json!({
                    "code": "synthetic_failure",
                    "message_key": "discovery.failed",
                    "recoverable": true,
                })
                .to_string()
            });
            storage
                .connection()
                .expect("database connection")
                .execute(
                    "INSERT INTO provider_discovery_sessions (
                         id, state, sanitized_input_json, error_json, recovery_json,
                         unknown_operation, commit_plan_sha256, commit_attempt_id,
                         committed_connection_id, created_at, updated_at
                     ) VALUES (
                         ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10
                     )",
                    rusqlite::params![
                        draft.id.as_str(),
                        state_label,
                        input_json,
                        failure_json,
                        recovery_json,
                        unknown_operation,
                        commit_plan_sha256,
                        commit_attempt_id,
                        committed_connection_id,
                        now().to_rfc3339(),
                    ],
                )
                .expect("seed exact discovery state");

            let archive = storage.delete_provider_connection(&connection_id);
            if state.is_terminal() {
                archive.expect("terminal discovery history permits provider archive");
                assert_eq!(
                    storage
                        .get_provider_connection(&connection_id)
                        .expect_err("terminal state permits hidden archive")
                        .code,
                    CoreErrorCode::NotFound
                );
            } else {
                nonterminal_count += 1;
                let error = archive.expect_err("nonterminal discovery must block archive");
                assert_eq!(error.code, CoreErrorCode::InvalidInput);
                assert!(error.recoverable);
                assert_eq!(
                    error.message,
                    "provider connection cannot be archived while provider discovery is unfinished"
                );
                assert!(
                    storage.get_provider_connection(&connection_id).is_ok(),
                    "rejected archive keeps provider active for {state_label}"
                );
            }
        }

        assert_eq!(
            nonterminal_count, 19,
            "the test fixture must cover every current nonterminal discovery state"
        );
    }

    #[test]
    fn startup_recovery_records_interruption_without_replaying_effect() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-recovery");
        let begin = apply(&draft, ProviderDiscoveryAction::Begin, 'd');
        let operation_id = DiscoveryOperationId::parse("operation-recovery").expect("operation id");
        storage
            .begin_discovery_session(&draft, &write(begin, Some(operation_id.clone()), None))
            .expect("persist begin");
        assert!(
            storage
                .mark_discovery_operation_started(&operation_id, now())
                .expect("mark operation started")
        );

        drop(storage);
        let reopened = Storage::open(root.path()).expect("reopen and recover storage");
        let recovered = reopened
            .get_discovery_session(&draft.id)
            .expect("load recovered discovery session");
        assert_eq!(
            recovered.session.state,
            lorepia_domain::discovery::DiscoveryState::Interrupted
        );
        assert!(
            reopened
                .get_current_discovery_operation(&draft.id)
                .expect("query active operation")
                .is_none()
        );
        let operation_status = reopened
            .connection()
            .expect("database connection")
            .query_row(
                "SELECT status FROM provider_discovery_operations WHERE id = ?1",
                [operation_id.as_str()],
                |row| row.get::<_, String>(0),
            )
            .expect("recovered operation status");
        assert_eq!(operation_status, "interrupted");
    }

    #[test]
    fn deferred_open_leaves_recovery_untouched_until_core_classification() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-deferred-recovery");
        let begin = apply(&draft, ProviderDiscoveryAction::Begin, 'e');
        let operation_id =
            DiscoveryOperationId::parse("operation-deferred-recovery").expect("operation id");
        storage
            .begin_discovery_session(&draft, &write(begin, Some(operation_id.clone()), None))
            .expect("persist begin");
        assert!(
            storage
                .mark_discovery_operation_started(&operation_id, now())
                .expect("mark operation started")
        );
        drop(storage);

        let deferred = Storage::open_with_deferred_discovery_recovery(root.path())
            .expect("open storage with deferred discovery recovery");
        let untouched = deferred
            .get_discovery_session(&draft.id)
            .expect("load unrecovered session");
        assert_eq!(
            untouched.session.state,
            lorepia_domain::discovery::DiscoveryState::ResolvingKnownProvider
        );
        assert_eq!(untouched.active_operation_id.as_ref(), Some(&operation_id));
        assert_eq!(
            deferred
                .get_current_discovery_operation(&draft.id)
                .expect("load unrecovered operation")
                .expect("active operation")
                .status,
            super::DiscoveryOperationStatus::Started
        );

        let recovered = deferred
            .recover_unfinished_discovery_operations(now())
            .expect("apply explicit conservative recovery");
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].operation_id, operation_id);
        assert_eq!(
            deferred
                .get_discovery_session(&draft.id)
                .expect("load explicitly recovered session")
                .session
                .state,
            lorepia_domain::discovery::DiscoveryState::Interrupted
        );
    }

    #[test]
    fn recovery_exception_rejects_a_non_assistant_operation_id() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-invalid-recovery-exception");
        let begin = apply(&draft, ProviderDiscoveryAction::Begin, 'd');
        let operation_id =
            DiscoveryOperationId::parse("operation-not-assistant").expect("operation id");
        storage
            .begin_discovery_session(&draft, &write(begin, Some(operation_id.clone()), None))
            .expect("persist begin");
        let error = storage
            .recover_unfinished_discovery_operations_except(
                now(),
                &std::collections::BTreeSet::from([operation_id.clone()]),
            )
            .expect_err("a read-only operation must not bypass recovery");
        assert_eq!(error.code, CoreErrorCode::StorageCorrupted);
        let unchanged = storage
            .get_discovery_session(&draft.id)
            .expect("load unchanged discovery");
        assert_eq!(
            unchanged.session.state,
            lorepia_domain::discovery::DiscoveryState::ResolvingKnownProvider
        );
        assert_eq!(unchanged.active_operation_id.as_ref(), Some(&operation_id));
    }

    #[test]
    fn assistant_evidence_boundary_actions_complete_the_billable_operation() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-assistant-more-evidence");
        storage
            .create_discovery_session(&draft, now())
            .expect("create draft");
        let operation_id =
            DiscoveryOperationId::parse("operation-assistant-more-evidence").expect("operation id");
        let mut connection = storage.connection().expect("database connection");
        let transaction = connection.transaction().expect("transaction");
        transaction
            .execute(
                "INSERT INTO provider_discovery_operations (
                     id, session_id, operation_kind, side_effect_class, status,
                     action_id, expected_revision, request_sha256, approval_id,
                     approval_grant_sha256, started_at, finished_at, created_at, updated_at
                 ) VALUES (
                     ?1, ?2, 'build_assistant_manifest_draft', 'billable_external', 'started',
                     'action-assistant-more-evidence', 0, ?3, NULL, NULL,
                     ?4, NULL, ?4, ?4
                 )",
                rusqlite::params![
                    operation_id.as_str(),
                    draft.id.as_str(),
                    "d".repeat(64),
                    now().to_rfc3339(),
                ],
            )
            .expect("insert started assistant operation");
        transaction
            .execute(
                "UPDATE provider_discovery_sessions
                 SET state = 'building_assistant_manifest_draft',
                     revision = 1,
                     next_event_sequence = 2,
                     active_operation_id = ?2,
                     updated_at = ?3
                 WHERE id = ?1",
                rusqlite::params![draft.id.as_str(), operation_id.as_str(), now().to_rfc3339(),],
            )
            .expect("activate assistant operation");

        let mut completion = write(
            apply(&draft, ProviderDiscoveryAction::Begin, 'd'),
            None,
            Some(DiscoveryCompletedOperationWrite {
                id: operation_id,
                outcome: super::DurableOperationOutcome::Succeeded,
            }),
        );
        completion.transition.receipt.action_kind = "assistant_requested_more_evidence".to_owned();
        super::validate_completed_operation_binding(&transaction, &completion)
            .expect("more-evidence action must complete the billable operation");

        completion.transition.receipt.action_kind = "assistant_resumed_with_evidence".to_owned();
        super::validate_completed_operation_binding(&transaction, &completion)
            .expect("resumed-with-evidence action must complete the billable operation");
    }

    #[test]
    fn evidence_rejects_known_credential_markers_without_blocking_model_ids() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-evidence");
        storage
            .create_discovery_session(&draft, now())
            .expect("create draft");
        let query_url = DiscoveryEvidenceRecord {
            id: "evidence-query".into(),
            session_id: draft.id.clone(),
            kind: DiscoveryEvidenceKind::JsonDocument,
            source_url: HttpUrl::parse("https://provider.example/docs?token=secret")
                .expect("URL parser permits query"),
            content_sha256: "a".repeat(64),
            extracted_json: json!({"endpoint": "/v1/models"}),
            fetched_at: now(),
        };
        assert!(storage.save_discovery_evidence(&query_url).is_err());

        let sensitive = DiscoveryEvidenceRecord {
            id: "evidence-sensitive".into(),
            source_url: HttpUrl::parse("https://provider.example/docs").expect("source URL"),
            extracted_json: json!({"example_value": "sk-proj-must-not-persist"}),
            ..query_url
        };
        assert!(storage.save_discovery_evidence(&sensitive).is_err());
        let legitimate_model_id = "Qwen/Qwen2.5-Coder-32B-Instruct";
        let model_evidence = DiscoveryEvidenceRecord {
            id: "evidence-model-identifier".into(),
            extracted_json: json!({"model_id": legitimate_model_id}),
            ..sensitive.clone()
        };
        storage
            .save_discovery_evidence(&model_evidence)
            .expect("ordinary mixed-case model identifiers must remain persistable");
        assert!(!super::looks_like_secret(legitimate_model_id));
        assert!(!super::looks_like_secret("provider.parameter.temperature"));

        let known_secret = "sk-proj-must-not-persist-in-path";
        let secret_path = DiscoveryEvidenceRecord {
            id: "evidence-secret-path".into(),
            source_url: HttpUrl::parse(&format!("https://provider.example/docs/{known_secret}"))
                .expect("URL parser permits path material"),
            extracted_json: json!({"endpoint": "/v1/models"}),
            ..sensitive
        };
        assert!(storage.save_discovery_evidence(&secret_path).is_err());
        let mut unsafe_label = draft_session("session-secret-label");
        unsafe_label.input.display_name = known_secret.to_owned();
        assert!(
            storage
                .create_discovery_session(&unsafe_label, now())
                .is_err()
        );
        let mut unsafe_connection_id = draft_session("session-secret-connection-id");
        unsafe_connection_id.input.connection_id = ProviderConnectionId::from(known_secret);
        assert!(
            storage
                .create_discovery_session(&unsafe_connection_id, now())
                .is_err()
        );

        let mut unsafe_draft = draft_session("session-secret-ref");
        unsafe_draft.input.connection_id = ProviderConnectionId::from(known_secret);
        unsafe_draft.input.credential_ref = Some(CredentialRef(known_secret.to_owned()));
        assert!(
            storage
                .create_discovery_session(&unsafe_draft, now())
                .is_err()
        );
    }

    #[test]
    fn begin_and_action_receipt_are_idempotently_replayable() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-replay");
        let begin = apply(&draft, ProviderDiscoveryAction::Begin, 'e');
        let operation_id = DiscoveryOperationId::parse("operation-replay").expect("operation id");
        let mut begin_write = write(begin.clone(), Some(operation_id), None);
        begin_write.draft =
            DiscoveryJsonUpdate::Replace(initial_working_draft(json!({"kind": "site"})));
        begin_write.review = DiscoveryJsonUpdate::Clear;
        assert!(matches!(
            storage
                .begin_discovery_session(&draft, &begin_write)
                .expect("persist begin"),
            PersistDiscoveryTransition::Applied { .. }
        ));
        let replay = storage
            .find_discovery_action_replay(
                &draft.id,
                &begin.receipt.action_id,
                &begin.receipt.request_sha256,
                &begin.receipt.action_kind,
            )
            .expect("find replay")
            .expect("stored replay");
        assert_eq!(replay.transition, begin);
        assert_eq!(
            storage
                .get_discovery_session(&draft.id)
                .expect("load begun session")
                .draft_json,
            match &begin_write.draft {
                DiscoveryJsonUpdate::Replace(value) => Some(value.clone()),
                _ => None,
            }
        );
        assert!(matches!(
            storage
                .begin_discovery_session(&draft, &begin_write)
                .expect("replay begin"),
            PersistDiscoveryTransition::Replayed { .. }
        ));
        assert!(
            storage
                .find_discovery_action_replay(
                    &draft.id,
                    &begin_write.transition.receipt.action_id,
                    &"f".repeat(64),
                    &begin_write.transition.receipt.action_kind,
                )
                .is_err()
        );
    }

    #[test]
    fn begin_rejects_forged_commit_metadata_on_initial_or_resulting_session() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");

        let mut forged_initial = draft_session("session-forged-initial");
        forged_initial.commit_attempt_id =
            Some(DiscoveryCommitAttemptId::parse("foreign-attempt").expect("attempt id"));
        forged_initial.commit_plan_sha256 = Some("4".repeat(64));
        let begin = apply(&forged_initial, ProviderDiscoveryAction::Begin, '5');
        let error = storage
            .begin_discovery_session(
                &forged_initial,
                &write(
                    begin,
                    Some(
                        DiscoveryOperationId::parse("operation-forged-initial")
                            .expect("operation id"),
                    ),
                    None,
                ),
            )
            .expect_err("begin must reject a non-pristine initial session");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert_eq!(
            storage
                .get_discovery_session(&forged_initial.id)
                .expect_err("rejected begin must not create a session")
                .code,
            CoreErrorCode::NotFound
        );

        let pristine = draft_session("session-forged-result");
        let mut begin = apply(&pristine, ProviderDiscoveryAction::Begin, '6');
        begin.session.commit_attempt_id =
            Some(DiscoveryCommitAttemptId::parse("foreign-result-attempt").expect("attempt id"));
        begin.session.commit_plan_sha256 = Some("7".repeat(64));
        let error = storage
            .begin_discovery_session(
                &pristine,
                &write(
                    begin,
                    Some(
                        DiscoveryOperationId::parse("operation-forged-result")
                            .expect("operation id"),
                    ),
                    None,
                ),
            )
            .expect_err("begin must reject forged resulting session metadata");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert_eq!(
            storage
                .get_discovery_session(&pristine.id)
                .expect_err("rejected begin must remain atomic")
                .code,
            CoreErrorCode::NotFound
        );

        let raw_curl = draft_session("session-raw-curl-draft");
        let mut raw_curl_write = write(
            apply(&raw_curl, ProviderDiscoveryAction::Begin, '8'),
            Some(DiscoveryOperationId::parse("operation-raw-curl-draft").expect("operation id")),
            None,
        );
        raw_curl_write.draft = DiscoveryJsonUpdate::Replace(initial_working_draft(json!({
            "kind": "curl",
            "raw_curl": "curl https://provider.example/v1/models"
        })));
        raw_curl_write.review = DiscoveryJsonUpdate::Clear;
        let error = storage
            .begin_discovery_session(&raw_curl, &raw_curl_write)
            .expect_err("raw cURL command text must not enter the durable initial draft");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert_eq!(
            storage
                .get_discovery_session(&raw_curl.id)
                .expect_err("rejected raw cURL begin must remain atomic")
                .code,
            CoreErrorCode::NotFound
        );
    }

    #[test]
    fn begin_accepts_only_canonical_sanitized_curl_output() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-sanitized-curl-draft");
        let mut working_draft = initial_working_draft(json!({"kind": "curl"}));
        working_draft["deterministic"] = initial_sanitized_curl_output();
        let mut begin_write = write(
            apply(&draft, ProviderDiscoveryAction::Begin, '9'),
            Some(
                DiscoveryOperationId::parse("operation-sanitized-curl-draft")
                    .expect("operation id"),
            ),
            None,
        );
        begin_write.draft = DiscoveryJsonUpdate::Replace(working_draft);
        begin_write.review = DiscoveryJsonUpdate::Clear;
        storage
            .begin_discovery_session(&draft, &begin_write)
            .expect("persist canonical sanitized cURL output");

        let forged = draft_session("session-forged-curl-output");
        let mut forged_output = initial_sanitized_curl_output();
        forged_output["evidence"][0]["extracted_json"]["raw_curl"] =
            Value::String("curl https://provider.example/v1/models".to_owned());
        let mut forged_draft = initial_working_draft(json!({"kind": "curl"}));
        forged_draft["deterministic"] = forged_output;
        let mut forged_write = write(
            apply(&forged, ProviderDiscoveryAction::Begin, 'a'),
            Some(
                DiscoveryOperationId::parse("operation-forged-curl-output").expect("operation id"),
            ),
            None,
        );
        forged_write.draft = DiscoveryJsonUpdate::Replace(forged_draft);
        forged_write.review = DiscoveryJsonUpdate::Clear;
        let error = storage
            .begin_discovery_session(&forged, &forged_write)
            .expect_err("non-canonical cURL payload must not enter durable state");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert_eq!(
            storage
                .get_discovery_session(&forged.id)
                .expect_err("rejected cURL output must remain atomic")
                .code,
            CoreErrorCode::NotFound
        );
    }

    #[test]
    fn commit_succeeded_cannot_publish_ready_without_its_graph() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-missing-commit-graph");
        let mut forged = write(
            apply(&draft, ProviderDiscoveryAction::Begin, 'b'),
            Some(
                DiscoveryOperationId::parse("operation-missing-commit-graph")
                    .expect("operation id"),
            ),
            None,
        );
        forged.transition.receipt.action_kind = "commit_succeeded".to_owned();

        let error = storage
            .persist_discovery_transition(&forged)
            .expect_err("Ready commit bookkeeping without a graph must be rejected");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert_eq!(
            storage
                .get_discovery_session(&draft.id)
                .expect_err("rejected publication must leave no partial session")
                .code,
            CoreErrorCode::NotFound
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn prepared_keyless_commit_cancellation_enters_durable_compensation() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let mut committing = draft_session("session-keyless-commit-cancel");
        storage
            .create_discovery_session(&committing, now())
            .expect("create discovery session");

        let attempt_id =
            DiscoveryCommitAttemptId::parse("attempt-keyless-commit-cancel").expect("attempt id");
        let plan = DiscoveryCommitPlan {
            attempt_id: attempt_id.clone(),
            session_id: committing.id.clone(),
            expected_revision: 0,
            manifest_sha256: "1".repeat(64),
            graph_sha256: "2".repeat(64),
            template_id: ProviderTemplateId::from("template-keyless-commit-cancel"),
            template_version: 1,
            connection_id: committing.input.connection_id.clone(),
            model_route_ids: vec![ModelRouteId::from("route-keyless-commit-cancel")],
            credential_ref: None,
            credential_approval_id: None,
            review_sha256: "3".repeat(64),
            previous_selection: DiscoveryPreviousSelection::None,
        };
        plan.validate().expect("valid keyless commit plan");
        let plan_json = serde_json::to_string(&plan).expect("commit plan JSON");
        let plan_sha256 = sha256_hex(plan_json.as_bytes());
        let commit_operation_id =
            DiscoveryOperationId::parse("operation-keyless-atomic-commit").expect("operation id");
        let compensation_operation_id =
            DiscoveryOperationId::parse("operation-keyless-compensation").expect("operation id");
        let selection_step = DiscoveryCompensationStep {
            action_id: DiscoveryActionId::parse("action-keyless-restore-selection")
                .expect("step action id"),
            ordinal: 0,
            kind: DiscoveryCompensationKind::RestorePreviousSelection,
            target: DiscoveryCompensationTarget::RestorePreviousSelection {
                previous_selection: DiscoveryPreviousSelection::None,
            },
            status: DiscoveryCompensationStatus::Pending,
        };
        let graph_step = DiscoveryCompensationStep {
            action_id: DiscoveryActionId::parse("action-keyless-remove-graph")
                .expect("step action id"),
            ordinal: 1,
            kind: DiscoveryCompensationKind::RemoveConnectionGraph,
            target: DiscoveryCompensationTarget::RemoveConnectionGraph {
                connection_id: committing.input.connection_id.clone(),
            },
            status: DiscoveryCompensationStatus::Pending,
        };
        for step in [&selection_step, &graph_step] {
            step.validate_against(&plan)
                .expect("valid compensation step");
        }

        {
            let mut connection = storage.connection().expect("database connection");
            let transaction = connection.transaction().expect("transaction");
            transaction
                .execute(
                    "INSERT INTO provider_discovery_commit_attempts (
                         id, session_id, attempt_number, action_id, expected_revision,
                         plan_sha256, plan_json, phase, redaction_version,
                         created_at, updated_at, completed_at
                     ) VALUES (
                         ?1, ?2, 1, 'action-prepare-keyless-commit', 0,
                         ?3, ?4, 'prepared', 1, ?5, ?5, NULL
                     )",
                    rusqlite::params![
                        attempt_id.as_str(),
                        committing.id.as_str(),
                        plan_sha256,
                        plan_json,
                        now().to_rfc3339(),
                    ],
                )
                .expect("insert prepared commit attempt");
            for (id, step) in [
                ("step-keyless-restore-selection", &selection_step),
                ("step-keyless-remove-graph", &graph_step),
            ] {
                let kind =
                    serde_json::to_value(step.kind).expect("compensation kind serialization");
                transaction
                    .execute(
                        "INSERT INTO provider_discovery_compensation_steps (
                             id, commit_attempt_id, ordinal, action_id, step_kind,
                             step_json, status, attempt_count, last_failure_json,
                             redaction_version, created_at, updated_at, completed_at
                         ) VALUES (
                             ?1, ?2, ?3, ?4, ?5, ?6, 'pending', 0, NULL, 1, ?7, ?7, NULL
                         )",
                        rusqlite::params![
                            id,
                            attempt_id.as_str(),
                            step.ordinal,
                            step.action_id.as_str(),
                            kind.as_str().expect("wire compensation kind"),
                            serde_json::to_string(step).expect("compensation step JSON"),
                            now().to_rfc3339(),
                        ],
                    )
                    .expect("insert compensation step");
            }
            transaction
                .execute(
                    "INSERT INTO provider_discovery_operations (
                         id, session_id, operation_kind, side_effect_class, status,
                         action_id, expected_revision, request_sha256, approval_id,
                         approval_grant_sha256, started_at, finished_at, created_at, updated_at
                     ) VALUES (
                         ?1, ?2, 'atomic_commit', 'persistent', 'started',
                         'action-run-keyless-commit', 1, ?3, NULL, NULL,
                         ?4, NULL, ?4, ?4
                     )",
                    rusqlite::params![
                        commit_operation_id.as_str(),
                        committing.id.as_str(),
                        "4".repeat(64),
                        now().to_rfc3339(),
                    ],
                )
                .expect("insert started atomic commit operation");
            transaction
                .execute(
                    "UPDATE provider_discovery_sessions
                     SET state = 'committing',
                         revision = 1,
                         next_event_sequence = 2,
                         commit_plan_sha256 = ?2,
                         commit_attempt_id = ?3,
                         cancellation_pending = 1,
                         active_operation_id = ?4,
                         updated_at = ?5
                     WHERE id = ?1",
                    rusqlite::params![
                        committing.id.as_str(),
                        plan_sha256,
                        attempt_id.as_str(),
                        commit_operation_id.as_str(),
                        now().to_rfc3339(),
                    ],
                )
                .expect("activate keyless committing session");
            transaction.commit().expect("commit fixture");
        }

        committing.state = DiscoveryState::Committing;
        committing.revision = 1;
        committing.next_event_sequence = 2;
        committing.commit_plan_sha256 = Some(plan_sha256);
        committing.commit_attempt_id = Some(attempt_id.clone());
        committing.cancellation_pending = true;
        committing.validate().expect("valid committing session");
        let transition = apply(
            &committing,
            ProviderDiscoveryAction::CompensationRequired,
            '5',
        );
        let cancellation = write(
            transition,
            Some(compensation_operation_id.clone()),
            Some(DiscoveryCompletedOperationWrite {
                id: commit_operation_id,
                outcome: super::DurableOperationOutcome::Failed,
            }),
        );
        storage
            .persist_discovery_transition(&cancellation)
            .expect("persist explicit keyless compensation transition");

        let compensating = storage
            .get_discovery_session(&committing.id)
            .expect("load compensating session");
        assert_eq!(compensating.session.state, DiscoveryState::Compensating);
        assert_eq!(
            storage
                .get_discovery_commit_attempt(&attempt_id)
                .expect("load compensated attempt")
                .phase,
            super::DiscoveryCommitPhase::CompensationRequired
        );
        assert!(
            storage
                .mark_discovery_operation_started(&compensation_operation_id, now())
                .expect("start compensation operation")
        );
        assert_eq!(
            storage
                .get_discovery_commit_attempt(&attempt_id)
                .expect("load started compensation attempt")
                .phase,
            super::DiscoveryCommitPhase::Compensating
        );
        storage
            .update_discovery_compensation_status(
                "step-keyless-remove-graph",
                super::DiscoveryCompensationStatus::Pending,
                super::DiscoveryCompensationStatus::InProgress,
                None,
                now(),
            )
            .expect("start graph compensation");
        storage
            .compensate_discovered_provider_graph(&attempt_id, now())
            .expect("complete absent graph compensation");
        storage
            .update_discovery_compensation_status(
                "step-keyless-restore-selection",
                super::DiscoveryCompensationStatus::Pending,
                super::DiscoveryCompensationStatus::InProgress,
                None,
                now(),
            )
            .expect("start selection compensation");
        storage
            .restore_discovery_previous_selection(&attempt_id, now())
            .expect("complete selection compensation");
        assert!(
            storage
                .list_discovery_compensation_steps(&attempt_id)
                .expect("load durable completed recipe")
                .iter()
                .all(|step| step.status == super::DiscoveryCompensationStatus::Completed)
        );

        // Simulate a crash after the last effect was durably confirmed but
        // before the aggregate CompensationSucceeded action was recorded.
        drop(storage);
        let reopened = Storage::open(root.path()).expect("recover completed compensation");
        let recovered = reopened
            .get_discovery_session(&committing.id)
            .expect("load recovered cancellation");
        assert_eq!(recovered.session.state, DiscoveryState::Cancelled);
        assert!(recovered.active_operation_id.is_none());
        assert_eq!(
            reopened
                .get_discovery_commit_attempt(&attempt_id)
                .expect("load recovered compensation attempt")
                .phase,
            super::DiscoveryCommitPhase::Compensated
        );
    }

    #[test]
    fn cross_session_commit_attempt_binding_fails_closed_before_restart_shortcut() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let owner = draft_session("session-attempt-owner");
        let other = draft_session("session-attempt-other");
        storage
            .create_discovery_session(&owner, now())
            .expect("create attempt owner");
        storage
            .create_discovery_session(&other, now())
            .expect("create other session");

        let attempt_id =
            DiscoveryCommitAttemptId::parse("attempt-owned-by-first-session").expect("attempt id");
        let plan = DiscoveryCommitPlan {
            attempt_id: attempt_id.clone(),
            session_id: owner.id.clone(),
            expected_revision: 0,
            manifest_sha256: "1".repeat(64),
            graph_sha256: "2".repeat(64),
            template_id: ProviderTemplateId::from("template-attempt-owner"),
            template_version: 1,
            connection_id: owner.input.connection_id.clone(),
            model_route_ids: vec![ModelRouteId::from("route-attempt-owner")],
            credential_ref: None,
            credential_approval_id: None,
            review_sha256: "3".repeat(64),
            previous_selection: DiscoveryPreviousSelection::None,
        };
        plan.validate().expect("valid commit plan");
        let plan_json = serde_json::to_string(&plan).expect("commit plan JSON");
        let plan_sha256 = sha256_hex(plan_json.as_bytes());

        let mut connection = storage.connection().expect("database connection");
        let transaction = connection.transaction().expect("transaction");
        transaction
            .execute(
                "INSERT INTO provider_discovery_commit_attempts (
                     id, session_id, attempt_number, action_id, expected_revision,
                     plan_sha256, plan_json, phase, redaction_version,
                     created_at, updated_at, completed_at
                 ) VALUES (
                     ?1, ?2, 1, 'action-prepare-owned-attempt', 0,
                     ?3, ?4, 'compensating', 1, ?5, ?5, NULL
                 )",
                rusqlite::params![
                    attempt_id.as_str(),
                    owner.id.as_str(),
                    plan_sha256,
                    plan_json,
                    now().to_rfc3339(),
                ],
            )
            .expect("insert owned commit attempt");

        let mut restart = write(
            apply(&other, ProviderDiscoveryAction::Begin, '7'),
            None,
            None,
        );
        restart.transition.session.commit_attempt_id = Some(attempt_id.clone());
        restart.transition.session.commit_plan_sha256 = Some(plan_sha256.clone());
        restart.transition.receipt.action_kind = "restart_interrupted".to_owned();
        let error = super::prepare_compensation_ledger(&transaction, &restart)
            .expect_err("another session cannot reuse a compensating attempt");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        let error = super::validate_failed_compensation_ledger(&transaction, &restart)
            .expect_err("another session cannot validate a foreign compensation ledger");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);

        transaction
            .execute(
                "UPDATE provider_discovery_sessions
                 SET revision = revision + 1,
                     next_event_sequence = next_event_sequence + 1,
                     commit_plan_sha256 = ?2,
                     commit_attempt_id = ?3,
                     updated_at = ?4
                 WHERE id = ?1",
                rusqlite::params![
                    other.id.as_str(),
                    plan_sha256,
                    attempt_id.as_str(),
                    now().to_rfc3339(),
                ],
            )
            .expect("seed corrupt cross-session binding");
        transaction.commit().expect("commit corrupt fixture");
        drop(connection);

        let error = storage
            .get_discovery_session(&other.id)
            .expect_err("cross-session attempt binding must fail during hydration");
        assert_eq!(error.code, CoreErrorCode::StorageCorrupted);
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn compensation_step_failure_and_session_transition_commit_atomically() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let mut session = draft_session("session-atomic-compensation-failure");
        storage
            .create_discovery_session(&session, now())
            .expect("create session");

        let attempt_id =
            DiscoveryCommitAttemptId::parse("attempt-atomic-compensation").expect("attempt id");
        let plan = DiscoveryCommitPlan {
            attempt_id: attempt_id.clone(),
            session_id: session.id.clone(),
            expected_revision: 0,
            manifest_sha256: "8".repeat(64),
            graph_sha256: "9".repeat(64),
            template_id: ProviderTemplateId::from("template-atomic-compensation"),
            template_version: 1,
            connection_id: session.input.connection_id.clone(),
            model_route_ids: vec![ModelRouteId::from("route-atomic-compensation")],
            credential_ref: None,
            credential_approval_id: None,
            review_sha256: "a".repeat(64),
            previous_selection: DiscoveryPreviousSelection::None,
        };
        plan.validate().expect("valid commit plan");
        let plan_json = serde_json::to_string(&plan).expect("plan JSON");
        let plan_sha256 = sha256_hex(plan_json.as_bytes());
        let operation_id =
            DiscoveryOperationId::parse("operation-atomic-compensation").expect("operation id");
        let step_id = "step-atomic-compensation";
        let step = DiscoveryCompensationStep {
            action_id: DiscoveryActionId::parse("action-step-atomic-compensation")
                .expect("step action id"),
            ordinal: 0,
            kind: DiscoveryCompensationKind::RestorePreviousSelection,
            target: DiscoveryCompensationTarget::RestorePreviousSelection {
                previous_selection: DiscoveryPreviousSelection::None,
            },
            status: DiscoveryCompensationStatus::Pending,
        };
        step.validate_against(&plan)
            .expect("valid compensation step");
        let step_json = serde_json::to_string(&step).expect("step JSON");
        {
            let mut connection = storage.connection().expect("database connection");
            let transaction = connection.transaction().expect("transaction");
            transaction
                .execute(
                    "INSERT INTO provider_discovery_commit_attempts (
                         id, session_id, attempt_number, action_id, expected_revision,
                         plan_sha256, plan_json, phase, redaction_version,
                         created_at, updated_at, completed_at
                     ) VALUES (
                         ?1, ?2, 1, 'action-prepare-atomic-compensation', 0,
                         ?3, ?4, 'compensating', 1, ?5, ?5, NULL
                     )",
                    rusqlite::params![
                        attempt_id.as_str(),
                        session.id.as_str(),
                        plan_sha256,
                        plan_json,
                        now().to_rfc3339(),
                    ],
                )
                .expect("insert commit attempt");
            transaction
                .execute(
                    "INSERT INTO provider_discovery_compensation_steps (
                         id, commit_attempt_id, ordinal, action_id, step_kind,
                         step_json, status, attempt_count, last_failure_json,
                         redaction_version, created_at, updated_at, completed_at
                     ) VALUES (
                         ?1, ?2, 0, ?3, 'restore_previous_selection',
                         ?4, 'in_progress', 1, NULL, 1, ?5, ?5, NULL
                     )",
                    rusqlite::params![
                        step_id,
                        attempt_id.as_str(),
                        step.action_id.as_str(),
                        step_json,
                        now().to_rfc3339(),
                    ],
                )
                .expect("insert in-progress compensation step");
            transaction
                .execute(
                    "INSERT INTO provider_discovery_operations (
                         id, session_id, operation_kind, side_effect_class, status,
                         action_id, expected_revision, request_sha256, approval_id,
                         approval_grant_sha256, started_at, finished_at, created_at, updated_at
                     ) VALUES (
                         ?1, ?2, 'compensation', 'persistent', 'started',
                         'action-run-atomic-compensation', 0, ?3, NULL, NULL,
                         ?4, NULL, ?4, ?4
                     )",
                    rusqlite::params![
                        operation_id.as_str(),
                        session.id.as_str(),
                        "b".repeat(64),
                        now().to_rfc3339(),
                    ],
                )
                .expect("insert started compensation operation");
            transaction
                .execute(
                    "UPDATE provider_discovery_sessions
                     SET state = 'compensating',
                         revision = 1,
                         next_event_sequence = 2,
                         commit_plan_sha256 = ?2,
                         commit_attempt_id = ?3,
                         active_operation_id = ?4,
                         updated_at = ?5
                     WHERE id = ?1",
                    rusqlite::params![
                        session.id.as_str(),
                        plan_sha256,
                        attempt_id.as_str(),
                        operation_id.as_str(),
                        now().to_rfc3339(),
                    ],
                )
                .expect("activate compensation fixture");
            transaction.commit().expect("commit fixture");
        }

        session.state = DiscoveryState::Compensating;
        session.revision = 1;
        session.next_event_sequence = 2;
        session.commit_plan_sha256 = Some(plan_sha256);
        session.commit_attempt_id = Some(attempt_id);
        session.validate().expect("valid compensating session");
        let failure = DiscoveryFailure {
            code: "compensation_failed".to_owned(),
            message_key: "discovery.compensation.failed".to_owned(),
            recoverable: true,
        };
        assert!(
            storage
                .update_discovery_compensation_status(
                    step_id,
                    super::DiscoveryCompensationStatus::InProgress,
                    super::DiscoveryCompensationStatus::OutcomeUnknown,
                    None,
                    now(),
                )
                .is_err(),
            "an unknown step outcome cannot be split from its session and operation transition"
        );
        assert!(
            storage
                .update_discovery_compensation_status(
                    step_id,
                    super::DiscoveryCompensationStatus::InProgress,
                    super::DiscoveryCompensationStatus::Failed,
                    Some(&failure),
                    now(),
                )
                .is_err(),
            "a step failure cannot be split from its session transition"
        );
        assert_eq!(
            storage
                .connection()
                .expect("database connection")
                .query_row(
                    "SELECT status FROM provider_discovery_compensation_steps WHERE id = ?1",
                    [step_id],
                    |row| row.get::<_, String>(0),
                )
                .expect("unchanged compensation step"),
            "in_progress"
        );
        let transition = apply(
            &session,
            ProviderDiscoveryAction::CompensationFailed {
                failure: failure.clone(),
            },
            'c',
        );
        let failure_write = write(
            transition,
            None,
            Some(DiscoveryCompletedOperationWrite {
                id: operation_id.clone(),
                outcome: super::DurableOperationOutcome::Failed,
            }),
        );
        assert!(matches!(
            storage
                .fail_discovery_compensation_and_persist_transition(step_id, &failure_write)
                .expect("atomically fail compensation"),
            PersistDiscoveryTransition::Applied { .. }
        ));
        assert!(matches!(
            storage
                .fail_discovery_compensation_and_persist_transition(step_id, &failure_write)
                .expect("idempotently replay atomic failure"),
            PersistDiscoveryTransition::Replayed { .. }
        ));

        let snapshot = storage
            .get_discovery_session(&session.id)
            .expect("load failed compensation session");
        assert_eq!(snapshot.session.failure, Some(failure.clone()));
        assert!(snapshot.active_operation_id.is_none());
        let stored = storage
            .connection()
            .expect("database connection")
            .query_row(
                "SELECT step.status, step.last_failure_json, operation.status
                 FROM provider_discovery_compensation_steps AS step
                 JOIN provider_discovery_operations AS operation
                   ON operation.id = ?2
                 WHERE step.id = ?1",
                rusqlite::params![step_id, operation_id.as_str()],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, String>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .expect("load atomic failure rows");
        assert_eq!(stored.0, "failed");
        assert_eq!(
            serde_json::from_str::<DiscoveryFailure>(&stored.1).expect("stored failure"),
            failure
        );
        assert_eq!(stored.2, "failed");
    }

    #[test]
    fn unknown_billable_outcome_rejects_approval_with_missing_references() {
        let root = tempdir().expect("temp directory");
        let storage = Storage::open(root.path()).expect("open storage");
        let draft = draft_session("session-billable-unknown");
        storage
            .create_discovery_session(&draft, now())
            .expect("create draft");
        let approval_id = DiscoveryApprovalId::parse("approval-assistant").expect("approval id");
        let grant = DiscoveryApprovalGrant::AssistantConsent {
            assistant_route_id: ModelRouteId::from("assistant-route"),
            evidence_ids: vec![EvidenceId::from("evidence-assistant")],
            allowed_document_origins: vec![
                CanonicalOrigin::parse("https://provider.example/").expect("origin"),
            ],
            max_calls: 2,
            max_input_tokens: 4_096,
            max_output_tokens: 2_048,
            max_tool_calls: 4,
            max_retries: 1,
            max_cost_micro_units: 1_000_000,
        };
        let grant_json = serde_json::to_string(&grant).expect("grant JSON");
        let grant_sha256 = sha256_hex(grant_json.as_bytes());
        let binding = DiscoveryApprovalBinding {
            approval_id: approval_id.clone(),
            grant_sha256: grant_sha256.clone(),
        };
        let binding_json = serde_json::to_string(&binding).expect("binding JSON");
        {
            let mut connection = storage.connection().expect("database connection");
            let transaction = connection.transaction().expect("transaction");
            transaction
                .execute(
                    "INSERT INTO provider_discovery_approvals (
                         id, session_id, approval_kind, candidate_id, decision,
                         grant_json, session_revision, grant_sha256, redaction_version, created_at
                     ) VALUES (?1, ?2, 'assistant_consent', NULL, 'approved',
                         ?3, 0, ?4, 1, ?5)",
                    rusqlite::params![
                        approval_id.as_str(),
                        draft.id.as_str(),
                        grant_json,
                        grant_sha256,
                        now().to_rfc3339(),
                    ],
                )
                .expect("approval row");
            transaction
                .execute(
                    "INSERT INTO provider_discovery_operations (
                         id, session_id, operation_kind, side_effect_class, status,
                         action_id, expected_revision, request_sha256, approval_id,
                         approval_grant_sha256, started_at, finished_at, created_at, updated_at
                     ) VALUES (
                         'operation-assistant', ?1, 'build_assistant_manifest_draft',
                         'billable_external', 'outcome_unknown', 'action-assistant', 0,
                         ?2, ?3, ?4, ?5, ?5, ?5, ?5
                     )",
                    rusqlite::params![
                        draft.id.as_str(),
                        "a".repeat(64),
                        approval_id.as_str(),
                        binding.grant_sha256,
                        now().to_rfc3339(),
                    ],
                )
                .expect("operation row");
            transaction
                .execute(
                    "UPDATE provider_discovery_sessions
                     SET state = 'unknown_outcome',
                         revision = 1,
                         next_event_sequence = 2,
                         unknown_operation = 'build_assistant_manifest_draft',
                         active_operation_id = NULL,
                         active_effect_approval_json = ?2,
                         updated_at = ?3
                     WHERE id = ?1",
                    rusqlite::params![draft.id.as_str(), binding_json, now().to_rfc3339()],
                )
                .expect("unknown session state");
            transaction.commit().expect("commit fixture");
        }
        let error = storage
            .get_discovery_session(&draft.id)
            .expect_err("missing assistant evidence and route must fail closed");
        assert_eq!(error.code, CoreErrorCode::StorageCorrupted);
    }
}
