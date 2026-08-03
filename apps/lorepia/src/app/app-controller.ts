import { get, writable, type Readable } from 'svelte/store';

import {
    SUPPORTED_CHAT_EVENT_VERSION,
    SUPPORTED_CORE_API_VERSION,
    SUPPORTED_SHELL_API_VERSION,
    type AppSettingsDto,
    type BeginProviderDiscoveryCurlInput,
    type BeginProviderDiscoveryInput,
    type BootstrapDto,
    type CapabilityKeyInput,
    type CharacterDto,
    type ChatEventDto,
    type ChatStreamItemDto,
    type ContinueProviderDiscoveryActionInput,
    type ConversationBranchDto,
    type ConversationDto,
    type ConversationMode,
    type ConversationStateDto,
    type CreateProviderConnectionInput,
    type CredentialTargetDto,
    type GenerationPresetInput,
    type DiscoveryAssistantFailureKindInput,
    type DiscoveryAssistantInterruptionOutcomeInput,
    type GenerationPresetDto,
    type GenerationSelectionInput,
    type ImportInspectionDto,
    type LoadingPhase,
    type LorepiaClient,
    type MessageActionGenerationDto,
    type MessageDto,
    type ModelRouteDto,
    type ModelSyncJobDto,
    type ProviderCatalogRollbackPlanDto,
    type ProviderConnectionDto,
    type ProviderDiscoverySessionDto,
    type ProviderProfileDto,
    type ProviderTemplateDto,
    type ProviderWorkspaceDto,
    type UpdateProviderConnectionInput,
    type UpsertCapabilityOverrideInput,
    type UpsertModelRouteInput,
} from '../lib/ipc/contracts';
import { LorepiaClientError, normalizeClientError } from '../lib/ipc/errors';
import { ChatStreamVerifier } from '../features/chat/chat-stream';

export interface SectionState {
    phase: LoadingPhase;
    error: string | null;
}

export interface ImportFlowState extends SectionState {
    inspection: ImportInspectionDto | null;
}

export interface ChatState extends SectionState {
    active_generation_id: string | null;
    streaming_text: string;
    reasoning_text: string;
    reconcile_notice: string | null;
    usage_label: string | null;
}

export interface LorepiaAppState {
    bootstrap: SectionState & { value: BootstrapDto | null };
    library: SectionState & { characters: CharacterDto[] };
    import_flow: ImportFlowState;
    selected_character: CharacterDto | null;
    conversations: SectionState & { items: ConversationDto[] };
    selected_conversation: ConversationDto | null;
    conversation_state: ConversationStateDto | null;
    branches: ConversationBranchDto[];
    messages: SectionState & { items: MessageDto[] };
    chat: ChatState;
    providers: SectionState & { workspace: ProviderWorkspaceDto };
    announcement: string;
}

const EMPTY_SETTINGS: AppSettingsDto = {
    preserve_partial_generations: true,
    selected_provider_profile_id: null,
    selected_model_route_id: null,
    selected_generation_preset_id: null,
};

const EMPTY_PROVIDER_WORKSPACE: ProviderWorkspaceDto = {
    templates: [],
    connections: [],
    legacy_profiles: [],
    routes: [],
    presets: [],
    settings: EMPTY_SETTINGS,
    credential_statuses: {},
    request_preview: null,
    selected_capability_model_route_id: null,
    capability_observations: [],
    capability_parameter_specs: [],
    effective_capability: null,
    model_sync_jobs: [],
    selected_model_sync_job_id: null,
    model_sync_event: null,
    discoveries: [],
    selected_discovery_id: null,
    discovery_candidates: [],
    discovery_evidence: [],
    discovery_approvals: [],
    discovery_review: null,
    discovery_approval_proposal: null,
    discovery_review_proposal: null,
    discovery_assistant_resume_boundary: null,
    discovery_assistant_host_action: null,
    discovery_event: null,
    discovery_compensation_steps: [],
    discovery_recovery_results: [],
    catalog_status: null,
    catalog_history: null,
    pending_catalog_import: null,
    pending_catalog_rollback: null,
    catalog_diff: null,
};

export const INITIAL_APP_STATE: LorepiaAppState = {
    bootstrap: { phase: 'idle', error: null, value: null },
    library: { phase: 'idle', error: null, characters: [] },
    import_flow: { phase: 'idle', error: null, inspection: null },
    selected_character: null,
    conversations: { phase: 'idle', error: null, items: [] },
    selected_conversation: null,
    conversation_state: null,
    branches: [],
    messages: { phase: 'idle', error: null, items: [] },
    chat: {
        phase: 'idle',
        error: null,
        active_generation_id: null,
        streaming_text: '',
        reasoning_text: '',
        reconcile_notice: null,
        usage_label: null,
    },
    providers: {
        phase: 'idle',
        error: null,
        workspace: EMPTY_PROVIDER_WORKSPACE,
    },
    announcement: '',
};

const GENERATION_REATTACHMENT_UNAVAILABLE_MESSAGE =
    '앱을 다시 연 뒤에는 진행 중이던 응답 스트림에 다시 연결할 수 없습니다. 생성 취소 후 대화를 다시 열어 주세요.';

function errorLabel(error: unknown): string {
    const normalized = normalizeClientError(error);
    const fallback: Record<string, string> = {
        'error.unexpected': '예상하지 못한 오류가 발생했습니다.',
        'error.compatibility': '앱과 Core 버전이 호환되지 않습니다.',
        'error.invalid_input': '입력 내용을 확인해 주세요.',
        'error.core_unavailable': '로컬 Core를 열 수 없습니다.',
        'chat.generation_reattachment_unavailable': GENERATION_REATTACHMENT_UNAVAILABLE_MESSAGE,
        'provider.discovery.assistant_pricing_unavailable':
            '신뢰할 수 있는 가격·토큰 정책이 준비될 때까지 원격 설정 도우미를 사용할 수 없습니다.',
    };
    return fallback[normalized.messageKey] ?? normalized.messageKey;
}

function reattachmentUnavailableChatState(generationId: string): ChatState {
    return {
        phase: 'error',
        error: GENERATION_REATTACHMENT_UNAVAILABLE_MESSAGE,
        active_generation_id: generationId,
        streaming_text: '',
        reasoning_text: '',
        reconcile_notice: null,
        usage_label: null,
    };
}

function ensureCompatible(snapshot: BootstrapDto): void {
    const shellCompatible =
        snapshot.shell_api_version === undefined ||
        snapshot.shell_api_version === SUPPORTED_SHELL_API_VERSION;
    if (
        !shellCompatible ||
        snapshot.core_api_version !== SUPPORTED_CORE_API_VERSION ||
        snapshot.chat_event_version !== SUPPORTED_CHAT_EVENT_VERSION
    ) {
        throw new LorepiaClientError({
            code: 'incompatible_version',
            message_key: 'error.compatibility',
            recoverable: false,
            operation_id: null,
            field_errors: [],
        });
    }
}

function credentialKey(target: CredentialTargetDto): string {
    return target.kind === 'connection'
        ? `connection:${target.connection_id}`
        : `legacy_profile:${target.provider_profile_id}`;
}

export class LorepiaAppController {
    private readonly mutable = writable<LorepiaAppState>(structuredClone(INITIAL_APP_STATE));
    readonly state: Readable<LorepiaAppState> = this.mutable;

    private appEpoch = 0;
    private conversationEpoch = 0;
    private streamEpoch = 0;
    private providerEpoch = 0;
    private reconcileInFlight = false;
    private streamVerifier: ChatStreamVerifier | null = null;
    private activeStreamId: string | null = null;
    private deltaFlushTimer: ReturnType<typeof setTimeout> | null = null;
    private pendingTextDelta = '';
    private pendingReasoningDelta = '';

    constructor(private readonly client: LorepiaClient) {}

    private update(updater: (state: LorepiaAppState) => LorepiaAppState): void {
        this.mutable.update(updater);
    }

    private announce(message: string): void {
        this.update((state) => ({ ...state, announcement: message }));
    }

    async start(): Promise<void> {
        const epoch = ++this.appEpoch;
        this.update((state) => ({
            ...state,
            bootstrap: { ...state.bootstrap, phase: 'loading', error: null },
        }));
        try {
            const snapshot = await this.client.bootstrapSnapshot();
            ensureCompatible(snapshot);
            if (epoch !== this.appEpoch) return;
            this.update((state) => ({
                ...state,
                bootstrap: { phase: 'ready', error: null, value: snapshot },
            }));
            await Promise.all([this.loadLibrary(epoch), this.loadProviders()]);
        } catch (error: unknown) {
            if (epoch !== this.appEpoch) return;
            this.update((state) => ({
                ...state,
                bootstrap: { phase: 'error', error: errorLabel(error), value: null },
            }));
        }
    }

    async loadLibrary(parentEpoch = this.appEpoch): Promise<void> {
        this.update((state) => ({
            ...state,
            library: { ...state.library, phase: 'loading', error: null },
        }));
        try {
            const characters = await this.client.listCharacters();
            if (parentEpoch !== this.appEpoch) return;
            this.update((state) => ({
                ...state,
                library: { phase: 'ready', error: null, characters },
            }));
        } catch (error: unknown) {
            if (parentEpoch !== this.appEpoch) return;
            this.update((state) => ({
                ...state,
                library: { ...state.library, phase: 'error', error: errorLabel(error) },
            }));
        }
    }

    async beginImport(): Promise<void> {
        this.update((state) => ({
            ...state,
            import_flow: { phase: 'loading', error: null, inspection: null },
        }));
        try {
            const ticket = await this.client.selectImportSource();
            if (ticket === null) {
                this.update((state) => ({
                    ...state,
                    import_flow: { phase: 'idle', error: null, inspection: null },
                }));
                return;
            }
            const inspection = await this.client.inspectImport(ticket.ticket_id);
            this.update((state) => ({
                ...state,
                import_flow: { phase: 'ready', error: null, inspection },
            }));
            this.announce(`${inspection.display_name} 가져오기를 검토해 주세요.`);
        } catch (error: unknown) {
            this.update((state) => ({
                ...state,
                import_flow: { phase: 'error', error: errorLabel(error), inspection: null },
            }));
        }
    }

    async commitImport(): Promise<void> {
        const inspection = get(this.mutable).import_flow.inspection;
        if (inspection?.allowed !== true) return;
        this.update((state) => ({
            ...state,
            import_flow: { ...state.import_flow, phase: 'loading', error: null },
        }));
        try {
            const character = await this.client.commitImport(inspection.inspection_id);
            this.update((state) => ({
                ...state,
                library: {
                    phase: 'ready',
                    error: null,
                    characters: [
                        character,
                        ...state.library.characters.filter((item) => item.id !== character.id),
                    ],
                },
                import_flow: { phase: 'idle', error: null, inspection: null },
            }));
            this.announce(`${character.name}을(를) 서재에 추가했습니다.`);
        } catch (error: unknown) {
            this.update((state) => ({
                ...state,
                import_flow: {
                    ...state.import_flow,
                    phase: 'error',
                    error: errorLabel(error),
                },
            }));
        }
    }

    async discardImport(): Promise<void> {
        const inspection = get(this.mutable).import_flow.inspection;
        this.update((state) => ({
            ...state,
            import_flow: { phase: 'idle', error: null, inspection: null },
        }));
        if (inspection === null) return;
        try {
            await this.client.discardImport(inspection.inspection_id);
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async selectCharacter(character: CharacterDto): Promise<void> {
        const epoch = ++this.conversationEpoch;
        this.detachStream();
        this.update((state) => ({
            ...state,
            selected_character: character,
            selected_conversation: null,
            conversation_state: null,
            branches: [],
            messages: { phase: 'idle', error: null, items: [] },
            conversations: { phase: 'loading', error: null, items: [] },
            chat: { ...INITIAL_APP_STATE.chat },
        }));
        try {
            const items = await this.client.listConversations(character.id);
            if (epoch !== this.conversationEpoch) return;
            this.update((state) => ({
                ...state,
                conversations: { phase: 'ready', error: null, items },
            }));
        } catch (error: unknown) {
            if (epoch !== this.conversationEpoch) return;
            this.update((state) => ({
                ...state,
                conversations: { phase: 'error', error: errorLabel(error), items: [] },
            }));
        }
    }

    async openNewConversation(): Promise<void> {
        const character = get(this.mutable).selected_character;
        if (character === null) return;
        const epoch = ++this.conversationEpoch;
        try {
            const conversation = await this.client.openConversation(character.id);
            if (epoch !== this.conversationEpoch) return;
            this.update((state) => ({
                ...state,
                conversations: {
                    phase: 'ready',
                    error: null,
                    items: [
                        conversation,
                        ...state.conversations.items.filter((item) => item.id !== conversation.id),
                    ],
                },
            }));
            await this.selectConversation(conversation);
        } catch (error: unknown) {
            if (epoch !== this.conversationEpoch) return;
            this.update((state) => ({
                ...state,
                conversations: {
                    ...state.conversations,
                    phase: 'error',
                    error: errorLabel(error),
                },
            }));
        }
    }

    async selectConversation(conversation: ConversationDto): Promise<void> {
        const epoch = ++this.conversationEpoch;
        this.detachStream();
        this.update((state) => ({
            ...state,
            selected_conversation: conversation,
            conversation_state: null,
            branches: [],
            messages: { phase: 'loading', error: null, items: [] },
            chat: { ...INITIAL_APP_STATE.chat },
        }));
        try {
            const [conversationState, branches] = await Promise.all([
                this.client.getConversationState(conversation.id),
                this.client.listBranches(conversation.id),
            ]);
            const messages = await this.client.listBranchMessages(
                conversationState.active_branch_id,
            );
            if (epoch !== this.conversationEpoch) return;
            this.update((state) => ({
                ...state,
                conversation_state: conversationState,
                branches,
                messages: { phase: 'ready', error: null, items: messages },
            }));
            this.resumePendingGeneration(messages);
        } catch (error: unknown) {
            if (epoch !== this.conversationEpoch) return;
            this.update((state) => ({
                ...state,
                messages: { phase: 'error', error: errorLabel(error), items: [] },
            }));
        }
    }

    async selectBranch(branchId: string): Promise<void> {
        const conversation = get(this.mutable).selected_conversation;
        if (conversation === null) return;
        const epoch = ++this.conversationEpoch;
        this.detachStream();
        this.update((state) => ({
            ...state,
            messages: { ...state.messages, phase: 'loading', error: null },
            chat: { ...INITIAL_APP_STATE.chat },
        }));
        try {
            const conversationState = await this.client.selectBranch(conversation.id, branchId);
            const messages = await this.client.listBranchMessages(branchId);
            if (epoch !== this.conversationEpoch) return;
            this.update((state) => ({
                ...state,
                conversation_state: conversationState,
                messages: { phase: 'ready', error: null, items: messages },
            }));
            this.resumePendingGeneration(messages);
        } catch (error: unknown) {
            if (epoch !== this.conversationEpoch) return;
            this.update((state) => ({
                ...state,
                messages: { ...state.messages, phase: 'error', error: errorLabel(error) },
            }));
        }
    }

    async createBranch(fromMessageId: string | null): Promise<void> {
        const conversation = get(this.mutable).selected_conversation;
        if (conversation === null) return;
        try {
            const branch = await this.client.createBranch(conversation.id, fromMessageId, null);
            this.update((state) => ({
                ...state,
                branches: [branch, ...state.branches.filter((item) => item.id !== branch.id)],
            }));
            await this.selectBranch(branch.id);
            this.announce('새 대화 분기를 만들었습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async setConversationMode(mode: ConversationMode): Promise<void> {
        const conversation = get(this.mutable).selected_conversation;
        if (conversation === null) return;
        try {
            const conversationState = await this.client.setConversationMode(conversation.id, mode);
            this.update((state) => ({ ...state, conversation_state: conversationState }));
            this.announce(
                mode === 'chat' ? '채팅 모드로 변경했습니다.' : '스토리 모드로 변경했습니다.',
            );
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    private generationSelection(state: LorepiaAppState): GenerationSelectionInput | null {
        const routeId = state.providers.workspace.settings.selected_model_route_id;
        const presetId = state.providers.workspace.settings.selected_generation_preset_id;
        if (routeId !== null && presetId !== null) {
            return {
                kind: 'target',
                target: {
                    model_route_id: routeId,
                    generation_preset_id: presetId,
                },
            };
        }
        const profileId = state.providers.workspace.settings.selected_provider_profile_id;
        return profileId === null
            ? null
            : { kind: 'legacy_profile', provider_profile_id: profileId };
    }

    async sendMessage(content: string): Promise<boolean> {
        const state = get(this.mutable);
        if (state.chat.active_generation_id !== null) {
            this.announce('진행 중인 생성을 취소한 뒤 새 메시지를 보내세요.');
            return false;
        }
        const conversation = state.selected_conversation;
        const conversationState = state.conversation_state;
        const selection = this.generationSelection(state);
        if (
            conversation === null ||
            conversationState === null ||
            selection === null ||
            content.trim().length === 0
        ) {
            this.announce('대화와 저장된 기본 모델을 확인한 뒤 메시지를 보내세요.');
            return false;
        }

        const branch = state.branches.find(
            (item) => item.id === conversationState.active_branch_id,
        );
        const { epoch, streamId } = this.prepareStream(
            conversation.id,
            conversationState.active_branch_id,
        );
        const buffered: ChatStreamItemDto[] = [];
        let ready = false;
        try {
            const started = await this.client.sendMessage(
                {
                    conversation_id: conversation.id,
                    branch_id: conversationState.active_branch_id,
                    expected_head: branch?.head_message_id ?? null,
                    mode: conversationState.selected_mode,
                    text: content.trim(),
                    selection,
                },
                streamId,
                (item) => {
                    if (epoch !== this.streamEpoch || this.activeStreamId !== streamId) {
                        void this.disposeStream(streamId);
                        return;
                    }
                    if (ready) this.acceptStreamItem(item, epoch, streamId);
                    else buffered.push(item);
                },
            );
            if (epoch !== this.streamEpoch || this.activeStreamId !== streamId) {
                void this.disposeStream(streamId);
                return false;
            }
            if (!this.streamVerifier?.bindGeneration(started.generation_id)) {
                await this.reconcile(started.generation_id, epoch, streamId, 'generation mismatch');
                return false;
            }
            this.update((current) => ({
                ...current,
                chat: {
                    ...current.chat,
                    phase: 'ready',
                    active_generation_id: started.generation_id,
                },
            }));
            ready = true;
            for (const item of buffered) {
                if (epoch !== this.streamEpoch || this.activeStreamId !== streamId) break;
                this.acceptStreamItem(item, epoch, streamId);
            }
            return true;
        } catch (error: unknown) {
            this.failStream(epoch, streamId, error);
            return false;
        }
    }

    async editUserMessage(messageId: string, replacementText: string): Promise<boolean> {
        const trimmed = replacementText.trim();
        if (trimmed.length === 0) return false;
        return this.startBranchGeneration((state, selection, streamId, onItem) => {
            const branchId = state.conversation_state?.active_branch_id;
            const conversationId = state.selected_conversation?.id;
            if (branchId === undefined || conversationId === undefined) return null;
            return this.client.editUserMessage(
                {
                    conversation_id: conversationId,
                    branch_id: branchId,
                    expected_head: this.activeBranchHead(state),
                    message_id: messageId,
                    replacement_text: trimmed,
                    selection,
                },
                streamId,
                onItem,
            );
        });
    }

    async regenerateAssistantMessage(messageId: string): Promise<boolean> {
        return this.startBranchGeneration((state, selection, streamId, onItem) => {
            const branchId = state.conversation_state?.active_branch_id;
            const conversationId = state.selected_conversation?.id;
            if (branchId === undefined || conversationId === undefined) return null;
            return this.client.regenerateAssistantMessage(
                {
                    conversation_id: conversationId,
                    branch_id: branchId,
                    expected_head: this.activeBranchHead(state),
                    message_id: messageId,
                    selection,
                },
                streamId,
                onItem,
            );
        });
    }

    private async startBranchGeneration(
        start: (
            state: LorepiaAppState,
            selection: GenerationSelectionInput,
            streamId: string,
            onItem: (item: ChatStreamItemDto) => void,
        ) => Promise<MessageActionGenerationDto> | null,
    ): Promise<boolean> {
        const state = get(this.mutable);
        if (state.chat.active_generation_id !== null) {
            this.announce('진행 중인 생성을 취소한 뒤 메시지를 변경하세요.');
            return false;
        }
        const conversation = state.selected_conversation;
        const selection = this.generationSelection(state);
        if (conversation === null || state.conversation_state === null || selection === null) {
            this.announce('대화와 저장된 기본 모델을 먼저 확인해 주세요.');
            return false;
        }

        const { epoch, streamId } = this.beginStreamReceiver();
        const buffered: ChatStreamItemDto[] = [];
        let ready = false;
        this.setChatLoading();
        try {
            const started = await start(state, selection, streamId, (item) => {
                if (epoch !== this.streamEpoch || this.activeStreamId !== streamId) {
                    void this.disposeStream(streamId);
                    return;
                }
                if (ready) this.acceptStreamItem(item, epoch, streamId);
                else buffered.push(item);
            });
            if (
                started === null ||
                epoch !== this.streamEpoch ||
                this.activeStreamId !== streamId
            ) {
                void this.disposeStream(streamId);
                return false;
            }

            const conversationState = await this.client.selectBranch(
                conversation.id,
                started.branch.id,
            );
            const messages = await this.client.listBranchMessages(started.branch.id);
            if (epoch !== this.streamEpoch || this.activeStreamId !== streamId) {
                void this.disposeStream(streamId);
                return false;
            }
            const pendingAssistant = this.pendingAssistantMessage(messages, started.generation_id);
            this.streamVerifier = new ChatStreamVerifier({
                conversationId: conversation.id,
                branchId: started.branch.id,
                generationId: started.generation_id,
                assistantMessageId: pendingAssistant?.id,
            });
            this.update((current) => ({
                ...current,
                conversation_state: conversationState,
                branches: [
                    started.branch,
                    ...current.branches.filter((item) => item.id !== started.branch.id),
                ],
                messages: { phase: 'ready', error: null, items: messages },
                chat: {
                    ...current.chat,
                    phase: 'ready',
                    active_generation_id: started.generation_id,
                },
            }));
            ready = true;
            for (const item of buffered) this.acceptStreamItem(item, epoch, streamId);
            return true;
        } catch (error: unknown) {
            this.failStream(epoch, streamId, error);
            return false;
        }
    }

    async removeMessage(messageId: string): Promise<void> {
        const state = get(this.mutable);
        const conversation = state.selected_conversation;
        const branchId = state.conversation_state?.active_branch_id;
        if (conversation === null || branchId === undefined) return;
        try {
            const branch = await this.client.removeMessageFromBranch({
                conversation_id: conversation.id,
                branch_id: branchId,
                expected_head: this.activeBranchHead(state),
                message_id: messageId,
            });
            const messages = await this.client.listBranchMessages(branch.id);
            this.update((current) => ({
                ...current,
                branches: current.branches.map((item) => (item.id === branch.id ? branch : item)),
                messages: { phase: 'ready', error: null, items: messages },
            }));
            this.announce('이 메시지부터 분기에서 제거했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    private activeBranchHead(state: LorepiaAppState): string | null {
        const activeBranchId = state.conversation_state?.active_branch_id;
        return state.branches.find((item) => item.id === activeBranchId)?.head_message_id ?? null;
    }

    private beginStreamReceiver(): { epoch: number; streamId: string } {
        this.detachStream();
        const streamId = this.activateStreamReceiver();
        return { epoch: this.streamEpoch, streamId };
    }

    private activateStreamReceiver(): string {
        const streamId = globalThis.crypto.randomUUID();
        this.activeStreamId = streamId;
        return streamId;
    }

    private prepareStream(
        conversationId: string,
        branchId: string,
        generationId?: string,
        assistantMessageId?: string,
        sequenceBaseline = 0,
    ): { epoch: number; streamId: string } {
        const active = this.beginStreamReceiver();
        this.streamVerifier = new ChatStreamVerifier({
            conversationId,
            branchId,
            generationId,
            assistantMessageId,
            sequenceBaseline,
        });
        this.setChatLoading(generationId ?? null);
        return active;
    }

    private setChatLoading(generationId: string | null = null): void {
        this.update((state) => ({
            ...state,
            chat: {
                phase: 'loading',
                error: null,
                active_generation_id: generationId,
                streaming_text: '',
                reasoning_text: '',
                reconcile_notice: null,
                usage_label: null,
            },
        }));
    }

    private failStream(epoch: number, streamId: string, error: unknown): void {
        void this.disposeStream(streamId);
        if (epoch !== this.streamEpoch) return;
        this.cancelPendingDeltas();
        this.update((state) => ({
            ...state,
            chat: {
                ...state.chat,
                phase: 'error',
                error: errorLabel(error),
                active_generation_id: null,
            },
        }));
    }

    private resumePendingGeneration(messages: MessageDto[]): void {
        const pending = this.pendingAssistantMessage(messages);
        if (pending?.generation_id === null || pending?.generation_id === undefined) return;
        const generationId = pending.generation_id;
        this.streamVerifier = null;
        this.cancelPendingDeltas();
        this.update((state) => ({
            ...state,
            chat: reattachmentUnavailableChatState(generationId),
        }));
    }

    private pendingAssistantMessage(
        messages: MessageDto[],
        generationId?: string,
    ): MessageDto | null {
        return (
            [...messages]
                .reverse()
                .find(
                    (message) =>
                        message.role === 'assistant' &&
                        message.status === 'pending' &&
                        message.generation_id !== null &&
                        (generationId === undefined || message.generation_id === generationId),
                ) ?? null
        );
    }

    private acceptStreamItem(item: ChatStreamItemDto, epoch: number, streamId: string): void {
        if (this.streamVerifier === null) return;
        const decision = this.streamVerifier.accept(item);
        if (decision.type === 'ignore') return;
        if (decision.type === 'reconcile') {
            this.cancelPendingDeltas();
            const generationId =
                decision.event?.generation_id ?? this.streamVerifier.getGenerationId();
            if (generationId !== null) {
                void this.reconcile(generationId, epoch, streamId, decision.reason);
            }
            return;
        }
        this.applyChatEvent(decision.event, epoch);
    }

    private applyChatEvent(event: ChatEventDto, epoch: number): void {
        if (event.kind.type === 'text_delta') {
            this.pendingTextDelta += event.kind.payload;
            this.scheduleDeltaFlush(epoch);
            return;
        }
        if (event.kind.type === 'reasoning_delta') {
            this.pendingReasoningDelta += event.kind.payload;
            this.scheduleDeltaFlush(epoch);
            return;
        }
        this.update((state) => {
            const chat = { ...state.chat, active_generation_id: event.generation_id };
            switch (event.kind.type) {
                case 'generation_started':
                    chat.phase = 'ready';
                    break;
                case 'usage_updated': {
                    const output = event.kind.payload.output_tokens;
                    chat.usage_label =
                        output === null ? null : `출력 ${output.toLocaleString()} 토큰`;
                    break;
                }
                case 'message_committed':
                    chat.reconcile_notice = '저장된 메시지를 확인하는 중입니다.';
                    break;
                case 'tool_call_started':
                    chat.reconcile_notice =
                        '모델이 도구 사용을 제안했습니다. 자동 실행하지 않습니다.';
                    break;
                case 'tool_call_arguments_delta':
                case 'tool_call_completed':
                case 'generation_cancelled':
                case 'generation_failed':
                case 'generation_finished':
                    break;
                case 'text_delta':
                case 'reasoning_delta':
                    break;
            }
            return { ...state, chat };
        });
    }

    private scheduleDeltaFlush(epoch: number): void {
        if (this.deltaFlushTimer !== null) return;
        this.deltaFlushTimer = setTimeout(() => {
            this.deltaFlushTimer = null;
            if (epoch !== this.streamEpoch) {
                this.pendingTextDelta = '';
                this.pendingReasoningDelta = '';
                return;
            }
            const text = this.pendingTextDelta;
            const reasoning = this.pendingReasoningDelta;
            this.pendingTextDelta = '';
            this.pendingReasoningDelta = '';
            if (text === '' && reasoning === '') return;
            this.update((state) => ({
                ...state,
                chat: {
                    ...state.chat,
                    streaming_text: state.chat.streaming_text + text,
                    reasoning_text: state.chat.reasoning_text + reasoning,
                },
            }));
        }, 16);
    }

    private cancelPendingDeltas(): void {
        if (this.deltaFlushTimer !== null) {
            clearTimeout(this.deltaFlushTimer);
            this.deltaFlushTimer = null;
        }
        this.pendingTextDelta = '';
        this.pendingReasoningDelta = '';
    }

    private async reconcile(
        generationId: string,
        epoch: number,
        streamId: string,
        reason: string,
    ): Promise<void> {
        if (this.reconcileInFlight) return;
        const conversation = get(this.mutable).selected_conversation;
        if (conversation === null) {
            void this.disposeStream(streamId);
            return;
        }
        this.reconcileInFlight = true;
        this.update((state) => ({
            ...state,
            chat: {
                ...state.chat,
                reconcile_notice: `스트림 상태를 복구하는 중입니다. (${reason})`,
            },
        }));
        try {
            await this.disposeStream(streamId);
            if (epoch !== this.streamEpoch) return;
            const conversationState = await this.client.getConversationState(conversation.id);
            const [branches, messages] = await Promise.all([
                this.client.listBranches(conversation.id),
                this.client.listBranchMessages(conversationState.active_branch_id),
            ]);
            if (epoch !== this.streamEpoch) return;
            const pendingAssistant = this.pendingAssistantMessage(messages, generationId);
            const running = pendingAssistant !== null;
            this.streamVerifier = null;
            this.update((state) => ({
                ...state,
                conversation_state: conversationState,
                branches,
                messages: { phase: 'ready', error: null, items: messages },
                chat: running
                    ? reattachmentUnavailableChatState(generationId)
                    : {
                          ...state.chat,
                          phase: 'idle',
                          error: null,
                          active_generation_id: null,
                          streaming_text: '',
                          reasoning_text: '',
                          reconcile_notice: null,
                      },
            }));
            if (!running) this.announce('대화가 저장된 상태와 동기화됐습니다.');
        } catch (error: unknown) {
            if (epoch !== this.streamEpoch) return;
            this.update((state) => ({
                ...state,
                chat: {
                    ...state.chat,
                    phase: 'error',
                    error: errorLabel(error),
                    reconcile_notice: '대화 새로고침이 필요합니다.',
                },
            }));
        } finally {
            if (epoch === this.streamEpoch) this.reconcileInFlight = false;
        }
    }

    async cancelGeneration(): Promise<void> {
        const generationId = get(this.mutable).chat.active_generation_id;
        if (generationId === null) return;
        try {
            await this.client.cancelGeneration(generationId);
            this.announce('생성 취소를 요청했습니다.');
        } catch (error: unknown) {
            const normalized = normalizeClientError(error);
            if (normalized.code !== 'not_found' && normalized.code !== 'cancelled') {
                this.announce(errorLabel(normalized));
            }
        }
    }

    async loadProviders(): Promise<void> {
        const epoch = ++this.providerEpoch;
        this.update((state) => ({
            ...state,
            providers: { ...state.providers, phase: 'loading', error: null },
        }));
        try {
            const [overview, discoveries, catalogStatus, catalogHistory] = await Promise.all([
                this.client.getProviderOverview(),
                this.client.listProviderDiscoveries(50),
                this.client.providerCatalogStatus(),
                this.client.providerCatalogHistory(50, null, null),
            ]);
            const routeGroups = await Promise.all(
                overview.connections.map((connection) =>
                    this.client.listModelRoutes(connection.id),
                ),
            );
            const routes = routeGroups.flat();
            const presetGroups = await Promise.all(
                routes.map((route) => this.client.listGenerationPresets(route.id)),
            );
            const credentialTargets: CredentialTargetDto[] = [
                ...overview.connections
                    .filter((connection) => connection.credential_binding_required)
                    .map((connection): CredentialTargetDto => ({
                        kind: 'connection',
                        connection_id: connection.id,
                    })),
                ...overview.legacy_profiles.map((profile): CredentialTargetDto => ({
                    kind: 'legacy_profile',
                    provider_profile_id: profile.id,
                })),
            ];
            const credentialStates = await Promise.all(
                credentialTargets.map(async (target) => ({
                    target,
                    status: (await this.client.credentialStatus(target)).status,
                })),
            );
            const modelSyncGroups = await Promise.all(
                overview.connections.map((connection) =>
                    this.client.listProviderModelSyncs(connection.id, 20),
                ),
            );
            if (epoch !== this.providerEpoch) return;
            this.update((state) => ({
                ...state,
                providers: {
                    phase: 'ready',
                    error: null,
                    workspace: {
                        templates: overview.templates,
                        connections: overview.connections,
                        legacy_profiles: overview.legacy_profiles,
                        routes,
                        presets: presetGroups.flat(),
                        settings: overview.settings,
                        credential_statuses: Object.fromEntries(
                            credentialStates.map(({ target, status }) => [
                                credentialKey(target),
                                status,
                            ]),
                        ),
                        request_preview: state.providers.workspace.request_preview,
                        selected_capability_model_route_id:
                            state.providers.workspace.selected_capability_model_route_id,
                        capability_observations: state.providers.workspace.capability_observations,
                        capability_parameter_specs:
                            state.providers.workspace.capability_parameter_specs,
                        effective_capability: state.providers.workspace.effective_capability,
                        model_sync_jobs: modelSyncGroups
                            .flat()
                            .sort((left, right) => right.updated_at.localeCompare(left.updated_at)),
                        selected_model_sync_job_id:
                            state.providers.workspace.selected_model_sync_job_id,
                        model_sync_event: state.providers.workspace.model_sync_event,
                        discoveries,
                        selected_discovery_id: state.providers.workspace.selected_discovery_id,
                        discovery_candidates: state.providers.workspace.discovery_candidates,
                        discovery_evidence: state.providers.workspace.discovery_evidence,
                        discovery_approvals: state.providers.workspace.discovery_approvals,
                        discovery_review: state.providers.workspace.discovery_review,
                        discovery_approval_proposal:
                            state.providers.workspace.discovery_approval_proposal,
                        discovery_review_proposal:
                            state.providers.workspace.discovery_review_proposal,
                        discovery_assistant_resume_boundary:
                            state.providers.workspace.discovery_assistant_resume_boundary,
                        discovery_assistant_host_action:
                            state.providers.workspace.discovery_assistant_host_action,
                        discovery_event: state.providers.workspace.discovery_event,
                        discovery_compensation_steps:
                            state.providers.workspace.discovery_compensation_steps,
                        discovery_recovery_results:
                            state.providers.workspace.discovery_recovery_results,
                        catalog_status: catalogStatus,
                        catalog_history: catalogHistory,
                        pending_catalog_import: state.providers.workspace.pending_catalog_import,
                        pending_catalog_rollback:
                            state.providers.workspace.pending_catalog_rollback,
                        catalog_diff: state.providers.workspace.catalog_diff,
                    },
                },
            }));
        } catch (error: unknown) {
            if (epoch !== this.providerEpoch) return;
            this.update((state) => ({
                ...state,
                providers: {
                    ...state.providers,
                    phase: 'error',
                    error: errorLabel(error),
                },
            }));
        }
    }

    async setProviderCredential(target: CredentialTargetDto, credential: string): Promise<boolean> {
        if (credential.length === 0) return false;
        try {
            await this.client.setCredential(target, credential);
            const status = await this.client.credentialStatus(target);
            this.update((state) => ({
                ...state,
                providers: {
                    ...state.providers,
                    workspace: {
                        ...state.providers.workspace,
                        credential_statuses: {
                            ...state.providers.workspace.credential_statuses,
                            [credentialKey(target)]: status.status,
                        },
                    },
                },
            }));
            this.announce('운영체제 자격증명 저장소에 저장했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async deleteProviderCredential(target: CredentialTargetDto): Promise<void> {
        try {
            await this.client.deleteCredential(target);
            this.update((state) => ({
                ...state,
                providers: {
                    ...state.providers,
                    workspace: {
                        ...state.providers.workspace,
                        credential_statuses: {
                            ...state.providers.workspace.credential_statuses,
                            [credentialKey(target)]: 'missing',
                        },
                    },
                },
            }));
            this.announce('저장된 자격증명을 삭제했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async createProviderConnection(
        input: CreateProviderConnectionInput,
        credential: string | null,
    ): Promise<boolean> {
        try {
            await this.client.createProviderConnection(input, credential);
            await this.loadProviders();
            this.announce('프로바이더 연결을 만들었습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async updateProviderConnection(input: UpdateProviderConnectionInput): Promise<boolean> {
        try {
            await this.client.upsertProviderConnection(input);
            await this.loadProviders();
            this.announce('프로바이더 연결을 수정했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async deleteProviderConnection(connectionId: string): Promise<boolean> {
        try {
            await this.client.deleteProviderConnection(connectionId);
            await this.loadProviders();
            this.announce('프로바이더 연결과 연결된 자격증명을 삭제했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async upsertProviderModelRoute(input: UpsertModelRouteInput): Promise<boolean> {
        try {
            await this.client.upsertModelRoute(input);
            await this.loadProviders();
            this.announce('모델 라우트를 저장했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async deleteProviderModelRoute(modelRouteId: string): Promise<boolean> {
        try {
            await this.client.deleteModelRoute(modelRouteId);
            await this.loadProviders();
            this.announce('모델 라우트를 삭제했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async upsertProviderGenerationPreset(input: GenerationPresetInput): Promise<boolean> {
        try {
            await this.client.upsertGenerationPreset(input);
            await this.loadProviders();
            this.announce('생성 프리셋을 저장했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async deleteProviderGenerationPreset(generationPresetId: string): Promise<boolean> {
        try {
            await this.client.deleteGenerationPreset(generationPresetId);
            await this.loadProviders();
            this.announce('생성 프리셋을 삭제했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async validateProviderGenerationPresetCandidate(
        input: GenerationPresetInput,
    ): Promise<boolean> {
        try {
            await this.client.validateGenerationPresetCandidate(input);
            this.announce('프리셋 후보가 유효합니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async previewProviderRequestCandidate(input: GenerationPresetInput): Promise<void> {
        try {
            const preview = await this.client.previewProviderRequestCandidate(input);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                request_preview: preview,
            }));
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async previewSelectedProviderRequest(): Promise<void> {
        const settings = get(this.mutable).providers.workspace.settings;
        if (
            settings.selected_model_route_id === null ||
            settings.selected_generation_preset_id === null
        ) {
            this.announce('저장된 기본 모델 라우트가 없습니다.');
            return;
        }
        try {
            const preview = await this.client.previewProviderRequest({
                model_route_id: settings.selected_model_route_id,
                generation_preset_id: settings.selected_generation_preset_id,
            });
            this.update((state) => ({
                ...state,
                providers: {
                    ...state.providers,
                    workspace: { ...state.providers.workspace, request_preview: preview },
                },
            }));
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    private updateProviderWorkspace(
        updater: (workspace: ProviderWorkspaceDto) => ProviderWorkspaceDto,
    ): void {
        this.update((state) => ({
            ...state,
            providers: {
                ...state.providers,
                workspace: updater(state.providers.workspace),
            },
        }));
    }

    private storeModelSyncJob(job: ModelSyncJobDto): void {
        this.updateProviderWorkspace((workspace) => ({
            ...workspace,
            model_sync_jobs: [
                job,
                ...workspace.model_sync_jobs.filter((candidate) => candidate.id !== job.id),
            ],
            selected_model_sync_job_id: job.id,
        }));
    }

    private storeDiscoverySession(session: ProviderDiscoverySessionDto): void {
        this.updateProviderWorkspace((workspace) => ({
            ...workspace,
            discoveries: [
                session,
                ...workspace.discoveries.filter((candidate) => candidate.id !== session.id),
            ],
            selected_discovery_id: session.id,
        }));
    }

    async loadProviderCapabilities(modelRouteId: string): Promise<void> {
        if (modelRouteId === '') return;
        try {
            const [observations, parameterSpecs] = await Promise.all([
                this.client.listCapabilityObservations(modelRouteId),
                this.client.effectiveParameterSpecs(modelRouteId),
            ]);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                selected_capability_model_route_id: modelRouteId,
                capability_observations: observations,
                capability_parameter_specs: parameterSpecs,
                effective_capability: null,
            }));
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async inspectEffectiveProviderCapability(key: CapabilityKeyInput): Promise<void> {
        const routeId = get(this.mutable).providers.workspace.selected_capability_model_route_id;
        if (routeId === null) return;
        try {
            const capability = await this.client.effectiveCapability(routeId, key);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                effective_capability: capability,
            }));
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async upsertProviderCapabilityOverride(input: UpsertCapabilityOverrideInput): Promise<boolean> {
        try {
            await this.client.upsertUserCapabilityOverride(input);
            await this.loadProviderCapabilities(input.model_route_id);
            this.announce('사용자 capability override를 저장했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async deleteProviderCapabilityOverride(observationId: string): Promise<void> {
        const routeId = get(this.mutable).providers.workspace.selected_capability_model_route_id;
        if (routeId === null) return;
        try {
            await this.client.deleteUserCapabilityOverride(routeId, observationId);
            await this.loadProviderCapabilities(routeId);
            this.announce('사용자 capability override를 삭제했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async selectProviderGenerationTarget(
        modelRouteId: string | null,
        generationPresetId: string | null,
    ): Promise<boolean> {
        if ((modelRouteId === null) !== (generationPresetId === null)) return false;
        try {
            const settings = await this.client.selectGenerationTarget(
                modelRouteId === null || generationPresetId === null
                    ? null
                    : {
                          model_route_id: modelRouteId,
                          generation_preset_id: generationPresetId,
                      },
            );
            this.updateProviderWorkspace((workspace) => ({ ...workspace, settings }));
            this.announce(
                modelRouteId === null
                    ? '기본 생성 대상을 해제했습니다.'
                    : '기본 생성 대상을 저장했습니다.',
            );
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async setPreservePartialGenerations(preserve: boolean): Promise<boolean> {
        const current = get(this.mutable).providers.workspace.settings;
        try {
            const settings = await this.client.updateSettings({
                ...current,
                preserve_partial_generations: preserve,
            });
            this.updateProviderWorkspace((workspace) => ({ ...workspace, settings }));
            this.announce('부분 생성 보존 설정을 저장했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async startProviderModelSync(connectionId: string): Promise<void> {
        try {
            const started = await this.client.startProviderModelSync(connectionId);
            await this.refreshProviderModelSync(started.job_id);
            this.announce('모델 동기화를 시작했습니다. 자동 승인하지 않습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async refreshProviderModelSync(jobId: string): Promise<void> {
        try {
            const [job, events] = await Promise.all([
                this.client.getProviderModelSync(jobId),
                this.client.pollProviderModelSyncEvents(jobId, 100),
            ]);
            const latestEvent = events.at(-1) ?? null;
            for (const event of events) {
                await this.client.ackProviderModelSyncEvent(jobId, event.sequence);
            }
            this.storeModelSyncJob(job);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                model_sync_event: latestEvent ?? workspace.model_sync_event,
            }));
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async approveProviderModelSync(jobId: string): Promise<void> {
        const job = get(this.mutable).providers.workspace.model_sync_jobs.find(
            (candidate) => candidate.id === jobId,
        );
        if (job?.review === null || job?.review === undefined) return;
        try {
            this.storeModelSyncJob(
                await this.client.approveProviderModelSync(jobId, job.review.sha256),
            );
            await this.loadProviders();
            this.announce('검토한 정확한 모델 동기화 변경을 적용했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async cancelProviderModelSync(jobId: string): Promise<void> {
        try {
            this.storeModelSyncJob(await this.client.cancelProviderModelSync(jobId));
            this.announce('모델 동기화를 취소했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async beginProviderDiscovery(
        request:
            | { kind: 'site'; input: BeginProviderDiscoveryInput }
            | { kind: 'curl'; input: BeginProviderDiscoveryCurlInput; curl: string },
    ): Promise<boolean> {
        try {
            const session =
                request.kind === 'site'
                    ? await this.client.beginProviderDiscovery(request.input)
                    : await this.client.beginProviderDiscoveryCurl(request.input, request.curl);
            this.storeDiscoverySession(session);
            await this.refreshProviderDiscovery(session.id);
            await this.pollSelectedProviderDiscoveryEvents();
            this.announce('프로바이더 탐색을 시작했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async refreshProviderDiscovery(sessionId: string): Promise<void> {
        try {
            const [
                session,
                candidates,
                evidence,
                approvals,
                review,
                approvalProposal,
                reviewProposal,
                assistantResumeBoundary,
            ] = await Promise.all([
                this.client.getProviderDiscovery(sessionId),
                this.client.listProviderDiscoveryCandidates(sessionId),
                this.client.listProviderDiscoveryEvidence(sessionId),
                this.client.listProviderDiscoveryApprovals(sessionId),
                this.client.getProviderDiscoveryReview(sessionId),
                this.client.getProviderDiscoveryApprovalProposal(sessionId),
                this.client.getProviderDiscoveryReviewProposal(sessionId),
                this.client.getProviderDiscoveryAssistantResumeBoundary(sessionId),
            ]);
            const compensationSteps =
                session.commit_attempt_id === null
                    ? []
                    : await this.client.listProviderDiscoveryCompensationSteps(
                          session.commit_attempt_id,
                      );
            this.storeDiscoverySession(session);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                selected_discovery_id: session.id,
                discovery_candidates: candidates,
                discovery_evidence: evidence,
                discovery_approvals: approvals,
                discovery_review: review,
                discovery_approval_proposal: approvalProposal,
                discovery_review_proposal: reviewProposal,
                discovery_assistant_resume_boundary: assistantResumeBoundary,
                discovery_compensation_steps: compensationSteps,
            }));
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    private selectedProviderDiscoveryId(): string | null {
        return get(this.mutable).providers.workspace.selected_discovery_id;
    }

    async runProviderDiscoveryAssistant(): Promise<void> {
        const sessionId = this.selectedProviderDiscoveryId();
        if (sessionId === null) return;
        try {
            const hostAction = await this.client.runProviderDiscoveryAssistantTurn(sessionId);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                discovery_assistant_host_action: hostAction,
            }));
            await this.refreshProviderDiscovery(sessionId);
            this.announce('설정 도우미 결과가 검토 대기 상태로 도착했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async resumeProviderDiscoveryAssistantCoreHostAction(): Promise<void> {
        await this.mutateSelectedDiscoveryAssistant((sessionId) =>
            this.client.resumeProviderDiscoveryAssistantCoreHostAction(sessionId),
        );
    }

    async approveProviderDiscoveryAssistantRetry(): Promise<void> {
        await this.mutateSelectedDiscoveryAssistant((sessionId) =>
            this.client.approveProviderDiscoveryAssistantRetry(sessionId),
        );
    }

    async requestProviderDiscoveryAssistantRevision(): Promise<void> {
        await this.mutateSelectedDiscoveryAssistant((sessionId) =>
            this.client.requestProviderDiscoveryAssistantRevision(sessionId),
        );
    }

    async acceptProviderDiscoveryAssistantDraft(): Promise<void> {
        await this.mutateSelectedDiscoveryAssistant((sessionId) =>
            this.client.acceptProviderDiscoveryAssistantDraft(sessionId),
        );
    }

    async recordProviderDiscoveryAssistantFailure(
        kind: DiscoveryAssistantFailureKindInput,
        retryable: boolean,
    ): Promise<void> {
        await this.mutateSelectedDiscoveryAssistant((sessionId) =>
            this.client.recordProviderDiscoveryAssistantFailure(sessionId, kind, retryable),
        );
    }

    async interruptProviderDiscoveryAssistant(
        outcome: DiscoveryAssistantInterruptionOutcomeInput,
    ): Promise<void> {
        await this.mutateSelectedDiscoveryAssistant((sessionId) =>
            this.client.interruptProviderDiscoveryAssistant(sessionId, outcome),
        );
    }

    async restartProviderDiscoveryAssistantAfterInterruption(): Promise<void> {
        await this.mutateSelectedDiscoveryAssistant((sessionId) =>
            this.client.restartProviderDiscoveryAssistantAfterInterruption(sessionId),
        );
    }

    private async mutateSelectedDiscoveryAssistant(
        action: (sessionId: string) => Promise<ProviderDiscoverySessionDto>,
    ): Promise<void> {
        const sessionId = this.selectedProviderDiscoveryId();
        if (sessionId === null) return;
        try {
            this.storeDiscoverySession(await action(sessionId));
            await this.refreshProviderDiscovery(sessionId);
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async pollSelectedProviderDiscoveryEvents(): Promise<void> {
        const selectedId = get(this.mutable).providers.workspace.selected_discovery_id;
        if (selectedId === null) return;
        try {
            const events = (await this.client.pollProviderDiscoveryEvents(100)).filter(
                (item) => item.event.session_id === selectedId,
            );
            for (const item of events) {
                await this.client.ackProviderDiscoveryEvent(item.event.id);
            }
            const latest = events.at(-1)?.event ?? null;
            if (latest !== null) {
                this.updateProviderWorkspace((workspace) => ({
                    ...workspace,
                    discovery_event: latest,
                }));
            }
            await this.refreshProviderDiscovery(selectedId);
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async continueProviderDiscovery(
        action: ContinueProviderDiscoveryActionInput,
    ): Promise<boolean> {
        const workspace = get(this.mutable).providers.workspace;
        const session = workspace.discoveries.find(
            (candidate) => candidate.id === workspace.selected_discovery_id,
        );
        const event = workspace.discovery_event;
        if (session === undefined || event?.session_id !== session.id) {
            this.announce('먼저 최신 탐색 이벤트를 확인해 주세요.');
            return false;
        }
        try {
            const next = await this.client.continueProviderDiscovery({
                session_id: session.id,
                action_id: event.action_id,
                expected_revision: session.revision,
                action,
            });
            this.storeDiscoverySession(next);
            await this.refreshProviderDiscovery(next.id);
            await this.pollSelectedProviderDiscoveryEvents();
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async supplyProviderDiscoveryDocumentEvidence(documentUrl: string): Promise<boolean> {
        const workspace = get(this.mutable).providers.workspace;
        const session = workspace.discoveries.find(
            (candidate) => candidate.id === workspace.selected_discovery_id,
        );
        if (session === undefined || documentUrl.trim() === '') return false;
        try {
            this.storeDiscoverySession(
                await this.client.supplyProviderDiscoveryDocumentEvidence(
                    session.id,
                    session.revision,
                    documentUrl.trim(),
                ),
            );
            await this.refreshProviderDiscovery(session.id);
            await this.pollSelectedProviderDiscoveryEvents();
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async supplyProviderDiscoveryCurlEvidence(curl: string): Promise<boolean> {
        const workspace = get(this.mutable).providers.workspace;
        const session = workspace.discoveries.find(
            (candidate) => candidate.id === workspace.selected_discovery_id,
        );
        if (session === undefined || curl.trim() === '') return false;
        try {
            this.storeDiscoverySession(
                await this.client.supplyProviderDiscoveryCurlEvidence(
                    session.id,
                    session.revision,
                    curl,
                ),
            );
            await this.refreshProviderDiscovery(session.id);
            await this.pollSelectedProviderDiscoveryEvents();
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async cancelProviderDiscovery(): Promise<void> {
        const workspace = get(this.mutable).providers.workspace;
        const session = workspace.discoveries.find(
            (candidate) => candidate.id === workspace.selected_discovery_id,
        );
        if (session === undefined) return;
        try {
            this.storeDiscoverySession(
                await this.client.cancelProviderDiscovery(session.id, session.revision),
            );
            await this.refreshProviderDiscovery(session.id);
            this.announce('프로바이더 탐색을 취소했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async commitProviderDiscovery(credential: string | null): Promise<boolean> {
        const sessionId = get(this.mutable).providers.workspace.selected_discovery_id;
        if (sessionId === null) return false;
        try {
            await this.client.commitProviderDiscovery(sessionId, credential);
            await this.loadProviders();
            this.announce('검토·승인된 프로바이더 연결을 저장했습니다.');
            return true;
        } catch (error: unknown) {
            this.announce(errorLabel(error));
            return false;
        }
    }

    async recoverProviderDiscoveries(): Promise<void> {
        try {
            const results = await this.client.recoverProviderDiscovery();
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                discovery_recovery_results: results,
            }));
            await this.loadProviders();
            this.announce(
                results.length === 0
                    ? '복구가 필요한 탐색 작업이 없습니다.'
                    : `${String(results.length)}개 탐색 작업을 복구했습니다.`,
            );
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async continueProviderDiscoveryCompensation(resume: boolean): Promise<void> {
        const sessionId = get(this.mutable).providers.workspace.selected_discovery_id;
        if (sessionId === null) return;
        try {
            const session = resume
                ? await this.client.resumeProviderDiscoveryCompensation(sessionId)
                : await this.client.continueProviderDiscoveryCompensation(sessionId);
            this.storeDiscoverySession(session);
            await this.refreshProviderDiscovery(sessionId);
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async pickProviderCatalogImport(): Promise<void> {
        try {
            const ticket = await this.client.pickProviderCatalogImport();
            if (ticket === null) return;
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                pending_catalog_import: ticket,
            }));
            this.announce('서명된 카탈로그 변경 계획을 검토해 주세요.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async activateProviderCatalogImport(): Promise<void> {
        const ticket = get(this.mutable).providers.workspace.pending_catalog_import;
        if (ticket === null) return;
        try {
            const result = await this.client.activateProviderCatalogImport(ticket.ticket_id);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                catalog_status: result.status,
                pending_catalog_import: null,
                catalog_diff: result.diff,
            }));
            await this.loadProviders();
            this.announce('검토한 카탈로그 변경을 적용했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async discardProviderCatalogImport(): Promise<void> {
        const ticket = get(this.mutable).providers.workspace.pending_catalog_import;
        if (ticket === null) return;
        try {
            await this.client.discardProviderCatalogImport(ticket.ticket_id);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                pending_catalog_import: null,
            }));
            this.announce('카탈로그 가져오기 계획을 폐기했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async diffProviderCatalogRevisions(fromRevision: number, toRevision: number): Promise<void> {
        try {
            const catalogDiff = await this.client.diffProviderCatalogRevisions(
                fromRevision,
                toRevision,
            );
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                catalog_diff: catalogDiff,
            }));
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async prepareProviderCatalogRollback(targetRevision: number): Promise<void> {
        try {
            const plan = await this.client.prepareProviderCatalogRollback(targetRevision);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                pending_catalog_rollback: plan,
                catalog_diff: plan.catalog_plan.diff,
            }));
            this.announce('정확한 롤백 계획을 검토해 주세요.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    async activateProviderCatalogRollback(plan?: ProviderCatalogRollbackPlanDto): Promise<void> {
        const exactPlan = plan ?? get(this.mutable).providers.workspace.pending_catalog_rollback;
        if (exactPlan === null) return;
        try {
            const result = await this.client.activateProviderCatalogRollback(exactPlan);
            this.updateProviderWorkspace((workspace) => ({
                ...workspace,
                catalog_status: result.status,
                pending_catalog_rollback: null,
                catalog_diff: exactPlan.catalog_plan.diff,
            }));
            await this.loadProviders();
            this.announce('검토한 카탈로그 리비전으로 롤백했습니다.');
        } catch (error: unknown) {
            this.announce(errorLabel(error));
        }
    }

    private async disposeStream(streamId: string): Promise<void> {
        if (this.activeStreamId === streamId) this.activeStreamId = null;
        try {
            await this.client.disposeChatStream(streamId);
        } catch {
            // Receiver disposal is idempotent and must not mask the product action.
        }
    }

    private detachStream(): void {
        const streamId = this.activeStreamId;
        this.activeStreamId = null;
        ++this.streamEpoch;
        this.streamVerifier = null;
        this.reconcileInFlight = false;
        this.cancelPendingDeltas();
        if (streamId !== null) void this.disposeStream(streamId);
    }

    destroy(): void {
        ++this.appEpoch;
        ++this.conversationEpoch;
        ++this.providerEpoch;
        this.detachStream();
    }
}

export type {
    GenerationPresetDto,
    ModelRouteDto,
    ProviderConnectionDto,
    ProviderProfileDto,
    ProviderTemplateDto,
};
