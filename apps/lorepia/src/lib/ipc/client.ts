import { Channel, invoke } from '@tauri-apps/api/core';

import type {
    BootstrapDto,
    BeginProviderDiscoveryCurlInput,
    BeginProviderDiscoveryInput,
    CapabilityKeyInput,
    CapabilityObservationDto,
    CharacterDto,
    ChatStreamItemDto,
    ConversationBranchDto,
    ConversationDto,
    ConversationMode,
    ConversationStateDto,
    ContinueProviderDiscoveryInput,
    CreateProviderConnectionInput,
    CredentialStatusDto,
    CredentialTargetDto,
    EditUserMessageInput,
    GenerationPresetDto,
    GenerationPresetInput,
    GenerationStartedDto,
    GenerationTargetDto,
    ImportInspectionDto,
    ImportTicketDto,
    LorepiaClient,
    MessageDto,
    MessageActionGenerationDto,
    ModelRouteDto,
    ModelSyncEventDto,
    ModelSyncJobDto,
    ModelSyncStartedDto,
    PromptCacheControlDto,
    ProviderCatalogDiffDto,
    ProviderCatalogHistoryDto,
    ProviderCatalogImportResultDto,
    ProviderCatalogImportTicketDto,
    ProviderCatalogRollbackPlanDto,
    ProviderCatalogRollbackResultDto,
    ProviderCatalogStatusDto,
    ProviderConnectionDto,
    ProviderDiscoveryApprovalProposalDto,
    ProviderDiscoveryReviewProposalDto,
    ProviderDiscoverySessionDto,
    ProviderProfileDto,
    ProviderTemplateDto,
    ProviderOverviewDto,
    ReasoningControlDto,
    RegenerateAssistantMessageInput,
    RemoveMessageInput,
    RequestPreviewDto,
    SendMessageInput,
    AppSettingsDto,
    DiscoveryApprovalRecordDto,
    DiscoveryAssistantFailureKindInput,
    DiscoveryAssistantHostActionDto,
    DiscoveryAssistantInterruptionOutcomeInput,
    DiscoveryAssistantResumeBoundaryDto,
    DiscoveryCandidateDto,
    DiscoveryCompensationRecordDto,
    DiscoveryEvidenceDto,
    DiscoveryOutboxEventDto,
    DiscoveryRecoveryResultDto,
    DiscoveryReviewDto,
    EffectiveCapabilityDto,
    ParameterSpecDto,
    UpdateProviderConnectionInput,
    UpsertCapabilityOverrideInput,
    UpsertModelRouteInput,
} from './contracts';
import { normalizeClientError } from './errors';

/**
 * Command names registered by `src-tauri/src/lib.rs`.
 *
 * Keep this list as the sole frontend command-name source. Product UI never
 * calls the Rust-only platform plugin directly.
 */
export const LOREPIA_COMMANDS = {
    bootstrap: 'bootstrap',
    listCharacters: 'list_characters',
    getCharacter: 'get_character',
    pickImport: 'pick_import',
    inspectImport: 'inspect_import',
    commitImport: 'commit_import',
    discardImport: 'discard_import',
    createConversation: 'create_conversation',
    listConversations: 'list_conversations',
    listConversationsForCharacter: 'list_conversations_for_character',
    openConversation: 'open_conversation',
    getConversation: 'get_conversation',
    getConversationState: 'get_conversation_state',
    listBranches: 'list_branches',
    createBranch: 'create_branch',
    selectBranch: 'select_branch',
    setConversationMode: 'set_conversation_mode',
    listBranchMessages: 'list_branch_messages',
    listMessages: 'list_messages',
    sendMessage: 'send_message',
    editUserMessage: 'edit_user_message',
    regenerateAssistantMessage: 'regenerate_assistant_message',
    removeMessageFromBranch: 'remove_message_from_branch',
    cancelGeneration: 'cancel_generation',
    subscribeGeneration: 'subscribe_generation',
    disposeChatStream: 'dispose_chat_stream',
    credentialStatus: 'credential_status',
    setCredential: 'set_credential',
    deleteCredential: 'delete_credential',
    getProviderOverview: 'get_provider_overview',
    getSettings: 'get_settings',
    updateSettings: 'update_settings',
    selectGenerationTarget: 'select_generation_target',
    listProviderTemplates: 'list_provider_templates',
    listProviderConnections: 'list_provider_connections',
    createProviderConnection: 'create_provider_connection',
    upsertProviderConnection: 'upsert_provider_connection',
    deleteProviderConnection: 'delete_provider_connection',
    listProviderProfiles: 'list_provider_profiles',
    listModelRoutes: 'list_model_routes',
    upsertModelRoute: 'upsert_model_route',
    deleteModelRoute: 'delete_model_route',
    listCapabilityObservations: 'list_capability_observations',
    effectiveCapability: 'effective_capability',
    effectiveParameterSpecs: 'effective_parameter_specs',
    upsertUserCapabilityOverride: 'upsert_user_capability_override',
    deleteUserCapabilityOverride: 'delete_user_capability_override',
    listGenerationPresets: 'list_generation_presets',
    upsertGenerationPreset: 'upsert_generation_preset',
    deleteGenerationPreset: 'delete_generation_preset',
    validateGenerationPresetCandidate: 'validate_generation_preset_candidate',
    renderReasoningControlForPreset: 'render_reasoning_control_for_preset',
    renderPromptCacheControlForPreset: 'render_prompt_cache_control_for_preset',
    previewProviderRequestCandidate: 'preview_provider_request_candidate',
    previewProviderRequest: 'preview_provider_request',
    startProviderModelSync: 'start_provider_model_sync',
    getProviderModelSync: 'get_provider_model_sync',
    listProviderModelSyncs: 'list_provider_model_syncs',
    approveProviderModelSync: 'approve_provider_model_sync',
    cancelProviderModelSync: 'cancel_provider_model_sync',
    pollProviderModelSyncEvents: 'poll_provider_model_sync_events',
    ackProviderModelSyncEvent: 'ack_provider_model_sync_event',
    beginProviderDiscovery: 'begin_provider_discovery',
    beginProviderDiscoveryCurl: 'begin_provider_discovery_curl',
    listProviderDiscoveries: 'list_provider_discoveries',
    getProviderDiscovery: 'get_provider_discovery',
    listProviderDiscoveryCandidates: 'list_provider_discovery_candidates',
    listProviderDiscoveryEvidence: 'list_provider_discovery_evidence',
    listProviderDiscoveryApprovals: 'list_provider_discovery_approvals',
    getProviderDiscoveryReview: 'get_provider_discovery_review',
    getProviderDiscoveryApprovalProposal: 'get_provider_discovery_approval_proposal',
    getProviderDiscoveryReviewProposal: 'get_provider_discovery_review_proposal',
    getProviderDiscoveryAssistantResumeBoundary: 'get_provider_discovery_assistant_resume_boundary',
    runProviderDiscoveryAssistantTurn: 'run_provider_discovery_assistant_turn',
    resumeProviderDiscoveryAssistantCoreHostAction:
        'resume_provider_discovery_assistant_core_host_action',
    approveProviderDiscoveryAssistantRetry: 'approve_provider_discovery_assistant_retry',
    requestProviderDiscoveryAssistantRevision: 'request_provider_discovery_assistant_revision',
    acceptProviderDiscoveryAssistantDraft: 'accept_provider_discovery_assistant_draft',
    recordProviderDiscoveryAssistantFailure: 'record_provider_discovery_assistant_failure',
    interruptProviderDiscoveryAssistant: 'interrupt_provider_discovery_assistant',
    restartProviderDiscoveryAssistantAfterInterruption:
        'restart_provider_discovery_assistant_after_interruption',
    continueProviderDiscovery: 'continue_provider_discovery',
    supplyProviderDiscoveryDocumentEvidence: 'supply_provider_discovery_document_evidence',
    supplyProviderDiscoveryCurlEvidence: 'supply_provider_discovery_curl_evidence',
    cancelProviderDiscovery: 'cancel_provider_discovery',
    commitProviderDiscovery: 'commit_provider_discovery',
    pollProviderDiscoveryEvents: 'poll_provider_discovery_events',
    ackProviderDiscoveryEvent: 'ack_provider_discovery_event',
    recoverProviderDiscovery: 'recover_provider_discovery',
    listProviderDiscoveryCompensationSteps: 'list_provider_discovery_compensation_steps',
    continueProviderDiscoveryCompensation: 'continue_provider_discovery_compensation',
    resumeProviderDiscoveryCompensation: 'resume_provider_discovery_compensation',
    pickProviderCatalogImport: 'pick_provider_catalog_import',
    activateProviderCatalogImport: 'activate_provider_catalog_import',
    discardProviderCatalogImport: 'discard_provider_catalog_import',
    providerCatalogStatus: 'provider_catalog_status',
    providerCatalogHistory: 'provider_catalog_history',
    diffProviderCatalogRevisions: 'diff_provider_catalog_revisions',
    prepareProviderCatalogRollback: 'prepare_provider_catalog_rollback',
    activateProviderCatalogRollback: 'activate_provider_catalog_rollback',
} as const;

type CommandName = (typeof LOREPIA_COMMANDS)[keyof typeof LOREPIA_COMMANDS];

export interface LorepiaTransport {
    invoke(commandName: string, args?: Record<string, unknown>): Promise<unknown>;
    createChatChannel(onMessage: (message: ChatStreamItemDto) => void): unknown;
}

export class TauriTransport implements LorepiaTransport {
    invoke(commandName: string, args?: Record<string, unknown>): Promise<unknown> {
        return invoke(commandName, args);
    }

    createChatChannel(onMessage: (message: ChatStreamItemDto) => void): Channel<ChatStreamItemDto> {
        const channel = new Channel<ChatStreamItemDto>();
        channel.onmessage = onMessage;
        return channel;
    }
}

export class LiveLorepiaClient implements LorepiaClient {
    constructor(private readonly transport: LorepiaTransport = new TauriTransport()) {}

    private async call<Result>(name: CommandName, args?: Record<string, unknown>): Promise<Result> {
        try {
            return (await this.transport.invoke(name, args)) as Result;
        } catch (error: unknown) {
            throw normalizeClientError(error);
        }
    }

    bootstrapSnapshot(): Promise<BootstrapDto> {
        return this.call(LOREPIA_COMMANDS.bootstrap);
    }

    listCharacters(): Promise<CharacterDto[]> {
        return this.call(LOREPIA_COMMANDS.listCharacters);
    }

    getCharacter(characterId: string): Promise<CharacterDto> {
        return this.call(LOREPIA_COMMANDS.getCharacter, {
            request: { character_id: characterId },
        });
    }

    selectImportSource(): Promise<ImportTicketDto | null> {
        return this.call(LOREPIA_COMMANDS.pickImport);
    }

    inspectImport(ticketId: string): Promise<ImportInspectionDto> {
        return this.call(LOREPIA_COMMANDS.inspectImport, {
            request: { ticket_id: ticketId },
        });
    }

    commitImport(inspectionId: string): Promise<CharacterDto> {
        return this.call(LOREPIA_COMMANDS.commitImport, {
            request: { inspection_id: inspectionId },
        });
    }

    discardImport(inspectionId: string): Promise<void> {
        return this.call(LOREPIA_COMMANDS.discardImport, {
            request: { kind: 'inspection', inspection_id: inspectionId },
        });
    }

    listConversations(characterId: string | null): Promise<ConversationDto[]> {
        if (characterId === null) {
            return this.call(LOREPIA_COMMANDS.listConversations);
        }
        return this.call(LOREPIA_COMMANDS.listConversationsForCharacter, {
            request: { character_id: characterId },
        });
    }

    createConversation(
        characterId: string,
        title: string,
        mode: ConversationMode,
    ): Promise<ConversationDto> {
        return this.call(LOREPIA_COMMANDS.createConversation, {
            input: { character_id: characterId, title, mode },
        });
    }

    openConversation(characterId: string): Promise<ConversationDto> {
        return this.call(LOREPIA_COMMANDS.openConversation, {
            request: { character_id: characterId },
        });
    }

    getConversation(conversationId: string): Promise<ConversationDto> {
        return this.call(LOREPIA_COMMANDS.getConversation, {
            request: { conversation_id: conversationId },
        });
    }

    getConversationState(conversationId: string): Promise<ConversationStateDto> {
        return this.call(LOREPIA_COMMANDS.getConversationState, {
            request: { conversation_id: conversationId },
        });
    }

    listBranches(conversationId: string): Promise<ConversationBranchDto[]> {
        return this.call(LOREPIA_COMMANDS.listBranches, {
            request: { conversation_id: conversationId },
        });
    }

    createBranch(
        conversationId: string,
        fromMessageId: string | null,
        title: string | null,
    ): Promise<ConversationBranchDto> {
        return this.call(LOREPIA_COMMANDS.createBranch, {
            input: {
                conversation_id: conversationId,
                from_message_id: fromMessageId,
                title,
            },
        });
    }

    selectBranch(conversationId: string, branchId: string): Promise<ConversationStateDto> {
        return this.call(LOREPIA_COMMANDS.selectBranch, {
            input: { conversation_id: conversationId, branch_id: branchId },
        });
    }

    setConversationMode(
        conversationId: string,
        mode: ConversationMode,
    ): Promise<ConversationStateDto> {
        return this.call(LOREPIA_COMMANDS.setConversationMode, {
            input: { conversation_id: conversationId, mode },
        });
    }

    listBranchMessages(branchId: string): Promise<MessageDto[]> {
        return this.call(LOREPIA_COMMANDS.listBranchMessages, {
            request: { branch_id: branchId },
        });
    }

    listMessages(conversationId: string): Promise<MessageDto[]> {
        return this.call(LOREPIA_COMMANDS.listMessages, {
            request: { conversation_id: conversationId },
        });
    }

    sendMessage(
        input: SendMessageInput,
        streamId: string,
        onItem: (item: ChatStreamItemDto) => void,
    ): Promise<GenerationStartedDto> {
        const onEvent = this.transport.createChatChannel(onItem);
        return this.call(LOREPIA_COMMANDS.sendMessage, { input, streamId, onEvent });
    }

    editUserMessage(
        input: EditUserMessageInput,
        streamId: string,
        onItem: (item: ChatStreamItemDto) => void,
    ): Promise<MessageActionGenerationDto> {
        const onEvent = this.transport.createChatChannel(onItem);
        return this.call(LOREPIA_COMMANDS.editUserMessage, { input, streamId, onEvent });
    }

    regenerateAssistantMessage(
        input: RegenerateAssistantMessageInput,
        streamId: string,
        onItem: (item: ChatStreamItemDto) => void,
    ): Promise<MessageActionGenerationDto> {
        const onEvent = this.transport.createChatChannel(onItem);
        return this.call(LOREPIA_COMMANDS.regenerateAssistantMessage, {
            input,
            streamId,
            onEvent,
        });
    }

    removeMessageFromBranch(input: RemoveMessageInput): Promise<ConversationBranchDto> {
        return this.call(LOREPIA_COMMANDS.removeMessageFromBranch, { input });
    }

    cancelGeneration(generationId: string): Promise<void> {
        return this.call(LOREPIA_COMMANDS.cancelGeneration, {
            request: { generation_id: generationId },
        });
    }

    subscribeGeneration(
        generationId: string,
        conversationId: string,
        branchId: string,
        sequenceBaseline: number,
        streamId: string,
        onItem: (item: ChatStreamItemDto) => void,
    ): Promise<void> {
        const onEvent = this.transport.createChatChannel(onItem);
        return this.call(LOREPIA_COMMANDS.subscribeGeneration, {
            request: {
                generation_id: generationId,
                conversation_id: conversationId,
                branch_id: branchId,
                sequence_baseline: sequenceBaseline,
            },
            streamId,
            onEvent,
        });
    }

    disposeChatStream(streamId: string): Promise<boolean> {
        return this.call(LOREPIA_COMMANDS.disposeChatStream, {
            request: { stream_id: streamId },
        });
    }

    getProviderOverview(): Promise<ProviderOverviewDto> {
        return this.call(LOREPIA_COMMANDS.getProviderOverview);
    }

    getSettings(): Promise<AppSettingsDto> {
        return this.call(LOREPIA_COMMANDS.getSettings);
    }

    updateSettings(settings: AppSettingsDto): Promise<AppSettingsDto> {
        return this.call(LOREPIA_COMMANDS.updateSettings, { request: { settings } });
    }

    selectGenerationTarget(target: GenerationTargetDto | null): Promise<AppSettingsDto> {
        return this.call(LOREPIA_COMMANDS.selectGenerationTarget, { request: { target } });
    }

    listProviderTemplates(): Promise<ProviderTemplateDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderTemplates);
    }

    listProviderConnections(): Promise<ProviderConnectionDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderConnections);
    }

    createProviderConnection(
        input: CreateProviderConnectionInput,
        credential: string | null,
    ): Promise<ProviderConnectionDto> {
        return this.call(LOREPIA_COMMANDS.createProviderConnection, {
            request: { input, credential },
        });
    }

    upsertProviderConnection(input: UpdateProviderConnectionInput): Promise<ProviderConnectionDto> {
        return this.call(LOREPIA_COMMANDS.upsertProviderConnection, {
            request: { input },
        });
    }

    deleteProviderConnection(connectionId: string): Promise<void> {
        return this.call(LOREPIA_COMMANDS.deleteProviderConnection, {
            request: { connection_id: connectionId },
        });
    }

    listProviderProfiles(): Promise<ProviderProfileDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderProfiles);
    }

    listModelRoutes(connectionId: string): Promise<ModelRouteDto[]> {
        return this.call(LOREPIA_COMMANDS.listModelRoutes, {
            request: { connection_id: connectionId },
        });
    }

    upsertModelRoute(input: UpsertModelRouteInput): Promise<ModelRouteDto> {
        return this.call(LOREPIA_COMMANDS.upsertModelRoute, { request: { input } });
    }

    deleteModelRoute(routeId: string): Promise<void> {
        return this.call(LOREPIA_COMMANDS.deleteModelRoute, {
            request: { model_route_id: routeId },
        });
    }

    listCapabilityObservations(modelRouteId: string): Promise<CapabilityObservationDto[]> {
        return this.call(LOREPIA_COMMANDS.listCapabilityObservations, {
            request: { model_route_id: modelRouteId },
        });
    }

    effectiveCapability(
        modelRouteId: string,
        key: CapabilityKeyInput,
    ): Promise<EffectiveCapabilityDto | null> {
        return this.call(LOREPIA_COMMANDS.effectiveCapability, {
            request: { model_route_id: modelRouteId, key },
        });
    }

    effectiveParameterSpecs(modelRouteId: string): Promise<ParameterSpecDto[]> {
        return this.call(LOREPIA_COMMANDS.effectiveParameterSpecs, {
            request: { model_route_id: modelRouteId },
        });
    }

    upsertUserCapabilityOverride(
        input: UpsertCapabilityOverrideInput,
    ): Promise<CapabilityObservationDto> {
        return this.call(LOREPIA_COMMANDS.upsertUserCapabilityOverride, {
            request: { input },
        });
    }

    deleteUserCapabilityOverride(modelRouteId: string, observationId: string): Promise<void> {
        return this.call(LOREPIA_COMMANDS.deleteUserCapabilityOverride, {
            request: {
                model_route_id: modelRouteId,
                observation_id: observationId,
            },
        });
    }

    listGenerationPresets(routeId: string): Promise<GenerationPresetDto[]> {
        return this.call(LOREPIA_COMMANDS.listGenerationPresets, {
            request: { model_route_id: routeId },
        });
    }

    upsertGenerationPreset(input: GenerationPresetInput): Promise<GenerationPresetDto> {
        return this.call(LOREPIA_COMMANDS.upsertGenerationPreset, {
            request: { input },
        });
    }

    deleteGenerationPreset(presetId: string): Promise<void> {
        return this.call(LOREPIA_COMMANDS.deleteGenerationPreset, {
            request: { generation_preset_id: presetId },
        });
    }

    validateGenerationPresetCandidate(input: GenerationPresetInput): Promise<void> {
        return this.call(LOREPIA_COMMANDS.validateGenerationPresetCandidate, {
            request: { input },
        });
    }

    renderReasoningControlForPreset(input: GenerationPresetInput): Promise<ReasoningControlDto> {
        return this.call(LOREPIA_COMMANDS.renderReasoningControlForPreset, {
            request: { input },
        });
    }

    renderPromptCacheControlForPreset(
        input: GenerationPresetInput,
    ): Promise<PromptCacheControlDto> {
        return this.call(LOREPIA_COMMANDS.renderPromptCacheControlForPreset, {
            request: { input },
        });
    }

    previewProviderRequestCandidate(input: GenerationPresetInput): Promise<RequestPreviewDto> {
        return this.call(LOREPIA_COMMANDS.previewProviderRequestCandidate, {
            request: { input },
        });
    }

    credentialStatus(target: CredentialTargetDto): Promise<CredentialStatusDto> {
        return this.call(LOREPIA_COMMANDS.credentialStatus, { request: { target } });
    }

    setCredential(target: CredentialTargetDto, credential: string): Promise<void> {
        return this.call(LOREPIA_COMMANDS.setCredential, {
            request: { target, credential },
        });
    }

    deleteCredential(target: CredentialTargetDto): Promise<void> {
        return this.call(LOREPIA_COMMANDS.deleteCredential, { request: { target } });
    }

    previewProviderRequest(target: GenerationTargetDto): Promise<RequestPreviewDto> {
        return this.call(LOREPIA_COMMANDS.previewProviderRequest, {
            request: { target },
        });
    }

    startProviderModelSync(connectionId: string): Promise<ModelSyncStartedDto> {
        return this.call(LOREPIA_COMMANDS.startProviderModelSync, {
            request: { connection_id: connectionId },
        });
    }

    getProviderModelSync(jobId: string): Promise<ModelSyncJobDto> {
        return this.call(LOREPIA_COMMANDS.getProviderModelSync, {
            request: { job_id: jobId },
        });
    }

    listProviderModelSyncs(connectionId: string, limit: number): Promise<ModelSyncJobDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderModelSyncs, {
            request: { connection_id: connectionId, limit },
        });
    }

    approveProviderModelSync(jobId: string, reviewSha256: string): Promise<ModelSyncJobDto> {
        return this.call(LOREPIA_COMMANDS.approveProviderModelSync, {
            request: { job_id: jobId, review_sha256: reviewSha256 },
        });
    }

    cancelProviderModelSync(jobId: string): Promise<ModelSyncJobDto> {
        return this.call(LOREPIA_COMMANDS.cancelProviderModelSync, {
            request: { job_id: jobId },
        });
    }

    pollProviderModelSyncEvents(jobId: string, limit: number): Promise<ModelSyncEventDto[]> {
        return this.call(LOREPIA_COMMANDS.pollProviderModelSyncEvents, {
            request: { job_id: jobId, limit },
        });
    }

    ackProviderModelSyncEvent(jobId: string, sequence: number): Promise<boolean> {
        return this.call(LOREPIA_COMMANDS.ackProviderModelSyncEvent, {
            request: { job_id: jobId, sequence },
        });
    }

    beginProviderDiscovery(
        input: BeginProviderDiscoveryInput,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.beginProviderDiscovery, {
            request: { input },
        });
    }

    beginProviderDiscoveryCurl(
        input: BeginProviderDiscoveryCurlInput,
        curl: string,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.beginProviderDiscoveryCurl, {
            request: { input, curl },
        });
    }

    listProviderDiscoveries(limit: number): Promise<ProviderDiscoverySessionDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderDiscoveries, {
            request: { limit },
        });
    }

    getProviderDiscovery(sessionId: string): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.getProviderDiscovery, {
            request: { session_id: sessionId },
        });
    }

    listProviderDiscoveryCandidates(sessionId: string): Promise<DiscoveryCandidateDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderDiscoveryCandidates, {
            request: { session_id: sessionId },
        });
    }

    listProviderDiscoveryEvidence(sessionId: string): Promise<DiscoveryEvidenceDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderDiscoveryEvidence, {
            request: { session_id: sessionId },
        });
    }

    listProviderDiscoveryApprovals(sessionId: string): Promise<DiscoveryApprovalRecordDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderDiscoveryApprovals, {
            request: { session_id: sessionId },
        });
    }

    getProviderDiscoveryReview(sessionId: string): Promise<DiscoveryReviewDto | null> {
        return this.call(LOREPIA_COMMANDS.getProviderDiscoveryReview, {
            request: { session_id: sessionId },
        });
    }

    getProviderDiscoveryApprovalProposal(
        sessionId: string,
    ): Promise<ProviderDiscoveryApprovalProposalDto | null> {
        return this.call(LOREPIA_COMMANDS.getProviderDiscoveryApprovalProposal, {
            request: { session_id: sessionId },
        });
    }

    getProviderDiscoveryReviewProposal(
        sessionId: string,
    ): Promise<ProviderDiscoveryReviewProposalDto | null> {
        return this.call(LOREPIA_COMMANDS.getProviderDiscoveryReviewProposal, {
            request: { session_id: sessionId },
        });
    }

    getProviderDiscoveryAssistantResumeBoundary(
        sessionId: string,
    ): Promise<DiscoveryAssistantResumeBoundaryDto | null> {
        return this.call(LOREPIA_COMMANDS.getProviderDiscoveryAssistantResumeBoundary, {
            request: { session_id: sessionId },
        });
    }

    runProviderDiscoveryAssistantTurn(sessionId: string): Promise<DiscoveryAssistantHostActionDto> {
        return this.call(LOREPIA_COMMANDS.runProviderDiscoveryAssistantTurn, {
            request: { session_id: sessionId },
        });
    }

    resumeProviderDiscoveryAssistantCoreHostAction(
        sessionId: string,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.resumeProviderDiscoveryAssistantCoreHostAction, {
            request: { session_id: sessionId },
        });
    }

    approveProviderDiscoveryAssistantRetry(
        sessionId: string,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.approveProviderDiscoveryAssistantRetry, {
            request: { session_id: sessionId },
        });
    }

    requestProviderDiscoveryAssistantRevision(
        sessionId: string,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.requestProviderDiscoveryAssistantRevision, {
            request: { session_id: sessionId },
        });
    }

    acceptProviderDiscoveryAssistantDraft(sessionId: string): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.acceptProviderDiscoveryAssistantDraft, {
            request: { session_id: sessionId },
        });
    }

    recordProviderDiscoveryAssistantFailure(
        sessionId: string,
        kind: DiscoveryAssistantFailureKindInput,
        retryable: boolean,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.recordProviderDiscoveryAssistantFailure, {
            request: { session_id: sessionId, kind, retryable },
        });
    }

    interruptProviderDiscoveryAssistant(
        sessionId: string,
        outcome: DiscoveryAssistantInterruptionOutcomeInput,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.interruptProviderDiscoveryAssistant, {
            request: { session_id: sessionId, outcome },
        });
    }

    restartProviderDiscoveryAssistantAfterInterruption(
        sessionId: string,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.restartProviderDiscoveryAssistantAfterInterruption, {
            request: { session_id: sessionId },
        });
    }

    continueProviderDiscovery(
        input: ContinueProviderDiscoveryInput,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.continueProviderDiscovery, {
            request: { input },
        });
    }

    supplyProviderDiscoveryDocumentEvidence(
        sessionId: string,
        expectedRevision: number,
        documentUrl: string,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.supplyProviderDiscoveryDocumentEvidence, {
            request: {
                session_id: sessionId,
                expected_revision: expectedRevision,
                document_url: documentUrl,
            },
        });
    }

    supplyProviderDiscoveryCurlEvidence(
        sessionId: string,
        expectedRevision: number,
        curl: string,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.supplyProviderDiscoveryCurlEvidence, {
            request: {
                session_id: sessionId,
                expected_revision: expectedRevision,
                curl,
            },
        });
    }

    cancelProviderDiscovery(
        sessionId: string,
        expectedRevision: number,
    ): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.cancelProviderDiscovery, {
            request: {
                session_id: sessionId,
                expected_revision: expectedRevision,
            },
        });
    }

    commitProviderDiscovery(
        sessionId: string,
        credential: string | null,
    ): Promise<ProviderConnectionDto> {
        return this.call(LOREPIA_COMMANDS.commitProviderDiscovery, {
            request: { session_id: sessionId, credential },
        });
    }

    pollProviderDiscoveryEvents(limit: number): Promise<DiscoveryOutboxEventDto[]> {
        return this.call(LOREPIA_COMMANDS.pollProviderDiscoveryEvents, {
            request: { limit },
        });
    }

    ackProviderDiscoveryEvent(eventId: string): Promise<boolean> {
        return this.call(LOREPIA_COMMANDS.ackProviderDiscoveryEvent, {
            request: { event_id: eventId },
        });
    }

    recoverProviderDiscovery(): Promise<DiscoveryRecoveryResultDto[]> {
        return this.call(LOREPIA_COMMANDS.recoverProviderDiscovery);
    }

    listProviderDiscoveryCompensationSteps(
        commitAttemptId: string,
    ): Promise<DiscoveryCompensationRecordDto[]> {
        return this.call(LOREPIA_COMMANDS.listProviderDiscoveryCompensationSteps, {
            request: { commit_attempt_id: commitAttemptId },
        });
    }

    continueProviderDiscoveryCompensation(sessionId: string): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.continueProviderDiscoveryCompensation, {
            request: { session_id: sessionId },
        });
    }

    resumeProviderDiscoveryCompensation(sessionId: string): Promise<ProviderDiscoverySessionDto> {
        return this.call(LOREPIA_COMMANDS.resumeProviderDiscoveryCompensation, {
            request: { session_id: sessionId },
        });
    }

    pickProviderCatalogImport(): Promise<ProviderCatalogImportTicketDto | null> {
        return this.call(LOREPIA_COMMANDS.pickProviderCatalogImport);
    }

    activateProviderCatalogImport(ticketId: string): Promise<ProviderCatalogImportResultDto> {
        return this.call(LOREPIA_COMMANDS.activateProviderCatalogImport, {
            request: { ticket_id: ticketId },
        });
    }

    discardProviderCatalogImport(ticketId: string): Promise<void> {
        return this.call(LOREPIA_COMMANDS.discardProviderCatalogImport, {
            request: { ticket_id: ticketId },
        });
    }

    providerCatalogStatus(): Promise<ProviderCatalogStatusDto> {
        return this.call(LOREPIA_COMMANDS.providerCatalogStatus);
    }

    providerCatalogHistory(
        limit: number,
        beforeRevision: number | null,
        beforeStateVersion: number | null,
    ): Promise<ProviderCatalogHistoryDto> {
        return this.call(LOREPIA_COMMANDS.providerCatalogHistory, {
            request: {
                limit,
                before_revision: beforeRevision,
                before_state_version: beforeStateVersion,
            },
        });
    }

    diffProviderCatalogRevisions(
        fromRevision: number,
        toRevision: number,
    ): Promise<ProviderCatalogDiffDto> {
        return this.call(LOREPIA_COMMANDS.diffProviderCatalogRevisions, {
            request: { from_revision: fromRevision, to_revision: toRevision },
        });
    }

    prepareProviderCatalogRollback(
        targetRevision: number,
    ): Promise<ProviderCatalogRollbackPlanDto> {
        return this.call(LOREPIA_COMMANDS.prepareProviderCatalogRollback, {
            request: { target_revision: targetRevision },
        });
    }

    activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlanDto,
    ): Promise<ProviderCatalogRollbackResultDto> {
        return this.call(LOREPIA_COMMANDS.activateProviderCatalogRollback, {
            request: { plan },
        });
    }
}

export function createLiveLorepiaClient(): LorepiaClient {
    return new LiveLorepiaClient();
}
