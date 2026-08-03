<script lang="ts">
    import type { LorepiaAppState, LorepiaAppController } from '../../app/app-controller';
    import type { ConversationDto } from '../../lib/ipc/contracts';

    interface Props {
        state: LorepiaAppState;
        controller: LorepiaAppController;
        onOpenChat: () => void;
    }

    let { state, controller, onOpenChat }: Props = $props();

    function selectConversation(conversation: ConversationDto): void {
        void controller.selectConversation(conversation).then(onOpenChat);
    }

    function relativeDate(value: string): string {
        const parsed = new Date(value);
        return Number.isNaN(parsed.getTime())
            ? ''
            : new Intl.DateTimeFormat('ko-KR', { month: 'short', day: 'numeric' }).format(parsed);
    }
</script>

<section class="pane conversation-pane" aria-labelledby="conversation-title">
    <header class="pane-header">
        <div>
            <p class="eyebrow">Conversations</p>
            <h2 id="conversation-title">대화</h2>
        </div>
        <button
            class="compact"
            type="button"
            disabled={state.selected_character === null}
            onclick={() => void controller.openNewConversation().then(onOpenChat)}
        >
            새 대화
        </button>
    </header>

    {#if state.selected_character === null}
        <div class="state-panel empty">
            <strong>캐릭터를 선택하세요.</strong>
            <p>서재에서 캐릭터를 고르면 저장된 대화를 볼 수 있습니다.</p>
        </div>
    {:else if state.conversations.phase === 'loading'}
        <div class="state-panel" role="status">대화를 불러오는 중입니다.</div>
    {:else if state.conversations.phase === 'error'}
        <div class="state-panel error" role="alert">{state.conversations.error}</div>
    {:else if state.conversations.items.length === 0}
        <div class="state-panel empty">
            <strong>저장된 대화가 없습니다.</strong>
            <button
                class="primary"
                type="button"
                onclick={() => void controller.openNewConversation()}
            >
                대화 시작
            </button>
        </div>
    {:else}
        <ul class="entity-list" aria-label={`${state.selected_character.name} 대화 목록`}>
            {#each state.conversations.items as conversation (conversation.id)}
                <li>
                    <button
                        type="button"
                        class="entity-row conversation-row"
                        class:active={state.selected_conversation?.id === conversation.id}
                        aria-pressed={state.selected_conversation?.id === conversation.id}
                        onclick={() => selectConversation(conversation)}
                    >
                        <span class="entity-copy">
                            <strong>{conversation.title || state.selected_character.name}</strong>
                            <span>{relativeDate(conversation.updated_at)}</span>
                        </span>
                        <span aria-hidden="true">›</span>
                    </button>
                </li>
            {/each}
        </ul>
    {/if}
</section>
