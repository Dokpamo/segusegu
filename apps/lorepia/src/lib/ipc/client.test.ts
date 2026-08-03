import { describe, expect, it } from 'vitest';

import rustInvokeHandler from '../../../src-tauri/src/lib.rs?raw';
import type { ChatStreamItemDto } from './contracts';
import { LOREPIA_COMMANDS, LiveLorepiaClient, type LorepiaTransport } from './client';

class RecordingTransport implements LorepiaTransport {
    readonly calls: {
        commandName: string;
        args: Record<string, unknown> | undefined;
    }[] = [];
    channelListener: ((item: ChatStreamItemDto) => void) | null = null;

    invoke(commandName: string, args?: Record<string, unknown>): Promise<unknown> {
        this.calls.push({ commandName, args });
        if (commandName === LOREPIA_COMMANDS.sendMessage) {
            return Promise.resolve({ generation_id: 'generation-1' });
        }
        if (commandName === LOREPIA_COMMANDS.disposeChatStream) {
            return Promise.resolve(true);
        }
        return Promise.resolve(undefined);
    }

    createChatChannel(onMessage: (message: ChatStreamItemDto) => void): unknown {
        this.channelListener = onMessage;
        return { kind: 'test-channel' };
    }
}

describe('LiveLorepiaClient transport boundary', () => {
    it('uses the exact Rust request/input wrappers and camelCase channel argument', async () => {
        const transport = new RecordingTransport();
        const client = new LiveLorepiaClient(transport);

        await client.getCharacter('character-1');
        await client.inspectImport('ticket-1');
        await client.commitImport('inspection-1');
        await client.discardImport('inspection-1');
        await client.createConversation('character-1', '새 대화', 'story');
        await client.getConversation('conversation-1');
        await client.selectBranch('conversation-1', 'branch-1');
        await client.listBranchMessages('branch-1');
        await client.listMessages('conversation-1');
        await client.createBranch('conversation-1', 'message-1', null);
        await client.editUserMessage(
            {
                conversation_id: 'conversation-1',
                branch_id: 'branch-1',
                expected_head: 'message-2',
                message_id: 'message-1',
                replacement_text: '고친 문장',
                selection: {
                    kind: 'target',
                    target: {
                        model_route_id: 'route-1',
                        generation_preset_id: 'preset-1',
                    },
                },
            },
            'stream-edit-1',
            () => undefined,
        );
        await client.regenerateAssistantMessage(
            {
                conversation_id: 'conversation-1',
                branch_id: 'branch-1',
                expected_head: 'message-2',
                message_id: 'message-2',
                selection: {
                    kind: 'target',
                    target: {
                        model_route_id: 'route-1',
                        generation_preset_id: 'preset-1',
                    },
                },
            },
            'stream-regenerate-1',
            () => undefined,
        );
        await client.removeMessageFromBranch({
            conversation_id: 'conversation-1',
            branch_id: 'branch-1',
            expected_head: 'message-2',
            message_id: 'message-1',
        });
        await client.sendMessage(
            {
                conversation_id: 'conversation-1',
                branch_id: 'branch-1',
                expected_head: null,
                mode: 'chat',
                text: '안녕',
                selection: {
                    kind: 'target',
                    target: {
                        model_route_id: 'route-1',
                        generation_preset_id: 'preset-1',
                    },
                },
            },
            'stream-send-1',
            () => undefined,
        );
        await client.subscribeGeneration(
            'generation-1',
            'conversation-1',
            'branch-1',
            7,
            'stream-subscribe-1',
            () => undefined,
        );
        await expect(client.disposeChatStream('stream-subscribe-1')).resolves.toBe(true);

        expect(transport.calls).toEqual([
            {
                commandName: 'get_character',
                args: { request: { character_id: 'character-1' } },
            },
            {
                commandName: 'inspect_import',
                args: { request: { ticket_id: 'ticket-1' } },
            },
            {
                commandName: 'commit_import',
                args: { request: { inspection_id: 'inspection-1' } },
            },
            {
                commandName: 'discard_import',
                args: {
                    request: { kind: 'inspection', inspection_id: 'inspection-1' },
                },
            },
            {
                commandName: 'create_conversation',
                args: {
                    input: {
                        character_id: 'character-1',
                        title: '새 대화',
                        mode: 'story',
                    },
                },
            },
            {
                commandName: 'get_conversation',
                args: { request: { conversation_id: 'conversation-1' } },
            },
            {
                commandName: 'select_branch',
                args: {
                    input: {
                        conversation_id: 'conversation-1',
                        branch_id: 'branch-1',
                    },
                },
            },
            {
                commandName: 'list_branch_messages',
                args: { request: { branch_id: 'branch-1' } },
            },
            {
                commandName: 'list_messages',
                args: { request: { conversation_id: 'conversation-1' } },
            },
            {
                commandName: 'create_branch',
                args: {
                    input: {
                        conversation_id: 'conversation-1',
                        from_message_id: 'message-1',
                        title: null,
                    },
                },
            },
            {
                commandName: 'edit_user_message',
                args: {
                    input: {
                        conversation_id: 'conversation-1',
                        branch_id: 'branch-1',
                        expected_head: 'message-2',
                        message_id: 'message-1',
                        replacement_text: '고친 문장',
                        selection: {
                            kind: 'target',
                            target: {
                                model_route_id: 'route-1',
                                generation_preset_id: 'preset-1',
                            },
                        },
                    },
                    streamId: 'stream-edit-1',
                    onEvent: { kind: 'test-channel' },
                },
            },
            {
                commandName: 'regenerate_assistant_message',
                args: {
                    input: {
                        conversation_id: 'conversation-1',
                        branch_id: 'branch-1',
                        expected_head: 'message-2',
                        message_id: 'message-2',
                        selection: {
                            kind: 'target',
                            target: {
                                model_route_id: 'route-1',
                                generation_preset_id: 'preset-1',
                            },
                        },
                    },
                    streamId: 'stream-regenerate-1',
                    onEvent: { kind: 'test-channel' },
                },
            },
            {
                commandName: 'remove_message_from_branch',
                args: {
                    input: {
                        conversation_id: 'conversation-1',
                        branch_id: 'branch-1',
                        expected_head: 'message-2',
                        message_id: 'message-1',
                    },
                },
            },
            {
                commandName: 'send_message',
                args: {
                    input: {
                        conversation_id: 'conversation-1',
                        branch_id: 'branch-1',
                        expected_head: null,
                        mode: 'chat',
                        text: '안녕',
                        selection: {
                            kind: 'target',
                            target: {
                                model_route_id: 'route-1',
                                generation_preset_id: 'preset-1',
                            },
                        },
                    },
                    streamId: 'stream-send-1',
                    onEvent: { kind: 'test-channel' },
                },
            },
            {
                commandName: 'subscribe_generation',
                args: {
                    request: {
                        generation_id: 'generation-1',
                        conversation_id: 'conversation-1',
                        branch_id: 'branch-1',
                        sequence_baseline: 7,
                    },
                    streamId: 'stream-subscribe-1',
                    onEvent: { kind: 'test-channel' },
                },
            },
            {
                commandName: 'dispose_chat_stream',
                args: {
                    request: { stream_id: 'stream-subscribe-1' },
                },
            },
        ]);
        expect(transport.channelListener).not.toBeNull();
    });

    it('contains only commands registered by the Tauri invoke handler', () => {
        const registered = new Set(
            [...rustInvokeHandler.matchAll(/commands::([a-z_]+)/g)].map((match) => match[1]),
        );

        const clientCommands = Object.values(LOREPIA_COMMANDS);
        for (const commandName of clientCommands) {
            expect(commandName).not.toContain('plugin:');
            expect(registered.has(commandName), commandName).toBe(true);
        }
        expect([...clientCommands].sort()).toEqual([...registered].sort());
    });

    it('wraps capability and assistant lifecycle commands in the exact request object', async () => {
        const transport = new RecordingTransport();
        const client = new LiveLorepiaClient(transport);

        await client.listCapabilityObservations('route-1');
        await client.effectiveCapability('route-1', 'reasoning');
        await client.effectiveParameterSpecs('route-1');
        await client.upsertUserCapabilityOverride({
            id: 'override-1',
            model_route_id: 'route-1',
            key: 'streaming',
            value: { type: 'boolean', value: true },
            status: 'verified',
            expires_at: null,
        });
        await client.deleteUserCapabilityOverride('route-1', 'override-1');
        await client.getProviderDiscoveryAssistantResumeBoundary('discovery-1');
        await client.runProviderDiscoveryAssistantTurn('discovery-1');
        await client.resumeProviderDiscoveryAssistantCoreHostAction('discovery-1');
        await client.approveProviderDiscoveryAssistantRetry('discovery-1');
        await client.requestProviderDiscoveryAssistantRevision('discovery-1');
        await client.acceptProviderDiscoveryAssistantDraft('discovery-1');
        await client.recordProviderDiscoveryAssistantFailure('discovery-1', 'timeout', true);
        await client.interruptProviderDiscoveryAssistant('discovery-1', 'external_outcome_unknown');
        await client.restartProviderDiscoveryAssistantAfterInterruption('discovery-1');

        expect(transport.calls).toEqual([
            {
                commandName: 'list_capability_observations',
                args: { request: { model_route_id: 'route-1' } },
            },
            {
                commandName: 'effective_capability',
                args: { request: { model_route_id: 'route-1', key: 'reasoning' } },
            },
            {
                commandName: 'effective_parameter_specs',
                args: { request: { model_route_id: 'route-1' } },
            },
            {
                commandName: 'upsert_user_capability_override',
                args: {
                    request: {
                        input: {
                            id: 'override-1',
                            model_route_id: 'route-1',
                            key: 'streaming',
                            value: { type: 'boolean', value: true },
                            status: 'verified',
                            expires_at: null,
                        },
                    },
                },
            },
            {
                commandName: 'delete_user_capability_override',
                args: {
                    request: {
                        model_route_id: 'route-1',
                        observation_id: 'override-1',
                    },
                },
            },
            {
                commandName: 'get_provider_discovery_assistant_resume_boundary',
                args: { request: { session_id: 'discovery-1' } },
            },
            {
                commandName: 'run_provider_discovery_assistant_turn',
                args: {
                    request: {
                        session_id: 'discovery-1',
                    },
                },
            },
            {
                commandName: 'resume_provider_discovery_assistant_core_host_action',
                args: { request: { session_id: 'discovery-1' } },
            },
            {
                commandName: 'approve_provider_discovery_assistant_retry',
                args: { request: { session_id: 'discovery-1' } },
            },
            {
                commandName: 'request_provider_discovery_assistant_revision',
                args: { request: { session_id: 'discovery-1' } },
            },
            {
                commandName: 'accept_provider_discovery_assistant_draft',
                args: { request: { session_id: 'discovery-1' } },
            },
            {
                commandName: 'record_provider_discovery_assistant_failure',
                args: {
                    request: {
                        session_id: 'discovery-1',
                        kind: 'timeout',
                        retryable: true,
                    },
                },
            },
            {
                commandName: 'interrupt_provider_discovery_assistant',
                args: {
                    request: {
                        session_id: 'discovery-1',
                        outcome: 'external_outcome_unknown',
                    },
                },
            },
            {
                commandName: 'restart_provider_discovery_assistant_after_interruption',
                args: { request: { session_id: 'discovery-1' } },
            },
        ]);
        expect(JSON.stringify(transport.calls)).not.toContain('credential');
        expect(JSON.stringify(transport.calls)).not.toContain('"estimate"');
    });
});
