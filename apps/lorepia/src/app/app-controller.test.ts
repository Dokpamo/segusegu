import { get } from 'svelte/store';
import { afterEach, describe, expect, it, vi } from 'vitest';

import type {
    CharacterDto,
    ChatEventDto,
    ChatStreamItemDto,
    ConversationBranchDto,
    ConversationDto,
    ConversationStateDto,
    LorepiaClient,
    MessageDto,
} from '../lib/ipc/contracts';
import { LorepiaAppController } from './app-controller';

const character: CharacterDto = {
    id: 'character-1',
    name: '라온',
    description: '',
    source_hash: 'synthetic',
    avatar_asset_id: null,
    created_at: '2026-08-02T00:00:00Z',
};

const conversation: ConversationDto = {
    id: 'conversation-1',
    character_id: character.id,
    title: '첫 대화',
    created_at: '2026-08-02T00:00:00Z',
    updated_at: '2026-08-02T00:00:00Z',
};

const conversationState: ConversationStateDto = {
    conversation_id: conversation.id,
    active_branch_id: 'branch-1',
    selected_mode: 'chat',
    updated_at: '2026-08-02T00:00:00Z',
};

const branch: ConversationBranchDto = {
    id: conversationState.active_branch_id,
    conversation_id: conversation.id,
    title: null,
    fork_message_id: null,
    head_message_id: null,
    created_at: '2026-08-02T00:00:00Z',
    updated_at: '2026-08-02T00:00:00Z',
};

function mockClient(overrides: Partial<LorepiaClient>): LorepiaClient {
    const defaults: Partial<LorepiaClient> = {
        bootstrapSnapshot: () =>
            Promise.resolve({
                core_api_version: 8,
                chat_event_version: 4,
                health: {
                    core_version: '0.1.0',
                    database_open: true,
                    schema_version: 1,
                    data_root_writable: true,
                    staging_writable: true,
                    recovery_pending: false,
                    active_jobs: 0,
                },
            }),
        listCharacters: () => Promise.resolve([character]),
        getProviderOverview: () =>
            Promise.resolve({
                templates: [],
                connections: [],
                legacy_profiles: [],
                settings: {
                    preserve_partial_generations: true,
                    selected_provider_profile_id: null,
                    selected_model_route_id: 'route-1',
                    selected_generation_preset_id: 'preset-1',
                },
            }),
        listProviderDiscoveries: () => Promise.resolve([]),
        providerCatalogStatus: () =>
            Promise.resolve({
                status_schema_version: 1,
                state_version: 1,
                active_revision: 1,
                active_snapshot_sha256: 'synthetic-active',
                bundled_baseline_sha256: 'synthetic-baseline',
                snapshot_count: 1,
                signed_update_count: 0,
                highest_accepted_revision: 1,
                latest_issued_at: null,
                active_signed_revisions: [],
            }),
        providerCatalogHistory: () =>
            Promise.resolve({
                history_schema_version: 1,
                active_revision: 1,
                revisions: [],
                activations: [],
                next_before_revision: null,
                next_before_state_version: null,
            }),
        listConversations: () => Promise.resolve([conversation]),
        getConversationState: () => Promise.resolve(conversationState),
        listBranches: () => Promise.resolve([branch]),
        listBranchMessages: () => Promise.resolve([]),
        disposeChatStream: () => Promise.resolve(false),
    };
    return new Proxy({ ...defaults, ...overrides } as LorepiaClient, {
        get(target, property, receiver) {
            const value = Reflect.get(target, property, receiver) as unknown;
            if (typeof value === 'function') return value;
            throw new Error(`Unexpected client method: ${String(property)}`);
        },
    });
}

afterEach(() => {
    vi.useRealTimers();
});

function textEvent(sequence: number, payload = '늦게 도착한 조각'): ChatStreamItemDto {
    const event: ChatEventDto = {
        event_version: 4,
        generation_id: 'generation-1',
        conversation_id: conversation.id,
        branch_id: branch.id,
        assistant_message_id: 'message-1',
        sequence,
        emitted_at: '2026-08-02T00:00:00Z',
        kind: { type: 'text_delta', payload },
    };
    return { type: 'event', payload: event };
}

describe('LorepiaAppController stream lifecycle', () => {
    it('disposes the receiver and detaches a late callback after destroy', async () => {
        let onItem: ((item: ChatStreamItemDto) => void) | null = null;
        let streamId: string | null = null;
        const disposeChatStream = vi.fn((streamId: string) => Promise.resolve(streamId.length > 0));
        const client = mockClient({
            sendMessage: (_input, id, listener) => {
                streamId = id;
                onItem = listener;
                return Promise.resolve({ generation_id: 'generation-1' });
            },
            disposeChatStream,
        });
        const controller = new LorepiaAppController(client);

        await controller.start();
        await controller.selectCharacter(character);
        await controller.selectConversation(conversation);
        expect(await controller.sendMessage('안녕')).toBe(true);
        expect(onItem).not.toBeNull();

        controller.destroy();
        expect(streamId).not.toBeNull();
        expect(disposeChatStream).toHaveBeenCalledWith(streamId);
        const detachedListener = onItem as unknown as (item: ChatStreamItemDto) => void;
        detachedListener(textEvent(1));

        expect(get(controller.state).chat.streaming_text).toBe('');
    });

    it('batches adjacent text deltas into one short-interval state update', async () => {
        vi.useFakeTimers();
        let onItem: ((item: ChatStreamItemDto) => void) | null = null;
        const client = mockClient({
            sendMessage: (_input, _streamId, listener) => {
                onItem = listener;
                return Promise.resolve({ generation_id: 'generation-1' });
            },
        });
        const controller = new LorepiaAppController(client);
        await controller.start();
        await controller.selectCharacter(character);
        await controller.selectConversation(conversation);
        await controller.sendMessage('안녕');

        const listener = onItem as unknown as (item: ChatStreamItemDto) => void;
        listener(textEvent(1, '첫째'));
        listener(textEvent(2, '둘째'));
        expect(get(controller.state).chat.streaming_text).toBe('');

        await vi.advanceTimersByTimeAsync(16);
        expect(get(controller.state).chat.streaming_text).toBe('첫째둘째');
        controller.destroy();
    });

    it('disposes the receiver when the stream command fails', async () => {
        let streamId: string | null = null;
        const disposeChatStream = vi.fn((streamId: string) => Promise.resolve(streamId.length > 0));
        const client = mockClient({
            sendMessage: (_input, id) => {
                streamId = id;
                return Promise.reject(new Error('invoke failed'));
            },
            disposeChatStream,
        });
        const controller = new LorepiaAppController(client);

        await controller.start();
        await controller.selectCharacter(character);
        await controller.selectConversation(conversation);

        expect(await controller.sendMessage('안녕')).toBe(false);
        expect(disposeChatStream).toHaveBeenCalledWith(streamId);
        expect(get(controller.state).chat.phase).toBe('error');
    });

    it('idempotently disposes the stale receiver again after an epoch mismatch', async () => {
        let streamId: string | null = null;
        let resolveStarted: ((value: { generation_id: string }) => void) | null = null;
        const disposeChatStream = vi.fn((streamId: string) => Promise.resolve(streamId.length > 0));
        const client = mockClient({
            sendMessage: (_input, id) => {
                streamId = id;
                return new Promise((resolve) => {
                    resolveStarted = resolve;
                });
            },
            disposeChatStream,
        });
        const controller = new LorepiaAppController(client);

        await controller.start();
        await controller.selectCharacter(character);
        await controller.selectConversation(conversation);
        const sending = controller.sendMessage('안녕');
        expect(streamId).not.toBeNull();

        controller.destroy();
        const complete = resolveStarted as unknown as (value: { generation_id: string }) => void;
        complete({ generation_id: 'generation-1' });

        await expect(sending).resolves.toBe(false);
        expect(disposeChatStream.mock.calls.filter(([id]) => id === streamId)).toHaveLength(2);
    });

    it('keeps persisted pending generations blocked without attempting reattachment', async () => {
        const pending: MessageDto = {
            id: 'message-1',
            conversation_id: conversation.id,
            parent_id: null,
            role: 'assistant',
            content: '저장된 부분 응답',
            status: 'pending',
            generation_id: 'generation-1',
            created_at: '2026-08-02T00:00:00Z',
        };
        const subscribeGeneration = vi.fn(() => Promise.resolve());
        const sendMessage = vi.fn(() =>
            Promise.resolve({ generation_id: 'unexpected-generation' }),
        );
        const editUserMessage = vi.fn(() =>
            Promise.resolve({ branch, generation_id: 'unexpected-generation' }),
        );
        const regenerateAssistantMessage = vi.fn(() =>
            Promise.resolve({ branch, generation_id: 'unexpected-generation' }),
        );
        const client = mockClient({
            listBranchMessages: () => Promise.resolve([pending]),
            subscribeGeneration,
            selectBranch: () => Promise.resolve(conversationState),
            sendMessage,
            editUserMessage,
            regenerateAssistantMessage,
        });
        const controller = new LorepiaAppController(client);

        await controller.start();
        await controller.selectCharacter(character);
        await controller.selectConversation(conversation);
        expect(subscribeGeneration).not.toHaveBeenCalled();
        expect(get(controller.state).chat).toMatchObject({
            phase: 'error',
            active_generation_id: 'generation-1',
        });
        expect(get(controller.state).chat.error).toContain('다시 연결할 수 없습니다');
        await expect(controller.sendMessage('새 메시지')).resolves.toBe(false);
        await expect(controller.editUserMessage('message-user', '고친 메시지')).resolves.toBe(
            false,
        );
        await expect(controller.regenerateAssistantMessage('message-1')).resolves.toBe(false);
        expect(sendMessage).not.toHaveBeenCalled();
        expect(editUserMessage).not.toHaveBeenCalled();
        expect(regenerateAssistantMessage).not.toHaveBeenCalled();

        await controller.selectConversation(conversation);
        await controller.selectBranch(branch.id);
        expect(subscribeGeneration).not.toHaveBeenCalled();
        controller.destroy();
    });

    it('fails closed instead of reattaching after a live stream needs reconciliation', async () => {
        const pending: MessageDto = {
            id: 'message-1',
            conversation_id: conversation.id,
            parent_id: null,
            role: 'assistant',
            content: '저장된 부분 응답',
            status: 'pending',
            generation_id: 'generation-1',
            created_at: '2026-08-02T00:00:00Z',
        };
        let listener: ((item: ChatStreamItemDto) => void) | null = null;
        let messageReadCount = 0;
        const subscribeGeneration = vi.fn(() => Promise.resolve());
        const disposeChatStream = vi.fn((streamId: string) => Promise.resolve(streamId.length > 0));
        const client = mockClient({
            listBranchMessages: () => Promise.resolve(messageReadCount++ === 0 ? [] : [pending]),
            sendMessage: (_input, _streamId, onItem) => {
                listener = onItem;
                return Promise.resolve({ generation_id: 'generation-1' });
            },
            subscribeGeneration,
            disposeChatStream,
        });
        const controller = new LorepiaAppController(client);

        await controller.start();
        await controller.selectCharacter(character);
        await controller.selectConversation(conversation);
        expect(await controller.sendMessage('안녕')).toBe(true);

        const activeListener = listener as unknown as (item: ChatStreamItemDto) => void;
        activeListener({
            type: 'reconciliation_required',
            payload: {
                reason: 'sequence_gap',
                generation_id: 'generation-1',
                conversation_id: conversation.id,
                branch_id: branch.id,
                last_sequence: 0,
                observed_sequence: 7,
                dropped_events: null,
                supported_event_version: 4,
            },
        });

        await vi.waitFor(() => expect(get(controller.state).chat.phase).toBe('error'));
        expect(subscribeGeneration).not.toHaveBeenCalled();
        expect(disposeChatStream).toHaveBeenCalledOnce();
        expect(get(controller.state).chat.active_generation_id).toBe('generation-1');
        expect(get(controller.state).chat.error).toContain('다시 연결할 수 없습니다');
        controller.destroy();
    });

    it('reconciles a closed stream or marker received before the send response', async () => {
        const earlyItems: ChatStreamItemDto[] = [
            { type: 'closed' },
            {
                type: 'reconciliation_required',
                payload: {
                    reason: 'sequence_gap',
                    generation_id: 'generation-1',
                    conversation_id: conversation.id,
                    branch_id: branch.id,
                    last_sequence: 0,
                    observed_sequence: 2,
                    dropped_events: null,
                    supported_event_version: 4,
                },
            },
        ];

        for (const earlyItem of earlyItems) {
            const disposeChatStream = vi.fn((streamId: string) =>
                Promise.resolve(streamId.length > 0),
            );
            const client = mockClient({
                sendMessage: (_input, _streamId, listener) => {
                    listener(earlyItem);
                    return Promise.resolve({ generation_id: 'generation-1' });
                },
                disposeChatStream,
            });
            const controller = new LorepiaAppController(client);

            await controller.start();
            await controller.selectCharacter(character);
            await controller.selectConversation(conversation);
            expect(await controller.sendMessage('안녕')).toBe(true);

            await vi.waitFor(() => expect(get(controller.state).chat.phase).toBe('idle'));
            expect(get(controller.state).chat.active_generation_id).toBeNull();
            expect(disposeChatStream).toHaveBeenCalledTimes(1);
            controller.destroy();
        }
    });

    it('uses the refreshed branch head for the next send after terminal reconciliation', async () => {
        const refreshedBranch: ConversationBranchDto = {
            ...branch,
            head_message_id: 'message-committed',
            updated_at: '2026-08-02T00:00:01Z',
        };
        const sentHeads: (string | null)[] = [];
        const listeners: ((item: ChatStreamItemDto) => void)[] = [];
        const listBranches = vi
            .fn<() => Promise<ConversationBranchDto[]>>()
            .mockResolvedValueOnce([branch])
            .mockResolvedValue([refreshedBranch]);
        const client = mockClient({
            listBranches,
            sendMessage: (input, _streamId, listener) => {
                sentHeads.push(input.expected_head);
                listeners.push(listener);
                return Promise.resolve({
                    generation_id: `generation-${String(sentHeads.length)}`,
                });
            },
        });
        const controller = new LorepiaAppController(client);

        await controller.start();
        await controller.selectCharacter(character);
        await controller.selectConversation(conversation);
        expect(await controller.sendMessage('첫 메시지')).toBe(true);

        listeners[0]?.({
            type: 'event',
            payload: {
                event_version: 4,
                generation_id: 'generation-1',
                conversation_id: conversation.id,
                branch_id: branch.id,
                assistant_message_id: 'message-1',
                sequence: 1,
                emitted_at: '2026-08-02T00:00:01Z',
                kind: { type: 'generation_finished' },
            },
        });

        await vi.waitFor(() =>
            expect(get(controller.state).branches[0]?.head_message_id).toBe('message-committed'),
        );
        expect(get(controller.state).chat.phase).toBe('idle');
        expect(await controller.sendMessage('다음 메시지')).toBe(true);
        expect(sentHeads).toEqual([null, 'message-committed']);
        controller.destroy();
    });
});
