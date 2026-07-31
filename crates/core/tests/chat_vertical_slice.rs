use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

use lorepia_core::{AppSettings, ChatEventKind, Core, CoreConfig, MessageStatus, ProviderProfile};
use tempfile::{NamedTempFile, tempdir};

fn imported_core() -> (tempfile::TempDir, Core, String) {
    let root = tempdir().expect("temporary data root");
    let core = Core::open(CoreConfig::new(root.path())).expect("open core");
    let mut source = NamedTempFile::new().expect("temporary source");
    write!(
        source,
        r#"{{"spec":"chara_card_v3","data":{{"name":"세구","description":"테스트"}}}}"#
    )
    .expect("write source");
    let review = core.inspect_import(source.path()).expect("inspect");
    let character = core.commit_import(&review.id).expect("commit");
    (root, core, character.id)
}

fn read_request(stream: &mut TcpStream) -> Vec<u8> {
    stream
        .set_read_timeout(Some(Duration::from_secs(2)))
        .expect("request timeout");
    let mut request = Vec::new();
    let mut buffer = [0_u8; 4096];
    loop {
        let read = stream.read(&mut buffer).expect("read request");
        if read == 0 {
            break;
        }
        request.extend_from_slice(&buffer[..read]);
        let Some(header_end) = request.windows(4).position(|value| value == b"\r\n\r\n") else {
            continue;
        };
        let headers = String::from_utf8_lossy(&request[..header_end]);
        let content_length = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse::<usize>().ok())
                    .flatten()
            })
            .unwrap_or(0);
        if request.len() >= header_end + 4 + content_length {
            break;
        }
    }
    request
}

fn spawn_completed_provider() -> (String, mpsc::Receiver<Vec<u8>>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind provider");
    let address = listener.local_addr().expect("provider address");
    let (request_sender, request_receiver) = mpsc::channel();
    thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept provider request");
        let request = read_request(&mut stream);
        request_sender.send(request).expect("capture request");
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"안녕\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}\n\n",
            "data: [DONE]\n\n"
        );
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .expect("write provider response");
    });
    (format!("http://{address}/v1"), request_receiver)
}

fn spawn_stalling_provider() -> (String, mpsc::Receiver<()>, mpsc::Sender<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind provider");
    let address = listener.local_addr().expect("provider address");
    let (ready_sender, ready_receiver) = mpsc::channel();
    let (stop_sender, stop_receiver) = mpsc::channel();
    thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept provider request");
        let _request = read_request(&mut stream);
        let event = "data: {\"choices\":[{\"delta\":{\"content\":\"부분\"}}]}\n\n";
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:X}\r\n{}\r\n",
            event.len(),
            event
        )
        .expect("write provider chunk");
        stream.flush().expect("flush provider chunk");
        ready_sender.send(()).expect("provider ready");
        let _ = stop_receiver.recv_timeout(Duration::from_secs(3));
        let _ = stream.write_all(b"0\r\n\r\n");
    });
    (format!("http://{address}/v1"), ready_receiver, stop_sender)
}

fn wait_for_terminal_message(core: &Core, conversation_id: &lorepia_core::ConversationId) {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let messages = core.list_messages(conversation_id).expect("messages");
        if messages.len() == 2 && messages[1].status != MessageStatus::Pending {
            return;
        }
        assert!(Instant::now() < deadline, "generation did not finish");
        thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn streams_commits_and_restores_messages_without_persisting_the_credential() {
    let (root, core, character_id) = imported_core();
    let (base_url, captured_request) = spawn_completed_provider();
    let profile = core
        .upsert_provider_profile(ProviderProfile {
            id: "local-test".to_owned(),
            display_name: "Local test".to_owned(),
            base_url,
            model: "fixture".to_owned(),
            timeout_seconds: 5,
        })
        .expect("save provider profile");
    core.update_settings(&AppSettings {
        preserve_partial_generations: true,
        selected_provider_profile_id: Some(profile.id.clone()),
    })
    .expect("save settings");

    let conversation = core
        .open_conversation(&character_id)
        .expect("open conversation");
    let mut events = core.subscribe_events();
    let generation = core
        .send_message(
            &conversation.id,
            "반가워",
            &profile.id,
            Some("short-lived-secret".to_owned()),
        )
        .expect("send message");
    wait_for_terminal_message(&core, &conversation.id);

    let request = String::from_utf8_lossy(
        &captured_request
            .recv_timeout(Duration::from_secs(2))
            .expect("captured request"),
    )
    .into_owned();
    assert!(
        request
            .to_ascii_lowercase()
            .contains("authorization: bearer short-lived-secret")
    );
    assert!(
        request.contains("\"max_tokens\":4096"),
        "core must apply its finite provider output-token limit"
    );
    let received = std::iter::from_fn(|| events.try_recv().ok())
        .filter(|event| event.generation_id == generation)
        .collect::<Vec<_>>();
    assert!(
        received
            .windows(2)
            .all(|pair| pair[0].sequence < pair[1].sequence)
    );
    assert!(matches!(
        received.last().map(|event| &event.kind),
        Some(ChatEventKind::GenerationFinished)
    ));

    let messages = core.list_messages(&conversation.id).expect("messages");
    assert_eq!(messages[1].content, "안녕");
    assert_eq!(messages[1].status, MessageStatus::Complete);
    drop(core);

    let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen core");
    let restored = reopened
        .list_messages(&conversation.id)
        .expect("restored messages");
    assert_eq!(restored, messages);
    let database = std::fs::read(root.path().join("db/lorepia.sqlite3")).expect("database bytes");
    assert!(
        !database
            .windows(b"short-lived-secret".len())
            .any(|window| window == b"short-lived-secret"),
        "credentials must never be persisted in the Rust data root"
    );
}

#[test]
fn cancellation_preserves_partial_text_and_emits_a_terminal_event() {
    let (_root, core, character_id) = imported_core();
    let (base_url, provider_ready, provider_stop) = spawn_stalling_provider();
    let profile = core
        .upsert_provider_profile(ProviderProfile {
            id: "cancellation-test".to_owned(),
            display_name: "Cancellation test".to_owned(),
            base_url,
            model: "fixture".to_owned(),
            timeout_seconds: 5,
        })
        .expect("save provider profile");
    let conversation = core
        .open_conversation(&character_id)
        .expect("open conversation");
    let mut events = core.subscribe_events();
    let generation = core
        .send_message(&conversation.id, "중지해", &profile.id, None)
        .expect("send message");
    provider_ready
        .recv_timeout(Duration::from_secs(2))
        .expect("provider started streaming");

    let deadline = Instant::now() + Duration::from_secs(2);
    loop {
        if let Ok(event) = events.try_recv()
            && event.generation_id == generation
            && matches!(event.kind, ChatEventKind::TextDelta(_))
        {
            break;
        }
        assert!(Instant::now() < deadline, "text delta did not arrive");
        thread::sleep(Duration::from_millis(5));
    }
    core.cancel_generation(&generation)
        .expect("cancel generation");
    wait_for_terminal_message(&core, &conversation.id);
    let _ = provider_stop.send(());

    let messages = core.list_messages(&conversation.id).expect("messages");
    assert_eq!(messages[1].status, MessageStatus::Cancelled);
    assert_eq!(messages[1].content, "부분");
    assert!(std::iter::from_fn(|| events.try_recv().ok()).any(|event| {
        event.generation_id == generation
            && matches!(event.kind, ChatEventKind::GenerationCancelled)
    }));
}
