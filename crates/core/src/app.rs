use std::{
    collections::HashMap,
    fs::{self, File, OpenOptions},
    future::Future,
    io::{BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, RwLock},
    time::{Duration, Instant},
};

use chrono::Utc;
use lorepia_chat::{
    ChatEvent, ChatEventKind, GenerationFailure, GenerationOutcome, MAX_HISTORY_MESSAGE_BYTES,
    MAX_HISTORY_MESSAGE_CHARS, MAX_PROMPT_MESSAGES, PromptPlanner, run_generation,
};
use lorepia_content::{StagedAsset, prepare_import};
use lorepia_domain::{
    AppSettings, Character, Conversation, ConversationBranch, ConversationBranchId, ConversationId,
    ConversationMode, ConversationState, CoreError, CoreErrorCode, CoreResult, GenerationId,
    GenerationRecord, GenerationRequest, GenerationStatus, HealthReport, ImportInspection,
    ImportLimits, InspectionId, Message, MessageActionGeneration, MessageId, MessageStatus,
    ProviderProfile,
};
use lorepia_providers::{OpenAiCompatibleProvider, Provider};
use lorepia_storage::{DatabaseStats, MessageGenerationAction, StagedAssetImport, Storage};
use tokio::{
    runtime::{Builder, Handle},
    sync::{broadcast, mpsc, watch},
    time::{self, MissedTickBehavior},
};
use uuid::Uuid;

use crate::{CoreConfig, core_version};

const CORE_MAX_OUTPUT_TOKENS: u32 = 4_096;
const GENERATION_SHUTDOWN_GRACE: Duration = Duration::from_millis(750);
const RUNTIME_SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(1);
const PARTIAL_CHECKPOINT_INTERVAL: Duration = Duration::from_millis(500);
const PARTIAL_CHECKPOINT_BYTES: usize = 64 * 1024;
const MAX_USER_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_USER_MESSAGE_CHARS: usize = 16 * 1024;
const MAX_PROVIDER_ID_BYTES: usize = 256;
const MAX_PROVIDER_ID_CHARS: usize = 64;
const MAX_PROVIDER_DISPLAY_NAME_BYTES: usize = 512;
const MAX_PROVIDER_DISPLAY_NAME_CHARS: usize = 128;
const MAX_PROVIDER_BASE_URL_BYTES: usize = 4 * 1024;
const MAX_PROVIDER_BASE_URL_CHARS: usize = 1_024;
const MAX_PROVIDER_MODEL_BYTES: usize = 1_024;
const MAX_PROVIDER_MODEL_CHARS: usize = 256;
const MAX_CONVERSATION_TITLE_BYTES: usize = 1_024;
const MAX_CONVERSATION_TITLE_CHARS: usize = 256;
const MAX_BRANCH_TITLE_BYTES: usize = 1_024;
const MAX_BRANCH_TITLE_CHARS: usize = 256;
const GENERATION_PERSISTENCE_FAILURE_MESSAGE: &str =
    "generation state could not be saved; retry the message";

#[derive(Clone)]
pub struct Core {
    inner: Arc<CoreInner>,
}

struct CoreInner {
    storage: Arc<Storage>,
    runtime: RuntimeControl,
    pending_imports: RwLock<HashMap<InspectionId, PendingImport>>,
    active_generations: Arc<GenerationRegistry>,
    event_bus: broadcast::Sender<ChatEvent>,
}

struct RuntimeControl {
    handle: Handle,
    shutdown_sender: Option<tokio::sync::oneshot::Sender<()>>,
    owner_thread: Option<std::thread::JoinHandle<()>>,
}

#[derive(Default)]
struct GenerationRegistry {
    active: Mutex<HashMap<GenerationId, watch::Sender<bool>>>,
    drained: Condvar,
}

#[derive(Clone)]
struct PendingImport {
    path: PathBuf,
    inspection: ImportInspection,
    staged_assets: Vec<StagedAsset>,
}

struct GenerationTask {
    storage: Arc<Storage>,
    active_generations: Arc<GenerationRegistry>,
    event_bus: broadcast::Sender<ChatEvent>,
    branch_id: ConversationBranchId,
    request: GenerationRequest,
    assistant: Message,
    provider: Arc<dyn Provider>,
    credential: Option<String>,
    cancel_receiver: watch::Receiver<bool>,
    preserve_partial: bool,
}

struct TerminalPersistenceContext<'a> {
    storage: &'a Storage,
    event_bus: &'a broadcast::Sender<ChatEvent>,
    generation_id: &'a GenerationId,
    conversation_id: &'a ConversationId,
    branch_id: &'a ConversationBranchId,
    assistant_message_id: &'a MessageId,
}

struct GenerationLaunchPermit {
    generation_id: GenerationId,
    active_generations: Arc<GenerationRegistry>,
    cancel_receiver: Option<watch::Receiver<bool>>,
    preserve_partial: bool,
}

struct ActiveGenerationGuard {
    generation_id: GenerationId,
    active_generations: Arc<GenerationRegistry>,
}

impl GenerationLaunchPermit {
    #[allow(clippy::too_many_arguments)]
    fn into_task(
        mut self,
        storage: Arc<Storage>,
        event_bus: broadcast::Sender<ChatEvent>,
        branch_id: ConversationBranchId,
        request: GenerationRequest,
        assistant: Message,
        provider: Arc<dyn Provider>,
        credential: Option<String>,
    ) -> GenerationTask {
        let cancel_receiver = self
            .cancel_receiver
            .take()
            .expect("generation launch permit can be consumed only once");
        GenerationTask {
            storage,
            active_generations: Arc::clone(&self.active_generations),
            event_bus,
            branch_id,
            request,
            assistant,
            provider,
            credential,
            cancel_receiver,
            preserve_partial: self.preserve_partial,
        }
    }
}

impl Drop for GenerationLaunchPermit {
    fn drop(&mut self) {
        if self.cancel_receiver.is_some() {
            self.active_generations.remove(&self.generation_id);
        }
    }
}

impl Drop for ActiveGenerationGuard {
    fn drop(&mut self) {
        self.active_generations.remove(&self.generation_id);
    }
}

impl RuntimeControl {
    fn start() -> CoreResult<Self> {
        let (ready_sender, ready_receiver) =
            std::sync::mpsc::sync_channel::<Result<Handle, String>>(1);
        let (shutdown_sender, shutdown_receiver) = tokio::sync::oneshot::channel();
        let owner_thread = std::thread::Builder::new()
            .name("lorepia-core-owner".to_owned())
            .spawn(move || {
                let runtime = match Builder::new_multi_thread()
                    .worker_threads(2)
                    .enable_all()
                    .thread_name("lorepia-core-worker")
                    .build()
                {
                    Ok(runtime) => runtime,
                    Err(error) => {
                        let _ = ready_sender
                            .send(Err(format!("cannot create core async runtime: {error}")));
                        return;
                    }
                };
                if ready_sender.send(Ok(runtime.handle().clone())).is_err() {
                    runtime.shutdown_timeout(RUNTIME_SHUTDOWN_TIMEOUT);
                    return;
                }
                let _ = runtime.block_on(shutdown_receiver);
                runtime.shutdown_timeout(RUNTIME_SHUTDOWN_TIMEOUT);
            })
            .map_err(|error| {
                CoreError::internal(format!("cannot start core runtime owner: {error}"))
            })?;

        match ready_receiver.recv() {
            Ok(Ok(handle)) => Ok(Self {
                handle,
                shutdown_sender: Some(shutdown_sender),
                owner_thread: Some(owner_thread),
            }),
            Ok(Err(message)) => {
                let _ = owner_thread.join();
                Err(CoreError::internal(message))
            }
            Err(error) => {
                let _ = owner_thread.join();
                Err(CoreError::internal(format!(
                    "core runtime owner stopped during startup: {error}"
                )))
            }
        }
    }

    fn spawn(&self, future: impl Future<Output = ()> + Send + 'static) {
        std::mem::drop(self.handle.spawn(future));
    }

    fn shutdown(&mut self) {
        if let Some(sender) = self.shutdown_sender.take() {
            let _ = sender.send(());
        }
        if let Some(owner_thread) = self.owner_thread.take() {
            let _ = owner_thread.join();
        }
    }
}

impl GenerationRegistry {
    fn register(&self, generation_id: GenerationId, sender: watch::Sender<bool>) -> CoreResult<()> {
        self.active
            .lock()
            .map_err(|_| CoreError::internal("generation registry lock was poisoned"))?
            .insert(generation_id, sender);
        Ok(())
    }

    fn cancel(&self, generation_id: &GenerationId) -> CoreResult<()> {
        let sender = self
            .active
            .lock()
            .map_err(|_| CoreError::internal("generation registry lock was poisoned"))?
            .get(generation_id)
            .cloned()
            .ok_or_else(|| {
                CoreError::new(CoreErrorCode::NotFound, "generation was not found", false)
            })?;
        sender.send(true).map_err(|_| {
            CoreError::new(CoreErrorCode::Cancelled, "generation already stopped", true)
        })
    }

    fn remove(&self, generation_id: &GenerationId) {
        if let Ok(mut active) = self.active.lock() {
            active.remove(generation_id);
            if active.is_empty() {
                self.drained.notify_all();
            }
        }
    }

    fn len(&self) -> usize {
        self.active.lock().map_or(0, |active| active.len())
    }

    fn cancel_all_and_wait(&self, timeout: Duration) {
        let Ok(mut active) = self.active.lock() else {
            return;
        };
        for sender in active.values() {
            let _ = sender.send(true);
        }
        let deadline = Instant::now() + timeout;
        while !active.is_empty() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            if remaining.is_zero() {
                break;
            }
            match self.drained.wait_timeout(active, remaining) {
                Ok((next, result)) => {
                    active = next;
                    if result.timed_out() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    }
}

impl Drop for CoreInner {
    fn drop(&mut self) {
        self.active_generations
            .cancel_all_and_wait(GENERATION_SHUTDOWN_GRACE);
        self.runtime.shutdown();
    }
}

impl Core {
    pub fn open(config: CoreConfig) -> CoreResult<Self> {
        let storage = Arc::new(Storage::open(config.data_root)?);
        let runtime = RuntimeControl::start()?;
        let (event_bus, _) = broadcast::channel(256);
        Ok(Self {
            inner: Arc::new(CoreInner {
                storage,
                runtime,
                pending_imports: RwLock::new(HashMap::new()),
                active_generations: Arc::new(GenerationRegistry::default()),
                event_bus,
            }),
        })
    }

    pub fn health_check(&self) -> CoreResult<HealthReport> {
        Ok(HealthReport {
            core_version: core_version().to_owned(),
            database_open: true,
            schema_version: self.inner.storage.schema_version(),
            data_root_writable: directory_is_writable(self.inner.storage.data_root()),
            staging_writable: directory_is_writable(&self.inner.storage.staging_dir()),
            recovery_pending: self.inner.storage.recovery_pending()?,
            active_jobs: u32::try_from(self.active_generation_count()).unwrap_or(u32::MAX),
        })
    }

    pub fn inspect_import(&self, staged_path: impl AsRef<Path>) -> CoreResult<ImportInspection> {
        let limits = ImportLimits::default();
        let snapshot = snapshot_import_source(
            staged_path.as_ref(),
            &self.inner.storage.staging_dir(),
            limits.max_source_bytes,
        )?;
        let prepared = match prepare_import(&snapshot, limits, &self.inner.storage.staging_dir()) {
            Ok(prepared) => prepared,
            Err(error) => {
                let _ = fs::remove_file(&snapshot);
                return Err(error);
            }
        };
        let inspection = prepared.inspection;
        self.inner
            .pending_imports
            .write()
            .map_err(|_| CoreError::internal("pending import lock was poisoned"))?
            .insert(
                inspection.id.clone(),
                PendingImport {
                    path: snapshot,
                    inspection: inspection.clone(),
                    staged_assets: prepared.staged_assets,
                },
            );
        Ok(inspection)
    }

    pub fn commit_import(&self, inspection_id: &InspectionId) -> CoreResult<Character> {
        let pending = self
            .inner
            .pending_imports
            .write()
            .map_err(|_| CoreError::internal("pending import lock was poisoned"))?
            .remove(inspection_id)
            .ok_or_else(|| {
                CoreError::new(CoreErrorCode::NotFound, "inspection was not found", false)
            })?;
        if !pending.inspection.is_allowed() {
            let error = CoreError::new(
                CoreErrorCode::UnsafeArchive,
                "blocked import cannot be committed",
                false,
            );
            self.restore_pending_import(inspection_id.clone(), pending)?;
            return Err(error);
        }
        let mut character = Character::new(
            &pending.inspection.display_name,
            &pending.inspection.description,
            &pending.inspection.source_sha256,
        );
        character.avatar_asset_hash = pending
            .staged_assets
            .iter()
            .find(|asset| asset.signature_valid && asset.media_type.starts_with("image/"))
            .map(|asset| asset.sha256.clone());
        let staged_assets = pending
            .staged_assets
            .iter()
            .map(|asset| StagedAssetImport {
                staged_path: asset.staged_path.clone(),
                sha256: asset.sha256.clone(),
                media_type: asset.media_type.clone(),
                size_bytes: asset.size_bytes,
            })
            .collect::<Vec<_>>();
        let commit = self.inner.storage.commit_character_import(
            &pending.path,
            &character,
            pending.inspection.source_size,
            &inspection_id.0,
            &staged_assets,
        );
        match commit {
            Ok(()) => {
                let _ = cleanup_pending_import(&pending, &self.inner.storage.staging_dir());
                Ok(character)
            }
            Err(error) => match self.inner.storage.get_character(&character.id) {
                Ok(committed) => {
                    let _ = cleanup_pending_import(&pending, &self.inner.storage.staging_dir());
                    Ok(committed)
                }
                Err(lookup) if lookup.code == CoreErrorCode::NotFound => {
                    self.restore_pending_import(inspection_id.clone(), pending)?;
                    Err(error)
                }
                Err(_) => Err(error),
            },
        }
    }

    pub fn discard_import(&self, inspection_id: &InspectionId) -> CoreResult<()> {
        let pending = self
            .inner
            .pending_imports
            .write()
            .map_err(|_| CoreError::internal("pending import lock was poisoned"))?
            .remove(inspection_id)
            .ok_or_else(|| {
                CoreError::new(CoreErrorCode::NotFound, "inspection was not found", false)
            })?;
        cleanup_pending_import(&pending, &self.inner.storage.staging_dir())
    }

    pub fn list_characters(&self) -> CoreResult<Vec<Character>> {
        self.inner.storage.list_characters()
    }

    pub fn get_character(&self, id: &str) -> CoreResult<Character> {
        self.inner.storage.get_character(id)
    }

    pub fn open_conversation(&self, character_id: &str) -> CoreResult<Conversation> {
        let character = self.get_character(character_id)?;
        self.create_conversation(&character.id, character.name, ConversationMode::Chat)
    }

    pub fn create_conversation(
        &self,
        character_id: &str,
        title: impl Into<String>,
        mode: ConversationMode,
    ) -> CoreResult<Conversation> {
        self.get_character(character_id)?;
        let title = normalize_bounded_text(
            "conversation title",
            title.into(),
            MAX_CONVERSATION_TITLE_BYTES,
            MAX_CONVERSATION_TITLE_CHARS,
        )?;
        let conversation = Conversation::new(character_id, title);
        self.inner
            .storage
            .save_conversation_with_mode(&conversation, mode)?;
        Ok(conversation)
    }

    pub fn list_conversations(&self) -> CoreResult<Vec<Conversation>> {
        self.inner.storage.list_conversations()
    }

    pub fn list_conversations_for_character(
        &self,
        character_id: &str,
    ) -> CoreResult<Vec<Conversation>> {
        self.get_character(character_id)?;
        self.inner
            .storage
            .list_conversations_for_character(character_id)
    }

    pub fn get_conversation(&self, conversation_id: &ConversationId) -> CoreResult<Conversation> {
        self.inner.storage.get_conversation(conversation_id)
    }

    pub fn get_conversation_state(
        &self,
        conversation_id: &ConversationId,
    ) -> CoreResult<ConversationState> {
        self.inner.storage.get_conversation_state(conversation_id)
    }

    pub fn list_conversation_branches(
        &self,
        conversation_id: &ConversationId,
    ) -> CoreResult<Vec<ConversationBranch>> {
        self.inner.storage.get_conversation(conversation_id)?;
        self.inner
            .storage
            .list_conversation_branches(conversation_id)
    }

    pub fn create_conversation_branch(
        &self,
        conversation_id: &ConversationId,
        from_message_id: Option<&MessageId>,
        title: Option<String>,
    ) -> CoreResult<ConversationBranch> {
        let title = title
            .map(|title| {
                normalize_bounded_text(
                    "conversation branch title",
                    title,
                    MAX_BRANCH_TITLE_BYTES,
                    MAX_BRANCH_TITLE_CHARS,
                )
            })
            .transpose()?;
        self.inner
            .storage
            .create_conversation_branch(conversation_id, from_message_id, title)
    }

    pub fn select_conversation_branch(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
    ) -> CoreResult<ConversationState> {
        self.inner
            .storage
            .select_conversation_branch(conversation_id, branch_id)
    }

    pub fn set_conversation_mode(
        &self,
        conversation_id: &ConversationId,
        mode: ConversationMode,
    ) -> CoreResult<ConversationState> {
        self.inner
            .storage
            .set_conversation_mode(conversation_id, mode)
    }

    pub fn list_branch_messages(
        &self,
        branch_id: &ConversationBranchId,
    ) -> CoreResult<Vec<Message>> {
        self.inner.storage.list_branch_messages(branch_id)
    }

    pub fn list_messages(&self, conversation_id: &ConversationId) -> CoreResult<Vec<Message>> {
        let state = self.inner.storage.get_conversation_state(conversation_id)?;
        self.inner
            .storage
            .list_branch_messages(&state.active_branch_id)
    }

    pub fn send_message(
        &self,
        conversation_id: &ConversationId,
        text: &str,
        provider_profile_id: &str,
        credential: Option<String>,
    ) -> CoreResult<GenerationId> {
        let profile = self
            .inner
            .storage
            .get_provider_profile(provider_profile_id)?;
        let provider = Arc::new(OpenAiCompatibleProvider::new(
            &profile.base_url,
            Duration::from_secs(u64::from(profile.timeout_seconds.max(1))),
        )?);
        let state = self.inner.storage.get_conversation_state(conversation_id)?;
        let branch = self
            .inner
            .storage
            .get_conversation_branch(&state.active_branch_id)?;
        self.send_message_to_branch_with_provider(
            conversation_id,
            &state.active_branch_id,
            branch.head_message_id.as_ref(),
            state.selected_mode,
            text,
            profile.model,
            credential,
            provider,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn send_message_to_branch(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        mode: ConversationMode,
        text: &str,
        provider_profile_id: &str,
        credential: Option<String>,
    ) -> CoreResult<GenerationId> {
        let profile = self
            .inner
            .storage
            .get_provider_profile(provider_profile_id)?;
        let provider = Arc::new(OpenAiCompatibleProvider::new(
            &profile.base_url,
            Duration::from_secs(u64::from(profile.timeout_seconds.max(1))),
        )?);
        self.send_message_to_branch_with_provider(
            conversation_id,
            branch_id,
            expected_head,
            mode,
            text,
            profile.model,
            credential,
            provider,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn edit_user_message(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
        replacement_text: &str,
        provider_profile_id: &str,
        credential: Option<String>,
    ) -> CoreResult<MessageActionGeneration> {
        let profile = self
            .inner
            .storage
            .get_provider_profile(provider_profile_id)?;
        let provider = Arc::new(OpenAiCompatibleProvider::new(
            &profile.base_url,
            Duration::from_secs(u64::from(profile.timeout_seconds.max(1))),
        )?);
        self.start_message_generation_action_with_provider(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
            MessageGenerationAction::EditUser,
            Some(replacement_text),
            profile.model,
            credential,
            provider,
        )
    }

    #[allow(clippy::too_many_arguments)]
    pub fn regenerate_assistant_message(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
        provider_profile_id: &str,
        credential: Option<String>,
    ) -> CoreResult<MessageActionGeneration> {
        let profile = self
            .inner
            .storage
            .get_provider_profile(provider_profile_id)?;
        let provider = Arc::new(OpenAiCompatibleProvider::new(
            &profile.base_url,
            Duration::from_secs(u64::from(profile.timeout_seconds.max(1))),
        )?);
        self.start_message_generation_action_with_provider(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
            MessageGenerationAction::RegenerateAssistant,
            None,
            profile.model,
            credential,
            provider,
        )
    }

    pub fn remove_message_from_branch(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
    ) -> CoreResult<ConversationBranch> {
        self.inner.storage.remove_message_from_branch(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
        )
    }

    pub fn cancel_generation(&self, generation_id: &GenerationId) -> CoreResult<()> {
        self.inner.active_generations.cancel(generation_id)
    }

    pub fn subscribe_events(&self) -> broadcast::Receiver<ChatEvent> {
        self.inner.event_bus.subscribe()
    }

    pub fn get_settings(&self) -> CoreResult<AppSettings> {
        self.inner.storage.load_settings()
    }

    pub fn update_settings(&self, settings: &AppSettings) -> CoreResult<()> {
        self.inner.storage.save_settings(settings)
    }

    pub fn list_provider_profiles(&self) -> CoreResult<Vec<ProviderProfile>> {
        self.inner.storage.list_provider_profiles()
    }

    pub fn upsert_provider_profile(
        &self,
        mut profile: ProviderProfile,
    ) -> CoreResult<ProviderProfile> {
        profile.id = normalize_bounded_text(
            "provider profile id",
            std::mem::take(&mut profile.id),
            MAX_PROVIDER_ID_BYTES,
            MAX_PROVIDER_ID_CHARS,
        )?;
        profile.display_name = normalize_bounded_text(
            "provider display name",
            std::mem::take(&mut profile.display_name),
            MAX_PROVIDER_DISPLAY_NAME_BYTES,
            MAX_PROVIDER_DISPLAY_NAME_CHARS,
        )?;
        profile.base_url = normalize_bounded_text(
            "provider base URL",
            std::mem::take(&mut profile.base_url),
            MAX_PROVIDER_BASE_URL_BYTES,
            MAX_PROVIDER_BASE_URL_CHARS,
        )?;
        profile.model = normalize_bounded_text(
            "provider model",
            std::mem::take(&mut profile.model),
            MAX_PROVIDER_MODEL_BYTES,
            MAX_PROVIDER_MODEL_CHARS,
        )?;
        if profile.timeout_seconds == 0 || profile.timeout_seconds > 600 {
            return Err(CoreError::invalid(
                "provider profile requires an id, display name, model, and a timeout from 1 to 600 seconds",
            ));
        }
        OpenAiCompatibleProvider::new(
            &profile.base_url,
            Duration::from_secs(u64::from(profile.timeout_seconds)),
        )?;
        self.inner.storage.save_provider_profile(&profile)?;
        Ok(profile)
    }

    pub fn delete_provider_profile(&self, id: &str) -> CoreResult<()> {
        self.inner.storage.delete_provider_profile(id)
    }

    pub fn database_stats(&self) -> CoreResult<DatabaseStats> {
        self.inner.storage.stats()
    }

    fn restore_pending_import(
        &self,
        inspection_id: InspectionId,
        pending: PendingImport,
    ) -> CoreResult<()> {
        let mut imports = self
            .inner
            .pending_imports
            .write()
            .map_err(|_| CoreError::internal("pending import lock was poisoned"))?;
        if let std::collections::hash_map::Entry::Vacant(entry) = imports.entry(inspection_id) {
            entry.insert(pending);
            Ok(())
        } else {
            Err(CoreError::internal(
                "inspection claim collided while restoring a retryable import",
            ))
        }
    }

    #[cfg(test)]
    fn send_message_with_provider(
        &self,
        conversation_id: &ConversationId,
        text: &str,
        model: String,
        credential: Option<String>,
        provider: Arc<dyn Provider>,
    ) -> CoreResult<GenerationId> {
        let state = self.inner.storage.get_conversation_state(conversation_id)?;
        let branch = self
            .inner
            .storage
            .get_conversation_branch(&state.active_branch_id)?;
        self.send_message_to_branch_with_provider(
            conversation_id,
            &state.active_branch_id,
            branch.head_message_id.as_ref(),
            state.selected_mode,
            text,
            model,
            credential,
            provider,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn send_message_to_branch_with_provider(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        mode: ConversationMode,
        text: &str,
        model: String,
        credential: Option<String>,
        provider: Arc<dyn Provider>,
    ) -> CoreResult<GenerationId> {
        let text = validate_user_message_text(text)?;
        let conversation = self.inner.storage.get_conversation(conversation_id)?;
        let character = self
            .inner
            .storage
            .get_character(&conversation.character_id)?;
        let branch = self.inner.storage.get_conversation_branch(branch_id)?;
        if branch.conversation_id != *conversation_id {
            return Err(CoreError::new(
                CoreErrorCode::NotFound,
                "conversation branch was not found in the conversation",
                false,
            ));
        }
        let user_message =
            Message::user_after(conversation_id.clone(), expected_head.cloned(), text);
        let mut history = self.inner.storage.list_recent_branch_messages_for_prompt(
            branch_id,
            MAX_PROMPT_MESSAGES.saturating_sub(2),
            MAX_HISTORY_MESSAGE_BYTES,
            MAX_HISTORY_MESSAGE_CHARS,
        )?;
        history.push(user_message.clone());
        let request = PromptPlanner::plan_with_mode(
            &character,
            conversation_id.clone(),
            mode,
            &history,
            model.clone(),
            1.0,
            Some(CORE_MAX_OUTPUT_TOKENS),
        )?;
        let generation_id = request.generation_id.clone();
        let assistant_message = Message::pending_assistant(
            conversation_id.clone(),
            user_message.id.clone(),
            generation_id.clone(),
        );
        let generation = GenerationRecord {
            id: generation_id.clone(),
            conversation_id: conversation_id.clone(),
            branch_id: branch_id.clone(),
            user_message_id: user_message.id.clone(),
            assistant_message_id: Some(assistant_message.id.clone()),
            mode,
            model,
            status: GenerationStatus::Running,
            input_tokens: None,
            output_tokens: None,
            error_code: None,
            started_at: assistant_message.created_at,
            finished_at: None,
        };
        let launch = self.prepare_generation_launch(&generation_id)?;
        self.inner.storage.append_generation(
            branch_id,
            expected_head,
            &user_message,
            &assistant_message,
            &generation,
        )?;
        Ok(self.start_generation_task(
            launch,
            branch_id.clone(),
            request,
            assistant_message,
            provider,
            credential,
        ))
    }

    #[cfg(test)]
    #[allow(clippy::too_many_arguments)]
    fn edit_user_message_with_provider(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
        replacement_text: &str,
        model: String,
        credential: Option<String>,
        provider: Arc<dyn Provider>,
    ) -> CoreResult<MessageActionGeneration> {
        self.start_message_generation_action_with_provider(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
            MessageGenerationAction::EditUser,
            Some(replacement_text),
            model,
            credential,
            provider,
        )
    }

    #[cfg(test)]
    #[allow(clippy::too_many_arguments)]
    fn regenerate_assistant_message_with_provider(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
        model: String,
        credential: Option<String>,
        provider: Arc<dyn Provider>,
    ) -> CoreResult<MessageActionGeneration> {
        self.start_message_generation_action_with_provider(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
            MessageGenerationAction::RegenerateAssistant,
            None,
            model,
            credential,
            provider,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn start_message_generation_action_with_provider(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
        action: MessageGenerationAction,
        replacement_text: Option<&str>,
        model: String,
        credential: Option<String>,
        provider: Arc<dyn Provider>,
    ) -> CoreResult<MessageActionGeneration> {
        let replacement_text = validate_action_replacement(action, replacement_text)?;

        let conversation = self.inner.storage.get_conversation(conversation_id)?;
        let character = self
            .inner
            .storage
            .get_character(&conversation.character_id)?;
        let state = self.inner.storage.get_conversation_state(conversation_id)?;
        let context = self.inner.storage.prepare_message_generation_action(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
            action,
        )?;
        let text = match replacement_text {
            Some(text) => text,
            None => validate_user_message_text(&context.user_text)?,
        };
        let user_message = Message::user_after(
            conversation_id.clone(),
            context.fork_message_id.clone(),
            text,
        );
        let mut history = self.inner.storage.list_recent_message_lineage_for_prompt(
            conversation_id,
            context.fork_message_id.as_ref(),
            MAX_PROMPT_MESSAGES.saturating_sub(2),
            MAX_HISTORY_MESSAGE_BYTES,
            MAX_HISTORY_MESSAGE_CHARS,
        )?;
        history.push(user_message.clone());
        let request = PromptPlanner::plan_with_mode(
            &character,
            conversation_id.clone(),
            state.selected_mode,
            &history,
            model.clone(),
            1.0,
            Some(CORE_MAX_OUTPUT_TOKENS),
        )?;
        let generation_id = request.generation_id.clone();
        let assistant_message = Message::pending_assistant(
            conversation_id.clone(),
            user_message.id.clone(),
            generation_id.clone(),
        );
        let now = Utc::now();
        let branch = ConversationBranch {
            id: ConversationBranchId::new(),
            conversation_id: conversation_id.clone(),
            title: None,
            fork_message_id: context.fork_message_id,
            head_message_id: Some(assistant_message.id.clone()),
            created_at: now,
            updated_at: now,
        };
        let generation = GenerationRecord {
            id: generation_id.clone(),
            conversation_id: conversation_id.clone(),
            branch_id: branch.id.clone(),
            user_message_id: user_message.id.clone(),
            assistant_message_id: Some(assistant_message.id.clone()),
            mode: state.selected_mode,
            model,
            status: GenerationStatus::Running,
            input_tokens: None,
            output_tokens: None,
            error_code: None,
            started_at: assistant_message.created_at,
            finished_at: None,
        };
        let launch = self.prepare_generation_launch(&generation_id)?;
        self.inner.storage.append_message_generation_action(
            branch_id,
            expected_head,
            message_id,
            action,
            &branch,
            &user_message,
            &assistant_message,
            &generation,
        )?;
        self.start_generation_task(
            launch,
            branch.id.clone(),
            request,
            assistant_message,
            provider,
            credential,
        );
        Ok(MessageActionGeneration {
            branch,
            generation_id,
        })
    }

    fn prepare_generation_launch(
        &self,
        generation_id: &GenerationId,
    ) -> CoreResult<GenerationLaunchPermit> {
        let preserve_partial = self
            .inner
            .storage
            .load_settings()?
            .preserve_partial_generations;
        let (cancel_sender, cancel_receiver) = watch::channel(false);
        self.inner
            .active_generations
            .register(generation_id.clone(), cancel_sender)?;
        Ok(GenerationLaunchPermit {
            generation_id: generation_id.clone(),
            active_generations: Arc::clone(&self.inner.active_generations),
            cancel_receiver: Some(cancel_receiver),
            preserve_partial,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn start_generation_task(
        &self,
        launch: GenerationLaunchPermit,
        branch_id: ConversationBranchId,
        request: GenerationRequest,
        assistant_message: Message,
        provider: Arc<dyn Provider>,
        credential: Option<String>,
    ) -> GenerationId {
        let generation_id = request.generation_id.clone();
        let task = launch.into_task(
            Arc::clone(&self.inner.storage),
            self.inner.event_bus.clone(),
            branch_id,
            request,
            assistant_message,
            provider,
            credential,
        );
        self.inner.runtime.spawn(execute_generation_task(task));
        generation_id
    }

    fn active_generation_count(&self) -> usize {
        self.inner.active_generations.len()
    }
}

async fn execute_generation_task(task: GenerationTask) {
    let GenerationTask {
        storage,
        active_generations,
        event_bus,
        branch_id,
        request,
        mut assistant,
        provider,
        credential,
        cancel_receiver,
        preserve_partial,
    } = task;
    let generation_id = request.generation_id.clone();
    let _active_generation = ActiveGenerationGuard {
        generation_id: generation_id.clone(),
        active_generations,
    };
    let conversation_id = request.conversation_id.clone();
    let assistant_message_id = assistant.id.clone();
    let (event_sender, event_receiver) = mpsc::channel(128);
    let checkpoint_storage = Arc::clone(&storage);
    let checkpoint_assistant = assistant.clone();
    let forwarding_event_bus = event_bus.clone();
    let forward_events = tokio::spawn(forward_generation_events(
        event_receiver,
        forwarding_event_bus,
        checkpoint_storage,
        checkpoint_assistant,
        branch_id.clone(),
        assistant_message_id.clone(),
        preserve_partial,
    ));
    let generation_result = run_generation(
        provider.as_ref(),
        request,
        credential.as_deref(),
        event_sender,
        cancel_receiver,
    )
    .await;
    drop(credential);
    drop(provider);
    let forwarding_result = forward_events
        .await
        .map_err(|error| {
            CoreError::internal(format!(
                "generation event forwarder stopped unexpectedly: {error}"
            ))
        })
        .and_then(std::convert::identity);
    let result = merge_generation_and_forwarding_results(generation_result, forwarding_result);
    let usage = result.as_ref().ok().map(|outcome| outcome.usage.clone());
    let error_code = result
        .as_ref()
        .err()
        .map(|failure| failure.error.code.as_str().to_owned());

    let (sequence, terminal_kind, should_commit) =
        apply_generation_result(&mut assistant, result, preserve_partial);
    let (sequence, terminal_kind) = persist_generation_terminal(
        TerminalPersistenceContext {
            storage: &storage,
            event_bus: &event_bus,
            generation_id: &generation_id,
            conversation_id: &conversation_id,
            branch_id: &branch_id,
            assistant_message_id: &assistant_message_id,
        },
        &mut assistant,
        usage.as_ref(),
        error_code.as_deref(),
        should_commit,
        sequence,
        terminal_kind,
    );
    let _ = event_bus.send(
        ChatEvent::new(
            generation_id.clone(),
            conversation_id,
            sequence,
            terminal_kind,
        )
        .with_route(branch_id, assistant_message_id),
    );
}

fn persist_generation_terminal(
    context: TerminalPersistenceContext<'_>,
    assistant: &mut Message,
    usage: Option<&lorepia_domain::GenerationUsage>,
    error_code: Option<&str>,
    should_commit: bool,
    mut sequence: u64,
    mut terminal_kind: ChatEventKind,
) -> (u64, ChatEventKind) {
    let original_status = assistant.status;
    let persistence =
        context
            .storage
            .finalize_generation(assistant, usage, error_code, should_commit);
    let committed = if persistence.is_ok() {
        should_commit
    } else {
        assistant.status = MessageStatus::Failed;
        let compensation = context
            .storage
            .fail_generation_after_finalize_error(assistant, should_commit);
        if compensation.is_ok() {
            terminal_kind = generation_persistence_failure();
            should_commit
        } else if context
            .storage
            .get_generation(context.generation_id)
            .is_ok_and(|generation| {
                generation.status == generation_status_for_message(original_status)
            })
        {
            assistant.status = original_status;
            should_commit
        } else {
            terminal_kind = generation_persistence_failure();
            false
        }
    };
    if committed {
        let _ = context.event_bus.send(
            ChatEvent::new(
                context.generation_id.clone(),
                context.conversation_id.clone(),
                sequence,
                ChatEventKind::MessageCommitted {
                    message_id: assistant.id.clone(),
                    status: assistant.status,
                },
            )
            .with_route(
                context.branch_id.clone(),
                context.assistant_message_id.clone(),
            ),
        );
        sequence = sequence.saturating_add(1);
    }
    (sequence, terminal_kind)
}

const fn generation_status_for_message(status: MessageStatus) -> GenerationStatus {
    match status {
        MessageStatus::Pending => GenerationStatus::Running,
        MessageStatus::Complete => GenerationStatus::Complete,
        MessageStatus::Cancelled => GenerationStatus::Cancelled,
        MessageStatus::Failed => GenerationStatus::Failed,
    }
}

fn generation_persistence_failure() -> ChatEventKind {
    ChatEventKind::GenerationFailed {
        code: CoreErrorCode::StorageUnavailable.as_str().to_owned(),
        message: GENERATION_PERSISTENCE_FAILURE_MESSAGE.to_owned(),
    }
}

async fn forward_generation_events(
    mut event_receiver: mpsc::Receiver<ChatEvent>,
    event_bus: broadcast::Sender<ChatEvent>,
    storage: Arc<Storage>,
    mut checkpoint: Message,
    branch_id: ConversationBranchId,
    assistant_message_id: MessageId,
    preserve_partial: bool,
) -> CoreResult<()> {
    let start = time::Instant::now() + PARTIAL_CHECKPOINT_INTERVAL;
    let mut interval = time::interval_at(start, PARTIAL_CHECKPOINT_INTERVAL);
    interval.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let mut last_checkpoint_bytes = 0;
    let mut dirty = false;

    loop {
        tokio::select! {
            event = event_receiver.recv() => {
                let Some(event) = event else {
                    if preserve_partial && dirty {
                        storage.checkpoint_pending_assistant(&checkpoint)?;
                    }
                    return Ok(());
                };
                if preserve_partial
                    && let ChatEventKind::TextDelta(delta) = &event.kind
                {
                    checkpoint.content.push_str(delta);
                    dirty = true;
                }
                let _ = event_bus.send(
                    event.with_route(branch_id.clone(), assistant_message_id.clone())
                );
                if preserve_partial
                    && dirty
                    && partial_checkpoint_due(checkpoint.content.len(), last_checkpoint_bytes)
                {
                    storage.checkpoint_pending_assistant(&checkpoint)?;
                    last_checkpoint_bytes = checkpoint.content.len();
                    dirty = false;
                }
            }
            _ = interval.tick(), if preserve_partial => {
                if dirty {
                    storage.checkpoint_pending_assistant(&checkpoint)?;
                    last_checkpoint_bytes = checkpoint.content.len();
                    dirty = false;
                }
            }
        }
    }
}

fn partial_checkpoint_due(current_bytes: usize, last_checkpoint_bytes: usize) -> bool {
    current_bytes.saturating_sub(last_checkpoint_bytes) >= PARTIAL_CHECKPOINT_BYTES
}

fn merge_generation_and_forwarding_results(
    generation: Result<GenerationOutcome, GenerationFailure>,
    forwarding: CoreResult<()>,
) -> Result<GenerationOutcome, GenerationFailure> {
    match (generation, forwarding) {
        (result, Ok(())) => result,
        (Ok(outcome), Err(error)) => Err(GenerationFailure {
            error,
            partial_text: outcome.text,
            last_sequence: outcome.last_sequence,
        }),
        (Err(mut failure), Err(error)) => {
            failure.error = error;
            Err(failure)
        }
    }
}

fn apply_generation_result(
    assistant: &mut Message,
    result: Result<GenerationOutcome, GenerationFailure>,
    preserve_partial: bool,
) -> (u64, ChatEventKind, bool) {
    match result {
        Ok(outcome) => {
            assistant.content = outcome.text;
            assistant.status = MessageStatus::Complete;
            (
                outcome.last_sequence.saturating_add(1),
                ChatEventKind::GenerationFinished,
                true,
            )
        }
        Err(failure) => {
            let cancelled = failure.error.code == CoreErrorCode::Cancelled;
            assistant.content = failure.partial_text;
            assistant.status = if cancelled {
                MessageStatus::Cancelled
            } else {
                MessageStatus::Failed
            };
            let terminal = if cancelled {
                ChatEventKind::GenerationCancelled
            } else {
                ChatEventKind::GenerationFailed {
                    code: failure.error.code.as_str().to_owned(),
                    message: failure.error.message,
                }
            };
            (
                failure.last_sequence.saturating_add(1),
                terminal,
                preserve_partial && !assistant.content.is_empty(),
            )
        }
    }
}

fn normalize_bounded_text(
    field: &str,
    value: String,
    max_bytes: usize,
    max_chars: usize,
) -> CoreResult<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(CoreError::invalid(format!("{field} cannot be empty")));
    }
    validate_bounded_text(field, trimmed, max_bytes, max_chars)?;
    Ok(trimmed.to_owned())
}

fn validate_bounded_text(
    field: &str,
    value: &str,
    max_bytes: usize,
    max_chars: usize,
) -> CoreResult<()> {
    if value.len() > max_bytes || value.chars().count() > max_chars {
        return Err(CoreError::invalid(format!(
            "{field} exceeds the {max_bytes}-byte or {max_chars}-character limit"
        )));
    }
    Ok(())
}

fn validate_action_replacement(
    action: MessageGenerationAction,
    replacement_text: Option<&str>,
) -> CoreResult<Option<&str>> {
    match replacement_text {
        Some(text) => validate_user_message_text(text).map(Some),
        None if action == MessageGenerationAction::EditUser => {
            Err(CoreError::invalid("message text cannot be empty"))
        }
        None => Ok(None),
    }
}

fn validate_user_message_text(value: &str) -> CoreResult<&str> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(CoreError::invalid("message text cannot be empty"));
    }
    validate_bounded_text(
        "message text",
        trimmed,
        MAX_USER_MESSAGE_BYTES,
        MAX_USER_MESSAGE_CHARS,
    )?;
    Ok(trimmed)
}

fn directory_is_writable(path: &Path) -> bool {
    if fs::create_dir_all(path).is_err() {
        return false;
    }
    let probe = path.join(format!(".health-{}", Uuid::new_v4()));
    let created = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .and_then(|file| file.sync_all())
        .is_ok();
    let _ = fs::remove_file(probe);
    created
}

fn snapshot_import_source(
    source_path: &Path,
    staging_dir: &Path,
    max_source_bytes: u64,
) -> CoreResult<PathBuf> {
    let source_metadata = fs::symlink_metadata(source_path).map_err(import_io_error)?;
    if !source_metadata.file_type().is_file() {
        return Err(CoreError::invalid(
            "the import source must be a regular file and cannot be a symbolic link",
        ));
    }
    if source_metadata.len() > max_source_bytes {
        return Err(CoreError::new(
            CoreErrorCode::UnsupportedContent,
            format!(
                "source is {} bytes; maximum is {} bytes",
                source_metadata.len(),
                max_source_bytes
            ),
            false,
        ));
    }

    fs::create_dir_all(staging_dir).map_err(import_io_error)?;
    let extension = source_path
        .extension()
        .and_then(|value| value.to_str())
        .filter(|value| {
            !value.is_empty()
                && value.len() <= 16
                && value
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
        .map(|value| format!(".{}", value.to_ascii_lowercase()))
        .unwrap_or_default();
    let snapshot = staging_dir.join(format!("inspection-{}{extension}", Uuid::new_v4()));
    let result = (|| {
        let source = File::open(source_path).map_err(import_io_error)?;
        let opened_metadata = source.metadata().map_err(import_io_error)?;
        if !opened_metadata.is_file() {
            return Err(CoreError::invalid(
                "the import source is not a regular file",
            ));
        }
        let mut reader = BufReader::new(source);
        let mut destination = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&snapshot)
            .map_err(import_io_error)?;
        let mut copied = 0_u64;
        let mut buffer = vec![0_u8; 64 * 1024];
        loop {
            let read = reader.read(&mut buffer).map_err(import_io_error)?;
            if read == 0 {
                break;
            }
            copied = copied
                .checked_add(
                    u64::try_from(read)
                        .map_err(|_| CoreError::internal("import byte count overflow"))?,
                )
                .ok_or_else(|| CoreError::internal("import size overflow"))?;
            if copied > max_source_bytes {
                return Err(CoreError::new(
                    CoreErrorCode::UnsupportedContent,
                    format!("source exceeds the {max_source_bytes} byte import limit"),
                    false,
                ));
            }
            destination
                .write_all(&buffer[..read])
                .map_err(import_io_error)?;
        }
        destination.flush().map_err(import_io_error)?;
        destination.sync_all().map_err(import_io_error)?;
        Ok(())
    })();
    if let Err(error) = result {
        let _ = fs::remove_file(&snapshot);
        return Err(error);
    }
    Ok(snapshot)
}

fn remove_snapshot(snapshot: &Path, staging_dir: &Path) -> CoreResult<()> {
    if snapshot.parent() != Some(staging_dir) || snapshot.file_name().is_none() {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "pending import snapshot is outside the owned staging directory",
            false,
        ));
    }
    match fs::remove_file(snapshot) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(import_io_error(error)),
    }
}

fn cleanup_pending_import(pending: &PendingImport, staging_dir: &Path) -> CoreResult<()> {
    let mut first_error = remove_snapshot(&pending.path, staging_dir).err();
    for asset in &pending.staged_assets {
        if let Err(error) = remove_snapshot(&asset.staged_path, staging_dir)
            && first_error.is_none()
        {
            first_error = Some(error);
        }
    }
    first_error.map_or(Ok(()), Err)
}

fn import_io_error(error: std::io::Error) -> CoreError {
    CoreError::new(
        CoreErrorCode::StorageUnavailable,
        format!("cannot stage import source: {error}"),
        true,
    )
}

#[cfg(test)]
mod tests {
    use std::{
        io::Write,
        sync::{Arc, Barrier, mpsc as std_mpsc},
        thread,
        time::{Duration, Instant},
    };

    use async_trait::async_trait;
    use lorepia_domain::{GenerationUsage, ProviderCapabilities};
    use lorepia_providers::{ProviderEvent, ProviderEventSender, StaticProvider};
    use tempfile::{NamedTempFile, tempdir};

    use super::*;

    struct StallingProvider {
        partial: String,
        started: Mutex<Option<std_mpsc::Sender<()>>>,
    }

    struct CapturingProvider {
        response: String,
        captured: Mutex<Option<std_mpsc::Sender<Vec<String>>>>,
    }

    struct OverflowUsageProvider;

    impl CapturingProvider {
        fn new(response: impl Into<String>) -> (Arc<Self>, std_mpsc::Receiver<Vec<String>>) {
            let (sender, receiver) = std_mpsc::channel();
            (
                Arc::new(Self {
                    response: response.into(),
                    captured: Mutex::new(Some(sender)),
                }),
                receiver,
            )
        }
    }

    #[async_trait]
    impl Provider for CapturingProvider {
        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities {
                streaming: true,
                reasoning: false,
                max_context_tokens: None,
            }
        }

        async fn generate(
            &self,
            request: GenerationRequest,
            _credential: Option<&str>,
            sink: ProviderEventSender,
            _cancelled: watch::Receiver<bool>,
        ) -> CoreResult<GenerationUsage> {
            if let Some(sender) = self.captured.lock().expect("capture lock").take() {
                let _ = sender.send(
                    request
                        .messages
                        .into_iter()
                        .map(|message| message.content)
                        .collect(),
                );
            }
            sink.send(ProviderEvent::TextDelta(self.response.clone()))
                .await
                .map_err(|_| CoreError::internal("chat event receiver closed"))?;
            Ok(GenerationUsage::default())
        }
    }

    #[async_trait]
    impl Provider for OverflowUsageProvider {
        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities {
                streaming: true,
                reasoning: false,
                max_context_tokens: None,
            }
        }

        async fn generate(
            &self,
            _request: GenerationRequest,
            _credential: Option<&str>,
            sink: ProviderEventSender,
            _cancelled: watch::Receiver<bool>,
        ) -> CoreResult<GenerationUsage> {
            sink.send(ProviderEvent::TextDelta(
                "response before invalid usage".to_owned(),
            ))
            .await
            .map_err(|_| CoreError::internal("provider event receiver closed"))?;
            Ok(GenerationUsage {
                input_tokens: Some(i64::MAX as u64 + 1),
                output_tokens: Some(1),
            })
        }
    }

    impl StallingProvider {
        fn new(partial: impl Into<String>) -> (Arc<Self>, std_mpsc::Receiver<()>) {
            let (started_sender, started_receiver) = std_mpsc::channel();
            (
                Arc::new(Self {
                    partial: partial.into(),
                    started: Mutex::new(Some(started_sender)),
                }),
                started_receiver,
            )
        }
    }

    #[async_trait]
    impl Provider for StallingProvider {
        fn capabilities(&self) -> ProviderCapabilities {
            ProviderCapabilities {
                streaming: true,
                reasoning: false,
                max_context_tokens: None,
            }
        }

        async fn generate(
            &self,
            _request: GenerationRequest,
            _credential: Option<&str>,
            sink: ProviderEventSender,
            _cancelled: watch::Receiver<bool>,
        ) -> CoreResult<GenerationUsage> {
            sink.send(ProviderEvent::TextDelta(self.partial.clone()))
                .await
                .map_err(|_| CoreError::internal("provider event receiver closed"))?;
            if let Some(sender) = self.started.lock().expect("started lock").take() {
                let _ = sender.send(());
            }
            std::future::pending().await
        }
    }

    fn imported_core() -> (tempfile::TempDir, Core, Character) {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Segu","description":"Guide"}}}}"#
        )
        .expect("write card");
        let inspection = core.inspect_import(card.path()).expect("inspect");
        let character = core.commit_import(&inspection.id).expect("commit");
        (root, core, character)
    }

    fn poison_generation_registry(core: &Core) {
        let registry = Arc::clone(&core.inner.active_generations);
        let result = thread::spawn(move || {
            let _guard = registry.active.lock().expect("registry lock");
            panic!("synthetic generation registry failure");
        })
        .join();
        assert!(result.is_err(), "registry poison thread must panic");
    }

    fn wait_for_partial(core: &Core, conversation_id: &ConversationId, expected: &str) -> Message {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            let messages = core.list_messages(conversation_id).expect("messages");
            if let Some(message) = messages.get(1)
                && message.content == expected
            {
                return message.clone();
            }
            assert!(
                Instant::now() < deadline,
                "partial checkpoint was not persisted"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn wait_for_generation_status(
        core: &Core,
        generation_id: &GenerationId,
        expected: GenerationStatus,
    ) -> GenerationRecord {
        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let generation = core
                .inner
                .storage
                .get_generation(generation_id)
                .expect("generation snapshot");
            if generation.status == expected {
                return generation;
            }
            assert!(
                Instant::now() < deadline,
                "generation did not reach {expected:?}"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn wait_for_generation_registry_to_drain(core: &Core) {
        let deadline = Instant::now() + Duration::from_secs(2);
        while core.active_generation_count() != 0 {
            assert!(
                Instant::now() < deadline,
                "generation registry did not drain"
            );
            thread::sleep(Duration::from_millis(10));
        }
    }

    #[test]
    fn health_reports_storage_state() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let health = core.health_check().expect("health");
        assert!(health.database_open);
        assert!(health.data_root_writable);
        assert_eq!(health.schema_version, 3);
    }

    #[test]
    fn dropping_last_core_from_a_runtime_worker_bounds_shutdown_and_releases_provider() {
        let (_root, core, character) = imported_core();
        let conversation = core.open_conversation(&character.id).expect("conversation");
        let (provider, provider_started) = StallingProvider::new("partial before shutdown");
        let provider_weak = Arc::downgrade(&provider);
        core.send_message_with_provider(
            &conversation.id,
            "start",
            "stalling".to_owned(),
            Some("ephemeral-credential".to_owned()),
            provider,
        )
        .expect("start generation");
        provider_started
            .recv_timeout(Duration::from_secs(2))
            .expect("provider started");

        let runtime_handle = core.inner.runtime.handle.clone();
        let (dropped_sender, dropped_receiver) = std_mpsc::channel();
        std::mem::drop(runtime_handle.spawn(async move {
            let started = Instant::now();
            drop(core);
            let _ = dropped_sender.send(started.elapsed());
        }));

        let elapsed = dropped_receiver
            .recv_timeout(Duration::from_secs(4))
            .expect("core drop must not panic or deadlock on its runtime worker");
        assert!(
            elapsed < Duration::from_secs(3),
            "shutdown exceeded its cancellation and runtime bounds: {elapsed:?}"
        );
        assert!(
            provider_weak.upgrade().is_none(),
            "runtime shutdown must release the stalling provider and its captured state"
        );
    }

    #[test]
    fn timed_partial_checkpoint_survives_restart_when_preservation_is_enabled() {
        let (root, core, character) = imported_core();
        core.update_settings(&AppSettings {
            preserve_partial_generations: true,
            selected_provider_profile_id: None,
        })
        .expect("enable partial preservation");
        let conversation = core.open_conversation(&character.id).expect("conversation");
        let partial = "latest timer checkpoint";
        let (provider, provider_started) = StallingProvider::new(partial);
        core.send_message_with_provider(
            &conversation.id,
            "start",
            "stalling".to_owned(),
            None,
            provider,
        )
        .expect("start generation");
        provider_started
            .recv_timeout(Duration::from_secs(2))
            .expect("provider started");

        let checkpoint = wait_for_partial(&core, &conversation.id, partial);
        assert_eq!(checkpoint.status, MessageStatus::Pending);
        drop(core);

        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen");
        let messages = reopened
            .list_messages(&conversation.id)
            .expect("restored messages");
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[1].content, partial);
        assert_eq!(messages[1].status, MessageStatus::Cancelled);
    }

    #[test]
    fn partial_checkpoint_is_never_written_when_preservation_is_disabled() {
        let (root, core, character) = imported_core();
        core.update_settings(&AppSettings {
            preserve_partial_generations: false,
            selected_provider_profile_id: None,
        })
        .expect("disable partial preservation");
        let conversation = core.open_conversation(&character.id).expect("conversation");
        let partial = "must not persist";
        let (provider, provider_started) = StallingProvider::new(partial);
        core.send_message_with_provider(
            &conversation.id,
            "start",
            "stalling".to_owned(),
            None,
            provider,
        )
        .expect("start generation");
        provider_started
            .recv_timeout(Duration::from_secs(2))
            .expect("provider started");
        thread::sleep(PARTIAL_CHECKPOINT_INTERVAL + Duration::from_millis(150));

        let messages = core.list_messages(&conversation.id).expect("messages");
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[1].status, MessageStatus::Pending);
        assert!(messages[1].content.is_empty());
        drop(core);

        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen");
        let restored = reopened
            .list_messages(&conversation.id)
            .expect("restored messages");
        assert_eq!(restored.len(), 1);
        assert_eq!(restored[0].content, "start");
    }

    #[test]
    fn partial_checkpoint_byte_threshold_is_inclusive() {
        assert!(!partial_checkpoint_due(PARTIAL_CHECKPOINT_BYTES - 1, 0));
        assert!(partial_checkpoint_due(PARTIAL_CHECKPOINT_BYTES, 0));
        assert!(partial_checkpoint_due(
            PARTIAL_CHECKPOINT_BYTES * 2,
            PARTIAL_CHECKPOINT_BYTES
        ));
    }

    #[test]
    fn import_and_restart_restore_library() {
        let (root, core, _) = imported_core();
        drop(core);
        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen");
        assert_eq!(reopened.list_characters().expect("library").len(), 1);
    }

    #[test]
    fn import_uses_an_owned_snapshot_and_cleans_it_after_commit() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Snapshot","description":"Safe"}}}}"#
        )
        .expect("write card");

        let inspection = core.inspect_import(card.path()).expect("inspect");
        fs::write(card.path(), b"changed after inspection").expect("mutate original");
        let character = core.commit_import(&inspection.id).expect("commit snapshot");

        assert_eq!(character.name, "Snapshot");
        assert!(
            fs::read_dir(core.inner.storage.staging_dir())
                .expect("staging directory")
                .next()
                .is_none(),
            "committed snapshots must be removed"
        );
    }

    #[test]
    fn discard_and_restart_cleanup_owned_staging_files() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Discard","description":"Safe"}}}}"#
        )
        .expect("write card");
        let inspection = core.inspect_import(card.path()).expect("inspect");
        core.discard_import(&inspection.id).expect("discard");
        assert!(
            fs::read_dir(core.inner.storage.staging_dir())
                .expect("staging directory")
                .next()
                .is_none()
        );

        let abandoned = core
            .inner
            .storage
            .staging_dir()
            .join("inspection-abandoned.json");
        fs::write(&abandoned, b"abandoned").expect("abandoned staging file");
        drop(core);
        let _reopened = Core::open(CoreConfig::new(root.path())).expect("reopen");
        assert!(
            !abandoned.exists(),
            "restart must clean abandoned snapshots"
        );
    }

    #[test]
    fn concurrent_commits_atomically_claim_one_inspection() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Claim","description":"Safe"}}}}"#
        )
        .expect("write card");
        let inspection = core.inspect_import(card.path()).expect("inspect");
        let barrier = Arc::new(Barrier::new(3));
        let mut workers = Vec::new();
        for _ in 0..2 {
            let core = core.clone();
            let inspection_id = inspection.id.clone();
            let barrier = Arc::clone(&barrier);
            workers.push(thread::spawn(move || {
                barrier.wait();
                core.commit_import(&inspection_id)
            }));
        }
        barrier.wait();
        let results = workers
            .into_iter()
            .map(|worker| worker.join().expect("commit worker"))
            .collect::<Vec<_>>();

        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        let loser = results
            .iter()
            .find_map(|result| result.as_ref().err())
            .expect("one losing commit");
        assert_eq!(loser.code, CoreErrorCode::NotFound);
        assert_eq!(core.list_characters().expect("characters").len(), 1);
    }

    #[test]
    fn concurrent_commit_and_discard_have_one_atomic_winner() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        write!(
            card,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Race","description":"Safe"}}}}"#
        )
        .expect("write card");
        let inspection = core.inspect_import(card.path()).expect("inspect");
        let barrier = Arc::new(Barrier::new(3));
        let commit_core = core.clone();
        let commit_id = inspection.id.clone();
        let commit_barrier = Arc::clone(&barrier);
        let commit = thread::spawn(move || {
            commit_barrier.wait();
            commit_core.commit_import(&commit_id)
        });
        let discard_core = core.clone();
        let discard_id = inspection.id.clone();
        let discard_barrier = Arc::clone(&barrier);
        let discard = thread::spawn(move || {
            discard_barrier.wait();
            discard_core.discard_import(&discard_id)
        });
        barrier.wait();
        let commit = commit.join().expect("commit worker");
        let discard = discard.join().expect("discard worker");

        assert_ne!(commit.is_ok(), discard.is_ok());
        let loser = commit
            .as_ref()
            .err()
            .or_else(|| discard.as_ref().err())
            .expect("one losing operation");
        assert_eq!(loser.code, CoreErrorCode::NotFound);
        assert_eq!(
            core.list_characters().expect("characters").len(),
            usize::from(commit.is_ok())
        );
    }

    #[test]
    fn precommit_failure_restores_the_claim_for_a_safe_retry() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let mut card = NamedTempFile::new_in(root.path()).expect("card");
        let card_bytes =
            br#"{"spec":"chara_card_v3","data":{"name":"Retry","description":"Safe"}}"#;
        card.write_all(card_bytes).expect("write card");
        let inspection = core.inspect_import(card.path()).expect("inspect");
        let snapshot = core
            .inner
            .pending_imports
            .read()
            .expect("pending imports")
            .get(&inspection.id)
            .expect("inspection")
            .path
            .clone();
        fs::remove_file(&snapshot).expect("remove claimed snapshot");

        let error = core
            .commit_import(&inspection.id)
            .expect_err("precommit failure");
        assert_eq!(error.code, CoreErrorCode::StorageUnavailable);
        assert!(
            core.inner
                .pending_imports
                .read()
                .expect("pending imports")
                .contains_key(&inspection.id),
            "a definitely uncommitted claim must be restored"
        );

        fs::write(&snapshot, card_bytes).expect("restore snapshot");
        let character = core.commit_import(&inspection.id).expect("safe retry");
        assert_eq!(character.name, "Retry");
        assert_eq!(core.list_characters().expect("characters").len(), 1);
    }

    #[test]
    fn user_message_and_provider_fields_have_utf8_safe_inclusive_bounds() {
        let exact_message = "😀".repeat(MAX_USER_MESSAGE_CHARS);
        assert_eq!(exact_message.len(), MAX_USER_MESSAGE_BYTES);
        validate_bounded_text(
            "message text",
            &exact_message,
            MAX_USER_MESSAGE_BYTES,
            MAX_USER_MESSAGE_CHARS,
        )
        .expect("exact message boundary");
        let message_error = validate_bounded_text(
            "message text",
            &format!("{exact_message}😀"),
            MAX_USER_MESSAGE_BYTES,
            MAX_USER_MESSAGE_CHARS,
        )
        .expect_err("message over boundary");
        assert_eq!(message_error.code, CoreErrorCode::InvalidInput);
        assert_eq!(
            message_error.message,
            "message text exceeds the 65536-byte or 16384-character limit"
        );

        for (field, max_bytes, max_chars) in [
            (
                "provider profile id",
                MAX_PROVIDER_ID_BYTES,
                MAX_PROVIDER_ID_CHARS,
            ),
            (
                "provider display name",
                MAX_PROVIDER_DISPLAY_NAME_BYTES,
                MAX_PROVIDER_DISPLAY_NAME_CHARS,
            ),
            (
                "provider base URL",
                MAX_PROVIDER_BASE_URL_BYTES,
                MAX_PROVIDER_BASE_URL_CHARS,
            ),
            (
                "provider model",
                MAX_PROVIDER_MODEL_BYTES,
                MAX_PROVIDER_MODEL_CHARS,
            ),
        ] {
            let exact = "😀".repeat(max_chars);
            assert_eq!(exact.len(), max_bytes);
            validate_bounded_text(field, &exact, max_bytes, max_chars)
                .expect("exact provider field boundary");
            assert!(
                validate_bounded_text(field, &format!("{exact}😀"), max_bytes, max_chars).is_err()
            );
        }
    }

    #[test]
    fn oversized_user_input_and_provider_fields_are_not_persisted() {
        let (_root, core, character) = imported_core();
        let conversation = core.open_conversation(&character.id).expect("conversation");
        let error = core
            .send_message_with_provider(
                &conversation.id,
                &"😀".repeat(MAX_USER_MESSAGE_CHARS + 1),
                "static".to_owned(),
                None,
                Arc::new(StaticProvider::new("unused")),
            )
            .expect_err("oversized message");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert!(
            core.list_messages(&conversation.id)
                .expect("messages")
                .is_empty()
        );

        let profile_error = core
            .upsert_provider_profile(ProviderProfile {
                id: "provider".to_owned(),
                display_name: "Provider".to_owned(),
                base_url: "http://127.0.0.1:11434/v1".to_owned(),
                model: "😀".repeat(MAX_PROVIDER_MODEL_CHARS + 1),
                timeout_seconds: 30,
            })
            .expect_err("oversized model");
        assert_eq!(profile_error.code, CoreErrorCode::InvalidInput);
        assert_eq!(
            profile_error.message,
            "provider model exceeds the 1024-byte or 256-character limit"
        );
        assert!(core.list_provider_profiles().expect("profiles").is_empty());
    }

    #[test]
    fn every_provider_profile_string_is_bounded_before_storage() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let valid = || ProviderProfile {
            id: "provider".to_owned(),
            display_name: "Provider".to_owned(),
            base_url: "http://127.0.0.1:11434/v1".to_owned(),
            model: "model".to_owned(),
            timeout_seconds: 30,
        };
        let mut cases = Vec::new();
        let mut oversized_id = valid();
        oversized_id.id = "😀".repeat(MAX_PROVIDER_ID_CHARS + 1);
        cases.push(("provider profile id", oversized_id));
        let mut oversized_display = valid();
        oversized_display.display_name = "😀".repeat(MAX_PROVIDER_DISPLAY_NAME_CHARS + 1);
        cases.push(("provider display name", oversized_display));
        let mut oversized_url = valid();
        oversized_url.base_url = format!(
            "http://127.0.0.1/{}",
            "a".repeat(MAX_PROVIDER_BASE_URL_BYTES)
        );
        cases.push(("provider base URL", oversized_url));
        let mut oversized_model = valid();
        oversized_model.model = "😀".repeat(MAX_PROVIDER_MODEL_CHARS + 1);
        cases.push(("provider model", oversized_model));

        for (field, profile) in cases {
            let error = core
                .upsert_provider_profile(profile)
                .expect_err("oversized provider field");
            assert_eq!(error.code, CoreErrorCode::InvalidInput);
            assert!(error.message.starts_with(field), "{:?}", error.message);
        }
        assert!(core.list_provider_profiles().expect("profiles").is_empty());
    }

    #[test]
    fn one_character_can_own_multiple_explicit_rooms_with_independent_modes() {
        let (_root, core, character) = imported_core();
        let chat = core
            .create_conversation(&character.id, "첫 번째 방", ConversationMode::Chat)
            .expect("chat room");
        let story = core
            .create_conversation(&character.id, "두 번째 방", ConversationMode::Story)
            .expect("story room");

        assert_ne!(chat.id, story.id);
        assert_eq!(
            core.list_conversations_for_character(&character.id)
                .expect("character rooms")
                .len(),
            2
        );
        assert_eq!(
            core.get_conversation_state(&chat.id)
                .expect("chat state")
                .selected_mode,
            ConversationMode::Chat
        );
        assert_eq!(
            core.get_conversation_state(&story.id)
                .expect("story state")
                .selected_mode,
            ConversationMode::Story
        );
        assert_eq!(
            core.list_conversation_branches(&chat.id)
                .expect("default branch")
                .len(),
            1
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn forked_branch_uses_only_its_parent_lineage_and_rejects_a_stale_head() {
        let (_root, core, character) = imported_core();
        let conversation = core
            .create_conversation(&character.id, "분기 테스트", ConversationMode::Chat)
            .expect("conversation");
        core.send_message_with_provider(
            &conversation.id,
            "공통 시작",
            "static".to_owned(),
            None,
            Arc::new(StaticProvider::new("원본 답변")),
        )
        .expect("initial generation");
        let deadline = Instant::now() + Duration::from_secs(2);
        let original = loop {
            let messages = core.list_messages(&conversation.id).expect("messages");
            if messages.len() == 2 && messages[1].status == MessageStatus::Complete {
                break messages;
            }
            assert!(Instant::now() < deadline, "initial generation timed out");
            thread::sleep(Duration::from_millis(10));
        };

        let fork = core
            .create_conversation_branch(
                &conversation.id,
                Some(&original[0].id),
                Some("다른 선택".to_owned()),
            )
            .expect("fork");
        let (provider, captured) = CapturingProvider::new("분기 답변");
        let generation_id = core
            .send_message_to_branch_with_provider(
                &conversation.id,
                &fork.id,
                Some(&original[0].id),
                ConversationMode::Story,
                "분기 질문",
                "captured".to_owned(),
                None,
                provider,
            )
            .expect("branch generation");
        let request_messages = captured
            .recv_timeout(Duration::from_secs(2))
            .expect("captured prompt");
        assert!(
            request_messages
                .first()
                .is_some_and(|message| message.contains("Story mode:")),
            "the provider prompt must use the generation snapshot mode"
        );
        assert!(
            request_messages
                .iter()
                .any(|message| message == "공통 시작")
        );
        assert!(
            request_messages
                .iter()
                .any(|message| message == "분기 질문")
        );
        assert!(
            !request_messages
                .iter()
                .any(|message| message == "원본 답변"),
            "a sibling assistant response must not leak into the fork prompt"
        );

        let deadline = Instant::now() + Duration::from_secs(2);
        let forked = loop {
            let messages = core.list_branch_messages(&fork.id).expect("fork messages");
            if messages.len() == 3
                && messages
                    .last()
                    .is_some_and(|message| message.status == MessageStatus::Complete)
            {
                break messages;
            }
            assert!(Instant::now() < deadline, "branch generation timed out");
            thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(
            forked
                .iter()
                .map(|message| message.content.as_str())
                .collect::<Vec<_>>(),
            ["공통 시작", "분기 질문", "분기 답변"]
        );
        assert_eq!(
            core.inner
                .storage
                .get_generation(&generation_id)
                .expect("generation snapshot")
                .mode,
            ConversationMode::Story
        );
        assert_eq!(
            core.list_branch_messages(
                &core
                    .get_conversation_state(&conversation.id)
                    .expect("state")
                    .active_branch_id
            )
            .expect("original branch")
            .iter()
            .map(|message| message.content.as_str())
            .collect::<Vec<_>>(),
            ["공통 시작", "원본 답변"]
        );

        let stale = core
            .send_message_to_branch_with_provider(
                &conversation.id,
                &fork.id,
                Some(&original[0].id),
                ConversationMode::Story,
                "오래된 head",
                "static".to_owned(),
                None,
                Arc::new(StaticProvider::new("should not run")),
            )
            .expect_err("stale branch head");
        assert_eq!(stale.code, CoreErrorCode::InvalidInput);
        assert!(stale.recoverable);
        assert_eq!(
            core.list_branch_messages(&fork.id)
                .expect("unchanged fork")
                .len(),
            3
        );

        core.select_conversation_branch(&conversation.id, &fork.id)
            .expect("select fork");
        assert_eq!(
            core.list_messages(&conversation.id)
                .expect("active branch messages"),
            forked
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn message_actions_fork_immutable_lineage_and_rewind_without_deleting_rows() {
        let (root, core, character) = imported_core();
        let conversation = core
            .create_conversation(&character.id, "메시지 액션", ConversationMode::Chat)
            .expect("conversation");
        core.send_message_with_provider(
            &conversation.id,
            "원본 질문",
            "static".to_owned(),
            None,
            Arc::new(StaticProvider::new("원본 답변")),
        )
        .expect("initial generation");
        let deadline = Instant::now() + Duration::from_secs(2);
        let original = loop {
            let messages = core.list_messages(&conversation.id).expect("messages");
            if messages.len() == 2 && messages[1].status == MessageStatus::Complete {
                break messages;
            }
            assert!(Instant::now() < deadline, "initial generation timed out");
            thread::sleep(Duration::from_millis(10));
        };
        let source_branch_id = core
            .get_conversation_state(&conversation.id)
            .expect("source state")
            .active_branch_id;
        core.set_conversation_mode(&conversation.id, ConversationMode::Story)
            .expect("story mode");

        let (edit_provider, edited_prompt) = CapturingProvider::new("수정 답변");
        let edited = core
            .edit_user_message_with_provider(
                &conversation.id,
                &source_branch_id,
                Some(&original[1].id),
                &original[0].id,
                "수정 질문",
                "edited-model".to_owned(),
                None,
                edit_provider,
            )
            .expect("edit user");
        let edited_request = edited_prompt
            .recv_timeout(Duration::from_secs(2))
            .expect("edited prompt");
        assert!(
            edited_request
                .first()
                .is_some_and(|message| message.contains("Story mode:"))
        );
        assert!(edited_request.iter().any(|message| message == "수정 질문"));
        assert!(!edited_request.iter().any(|message| message == "원본 질문"));
        let deadline = Instant::now() + Duration::from_secs(2);
        let edited_messages = loop {
            let messages = core
                .list_branch_messages(&edited.branch.id)
                .expect("edited branch");
            if messages.len() == 2 && messages[1].status == MessageStatus::Complete {
                break messages;
            }
            assert!(Instant::now() < deadline, "edited generation timed out");
            thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(
            edited_messages
                .iter()
                .map(|message| message.content.as_str())
                .collect::<Vec<_>>(),
            ["수정 질문", "수정 답변"]
        );
        assert_eq!(
            core.get_conversation_state(&conversation.id)
                .expect("edited state")
                .active_branch_id,
            edited.branch.id
        );
        assert_eq!(
            core.inner
                .storage
                .get_generation(&edited.generation_id)
                .expect("edited generation")
                .mode,
            ConversationMode::Story
        );
        assert_eq!(
            core.list_branch_messages(&source_branch_id)
                .expect("original branch"),
            original
        );

        core.select_conversation_branch(&conversation.id, &source_branch_id)
            .expect("select original");
        let (regenerate_provider, regenerated_prompt) = CapturingProvider::new("새 답변");
        let regenerated = core
            .regenerate_assistant_message_with_provider(
                &conversation.id,
                &source_branch_id,
                Some(&original[1].id),
                &original[1].id,
                "regenerated-model".to_owned(),
                None,
                regenerate_provider,
            )
            .expect("regenerate assistant");
        let regenerated_request = regenerated_prompt
            .recv_timeout(Duration::from_secs(2))
            .expect("regenerated prompt");
        assert!(
            regenerated_request
                .iter()
                .any(|message| message == "원본 질문")
        );
        assert!(
            !regenerated_request
                .iter()
                .any(|message| message == "원본 답변")
        );
        let deadline = Instant::now() + Duration::from_secs(2);
        let regenerated_messages = loop {
            let messages = core
                .list_branch_messages(&regenerated.branch.id)
                .expect("regenerated branch");
            if messages.len() == 2 && messages[1].status == MessageStatus::Complete {
                break messages;
            }
            assert!(
                Instant::now() < deadline,
                "regenerated generation timed out"
            );
            thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(regenerated_messages[0].content, "원본 질문");
        assert_ne!(regenerated_messages[0].id, original[0].id);
        assert_eq!(regenerated_messages[1].content, "새 답변");
        assert_eq!(
            core.list_branch_messages(&source_branch_id)
                .expect("preserved original"),
            original
        );

        let rows_before_remove = core.database_stats().expect("stats").messages;
        let rewound = core
            .remove_message_from_branch(
                &conversation.id,
                &regenerated.branch.id,
                Some(&regenerated_messages[1].id),
                &regenerated_messages[1].id,
            )
            .expect("remove regenerated assistant");
        assert_eq!(
            rewound.head_message_id,
            Some(regenerated_messages[0].id.clone())
        );
        assert_eq!(
            core.list_branch_messages(&regenerated.branch.id)
                .expect("rewound branch"),
            vec![regenerated_messages[0].clone()]
        );
        assert_eq!(
            core.database_stats().expect("stats").messages,
            rows_before_remove,
            "logical removal must preserve immutable message rows"
        );

        drop(core);
        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen");
        assert_eq!(
            reopened
                .get_conversation_state(&conversation.id)
                .expect("restored state")
                .active_branch_id,
            regenerated.branch.id
        );
        assert_eq!(
            reopened
                .list_branch_messages(&source_branch_id)
                .expect("restored original"),
            original
        );
        assert_eq!(
            reopened.database_stats().expect("restored stats").messages,
            rows_before_remove
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn message_actions_reject_wrong_roles_stale_context_foreign_rooms_and_pending_heads() {
        let (_root, core, character) = imported_core();
        let conversation = core
            .create_conversation(&character.id, "거절 테스트", ConversationMode::Chat)
            .expect("conversation");
        core.send_message_with_provider(
            &conversation.id,
            "질문",
            "static".to_owned(),
            None,
            Arc::new(StaticProvider::new("답변")),
        )
        .expect("initial generation");
        let deadline = Instant::now() + Duration::from_secs(2);
        let messages = loop {
            let messages = core.list_messages(&conversation.id).expect("messages");
            if messages.len() == 2 && messages[1].status == MessageStatus::Complete {
                break messages;
            }
            assert!(Instant::now() < deadline, "initial generation timed out");
            thread::sleep(Duration::from_millis(10));
        };
        let branch_id = core
            .get_conversation_state(&conversation.id)
            .expect("state")
            .active_branch_id;

        let edit_assistant = core
            .edit_user_message_with_provider(
                &conversation.id,
                &branch_id,
                Some(&messages[1].id),
                &messages[1].id,
                "잘못된 편집",
                "unused".to_owned(),
                None,
                Arc::new(StaticProvider::new("unused")),
            )
            .expect_err("assistant cannot be edited");
        assert_eq!(edit_assistant.code, CoreErrorCode::InvalidInput);
        let regenerate_user = core
            .regenerate_assistant_message_with_provider(
                &conversation.id,
                &branch_id,
                Some(&messages[1].id),
                &messages[0].id,
                "unused".to_owned(),
                None,
                Arc::new(StaticProvider::new("unused")),
            )
            .expect_err("user cannot be regenerated");
        assert_eq!(regenerate_user.code, CoreErrorCode::InvalidInput);

        let stale = core
            .remove_message_from_branch(
                &conversation.id,
                &branch_id,
                Some(&messages[0].id),
                &messages[1].id,
            )
            .expect_err("stale expected head");
        assert_eq!(stale.code, CoreErrorCode::InvalidInput);
        assert!(stale.recoverable);

        let foreign = core
            .create_conversation(&character.id, "다른 방", ConversationMode::Chat)
            .expect("foreign conversation");
        let foreign_error = core
            .remove_message_from_branch(
                &foreign.id,
                &branch_id,
                Some(&messages[1].id),
                &messages[1].id,
            )
            .expect_err("foreign conversation");
        assert_eq!(foreign_error.code, CoreErrorCode::NotFound);

        let (stalling, started) = StallingProvider::new("생성 중");
        core.send_message_to_branch_with_provider(
            &conversation.id,
            &branch_id,
            Some(&messages[1].id),
            ConversationMode::Chat,
            "다음 질문",
            "stalling".to_owned(),
            None,
            stalling,
        )
        .expect("pending generation");
        started
            .recv_timeout(Duration::from_secs(2))
            .expect("provider started");
        let pending_head = core
            .list_branch_messages(&branch_id)
            .expect("pending lineage")
            .last()
            .expect("pending assistant")
            .id
            .clone();
        let pending_error = core
            .remove_message_from_branch(
                &conversation.id,
                &branch_id,
                Some(&pending_head),
                &pending_head,
            )
            .expect_err("pending generation");
        assert_eq!(pending_error.code, CoreErrorCode::InvalidInput);
        assert!(pending_error.recoverable);
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn generation_launch_preflight_prevents_failed_sends_and_actions_from_mutating_storage() {
        let (_send_root, send_core, send_character) = imported_core();
        let send_conversation = send_core
            .create_conversation(&send_character.id, "전송 preflight", ConversationMode::Chat)
            .expect("send conversation");
        let send_state = send_core
            .get_conversation_state(&send_conversation.id)
            .expect("send state");
        poison_generation_registry(&send_core);
        let send_error = send_core
            .send_message_with_provider(
                &send_conversation.id,
                "저장되면 안 됨",
                "unused".to_owned(),
                None,
                Arc::new(StaticProvider::new("unused")),
            )
            .expect_err("launch preflight must fail");
        assert_eq!(send_error.code, CoreErrorCode::Internal);
        assert!(
            send_core
                .list_messages(&send_conversation.id)
                .expect("send messages")
                .is_empty()
        );
        assert!(
            send_core
                .inner
                .storage
                .get_conversation_branch(&send_state.active_branch_id)
                .expect("send branch")
                .head_message_id
                .is_none()
        );

        let (_action_root, action_core, action_character) = imported_core();
        let action_conversation = action_core
            .create_conversation(
                &action_character.id,
                "액션 preflight",
                ConversationMode::Chat,
            )
            .expect("action conversation");
        action_core
            .send_message_with_provider(
                &action_conversation.id,
                "원본",
                "static".to_owned(),
                None,
                Arc::new(StaticProvider::new("답변")),
            )
            .expect("initial generation");
        let deadline = Instant::now() + Duration::from_secs(2);
        let original = loop {
            let messages = action_core
                .list_messages(&action_conversation.id)
                .expect("action messages");
            if messages.len() == 2 && messages[1].status == MessageStatus::Complete {
                break messages;
            }
            assert!(Instant::now() < deadline, "initial generation timed out");
            thread::sleep(Duration::from_millis(10));
        };
        let action_state = action_core
            .get_conversation_state(&action_conversation.id)
            .expect("action state");
        let branch_count = action_core
            .list_conversation_branches(&action_conversation.id)
            .expect("action branches")
            .len();
        let message_count = action_core.database_stats().expect("action stats").messages;
        poison_generation_registry(&action_core);
        let action_error = action_core
            .edit_user_message_with_provider(
                &action_conversation.id,
                &action_state.active_branch_id,
                Some(&original[1].id),
                &original[0].id,
                "수정본",
                "unused".to_owned(),
                None,
                Arc::new(StaticProvider::new("unused")),
            )
            .expect_err("action launch preflight must fail");
        assert_eq!(action_error.code, CoreErrorCode::Internal);
        assert_eq!(
            action_core
                .get_conversation_state(&action_conversation.id)
                .expect("unchanged action state")
                .active_branch_id,
            action_state.active_branch_id
        );
        assert_eq!(
            action_core
                .list_conversation_branches(&action_conversation.id)
                .expect("unchanged action branches")
                .len(),
            branch_count
        );
        assert_eq!(
            action_core
                .database_stats()
                .expect("unchanged stats")
                .messages,
            message_count
        );
        assert_eq!(
            action_core
                .list_messages(&action_conversation.id)
                .expect("unchanged action messages"),
            original
        );
    }

    #[test]
    fn regenerate_revalidates_copied_user_text_before_creating_a_branch() {
        let (_root, core, character) = imported_core();
        for (index, invalid_text) in ["   ".to_owned(), "x".repeat(MAX_USER_MESSAGE_BYTES + 1)]
            .into_iter()
            .enumerate()
        {
            let conversation = core
                .create_conversation(
                    &character.id,
                    format!("비정상 원본 {index}"),
                    ConversationMode::Chat,
                )
                .expect("conversation");
            let state = core
                .get_conversation_state(&conversation.id)
                .expect("state");
            let user = Message::user(conversation.id.clone(), invalid_text);
            let generation_id = GenerationId::new();
            let pending = Message::pending_assistant(
                conversation.id.clone(),
                user.id.clone(),
                generation_id.clone(),
            );
            let generation = GenerationRecord {
                id: generation_id,
                conversation_id: conversation.id.clone(),
                branch_id: state.active_branch_id.clone(),
                user_message_id: user.id.clone(),
                assistant_message_id: Some(pending.id.clone()),
                mode: ConversationMode::Chat,
                model: "synthetic".to_owned(),
                status: GenerationStatus::Running,
                input_tokens: None,
                output_tokens: None,
                error_code: None,
                started_at: pending.created_at,
                finished_at: None,
            };
            core.inner
                .storage
                .append_generation(&state.active_branch_id, None, &user, &pending, &generation)
                .expect("append abnormal legacy generation");
            let mut assistant = pending;
            assistant.content = "legacy response".to_owned();
            assistant.status = MessageStatus::Complete;
            core.inner
                .storage
                .finalize_generation(&assistant, None, None, true)
                .expect("finalize abnormal legacy generation");

            let branches_before = core
                .list_conversation_branches(&conversation.id)
                .expect("branches before");
            let messages_before = core
                .list_messages(&conversation.id)
                .expect("messages before");
            let error = core
                .regenerate_assistant_message_with_provider(
                    &conversation.id,
                    &state.active_branch_id,
                    Some(&assistant.id),
                    &assistant.id,
                    "unused".to_owned(),
                    None,
                    Arc::new(StaticProvider::new("unused")),
                )
                .expect_err("invalid copied user text");
            assert_eq!(error.code, CoreErrorCode::InvalidInput);
            assert_eq!(
                core.list_conversation_branches(&conversation.id)
                    .expect("unchanged branches"),
                branches_before
            );
            assert_eq!(
                core.list_messages(&conversation.id)
                    .expect("unchanged messages"),
                messages_before
            );
        }
    }

    #[test]
    fn provider_output_limit_failure_obeys_the_partial_persistence_policy() {
        let conversation_id = ConversationId::new();
        let parent_id = lorepia_domain::MessageId::new();
        let generation_id = GenerationId::new();
        let failure = GenerationFailure {
            error: CoreError::new(
                CoreErrorCode::ProviderUnavailable,
                lorepia_chat::OUTPUT_LIMIT_ERROR_MESSAGE,
                false,
            ),
            partial_text: "safe prefix 😀".to_owned(),
            last_sequence: 7,
        };

        let mut preserved = Message::pending_assistant(
            conversation_id.clone(),
            parent_id.clone(),
            generation_id.clone(),
        );
        let (sequence, terminal, should_commit) =
            apply_generation_result(&mut preserved, Err(failure.clone()), true);
        assert_eq!(sequence, 8);
        assert_eq!(preserved.status, MessageStatus::Failed);
        assert_eq!(preserved.content, "safe prefix 😀");
        assert!(should_commit);
        assert!(matches!(
            terminal,
            ChatEventKind::GenerationFailed { code, message }
                if code == "provider_unavailable"
                    && message == lorepia_chat::OUTPUT_LIMIT_ERROR_MESSAGE
        ));

        let mut discarded = Message::pending_assistant(conversation_id, parent_id, generation_id);
        let (_, _, should_commit) = apply_generation_result(&mut discarded, Err(failure), false);
        assert!(!should_commit);
    }

    #[test]
    fn static_provider_persists_assistant_message() {
        let (root, core, character) = imported_core();
        let conversation = core.open_conversation(&character.id).expect("conversation");
        let mut events = core.subscribe_events();
        let generation_id = core
            .send_message_with_provider(
                &conversation.id,
                "Hello",
                "static".to_owned(),
                None,
                Arc::new(StaticProvider::new("Hi there")),
            )
            .expect("send");

        let deadline = Instant::now() + Duration::from_secs(2);
        loop {
            let messages = core.list_messages(&conversation.id).expect("messages");
            if messages.len() == 2 && messages[1].status == MessageStatus::Complete {
                assert_eq!(messages[1].content, "Hi there");
                break;
            }
            assert!(Instant::now() < deadline, "generation timed out");
            thread::sleep(Duration::from_millis(10));
        }

        let events = std::iter::from_fn(|| events.try_recv().ok()).collect::<Vec<_>>();
        let committed = events
            .iter()
            .position(|event| matches!(event.kind, ChatEventKind::MessageCommitted { .. }))
            .expect("message committed event");
        let finished = events
            .iter()
            .position(|event| matches!(event.kind, ChatEventKind::GenerationFinished))
            .expect("generation finished event");
        assert!(committed < finished);
        assert!(events.windows(2).all(|events| {
            events[0].generation_id != events[1].generation_id
                || events[0].sequence < events[1].sequence
        }));
        let state = core
            .get_conversation_state(&conversation.id)
            .expect("conversation state");
        let generation = core
            .inner
            .storage
            .get_generation(&generation_id)
            .expect("generation snapshot");
        assert_eq!(generation.mode, ConversationMode::Chat);
        assert!(events.iter().all(|event| {
            event.branch_id.as_ref() == Some(&state.active_branch_id)
                && event.assistant_message_id.as_ref() == generation.assistant_message_id.as_ref()
        }));

        drop(core);
        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen");
        let restored = reopened
            .list_messages(&conversation.id)
            .expect("restored messages");
        assert_eq!(restored.len(), 2);
        assert_eq!(restored[1].content, "Hi there");
    }

    #[test]
    fn usage_overflow_is_compensated_as_failed_and_allows_the_next_send() {
        let (root, core, character) = imported_core();
        let conversation = core.open_conversation(&character.id).expect("conversation");
        let mut events = core.subscribe_events();
        let secret = "credential-must-not-leak";
        let failed_generation_id = core
            .send_message_with_provider(
                &conversation.id,
                "first",
                "overflow".to_owned(),
                Some(secret.to_owned()),
                Arc::new(OverflowUsageProvider),
            )
            .expect("start overflow generation");

        let failed_generation =
            wait_for_generation_status(&core, &failed_generation_id, GenerationStatus::Failed);
        wait_for_generation_registry_to_drain(&core);
        assert_eq!(failed_generation.input_tokens, None);
        assert_eq!(failed_generation.output_tokens, None);
        assert_eq!(
            failed_generation.error_code.as_deref(),
            Some(CoreErrorCode::StorageUnavailable.as_str())
        );
        assert!(failed_generation.finished_at.is_some());

        let failed_messages = core
            .list_messages(&conversation.id)
            .expect("failed messages");
        assert_eq!(failed_messages.len(), 2);
        assert_eq!(failed_messages[1].status, MessageStatus::Failed);
        assert_eq!(failed_messages[1].content, "response before invalid usage");

        let observed = std::iter::from_fn(|| events.try_recv().ok()).collect::<Vec<_>>();
        assert!(observed.iter().any(|event| {
            matches!(
                &event.kind,
                ChatEventKind::GenerationFailed { code, message }
                    if code == CoreErrorCode::StorageUnavailable.as_str()
                        && message == GENERATION_PERSISTENCE_FAILURE_MESSAGE
            )
        }));
        assert!(
            !format!("{observed:?}").contains(secret),
            "generation events must not expose credentials"
        );

        drop(core);
        let core = Core::open(CoreConfig::new(root.path())).expect("reopen core");
        assert_eq!(
            core.inner
                .storage
                .get_generation(&failed_generation_id)
                .expect("restored failed generation")
                .status,
            GenerationStatus::Failed
        );
        assert_eq!(
            core.list_messages(&conversation.id)
                .expect("restored failed messages")[1]
                .status,
            MessageStatus::Failed
        );

        let next_generation_id = core
            .send_message_with_provider(
                &conversation.id,
                "second",
                "static".to_owned(),
                None,
                Arc::new(StaticProvider::new("retry succeeded")),
            )
            .expect("start retry generation");
        wait_for_generation_status(&core, &next_generation_id, GenerationStatus::Complete);
        let messages = core
            .list_messages(&conversation.id)
            .expect("messages after retry");
        assert_eq!(messages.len(), 4);
        assert_eq!(messages[1].status, MessageStatus::Failed);
        assert_eq!(messages[3].status, MessageStatus::Complete);
        assert_eq!(messages[3].content, "retry succeeded");
        assert!(
            messages
                .iter()
                .all(|message| message.status != MessageStatus::Pending)
        );
    }
}
