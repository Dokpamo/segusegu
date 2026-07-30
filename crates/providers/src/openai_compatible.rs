use std::time::Duration;

use async_trait::async_trait;
use futures_util::StreamExt;
use lorepia_domain::{
    CoreError, CoreErrorCode, CoreResult, GenerationRequest, GenerationUsage, MessageRole,
    ProviderCapabilities,
};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use tokio::sync::watch;
use url::Url;

use crate::{Provider, ProviderEvent, ProviderEventSender};

const MAX_SSE_BUFFER_BYTES: usize = 1024 * 1024;
const SSE_EVENT_SEPARATORS: [&[u8]; 8] = [
    b"\r\n\r\n",
    b"\n\r\n",
    b"\r\r\n",
    b"\r\n\n",
    b"\r\n\r",
    b"\n\n",
    b"\n\r",
    b"\r\r",
];

pub struct OpenAiCompatibleProvider {
    endpoint: Url,
    client: Client,
}

impl OpenAiCompatibleProvider {
    pub fn new(base_url: &str, timeout: Duration) -> CoreResult<Self> {
        let mut endpoint = Url::parse(base_url)
            .map_err(|error| CoreError::invalid(format!("invalid provider base URL: {error}")))?;
        validate_endpoint(&endpoint)?;
        if !endpoint.path().ends_with('/') {
            let path = format!("{}/", endpoint.path());
            endpoint.set_path(&path);
        }
        endpoint = endpoint.join("chat/completions").map_err(|error| {
            CoreError::invalid(format!("cannot construct provider endpoint: {error}"))
        })?;
        let client = Client::builder()
            .timeout(timeout)
            .connect_timeout(timeout.min(Duration::from_secs(30)))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(|error| {
                CoreError::new(
                    CoreErrorCode::ProviderUnavailable,
                    format!("cannot create provider client: {error}"),
                    true,
                )
            })?;
        Ok(Self { endpoint, client })
    }
}

#[async_trait]
impl Provider for OpenAiCompatibleProvider {
    fn capabilities(&self) -> ProviderCapabilities {
        ProviderCapabilities {
            streaming: true,
            reasoning: true,
            max_context_tokens: None,
        }
    }

    async fn generate(
        &self,
        request: GenerationRequest,
        credential: Option<&str>,
        sink: ProviderEventSender,
        mut cancelled: watch::Receiver<bool>,
    ) -> CoreResult<GenerationUsage> {
        if *cancelled.borrow() {
            return Err(cancelled_error());
        }
        let payload = RequestPayload {
            model: request.model,
            messages: request
                .messages
                .into_iter()
                .map(|message| RequestMessage {
                    role: role_name(message.role),
                    content: message.content,
                })
                .collect(),
            stream: true,
            temperature: request.temperature,
            max_tokens: request.max_output_tokens,
            stream_options: StreamOptions {
                include_usage: true,
            },
        };
        let mut builder = self.client.post(self.endpoint.clone()).json(&payload);
        if let Some(credential) = credential.filter(|value| !value.is_empty()) {
            builder = builder.bearer_auth(credential);
        }
        let response = builder.send();
        tokio::pin!(response);
        let mut cancellation_open = true;
        let response = loop {
            tokio::select! {
                change = cancelled.changed(), if cancellation_open => {
                    if change.is_ok() && *cancelled.borrow() {
                        return Err(cancelled_error());
                    }
                    if change.is_err() {
                        cancellation_open = false;
                    }
                }
                result = &mut response => {
                    break result.map_err(network_error)?;
                }
            }
        };
        if !response.status().is_success() {
            return Err(status_error(response.status()));
        }

        let mut bytes = response.bytes_stream();
        let mut pending = Vec::<u8>::new();
        let mut usage = GenerationUsage::default();
        let mut stream_state = SseStreamState::default();
        loop {
            tokio::select! {
                change = cancelled.changed(), if cancellation_open => {
                    if change.is_ok() && *cancelled.borrow() {
                        return Err(cancelled_error());
                    }
                    if change.is_err() {
                        cancellation_open = false;
                    }
                }
                chunk = bytes.next() => {
                    let Some(chunk) = chunk else { break };
                    pending.extend_from_slice(&chunk.map_err(network_error)?);
                    while let Some((boundary, separator_len)) =
                        find_event_boundary(&pending, false)
                    {
                        ensure_not_cancelled(&cancelled)?;
                        ensure_event_size(boundary)?;
                        let event = pending.drain(..boundary).collect::<Vec<_>>();
                        pending.drain(..separator_len);
                        if process_event(
                            &event,
                            &sink,
                            &mut usage,
                            &mut stream_state,
                            &mut cancelled,
                            &mut cancellation_open,
                        )
                        .await?
                            == EventAction::Done
                        {
                            ensure_not_cancelled(&cancelled)?;
                            // `[DONE]` is terminal. Stop consuming immediately so bytes sent after
                            // the marker can never be forwarded as provider events.
                            return Ok(usage);
                        }
                    }
                    ensure_pending_size(&pending, false)?;
                }
            }
        }
        while let Some((boundary, separator_len)) = find_event_boundary(&pending, true) {
            ensure_not_cancelled(&cancelled)?;
            ensure_event_size(boundary)?;
            let event = pending.drain(..boundary).collect::<Vec<_>>();
            pending.drain(..separator_len);
            if process_event(
                &event,
                &sink,
                &mut usage,
                &mut stream_state,
                &mut cancelled,
                &mut cancellation_open,
            )
            .await?
                == EventAction::Done
            {
                ensure_not_cancelled(&cancelled)?;
                return Ok(usage);
            }
        }
        ensure_pending_size(&pending, true)?;
        if !pending.is_empty() {
            return Err(streaming_error(
                "provider stream ended with an incomplete event",
            ));
        }
        Err(stream_state.incomplete_error())
    }
}

fn cancelled_error() -> CoreError {
    CoreError::new(CoreErrorCode::Cancelled, "generation was cancelled", true)
}

fn ensure_not_cancelled(cancelled: &watch::Receiver<bool>) -> CoreResult<()> {
    if *cancelled.borrow() {
        Err(cancelled_error())
    } else {
        Ok(())
    }
}

#[derive(Serialize)]
struct RequestPayload {
    model: String,
    messages: Vec<RequestMessage>,
    stream: bool,
    temperature: f32,
    #[serde(skip_serializing_if = "Option::is_none")]
    max_tokens: Option<u32>,
    stream_options: StreamOptions,
}

#[derive(Serialize)]
struct RequestMessage {
    role: &'static str,
    content: String,
}

#[derive(Serialize)]
struct StreamOptions {
    include_usage: bool,
}

#[derive(Deserialize)]
struct StreamChunk {
    #[serde(default)]
    choices: Vec<StreamChoice>,
    usage: Option<StreamUsage>,
}

#[derive(Deserialize)]
struct StreamChoice {
    delta: StreamDelta,
    finish_reason: Option<String>,
}

#[derive(Default, Deserialize)]
struct StreamDelta {
    content: Option<String>,
    reasoning_content: Option<String>,
}

#[derive(Deserialize)]
struct StreamUsage {
    prompt_tokens: Option<u64>,
    completion_tokens: Option<u64>,
}

#[derive(Debug, Default, PartialEq, Eq)]
enum SseStreamState {
    #[default]
    AwaitingData,
    Streaming,
    Terminal,
}

impl SseStreamState {
    fn incomplete_error(&self) -> CoreError {
        match self {
            Self::AwaitingData => streaming_error("provider returned an empty streaming response"),
            Self::Streaming | Self::Terminal => {
                streaming_error("provider stream ended before [DONE]")
            }
        }
    }

    fn observe_payload(&mut self) {
        if *self == Self::AwaitingData {
            *self = Self::Streaming;
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
enum EventAction {
    Continue,
    Done,
}

async fn process_event(
    event: &[u8],
    sink: &ProviderEventSender,
    usage: &mut GenerationUsage,
    state: &mut SseStreamState,
    cancelled: &mut watch::Receiver<bool>,
    cancellation_open: &mut bool,
) -> CoreResult<EventAction> {
    let text = std::str::from_utf8(event)
        .map_err(|_| streaming_error("provider returned malformed streaming data"))?;
    let mut data_lines = Vec::new();
    for line in text.split(['\r', '\n']) {
        let Some(data) = line.strip_prefix("data:") else {
            continue;
        };
        data_lines.push(data.strip_prefix(' ').unwrap_or(data));
    }
    if data_lines.is_empty() {
        return Ok(EventAction::Continue);
    }

    let data = data_lines.join("\n");
    let data = data.trim();
    if data.is_empty() {
        return Ok(EventAction::Continue);
    }
    if data == "[DONE]" {
        return match state {
            SseStreamState::AwaitingData => Err(streaming_error(
                "provider stream completed without payload data",
            )),
            SseStreamState::Streaming => Err(streaming_error(
                "provider stream completed without a supported finish reason",
            )),
            SseStreamState::Terminal => Ok(EventAction::Done),
        };
    }

    let value: serde_json::Value = serde_json::from_str(data)
        .map_err(|_| streaming_error("provider returned malformed streaming data"))?;
    let Some(object) = value.as_object() else {
        return Err(streaming_error(
            "provider returned malformed streaming data",
        ));
    };
    if object
        .get("error")
        .is_some_and(|provider_error| !provider_error.is_null())
    {
        return Err(streaming_error("provider returned a streaming error"));
    }
    if !object.contains_key("choices") && object.get("usage").is_none_or(serde_json::Value::is_null)
    {
        return Err(streaming_error(
            "provider returned malformed streaming data",
        ));
    }

    let chunk: StreamChunk = serde_json::from_value(value)
        .map_err(|_| streaming_error("provider returned malformed streaming data"))?;
    if *state == SseStreamState::Terminal {
        return process_terminal_trailer(&chunk, usage);
    }
    if chunk.choices.iter().any(|choice| {
        choice
            .delta
            .content
            .as_ref()
            .is_some_and(|content| !content.is_empty())
            || choice
                .delta
                .reasoning_content
                .as_ref()
                .is_some_and(|reasoning| !reasoning.is_empty())
    }) {
        state.observe_payload();
    }
    update_usage(chunk.usage.as_ref(), usage);
    emit_choice_deltas(&chunk.choices, sink, cancelled, cancellation_open).await?;
    observe_finish_reasons(&chunk.choices, state)?;
    Ok(EventAction::Continue)
}

fn process_terminal_trailer(
    chunk: &StreamChunk,
    usage: &mut GenerationUsage,
) -> CoreResult<EventAction> {
    if !chunk.choices.is_empty() {
        return Err(streaming_error(
            "provider returned choice data after a terminal finish reason",
        ));
    }
    update_usage(chunk.usage.as_ref(), usage);
    Ok(EventAction::Continue)
}

fn update_usage(stream_usage: Option<&StreamUsage>, usage: &mut GenerationUsage) {
    if let Some(stream_usage) = stream_usage {
        usage.input_tokens = stream_usage.prompt_tokens;
        usage.output_tokens = stream_usage.completion_tokens;
    }
}

fn observe_finish_reasons(
    choices: &[StreamChoice],
    state: &mut SseStreamState,
) -> CoreResult<()> {
    let mut saw_supported_finish_reason = false;
    for choice in choices {
        match choice.finish_reason.as_deref() {
            None => {}
            Some("stop" | "length" | "content_filter") => {
                saw_supported_finish_reason = true;
            }
            Some(_) => {
                return Err(streaming_error(
                    "provider returned an unsupported finish reason",
                ));
            }
        }
    }
    if saw_supported_finish_reason {
        *state = SseStreamState::Terminal;
    }
    Ok(())
}

async fn emit_choice_deltas(
    choices: &[StreamChoice],
    sink: &ProviderEventSender,
    cancelled: &mut watch::Receiver<bool>,
    cancellation_open: &mut bool,
) -> CoreResult<()> {
    for choice in choices {
        if let Some(reasoning) = choice
            .delta
            .reasoning_content
            .as_ref()
            .filter(|value| !value.is_empty())
        {
            send_provider_event(
                sink,
                ProviderEvent::ReasoningDelta(reasoning.clone()),
                cancelled,
                cancellation_open,
            )
            .await?;
        }
        if let Some(content) = choice
            .delta
            .content
            .as_ref()
            .filter(|value| !value.is_empty())
        {
            send_provider_event(
                sink,
                ProviderEvent::TextDelta(content.clone()),
                cancelled,
                cancellation_open,
            )
            .await?;
        }
    }
    Ok(())
}

async fn send_provider_event(
    sink: &ProviderEventSender,
    event: ProviderEvent,
    cancelled: &mut watch::Receiver<bool>,
    cancellation_open: &mut bool,
) -> CoreResult<()> {
    ensure_not_cancelled(cancelled)?;
    let send = sink.send(event);
    tokio::pin!(send);
    loop {
        tokio::select! {
            biased;
            change = cancelled.changed(), if *cancellation_open => {
                if change.is_err() {
                    *cancellation_open = false;
                } else {
                    ensure_not_cancelled(cancelled)?;
                }
            }
            result = &mut send => {
                return result
                    .map_err(|_| CoreError::internal("provider event receiver closed"));
            }
        }
    }
}

fn find_event_boundary(bytes: &[u8], end_of_stream: bool) -> Option<(usize, usize)> {
    for position in 0..bytes.len() {
        for separator in SSE_EVENT_SEPARATORS {
            let ends_at_buffer_edge = position + separator.len() == bytes.len();
            if bytes[position..].starts_with(separator)
                && (end_of_stream
                    || !separator.ends_with(b"\r")
                    || separator == b"\r\r"
                    || !ends_at_buffer_edge)
            {
                return Some((position, separator.len()));
            }
        }
    }
    None
}

fn ensure_event_size(size: usize) -> CoreResult<()> {
    if size > MAX_SSE_BUFFER_BYTES {
        return Err(streaming_error("provider streaming event exceeded 1 MiB"));
    }
    Ok(())
}

fn ensure_pending_size(bytes: &[u8], end_of_stream: bool) -> CoreResult<()> {
    if bytes.len() <= MAX_SSE_BUFFER_BYTES {
        return Ok(());
    }
    let possible_separator = &bytes[MAX_SSE_BUFFER_BYTES..];
    if !end_of_stream
        && SSE_EVENT_SEPARATORS.iter().any(|separator| {
            possible_separator.len() < separator.len()
                && separator.starts_with(possible_separator)
        })
    {
        return Ok(());
    }
    Err(streaming_error("provider streaming event exceeded 1 MiB"))
}

fn streaming_error(message: &'static str) -> CoreError {
    CoreError::new(CoreErrorCode::ProviderUnavailable, message, true)
}

fn validate_endpoint(endpoint: &Url) -> CoreResult<()> {
    if endpoint.username() != "" || endpoint.password().is_some() {
        return Err(CoreError::invalid(
            "provider URL must not contain embedded credentials",
        ));
    }
    match endpoint.scheme() {
        "https" => Ok(()),
        "http" if endpoint.host_str().is_some_and(is_loopback_host) => Ok(()),
        "http" => Err(CoreError::invalid(
            "unencrypted HTTP is allowed only for loopback endpoints",
        )),
        _ => Err(CoreError::invalid(
            "provider endpoint must use HTTPS or loopback HTTP",
        )),
    }
}

fn is_loopback_host(host: &str) -> bool {
    matches!(host, "localhost" | "127.0.0.1" | "::1" | "[::1]")
}

fn role_name(role: MessageRole) -> &'static str {
    match role {
        MessageRole::System => "system",
        MessageRole::User => "user",
        MessageRole::Assistant => "assistant",
    }
}

fn network_error(error: reqwest::Error) -> CoreError {
    CoreError::new(
        if error.is_timeout() {
            CoreErrorCode::ProviderUnavailable
        } else {
            CoreErrorCode::NetworkUnavailable
        },
        format!("provider request failed: {error}"),
        true,
    )
}

fn status_error(status: StatusCode) -> CoreError {
    let code = match status {
        StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN => CoreErrorCode::ProviderAuthFailed,
        StatusCode::TOO_MANY_REQUESTS => CoreErrorCode::ProviderRateLimited,
        _ => CoreErrorCode::ProviderUnavailable,
    };
    CoreError::new(
        code,
        format!("provider returned HTTP {}", status.as_u16()),
        status.is_server_error() || status == StatusCode::TOO_MANY_REQUESTS,
    )
}

#[cfg(test)]
mod tests {
    use std::{
        io::{self, Read, Write},
        net::{TcpListener, TcpStream},
        thread,
    };

    use lorepia_domain::{ConversationId, GenerationId, GenerationRequest};
    use tokio::sync::{mpsc, watch};

    use super::*;

    #[test]
    fn rejects_credentials_and_remote_plain_http() {
        assert!(
            OpenAiCompatibleProvider::new(
                "https://user:secret@example.com/v1",
                Duration::from_secs(1)
            )
            .is_err()
        );
        assert!(
            OpenAiCompatibleProvider::new("http://example.com/v1", Duration::from_secs(1)).is_err()
        );
        assert!(
            OpenAiCompatibleProvider::new("http://127.0.0.1:11434/v1", Duration::from_secs(1))
                .is_ok()
        );
    }

    fn request() -> GenerationRequest {
        GenerationRequest {
            generation_id: GenerationId::new(),
            conversation_id: ConversationId::new(),
            model: "fixture".to_owned(),
            messages: Vec::new(),
            temperature: 1.0,
            max_output_tokens: None,
        }
    }

    fn read_http_request(stream: &mut TcpStream) -> io::Result<()> {
        const MAX_REQUEST_BYTES: usize = 64 * 1024;

        let mut request = Vec::new();
        let mut buffer = [0_u8; 4096];
        let (headers_len, content_len) = loop {
            let read = stream.read(&mut buffer)?;
            if read == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "request ended before its headers",
                ));
            }
            request.extend_from_slice(&buffer[..read]);
            if request.len() > MAX_REQUEST_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "request exceeded test server limit",
                ));
            }
            let Some(headers_end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n")
            else {
                continue;
            };
            let headers_len = headers_end + 4;
            let headers = std::str::from_utf8(&request[..headers_end])
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            let content_len = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    if name.eq_ignore_ascii_case("content-length") {
                        value.trim().parse::<usize>().ok()
                    } else {
                        None
                    }
                })
                .unwrap_or(0);
            break (headers_len, content_len);
        };

        while request.len() < headers_len + content_len {
            let read = stream.read(&mut buffer)?;
            if read == 0 {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "request ended before its body",
                ));
            }
            request.extend_from_slice(&buffer[..read]);
            if request.len() > MAX_REQUEST_BYTES {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "request exceeded test server limit",
                ));
            }
        }
        Ok(())
    }

    fn status_server(status: &str, extra_headers: &str) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind status server");
        let address = listener.local_addr().expect("status server address");
        let status = status.to_owned();
        let extra_headers = extra_headers.to_owned();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            read_http_request(&mut stream).expect("read status request");
            write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n{extra_headers}\r\n"
            )
            .expect("write status");
        });
        format!("http://{address}/v1")
    }

    fn stream_server(body: &[u8], fragment_bytes: usize) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind stream server");
        let address = listener.local_addr().expect("stream server address");
        let chunks = body
            .chunks(fragment_bytes)
            .map(<[u8]>::to_vec)
            .collect::<Vec<_>>();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            read_http_request(&mut stream).expect("read stream request");
            if stream
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                )
                .is_err()
            {
                return;
            }
            for chunk in chunks {
                if write!(stream, "{:X}\r\n", chunk.len()).is_err()
                    || stream.write_all(&chunk).is_err()
                    || stream.write_all(b"\r\n").is_err()
                {
                    return;
                }
            }
            let _ = stream.write_all(b"0\r\n\r\n");
        });
        format!("http://{address}/v1")
    }

    async fn generate_from_stream(
        body: &[u8],
        fragment_bytes: usize,
    ) -> (CoreResult<GenerationUsage>, Vec<ProviderEvent>) {
        let provider = OpenAiCompatibleProvider::new(
            &stream_server(body, fragment_bytes),
            Duration::from_secs(2),
        )
        .expect("provider");
        let (sink, mut events) = mpsc::channel(16);
        let (_cancel, cancelled) = watch::channel(false);
        let result = provider.generate(request(), None, sink, cancelled).await;
        let mut received = Vec::new();
        while let Ok(event) = events.try_recv() {
            received.push(event);
        }
        (result, received)
    }

    async fn status_error_from(status: &str, extra_headers: &str) -> CoreError {
        let provider = OpenAiCompatibleProvider::new(
            &status_server(status, extra_headers),
            Duration::from_secs(2),
        )
        .expect("provider");
        let (sink, _events) = mpsc::channel(4);
        let (_cancel, cancelled) = watch::channel(false);
        provider
            .generate(request(), None, sink, cancelled)
            .await
            .expect_err("status must fail")
    }

    #[tokio::test]
    async fn maps_auth_rate_limit_and_redirect_without_following() {
        let auth = status_error_from("401 Unauthorized", "").await;
        assert_eq!(auth.code, CoreErrorCode::ProviderAuthFailed);
        assert!(!auth.recoverable);

        let rate_limit = status_error_from("429 Too Many Requests", "").await;
        assert_eq!(rate_limit.code, CoreErrorCode::ProviderRateLimited);
        assert!(rate_limit.recoverable);

        let redirect = status_error_from(
            "302 Found",
            "Location: https://example.invalid/redirect\r\n",
        )
        .await;
        assert_eq!(redirect.code, CoreErrorCode::ProviderUnavailable);
    }

    #[tokio::test]
    async fn streams_fragmented_lf_and_crlf_events() {
        let body = concat!(
            ": keepalive\n\r\n",
            "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"생각\"}}]}\r\n\r\n",
            ": still-alive\r\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"안녕\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":3,\"completion_tokens\":2}}\r\n\r\n",
            "data: [DONE]\n\n",
        );

        let (result, events) = generate_from_stream(body.as_bytes(), 3).await;

        assert_eq!(
            result.expect("valid stream"),
            GenerationUsage {
                input_tokens: Some(3),
                output_tokens: Some(2),
            }
        );
        assert_eq!(
            events,
            vec![
                ProviderEvent::ReasoningDelta("생각".to_owned()),
                ProviderEvent::TextDelta("안녕".to_owned()),
            ]
        );
    }

    #[tokio::test]
    async fn streams_bare_cr_and_mixed_line_endings() {
        let body = concat!(
            ": bare-cr keepalive\r\r",
            "event: message\rdata: {\"choices\":[{\"delta\":{\"content\":\"CR\"}}]}\r\r",
            ": mixed keepalive\r\r\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":1}}\n\r",
            "data: [DONE]\r\n\r",
        );

        let (result, events) = generate_from_stream(body.as_bytes(), 1).await;

        assert_eq!(
            result.expect("valid bare-CR stream"),
            GenerationUsage {
                input_tokens: Some(4),
                output_tokens: Some(1),
            }
        );
        assert_eq!(events, vec![ProviderEvent::TextDelta("CR".to_owned())]);
    }

    #[test]
    fn recognizes_complete_bare_cr_boundary_at_a_chunk_edge() {
        assert_eq!(
            find_event_boundary(b"data: x\r\r", false),
            Some((b"data: x".len(), 2))
        );
        assert_eq!(find_event_boundary(b"data: x\r", false), None);
        assert_eq!(
            find_event_boundary(b"data: x\r\n\r\n", false),
            Some((b"data: x".len(), 4))
        );
    }

    #[tokio::test]
    async fn first_done_ignores_late_data_already_buffered_with_it() {
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"before\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"late\"}}]}\n\n",
            "data: {\"error\":{\"message\":\"also late\"}}\n\n",
        );

        let (result, events) = generate_from_stream(body.as_bytes(), body.len()).await;

        result.expect("the first terminal marker safely ends the stream");
        assert_eq!(events, vec![ProviderEvent::TextDelta("before".to_owned())]);
    }

    #[tokio::test]
    async fn rejects_empty_and_keepalive_only_success_responses() {
        for body in [
            b"".as_slice(),
            b": keepalive\r\n\r\n".as_slice(),
            b": bare-cr keepalive\r\r".as_slice(),
        ] {
            let (result, events) = generate_from_stream(body, 2).await;
            let error = result.expect_err("empty response must fail");

            assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
            assert_eq!(
                error.message, "provider returned an empty streaming response",
                "body: {body:?}"
            );
            assert!(events.is_empty());
        }
    }

    #[tokio::test]
    async fn rejects_stream_that_ends_without_done() {
        let body =
            b"data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"stop\"}]}\n\n";

        let (result, events) = generate_from_stream(body, 5).await;
        let error = result.expect_err("unterminated stream must fail");

        assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
        assert_eq!(error.message, "provider stream ended before [DONE]");
        assert_eq!(events, vec![ProviderEvent::TextDelta("partial".to_owned())]);
    }

    #[tokio::test]
    async fn rejects_done_event_without_a_terminating_blank_line() {
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]",
        );

        let (result, events) = generate_from_stream(body.as_bytes(), 7).await;
        let error = result.expect_err("incomplete terminal event must fail");

        assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
        assert_eq!(
            error.message,
            "provider stream ended with an incomplete event"
        );
        assert_eq!(events, vec![ProviderEvent::TextDelta("partial".to_owned())]);
    }

    #[tokio::test]
    async fn rejects_done_without_payload_data() {
        let (result, events) = generate_from_stream(b"data: [DONE]\n\n", 1).await;
        let error = result.expect_err("payload-free stream must fail");

        assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
        assert_eq!(
            error.message,
            "provider stream completed without payload data"
        );
        assert!(events.is_empty());
    }

    #[tokio::test]
    async fn rejects_done_after_payload_without_a_supported_finish_reason() {
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n",
            "data: [DONE]\n\n",
        );

        let (result, events) = generate_from_stream(body.as_bytes(), 3).await;
        let error = result.expect_err("a terminal marker alone must not complete generation");

        assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
        assert_eq!(
            error.message,
            "provider stream completed without a supported finish reason"
        );
        assert_eq!(events, vec![ProviderEvent::TextDelta("partial".to_owned())]);
    }

    #[tokio::test]
    async fn rejects_empty_choices_as_payload_free() {
        let bodies = [
            b"data: {\"choices\":[]}\n\ndata: [DONE]\n\n".as_slice(),
            b"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":0}}\n\ndata: [DONE]\n\n"
                .as_slice(),
            b"data: {\"choices\":[{\"delta\":{}}]}\n\ndata: [DONE]\n\n".as_slice(),
            b"data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"}}]}\n\ndata: [DONE]\n\n"
                .as_slice(),
        ];

        for body in bodies {
            let (result, events) = generate_from_stream(body, 4).await;
            let error = result.expect_err("empty choices must not establish payload data");

            assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
            assert_eq!(
                error.message,
                "provider stream completed without payload data"
            );
            assert!(events.is_empty());
        }
    }

    #[tokio::test]
    async fn accepts_standard_terminal_finish_reasons() {
        for finish_reason in ["length", "content_filter"] {
            let body = format!(
                "data: {{\"choices\":[{{\"delta\":{{\"content\":\"terminal\"}},\"finish_reason\":\"{finish_reason}\"}}]}}\n\ndata: [DONE]\n\n"
            );

            let (result, events) = generate_from_stream(body.as_bytes(), 5).await;

            result.expect("standard terminal reason must complete generation");
            assert_eq!(
                events,
                vec![ProviderEvent::TextDelta("terminal".to_owned())],
                "finish reason: {finish_reason}"
            );
        }
    }

    #[tokio::test]
    async fn accepts_only_empty_choice_trailers_after_a_terminal_reason() {
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"complete\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":3}}\n\n",
            "data: [DONE]\n\n",
        );

        let (result, events) = generate_from_stream(body.as_bytes(), body.len()).await;

        assert_eq!(
            result.expect("usage-only trailer must be accepted"),
            GenerationUsage {
                input_tokens: Some(7),
                output_tokens: Some(3),
            }
        );
        assert_eq!(
            events,
            vec![ProviderEvent::TextDelta("complete".to_owned())]
        );
    }

    #[tokio::test]
    async fn rejects_choice_data_after_a_terminal_reason_without_emitting_it() {
        for late_choice in [
            "{\"choices\":[{\"delta\":{\"content\":\"late text\"}}]}",
            "{\"choices\":[{\"delta\":{\"reasoning_content\":\"late reasoning\"}}]}",
            "{\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
        ] {
            let body = format!(
                "data: {{\"choices\":[{{\"delta\":{{\"content\":\"complete\"}},\"finish_reason\":\"stop\"}}]}}\n\ndata: {late_choice}\n\ndata: [DONE]\n\n"
            );

            let (result, events) = generate_from_stream(body.as_bytes(), body.len()).await;
            let error = result.expect_err("choice data after terminal reason must fail");

            assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
            assert_eq!(
                error.message,
                "provider returned choice data after a terminal finish reason"
            );
            assert_eq!(
                events,
                vec![ProviderEvent::TextDelta("complete".to_owned())],
                "late choice: {late_choice}"
            );
        }
    }

    #[tokio::test]
    async fn rejects_unsupported_finish_reasons_after_emitting_the_choice() {
        for finish_reason in ["tool_calls", "function_call"] {
            let body = format!(
                "data: {{\"choices\":[{{\"delta\":{{\"content\":\"preserved\"}},\"finish_reason\":\"{finish_reason}\"}}]}}\n\n"
            );

            let (result, events) = generate_from_stream(body.as_bytes(), 5).await;
            let error = result.expect_err("unsupported finish reason must fail");

            assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
            assert_eq!(
                error.message,
                "provider returned an unsupported finish reason"
            );
            assert_eq!(
                events,
                vec![ProviderEvent::TextDelta("preserved".to_owned())]
            );
        }
    }

    #[tokio::test]
    async fn accepts_stop_finish_reason_and_null_error_field() {
        let body = concat!(
            "data: {\"error\":null,\"choices\":[{\"delta\":{\"content\":\"complete\"},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n",
        );

        let (result, events) = generate_from_stream(body.as_bytes(), 3).await;

        result.expect("stop is a supported terminal reason");
        assert_eq!(
            events,
            vec![ProviderEvent::TextDelta("complete".to_owned())]
        );

        let empty_stop =
            b"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
        let (result, events) = generate_from_stream(empty_stop, 2).await;

        result.expect("an explicit stop may complete with empty content");
        assert!(events.is_empty());
    }

    #[tokio::test]
    async fn rejects_malformed_data_and_streaming_error_envelopes() {
        let cases = [
            (
                b"data: {not-json}\n\n".as_slice(),
                "provider returned malformed streaming data",
            ),
            (
                b"data: {\"error\":{\"message\":\"synthetic failure\"}}\n\n".as_slice(),
                "provider returned a streaming error",
            ),
            (
                b"data: {\"unexpected\":true}\n\n".as_slice(),
                "provider returned malformed streaming data",
            ),
        ];

        for (body, expected_message) in cases {
            let (result, events) = generate_from_stream(body, 4).await;
            let error = result.expect_err("invalid stream must fail");

            assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
            assert_eq!(error.message, expected_message);
            assert!(events.is_empty());
        }
    }

    #[tokio::test]
    async fn accepts_exactly_one_mib_event_when_separator_is_fragmented() {
        let prefix = b"data: {\"choices\":[{\"delta\":{\"content\":\"";
        let suffix = b"\"}}]}";
        let content_bytes = MAX_SSE_BUFFER_BYTES - prefix.len() - suffix.len();
        for separator in [b"\n\n".as_slice(), b"\r\r".as_slice()] {
            let mut body = Vec::with_capacity(MAX_SSE_BUFFER_BYTES + 32);
            body.extend_from_slice(prefix);
            body.extend(std::iter::repeat_n(b'x', content_bytes));
            body.extend_from_slice(suffix);
            assert_eq!(body.len(), MAX_SSE_BUFFER_BYTES);
            body.extend_from_slice(separator);
            body.extend_from_slice(
                b"data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
            );
            body.extend_from_slice(separator);
            body.extend_from_slice(b"data: [DONE]");
            body.extend_from_slice(separator);

            let (result, events) = generate_from_stream(&body, MAX_SSE_BUFFER_BYTES + 1).await;

            result.expect("event at the bound must succeed");
            assert_eq!(events.len(), 1);
            let ProviderEvent::TextDelta(content) = &events[0] else {
                panic!("expected text delta");
            };
            assert_eq!(content.len(), content_bytes);
        }
    }

    #[tokio::test]
    async fn retains_one_mib_streaming_event_bound() {
        let mut body = b"data: ".to_vec();
        body.extend(std::iter::repeat_n(
            b'x',
            MAX_SSE_BUFFER_BYTES + 1 - body.len(),
        ));

        let (result, events) = generate_from_stream(&body, 64 * 1024).await;
        let error = result.expect_err("oversized event must fail");

        assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
        assert_eq!(error.message, "provider streaming event exceeded 1 MiB");
        assert!(events.is_empty());
    }

    #[test]
    fn eof_rejects_oversized_event_ending_in_a_separator_prefix() {
        for suffix in [b'\r', b'\n'] {
            let mut pending = vec![b'x'; MAX_SSE_BUFFER_BYTES];
            pending.push(suffix);

            ensure_pending_size(&pending, false)
                .expect("a separator prefix may need one more network chunk");
            let error = ensure_pending_size(&pending, true)
                .expect_err("EOF resolves the extra byte as oversized event data");

            assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
            assert_eq!(error.message, "provider streaming event exceeded 1 MiB");
        }
    }

    #[tokio::test]
    async fn cancellation_interrupts_events_buffered_in_one_http_chunk() {
        let body = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"first\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"second\"}}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
            "data: [DONE]\n\n",
        );
        let provider = OpenAiCompatibleProvider::new(
            &stream_server(body.as_bytes(), body.len()),
            Duration::from_secs(2),
        )
        .expect("provider");
        let (sink, mut events) = mpsc::channel(1);
        let (cancel, cancelled) = watch::channel(false);
        let generation =
            tokio::spawn(async move { provider.generate(request(), None, sink, cancelled).await });

        tokio::time::timeout(Duration::from_secs(1), async {
            while events.is_empty() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("first buffered event");
        cancel.send(true).expect("cancel");

        let error = generation
            .await
            .expect("generation task")
            .expect_err("cancellation must interrupt buffered event draining");
        assert_eq!(error.code, CoreErrorCode::Cancelled);
        assert_eq!(
            events.try_recv().expect("first event remains buffered"),
            ProviderEvent::TextDelta("first".to_owned())
        );
        assert!(events.try_recv().is_err());
    }

    #[tokio::test]
    async fn cancellation_is_observed_before_connecting() {
        let provider =
            OpenAiCompatibleProvider::new("http://127.0.0.1:9/v1", Duration::from_secs(2))
                .expect("provider");
        let (sink, _events) = mpsc::channel(4);
        let (cancel, cancelled) = watch::channel(false);
        cancel.send(true).expect("cancel");
        let error = provider
            .generate(request(), None, sink, cancelled)
            .await
            .expect_err("cancelled request");
        assert_eq!(error.code, CoreErrorCode::Cancelled);
    }
}
