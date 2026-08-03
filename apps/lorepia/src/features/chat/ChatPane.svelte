<script lang="ts">
    import { onMount, tick } from 'svelte';
    import type { KeyboardEventHandler } from 'svelte/elements';
    import { SvelteMap } from 'svelte/reactivity';

    import type { LorepiaAppController, LorepiaAppState } from '../../app/app-controller';
    import type { ConversationMode, MessageDto } from '../../lib/ipc/contracts';
    import { shouldSubmitComposer } from './composer';
    import { computeVirtualMessageWindow } from './virtual-window';

    interface Props {
        appState: LorepiaAppState;
        controller: LorepiaAppController;
    }

    let { appState, controller }: Props = $props();
    let draft = $state('');
    let compositionActive = $state(false);
    let sending = $state(false);
    let activeDraftKey = '';
    let messageScroller = $state<HTMLDivElement | null>(null);
    let scrollTop = $state(0);
    let viewportHeight = $state(720);
    let nearBottom = $state(true);
    let scrollAnchorEpoch = 0;
    let anchoredBranchKey = '';
    let anchoredMessageCount = 0;
    let editingMessageId = $state<string | null>(null);
    let editDraft = $state('');
    let pendingRemoveId = $state<string | null>(null);
    let copyNotice = $state('');
    const drafts = new SvelteMap<string, string>();

    const branchKey = $derived(
        appState.selected_conversation && appState.conversation_state
            ? `${appState.selected_conversation.id}:${appState.conversation_state.active_branch_id}`
            : '',
    );
    const virtualWindow = $derived(
        computeVirtualMessageWindow(appState.messages.items.length, scrollTop, viewportHeight),
    );
    const visibleMessages = $derived(
        appState.messages.items.slice(virtualWindow.start, virtualWindow.end),
    );

    $effect(() => {
        const nextKey = branchKey;
        if (nextKey !== activeDraftKey) {
            if (activeDraftKey !== '') drafts.set(activeDraftKey, draft);
            draft = drafts.get(nextKey) ?? '';
            activeDraftKey = nextKey;
        }
    });

    $effect(() => {
        const nextKey = branchKey;
        if (nextKey === anchoredBranchKey) return;
        anchoredBranchKey = nextKey;
        anchoredMessageCount = appState.messages.items.length;
        nearBottom = true;
        editingMessageId = null;
        pendingRemoveId = null;
        const epoch = ++scrollAnchorEpoch;
        void scrollToBottom(epoch);
    });

    $effect(() => {
        const messageCount = appState.messages.items.length;
        const streamingLength = appState.chat.streaming_text.length;
        if (messageCount === anchoredMessageCount && streamingLength === 0) {
            return;
        }
        anchoredMessageCount = messageCount;
        if (nearBottom) {
            const epoch = scrollAnchorEpoch;
            void scrollToBottom(epoch);
        }
    });

    onMount(() => {
        if (messageScroller === null || typeof ResizeObserver === 'undefined') {
            return;
        }
        const observer = new ResizeObserver(([entry]) => {
            if (entry) viewportHeight = entry.contentRect.height;
        });
        observer.observe(messageScroller);
        return () => {
            observer.disconnect();
        };
    });

    async function scrollToBottom(epoch: number): Promise<void> {
        await tick();
        if (epoch !== scrollAnchorEpoch || messageScroller === null) return;
        messageScroller.scrollTop = messageScroller.scrollHeight;
        scrollTop = messageScroller.scrollTop;
    }

    function handleScroll(event: Event): void {
        const element = event.currentTarget as HTMLDivElement;
        scrollTop = element.scrollTop;
        viewportHeight = element.clientHeight || viewportHeight;
        nearBottom = element.scrollHeight - element.scrollTop - element.clientHeight < 120;
    }

    async function submit(): Promise<void> {
        if (sending || draft.trim().length === 0) return;
        sending = true;
        try {
            const accepted = await controller.sendMessage(draft);
            if (accepted) {
                draft = '';
                if (activeDraftKey !== '') drafts.delete(activeDraftKey);
            }
        } finally {
            sending = false;
        }
    }

    const onComposerKeydown: KeyboardEventHandler<HTMLTextAreaElement> = (event) => {
        if (
            shouldSubmitComposer(
                {
                    key: event.key,
                    shiftKey: event.shiftKey,
                    isComposing: event.isComposing,
                },
                compositionActive,
            )
        ) {
            event.preventDefault();
            void submit();
        }
    };

    function setMode(mode: ConversationMode): void {
        void controller.setConversationMode(mode);
    }

    function beginEdit(message: MessageDto): void {
        editingMessageId = message.id;
        editDraft = message.content;
        pendingRemoveId = null;
    }

    async function commitEdit(messageId: string): Promise<void> {
        const accepted = await controller.editUserMessage(messageId, editDraft);
        if (accepted) {
            editingMessageId = null;
            editDraft = '';
        }
    }

    async function copyMessage(message: MessageDto): Promise<void> {
        try {
            await navigator.clipboard.writeText(message.content);
            copyNotice = '메시지를 복사했습니다.';
        } catch {
            copyNotice = '메시지를 복사하지 못했습니다.';
        }
    }
</script>

<section class="pane chat-pane" aria-labelledby="chat-title">
    {#if appState.selected_conversation === null}
        <div class="chat-placeholder state-panel empty">
            <span class="large-mark" aria-hidden="true">✦</span>
            <strong>대화를 선택하세요.</strong>
            <p>메시지와 생성 상태는 로컬 Core에서 복원됩니다.</p>
        </div>
    {:else}
        <header class="chat-header">
            <div>
                <p class="eyebrow">{appState.selected_character?.name ?? 'Character'}</p>
                <h2 id="chat-title">{appState.selected_conversation.title}</h2>
            </div>
            <div class="chat-controls">
                <div class="segmented" aria-label="대화 모드">
                    <button
                        type="button"
                        class:active={appState.conversation_state?.selected_mode === 'chat'}
                        aria-pressed={appState.conversation_state?.selected_mode === 'chat'}
                        onclick={() => setMode('chat')}
                    >
                        채팅
                    </button>
                    <button
                        type="button"
                        class:active={appState.conversation_state?.selected_mode === 'story'}
                        aria-pressed={appState.conversation_state?.selected_mode === 'story'}
                        onclick={() => setMode('story')}
                    >
                        스토리
                    </button>
                </div>
                {#if appState.branches.length > 1}
                    <label class="branch-picker">
                        <span>분기</span>
                        <select
                            value={appState.conversation_state?.active_branch_id}
                            onchange={(event) =>
                                void controller.selectBranch(event.currentTarget.value)}
                        >
                            {#each appState.branches as branch, index (branch.id)}
                                <option value={branch.id}>
                                    {branch.title ?? `분기 ${String(index + 1)}`}
                                </option>
                            {/each}
                        </select>
                    </label>
                {/if}
            </div>
        </header>

        <div
            class="message-scroll"
            aria-label="메시지 기록"
            bind:this={messageScroller}
            onscroll={handleScroll}
        >
            {#if appState.messages.phase === 'loading'}
                <div class="state-panel" role="status">메시지를 불러오는 중입니다.</div>
            {:else if appState.messages.phase === 'error'}
                <div class="state-panel error" role="alert">{appState.messages.error}</div>
            {:else if appState.messages.items.length === 0 && appState.chat.streaming_text === ''}
                <div class="state-panel empty">
                    <strong>새로운 이야기의 첫 문장을 보내보세요.</strong>
                </div>
            {:else}
                <ol
                    class="message-list virtualized"
                    aria-label="대화 메시지"
                    style:padding-top={String(22 + virtualWindow.topSpacer) + 'px'}
                    style:padding-bottom={String(22 + virtualWindow.bottomSpacer) + 'px'}
                >
                    {#each visibleMessages as message, localIndex (message.id)}
                        <li
                            class:from-user={message.role === 'user'}
                            class="message-item"
                            data-message-id={message.id}
                            aria-setsize={appState.messages.items.length}
                            aria-posinset={virtualWindow.start + localIndex + 1}
                        >
                            <article
                                class="message-bubble"
                                aria-label={message.role === 'user'
                                    ? '내 메시지'
                                    : message.role === 'assistant'
                                      ? '캐릭터 메시지'
                                      : '시스템 메시지'}
                            >
                                {#if editingMessageId === message.id}
                                    <form
                                        class="inline-editor"
                                        aria-label="메시지 편집"
                                        onsubmit={(event) => {
                                            event.preventDefault();
                                            void commitEdit(message.id);
                                        }}
                                    >
                                        <label class="sr-only" for={`edit-${message.id}`}
                                            >편집할 메시지</label
                                        >
                                        <textarea
                                            id={`edit-${message.id}`}
                                            bind:value={editDraft}
                                            rows="3"></textarea>
                                        <div>
                                            <button
                                                type="button"
                                                onclick={() => {
                                                    editingMessageId = null;
                                                    editDraft = '';
                                                }}
                                            >
                                                취소
                                            </button>
                                            <button
                                                class="primary"
                                                type="submit"
                                                disabled={editDraft.trim().length === 0}
                                            >
                                                새 분기로 저장
                                            </button>
                                        </div>
                                    </form>
                                {:else}
                                    <p>{message.content}</p>
                                    {#if message.status !== 'complete'}
                                        <span class="message-status">{message.status}</span>
                                    {/if}
                                    <div class="message-actions" aria-label="메시지 작업">
                                        <button
                                            type="button"
                                            onclick={() => void copyMessage(message)}
                                        >
                                            복사
                                        </button>
                                        <button
                                            type="button"
                                            disabled={appState.chat.active_generation_id !== null}
                                            onclick={() => void controller.createBranch(message.id)}
                                        >
                                            여기서 분기
                                        </button>
                                        {#if message.role === 'user'}
                                            <button
                                                type="button"
                                                disabled={appState.chat.active_generation_id !==
                                                    null}
                                                onclick={() => beginEdit(message)}
                                            >
                                                편집
                                            </button>
                                        {:else if message.role === 'assistant'}
                                            <button
                                                type="button"
                                                disabled={appState.chat.active_generation_id !==
                                                    null}
                                                onclick={() =>
                                                    void controller.regenerateAssistantMessage(
                                                        message.id,
                                                    )}
                                            >
                                                재생성
                                            </button>
                                        {/if}
                                        {#if pendingRemoveId === message.id}
                                            <button
                                                class="danger"
                                                type="button"
                                                onclick={() => {
                                                    pendingRemoveId = null;
                                                    void controller.removeMessage(message.id);
                                                }}
                                            >
                                                제거 확인
                                            </button>
                                            <button
                                                type="button"
                                                onclick={() => (pendingRemoveId = null)}
                                            >
                                                취소
                                            </button>
                                        {:else}
                                            <button
                                                type="button"
                                                disabled={appState.chat.active_generation_id !==
                                                    null}
                                                onclick={() => (pendingRemoveId = message.id)}
                                            >
                                                여기부터 제거
                                            </button>
                                        {/if}
                                    </div>
                                {/if}
                            </article>
                        </li>
                    {/each}
                    {#if appState.chat.streaming_text !== ''}
                        <li class="message-item streaming-message">
                            <article class="message-bubble streaming" aria-label="생성 중인 응답">
                                <p>{appState.chat.streaming_text}</p>
                                <span class="stream-caret" aria-hidden="true"></span>
                            </article>
                        </li>
                    {/if}
                </ol>
            {/if}
        </div>

        {#if appState.chat.error !== null}
            <div class="state-panel error" role="alert">{appState.chat.error}</div>
        {/if}

        <div class="chat-live-status" aria-live="polite" aria-atomic="true">
            {appState.chat.reconcile_notice ?? appState.chat.usage_label ?? copyNotice}
        </div>

        <form
            class="composer"
            aria-label="메시지 작성"
            onsubmit={(event) => {
                event.preventDefault();
                void submit();
            }}
        >
            <label class="sr-only" for="chat-draft">메시지</label>
            <textarea
                id="chat-draft"
                bind:value={draft}
                rows="1"
                maxlength="131072"
                placeholder="메시지를 입력하세요"
                disabled={appState.chat.phase === 'loading' ||
                    appState.chat.active_generation_id !== null ||
                    appState.conversation_state === null}
                oncompositionstart={() => (compositionActive = true)}
                oncompositionend={() => (compositionActive = false)}
                onkeydown={onComposerKeydown}></textarea>
            {#if appState.chat.active_generation_id !== null}
                <button
                    class="danger compact"
                    type="button"
                    aria-label="응답 생성 취소"
                    onclick={() => void controller.cancelGeneration()}
                >
                    중지
                </button>
            {:else}
                <button
                    class="primary send-button"
                    type="submit"
                    disabled={draft.trim().length === 0 || sending}
                    aria-label="메시지 보내기"
                >
                    ↑
                </button>
            {/if}
        </form>
    {/if}
</section>
