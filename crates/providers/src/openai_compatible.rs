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
        let response = builder.send().await.map_err(network_error)?;
        if !response.status().is_success() {
            return Err(status_error(response.status()));
        }

        let mut bytes = response.bytes_stream();
        let mut pending = Vec::<u8>::new();
        let mut usage = GenerationUsage::default();
        loop {
            tokio::select! {
                change = cancelled.changed() => {
                    if change.is_ok() && *cancelled.borrow() {
                        return Err(CoreError::new(
                            CoreErrorCode::Cancelled,
                            "generation was cancelled",
                            true,
                        ));
                    }
                }
                chunk = bytes.next() => {
                    let Some(chunk) = chunk else { break };
                    pending.extend_from_slice(&chunk.map_err(network_error)?);
                    while let Some(boundary) = find_event_boundary(&pending) {
                        let event = pending.drain(..boundary).collect::<Vec<_>>();
                        pending.drain(..event_separator_len(&pending));
                        process_event(&event, &sink, &mut usage).await?;
                    }
                }
            }
        }
        if !pending.is_empty() {
            process_event(&pending, &sink, &mut usage).await?;
        }
        Ok(usage)
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

async fn process_event(
    event: &[u8],
    sink: &ProviderEventSender,
    usage: &mut GenerationUsage,
) -> CoreResult<()> {
    let text = String::from_utf8_lossy(event);
    for line in text.lines() {
        let Some(data) = line.strip_prefix("data:") else {
            continue;
        };
        let data = data.trim();
        if data.is_empty() || data == "[DONE]" {
            continue;
        }
        let chunk: StreamChunk = serde_json::from_str(data).map_err(|error| {
            CoreError::new(
                CoreErrorCode::ProviderUnavailable,
                format!("provider returned invalid streaming JSON: {error}"),
                true,
            )
        })?;
        if let Some(stream_usage) = chunk.usage {
            usage.input_tokens = stream_usage.prompt_tokens;
            usage.output_tokens = stream_usage.completion_tokens;
        }
        for choice in chunk.choices {
            if let Some(reasoning) = choice
                .delta
                .reasoning_content
                .filter(|value| !value.is_empty())
            {
                sink.send(ProviderEvent::ReasoningDelta(reasoning))
                    .await
                    .map_err(|_| CoreError::internal("provider event receiver closed"))?;
            }
            if let Some(content) = choice.delta.content.filter(|value| !value.is_empty()) {
                sink.send(ProviderEvent::TextDelta(content))
                    .await
                    .map_err(|_| CoreError::internal("provider event receiver closed"))?;
            }
        }
    }
    Ok(())
}

fn find_event_boundary(bytes: &[u8]) -> Option<usize> {
    bytes
        .windows(2)
        .position(|window| window == b"\n\n")
        .or_else(|| bytes.windows(4).position(|window| window == b"\r\n\r\n"))
}

fn event_separator_len(bytes: &[u8]) -> usize {
    if bytes.starts_with(b"\r\n\r\n") { 4 } else { 2 }
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
}
