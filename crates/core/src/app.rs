use std::{
    collections::HashMap,
    fs::{self, OpenOptions},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, RwLock},
    time::Duration,
};

use chrono::Utc;
use lorepia_chat::{ChatEvent, PromptPlanner, run_generation};
use lorepia_content::{inspect_file, sha256_file};
use lorepia_domain::{
    AppSettings, Character, Conversation, ConversationId, CoreError, CoreErrorCode, CoreResult,
    GenerationId, HealthReport, ImportInspection, ImportLimits, InspectionId, Message, MessageId,
    MessageRole, MessageStatus, ProviderProfile,
};
use lorepia_providers::{OpenAiCompatibleProvider, Provider};
use lorepia_storage::{DatabaseStats, Storage};
use tokio::{
    runtime::{Builder, Runtime},
    sync::{broadcast, mpsc, watch},
};
use uuid::Uuid;

use crate::{CoreConfig, core_version};

#[derive(Clone)]
pub struct Core {
    inner: Arc<CoreInner>,
}

struct CoreInner {
    storage: Arc<Storage>,
    runtime: Runtime,
    pending_imports: RwLock<HashMap<InspectionId, PendingImport>>,
    active_generations: Mutex<HashMap<GenerationId, watch::Sender<bool>>>,
    event_bus: broadcast::Sender<ChatEvent>,
}

#[derive(Clone)]
struct PendingImport {
    path: PathBuf,
    inspection: ImportInspection,
}

impl Core {
    pub fn open(config: CoreConfig) -> CoreResult<Self> {
        let storage = Arc::new(Storage::open(config.data_root)?);
        let runtime = Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("lorepia-core")
            .build()
            .map_err(|error| {
                CoreError::internal(format!("cannot create core async runtime: {error}"))
            })?;
        let (event_bus, _) = broadcast::channel(256);
        Ok(Self {
            inner: Arc::new(CoreInner {
                storage,
                runtime,
                pending_imports: RwLock::new(HashMap::new()),
                active_generations: Mutex::new(HashMap::new()),
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
        let staged_path = staged_path.as_ref();
        let inspection = inspect_file(staged_path, ImportLimits::default())?;
        self.inner
            .pending_imports
            .write()
            .map_err(|_| CoreError::internal("pending import lock was poisoned"))?
            .insert(
                inspection.id.clone(),
                PendingImport {
                    path: staged_path.to_path_buf(),
                    inspection: inspection.clone(),
                },
            );
        Ok(inspection)
    }

    pub fn commit_import(&self, inspection_id: &InspectionId) -> CoreResult<Character> {
        let pending = self
            .inner
            .pending_imports
            .read()
            .map_err(|_| CoreError::internal("pending import lock was poisoned"))?
            .get(inspection_id)
            .cloned()
            .ok_or_else(|| {
                CoreError::new(CoreErrorCode::NotFound, "inspection was not found", false)
            })?;
        if !pending.inspection.is_allowed() {
            return Err(CoreError::new(
                CoreErrorCode::UnsafeArchive,
                "blocked import cannot be committed",
                false,
            ));
        }
        let current_hash = sha256_file(&pending.path)?;
        if current_hash != pending.inspection.source_sha256 {
            return Err(CoreError::new(
                CoreErrorCode::UnsafeArchive,
                "staging file changed after inspection",
                false,
            ));
        }

        let character = Character::new(
            &pending.inspection.display_name,
            &pending.inspection.description,
            &pending.inspection.source_sha256,
        );
        self.inner.storage.commit_character_import(
            &pending.path,
            &character,
            pending.inspection.source_size,
            &inspection_id.0,
        )?;
        self.inner
            .pending_imports
            .write()
            .map_err(|_| CoreError::internal("pending import lock was poisoned"))?
            .remove(inspection_id);
        Ok(character)
    }

    pub fn list_characters(&self) -> CoreResult<Vec<Character>> {
        self.inner.storage.list_characters()
    }

    pub fn get_character(&self, id: &str) -> CoreResult<Character> {
        self.inner.storage.get_character(id)
    }

    pub fn open_conversation(&self, character_id: &str) -> CoreResult<Conversation> {
        let character = self.get_character(character_id)?;
        let conversation = Conversation::new(character.id, character.name);
        self.inner.storage.save_conversation(&conversation)?;
        Ok(conversation)
    }

    pub fn list_conversations(&self) -> CoreResult<Vec<Conversation>> {
        self.inner.storage.list_conversations()
    }

    pub fn list_messages(&self, conversation_id: &ConversationId) -> CoreResult<Vec<Message>> {
        self.inner.storage.list_messages(conversation_id)
    }

    pub fn send_message(
        &self,
        conversation_id: &ConversationId,
        text: &str,
        profile: ProviderProfile,
        credential: Option<String>,
    ) -> CoreResult<GenerationId> {
        let provider = Arc::new(OpenAiCompatibleProvider::new(
            &profile.base_url,
            Duration::from_secs(u64::from(profile.timeout_seconds.max(1))),
        )?);
        self.send_message_with_provider(conversation_id, text, profile.model, credential, provider)
    }

    pub fn cancel_generation(&self, generation_id: &GenerationId) -> CoreResult<()> {
        let sender = self
            .inner
            .active_generations
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

    pub fn subscribe_events(&self) -> broadcast::Receiver<ChatEvent> {
        self.inner.event_bus.subscribe()
    }

    pub fn get_settings(&self) -> CoreResult<AppSettings> {
        self.inner.storage.load_settings()
    }

    pub fn update_settings(&self, settings: &AppSettings) -> CoreResult<()> {
        self.inner.storage.save_settings(settings)
    }

    pub fn database_stats(&self) -> CoreResult<DatabaseStats> {
        self.inner.storage.stats()
    }

    fn send_message_with_provider(
        &self,
        conversation_id: &ConversationId,
        text: &str,
        model: String,
        credential: Option<String>,
        provider: Arc<dyn Provider>,
    ) -> CoreResult<GenerationId> {
        if text.trim().is_empty() {
            return Err(CoreError::invalid("message text cannot be empty"));
        }
        let conversation = self.inner.storage.get_conversation(conversation_id)?;
        let character = self
            .inner
            .storage
            .get_character(&conversation.character_id)?;
        let user_message = Message::user(conversation_id.clone(), text.trim());
        self.inner.storage.save_message(&user_message)?;
        let history = self.inner.storage.list_messages(conversation_id)?;
        let request = PromptPlanner::plan(
            &character,
            conversation_id.clone(),
            &history,
            model,
            1.0,
            None,
        );
        let generation_id = request.generation_id.clone();
        let (cancel_sender, cancel_receiver) = watch::channel(false);
        self.inner
            .active_generations
            .lock()
            .map_err(|_| CoreError::internal("generation registry lock was poisoned"))?
            .insert(generation_id.clone(), cancel_sender);

        let inner = Arc::clone(&self.inner);
        let generation_id_for_task = generation_id.clone();
        let conversation_id_for_task = conversation_id.clone();
        self.inner.runtime.spawn(async move {
            let (event_sender, mut event_receiver) = mpsc::channel(128);
            let event_bus = inner.event_bus.clone();
            let forward_events = tokio::spawn(async move {
                while let Some(event) = event_receiver.recv().await {
                    let _ = event_bus.send(event);
                }
            });
            let result = run_generation(
                provider.as_ref(),
                request,
                credential.as_deref(),
                event_sender,
                cancel_receiver,
            )
            .await;
            if let Ok(outcome) = result {
                let assistant = Message {
                    id: MessageId::new(),
                    conversation_id: conversation_id_for_task,
                    parent_id: Some(user_message.id),
                    role: MessageRole::Assistant,
                    content: outcome.text,
                    status: MessageStatus::Complete,
                    generation_id: Some(generation_id_for_task.clone()),
                    created_at: Utc::now(),
                };
                let _ = inner.storage.save_message(&assistant);
            }
            let _ = forward_events.await;
            if let Ok(mut registry) = inner.active_generations.lock() {
                registry.remove(&generation_id_for_task);
            }
        });
        Ok(generation_id)
    }

    fn active_generation_count(&self) -> usize {
        self.inner
            .active_generations
            .lock()
            .map_or(0, |registry| registry.len())
    }
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

#[cfg(test)]
mod tests {
    use std::{
        io::Write,
        thread,
        time::{Duration, Instant},
    };

    use lorepia_providers::StaticProvider;
    use tempfile::{NamedTempFile, tempdir};

    use super::*;

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

    #[test]
    fn health_reports_storage_state() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let health = core.health_check().expect("health");
        assert!(health.database_open);
        assert!(health.data_root_writable);
        assert_eq!(health.schema_version, 1);
    }

    #[test]
    fn import_and_restart_restore_library() {
        let (root, core, _) = imported_core();
        drop(core);
        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen");
        assert_eq!(reopened.list_characters().expect("library").len(), 1);
    }

    #[test]
    fn static_provider_persists_assistant_message() {
        let (_root, core, character) = imported_core();
        let conversation = core.open_conversation(&character.id).expect("conversation");
        core.send_message_with_provider(
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
            if messages.len() == 2 {
                assert_eq!(messages[1].content, "Hi there");
                break;
            }
            assert!(Instant::now() < deadline, "generation timed out");
            thread::sleep(Duration::from_millis(10));
        }
    }
}
