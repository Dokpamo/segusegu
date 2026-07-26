//! Thin `UniFFI` surface consumed by Android and Apple applications.

use std::sync::{Arc, Mutex};

use lorepia_core::{
    AppSettings, Character, ChatEvent, ChatEventKind, ContentKind, Conversation, ConversationId,
    Core, CoreConfig, CoreError, DatabaseStats, GenerationId, ImportInspection, InspectionId,
    Message, MessageRole, MessageStatus, ProviderProfile,
};
use tokio::sync::broadcast;

const BINDING_API_VERSION: u32 = 2;
const CHAT_EVENT_VERSION: u32 = 1;
const MAX_EVENT_BATCH_SIZE: u32 = 256;

uniffi::setup_scaffolding!();

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCoreConfig {
    pub data_root: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiVersionInfo {
    pub core_version: String,
    pub core_api_version: u32,
    pub binding_api_version: u32,
    pub chat_event_version: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
#[allow(clippy::struct_excessive_bools)]
pub struct FfiHealthReport {
    pub core_version: String,
    pub database_open: bool,
    pub schema_version: u32,
    pub data_root_writable: bool,
    pub staging_writable: bool,
    pub recovery_pending: bool,
    pub active_jobs: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCharacter {
    pub id: String,
    pub name: String,
    pub description: String,
    pub source_hash: String,
    pub avatar_asset_hash: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiImportWarning {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiImportImagePreview {
    pub logical_asset_id: String,
    pub media_type: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiImportInspection {
    pub id: String,
    pub content_kind: String,
    pub display_name: String,
    pub description: String,
    pub representative_image: Option<FfiImportImagePreview>,
    pub source_sha256: String,
    pub source_size: u64,
    pub estimated_stored_size: u64,
    pub asset_count: u32,
    pub warnings: Vec<FfiImportWarning>,
    pub blocked_reasons: Vec<String>,
    pub unsupported_optional_fields: Vec<String>,
    pub is_allowed: bool,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiConversation {
    pub id: String,
    pub character_id: String,
    pub title: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiMessage {
    pub id: String,
    pub conversation_id: String,
    pub parent_id: Option<String>,
    pub role: String,
    pub content: String,
    pub status: String,
    pub generation_id: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiProviderProfile {
    pub id: String,
    pub display_name: String,
    pub base_url: String,
    pub model: String,
    pub timeout_seconds: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiAppSettings {
    pub preserve_partial_generations: bool,
    pub selected_provider_profile_id: Option<String>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiDatabaseStats {
    pub characters: u64,
    pub conversations: u64,
    pub messages: u64,
    pub pending_imports: u64,
}

/// A flat, versioned event representation that is forward-compatible across
/// Kotlin and Swift. Fields that do not apply to `kind` are `None`.
#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiChatEvent {
    pub event_version: u32,
    pub generation_id: String,
    pub conversation_id: String,
    pub sequence: u64,
    pub emitted_at: String,
    pub kind: String,
    pub text: Option<String>,
    pub message_id: Option<String>,
    pub message_status: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
    pub usage_input_tokens: Option<u64>,
    pub usage_output_tokens: Option<u64>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiEventBatch {
    pub events: Vec<FfiChatEvent>,
    /// Number of events evicted before this poll could receive them.
    ///
    /// A non-zero value tells the platform to refresh persisted messages before
    /// applying subsequent deltas.
    pub dropped_event_count: u64,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{code}: {detail}")]
    Core {
        code: String,
        detail: String,
        recoverable: bool,
        operation_id: String,
    },
}

impl From<CoreError> for FfiError {
    fn from(error: CoreError) -> Self {
        Self::Core {
            code: error.code.as_str().to_owned(),
            detail: error.message,
            recoverable: error.recoverable,
            operation_id: error.operation_id,
        }
    }
}

#[derive(uniffi::Object)]
pub struct LorepiaCore {
    core: Core,
    event_receiver: Mutex<broadcast::Receiver<ChatEvent>>,
}

#[uniffi::export]
pub fn core_version() -> String {
    lorepia_core::core_version().to_owned()
}

#[uniffi::export]
pub fn version_info() -> FfiVersionInfo {
    FfiVersionInfo {
        core_version: core_version(),
        core_api_version: lorepia_core::CORE_API_VERSION,
        binding_api_version: BINDING_API_VERSION,
        chat_event_version: CHAT_EVENT_VERSION,
    }
}

#[uniffi::export]
impl LorepiaCore {
    #[uniffi::constructor]
    pub fn open(config: FfiCoreConfig) -> Result<Arc<Self>, FfiError> {
        let core = Core::open(CoreConfig::new(config.data_root))?;
        let event_receiver = Mutex::new(core.subscribe_events());
        Ok(Arc::new(Self {
            core,
            event_receiver,
        }))
    }

    pub fn health_check(&self) -> Result<FfiHealthReport, FfiError> {
        let report = self.core.health_check()?;
        Ok(FfiHealthReport {
            core_version: report.core_version,
            database_open: report.database_open,
            schema_version: report.schema_version,
            data_root_writable: report.data_root_writable,
            staging_writable: report.staging_writable,
            recovery_pending: report.recovery_pending,
            active_jobs: report.active_jobs,
        })
    }

    pub fn inspect_import(&self, staged_path: String) -> Result<FfiImportInspection, FfiError> {
        self.core
            .inspect_import(staged_path)
            .map(map_inspection)
            .map_err(Into::into)
    }

    pub fn commit_import(&self, inspection_id: String) -> Result<FfiCharacter, FfiError> {
        self.core
            .commit_import(&InspectionId(inspection_id))
            .map(map_character)
            .map_err(Into::into)
    }

    pub fn discard_import(&self, inspection_id: String) -> Result<(), FfiError> {
        self.core
            .discard_import(&InspectionId(inspection_id))
            .map_err(Into::into)
    }

    pub fn list_characters(&self) -> Result<Vec<FfiCharacter>, FfiError> {
        self.core
            .list_characters()
            .map(|characters| characters.into_iter().map(map_character).collect())
            .map_err(Into::into)
    }

    pub fn get_character(&self, character_id: String) -> Result<FfiCharacter, FfiError> {
        self.core
            .get_character(&character_id)
            .map(map_character)
            .map_err(Into::into)
    }

    pub fn open_conversation(&self, character_id: String) -> Result<FfiConversation, FfiError> {
        self.core
            .open_conversation(&character_id)
            .map(map_conversation)
            .map_err(Into::into)
    }

    pub fn list_conversations(&self) -> Result<Vec<FfiConversation>, FfiError> {
        self.core
            .list_conversations()
            .map(|conversations| conversations.into_iter().map(map_conversation).collect())
            .map_err(Into::into)
    }

    pub fn list_messages(&self, conversation_id: String) -> Result<Vec<FfiMessage>, FfiError> {
        self.core
            .list_messages(&ConversationId(conversation_id))
            .map(|messages| messages.into_iter().map(map_message).collect())
            .map_err(Into::into)
    }

    pub fn send_message(
        &self,
        conversation_id: String,
        text: String,
        provider_profile_id: String,
        credential: Option<String>,
    ) -> Result<String, FfiError> {
        self.core
            .send_message(
                &ConversationId(conversation_id),
                &text,
                &provider_profile_id,
                credential,
            )
            .map(|generation_id| generation_id.0)
            .map_err(Into::into)
    }

    pub fn cancel_generation(&self, generation_id: String) -> Result<(), FfiError> {
        self.core
            .cancel_generation(&GenerationId(generation_id))
            .map_err(Into::into)
    }

    /// Drains up to `max_events` without blocking a platform UI thread.
    pub fn poll_events(&self, max_events: u32) -> Result<FfiEventBatch, FfiError> {
        if max_events == 0 || max_events > MAX_EVENT_BATCH_SIZE {
            return Err(CoreError::invalid(format!(
                "max_events must be between 1 and {MAX_EVENT_BATCH_SIZE}"
            ))
            .into());
        }
        let mut receiver = self
            .event_receiver
            .lock()
            .map_err(|_| FfiError::from(CoreError::internal("event receiver lock was poisoned")))?;
        let mut events = Vec::with_capacity(max_events as usize);
        let mut dropped_event_count = 0_u64;
        while events.len() < max_events as usize {
            match receiver.try_recv() {
                Ok(event) => events.push(map_chat_event(event)),
                Err(
                    broadcast::error::TryRecvError::Empty | broadcast::error::TryRecvError::Closed,
                ) => {
                    break;
                }
                Err(broadcast::error::TryRecvError::Lagged(skipped)) => {
                    dropped_event_count = dropped_event_count.saturating_add(skipped);
                }
            }
        }
        Ok(FfiEventBatch {
            events,
            dropped_event_count,
        })
    }

    pub fn list_provider_profiles(&self) -> Result<Vec<FfiProviderProfile>, FfiError> {
        self.core
            .list_provider_profiles()
            .map(|profiles| profiles.into_iter().map(map_provider_profile).collect())
            .map_err(Into::into)
    }

    pub fn upsert_provider_profile(
        &self,
        profile: FfiProviderProfile,
    ) -> Result<FfiProviderProfile, FfiError> {
        self.core
            .upsert_provider_profile(unmap_provider_profile(profile))
            .map(map_provider_profile)
            .map_err(Into::into)
    }

    pub fn delete_provider_profile(&self, profile_id: String) -> Result<(), FfiError> {
        self.core
            .delete_provider_profile(&profile_id)
            .map_err(Into::into)
    }

    pub fn get_settings(&self) -> Result<FfiAppSettings, FfiError> {
        self.core
            .get_settings()
            .map(map_settings)
            .map_err(Into::into)
    }

    pub fn update_settings(&self, settings: FfiAppSettings) -> Result<FfiAppSettings, FfiError> {
        let settings = unmap_settings(settings);
        self.core.update_settings(&settings)?;
        self.core
            .get_settings()
            .map(map_settings)
            .map_err(Into::into)
    }

    pub fn database_stats(&self) -> Result<FfiDatabaseStats, FfiError> {
        self.core
            .database_stats()
            .map(map_database_stats)
            .map_err(Into::into)
    }
}

fn map_character(character: Character) -> FfiCharacter {
    FfiCharacter {
        id: character.id,
        name: character.name,
        description: character.description,
        source_hash: character.source_hash,
        avatar_asset_hash: character.avatar_asset_hash,
        created_at: character.created_at.to_rfc3339(),
    }
}

fn map_inspection(inspection: ImportInspection) -> FfiImportInspection {
    let is_allowed = inspection.is_allowed();
    FfiImportInspection {
        id: inspection.id.0,
        content_kind: map_content_kind(inspection.kind).to_owned(),
        display_name: inspection.display_name,
        description: inspection.description,
        representative_image: inspection
            .representative_image
            .map(|image| FfiImportImagePreview {
                logical_asset_id: image.logical_asset_id,
                media_type: image.media_type,
                size_bytes: image.size_bytes,
            }),
        source_sha256: inspection.source_sha256,
        source_size: inspection.source_size,
        estimated_stored_size: inspection.estimated_stored_size,
        asset_count: inspection.asset_count,
        warnings: inspection
            .warnings
            .into_iter()
            .map(|warning| FfiImportWarning {
                code: warning.code,
                message: warning.message,
            })
            .collect(),
        blocked_reasons: inspection.blocked_reasons,
        unsupported_optional_fields: inspection.unsupported_optional_fields,
        is_allowed,
    }
}

const fn map_content_kind(kind: ContentKind) -> &'static str {
    match kind {
        ContentKind::CharacterCardV3 => "character_card_v3",
        ContentKind::CharxPackage => "charx_package",
    }
}

fn map_conversation(conversation: Conversation) -> FfiConversation {
    FfiConversation {
        id: conversation.id.0,
        character_id: conversation.character_id,
        title: conversation.title,
        created_at: conversation.created_at.to_rfc3339(),
        updated_at: conversation.updated_at.to_rfc3339(),
    }
}

fn map_message(message: Message) -> FfiMessage {
    FfiMessage {
        id: message.id.0,
        conversation_id: message.conversation_id.0,
        parent_id: message.parent_id.map(|id| id.0),
        role: map_message_role(message.role).to_owned(),
        content: message.content,
        status: map_message_status(message.status).to_owned(),
        generation_id: message.generation_id.map(|id| id.0),
        created_at: message.created_at.to_rfc3339(),
    }
}

const fn map_message_role(role: MessageRole) -> &'static str {
    match role {
        MessageRole::System => "system",
        MessageRole::User => "user",
        MessageRole::Assistant => "assistant",
    }
}

const fn map_message_status(status: MessageStatus) -> &'static str {
    match status {
        MessageStatus::Pending => "pending",
        MessageStatus::Complete => "complete",
        MessageStatus::Cancelled => "cancelled",
        MessageStatus::Failed => "failed",
    }
}

fn map_provider_profile(profile: ProviderProfile) -> FfiProviderProfile {
    FfiProviderProfile {
        id: profile.id,
        display_name: profile.display_name,
        base_url: profile.base_url,
        model: profile.model,
        timeout_seconds: profile.timeout_seconds,
    }
}

fn unmap_provider_profile(profile: FfiProviderProfile) -> ProviderProfile {
    ProviderProfile {
        id: profile.id,
        display_name: profile.display_name,
        base_url: profile.base_url,
        model: profile.model,
        timeout_seconds: profile.timeout_seconds,
    }
}

fn map_settings(settings: AppSettings) -> FfiAppSettings {
    FfiAppSettings {
        preserve_partial_generations: settings.preserve_partial_generations,
        selected_provider_profile_id: settings.selected_provider_profile_id,
    }
}

fn unmap_settings(settings: FfiAppSettings) -> AppSettings {
    AppSettings {
        preserve_partial_generations: settings.preserve_partial_generations,
        selected_provider_profile_id: settings.selected_provider_profile_id,
    }
}

fn map_database_stats(stats: DatabaseStats) -> FfiDatabaseStats {
    FfiDatabaseStats {
        characters: stats.characters,
        conversations: stats.conversations,
        messages: stats.messages,
        pending_imports: stats.pending_imports,
    }
}

fn map_chat_event(event: ChatEvent) -> FfiChatEvent {
    let mut text = None;
    let mut message_id = None;
    let mut message_status = None;
    let mut error_code = None;
    let mut error_message = None;
    let mut usage_input_tokens = None;
    let mut usage_output_tokens = None;
    let kind = match event.kind {
        ChatEventKind::GenerationStarted => "generation_started",
        ChatEventKind::ReasoningDelta(delta) => {
            text = Some(delta);
            "reasoning_delta"
        }
        ChatEventKind::TextDelta(delta) => {
            text = Some(delta);
            "text_delta"
        }
        ChatEventKind::UsageUpdated(usage) => {
            usage_input_tokens = usage.input_tokens;
            usage_output_tokens = usage.output_tokens;
            "usage_updated"
        }
        ChatEventKind::MessageCommitted {
            message_id: committed_message_id,
            status,
        } => {
            message_id = Some(committed_message_id.0);
            message_status = Some(map_message_status(status).to_owned());
            "message_committed"
        }
        ChatEventKind::GenerationCancelled => "generation_cancelled",
        ChatEventKind::GenerationFailed { code, message } => {
            error_code = Some(code);
            error_message = Some(message);
            "generation_failed"
        }
        ChatEventKind::GenerationFinished => "generation_finished",
    };
    FfiChatEvent {
        event_version: event.event_version,
        generation_id: event.generation_id.0,
        conversation_id: event.conversation_id.0,
        sequence: event.sequence,
        emitted_at: event.emitted_at.to_rfc3339(),
        kind: kind.to_owned(),
        text,
        message_id,
        message_status,
        error_code,
        error_message,
        usage_input_tokens,
        usage_output_tokens,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::mpsc,
        thread,
        time::{Duration, Instant},
    };

    use lorepia_core::{CoreErrorCode, GenerationUsage, MessageId, MessageRole, MessageStatus};
    use tempfile::{NamedTempFile, tempdir};

    use super::*;

    fn read_request(stream: &mut TcpStream) {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("request timeout");
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4_096];
        loop {
            let read = stream.read(&mut buffer).expect("read request");
            if read == 0 {
                return;
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
                return;
            }
        }
    }

    fn spawn_completed_provider() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind provider");
        let address = listener.local_addr().expect("provider address");
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept provider request");
            read_request(&mut stream);
            let body = concat!(
                "data: {\"choices\":[{\"delta\":{\"content\":\"응답😀\"}}]}\n\n",
                "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":9,\"completion_tokens\":2}}\n\n",
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
        format!("http://{address}/v1")
    }

    fn spawn_stalling_provider() -> (String, mpsc::Receiver<()>, mpsc::Sender<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind provider");
        let address = listener.local_addr().expect("provider address");
        let (ready_sender, ready_receiver) = mpsc::channel();
        let (stop_sender, stop_receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept provider request");
            read_request(&mut stream);
            let event = "data: {\"choices\":[{\"delta\":{\"content\":\"부분😀\"}}]}\n\n";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:X}\r\n{}\r\n",
                event.len(),
                event
            )
            .expect("write provider chunk");
            stream.flush().expect("flush provider chunk");
            ready_sender.send(()).expect("provider ready");
            let _ = stop_receiver.recv_timeout(Duration::from_secs(5));
            let _ = stream.write_all(b"0\r\n\r\n");
        });
        (format!("http://{address}/v1"), ready_receiver, stop_sender)
    }

    fn import_character(
        core: &LorepiaCore,
        root: &std::path::Path,
        name: &str,
        description: &str,
    ) -> FfiCharacter {
        let mut card = NamedTempFile::new_in(root).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"{name}","description":"{description}"}}}}"#
        )
        .expect("write");
        card.flush().expect("flush");
        let inspection = core
            .inspect_import(card.path().to_string_lossy().into_owned())
            .expect("inspect");
        core.commit_import(inspection.id).expect("commit")
    }

    fn poll_until(
        core: &LorepiaCore,
        generation_id: &str,
        terminal_kind: &str,
    ) -> Vec<FfiChatEvent> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut received = Vec::new();
        loop {
            let batch = core.poll_events(64).expect("poll events");
            received.extend(
                batch
                    .events
                    .into_iter()
                    .filter(|event| event.generation_id == generation_id),
            );
            if received.iter().any(|event| event.kind == terminal_kind) {
                return received;
            }
            assert!(Instant::now() < deadline, "{terminal_kind} did not arrive");
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn opens_core_and_maps_version_health_and_empty_event_batch() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let health = core.health_check().expect("health");
        assert!(health.database_open);
        assert_eq!(health.core_version, core_version());
        let versions = version_info();
        assert_eq!(versions.core_version, core_version());
        assert_eq!(versions.core_api_version, lorepia_core::CORE_API_VERSION);
        assert_eq!(versions.core_api_version, 2);
        assert_eq!(versions.binding_api_version, BINDING_API_VERSION);
        assert_eq!(versions.binding_api_version, 2);
        assert_eq!(versions.chat_event_version, CHAT_EVENT_VERSION);
        assert!(core.poll_events(16).expect("poll").events.is_empty());
        let stats = core.database_stats().expect("database stats");
        assert_eq!(stats.characters, 0);
        assert_eq!(stats.conversations, 0);
        assert_eq!(stats.messages, 0);
        assert_eq!(stats.pending_imports, 0);
    }

    #[test]
    fn exposes_import_character_conversation_and_discard_flows() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Binding Test","description":"Synthetic"}}}}"#
        )
        .expect("write");
        card.flush().expect("flush");

        let inspection = core
            .inspect_import(card.path().to_string_lossy().into_owned())
            .expect("inspect");
        assert_eq!(inspection.content_kind, "character_card_v3");
        assert!(inspection.is_allowed);
        assert_eq!(inspection.display_name, "Binding Test");
        assert!(inspection.representative_image.is_none());
        assert!(inspection.unsupported_optional_fields.is_empty());
        let character = core.commit_import(inspection.id).expect("commit");
        assert_eq!(
            core.get_character(character.id.clone()).expect("get").id,
            character.id
        );
        assert_eq!(core.list_characters().expect("list").len(), 1);

        let conversation = core
            .open_conversation(character.id)
            .expect("open conversation");
        assert_eq!(
            core.list_conversations().expect("conversations")[0].id,
            conversation.id
        );
        assert!(
            core.list_messages(conversation.id)
                .expect("messages")
                .is_empty()
        );

        let second = core
            .inspect_import(card.path().to_string_lossy().into_owned())
            .expect("second inspect");
        core.discard_import(second.id).expect("discard");
        assert!(
            fs::read_dir(root.path().join("staging"))
                .expect("staging")
                .next()
                .is_none()
        );
    }

    #[test]
    fn maps_representative_image_and_unsupported_optional_fields() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let package = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../testdata/packages/with-avatar.charx");
        let package_inspection = core
            .inspect_import(package.to_string_lossy().into_owned())
            .expect("inspect package");
        let image = package_inspection
            .representative_image
            .expect("representative image");
        assert_eq!(image.logical_asset_id, "assets/avatar.png");
        assert_eq!(image.media_type, "image/png");
        assert_eq!(image.size_bytes, 70);
        core.discard_import(package_inspection.id)
            .expect("discard package");

        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{
                "name":"Optional",
                "description":"Consumed",
                "personality":"Unused",
                "creator":"Synthetic"
            }}}}"#
        )
        .expect("write");
        card.flush().expect("flush");
        let card_inspection = core
            .inspect_import(card.path().to_string_lossy().into_owned())
            .expect("inspect card");
        assert!(card_inspection.representative_image.is_none());
        assert_eq!(
            card_inspection.unsupported_optional_fields,
            ["creator", "personality"]
        );
        core.discard_import(card_inspection.id)
            .expect("discard card");
    }

    #[test]
    fn exposes_provider_profiles_and_settings() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let profile = FfiProviderProfile {
            id: "local".to_owned(),
            display_name: "Local Test".to_owned(),
            base_url: "https://example.invalid/v1".to_owned(),
            model: "synthetic".to_owned(),
            timeout_seconds: 15,
        };
        assert_eq!(
            core.upsert_provider_profile(profile)
                .expect("save profile")
                .id,
            "local"
        );
        assert_eq!(core.list_provider_profiles().expect("profiles").len(), 1);

        let settings = core
            .update_settings(FfiAppSettings {
                preserve_partial_generations: false,
                selected_provider_profile_id: Some("local".to_owned()),
            })
            .expect("update settings");
        assert!(!settings.preserve_partial_generations);
        assert_eq!(
            settings.selected_provider_profile_id.as_deref(),
            Some("local")
        );
        core.delete_provider_profile("local".to_owned())
            .expect("delete profile");
        assert!(
            core.get_settings()
                .expect("settings")
                .selected_provider_profile_id
                .is_none()
        );
    }

    #[test]
    fn round_trips_large_unicode_nullable_values_enums_and_empty_lists() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        assert!(core.list_characters().expect("characters").is_empty());
        assert!(core.list_conversations().expect("conversations").is_empty());
        assert!(
            core.list_provider_profiles()
                .expect("provider profiles")
                .is_empty()
        );
        assert!(
            core.get_settings()
                .expect("settings")
                .selected_provider_profile_id
                .is_none()
        );

        let name = "세구 😀 e\u{301}";
        let description = "큰문자열😀".repeat(8_192);
        let character = import_character(&core, root.path(), name, &description);
        assert_eq!(character.name, name);
        assert_eq!(character.description, description);
        assert!(character.avatar_asset_hash.is_none());

        let conversation = core
            .open_conversation(character.id)
            .expect("open conversation");
        assert_eq!(conversation.title, name);
        assert!(
            core.list_messages(conversation.id)
                .expect("empty message list")
                .is_empty()
        );

        let error = core
            .get_character("missing-character".to_owned())
            .expect_err("missing character");
        let FfiError::Core {
            code,
            recoverable,
            operation_id,
            ..
        } = error;
        assert_eq!(code, "not_found");
        assert!(!recoverable);
        assert!(!operation_id.is_empty());

        assert_eq!(
            [
                MessageRole::System,
                MessageRole::User,
                MessageRole::Assistant
            ]
            .map(map_message_role),
            ["system", "user", "assistant"]
        );
        assert_eq!(
            [
                MessageStatus::Pending,
                MessageStatus::Complete,
                MessageStatus::Cancelled,
                MessageStatus::Failed
            ]
            .map(map_message_status),
            ["pending", "complete", "cancelled", "failed"]
        );
        assert_eq!(
            [ContentKind::CharacterCardV3, ContentKind::CharxPackage].map(map_content_kind),
            ["character_card_v3", "charx_package"]
        );
    }

    #[test]
    fn maps_every_structured_event_variant_and_errors() {
        let generation_id = GenerationId("generation".to_owned());
        let conversation_id = ConversationId("conversation".to_owned());
        let kinds = vec![
            ChatEventKind::GenerationStarted,
            ChatEventKind::ReasoningDelta("생각".to_owned()),
            ChatEventKind::TextDelta("본문".to_owned()),
            ChatEventKind::UsageUpdated(GenerationUsage {
                input_tokens: Some(12),
                output_tokens: None,
            }),
            ChatEventKind::MessageCommitted {
                message_id: MessageId("message".to_owned()),
                status: MessageStatus::Complete,
            },
            ChatEventKind::GenerationCancelled,
            ChatEventKind::GenerationFailed {
                code: "network_unavailable".to_owned(),
                message: "offline".to_owned(),
            },
            ChatEventKind::GenerationFinished,
        ];
        let mapped = kinds
            .into_iter()
            .enumerate()
            .map(|(index, kind)| {
                map_chat_event(ChatEvent::new(
                    generation_id.clone(),
                    conversation_id.clone(),
                    index as u64 + 1,
                    kind,
                ))
            })
            .collect::<Vec<_>>();
        assert_eq!(
            mapped
                .iter()
                .map(|event| event.kind.as_str())
                .collect::<Vec<_>>(),
            [
                "generation_started",
                "reasoning_delta",
                "text_delta",
                "usage_updated",
                "message_committed",
                "generation_cancelled",
                "generation_failed",
                "generation_finished",
            ]
        );
        assert_eq!(mapped[1].text.as_deref(), Some("생각"));
        assert_eq!(mapped[2].text.as_deref(), Some("본문"));
        assert_eq!(mapped[3].usage_input_tokens, Some(12));
        assert_eq!(mapped[3].usage_output_tokens, None);
        assert_eq!(mapped[4].message_id.as_deref(), Some("message"));
        assert_eq!(mapped[4].message_status.as_deref(), Some("complete"));
        assert_eq!(mapped[6].error_code.as_deref(), Some("network_unavailable"));
        assert_eq!(mapped[6].error_message.as_deref(), Some("offline"));
        assert!(mapped[7].text.is_none());
        assert!(mapped[7].message_id.is_none());
        assert!(mapped[7].error_code.is_none());

        let error = FfiError::from(CoreError::new(
            CoreErrorCode::NetworkUnavailable,
            "offline",
            true,
        ));
        let FfiError::Core {
            code,
            detail,
            recoverable,
            operation_id,
        } = error;
        assert_eq!(code, "network_unavailable");
        assert_eq!(detail, "offline");
        assert!(recoverable);
        assert!(!operation_id.is_empty());
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn live_binding_preserves_event_order_large_unicode_and_cancellation() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let character = import_character(&core, root.path(), "세구", "바인딩 이벤트 테스트");
        let conversation = core
            .open_conversation(character.id)
            .expect("open conversation");

        let profile = core
            .upsert_provider_profile(FfiProviderProfile {
                id: "completed".to_owned(),
                display_name: "완료 제공자".to_owned(),
                base_url: spawn_completed_provider(),
                model: "synthetic".to_owned(),
                timeout_seconds: 5,
            })
            .expect("save provider");
        let large_unicode_message = "질문😀".repeat(4_096);
        let generation_id = core
            .send_message(
                conversation.id.clone(),
                large_unicode_message.clone(),
                profile.id,
                None,
            )
            .expect("send message");
        let events = poll_until(&core, &generation_id, "generation_finished");
        assert!(
            events
                .windows(2)
                .all(|pair| pair[0].sequence < pair[1].sequence)
        );
        assert_eq!(
            events.first().map(|event| event.kind.as_str()),
            Some("generation_started")
        );
        assert!(
            events
                .iter()
                .any(|event| event.kind == "text_delta" && event.text.as_deref() == Some("응답😀"))
        );
        assert!(events.iter().any(|event| event.kind == "usage_updated"
            && event.usage_input_tokens == Some(9)
            && event.usage_output_tokens == Some(2)));
        assert_eq!(
            events.last().map(|event| event.kind.as_str()),
            Some("generation_finished")
        );
        let messages = core
            .list_messages(conversation.id.clone())
            .expect("completed messages");
        assert_eq!(messages[0].content, large_unicode_message);
        assert_eq!(messages[0].role, "user");
        assert_eq!(messages[1].content, "응답😀");
        assert_eq!(messages[1].role, "assistant");
        assert_eq!(messages[1].status, "complete");
        assert!(messages[0].parent_id.is_none());
        assert!(messages[0].generation_id.is_none());
        assert!(messages[1].generation_id.is_some());

        let (base_url, provider_ready, provider_stop) = spawn_stalling_provider();
        let cancellation_profile = core
            .upsert_provider_profile(FfiProviderProfile {
                id: "cancellation".to_owned(),
                display_name: "취소 제공자".to_owned(),
                base_url,
                model: "synthetic".to_owned(),
                timeout_seconds: 5,
            })
            .expect("save cancellation provider");
        let character = core
            .list_characters()
            .expect("characters")
            .into_iter()
            .next()
            .expect("character");
        let cancellation_conversation = core
            .open_conversation(character.id)
            .expect("open cancellation conversation");
        let cancellation_id = core
            .send_message(
                cancellation_conversation.id.clone(),
                "중지해".to_owned(),
                cancellation_profile.id,
                None,
            )
            .expect("send cancellation message");
        provider_ready
            .recv_timeout(Duration::from_secs(2))
            .expect("provider started");

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut cancellation_events = Vec::new();
        loop {
            let batch = core.poll_events(64).expect("poll partial event");
            cancellation_events.extend(
                batch
                    .events
                    .into_iter()
                    .filter(|event| event.generation_id == cancellation_id),
            );
            if cancellation_events
                .iter()
                .any(|event| event.kind == "text_delta")
            {
                break;
            }
            assert!(Instant::now() < deadline, "text delta did not arrive");
            thread::sleep(Duration::from_millis(10));
        }
        core.cancel_generation(cancellation_id.clone())
            .expect("cancel");
        cancellation_events.extend(poll_until(&core, &cancellation_id, "generation_cancelled"));
        let _ = provider_stop.send(());

        assert!(
            cancellation_events
                .windows(2)
                .all(|pair| pair[0].sequence < pair[1].sequence)
        );
        assert_eq!(
            cancellation_events.last().map(|event| event.kind.as_str()),
            Some("generation_cancelled")
        );
        let messages = core
            .list_messages(cancellation_conversation.id)
            .expect("cancelled messages");
        assert_eq!(messages[1].content, "부분😀");
        assert_eq!(messages[1].status, "cancelled");
    }

    #[test]
    fn validates_event_batch_bounds() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        for size in [0, MAX_EVENT_BATCH_SIZE + 1] {
            let error = core.poll_events(size).expect_err("invalid batch");
            let FfiError::Core { code, .. } = error;
            assert_eq!(code, "invalid_input");
        }
    }
}
