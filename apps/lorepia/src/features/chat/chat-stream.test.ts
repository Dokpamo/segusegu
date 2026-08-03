import { describe, expect, it } from 'vitest';

import type { ChatEventDto, ChatStreamItemDto } from '../../lib/ipc/contracts';
import { ChatStreamVerifier } from './chat-stream';

function event(sequence: number, overrides: Partial<ChatEventDto> = {}): ChatStreamItemDto {
    return {
        type: 'event',
        payload: {
            event_version: 4,
            generation_id: 'generation-1',
            conversation_id: 'conversation-1',
            branch_id: 'branch-1',
            assistant_message_id: 'assistant-1',
            sequence,
            emitted_at: '2026-08-02T00:00:00Z',
            kind: { type: 'text_delta', payload: `chunk-${String(sequence)}` },
            ...overrides,
        },
    };
}

describe('ChatStreamVerifier', () => {
    it('accepts ordered events and reconciles duplicates', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
        });

        expect(verifier.accept(event(1)).type).toBe('apply');
        expect(verifier.accept(event(2)).type).toBe('apply');
        expect(verifier.accept(event(2))).toMatchObject({
            type: 'reconcile',
            reason: 'duplicate_or_decreasing_sequence',
        });
    });

    it('requires reconciliation for a gap and terminal event', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
        });

        expect(verifier.accept(event(1)).type).toBe('apply');
        expect(verifier.accept(event(3))).toMatchObject({
            type: 'reconcile',
            reason: 'sequence_gap',
        });
        expect(
            verifier.accept(
                event(4, {
                    kind: { type: 'generation_finished' },
                }),
            ),
        ).toMatchObject({ type: 'reconcile', reason: 'terminal' });
    });

    it('rejects wrong routes and versions before painting content', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
        });

        expect(verifier.accept(event(1, { conversation_id: 'another-conversation' }))).toEqual({
            type: 'ignore',
            reason: 'wrong_route',
        });
        expect(verifier.accept(event(1, { event_version: 999 }))).toMatchObject({
            type: 'reconcile',
            reason: 'unsupported_event_version',
        });
    });

    it('reconciles a null branch before applying the event', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
        });

        expect(verifier.accept(event(1, { branch_id: null }))).toMatchObject({
            type: 'reconcile',
            reason: 'route_mismatch',
        });
        expect(verifier.accept(event(1)).type).toBe('apply');
    });

    it('reconciles a null assistant message before binding the route', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
        });

        expect(verifier.accept(event(1, { assistant_message_id: null }))).toMatchObject({
            type: 'reconcile',
            reason: 'route_mismatch',
        });
        expect(verifier.accept(event(1))).toMatchObject({ type: 'apply' });
    });

    it('requires the assistant message id to remain stable after the first event', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
        });

        expect(verifier.accept(event(1)).type).toBe('apply');
        expect(verifier.accept(event(2, { assistant_message_id: 'assistant-2' }))).toMatchObject({
            type: 'reconcile',
            reason: 'route_mismatch',
        });
    });

    it('validates an expected assistant message id from the first event', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
            assistantMessageId: 'assistant-expected',
        });

        expect(verifier.accept(event(1))).toMatchObject({
            type: 'reconcile',
            reason: 'route_mismatch',
        });
        expect(
            verifier.accept(event(1, { assistant_message_id: 'assistant-expected' })),
        ).toMatchObject({ type: 'apply' });
    });

    it('accepts the first event immediately after the supplied sequence baseline', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
            sequenceBaseline: 7,
        });

        expect(verifier.accept(event(8))).toMatchObject({ type: 'apply' });
        expect(verifier.accept(event(9))).toMatchObject({ type: 'apply' });
    });

    it('turns a receiver lag marker into a reconcile decision', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
            generationId: 'generation-1',
        });

        expect(
            verifier.accept({
                type: 'reconciliation_required',
                payload: {
                    reason: 'broadcast_lagged',
                    conversation_id: 'conversation-1',
                    branch_id: 'branch-1',
                    generation_id: 'generation-1',
                    last_sequence: 2,
                    observed_sequence: null,
                    dropped_events: 4,
                    supported_event_version: 4,
                },
            }),
        ).toEqual({
            type: 'reconcile',
            reason: 'broadcast_lagged',
            event: null,
            sequenceBaseline: 2,
        });
    });

    it('uses the observed sequence for gaps and the current sequence for duplicates', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
            sequenceBaseline: 7,
        });

        expect(verifier.accept(event(8))).toMatchObject({ type: 'apply' });
        expect(verifier.accept(event(10))).toMatchObject({
            type: 'reconcile',
            reason: 'sequence_gap',
            sequenceBaseline: 10,
        });
        expect(verifier.accept(event(9))).toMatchObject({
            type: 'reconcile',
            reason: 'duplicate_or_decreasing_sequence',
            sequenceBaseline: 10,
        });
    });

    it('never applies an event after a terminal event and can reset after persisted reconcile', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
        });

        expect(verifier.accept(event(1, { kind: { type: 'generation_finished' } }))).toMatchObject({
            type: 'reconcile',
            reason: 'terminal',
        });
        expect(verifier.accept(event(2))).toMatchObject({
            type: 'reconcile',
            reason: 'event_after_terminal',
        });
        verifier.resetAfterReconciliation('generation-1', 2);
        expect(verifier.accept(event(3)).type).toBe('apply');
    });

    it('rebinds to the persisted generation after reconciliation', () => {
        const verifier = new ChatStreamVerifier({
            conversationId: 'conversation-1',
            branchId: 'branch-1',
        });

        expect(verifier.accept(event(1)).type).toBe('apply');
        verifier.resetAfterReconciliation('generation-2', 0);
        expect(verifier.accept(event(1, { generation_id: 'generation-2' }))).toMatchObject({
            type: 'apply',
        });
        expect(verifier.accept(event(2))).toEqual({
            type: 'ignore',
            reason: 'wrong_generation',
        });
    });
});
