export const VIRTUAL_MESSAGE_ITEM_HEIGHT = 96;
export const VIRTUAL_MESSAGE_OVERSCAN = 8;
export const VIRTUAL_MESSAGE_DOM_LIMIT = 80;

export interface VirtualWindow {
    start: number;
    end: number;
    topSpacer: number;
    bottomSpacer: number;
}

export function computeVirtualMessageWindow(
    total: number,
    scrollTop: number,
    viewportHeight: number,
): VirtualWindow {
    const safeTotal = Math.max(0, Math.trunc(total));
    const safeScrollTop = Math.max(0, scrollTop);
    const safeViewportHeight = Math.max(VIRTUAL_MESSAGE_ITEM_HEIGHT, viewportHeight);
    const firstVisible = Math.floor(safeScrollTop / VIRTUAL_MESSAGE_ITEM_HEIGHT);
    const visibleCount = Math.ceil(safeViewportHeight / VIRTUAL_MESSAGE_ITEM_HEIGHT);
    const requestedStart = Math.max(0, firstVisible - VIRTUAL_MESSAGE_OVERSCAN);
    const requestedCount = Math.min(
        VIRTUAL_MESSAGE_DOM_LIMIT,
        visibleCount + VIRTUAL_MESSAGE_OVERSCAN * 2,
    );
    const end = Math.min(safeTotal, requestedStart + requestedCount);
    const start = Math.max(0, Math.min(requestedStart, end));
    return {
        start,
        end,
        topSpacer: start * VIRTUAL_MESSAGE_ITEM_HEIGHT,
        bottomSpacer: Math.max(0, (safeTotal - end) * VIRTUAL_MESSAGE_ITEM_HEIGHT),
    };
}
