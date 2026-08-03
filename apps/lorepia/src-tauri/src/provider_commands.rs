use lorepia_shell_api as shell;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, State};
use tauri_plugin_lorepia_platform::{CredentialStatus, LorepiaPlatformExt, NativeCredential};
use uuid::Uuid;

use crate::{
    error::{CommandError, CommandResult},
    state::{AppState, CatalogImportTicket},
};

const MAXIMUM_PROVIDER_CURL_BYTES: usize = 1024 * 1024;
const MAXIMUM_SIGNED_CATALOG_BYTES: u64 = 4 * 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateSettingsRequest {
    pub settings: shell::AppSettingsDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SelectGenerationTargetRequest {
    pub target: Option<shell::GenerationTargetDto>,
}

/// Credential ingress is intentionally neither `Debug` nor `Clone`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateProviderConnectionRequest {
    pub input: shell::CreateProviderConnectionInput,
    pub credential: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpdateProviderConnectionRequest {
    pub input: shell::UpdateProviderConnectionInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderConnectionRequest {
    pub connection_id: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpsertModelRouteRequest {
    pub input: shell::UpsertModelRouteInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelRouteRequest {
    pub model_route_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EffectiveCapabilityRequest {
    pub model_route_id: String,
    pub key: shell::CapabilityKeyInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct UpsertCapabilityOverrideRequest {
    pub input: shell::UpsertCapabilityOverrideInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeleteCapabilityOverrideRequest {
    pub model_route_id: String,
    pub observation_id: String,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GenerationPresetCandidateRequest {
    pub input: shell::GenerationPresetInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GenerationPresetRequest {
    pub generation_preset_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StartProviderModelSyncRequest {
    pub connection_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ModelSyncJobRequest {
    pub job_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ListProviderModelSyncsRequest {
    pub connection_id: String,
    pub limit: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ApproveProviderModelSyncRequest {
    pub job_id: String,
    pub review_sha256: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PollProviderModelSyncEventsRequest {
    pub job_id: String,
    pub limit: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AckProviderModelSyncEventRequest {
    pub job_id: String,
    pub sequence: u64,
}

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BeginProviderDiscoveryRequest {
    pub input: shell::BeginProviderDiscoveryInput,
}

/// Pasted cURL may contain credentials, so this request cannot be logged or
/// cloned by deriving `Debug` or `Clone`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BeginProviderDiscoveryCurlRequest {
    pub input: shell::BeginProviderDiscoveryCurlInput,
    pub curl: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LimitRequest {
    pub limit: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderDiscoverySessionRequest {
    pub session_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecordProviderDiscoveryAssistantFailureRequest {
    pub session_id: String,
    pub kind: shell::DiscoveryAssistantFailureKindInput,
    pub retryable: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct InterruptProviderDiscoveryAssistantRequest {
    pub session_id: String,
    pub outcome: shell::DiscoveryAssistantInterruptionOutcomeInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ContinueProviderDiscoveryRequest {
    pub input: shell::ContinueProviderDiscoveryInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SupplyProviderDiscoveryDocumentEvidenceRequest {
    pub session_id: String,
    pub expected_revision: u64,
    pub document_url: String,
}

/// Pasted cURL may contain credentials, so this request cannot be logged or
/// cloned by deriving `Debug` or `Clone`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SupplyProviderDiscoveryCurlEvidenceRequest {
    pub session_id: String,
    pub expected_revision: u64,
    pub curl: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CancelProviderDiscoveryRequest {
    pub session_id: String,
    pub expected_revision: u64,
}

/// Credential ingress is intentionally neither `Debug` nor `Clone`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CommitProviderDiscoveryRequest {
    pub session_id: String,
    pub credential: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderDiscoveryEventRequest {
    pub event_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DiscoveryCompensationStepsRequest {
    pub commit_attempt_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderCatalogImportTicketDto {
    pub ticket_id: String,
    pub plan: shell::ProviderCatalogImportPlanDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderCatalogTicketRequest {
    pub ticket_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderCatalogHistoryRequest {
    pub limit: u32,
    pub before_revision: Option<u64>,
    pub before_state_version: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ProviderCatalogDiffRequest {
    pub from_revision: u64,
    pub to_revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PrepareProviderCatalogRollbackRequest {
    pub target_revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActivateProviderCatalogRollbackRequest {
    pub plan: shell::ProviderCatalogRollbackPlanDto,
}

#[tauri::command]
pub fn get_settings(state: State<'_, AppState>) -> CommandResult<shell::AppSettingsDto> {
    state.shell()?.get_settings().map_err(Into::into)
}

#[tauri::command]
pub fn update_settings(
    state: State<'_, AppState>,
    request: UpdateSettingsRequest,
) -> CommandResult<shell::AppSettingsDto> {
    state
        .shell()?
        .update_settings(request.settings)
        .map_err(Into::into)
}

#[tauri::command]
pub fn select_generation_target(
    state: State<'_, AppState>,
    request: SelectGenerationTargetRequest,
) -> CommandResult<shell::AppSettingsDto> {
    state
        .shell()?
        .select_generation_target(request.target)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_provider_templates(
    state: State<'_, AppState>,
) -> CommandResult<Vec<shell::ProviderTemplateDto>> {
    state.shell()?.list_provider_templates().map_err(Into::into)
}

#[tauri::command]
pub fn list_provider_connections(
    state: State<'_, AppState>,
) -> CommandResult<Vec<shell::ProviderConnectionDto>> {
    state
        .shell()?
        .list_provider_connections()
        .map_err(Into::into)
}

#[tauri::command]
pub async fn create_provider_connection(
    app: AppHandle,
    state: State<'_, AppState>,
    request: CreateProviderConnectionRequest,
) -> CommandResult<shell::ProviderConnectionDto> {
    let shell = state.shell()?;
    let CreateProviderConnectionRequest { input, credential } = request;
    let connection_id = input.id.clone();
    if shell
        .list_provider_connections()?
        .iter()
        .any(|connection| connection.id == connection_id)
    {
        return Err(CommandError::invalid_input());
    }

    let stored_credential = if let Some(credential) = credential {
        if input.approved_credential_origin.is_none()
            || app
                .lorepia_platform()
                .credential_status(&connection_id)
                .await?
                != CredentialStatus::Missing
        {
            return Err(CommandError::invalid_input());
        }
        app.lorepia_platform()
            .store_credential(&connection_id, NativeCredential::new(credential))
            .await?;
        true
    } else {
        false
    };

    match shell.create_provider_connection(input) {
        Ok(connection) => {
            if connection.id != connection_id
                || (stored_credential && !connection.credential_binding_required)
            {
                let core_rollback = shell.delete_provider_connection(&connection.id);
                let credential_rollback = if stored_credential {
                    app.lorepia_platform()
                        .delete_credential(&connection_id)
                        .await
                } else {
                    Ok(())
                };
                return match (core_rollback, credential_rollback) {
                    (Ok(()), Ok(())) | (Err(_), Err(_)) => Err(CommandError::internal()),
                    (Err(error), Ok(())) => Err(error.into()),
                    (Ok(()), Err(error)) => Err(error.into()),
                };
            }
            Ok(connection)
        }
        Err(error) => {
            if stored_credential {
                app.lorepia_platform()
                    .delete_credential(&connection_id)
                    .await?;
            }
            Err(error.into())
        }
    }
}

#[tauri::command]
pub fn upsert_provider_connection(
    state: State<'_, AppState>,
    request: UpdateProviderConnectionRequest,
) -> CommandResult<shell::ProviderConnectionDto> {
    state
        .shell()?
        .upsert_provider_connection(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn delete_provider_connection(
    app: AppHandle,
    state: State<'_, AppState>,
    request: ProviderConnectionRequest,
) -> CommandResult<()> {
    let shell = state.shell()?;
    find_connection(&shell, &request.connection_id)?;
    let previous = app
        .lorepia_platform()
        .read_credential(&request.connection_id)
        .await?;
    app.lorepia_platform()
        .delete_credential(&request.connection_id)
        .await?;

    match shell.delete_provider_connection(&request.connection_id) {
        Ok(()) => Ok(()),
        Err(error) => {
            if let Some(previous) = previous {
                app.lorepia_platform()
                    .store_credential(&request.connection_id, previous)
                    .await?;
            }
            Err(error.into())
        }
    }
}

#[tauri::command]
pub fn list_provider_profiles(
    state: State<'_, AppState>,
) -> CommandResult<Vec<shell::ProviderProfileDto>> {
    state.shell()?.list_provider_profiles().map_err(Into::into)
}

#[tauri::command]
pub fn upsert_model_route(
    state: State<'_, AppState>,
    request: UpsertModelRouteRequest,
) -> CommandResult<shell::ModelRouteDto> {
    state
        .shell()?
        .upsert_model_route(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn delete_model_route(
    state: State<'_, AppState>,
    request: ModelRouteRequest,
) -> CommandResult<()> {
    state
        .shell()?
        .delete_model_route(&request.model_route_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_capability_observations(
    state: State<'_, AppState>,
    request: ModelRouteRequest,
) -> CommandResult<Vec<shell::CapabilityObservationDto>> {
    state
        .shell()?
        .list_capability_observations(&request.model_route_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn effective_capability(
    state: State<'_, AppState>,
    request: EffectiveCapabilityRequest,
) -> CommandResult<Option<shell::EffectiveCapabilityDto>> {
    state
        .shell()?
        .effective_capability(&request.model_route_id, request.key)
        .map_err(Into::into)
}

#[tauri::command]
pub fn effective_parameter_specs(
    state: State<'_, AppState>,
    request: ModelRouteRequest,
) -> CommandResult<Vec<shell::ParameterSpecDto>> {
    state
        .shell()?
        .effective_parameter_specs(&request.model_route_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn upsert_user_capability_override(
    state: State<'_, AppState>,
    request: UpsertCapabilityOverrideRequest,
) -> CommandResult<shell::CapabilityObservationDto> {
    state
        .shell()?
        .upsert_user_capability_override(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn delete_user_capability_override(
    state: State<'_, AppState>,
    request: DeleteCapabilityOverrideRequest,
) -> CommandResult<()> {
    state
        .shell()?
        .delete_user_capability_override(&request.model_route_id, &request.observation_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn upsert_generation_preset(
    state: State<'_, AppState>,
    request: GenerationPresetCandidateRequest,
) -> CommandResult<shell::GenerationPresetDto> {
    state
        .shell()?
        .upsert_generation_preset(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn delete_generation_preset(
    state: State<'_, AppState>,
    request: GenerationPresetRequest,
) -> CommandResult<()> {
    state
        .shell()?
        .delete_generation_preset(&request.generation_preset_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn validate_generation_preset_candidate(
    state: State<'_, AppState>,
    request: GenerationPresetCandidateRequest,
) -> CommandResult<()> {
    state
        .shell()?
        .validate_generation_preset_candidate(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn render_reasoning_control_for_preset(
    state: State<'_, AppState>,
    request: GenerationPresetCandidateRequest,
) -> CommandResult<shell::ReasoningControlDto> {
    state
        .shell()?
        .render_reasoning_control_for_preset(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn render_prompt_cache_control_for_preset(
    state: State<'_, AppState>,
    request: GenerationPresetCandidateRequest,
) -> CommandResult<shell::PromptCacheControlDto> {
    state
        .shell()?
        .render_prompt_cache_control_for_preset(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn preview_provider_request_candidate(
    state: State<'_, AppState>,
    request: GenerationPresetCandidateRequest,
) -> CommandResult<shell::RequestPreviewDto> {
    state
        .shell()?
        .preview_provider_request_candidate(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn start_provider_model_sync(
    app: AppHandle,
    state: State<'_, AppState>,
    request: StartProviderModelSyncRequest,
) -> CommandResult<shell::ModelSyncStartedDto> {
    let shell = state.shell()?;
    let credential = credential_for_connection(&app, &shell, &request.connection_id).await?;
    shell
        .start_provider_model_sync(&request.connection_id, credential)
        .map_err(Into::into)
}

#[tauri::command]
pub fn get_provider_model_sync(
    state: State<'_, AppState>,
    request: ModelSyncJobRequest,
) -> CommandResult<shell::ModelSyncJobDto> {
    state
        .shell()?
        .get_provider_model_sync(&request.job_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_provider_model_syncs(
    state: State<'_, AppState>,
    request: ListProviderModelSyncsRequest,
) -> CommandResult<Vec<shell::ModelSyncJobDto>> {
    state
        .shell()?
        .list_provider_model_syncs(&request.connection_id, request.limit)
        .map_err(Into::into)
}

#[tauri::command]
pub fn approve_provider_model_sync(
    state: State<'_, AppState>,
    request: ApproveProviderModelSyncRequest,
) -> CommandResult<shell::ModelSyncJobDto> {
    state
        .shell()?
        .approve_provider_model_sync(&request.job_id, &request.review_sha256)
        .map_err(Into::into)
}

#[tauri::command]
pub fn cancel_provider_model_sync(
    state: State<'_, AppState>,
    request: ModelSyncJobRequest,
) -> CommandResult<shell::ModelSyncJobDto> {
    state
        .shell()?
        .cancel_provider_model_sync(&request.job_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn poll_provider_model_sync_events(
    state: State<'_, AppState>,
    request: PollProviderModelSyncEventsRequest,
) -> CommandResult<Vec<shell::ModelSyncEventDto>> {
    state
        .shell()?
        .poll_provider_model_sync_events(&request.job_id, request.limit)
        .map_err(Into::into)
}

#[tauri::command]
pub fn ack_provider_model_sync_event(
    state: State<'_, AppState>,
    request: AckProviderModelSyncEventRequest,
) -> CommandResult<bool> {
    state
        .shell()?
        .ack_provider_model_sync_event(&request.job_id, request.sequence)
        .map_err(Into::into)
}

#[tauri::command]
pub fn begin_provider_discovery(
    state: State<'_, AppState>,
    request: BeginProviderDiscoveryRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .begin_provider_discovery(request.input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn begin_provider_discovery_curl(
    state: State<'_, AppState>,
    request: BeginProviderDiscoveryCurlRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    let curl = bounded_secret_curl(request.curl)?;
    state
        .shell()?
        .begin_provider_discovery_curl(request.input, curl)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_provider_discoveries(
    state: State<'_, AppState>,
    request: LimitRequest,
) -> CommandResult<Vec<shell::ProviderDiscoverySessionDto>> {
    state
        .shell()?
        .list_provider_discoveries(request.limit)
        .map_err(Into::into)
}

#[tauri::command]
pub fn get_provider_discovery(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .get_provider_discovery(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_provider_discovery_candidates(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<Vec<shell::DiscoveryCandidateDto>> {
    state
        .shell()?
        .list_provider_discovery_candidates(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_provider_discovery_evidence(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<Vec<shell::DiscoveryEvidenceDto>> {
    state
        .shell()?
        .list_provider_discovery_evidence(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_provider_discovery_approvals(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<Vec<shell::DiscoveryApprovalRecordDto>> {
    state
        .shell()?
        .list_provider_discovery_approvals(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn get_provider_discovery_review(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<Option<shell::DiscoveryReviewDto>> {
    state
        .shell()?
        .get_provider_discovery_review(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn get_provider_discovery_approval_proposal(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<Option<shell::ProviderDiscoveryApprovalProposalDto>> {
    state
        .shell()?
        .get_provider_discovery_approval_proposal(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn get_provider_discovery_review_proposal(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<Option<shell::ProviderDiscoveryReviewProposalDto>> {
    state
        .shell()?
        .get_provider_discovery_review_proposal(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn get_provider_discovery_assistant_resume_boundary(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<Option<shell::DiscoveryAssistantResumeBoundaryDto>> {
    state
        .shell()?
        .get_provider_discovery_assistant_resume_boundary(&request.session_id)
        .map_err(Into::into)
}

/// Remote setup-assistant execution stays unavailable until Rust can price and
/// tokenize the exact prepared provider request. Deliberately accepting neither
/// application state nor a platform handle makes credential access and provider
/// construction impossible on this command path.
#[tauri::command]
pub fn run_provider_discovery_assistant_turn(
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::DiscoveryAssistantHostActionDto> {
    let _ = request;
    Err(CommandError::assistant_pricing_unavailable())
}

#[tauri::command]
pub fn resume_provider_discovery_assistant_core_host_action(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .resume_provider_discovery_assistant_core_host_action(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn approve_provider_discovery_assistant_retry(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .approve_provider_discovery_assistant_retry(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn request_provider_discovery_assistant_revision(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .request_provider_discovery_assistant_revision(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn accept_provider_discovery_assistant_draft(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .accept_provider_discovery_assistant_draft(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn record_provider_discovery_assistant_failure(
    state: State<'_, AppState>,
    request: RecordProviderDiscoveryAssistantFailureRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .record_provider_discovery_assistant_failure(
            &request.session_id,
            request.kind,
            request.retryable,
        )
        .map_err(Into::into)
}

#[tauri::command]
pub fn interrupt_provider_discovery_assistant(
    state: State<'_, AppState>,
    request: InterruptProviderDiscoveryAssistantRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .interrupt_provider_discovery_assistant(&request.session_id, request.outcome)
        .map_err(Into::into)
}

#[tauri::command]
pub fn restart_provider_discovery_assistant_after_interruption(
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .restart_provider_discovery_assistant_after_interruption(&request.session_id)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn continue_provider_discovery(
    app: AppHandle,
    state: State<'_, AppState>,
    request: ContinueProviderDiscoveryRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    let shell = state.shell()?;
    let session = shell.get_provider_discovery(&request.input.session_id)?;
    let credential = credential_for_discovery_session(&app, &session).await?;
    shell
        .continue_provider_discovery(request.input, credential)
        .map_err(Into::into)
}

#[tauri::command]
pub fn supply_provider_discovery_document_evidence(
    state: State<'_, AppState>,
    request: SupplyProviderDiscoveryDocumentEvidenceRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .supply_provider_discovery_document_evidence(
            &request.session_id,
            request.expected_revision,
            &request.document_url,
        )
        .map_err(Into::into)
}

#[tauri::command]
pub fn supply_provider_discovery_curl_evidence(
    state: State<'_, AppState>,
    request: SupplyProviderDiscoveryCurlEvidenceRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    let curl = bounded_secret_curl(request.curl)?;
    state
        .shell()?
        .supply_provider_discovery_curl_evidence(
            &request.session_id,
            request.expected_revision,
            curl,
        )
        .map_err(Into::into)
}

#[tauri::command]
pub fn cancel_provider_discovery(
    state: State<'_, AppState>,
    request: CancelProviderDiscoveryRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    state
        .shell()?
        .cancel_provider_discovery(&request.session_id, request.expected_revision)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn commit_provider_discovery(
    app: AppHandle,
    state: State<'_, AppState>,
    request: CommitProviderDiscoveryRequest,
) -> CommandResult<shell::ProviderConnectionDto> {
    let shell = state.shell()?;
    let CommitProviderDiscoveryRequest {
        session_id,
        credential,
    } = request;
    let session = shell.get_provider_discovery(&session_id)?;
    if !session.credential_binding_requested && credential.is_some() {
        return Err(CommandError::invalid_input());
    }

    let mut previous = None;
    let replaced_credential = if let Some(credential) = credential {
        previous = app
            .lorepia_platform()
            .read_credential(&session.connection_id)
            .await?;
        app.lorepia_platform()
            .store_credential(&session.connection_id, NativeCredential::new(credential))
            .await?;
        true
    } else {
        false
    };
    let credential_binding_confirmed = if session.credential_binding_requested {
        replaced_credential
            || app
                .lorepia_platform()
                .credential_status(&session.connection_id)
                .await?
                == CredentialStatus::Available
    } else {
        false
    };
    if session.credential_binding_requested && !credential_binding_confirmed {
        return Err(CommandError::invalid_input());
    }

    match shell.commit_provider_discovery(&session_id, credential_binding_confirmed) {
        Ok(connection) => Ok(connection),
        Err(error) => {
            let latest = shell.get_provider_discovery(&session_id).ok();
            match latest {
                Some(latest) if latest.state == "compensating" => {
                    let compensated =
                        drive_provider_discovery_compensation(&app, &shell, latest, false).await?;
                    let credential_to_restore = previous.filter(|_| {
                        replaced_credential
                            && matches!(compensated.state.as_str(), "failed" | "cancelled")
                    });
                    if let Some(previous) = credential_to_restore {
                        app.lorepia_platform()
                            .store_credential(&session.connection_id, previous)
                            .await?;
                    }
                }
                Some(latest) if matches!(latest.state.as_str(), "ready" | "unknown_outcome") => {}
                _ if replaced_credential => {
                    restore_credential(&app, &session.connection_id, previous).await?;
                }
                _ => {}
            }
            Err(error.into())
        }
    }
}

#[tauri::command]
pub fn poll_provider_discovery_events(
    state: State<'_, AppState>,
    request: LimitRequest,
) -> CommandResult<Vec<shell::DiscoveryOutboxEventDto>> {
    state
        .shell()?
        .poll_provider_discovery_events(request.limit)
        .map_err(Into::into)
}

#[tauri::command]
pub fn ack_provider_discovery_event(
    state: State<'_, AppState>,
    request: ProviderDiscoveryEventRequest,
) -> CommandResult<bool> {
    state
        .shell()?
        .ack_provider_discovery_event(&request.event_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn recover_provider_discovery(
    state: State<'_, AppState>,
) -> CommandResult<Vec<shell::DiscoveryRecoveryResultDto>> {
    state
        .shell()?
        .recover_provider_discovery()
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_provider_discovery_compensation_steps(
    state: State<'_, AppState>,
    request: DiscoveryCompensationStepsRequest,
) -> CommandResult<Vec<shell::DiscoveryCompensationRecordDto>> {
    state
        .shell()?
        .list_provider_discovery_compensation_steps(&request.commit_attempt_id)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn continue_provider_discovery_compensation(
    app: AppHandle,
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    let shell = state.shell()?;
    let session = shell
        .continue_provider_discovery_compensation(&request.session_id)
        .map_err(CommandError::from)?;
    drive_provider_discovery_compensation(&app, &shell, session, false).await
}

#[tauri::command]
pub async fn resume_provider_discovery_compensation(
    app: AppHandle,
    state: State<'_, AppState>,
    request: ProviderDiscoverySessionRequest,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    let shell = state.shell()?;
    let session = shell
        .resume_provider_discovery_compensation(&request.session_id)
        .map_err(CommandError::from)?;
    drive_provider_discovery_compensation(&app, &shell, session, true).await
}

#[tauri::command]
pub async fn pick_provider_catalog_import(
    app: AppHandle,
    state: State<'_, AppState>,
) -> CommandResult<Option<ProviderCatalogImportTicketDto>> {
    let shell = state.shell()?;
    let Some(bytes) = app
        .lorepia_platform()
        .pick_bounded_file(MAXIMUM_SIGNED_CATALOG_BYTES)
        .await?
    else {
        return Ok(None);
    };
    let envelope = shell::SignedCatalogEnvelope::new(bytes);
    let plan = shell.prepare_signed_provider_catalog_import(&envelope)?;
    let ticket_id = Uuid::new_v4().to_string();
    let response = ProviderCatalogImportTicketDto {
        ticket_id: ticket_id.clone(),
        plan: plan.clone(),
    };
    state.insert_catalog_ticket(ticket_id, CatalogImportTicket { plan, envelope })?;
    Ok(Some(response))
}

#[tauri::command]
pub fn activate_provider_catalog_import(
    state: State<'_, AppState>,
    request: ProviderCatalogTicketRequest,
) -> CommandResult<shell::ProviderCatalogImportResultDto> {
    let shell = state.shell()?;
    state.activate_catalog_ticket(&shell, &request.ticket_id)
}

#[tauri::command]
pub fn discard_provider_catalog_import(
    state: State<'_, AppState>,
    request: ProviderCatalogTicketRequest,
) -> CommandResult<()> {
    state.discard_catalog_ticket(&request.ticket_id)
}

#[tauri::command]
pub fn provider_catalog_status(
    state: State<'_, AppState>,
) -> CommandResult<shell::ProviderCatalogStatusDto> {
    state.shell()?.provider_catalog_status().map_err(Into::into)
}

#[tauri::command]
pub fn provider_catalog_history(
    state: State<'_, AppState>,
    request: ProviderCatalogHistoryRequest,
) -> CommandResult<shell::ProviderCatalogHistoryDto> {
    state
        .shell()?
        .provider_catalog_history(
            request.limit,
            request.before_revision,
            request.before_state_version,
        )
        .map_err(Into::into)
}

#[tauri::command]
pub fn diff_provider_catalog_revisions(
    state: State<'_, AppState>,
    request: ProviderCatalogDiffRequest,
) -> CommandResult<shell::ProviderCatalogDiffDto> {
    state
        .shell()?
        .diff_provider_catalog_revisions(request.from_revision, request.to_revision)
        .map_err(Into::into)
}

#[tauri::command]
pub fn prepare_provider_catalog_rollback(
    state: State<'_, AppState>,
    request: PrepareProviderCatalogRollbackRequest,
) -> CommandResult<shell::ProviderCatalogRollbackPlanDto> {
    state
        .shell()?
        .prepare_provider_catalog_rollback(request.target_revision)
        .map_err(Into::into)
}

#[tauri::command]
pub fn activate_provider_catalog_rollback(
    state: State<'_, AppState>,
    request: ActivateProviderCatalogRollbackRequest,
) -> CommandResult<shell::ProviderCatalogRollbackResultDto> {
    state
        .shell()?
        .activate_provider_catalog_rollback(request.plan)
        .map_err(Into::into)
}

async fn credential_for_connection(
    app: &AppHandle,
    shell: &shell::ShellApi,
    connection_id: &str,
) -> CommandResult<Option<shell::SecretCredential>> {
    let connection = find_connection(shell, connection_id)?;
    if !connection.credential_binding_required {
        return Ok(None);
    }
    app.lorepia_platform()
        .read_credential(connection_id)
        .await
        .map(native_credential_to_shell)
        .map_err(Into::into)
}

async fn credential_for_discovery_session(
    app: &AppHandle,
    session: &shell::ProviderDiscoverySessionDto,
) -> CommandResult<Option<shell::SecretCredential>> {
    if !session.credential_binding_requested {
        return Ok(None);
    }
    app.lorepia_platform()
        .read_credential(&session.connection_id)
        .await
        .map(native_credential_to_shell)
        .map_err(Into::into)
}

fn native_credential_to_shell(value: Option<NativeCredential>) -> Option<shell::SecretCredential> {
    value.map(|value| shell::SecretCredential::new(value.expose().to_owned()))
}

async fn drive_provider_discovery_compensation(
    app: &AppHandle,
    shell: &shell::ShellApi,
    session: shell::ProviderDiscoverySessionDto,
    allow_failed_retry: bool,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    if session.state != "compensating" {
        return Ok(session);
    }
    let attempt_id = session
        .commit_attempt_id
        .as_deref()
        .ok_or_else(CommandError::internal)?;
    let steps = shell.list_provider_discovery_compensation_steps(attempt_id)?;
    let mut credential_steps = steps
        .iter()
        .filter(|step| step.kind == "remove_credential_slot");
    let credential_step = credential_steps.next();
    if credential_steps.next().is_some()
        || credential_step.is_some_and(|step| step.commit_attempt_id != attempt_id)
    {
        return Err(CommandError::internal());
    }
    // The DTO deliberately withholds the native slot target. Core revalidates
    // this exact step ID against the session's immutable commit plan before it
    // lets the backend claim the step; only then may the backend use the
    // session-bound connection ID as the opaque native credential reference.
    let Some(step) = credential_step else {
        if session.credential_binding_requested {
            return Err(CommandError::internal());
        }
        return shell
            .continue_provider_discovery_compensation(&session.id)
            .map_err(Into::into);
    };

    match step.status.as_str() {
        "completed" => {
            return shell
                .continue_provider_discovery_compensation(&session.id)
                .map_err(Into::into);
        }
        "pending" if step.attempt_count == 0 => {}
        "failed" if allow_failed_retry => {}
        "pending" | "in_progress" | "failed" | "outcome_unknown" => return Ok(session),
        _ => return Err(CommandError::internal()),
    }

    let started = shell.start_provider_discovery_credential_compensation(&session.id, &step.id)?;
    if started.id != step.id
        || started.commit_attempt_id != attempt_id
        || started.kind != "remove_credential_slot"
        || started.status != "in_progress"
    {
        return Err(CommandError::internal());
    }

    match app
        .lorepia_platform()
        .delete_credential(&session.connection_id)
        .await
    {
        Ok(()) => complete_provider_discovery_credential_compensation(shell, &session, &step.id),
        Err(_) => match app
            .lorepia_platform()
            .credential_status(&session.connection_id)
            .await
        {
            Ok(CredentialStatus::Missing) => {
                complete_provider_discovery_credential_compensation(shell, &session, &step.id)
            }
            Ok(CredentialStatus::Available) => shell
                .fail_provider_discovery_credential_compensation(
                    &session.id,
                    &step.id,
                    credential_compensation_failure(
                        "credential_compensation_delete_failed",
                        "provider.discovery.credential_compensation_delete_failed",
                    ),
                )
                .map_err(Into::into),
            Ok(CredentialStatus::Unreadable) | Err(_) => shell
                .mark_provider_discovery_credential_compensation_unknown(&session.id, &step.id)
                .map_err(Into::into),
        },
    }
}

fn complete_provider_discovery_credential_compensation(
    shell: &shell::ShellApi,
    session: &shell::ProviderDiscoverySessionDto,
    step_id: &str,
) -> CommandResult<shell::ProviderDiscoverySessionDto> {
    match shell.complete_provider_discovery_credential_compensation(&session.id, step_id) {
        Ok(session) => Ok(session),
        Err(_) => shell
            .fail_provider_discovery_credential_compensation(
                &session.id,
                step_id,
                credential_compensation_failure(
                    "credential_compensation_record_failed",
                    "provider.discovery.credential_compensation_record_failed",
                ),
            )
            .map_err(Into::into),
    }
}

fn credential_compensation_failure(code: &str, message_key: &str) -> shell::DiscoveryFailureDto {
    shell::DiscoveryFailureDto {
        code: code.to_owned(),
        message_key: message_key.to_owned(),
        recoverable: true,
    }
}

async fn restore_credential(
    app: &AppHandle,
    reference: &str,
    previous: Option<NativeCredential>,
) -> CommandResult<()> {
    match previous {
        Some(previous) => {
            app.lorepia_platform()
                .store_credential(reference, previous)
                .await?;
        }
        None => {
            app.lorepia_platform().delete_credential(reference).await?;
        }
    }
    Ok(())
}

fn find_connection(
    shell: &shell::ShellApi,
    connection_id: &str,
) -> CommandResult<shell::ProviderConnectionDto> {
    shell
        .list_provider_connections()?
        .into_iter()
        .find(|connection| connection.id == connection_id)
        .ok_or_else(CommandError::invalid_input)
}

fn bounded_secret_curl(value: String) -> CommandResult<shell::SecretProviderCurl> {
    if value.len() > MAXIMUM_PROVIDER_CURL_BYTES || value.trim().is_empty() {
        return Err(CommandError::invalid_input());
    }
    Ok(shell::SecretProviderCurl::new(value))
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{
        MAXIMUM_PROVIDER_CURL_BYTES, ProviderDiscoverySessionRequest, bounded_secret_curl,
        run_provider_discovery_assistant_turn,
    };

    #[test]
    fn provider_curl_ingress_is_nonempty_and_bounded() {
        assert!(bounded_secret_curl(String::new()).is_err());
        assert!(bounded_secret_curl(" \n".to_owned()).is_err());
        assert!(bounded_secret_curl("curl https://example.test".to_owned()).is_ok());
        assert!(bounded_secret_curl("x".repeat(MAXIMUM_PROVIDER_CURL_BYTES + 1)).is_err());
    }

    #[test]
    fn assistant_turn_request_rejects_renderer_estimates() {
        let request = json!({
            "session_id": "synthetic-session",
            "estimate": {
                "input_tokens": 1,
                "maximum_output_tokens": 1,
                "maximum_cost_micro_units": 0
            }
        });

        serde_json::from_value::<ProviderDiscoverySessionRequest>(request)
            .expect_err("renderer-authored estimates must not cross Tauri IPC");
    }

    #[test]
    fn assistant_turn_fails_closed_without_application_or_platform_state() {
        let error = run_provider_discovery_assistant_turn(ProviderDiscoverySessionRequest {
            session_id: "synthetic-session".to_owned(),
        })
        .expect_err("remote assistant execution must remain unavailable");

        assert_eq!(error.code, "assistant_pricing_unavailable");
        assert_eq!(
            error.message_key,
            "provider.discovery.assistant_pricing_unavailable"
        );
        assert!(!error.recoverable);
    }
}
