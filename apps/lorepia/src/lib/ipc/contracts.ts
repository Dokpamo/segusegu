export const SUPPORTED_SHELL_API_VERSION = 1;
export const SUPPORTED_CORE_API_VERSION = 8;
export const SUPPORTED_CHAT_EVENT_VERSION = 4;

export type PlatformKind = 'android' | 'ios' | 'macos' | 'windows';
export type LoadingPhase = 'idle' | 'loading' | 'ready' | 'error';
export type ConversationMode = 'chat' | 'story';
export type MessageRole = 'system' | 'user' | 'assistant';
export type MessageStatus = 'pending' | 'complete' | 'cancelled' | 'failed';
export type CredentialStatus = 'missing' | 'available' | 'unreadable';

export interface HealthDto {
    core_version: string;
    database_open: boolean;
    schema_version: number;
    data_root_writable: boolean;
    staging_writable: boolean;
    recovery_pending: boolean;
    active_jobs: number;
}

export interface PlatformCapabilitiesDto {
    file_picker: boolean;
    credential_store: boolean;
    native_menu: boolean;
    notifications: boolean;
    creator_runtime: boolean;
}

export interface BootstrapDto {
    app_version?: string;
    shell_api_version?: number;
    core_version?: string;
    core_api_version: number;
    chat_event_version: number;
    creator_schema_version?: number;
    platform?: PlatformKind;
    health: HealthDto;
    capabilities?: PlatformCapabilitiesDto;
}

export interface FieldErrorDto {
    field: string;
    message_key: string;
}

export interface ShellErrorDto {
    code: string;
    message_key: string;
    recoverable: boolean;
    operation_id: string | null;
    field_errors: FieldErrorDto[];
}

export interface CharacterDto {
    id: string;
    name: string;
    description: string;
    source_hash: string;
    avatar_asset_id: string | null;
    created_at: string;
}

export interface ImportTicketDto {
    ticket_id: string;
    display_name: string;
    size_bytes: number;
}

export interface ImportIssueDto {
    code: string;
    message: string;
}

export interface ImportImagePreviewDto {
    logical_asset_id: string;
    media_type: string;
    size_bytes: number;
}

export interface ImportInspectionDto {
    inspection_id: string;
    kind: 'character_card_v3' | 'charx_package';
    display_name: string;
    description: string;
    source_sha256: string;
    source_size: number;
    estimated_stored_size: number;
    asset_count: number;
    representative_image: ImportImagePreviewDto | null;
    warnings: ImportIssueDto[];
    blocked_reasons: string[];
    unsupported_optional_fields: string[];
    allowed: boolean;
}

export interface ConversationDto {
    id: string;
    character_id: string;
    title: string;
    created_at: string;
    updated_at: string;
}

export interface ConversationStateDto {
    conversation_id: string;
    active_branch_id: string;
    selected_mode: ConversationMode;
    updated_at: string;
}

export interface ConversationBranchDto {
    id: string;
    conversation_id: string;
    title: string | null;
    fork_message_id: string | null;
    head_message_id: string | null;
    created_at: string;
    updated_at: string;
}

export interface MessageDto {
    id: string;
    conversation_id: string;
    parent_id: string | null;
    role: MessageRole;
    content: string;
    status: MessageStatus;
    generation_id: string | null;
    created_at: string;
}

export interface GenerationTargetDto {
    model_route_id: string;
    generation_preset_id: string;
}

export interface GenerationUsageDto {
    input_tokens: number | null;
    cached_read_tokens: number | null;
    cached_write_tokens: number | null;
    output_tokens: number | null;
    reasoning_tokens: number | null;
    tool_tokens: number | null;
}

export type ChatEventKindDto =
    | { type: 'generation_started' }
    | { type: 'reasoning_delta'; payload: string }
    | { type: 'text_delta'; payload: string }
    | { type: 'tool_call_started'; payload: { id: string; name: string } }
    | { type: 'tool_call_arguments_delta'; payload: { id: string; delta: string } }
    | { type: 'tool_call_completed'; payload: { id: string } }
    | { type: 'usage_updated'; payload: GenerationUsageDto }
    | { type: 'message_committed'; payload: { message_id: string; status: MessageStatus } }
    | { type: 'generation_cancelled' }
    | { type: 'generation_failed'; payload: { code: string; message: string } }
    | { type: 'generation_finished' };

export interface ChatEventDto {
    event_version: number;
    generation_id: string;
    conversation_id: string;
    branch_id: string | null;
    assistant_message_id: string | null;
    sequence: number;
    emitted_at: string;
    kind: ChatEventKindDto;
}

export type ChatStreamItemDto =
    | { type: 'event'; payload: ChatEventDto }
    | {
          type: 'reconciliation_required';
          payload: {
              reason:
                  | 'broadcast_lagged'
                  | 'unsupported_event_version'
                  | 'route_mismatch'
                  | 'duplicate_or_decreasing_sequence'
                  | 'sequence_gap'
                  | 'event_after_terminal';
              generation_id: string;
              conversation_id: string;
              branch_id: string;
              last_sequence: number | null;
              observed_sequence: number | null;
              dropped_events: number | null;
              supported_event_version: number;
          };
      }
    | { type: 'closed' };

export type GenerationSelectionInput =
    | { kind: 'legacy_profile'; provider_profile_id: string }
    | { kind: 'target'; target: GenerationTargetDto };

export interface SendMessageInput {
    conversation_id: string;
    branch_id: string;
    expected_head: string | null;
    mode: ConversationMode;
    text: string;
    selection: GenerationSelectionInput;
}

export interface GenerationStartedDto {
    generation_id: string;
}

export interface MessageActionGenerationDto {
    branch: ConversationBranchDto;
    generation_id: string;
}

export interface EditUserMessageInput {
    conversation_id: string;
    branch_id: string;
    expected_head: string | null;
    message_id: string;
    replacement_text: string;
    selection: GenerationSelectionInput;
}

export interface RegenerateAssistantMessageInput {
    conversation_id: string;
    branch_id: string;
    expected_head: string | null;
    message_id: string;
    selection: GenerationSelectionInput;
}

export interface RemoveMessageInput {
    conversation_id: string;
    branch_id: string;
    expected_head: string | null;
    message_id: string;
}

export interface ConnectionFieldSpecDto {
    key: string;
    label_key: string;
    description_key: string | null;
    value_type: string;
    required: boolean;
}

export interface ProviderTemplateDto {
    id: string;
    display_name: string;
    manifest_version: number;
    source: string;
    api_family: string;
    connection_fields: ConnectionFieldSpecDto[];
    default_network_mode: string;
    default_api_origin: string | null;
    credential_required: boolean;
    supports_model_listing: boolean;
    auth_binding: AuthBindingDto;
    parameters: ParameterSpecDto[];
}

export type AuthBindingDto =
    { kind: 'none' } | { kind: 'bearer_header' } | { kind: 'header_api_key'; header_name: string };

export type ConnectionConfigValueDto =
    | { type: 'text'; value: string }
    | { type: 'integer'; value: number }
    | { type: 'boolean'; value: boolean };

export interface ProviderConfigEntryDto {
    key: string;
    value: ConnectionConfigValueDto;
}

export interface CredentialScopeDto {
    allowed_origins: string[];
    auth_binding: AuthBindingDto;
    redirect_policy: string;
}

export interface ProviderConnectionDto {
    id: string;
    template_id: string;
    template_version: number;
    display_name: string;
    api_origin: string;
    api_base_path: string | null;
    network_mode: string;
    local_network_approval: ProviderLocalNetworkApprovalInput | null;
    config_values: ProviderConfigEntryDto[];
    credential_binding_required: boolean;
    credential_status?: CredentialStatus;
    credential_scope: CredentialScopeDto | null;
    approved_credential_origins: string[];
    timeout_seconds: number;
    status: string;
    created_at: string;
    updated_at: string;
}

export interface ModelRouteDto {
    id: string;
    connection_id: string;
    api_family: string;
    model_id: string;
    display_name: string | null;
    route_config: {
        deployment_id: string | null;
        region: string | null;
        endpoint_path: string | null;
        values: ProviderConfigEntryDto[];
    };
    status: string;
    miss_count: number;
    metadata_source: string;
    metadata_observed_at: string | null;
    first_seen_at: string;
    last_seen_at: string | null;
}

export const CAPABILITY_KEYS = [
    'streaming',
    'reasoning',
    'prompt_caching',
    'tool_calling',
    'parallel_tool_calling',
    'structured_output',
    'json_mode',
    'image_input',
    'audio_input',
    'audio_output',
    'logprobs',
    'seed',
    'batch',
    'background',
    'context_window',
    'max_output_tokens',
] as const;

export type CapabilityKeyInput = (typeof CAPABILITY_KEYS)[number];

export type CapabilityValueDto =
    | { type: 'boolean'; value: boolean }
    | { type: 'integer'; value: number }
    | { type: 'enum_values'; value: string[] }
    | { type: 'structured'; value: JsonValue };

export type CapabilityOverrideValueInput =
    | { type: 'boolean'; value: boolean }
    | { type: 'integer'; value: number }
    | { type: 'enum_values'; value: string[] };

export type CapabilityOverrideStatusInput = 'verified' | 'unsupported' | 'unknown' | 'conditional';

export interface UpsertCapabilityOverrideInput {
    id: string;
    model_route_id: string;
    key: CapabilityKeyInput;
    value: CapabilityOverrideValueInput;
    status: CapabilityOverrideStatusInput;
    expires_at: string | null;
}

export interface CapabilityObservationDto {
    id: string;
    model_route_id: string;
    key: string;
    value: CapabilityValueDto;
    status: string;
    source: string;
    confidence: string;
    observed_at: string;
    expires_at: string | null;
    evidence_ref: string | null;
}

export interface EffectiveCapabilityDto {
    selected: CapabilityObservationDto;
    alternatives: CapabilityObservationDto[];
    evaluated_at: string;
    selected_is_stale: boolean;
    has_conflict: boolean;
}

export type ParameterLiteralDto =
    | { type: 'boolean'; value: boolean }
    | { type: 'integer'; value: number }
    | { type: 'number'; value: number }
    | { type: 'string'; value: string }
    | { type: 'enum'; value: string }
    | { type: 'string_list'; value: string[] }
    | { type: 'json_schema'; value: string }
    | { type: 'stop_sequence_list'; value: string[] }
    | { type: 'tool_policy'; value: string };

export interface ParameterChoiceDto {
    value: ParameterLiteralDto;
    label_key: string;
}

export interface ParameterConditionDto {
    parameter_id: string;
    operator: string;
    value: ParameterLiteralDto;
}

export interface ParameterConflictDto {
    parameter_id: string;
    kind: string;
    message_key: string;
}

export interface ProviderParameterMappingDto {
    target: string;
    field_name: string;
}

export interface ParameterSpecDto {
    id: string;
    label_key: string;
    description_key: string | null;
    value_type: string;
    allowed_values: ParameterChoiceDto[];
    minimum: number | null;
    maximum: number | null;
    step: number | null;
    default_mode: string;
    visibility: ParameterConditionDto | null;
    conflicts: ParameterConflictDto[];
    provider_mapping: ProviderParameterMappingDto;
    level: string;
}

export type ParameterValueStateDto =
    { state: 'inherit_provider_default' } | { state: 'explicit'; value: ParameterLiteralDto };

export interface GenerationParameterDto {
    parameter_id: string;
    state: ParameterValueStateDto;
}

export interface GenerationPresetDto {
    id: string;
    model_route_id: string;
    display_name: string;
    values: GenerationParameterDto[];
    reasoning: {
        mode: string;
        effort: string | null;
        budget_tokens: number | null;
        summary: string;
        preserve_opaque_state: boolean;
    };
    prompt_cache: {
        mode: string;
        ttl_kind: string;
        ttl_seconds: number | null;
        context_reference: string | null;
    };
    created_at: string;
    updated_at: string;
}

export interface AppSettingsDto {
    preserve_partial_generations: boolean;
    selected_provider_profile_id: string | null;
    selected_model_route_id: string | null;
    selected_generation_preset_id: string | null;
}

export interface ProviderProfileDto {
    id: string;
    display_name: string;
    base_url: string;
    model: string;
    timeout_seconds: number;
}

export type ProviderNetworkModeInput = 'public' | 'local_loopback' | 'approved_local_network';

export interface ProviderLocalNetworkApprovalInput {
    origin: string;
    addresses: string[];
}

export interface CreateProviderConnectionInput {
    id: string;
    template_id: string;
    template_version: number;
    display_name: string;
    api_origin: string;
    api_base_path: string | null;
    network_mode: ProviderNetworkModeInput;
    local_network_approval: ProviderLocalNetworkApprovalInput | null;
    values: ProviderConfigEntryDto[];
    approved_credential_origin: string | null;
    timeout_seconds: number;
}

export interface UpdateProviderConnectionInput {
    id: string;
    display_name: string;
    timeout_seconds: number;
}

export type ApiFamilyInput =
    | 'open_ai_responses'
    | 'open_ai_chat_completions'
    | 'anthropic_messages'
    | 'gemini_generate_content'
    | 'ollama_native';

export type ModelAvailabilityInput =
    | 'available'
    | 'missing_temporarily'
    | 'documented_only'
    | 'access_denied'
    | 'deprecated'
    | 'retired'
    | 'unknown';

export type UpsertModelRouteInput =
    | {
          kind: 'create';
          id: string;
          connection_id: string;
          api_family: ApiFamilyInput;
          model_id: string;
          display_name: string | null;
          route_config: ModelRouteDto['route_config'];
          status: ModelAvailabilityInput;
      }
    | {
          kind: 'update';
          id: string;
          display_name: string | null;
          status: ModelAvailabilityInput;
      };

export interface GenerationPresetInput {
    id: string;
    model_route_id: string;
    display_name: string;
    values: GenerationParameterDto[];
    reasoning: GenerationPresetDto['reasoning'];
    prompt_cache: GenerationPresetDto['prompt_cache'];
}

export interface ParameterIssueDto {
    code: string;
    parameter_id: string | null;
    related_parameter_id: string | null;
}

export interface ReasoningControlDto {
    state: string;
    settings: GenerationPresetDto['reasoning'];
    allowed_modes: string[];
    allowed_efforts: string[];
    allowed_summaries: string[];
    budget_bounds: { minimum: number; maximum: number } | null;
    effort_field: string;
    budget_field: string;
    summary_field: string;
    issues: ParameterIssueDto[];
}

export type PromptCacheTtlDto =
    | { kind: 'provider_default' }
    | { kind: 'short' }
    | { kind: 'long' }
    | { kind: 'custom_seconds'; seconds: number };

export interface PromptCacheControlDto {
    state: string;
    settings: GenerationPresetDto['prompt_cache'];
    allowed_modes: string[];
    allowed_ttls: PromptCacheTtlDto[];
    supports_custom_ttl: boolean;
    custom_ttl_bounds: {
        minimum_seconds: number;
        maximum_seconds: number;
    } | null;
    ttl_field: string;
    context_reference_field: string;
    issues: ParameterIssueDto[];
}

export interface ProviderOverviewDto {
    settings: AppSettingsDto;
    templates: ProviderTemplateDto[];
    connections: ProviderConnectionDto[];
    legacy_profiles: ProviderProfileDto[];
}

export type CredentialTargetDto =
    | { kind: 'legacy_profile'; provider_profile_id: string }
    | { kind: 'connection'; connection_id: string };

export interface CredentialStatusDto {
    status: CredentialStatus;
}

export type RequestBodyShapeDto =
    | { kind: 'null' }
    | { kind: 'boolean' }
    | { kind: 'number' }
    | { kind: 'string' }
    | { kind: 'array'; items: RequestBodyShapeDto[]; truncated: boolean }
    | { kind: 'object'; fields: RequestBodyFieldDto[]; truncated: boolean }
    | { kind: 'redacted' }
    | { kind: 'truncated' };

export interface RequestBodyFieldDto {
    name: string;
    shape: RequestBodyShapeDto;
}

export interface RequestPreviewDto {
    method: string;
    origin: string;
    path: string;
    query_parameter_names: string[];
    header_names: string[];
    body: RequestBodyShapeDto | null;
    body_truncated: boolean;
}

export interface ModelSyncStartedDto {
    job_id: string;
}

export interface ModelSyncFailureDto {
    code: string;
    message_key: string;
    recoverable: boolean;
}

export interface ModelSyncSourceProvenanceDto {
    source: string;
    api_family: string;
    api_origin: string;
    endpoint_path: string;
    pages_fetched: number;
    response_bytes: number;
}

export interface ModelSyncDiffDto {
    connection_id: string;
    expected_connection: ProviderConnectionDto;
    expected_model_routes: ModelRouteDto[];
    observed_at: string;
    listed_routes: ModelRouteDto[];
    newly_seen_model_route_ids: string[];
    missing_model_route_ids: string[];
    initial_presets: GenerationPresetDto[];
    capability_observation_count: number;
    routes_requiring_preset_configuration: string[];
    provenance: ModelSyncSourceProvenanceDto;
}

export interface ModelSyncReviewDto {
    sha256: string;
    diff: ModelSyncDiffDto;
}

export interface ModelSyncJobDto {
    id: string;
    connection_id: string;
    state: string;
    revision: number;
    review: ModelSyncReviewDto | null;
    failure: ModelSyncFailureDto | null;
    created_at: string;
    updated_at: string;
}

export interface ModelSyncEventDto {
    version: number;
    job_id: string;
    sequence: number;
    job_revision: number;
    redaction_version: number;
    state: string;
    progress: {
        completed_steps: number;
        total_steps: number;
        message_key: string;
    };
    review_sha256: string | null;
    failure: ModelSyncFailureDto | null;
    emitted_at: string;
}

export interface ProviderDiscoveryConnectionOptionsInput {
    values: ProviderConfigEntryDto[];
    api_base_path: string | null;
    timeout_seconds: number;
    network_mode: ProviderNetworkModeInput;
    local_network_approval: ProviderLocalNetworkApprovalInput | null;
}

export interface ProviderDiscoveryConnectionOptionsDto {
    values: ProviderConfigEntryDto[];
    api_base_path: string | null;
    timeout_seconds: number;
    network_mode: string;
    local_network_approval: ProviderLocalNetworkApprovalInput | null;
}

export type BeginProviderDiscoverySourceInput =
    { kind: 'site' } | { kind: 'known_provider'; template_id: string };

export interface BeginProviderDiscoveryInput {
    connection_id: string;
    display_name: string;
    site_url: string;
    docs_url: string | null;
    credential_binding_requested: boolean;
    preferred_assistant: string | null;
    connection_options: ProviderDiscoveryConnectionOptionsInput;
    supplied_evidence_ids: string[];
    source: BeginProviderDiscoverySourceInput;
}

export interface BeginProviderDiscoveryCurlInput {
    connection_id: string;
    display_name: string;
    docs_url: string | null;
    credential_binding_requested: boolean;
    preferred_assistant: string | null;
    connection_options: ProviderDiscoveryConnectionOptionsInput;
    supplied_evidence_ids: string[];
}

export interface DiscoveryFailureDto {
    code: string;
    message_key: string;
    recoverable: boolean;
}

export interface DiscoveryReviewChangeDto {
    kind: string;
    target_kind: string;
    target_id: string;
    summary_key: string;
    evidence_ids: string[];
}

export interface DiscoveryReviewDto {
    sha256: string;
    graph_sha256: string;
    changes: DiscoveryReviewChangeDto[];
    unresolved_question_count: number;
    warning_count: number;
}

export type JsonValue =
    null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };

export interface ProviderDiscoveryApprovalProposalDto {
    id: string;
    grant: Record<string, JsonValue>;
    grant_sha256: string;
}

export interface ProviderDiscoveryReviewProposalDto {
    review: DiscoveryReviewDto;
    approval: ProviderDiscoveryApprovalProposalDto;
    commit_attempt_id: string;
    commit_plan_sha256: string;
    request_preview: RequestPreviewDto | null;
}

export type DiscoveryAssistantFailureKindInput =
    | 'transport'
    | 'timeout'
    | 'rate_limited'
    | 'invalid_structured_output'
    | 'draft_revision_required'
    | 'provider_rejected'
    | 'internal';

export type DiscoveryAssistantInterruptionOutcomeInput =
    'confirmed_no_external_effect' | 'external_outcome_unknown';

export type DiscoveryAssistantDraftFieldDto =
    | { kind: 'api_family' }
    | { kind: 'default_api_origin' }
    | { kind: 'auth' }
    | { kind: 'generate_endpoint' }
    | { kind: 'models_endpoint' }
    | { kind: 'response_decoder' }
    | { kind: 'streaming_decoder' }
    | { kind: 'parameter'; parameter_id: string };

export interface DiscoveryAssistantQuestionDto {
    id: string;
    field: DiscoveryAssistantDraftFieldDto | null;
    question: string;
    required_evidence: string;
}

export interface DiscoveryAssistantEvidenceMappingDto {
    field: DiscoveryAssistantDraftFieldDto;
    evidence_ids: string[];
    explanation: string;
}

export interface DiscoveryAssistantFieldConfidenceDto {
    field: DiscoveryAssistantDraftFieldDto;
    level: string;
    rationale: string;
}

export type DiscoveryAssistantConflictDispositionDto =
    | { status: 'unresolved' }
    | { status: 'resolved'; selected_evidence_id: string; rationale: string };

export interface DiscoveryAssistantEvidenceConflictDto {
    field: DiscoveryAssistantDraftFieldDto;
    evidence_ids: string[];
    disposition: DiscoveryAssistantConflictDispositionDto;
}

export interface DiscoveryAssistantManifestSourceDto {
    kind: string;
    url: string;
    content_sha256: string | null;
}

export interface DiscoveryAssistantEndpointDto {
    method: string;
    path: string;
}

export interface DiscoveryAssistantManifestDto {
    schema_version: number;
    api_family: string;
    sources: DiscoveryAssistantManifestSourceDto[];
    default_api_origin: string | null;
    auth: AuthBindingDto;
    models_endpoint: DiscoveryAssistantEndpointDto | null;
    generate_endpoint: DiscoveryAssistantEndpointDto;
    response_decoder: string;
    streaming_decoder: string | null;
    parameters: ParameterSpecDto[];
}

export interface DiscoveryAssistantManifestDraftDto {
    manifest: DiscoveryAssistantManifestDto;
    evidence_mappings: DiscoveryAssistantEvidenceMappingDto[];
    conflicts: DiscoveryAssistantEvidenceConflictDto[];
    unresolved_questions: DiscoveryAssistantQuestionDto[];
    confidence: DiscoveryAssistantFieldConfidenceDto[];
    summary: string;
}

export interface DiscoveryAssistantDraftReviewDto {
    draft: DiscoveryAssistantManifestDraftDto;
    unresolved_conflicts: DiscoveryAssistantDraftFieldDto[];
    required_checks: string[];
    persistence: string;
}

export type DiscoveryAssistantHostActionDto =
    | {
          kind: 'request_more_evidence';
          session_id: string;
          questions: DiscoveryAssistantQuestionDto[];
      }
    | { kind: 'review_draft'; review: DiscoveryAssistantDraftReviewDto };

export type DiscoveryAssistantResumeAction =
    | 'approve_consent'
    | 'run_assistant'
    | 'wait_for_assistant_outcome'
    | 'resume_core_host_action'
    | 'supply_more_evidence'
    | 'approve_retry'
    | 'review_draft'
    | 'restart_interrupted'
    | 'resolve_unknown_outcome';

export interface DiscoveryAssistantResumeBoundaryDto {
    checkpoint: string | null;
    action: DiscoveryAssistantResumeAction;
    questions: DiscoveryAssistantQuestionDto[];
    draft_review: DiscoveryAssistantDraftReviewDto | null;
}

export interface DiscoveryStepDto {
    id: string;
    title_key: string;
    state: string;
}

export interface ProviderDiscoverySessionDto {
    snapshot_schema_version: number;
    id: string;
    connection_id: string;
    display_name: string;
    site_url: string;
    docs_url: string | null;
    credential_binding_requested: boolean;
    preferred_assistant: string | null;
    connection_options: ProviderDiscoveryConnectionOptionsDto;
    supplied_evidence_ids: string[];
    state: string;
    revision: number;
    next_event_sequence: number;
    steps: DiscoveryStepDto[];
    action_required: { kind: string; operation: string | null } | null;
    active_operation_id: string | null;
    recovery_operation: string | null;
    unknown_operation: string | null;
    manifest_sha256: string | null;
    commit_plan_sha256: string | null;
    commit_attempt_id: string | null;
    committed_connection_id: string | null;
    cancellation_pending: boolean;
    active_effect_approval: {
        approval_id: string;
        grant_sha256: string;
    } | null;
    failure: DiscoveryFailureDto | null;
    has_private_draft: boolean;
    review: DiscoveryReviewDto | null;
    assistant_resume_boundary: DiscoveryAssistantResumeBoundaryDto | null;
    created_at: string;
    updated_at: string;
}

export type DiscoveryCandidateSummaryDto =
    | { kind: 'provider_template'; template_id: string; template_version: number }
    | { kind: 'api_origin'; origin: string }
    | { kind: 'official_document'; url: string; content_sha256: string }
    | { kind: 'model_route'; model_id: string }
    | { kind: 'manifest_draft'; schema_version: number; manifest_sha256: string };

export interface DiscoveryCandidateDto {
    id: string;
    session_id: string;
    summary: DiscoveryCandidateSummaryDto;
    evidence_ids: string[];
    created_at: string;
    proposed_revision: number;
}

export interface DiscoveryEvidenceDto {
    id: string;
    session_id: string;
    kind: string;
    source_url: string;
    content_sha256: string;
    fetched_at: string;
}

export interface DiscoveryApprovalRecordDto {
    id: string;
    session_id: string;
    session_revision: number;
    decision: string;
    grant: Record<string, JsonValue>;
    created_at: string;
}

export type DiscoveryUnknownOutcomeResolutionInput =
    | { resolution: 'confirmed_no_effect' }
    | { resolution: 'confirmed_commit_completed'; connection_id: string }
    | { resolution: 'confirmed_compensated' }
    | { resolution: 'manually_reconciled_as_failed' };

export type ContinueProviderDiscoveryActionInput =
    | { kind: 'select_template'; candidate_id: string }
    | { kind: 'continue_without_template' }
    | { kind: 'supply_more_evidence'; evidence_ids: string[] }
    | { kind: 'request_assistant' }
    | {
          kind: 'approve_assistant';
          approval_id: string;
          approval_grant_sha256: string;
      }
    | { kind: 'decline_assistant' }
    | { kind: 'approve_credential_origin'; approval_id: string }
    | {
          kind: 'approve_probes';
          approval_id: string;
          approval_grant_sha256: string;
      }
    | { kind: 'skip_probes' }
    | {
          kind: 'approve_review';
          approval_id: string;
          commit_attempt_id: string;
          commit_plan_sha256: string;
          graph_sha256: string;
      }
    | { kind: 'resume_compensation' }
    | { kind: 'restart_interrupted' }
    | {
          kind: 'resolve_unknown_outcome';
          approval_id: string;
          resolution: DiscoveryUnknownOutcomeResolutionInput;
      };

export interface ContinueProviderDiscoveryInput {
    session_id: string;
    action_id: string;
    expected_revision: number;
    action: ContinueProviderDiscoveryActionInput;
}

export interface ProviderDiscoveryEventDto {
    version: number;
    id: string;
    session_id: string;
    sequence: number;
    session_revision: number;
    state: string;
    progress: { phase: string; completed: number; total: number | null } | null;
    action_required: { kind: string; operation: string | null } | null;
    warning: string | null;
    action_id: string;
    failure: DiscoveryFailureDto | null;
}

export interface DiscoveryOutboxEventDto {
    event: ProviderDiscoveryEventDto;
    delivery_attempts: number;
    available_at: string;
    created_at: string;
}

export interface DiscoveryRecoveryResultDto {
    operation_id: string;
    session_id: string;
    state: string;
    event: ProviderDiscoveryEventDto;
}

export interface DiscoveryCompensationRecordDto {
    id: string;
    commit_attempt_id: string;
    ordinal: number;
    action_id: string;
    kind: string;
    status: string;
    attempt_count: number;
    last_failure: DiscoveryFailureDto | null;
    created_at: string;
    updated_at: string;
    completed_at: string | null;
}

export type CatalogChangeKind = 'added' | 'updated' | 'removed';

export interface CatalogManifestDiffDto {
    provider_template_id: string;
    change: CatalogChangeKind;
    previous_manifest_version: number | null;
    next_manifest_version: number | null;
    previous_sha256: string | null;
    next_sha256: string | null;
    changed_sections: string[];
}

export interface CatalogModelMetadataDiffDto {
    model_entry_id: string;
    provider_template_id: string;
    change: CatalogChangeKind;
    previous_metadata_version: number | null;
    next_metadata_version: number | null;
    previous_sha256: string | null;
    next_sha256: string | null;
    changed_sections: string[];
}

export interface ProviderCatalogDiffDto {
    diff_schema_version: number;
    from_revision: number;
    to_revision: number;
    manifest_changes: CatalogManifestDiffDto[];
    model_changes: CatalogModelMetadataDiffDto[];
}

export interface ProviderCatalogStatusDto {
    status_schema_version: number;
    state_version: number;
    active_revision: number;
    active_snapshot_sha256: string;
    bundled_baseline_sha256: string;
    snapshot_count: number;
    signed_update_count: number;
    highest_accepted_revision: number;
    latest_issued_at: string | null;
    active_signed_revisions: number[];
}

export interface ProviderCatalogRevisionSummaryDto {
    revision: number;
    captured_at: string;
    snapshot_sha256: string;
    signed_revisions: number[];
    active: boolean;
}

export interface ProviderCatalogHistoryDto {
    history_schema_version: number;
    active_revision: number;
    revisions: ProviderCatalogRevisionSummaryDto[];
    activations: {
        action_id: string;
        state_version: number;
        kind: string;
        from_revision: number | null;
        to_revision: number;
        activated_at: string;
        diff: ProviderCatalogDiffDto;
    }[];
    next_before_revision: number | null;
    next_before_state_version: number | null;
}

export interface ProviderCatalogImportPlanDto {
    review: {
        plan_schema_version: number;
        action_id: string;
        expected_state_version: number;
        expected_active_revision: number;
        expected_active_snapshot_sha256: string;
        expected_highest_accepted_revision: number;
        envelope_byte_count: number;
        envelope_sha256: string;
        signing_key_id: string;
        payload_sha256: string;
        signed_catalog_revision: number;
        candidate_revision: number;
        candidate_snapshot_sha256: string;
        prepared_at: string;
        expires_at: string;
        diff: ProviderCatalogDiffDto;
    };
    plan_sha256: string;
}

export interface ProviderCatalogImportTicketDto {
    ticket_id: string;
    plan: ProviderCatalogImportPlanDto;
}

export interface ProviderCatalogImportResultDto {
    signed_catalog_revision: number;
    activated_revision: number;
    diff: ProviderCatalogDiffDto;
    status: ProviderCatalogStatusDto;
}

export interface ProviderCatalogRollbackPlanDto {
    plan_schema_version: number;
    action_id: string;
    expected_state_version: number;
    plan_sha256: string;
    catalog_plan: {
        rollback_plan_version: number;
        from_revision: number;
        to_revision: number;
        expected_active_sha256: string;
        target_sha256: string;
        created_at: string;
        expires_at: string;
        diff: ProviderCatalogDiffDto;
    };
}

export interface ProviderCatalogRollbackResultDto {
    from_revision: number;
    activated_revision: number;
    status: ProviderCatalogStatusDto;
}

export interface ProviderWorkspaceDto {
    templates: ProviderTemplateDto[];
    connections: ProviderConnectionDto[];
    legacy_profiles: ProviderProfileDto[];
    routes: ModelRouteDto[];
    presets: GenerationPresetDto[];
    settings: AppSettingsDto;
    credential_statuses: Record<string, CredentialStatus>;
    request_preview: RequestPreviewDto | null;
    selected_capability_model_route_id: string | null;
    capability_observations: CapabilityObservationDto[];
    capability_parameter_specs: ParameterSpecDto[];
    effective_capability: EffectiveCapabilityDto | null;
    model_sync_jobs: ModelSyncJobDto[];
    selected_model_sync_job_id: string | null;
    model_sync_event: ModelSyncEventDto | null;
    discoveries: ProviderDiscoverySessionDto[];
    selected_discovery_id: string | null;
    discovery_candidates: DiscoveryCandidateDto[];
    discovery_evidence: DiscoveryEvidenceDto[];
    discovery_approvals: DiscoveryApprovalRecordDto[];
    discovery_review: DiscoveryReviewDto | null;
    discovery_approval_proposal: ProviderDiscoveryApprovalProposalDto | null;
    discovery_review_proposal: ProviderDiscoveryReviewProposalDto | null;
    discovery_assistant_resume_boundary: DiscoveryAssistantResumeBoundaryDto | null;
    discovery_assistant_host_action: DiscoveryAssistantHostActionDto | null;
    discovery_event: ProviderDiscoveryEventDto | null;
    discovery_compensation_steps: DiscoveryCompensationRecordDto[];
    discovery_recovery_results: DiscoveryRecoveryResultDto[];
    catalog_status: ProviderCatalogStatusDto | null;
    catalog_history: ProviderCatalogHistoryDto | null;
    pending_catalog_import: ProviderCatalogImportTicketDto | null;
    pending_catalog_rollback: ProviderCatalogRollbackPlanDto | null;
    catalog_diff: ProviderCatalogDiffDto | null;
}

export interface LorepiaClient {
    bootstrapSnapshot(): Promise<BootstrapDto>;

    listCharacters(): Promise<CharacterDto[]>;
    getCharacter(characterId: string): Promise<CharacterDto>;
    selectImportSource(): Promise<ImportTicketDto | null>;
    inspectImport(ticketId: string): Promise<ImportInspectionDto>;
    commitImport(inspectionId: string): Promise<CharacterDto>;
    discardImport(inspectionId: string): Promise<void>;

    listConversations(characterId: string | null): Promise<ConversationDto[]>;
    createConversation(
        characterId: string,
        title: string,
        mode: ConversationMode,
    ): Promise<ConversationDto>;
    openConversation(characterId: string): Promise<ConversationDto>;
    getConversation(conversationId: string): Promise<ConversationDto>;
    getConversationState(conversationId: string): Promise<ConversationStateDto>;
    listBranches(conversationId: string): Promise<ConversationBranchDto[]>;
    createBranch(
        conversationId: string,
        fromMessageId: string | null,
        title: string | null,
    ): Promise<ConversationBranchDto>;
    selectBranch(conversationId: string, branchId: string): Promise<ConversationStateDto>;
    setConversationMode(
        conversationId: string,
        mode: ConversationMode,
    ): Promise<ConversationStateDto>;
    listBranchMessages(branchId: string): Promise<MessageDto[]>;
    listMessages(conversationId: string): Promise<MessageDto[]>;

    sendMessage(
        input: SendMessageInput,
        streamId: string,
        onItem: (item: ChatStreamItemDto) => void,
    ): Promise<GenerationStartedDto>;
    editUserMessage(
        input: EditUserMessageInput,
        streamId: string,
        onItem: (item: ChatStreamItemDto) => void,
    ): Promise<MessageActionGenerationDto>;
    regenerateAssistantMessage(
        input: RegenerateAssistantMessageInput,
        streamId: string,
        onItem: (item: ChatStreamItemDto) => void,
    ): Promise<MessageActionGenerationDto>;
    removeMessageFromBranch(input: RemoveMessageInput): Promise<ConversationBranchDto>;
    cancelGeneration(generationId: string): Promise<void>;
    subscribeGeneration(
        generationId: string,
        conversationId: string,
        branchId: string,
        sequenceBaseline: number,
        streamId: string,
        onItem: (item: ChatStreamItemDto) => void,
    ): Promise<void>;
    disposeChatStream(streamId: string): Promise<boolean>;

    getProviderOverview(): Promise<ProviderOverviewDto>;
    getSettings(): Promise<AppSettingsDto>;
    updateSettings(settings: AppSettingsDto): Promise<AppSettingsDto>;
    selectGenerationTarget(target: GenerationTargetDto | null): Promise<AppSettingsDto>;
    listProviderTemplates(): Promise<ProviderTemplateDto[]>;
    listProviderConnections(): Promise<ProviderConnectionDto[]>;
    createProviderConnection(
        input: CreateProviderConnectionInput,
        credential: string | null,
    ): Promise<ProviderConnectionDto>;
    upsertProviderConnection(input: UpdateProviderConnectionInput): Promise<ProviderConnectionDto>;
    deleteProviderConnection(connectionId: string): Promise<void>;
    listProviderProfiles(): Promise<ProviderProfileDto[]>;
    listModelRoutes(connectionId: string): Promise<ModelRouteDto[]>;
    upsertModelRoute(input: UpsertModelRouteInput): Promise<ModelRouteDto>;
    deleteModelRoute(routeId: string): Promise<void>;
    listCapabilityObservations(modelRouteId: string): Promise<CapabilityObservationDto[]>;
    effectiveCapability(
        modelRouteId: string,
        key: CapabilityKeyInput,
    ): Promise<EffectiveCapabilityDto | null>;
    effectiveParameterSpecs(modelRouteId: string): Promise<ParameterSpecDto[]>;
    upsertUserCapabilityOverride(
        input: UpsertCapabilityOverrideInput,
    ): Promise<CapabilityObservationDto>;
    deleteUserCapabilityOverride(modelRouteId: string, observationId: string): Promise<void>;
    listGenerationPresets(routeId: string): Promise<GenerationPresetDto[]>;
    upsertGenerationPreset(input: GenerationPresetInput): Promise<GenerationPresetDto>;
    deleteGenerationPreset(presetId: string): Promise<void>;
    validateGenerationPresetCandidate(input: GenerationPresetInput): Promise<void>;
    renderReasoningControlForPreset(input: GenerationPresetInput): Promise<ReasoningControlDto>;
    renderPromptCacheControlForPreset(input: GenerationPresetInput): Promise<PromptCacheControlDto>;
    previewProviderRequestCandidate(input: GenerationPresetInput): Promise<RequestPreviewDto>;
    credentialStatus(target: CredentialTargetDto): Promise<CredentialStatusDto>;
    setCredential(target: CredentialTargetDto, credential: string): Promise<void>;
    deleteCredential(target: CredentialTargetDto): Promise<void>;
    previewProviderRequest(target: GenerationTargetDto): Promise<RequestPreviewDto>;

    startProviderModelSync(connectionId: string): Promise<ModelSyncStartedDto>;
    getProviderModelSync(jobId: string): Promise<ModelSyncJobDto>;
    listProviderModelSyncs(connectionId: string, limit: number): Promise<ModelSyncJobDto[]>;
    approveProviderModelSync(jobId: string, reviewSha256: string): Promise<ModelSyncJobDto>;
    cancelProviderModelSync(jobId: string): Promise<ModelSyncJobDto>;
    pollProviderModelSyncEvents(jobId: string, limit: number): Promise<ModelSyncEventDto[]>;
    ackProviderModelSyncEvent(jobId: string, sequence: number): Promise<boolean>;

    beginProviderDiscovery(
        input: BeginProviderDiscoveryInput,
    ): Promise<ProviderDiscoverySessionDto>;
    beginProviderDiscoveryCurl(
        input: BeginProviderDiscoveryCurlInput,
        curl: string,
    ): Promise<ProviderDiscoverySessionDto>;
    listProviderDiscoveries(limit: number): Promise<ProviderDiscoverySessionDto[]>;
    getProviderDiscovery(sessionId: string): Promise<ProviderDiscoverySessionDto>;
    listProviderDiscoveryCandidates(sessionId: string): Promise<DiscoveryCandidateDto[]>;
    listProviderDiscoveryEvidence(sessionId: string): Promise<DiscoveryEvidenceDto[]>;
    listProviderDiscoveryApprovals(sessionId: string): Promise<DiscoveryApprovalRecordDto[]>;
    getProviderDiscoveryReview(sessionId: string): Promise<DiscoveryReviewDto | null>;
    getProviderDiscoveryApprovalProposal(
        sessionId: string,
    ): Promise<ProviderDiscoveryApprovalProposalDto | null>;
    getProviderDiscoveryReviewProposal(
        sessionId: string,
    ): Promise<ProviderDiscoveryReviewProposalDto | null>;
    getProviderDiscoveryAssistantResumeBoundary(
        sessionId: string,
    ): Promise<DiscoveryAssistantResumeBoundaryDto | null>;
    runProviderDiscoveryAssistantTurn(sessionId: string): Promise<DiscoveryAssistantHostActionDto>;
    resumeProviderDiscoveryAssistantCoreHostAction(
        sessionId: string,
    ): Promise<ProviderDiscoverySessionDto>;
    approveProviderDiscoveryAssistantRetry(sessionId: string): Promise<ProviderDiscoverySessionDto>;
    requestProviderDiscoveryAssistantRevision(
        sessionId: string,
    ): Promise<ProviderDiscoverySessionDto>;
    acceptProviderDiscoveryAssistantDraft(sessionId: string): Promise<ProviderDiscoverySessionDto>;
    recordProviderDiscoveryAssistantFailure(
        sessionId: string,
        kind: DiscoveryAssistantFailureKindInput,
        retryable: boolean,
    ): Promise<ProviderDiscoverySessionDto>;
    interruptProviderDiscoveryAssistant(
        sessionId: string,
        outcome: DiscoveryAssistantInterruptionOutcomeInput,
    ): Promise<ProviderDiscoverySessionDto>;
    restartProviderDiscoveryAssistantAfterInterruption(
        sessionId: string,
    ): Promise<ProviderDiscoverySessionDto>;
    continueProviderDiscovery(
        input: ContinueProviderDiscoveryInput,
    ): Promise<ProviderDiscoverySessionDto>;
    supplyProviderDiscoveryDocumentEvidence(
        sessionId: string,
        expectedRevision: number,
        documentUrl: string,
    ): Promise<ProviderDiscoverySessionDto>;
    supplyProviderDiscoveryCurlEvidence(
        sessionId: string,
        expectedRevision: number,
        curl: string,
    ): Promise<ProviderDiscoverySessionDto>;
    cancelProviderDiscovery(
        sessionId: string,
        expectedRevision: number,
    ): Promise<ProviderDiscoverySessionDto>;
    commitProviderDiscovery(
        sessionId: string,
        credential: string | null,
    ): Promise<ProviderConnectionDto>;
    pollProviderDiscoveryEvents(limit: number): Promise<DiscoveryOutboxEventDto[]>;
    ackProviderDiscoveryEvent(eventId: string): Promise<boolean>;
    recoverProviderDiscovery(): Promise<DiscoveryRecoveryResultDto[]>;
    listProviderDiscoveryCompensationSteps(
        commitAttemptId: string,
    ): Promise<DiscoveryCompensationRecordDto[]>;
    continueProviderDiscoveryCompensation(sessionId: string): Promise<ProviderDiscoverySessionDto>;
    resumeProviderDiscoveryCompensation(sessionId: string): Promise<ProviderDiscoverySessionDto>;

    pickProviderCatalogImport(): Promise<ProviderCatalogImportTicketDto | null>;
    activateProviderCatalogImport(ticketId: string): Promise<ProviderCatalogImportResultDto>;
    discardProviderCatalogImport(ticketId: string): Promise<void>;
    providerCatalogStatus(): Promise<ProviderCatalogStatusDto>;
    providerCatalogHistory(
        limit: number,
        beforeRevision: number | null,
        beforeStateVersion: number | null,
    ): Promise<ProviderCatalogHistoryDto>;
    diffProviderCatalogRevisions(
        fromRevision: number,
        toRevision: number,
    ): Promise<ProviderCatalogDiffDto>;
    prepareProviderCatalogRollback(targetRevision: number): Promise<ProviderCatalogRollbackPlanDto>;
    activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlanDto,
    ): Promise<ProviderCatalogRollbackResultDto>;
}
