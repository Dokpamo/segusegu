import {
    SUPPORTED_CHAT_EVENT_VERSION,
    type ChatEventDto,
    type ChatStreamItemDto,
} from '../../lib/ipc/contracts';

export type ChatStreamDecision =
    | { type: 'apply'; event: ChatEventDto }
    | { type: 'ignore'; reason: 'wrong_route' | 'wrong_generation' }
    | {
          type: 'reconcile';
          reason:
              | 'broadcast_lagged'
              | 'sequence_gap'
              | 'unsupported_event_version'
              | 'route_mismatch'
              | 'duplicate_or_decreasing_sequence'
              | 'event_after_terminal'
              | 'terminal'
              | 'stream_closed';
          event: ChatEventDto | null;
          sequenceBaseline: number;
      };

export interface ChatStreamExpectation {
    conversationId: string;
    branchId: string;
    generationId?: string;
    assistantMessageId?: string;
    sequenceBaseline?: number;
    eventVersion?: number;
}

export function isTerminalChatEvent(event: ChatEventDto): boolean {
    return (
        event.kind.type === 'generation_finished' ||
        event.kind.type === 'generation_cancelled' ||
        event.kind.type === 'generation_failed'
    );
}

/**
 * Enforces route, wire-version and monotonic sequence invariants before a
 * renderer may apply streamed text. A gap never gets painted optimistically;
 * persisted Core state is reconciled first.
 */
export class ChatStreamVerifier {
    private readonly conversationId: string;
    private readonly branchId: string;
    private readonly eventVersion: number;
    private generationId: string | null;
    private assistantMessageId: string | null;
    private lastSequence: number;
    private terminalSeen = false;

    constructor(expectation: ChatStreamExpectation) {
        this.conversationId = expectation.conversationId;
        this.branchId = expectation.branchId;
        this.generationId = expectation.generationId ?? null;
        this.assistantMessageId = expectation.assistantMessageId ?? null;
        this.lastSequence = expectation.sequenceBaseline ?? 0;
        this.eventVersion = expectation.eventVersion ?? SUPPORTED_CHAT_EVENT_VERSION;
    }

    accept(item: ChatStreamItemDto): ChatStreamDecision {
        if (item.type === 'closed') {
            return {
                type: 'reconcile',
                reason: 'stream_closed',
                event: null,
                sequenceBaseline: this.lastSequence,
            };
        }
        if (item.type === 'reconciliation_required') {
            const marker = item.payload;
            if (
                marker.conversation_id !== this.conversationId ||
                marker.branch_id !== this.branchId
            ) {
                return { type: 'ignore', reason: 'wrong_route' };
            }
            if (this.generationId !== null && marker.generation_id !== this.generationId) {
                return { type: 'ignore', reason: 'wrong_generation' };
            }
            return {
                type: 'reconcile',
                reason: marker.reason,
                event: null,
                sequenceBaseline:
                    marker.reason === 'duplicate_or_decreasing_sequence'
                        ? this.lastSequence
                        : (marker.observed_sequence ?? marker.last_sequence ?? this.lastSequence),
            };
        }

        const event = item.payload;
        if (event.conversation_id !== this.conversationId) {
            return { type: 'ignore', reason: 'wrong_route' };
        }
        if (event.branch_id !== this.branchId) {
            return {
                type: 'reconcile',
                reason: 'route_mismatch',
                event,
                sequenceBaseline: this.lastSequence,
            };
        }
        if (event.event_version !== this.eventVersion) {
            return {
                type: 'reconcile',
                reason: 'unsupported_event_version',
                event,
                sequenceBaseline: this.lastSequence,
            };
        }

        if (this.generationId === null) {
            this.generationId = event.generation_id;
        } else if (event.generation_id !== this.generationId) {
            return { type: 'ignore', reason: 'wrong_generation' };
        }

        if (event.assistant_message_id === null) {
            return {
                type: 'reconcile',
                reason: 'route_mismatch',
                event,
                sequenceBaseline: this.lastSequence,
            };
        }
        if (this.assistantMessageId === null) {
            this.assistantMessageId = event.assistant_message_id;
        } else if (event.assistant_message_id !== this.assistantMessageId) {
            return {
                type: 'reconcile',
                reason: 'route_mismatch',
                event,
                sequenceBaseline: this.lastSequence,
            };
        }

        if (this.terminalSeen) {
            return {
                type: 'reconcile',
                reason: 'event_after_terminal',
                event,
                sequenceBaseline: this.lastSequence,
            };
        }
        if (event.sequence <= this.lastSequence) {
            return {
                type: 'reconcile',
                reason: 'duplicate_or_decreasing_sequence',
                event,
                sequenceBaseline: this.lastSequence,
            };
        }
        if (event.sequence !== this.lastSequence + 1) {
            this.lastSequence = event.sequence;
            return {
                type: 'reconcile',
                reason: 'sequence_gap',
                event,
                sequenceBaseline: event.sequence,
            };
        }

        this.lastSequence = event.sequence;
        if (isTerminalChatEvent(event)) {
            this.terminalSeen = true;
            return {
                type: 'reconcile',
                reason: 'terminal',
                event,
                sequenceBaseline: this.lastSequence,
            };
        }
        return { type: 'apply', event };
    }

    bindGeneration(generationId: string): boolean {
        if (this.generationId === null) {
            this.generationId = generationId;
            return true;
        }
        return this.generationId === generationId;
    }

    getGenerationId(): string | null {
        return this.generationId;
    }

    getLastSequence(): number {
        return this.lastSequence;
    }

    resetAfterReconciliation(generationId: string, lastSequence = this.lastSequence): void {
        this.generationId = generationId;
        this.lastSequence = lastSequence;
        this.terminalSeen = false;
    }
}
