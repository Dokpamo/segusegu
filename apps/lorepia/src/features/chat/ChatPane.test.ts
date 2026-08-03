import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, describe, expect, it, vi, type MockInstance } from 'vitest';

import type { LorepiaClient } from '../../lib/ipc/contracts';
import {
    INITIAL_APP_STATE,
    LorepiaAppController,
    type LorepiaAppState,
} from '../../app/app-controller';
import ChatPane from './ChatPane.svelte';

afterEach(() => {
    cleanup();
    vi.restoreAllMocks();
});

function chatReadyState(): LorepiaAppState {
    return {
        ...structuredClone(INITIAL_APP_STATE),
        selected_character: {
            id: 'character-1',
            name: '라온',
            description: '',
            source_hash: 'synthetic',
            avatar_asset_id: null,
            created_at: '2026-08-02T00:00:00Z',
        },
        selected_conversation: {
            id: 'conversation-1',
            character_id: 'character-1',
            title: '첫 대화',
            created_at: '2026-08-02T00:00:00Z',
            updated_at: '2026-08-02T00:00:00Z',
        },
        conversation_state: {
            conversation_id: 'conversation-1',
            active_branch_id: 'branch-1',
            selected_mode: 'chat',
            updated_at: '2026-08-02T00:00:00Z',
        },
        messages: { phase: 'ready', error: null, items: [] },
    };
}

interface RenderedChat {
    controller: LorepiaAppController;
    sendMessage: MockInstance<LorepiaAppController['sendMessage']>;
}

function renderChat(appState = chatReadyState()): RenderedChat {
    const controller = new LorepiaAppController({} as LorepiaClient);
    const sendMessage = vi.spyOn(controller, 'sendMessage').mockResolvedValue(true);
    render(ChatPane, { appState, controller });
    return { controller, sendMessage };
}

describe('ChatPane composer', () => {
    it.each(['안녕', 'こんにちは', '你好'])(
        'does not submit %s when Enter confirms an IME composition',
        async (draft) => {
            const { controller, sendMessage } = renderChat();
            const composer = screen.getByRole('textbox', { name: '메시지' });

            await fireEvent.input(composer, { target: { value: draft } });
            await fireEvent.compositionStart(composer);
            await fireEvent.keyDown(composer, {
                key: 'Enter',
                code: 'Enter',
                isComposing: true,
            });

            expect(sendMessage).not.toHaveBeenCalled();
            expect(composer).toHaveValue(draft);
            controller.destroy();
        },
    );

    it('submits plain Enter after composition ends and keeps Shift+Enter as a newline', async () => {
        const { controller, sendMessage } = renderChat();
        const composer = screen.getByRole('textbox', { name: '메시지' });

        await fireEvent.input(composer, { target: { value: '계속 이야기해 줘' } });
        await fireEvent.keyDown(composer, { key: 'Enter', code: 'Enter', shiftKey: true });
        expect(sendMessage).not.toHaveBeenCalled();

        await fireEvent.compositionStart(composer);
        await fireEvent.compositionEnd(composer);
        await fireEvent.keyDown(composer, {
            key: 'Enter',
            code: 'Enter',
            isComposing: false,
        });

        await waitFor(() => {
            expect(sendMessage).toHaveBeenCalledOnce();
        });
        expect(sendMessage).toHaveBeenCalledWith('계속 이야기해 줘');
        await waitFor(() => {
            expect(composer).toHaveValue('');
        });
        controller.destroy();
    });

    it('keeps the visible DOM bounded for 10,000 persisted messages', () => {
        const appState = chatReadyState();
        appState.messages.items = Array.from({ length: 10_000 }, (_, index) => ({
            id: `message-${String(index)}`,
            conversation_id: 'conversation-1',
            parent_id: index === 0 ? null : `message-${String(index - 1)}`,
            role: index % 2 === 0 ? ('user' as const) : ('assistant' as const),
            content: `synthetic-${String(index)}`,
            status: 'complete' as const,
            generation_id: null,
            created_at: '2026-08-02T00:00:00Z',
        }));

        const { controller } = renderChat(appState);
        const renderedMessages = document.querySelectorAll('[data-message-id]');

        expect(renderedMessages.length).toBeGreaterThan(0);
        expect(renderedMessages.length).toBeLessThanOrEqual(80);
        controller.destroy();
    });

    it('surfaces a blocked generation reattachment and keeps new sends unavailable', () => {
        const appState = chatReadyState();
        appState.chat = {
            ...appState.chat,
            phase: 'error',
            error: '진행 중이던 응답 스트림에 다시 연결할 수 없습니다.',
            active_generation_id: 'generation-1',
        };

        const { controller } = renderChat(appState);

        expect(screen.getByRole('alert')).toHaveTextContent(
            '진행 중이던 응답 스트림에 다시 연결할 수 없습니다.',
        );
        expect(screen.getByRole('textbox', { name: '메시지' })).toBeDisabled();
        expect(screen.getByRole('button', { name: '응답 생성 취소' })).toBeInTheDocument();
        expect(screen.queryByRole('button', { name: '메시지 보내기' })).not.toBeInTheDocument();
        controller.destroy();
    });

    it('exposes explicit edit, regenerate, branch, remove and clipboard actions', async () => {
        const appState = chatReadyState();
        appState.messages.items = [
            {
                id: 'user-1',
                conversation_id: 'conversation-1',
                parent_id: null,
                role: 'user',
                content: '원래 문장',
                status: 'complete',
                generation_id: null,
                created_at: '2026-08-02T00:00:00Z',
            },
            {
                id: 'assistant-1',
                conversation_id: 'conversation-1',
                parent_id: 'user-1',
                role: 'assistant',
                content: '원래 응답',
                status: 'complete',
                generation_id: 'generation-old',
                created_at: '2026-08-02T00:00:01Z',
            },
        ];
        const { controller } = renderChat(appState);
        const edit = vi.spyOn(controller, 'editUserMessage').mockResolvedValue(true);
        const regenerate = vi
            .spyOn(controller, 'regenerateAssistantMessage')
            .mockResolvedValue(true);
        const createBranch = vi.spyOn(controller, 'createBranch').mockResolvedValue();
        const remove = vi.spyOn(controller, 'removeMessage').mockResolvedValue();
        const writeText = vi.fn().mockResolvedValue(undefined);
        Object.defineProperty(navigator, 'clipboard', {
            configurable: true,
            value: { writeText },
        });

        expect(writeText).not.toHaveBeenCalled();
        const firstCopyButton = screen.getAllByRole('button', { name: '복사' }).at(0);
        if (firstCopyButton === undefined) throw new Error('copy action missing');
        await fireEvent.click(firstCopyButton);
        expect(writeText).toHaveBeenCalledWith('원래 문장');

        await fireEvent.click(screen.getByRole('button', { name: '편집' }));
        const editor = screen.getByRole('textbox', { name: '편집할 메시지' });
        await fireEvent.input(editor, { target: { value: '고친 문장' } });
        await fireEvent.click(screen.getByRole('button', { name: '새 분기로 저장' }));
        await waitFor(() => {
            expect(edit).toHaveBeenCalledWith('user-1', '고친 문장');
        });

        await fireEvent.click(screen.getByRole('button', { name: '재생성' }));
        expect(regenerate).toHaveBeenCalledWith('assistant-1');

        const firstBranchButton = screen.getAllByRole('button', { name: '여기서 분기' }).at(0);
        if (firstBranchButton === undefined) throw new Error('branch action missing');
        await fireEvent.click(firstBranchButton);
        expect(createBranch).toHaveBeenCalledWith('user-1');

        const firstRemoveButton = screen.getAllByRole('button', { name: '여기부터 제거' }).at(0);
        if (firstRemoveButton === undefined) throw new Error('remove action missing');
        await fireEvent.click(firstRemoveButton);
        await fireEvent.click(screen.getByRole('button', { name: '제거 확인' }));
        expect(remove).toHaveBeenCalledWith('user-1');
        controller.destroy();
    });
});
