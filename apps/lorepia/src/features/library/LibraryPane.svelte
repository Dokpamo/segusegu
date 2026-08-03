<script lang="ts">
    import type { LorepiaAppState, LorepiaAppController } from '../../app/app-controller';
    import type { CharacterDto } from '../../lib/ipc/contracts';

    interface Props {
        state: LorepiaAppState;
        controller: LorepiaAppController;
        onOpenConversations: () => void;
    }

    let { state, controller, onOpenConversations }: Props = $props();

    function selectCharacter(character: CharacterDto): void {
        void controller.selectCharacter(character).then(onOpenConversations);
    }
</script>

<section class="pane library-pane" aria-labelledby="library-title">
    <header class="pane-header">
        <div>
            <p class="eyebrow">Local library</p>
            <h1 id="library-title">서재</h1>
        </div>
        <button class="primary compact" type="button" onclick={() => void controller.beginImport()}>
            가져오기
        </button>
    </header>

    {#if state.library.phase === 'loading'}
        <div class="state-panel" role="status">캐릭터를 불러오는 중입니다.</div>
    {:else if state.library.phase === 'error'}
        <div class="state-panel error" role="alert">
            <p>{state.library.error}</p>
            <button type="button" onclick={() => void controller.loadLibrary()}>다시 시도</button>
        </div>
    {:else if state.library.characters.length === 0}
        <div class="state-panel empty">
            <strong>아직 캐릭터가 없습니다.</strong>
            <p>로컬 CCv3 JSON 또는 CHARX 파일을 안전하게 검사한 뒤 추가할 수 있습니다.</p>
            <button class="primary" type="button" onclick={() => void controller.beginImport()}>
                첫 캐릭터 가져오기
            </button>
        </div>
    {:else}
        <ul class="entity-list" aria-label="캐릭터 목록">
            {#each state.library.characters as character (character.id)}
                <li>
                    <button
                        type="button"
                        class:active={state.selected_character?.id === character.id}
                        class="entity-row"
                        aria-pressed={state.selected_character?.id === character.id}
                        onclick={() => selectCharacter(character)}
                    >
                        <span class="avatar" aria-hidden="true">
                            {character.name.slice(0, 1)}
                        </span>
                        <span class="entity-copy">
                            <strong>{character.name}</strong>
                            <span>{character.description || '설명이 없습니다.'}</span>
                        </span>
                    </button>
                </li>
            {/each}
        </ul>
    {/if}
</section>
