use lorepia_shell_api::{ChatEventKindDto, ChatEventStream, ChatStreamItem};
use tauri::ipc::Channel;

use crate::state::ChatStreamRegistration;

pub fn forward_chat_stream(
    mut stream: ChatEventStream,
    channel: Channel<ChatStreamItem>,
    mut registration: ChatStreamRegistration,
) {
    tauri::async_runtime::spawn(async move {
        loop {
            tokio::select! {
                biased;
                () = registration.disposed() => {
                    // Receiver disposal never implies Core generation cancellation.
                    break;
                }
                item = stream.recv() => {
                    let should_close = closes_forwarder(&item);
                    if channel.send(item).is_err() || should_close {
                        // Closing a renderer Channel stops only this forwarding task.
                        // Generation cancellation requires the explicit cancel command.
                        break;
                    }
                }
            }
        }
    });
}

fn closes_forwarder(item: &ChatStreamItem) -> bool {
    match item {
        ChatStreamItem::Event(event) => matches!(
            event.kind,
            ChatEventKindDto::GenerationCancelled
                | ChatEventKindDto::GenerationFailed { .. }
                | ChatEventKindDto::GenerationFinished
        ),
        ChatStreamItem::ReconciliationRequired(_) | ChatStreamItem::Closed => true,
    }
}
