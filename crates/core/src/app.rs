use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    future::Future,
    io::{BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, RwLock},
    time::{Duration, Instant},
};

use chrono::{DateTime, Utc};
use lorepia_chat::{
    ChatEvent, ChatEventKind, GenerationFailure, GenerationOutcome, MAX_HISTORY_MESSAGE_BYTES,
    MAX_HISTORY_MESSAGE_CHARS, MAX_PROMPT_MESSAGES, PromptPlanner, run_generation,
};
use lorepia_content::{StagedAsset, prepare_import};
use lorepia_domain::{
    ApiFamily, AppSettings, AuthBinding, BoundedJson, CanonicalOrigin, CapabilityKey,
    CapabilityObservation, CapabilityValue, Character, Confidence, ConnectionConfig,
    ConnectionStatus, Conversation, ConversationBranch, ConversationBranchId, ConversationId,
    ConversationMode, ConversationState, CoreError, CoreErrorCode, CoreResult,
    CredentialRedirectPolicy, CredentialRef, CredentialScope, EndpointPath, GenerationId,
    GenerationPreset, GenerationPresetId, GenerationProviderProvenance, GenerationRecord,
    GenerationRequest, GenerationStatus, GenerationTarget, HealthReport, ImportInspection,
    ImportLimits, InspectionId, Message, MessageActionGeneration, MessageId, MessageRole,
    MessageStatus, ModelAvailability, ModelMetadataSource, ModelRoute, ModelRouteConfig,
    ModelRouteId, ObservationId, ObservationSource, OpaqueReasoningContext, OpaqueReasoningState,
    ParameterDefaultMode, ParameterId, ParameterSpec, ParameterType, ProviderConnection,
    ProviderConnectionDraft, ProviderConnectionId, ProviderLocalNetworkApproval,
    ProviderNetworkMode, ProviderParameterMapping, ProviderParameterTarget, ProviderProfile,
    ProviderTemplate, SupportStatus, TemplateSource, UiParameterLevel,
    validate_opaque_reasoning_states,
};
use lorepia_providers::parameter_mapping::{
    GEMINI_OPAQUE_REASONING_TOPOLOGY_ERROR, OpenRouterReasoningWireStyle, ParameterEngine,
    PromptCacheControlModel, PromptCacheSettings, PromptCacheWireDialect, ProviderRequestPlan,
    ReasoningControlModel, ReasoningSettings, ReasoningWireDialect,
    parse_prompt_cache_wire_dialect_metadata, parse_reasoning_wire_dialect_metadata,
    render_prompt_cache_control, render_reasoning_control,
    validate_and_build_provider_request_plan,
};
use lorepia_providers::url_policy::{ApprovedLocalNetworkOrigin, UrlPolicy};
use lorepia_providers::{
    AdapterRegistry, BuiltInTemplateId, ListedModel, ListedModelCapabilities,
    ListedModelCapability, ListedModelReasoningCapability, ModelListResult, ModelRecordSource,
    OPAQUE_REASONING_STATE_UNSUPPORTED_ERROR, OpenAiCompatibleProvider,
    OpenRouterReasoningEffortSupport, OpenRouterSupportedParameter,
    OpenRouterSupportedParameterSupport, Provider, RequestPreview, merge_capability_observations,
    validate_connection_fields, validate_manifest,
};
use lorepia_storage::{
    DatabaseStats, MessageGenerationAction, StagedAssetImport, Storage,
    validate_provider_api_route_metadata,
};
use tokio::{
    runtime::{Builder, Handle},
    sync::{broadcast, mpsc, watch},
    time::{self, MissedTickBehavior},
};
use uuid::Uuid;

use crate::{
    CoreConfig,
    catalog::{CatalogRouteProjection, PendingProviderCatalogImportPlan},
    core_version,
};

mod model_sync;

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
const PROVIDER_API_CAPABILITY_FRESHNESS: chrono::Duration = chrono::Duration::hours(24);
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
    pending_catalog_import_plans: Mutex<HashMap<String, PendingProviderCatalogImportPlan>>,
    active_generations: Arc<GenerationRegistry>,
    active_model_syncs: Arc<model_sync::ModelSyncRegistry>,
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

pub(crate) struct ResolvedGenerationTarget {
    pub(crate) model: String,
    pub(crate) provider: Arc<dyn Provider>,
    pub(crate) api_family: ApiFamily,
    pub(crate) preserve_opaque_reasoning_state: bool,
}

struct ValidatedGenerationTarget {
    route: ModelRoute,
    connection: ProviderConnection,
    template: ProviderTemplate,
    request_plan: ProviderRequestPlan,
}

struct GenerationPresetControlContext {
    route: ModelRoute,
    connection: ProviderConnection,
    template: ProviderTemplate,
    parameter_engine: ParameterEngine,
    reasoning: ReasoningSettings,
    prompt_cache: PromptCacheSettings,
    reasoning_dialect: ReasoningWireDialect,
    cache_dialect: PromptCacheWireDialect,
}

/// Non-secret provenance for one successful provider model-list request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderModelRefreshProvenance {
    pub source: String,
    pub api_family: ApiFamily,
    pub api_origin: CanonicalOrigin,
    pub endpoint_path: EndpointPath,
}

/// Reconciled model catalog state returned to native clients.
///
/// Raw provider responses and credentials are intentionally excluded. Missing
/// routes remain in `model_routes` with `MissingTemporarily` availability so
/// existing presets and selections can be repaired explicitly by native UI.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderModelRefreshResult {
    pub connection_id: ProviderConnectionId,
    pub model_routes: Vec<ModelRoute>,
    pub newly_seen_model_route_ids: Vec<ModelRouteId>,
    pub missing_model_route_ids: Vec<ModelRouteId>,
    pub created_generation_preset_ids: Vec<GenerationPresetId>,
    pub routes_requiring_preset_configuration: Vec<ModelRouteId>,
    pub provenance: ProviderModelRefreshProvenance,
    pub pages_fetched: u32,
    pub response_bytes: u64,
    pub observed_at: DateTime<Utc>,
}

/// Native-facing provider-template presentation derived by Rust.
///
/// `default_network_mode` comes from the compiled adapter descriptor rather
/// than from native inference or persisted template JSON. This keeps Ollama's
/// loopback boundary explicit while every other built-in family defaults to
/// the public network policy.
#[derive(Debug, Clone, PartialEq)]
pub struct ProviderTemplateView {
    pub template: ProviderTemplate,
    pub default_network_mode: ProviderNetworkMode,
}

/// Deterministically merged capability state for one route and key.
///
/// Alternatives remain visible so native UI can explain disagreements rather
/// than presenting the selected value as an unqualified fact.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EffectiveCapability {
    pub selected: CapabilityObservation,
    pub alternatives: Vec<CapabilityObservation>,
    pub evaluated_at: DateTime<Utc>,
    pub selected_is_stale: bool,
    pub has_conflict: bool,
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
        self.active_model_syncs.cancel_all();
        self.runtime.shutdown();
    }
}

fn compiled_built_in_default_api_base_path(
    template: &ProviderTemplate,
) -> CoreResult<Option<EndpointPath>> {
    if template.source != TemplateSource::BuiltIn {
        return Ok(None);
    }
    let Some(id) = BuiltInTemplateId::ALL
        .into_iter()
        .find(|id| id.as_str() == template.id.as_str())
    else {
        return Ok(None);
    };
    let compiled = AdapterRegistry::built_in_template(id)?;
    if template != &compiled {
        return Ok(None);
    }
    EndpointPath::parse(id.default_api_base_path())
        .map(Some)
        .map_err(|error| {
            CoreError::internal(format!(
                "compiled provider API base path is invalid: {error}"
            ))
        })
}

impl Core {
    pub fn open(config: CoreConfig) -> CoreResult<Self> {
        let storage = Arc::new(Storage::open_with_deferred_discovery_recovery(
            config.data_root,
        )?);
        for template in AdapterRegistry::built_in_templates()? {
            validate_provider_template(&template)?;
            storage.save_provider_template(&template)?;
        }
        let resumable_assistant_operations =
            crate::provider_discovery::resumable_assistant_operation_ids(&storage)?;
        storage.recover_unfinished_discovery_operations_except(
            Utc::now(),
            &resumable_assistant_operations,
        )?;
        let runtime = RuntimeControl::start()?;
        let (event_bus, _) = broadcast::channel(256);
        Ok(Self {
            inner: Arc::new(CoreInner {
                storage,
                runtime,
                pending_imports: RwLock::new(HashMap::new()),
                pending_catalog_import_plans: Mutex::new(HashMap::new()),
                active_generations: Arc::new(GenerationRegistry::default()),
                active_model_syncs: Arc::new(model_sync::ModelSyncRegistry::default()),
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
            active_jobs: u32::try_from(
                self.active_generation_count()
                    .saturating_add(self.inner.active_model_syncs.len()),
            )
            .unwrap_or(u32::MAX),
        })
    }

    pub(crate) fn storage(&self) -> &Storage {
        &self.inner.storage
    }

    pub(crate) fn pending_catalog_import_plans(
        &self,
    ) -> &Mutex<HashMap<String, PendingProviderCatalogImportPlan>> {
        &self.inner.pending_catalog_import_plans
    }

    pub(crate) fn runtime_handle(&self) -> &Handle {
        &self.inner.runtime.handle
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

    pub fn send_message_with_target(
        &self,
        conversation_id: &ConversationId,
        text: &str,
        target: &GenerationTarget,
        credential: Option<String>,
    ) -> CoreResult<GenerationId> {
        let resolved = resolve_generation_target(self, target)?;
        let state = self.inner.storage.get_conversation_state(conversation_id)?;
        let branch = self
            .inner
            .storage
            .get_conversation_branch(&state.active_branch_id)?;
        self.send_message_to_branch_with_provider_options(
            conversation_id,
            &state.active_branch_id,
            branch.head_message_id.as_ref(),
            state.selected_mode,
            text,
            resolved.model,
            Some(target),
            Some(resolved.api_family),
            resolved.preserve_opaque_reasoning_state,
            None,
            None,
            credential,
            resolved.provider,
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
    pub fn send_message_to_branch_with_target(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        mode: ConversationMode,
        text: &str,
        target: &GenerationTarget,
        credential: Option<String>,
    ) -> CoreResult<GenerationId> {
        let resolved = resolve_generation_target(self, target)?;
        self.send_message_to_branch_with_provider_options(
            conversation_id,
            branch_id,
            expected_head,
            mode,
            text,
            resolved.model,
            Some(target),
            Some(resolved.api_family),
            resolved.preserve_opaque_reasoning_state,
            None,
            None,
            credential,
            resolved.provider,
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
    pub fn edit_user_message_with_target(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
        replacement_text: &str,
        target: &GenerationTarget,
        credential: Option<String>,
    ) -> CoreResult<MessageActionGeneration> {
        let resolved = resolve_generation_target(self, target)?;
        self.start_message_generation_action_with_provider_options(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
            MessageGenerationAction::EditUser,
            Some(replacement_text),
            resolved.model,
            Some(target),
            Some(resolved.api_family),
            resolved.preserve_opaque_reasoning_state,
            None,
            None,
            credential,
            resolved.provider,
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

    #[allow(clippy::too_many_arguments)]
    pub fn regenerate_assistant_message_with_target(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
        target: &GenerationTarget,
        credential: Option<String>,
    ) -> CoreResult<MessageActionGeneration> {
        let resolved = resolve_generation_target(self, target)?;
        self.start_message_generation_action_with_provider_options(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
            MessageGenerationAction::RegenerateAssistant,
            None,
            resolved.model,
            Some(target),
            Some(resolved.api_family),
            resolved.preserve_opaque_reasoning_state,
            None,
            None,
            credential,
            resolved.provider,
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
        validate_settings_generation_target(self, settings)?;
        self.inner.storage.save_settings(settings)
    }

    pub fn list_provider_templates(&self) -> CoreResult<Vec<ProviderTemplate>> {
        let active_catalog = self.operational_provider_catalog_projection_at(Utc::now())?;
        let active_templates = active_catalog.provider_templates();
        let active_ids = active_templates
            .iter()
            .map(|template| template.id.clone())
            .collect::<HashSet<_>>();
        let mut by_id = self
            .inner
            .storage
            .list_provider_templates()?
            .into_iter()
            // Signed template rows are retained only to keep already-created
            // connections pinned. Visibility is controlled by the atomic
            // active catalog pointer, never by these inert support rows.
            .filter(|template| {
                template.source != TemplateSource::SignedCatalog
                    && !active_ids.contains(&template.id)
            })
            .fold(HashMap::new(), |mut latest, template| {
                latest
                    .entry(template.id.clone())
                    .and_modify(|current: &mut ProviderTemplate| {
                        if template.manifest_version > current.manifest_version {
                            *current = template.clone();
                        }
                    })
                    .or_insert(template);
                latest
            });
        for template in active_templates {
            validate_provider_template(&template)?;
            by_id.insert(template.id.clone(), template);
        }
        let mut templates = by_id.into_values().collect::<Vec<_>>();
        templates.sort_by(|left, right| {
            left.display_name
                .to_lowercase()
                .cmp(&right.display_name.to_lowercase())
                .then_with(|| left.id.cmp(&right.id))
                .then_with(|| right.manifest_version.cmp(&left.manifest_version))
        });
        Ok(templates)
    }

    /// Lists provider templates together with Rust-owned presentation defaults.
    pub fn list_provider_template_views(&self) -> CoreResult<Vec<ProviderTemplateView>> {
        self.list_provider_templates()?
            .into_iter()
            .map(|template| {
                validate_provider_template(&template)?;
                let descriptor = AdapterRegistry::descriptor(template.api_family)?;
                Ok(ProviderTemplateView {
                    template,
                    default_network_mode: descriptor.default_network_mode,
                })
            })
            .collect()
    }

    pub fn list_provider_connections(&self) -> CoreResult<Vec<ProviderConnection>> {
        self.inner.storage.list_provider_connections()
    }

    #[allow(
        clippy::too_many_lines,
        reason = "connection creation is one fail-closed validation and persistence boundary"
    )]
    pub fn create_provider_connection(
        &self,
        mut draft: ProviderConnectionDraft,
    ) -> CoreResult<ProviderConnection> {
        match self.inner.storage.get_provider_connection(&draft.id) {
            Ok(_) => {
                return Err(CoreError::invalid(
                    "provider connection identifier already exists; create a new connection identifier",
                ));
            }
            Err(error) if error.code == CoreErrorCode::NotFound => {}
            Err(error) => return Err(error),
        }
        let (network_policy, local_network_approval) = match (
            draft.network_mode,
            draft.local_network_approval.as_ref(),
        ) {
            (ProviderNetworkMode::Public, None) => (UrlPolicy::public(), None),
            (ProviderNetworkMode::LocalLoopback, None) => (UrlPolicy::local_loopback(), None),
            (ProviderNetworkMode::ApprovedLocalNetwork, Some(approval)) => {
                if approval.origin != draft.api_origin {
                    return Err(CoreError::invalid(
                        "local-network approval origin must exactly match the provider API origin",
                    ));
                }
                let approval =
                    ApprovedLocalNetworkOrigin::new(approval.origin.as_str(), &approval.addresses)
                        .map_err(|error| {
                            CoreError::invalid(format!(
                                "provider local-network approval is invalid: {error}"
                            ))
                        })?;
                let normalized = ProviderLocalNetworkApproval {
                    origin: draft.api_origin.clone(),
                    addresses: approval.addresses().to_vec(),
                };
                (
                    UrlPolicy::approved_local_network(approval),
                    Some(normalized),
                )
            }
            (ProviderNetworkMode::ApprovedLocalNetwork, None) => {
                return Err(CoreError::invalid(
                    "approved local-network mode requires an exact origin and address approval",
                ));
            }
            (ProviderNetworkMode::Public | ProviderNetworkMode::LocalLoopback, Some(_)) => {
                return Err(CoreError::invalid(
                    "local-network approval is only valid in approved local-network mode",
                ));
            }
        };
        let policy_url = network_policy
            .canonicalize(&format!(
                "{}/",
                draft.api_origin.as_str().trim_end_matches('/')
            ))
            .map_err(|error| {
                CoreError::invalid(format!("provider API origin is not allowed: {error}"))
            })?;
        if policy_url.origin().as_string() != draft.api_origin.as_str() {
            return Err(CoreError::invalid(
                "provider API origin is not in canonical form",
            ));
        }
        draft.local_network_approval = local_network_approval;
        let active_catalog = self.operational_provider_catalog_projection_at(Utc::now())?;
        let expected_catalog_state_version = active_catalog.state_version;
        let template = if let Some(template) =
            active_catalog.provider_template(&draft.template_id, draft.template_version)
        {
            template
        } else {
            let template = self
                .inner
                .storage
                .get_provider_template(&draft.template_id, draft.template_version)?;
            if template.source == TemplateSource::SignedCatalog {
                return Err(CoreError::new(
                    CoreErrorCode::NotFound,
                    "provider template is not active in the signed catalog",
                    false,
                ));
            }
            template
        };
        validate_provider_template(&template)?;
        if draft.api_base_path.is_none() {
            draft.api_base_path = compiled_built_in_default_api_base_path(&template)?;
        }
        let credential_scope = match &template.default_manifest.auth {
            AuthBinding::None => {
                if draft.approved_credential_origin.is_some() {
                    return Err(CoreError::invalid(
                        "credential-free provider must not declare a credential origin",
                    ));
                }
                None
            }
            auth_binding => {
                let approved_origin =
                    draft.approved_credential_origin.as_ref().ok_or_else(|| {
                        CoreError::invalid(
                            "credential origin approval is required before saving this connection",
                        )
                    })?;
                if approved_origin != &draft.api_origin {
                    return Err(CoreError::invalid(
                        "approved credential origin must exactly match the provider API origin",
                    ));
                }
                Some(CredentialScope {
                    allowed_origins: vec![approved_origin.clone()],
                    auth_binding: auth_binding.clone(),
                    redirect_policy: CredentialRedirectPolicy::Deny,
                })
            }
        };
        let now = Utc::now();
        let connection = ProviderConnection {
            credential_ref: credential_scope
                .as_ref()
                .map(|_| CredentialRef(draft.id.as_str().to_owned())),
            credential_scope,
            id: draft.id,
            template_id: draft.template_id,
            template_version: draft.template_version,
            display_name: draft.display_name,
            api_origin: draft.api_origin,
            config: ConnectionConfig {
                api_base_path: draft.api_base_path,
                network_mode: draft.network_mode,
                local_network_approval: draft.local_network_approval,
                values: draft.values,
            },
            timeout_seconds: draft.timeout_seconds,
            status: ConnectionStatus::Untested,
            created_at: now,
            updated_at: now,
        };
        if template.source == TemplateSource::SignedCatalog {
            self.inner
                .storage
                .insert_provider_connection_for_catalog_state(
                    &connection,
                    &template,
                    expected_catalog_state_version,
                )?;
        } else {
            self.inner.storage.insert_provider_connection(&connection)?;
        }
        Ok(connection)
    }

    pub fn upsert_provider_connection(
        &self,
        connection: ProviderConnection,
    ) -> CoreResult<ProviderConnection> {
        let template = self
            .inner
            .storage
            .get_provider_template(&connection.template_id, connection.template_version)?;
        validate_provider_template(&template)?;
        let current = self.inner.storage.get_provider_connection(&connection.id)?;
        if connection.template_id != current.template_id
            || connection.template_version != current.template_version
            || connection.api_origin != current.api_origin
            || connection.config != current.config
            || connection.credential_ref != current.credential_ref
            || connection.credential_scope != current.credential_scope
        {
            return Err(CoreError::invalid(
                "provider template, endpoint configuration, network approval, and credential binding are immutable; create a newly approved connection instead",
            ));
        }
        let updated = ProviderConnection {
            display_name: connection.display_name,
            timeout_seconds: connection.timeout_seconds,
            updated_at: Utc::now(),
            ..current
        };
        self.inner.storage.save_provider_connection(&updated)?;
        Ok(updated)
    }

    pub fn delete_provider_connection(&self, id: &ProviderConnectionId) -> CoreResult<()> {
        self.inner.storage.delete_provider_connection(id)
    }

    pub fn list_model_routes(
        &self,
        connection_id: &ProviderConnectionId,
    ) -> CoreResult<Vec<ModelRoute>> {
        self.inner.storage.list_model_routes(connection_id)
    }

    /// Legacy immediate-refresh entry point.
    ///
    /// Model catalog writes now require a durable diff and explicit hash
    /// approval. Call `start_provider_model_sync`, wait for
    /// `DiffReadyAwaitingReview`, then call `approve_provider_model_sync`.
    #[deprecated(
        since = "0.1.0",
        note = "use the durable start/get/approve model synchronization APIs"
    )]
    pub fn refresh_provider_models(
        &self,
        _connection_id: &ProviderConnectionId,
        _credential: Option<&str>,
    ) -> CoreResult<ProviderModelRefreshResult> {
        Err(CoreError::invalid(
            "immediate model refresh is disabled; start a durable model synchronization and approve its review hash",
        ))
    }

    pub fn upsert_model_route(&self, mut route: ModelRoute) -> CoreResult<ModelRoute> {
        match self.inner.storage.get_model_route(&route.id) {
            Ok(existing) => {
                if route.connection_id != existing.connection_id
                    || route.api_family != existing.api_family
                    || route.model_id != existing.model_id
                    || route.route_config != existing.route_config
                    || route.first_seen_at != existing.first_seen_at
                {
                    return Err(CoreError::invalid(
                        "an existing model route cannot be rebound to another provider, model, or route discriminator",
                    ));
                }
                // Refresh/catalog provenance is owned by trusted Rust
                // ingestion paths. A native edit may change only the
                // user-facing label and availability.
                route.miss_count = existing.miss_count;
                route.raw_metadata = existing.raw_metadata;
                route.metadata_source = existing.metadata_source;
                route.metadata_observed_at = existing.metadata_observed_at;
                route.last_reconciled_sync_job_id = existing.last_reconciled_sync_job_id;
                route.metadata_sync_job_id = existing.metadata_sync_job_id;
                route.last_seen_at = existing.last_seen_at;
            }
            Err(error) if error.code == CoreErrorCode::NotFound => {
                let connection = self
                    .inner
                    .storage
                    .get_provider_connection(&route.connection_id)?;
                let template = self
                    .inner
                    .storage
                    .get_provider_template(&connection.template_id, connection.template_version)?;
                if route.api_family != template.api_family {
                    return Err(CoreError::invalid(
                        "model route API family does not match its provider template",
                    ));
                }
                if route.miss_count != 0
                    || route.raw_metadata.is_some()
                    || !matches!(
                        route.metadata_source,
                        ModelMetadataSource::Legacy | ModelMetadataSource::UserOverride
                    )
                    || route.metadata_observed_at.is_some()
                    || route.last_reconciled_sync_job_id.is_some()
                    || route.metadata_sync_job_id.is_some()
                {
                    return Err(CoreError::invalid(
                        "a native-created model route cannot claim provider, catalog, probe, or synchronization provenance",
                    ));
                }
            }
            Err(error) => return Err(error),
        }
        self.inner.storage.save_model_route(&route)?;
        Ok(route)
    }

    pub fn delete_model_route(&self, id: &ModelRouteId) -> CoreResult<()> {
        self.inner.storage.delete_model_route(id)
    }

    pub fn upsert_capability_observation(
        &self,
        observation: CapabilityObservation,
    ) -> CoreResult<CapabilityObservation> {
        if observation.source == ObservationSource::SignedLorepiaCatalog {
            return Err(CoreError::invalid(
                "signed catalog observations are derived from the active verified catalog and cannot be stored independently",
            ));
        }
        let route = self
            .inner
            .storage
            .get_model_route(&observation.model_route_id)?;
        let connection = self
            .inner
            .storage
            .get_provider_connection(&route.connection_id)?;
        let template = self
            .inner
            .storage
            .get_provider_template(&connection.template_id, connection.template_version)?;
        validate_capability_wire_metadata(&route, &template, &observation)?;
        self.inner
            .storage
            .upsert_capability_observation(&observation)?;
        Ok(observation)
    }

    /// Stores a capability override explicitly authored by the local user.
    ///
    /// Provider API, signed catalog, probe, documentation, and assistant
    /// observations have dedicated trusted ingestion paths and cannot be
    /// impersonated through a native binding.
    pub fn upsert_user_capability_override(
        &self,
        mut observation: CapabilityObservation,
    ) -> CoreResult<CapabilityObservation> {
        if observation.source != ObservationSource::UserOverride {
            return Err(CoreError::invalid(
                "the user override API only accepts user_override observations",
            ));
        }
        if matches!(observation.value, CapabilityValue::Structured(_)) {
            return Err(CoreError::invalid(
                "structured provider wire metadata cannot be authored as a user override",
            ));
        }
        if !matches!(
            observation.status,
            SupportStatus::Verified
                | SupportStatus::Unsupported
                | SupportStatus::Unknown
                | SupportStatus::Conditional
        ) {
            return Err(CoreError::invalid(
                "user override status must be verified, unsupported, unknown, or conditional",
            ));
        }
        observation.confidence = Confidence::High;
        observation.observed_at = Utc::now();
        observation.evidence_ref = None;
        if observation
            .expires_at
            .is_some_and(|expires_at| expires_at <= observation.observed_at)
        {
            return Err(CoreError::invalid(
                "a user capability override expiry must be in the future",
            ));
        }
        self.upsert_capability_observation(observation)
    }

    pub fn list_capability_observations(
        &self,
        model_route_id: &ModelRouteId,
    ) -> CoreResult<Vec<CapabilityObservation>> {
        let now = Utc::now();
        let route = self.inner.storage.get_model_route(model_route_id)?;
        let catalog = self.catalog_route_projection_at(&route, now)?;
        let mut observations = self
            .inner
            .storage
            .list_capability_observations(model_route_id)?
            .into_iter()
            .filter(|observation| observation.source != ObservationSource::SignedLorepiaCatalog)
            .map(|observation| (observation.id.clone(), observation))
            .collect::<HashMap<_, _>>();
        for observation in catalog.capability_observations {
            observations.insert(observation.id.clone(), observation);
        }
        let mut observations = observations.into_values().collect::<Vec<_>>();
        observations.sort_by(|left, right| {
            capability_key_identity(left.key)
                .cmp(capability_key_identity(right.key))
                .then_with(|| left.id.cmp(&right.id))
        });
        Ok(observations)
    }

    pub fn delete_capability_observation(&self, id: &ObservationId) -> CoreResult<()> {
        self.inner.storage.delete_capability_observation(id)
    }

    pub fn delete_user_capability_override(
        &self,
        model_route_id: &ModelRouteId,
        id: &ObservationId,
    ) -> CoreResult<()> {
        let observation = self
            .inner
            .storage
            .list_capability_observations(model_route_id)?
            .into_iter()
            .find(|observation| observation.id == *id)
            .ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::NotFound,
                    "capability observation was not found",
                    false,
                )
            })?;
        if observation.source != ObservationSource::UserOverride {
            return Err(CoreError::invalid(
                "only user_override observations can be deleted through this API",
            ));
        }
        self.inner.storage.delete_capability_observation(id)
    }

    pub fn effective_capability(
        &self,
        model_route_id: &ModelRouteId,
        key: CapabilityKey,
    ) -> CoreResult<Option<EffectiveCapability>> {
        let now = Utc::now();
        let route = self.inner.storage.get_model_route(model_route_id)?;
        let catalog = self.catalog_route_projection_at(&route, now)?;
        effective_capability_at(
            &self.inner.storage,
            &catalog.capability_observations,
            model_route_id,
            key,
            now,
        )
    }

    /// Return the fresh model-specific parameter contract in effect now.
    ///
    /// Signed exact/glob entries override the family fallback by stable
    /// parameter ID. Stale signed mappings are not allowed to alter a request;
    /// expired layers have already been removed from the active projection.
    pub fn effective_parameter_specs(
        &self,
        model_route_id: &ModelRouteId,
    ) -> CoreResult<Vec<lorepia_domain::ParameterSpec>> {
        let now = Utc::now();
        let route = self.inner.storage.get_model_route(model_route_id)?;
        let connection = self
            .inner
            .storage
            .get_provider_connection(&route.connection_id)?;
        let template = self
            .inner
            .storage
            .get_provider_template(&connection.template_id, connection.template_version)?;
        let catalog = self
            .operational_provider_catalog_projection_at(now)?
            .route_projection(&route, &connection.template_id);
        let base = if catalog.matched {
            catalog.parameters
        } else {
            template.default_manifest.parameters.clone()
        };
        effective_route_parameter_specs(&route, &template, &base, &catalog.signed_parameters, now)
    }

    fn catalog_route_projection_at(
        &self,
        route: &ModelRoute,
        now: DateTime<Utc>,
    ) -> CoreResult<CatalogRouteProjection> {
        let connection = self
            .inner
            .storage
            .get_provider_connection(&route.connection_id)?;
        Ok(self
            .operational_provider_catalog_projection_at(now)?
            .route_projection(route, &connection.template_id))
    }

    /// Atomic ingestion point for direct provider model metadata.
    pub fn record_provider_api_capability_observations(
        &self,
        observations: Vec<CapabilityObservation>,
    ) -> CoreResult<Vec<CapabilityObservation>> {
        self.record_capability_observations_from_source(
            observations,
            ObservationSource::ProviderApi,
        )
    }

    /// Atomic ingestion point for one-shot probe results.
    pub fn record_probe_capability_observations(
        &self,
        observations: Vec<CapabilityObservation>,
    ) -> CoreResult<Vec<CapabilityObservation>> {
        self.record_capability_observations_from_source(
            observations,
            ObservationSource::CapabilityProbe,
        )
    }

    fn record_capability_observations_from_source(
        &self,
        observations: Vec<CapabilityObservation>,
        expected_source: ObservationSource,
    ) -> CoreResult<Vec<CapabilityObservation>> {
        let mut routes = HashMap::<ModelRouteId, (ModelRoute, ProviderTemplate)>::new();
        for observation in &observations {
            if observation.source != expected_source {
                return Err(CoreError::invalid(
                    "capability observation source does not match the ingestion path",
                ));
            }
            let (route, template) = if let Some(route) = routes.get(&observation.model_route_id) {
                route
            } else {
                let route = self
                    .inner
                    .storage
                    .get_model_route(&observation.model_route_id)?;
                let connection = self
                    .inner
                    .storage
                    .get_provider_connection(&route.connection_id)?;
                let template = self
                    .inner
                    .storage
                    .get_provider_template(&connection.template_id, connection.template_version)?;
                routes.insert(observation.model_route_id.clone(), (route, template));
                routes
                    .get(&observation.model_route_id)
                    .expect("inserted capability route")
            };
            validate_capability_wire_metadata(route, template, observation)?;
        }
        self.inner
            .storage
            .upsert_capability_observations(&observations)?;
        Ok(observations)
    }

    pub fn list_generation_presets(
        &self,
        model_route_id: &ModelRouteId,
    ) -> CoreResult<Vec<GenerationPreset>> {
        self.inner.storage.list_generation_presets(model_route_id)
    }

    pub fn upsert_generation_preset(
        &self,
        preset: GenerationPreset,
    ) -> CoreResult<GenerationPreset> {
        self.validate_generation_preset_candidate(&preset)?;
        self.inner.storage.save_generation_preset(&preset)?;
        Ok(preset)
    }

    pub fn delete_generation_preset(&self, id: &GenerationPresetId) -> CoreResult<()> {
        self.inner.storage.delete_generation_preset(id)
    }

    /// Validates an unsaved preset candidate against the effective route
    /// catalog and capability dialects. Callers may safely use this before
    /// save; [`Self::upsert_generation_preset`] always applies the same gate.
    pub fn validate_generation_preset_candidate(
        &self,
        preset: &GenerationPreset,
    ) -> CoreResult<()> {
        validate_generation_preset_candidate_plan(self, preset).map(|_| ())
    }

    /// Returns the render-ready, model-specific reasoning controls for a
    /// stored or unsaved preset candidate. Native UI must not reconstruct
    /// these rules from an API-family name.
    pub fn render_reasoning_control_for_preset(
        &self,
        preset: &GenerationPreset,
    ) -> CoreResult<ReasoningControlModel> {
        let context = generation_preset_control_context(self, preset)?;
        let mut reasoning = context.reasoning;
        if context.connection.credential_ref.is_some()
            || !AdapterRegistry::template_supports_opaque_reasoning_state(&context.template)
        {
            reasoning.preserve_opaque_state = false;
        }
        Ok(render_reasoning_control(
            context.route.api_family,
            &context.reasoning_dialect,
            &reasoning,
        ))
    }

    /// Returns the render-ready, model-specific prompt-cache controls for a
    /// stored or unsaved preset candidate.
    pub fn render_prompt_cache_control_for_preset(
        &self,
        preset: &GenerationPreset,
    ) -> CoreResult<PromptCacheControlModel> {
        let context = generation_preset_control_context(self, preset)?;
        Ok(render_prompt_cache_control(
            context.route.api_family,
            context.cache_dialect,
            &context.prompt_cache,
        ))
    }

    /// Previews an unsaved preset through the same validation and adapter
    /// contract used by save and generation.
    pub fn preview_provider_request_candidate(
        &self,
        preset: &GenerationPreset,
    ) -> CoreResult<RequestPreview> {
        let validated = validate_generation_preset_candidate_plan(self, preset)?;
        AdapterRegistry::new().preview_provider_request(
            &validated.template,
            &validated.connection,
            &validated.route,
            Some(&validated.request_plan),
        )
    }

    /// Validates the same stored route/preset pair and family-specific request
    /// plan that generation will use, without constructing a provider or
    /// performing network work.
    pub fn validate_generation_preset(
        &self,
        model_route_id: &ModelRouteId,
        generation_preset_id: &GenerationPresetId,
    ) -> CoreResult<()> {
        validate_generation_target_plan(
            self,
            &GenerationTarget {
                model_route_id: model_route_id.clone(),
                generation_preset_id: generation_preset_id.clone(),
            },
        )
        .map(|_| ())
    }

    /// Returns a scalar-free, credential-free preview produced by the same
    /// family adapter and validated request plan used for generation.
    pub fn preview_provider_request(
        &self,
        model_route_id: &ModelRouteId,
        generation_preset_id: &GenerationPresetId,
    ) -> CoreResult<RequestPreview> {
        let validated = validate_generation_target_plan(
            self,
            &GenerationTarget {
                model_route_id: model_route_id.clone(),
                generation_preset_id: generation_preset_id.clone(),
            },
        )?;
        AdapterRegistry::new().preview_provider_request(
            &validated.template,
            &validated.connection,
            &validated.route,
            Some(&validated.request_plan),
        )
    }

    pub fn select_generation_target(
        &self,
        target: Option<GenerationTarget>,
    ) -> CoreResult<AppSettings> {
        let mut settings = self.inner.storage.load_settings()?;
        if let Some(target) = target {
            validate_generation_target_plan(self, &target)?;
            settings.selected_model_route_id = Some(target.model_route_id);
            settings.selected_generation_preset_id = Some(target.generation_preset_id);
            settings.selected_provider_profile_id = None;
        } else {
            settings.selected_model_route_id = None;
            settings.selected_generation_preset_id = None;
            settings.selected_provider_profile_id = None;
        }
        self.inner.storage.save_settings(&settings)?;
        Ok(settings)
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
        match self.inner.storage.get_provider_profile(&profile.id) {
            Ok(existing) if existing.base_url != profile.base_url => {
                return Err(CoreError::invalid(
                    "provider endpoint configuration is immutable; create a new provider connection instead",
                ));
            }
            Ok(_) => {}
            Err(error) if error.code == CoreErrorCode::NotFound => {}
            Err(error) => return Err(error),
        }
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
        self.send_message_to_branch_with_provider_options(
            conversation_id,
            branch_id,
            expected_head,
            mode,
            text,
            model,
            None,
            None,
            false,
            Some(1.0),
            Some(CORE_MAX_OUTPUT_TOKENS),
            credential,
            provider,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn send_message_to_branch_with_provider_options(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        mode: ConversationMode,
        text: &str,
        model: String,
        generation_target: Option<&GenerationTarget>,
        provider_family: Option<ApiFamily>,
        preserve_opaque_reasoning_state: bool,
        temperature: Option<f64>,
        max_output_tokens: Option<u32>,
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
        let mut request = PromptPlanner::plan_with_mode(
            &character,
            conversation_id.clone(),
            mode,
            &history,
            model.clone(),
            temperature.unwrap_or(1.0),
            max_output_tokens,
        )?;
        if temperature.is_none() {
            request.temperature = None;
        }
        let preserve_opaque_reasoning_state =
            preserve_opaque_reasoning_state && credential.as_deref().is_none_or(str::is_empty);
        configure_generation_protocol_request(
            &self.inner.storage,
            &mut request,
            generation_target,
            provider_family,
            preserve_opaque_reasoning_state,
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
            model_route_id: generation_target.map(|target| target.model_route_id.clone()),
            generation_preset_id: generation_target
                .map(|target| target.generation_preset_id.clone()),
            provider_family,
            status: GenerationStatus::Running,
            input_tokens: None,
            cached_read_tokens: None,
            cached_write_tokens: None,
            output_tokens: None,
            reasoning_tokens: None,
            tool_tokens: None,
            provider_raw_summary: None,
            opaque_reasoning_state: Vec::new(),
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
        self.start_message_generation_action_with_provider_options(
            conversation_id,
            branch_id,
            expected_head,
            message_id,
            action,
            replacement_text,
            model,
            None,
            None,
            false,
            Some(1.0),
            Some(CORE_MAX_OUTPUT_TOKENS),
            credential,
            provider,
        )
    }

    #[allow(
        clippy::too_many_arguments,
        clippy::too_many_lines,
        reason = "the atomic branch action keeps request planning and durable append in one boundary"
    )]
    fn start_message_generation_action_with_provider_options(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        message_id: &MessageId,
        action: MessageGenerationAction,
        replacement_text: Option<&str>,
        model: String,
        generation_target: Option<&GenerationTarget>,
        provider_family: Option<ApiFamily>,
        preserve_opaque_reasoning_state: bool,
        temperature: Option<f64>,
        max_output_tokens: Option<u32>,
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
        let mut request = PromptPlanner::plan_with_mode(
            &character,
            conversation_id.clone(),
            state.selected_mode,
            &history,
            model.clone(),
            temperature.unwrap_or(1.0),
            max_output_tokens,
        )?;
        if temperature.is_none() {
            request.temperature = None;
        }
        let preserve_opaque_reasoning_state =
            preserve_opaque_reasoning_state && credential.as_deref().is_none_or(str::is_empty);
        configure_generation_protocol_request(
            &self.inner.storage,
            &mut request,
            generation_target,
            provider_family,
            preserve_opaque_reasoning_state,
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
            model_route_id: generation_target.map(|target| target.model_route_id.clone()),
            generation_preset_id: generation_target
                .map(|target| target.generation_preset_id.clone()),
            provider_family,
            status: GenerationStatus::Running,
            input_tokens: None,
            cached_read_tokens: None,
            cached_write_tokens: None,
            output_tokens: None,
            reasoning_tokens: None,
            tool_tokens: None,
            provider_raw_summary: None,
            opaque_reasoning_state: Vec::new(),
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

fn configure_generation_protocol_request(
    storage: &Storage,
    request: &mut GenerationRequest,
    generation_target: Option<&GenerationTarget>,
    provider_family: Option<ApiFamily>,
    mut preserve_opaque_reasoning_state: bool,
) -> CoreResult<()> {
    if preserve_opaque_reasoning_state && let Some(target) = generation_target {
        let route = storage.get_model_route(&target.model_route_id)?;
        let connection = storage.get_provider_connection(&route.connection_id)?;
        if connection.credential_ref.is_some() {
            preserve_opaque_reasoning_state = false;
        }
    }
    let (generation_target, provider_family) = match (generation_target, provider_family) {
        (None, None) if !preserve_opaque_reasoning_state => {
            request.provider_provenance = None;
            request.preserve_opaque_reasoning_state = false;
            request.opaque_reasoning_context.clear();
            return Ok(());
        }
        (Some(target), Some(family)) => (target, family),
        _ => {
            return Err(CoreError::internal(
                "generation provider protocol provenance is inconsistent",
            ));
        }
    };

    let opaque_reasoning_context = if preserve_opaque_reasoning_state {
        load_opaque_reasoning_context(
            storage,
            &request.messages,
            provider_family,
            &request.model,
            generation_target,
        )?
    } else {
        Vec::new()
    };
    request.provider_provenance = Some(GenerationProviderProvenance {
        api_family: provider_family,
        model_route_id: generation_target.model_route_id.clone(),
        generation_preset_id: generation_target.generation_preset_id.clone(),
    });
    request.preserve_opaque_reasoning_state = preserve_opaque_reasoning_state;
    request.opaque_reasoning_context = opaque_reasoning_context;
    Ok(())
}

fn load_opaque_reasoning_context(
    storage: &Storage,
    history: &[Message],
    provider_family: ApiFamily,
    model: &str,
    generation_target: &GenerationTarget,
) -> CoreResult<Vec<OpaqueReasoningContext>> {
    let mut contexts = Vec::new();
    let mut states = Vec::<OpaqueReasoningState>::new();
    for message in history {
        if message.role != MessageRole::Assistant || message.status != MessageStatus::Complete {
            continue;
        }
        let Some(generation_id) = message.generation_id.as_ref() else {
            continue;
        };
        let generation = storage.get_generation(generation_id).map_err(|error| {
            if error.code == CoreErrorCode::NotFound {
                CoreError::new(
                    CoreErrorCode::StorageCorrupted,
                    "assistant message references a missing generation",
                    false,
                )
            } else {
                error
            }
        })?;
        if generation.opaque_reasoning_state.is_empty() {
            continue;
        }
        if generation.status != GenerationStatus::Complete
            || generation.conversation_id != message.conversation_id
            || generation.assistant_message_id.as_ref() != Some(&message.id)
        {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "stored opaque reasoning state has inconsistent message ownership",
                false,
            ));
        }
        if generation.provider_family != Some(provider_family)
            || generation.model != model
            || generation.model_route_id.as_ref() != Some(&generation_target.model_route_id)
        {
            continue;
        }
        let generation_preset_id = generation.generation_preset_id.ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "stored opaque reasoning state is missing preset provenance",
                false,
            )
        })?;
        for state in generation.opaque_reasoning_state {
            states.push(state.clone());
            contexts.push(OpaqueReasoningContext {
                source_message_id: message.id.clone(),
                api_family: provider_family,
                model: model.to_owned(),
                model_route_id: generation_target.model_route_id.clone(),
                generation_preset_id: generation_preset_id.clone(),
                state,
            });
        }
    }
    validate_opaque_reasoning_states(&states).map_err(CoreError::invalid)?;
    Ok(contexts)
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
    let opaque_reasoning_state = result
        .as_ref()
        .ok()
        .map(|outcome| outcome.opaque_reasoning_state.clone())
        .unwrap_or_default();
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
        &opaque_reasoning_state,
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

#[allow(
    clippy::too_many_arguments,
    reason = "terminal persistence keeps the complete transaction and compensation inputs explicit"
)]
fn persist_generation_terminal(
    context: TerminalPersistenceContext<'_>,
    assistant: &mut Message,
    usage: Option<&lorepia_domain::GenerationUsage>,
    opaque_reasoning_state: &[OpaqueReasoningState],
    error_code: Option<&str>,
    should_commit: bool,
    mut sequence: u64,
    mut terminal_kind: ChatEventKind,
) -> (u64, ChatEventKind) {
    let original_status = assistant.status;
    let persistence = context.storage.finalize_generation_with_protocol_state(
        assistant,
        usage,
        opaque_reasoning_state,
        error_code,
        should_commit,
    );
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

pub(crate) type ReconciledModelRoutes = (Vec<ModelRoute>, Vec<ModelRouteId>, Vec<ModelRouteId>);

pub(crate) fn provider_api_capability_observations(
    routes: &[ModelRoute],
    listed_models: &[ListedModel],
    observed_at: DateTime<Utc>,
) -> CoreResult<Vec<CapabilityObservation>> {
    let routes_by_model = routes
        .iter()
        .map(|route| (route.model_id.as_str(), route))
        .collect::<HashMap<_, _>>();
    let expires_at = observed_at.checked_add_signed(PROVIDER_API_CAPABILITY_FRESHNESS);
    let mut observations = Vec::new();
    for model in listed_models {
        let route = routes_by_model
            .get(model.model_id.as_str())
            .ok_or_else(|| {
                CoreError::internal("reconciled model route is missing from capability ingestion")
            })?;
        for (key, value) in [
            (CapabilityKey::ContextWindow, model.max_input_tokens),
            (CapabilityKey::MaxOutputTokens, model.max_output_tokens),
        ] {
            let Some(value) = value else {
                continue;
            };
            if value == 0 {
                return Err(CoreError::new(
                    CoreErrorCode::ProviderUnavailable,
                    "provider model metadata contains a zero token limit",
                    false,
                ));
            }
            observations.push(CapabilityObservation {
                id: deterministic_capability_observation_id(
                    &route.id,
                    key,
                    ObservationSource::ProviderApi,
                ),
                model_route_id: route.id.clone(),
                key,
                value: CapabilityValue::Integer(value),
                status: SupportStatus::Verified,
                source: ObservationSource::ProviderApi,
                confidence: Confidence::High,
                observed_at,
                expires_at,
                evidence_ref: None,
            });
        }
        append_listed_model_capability_observations(
            model,
            &route.id,
            observed_at,
            expires_at,
            &mut observations,
        )?;
    }
    observations.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(observations)
}

fn append_listed_model_capability_observations(
    model: &ListedModel,
    route_id: &ModelRouteId,
    observed_at: DateTime<Utc>,
    expires_at: Option<DateTime<Utc>>,
    observations: &mut Vec<CapabilityObservation>,
) -> CoreResult<()> {
    let mut supported = model.capabilities.supported.clone();
    supported.sort();
    supported.dedup();
    let authoritative = matches!(
        model.capabilities.parameters,
        OpenRouterSupportedParameterSupport::Exact(_)
    );
    let capabilities = if authoritative {
        vec![
            ListedModelCapability::Reasoning,
            ListedModelCapability::ToolCalling,
            ListedModelCapability::ParallelToolCalling,
            ListedModelCapability::StructuredOutput,
            ListedModelCapability::JsonMode,
            ListedModelCapability::Logprobs,
            ListedModelCapability::Seed,
        ]
    } else {
        supported.clone()
    };
    for capability in capabilities {
        let key = match capability {
            ListedModelCapability::Reasoning => CapabilityKey::Reasoning,
            ListedModelCapability::ToolCalling => CapabilityKey::ToolCalling,
            ListedModelCapability::ParallelToolCalling => CapabilityKey::ParallelToolCalling,
            ListedModelCapability::StructuredOutput => CapabilityKey::StructuredOutput,
            ListedModelCapability::JsonMode => CapabilityKey::JsonMode,
            ListedModelCapability::Logprobs => CapabilityKey::Logprobs,
            ListedModelCapability::Seed => CapabilityKey::Seed,
        };
        let is_supported = supported.contains(&capability);
        let value = if !is_supported {
            CapabilityValue::Boolean(false)
        } else if capability == ListedModelCapability::Reasoning {
            openrouter_reasoning_capability_value(model)?
        } else {
            CapabilityValue::Boolean(true)
        };
        observations.push(CapabilityObservation {
            id: deterministic_capability_observation_id(
                route_id,
                key,
                ObservationSource::ProviderApi,
            ),
            model_route_id: route_id.clone(),
            key,
            value,
            status: if is_supported {
                SupportStatus::Verified
            } else {
                SupportStatus::Unsupported
            },
            source: ObservationSource::ProviderApi,
            confidence: Confidence::High,
            observed_at,
            expires_at,
            evidence_ref: None,
        });
    }
    Ok(())
}

fn openrouter_reasoning_capability_value(model: &ListedModel) -> CoreResult<CapabilityValue> {
    let Some(dialect) = openrouter_reasoning_dialect_from_capabilities(&model.capabilities) else {
        return Ok(CapabilityValue::Boolean(true));
    };
    serialize_reasoning_capability(dialect)
}

fn openrouter_reasoning_dialect_from_capabilities(
    capabilities: &ListedModelCapabilities,
) -> Option<ReasoningWireDialect> {
    let parameters = match &capabilities.parameters {
        OpenRouterSupportedParameterSupport::Exact(parameters) => parameters,
        OpenRouterSupportedParameterSupport::NotExposed => return None,
    };
    if parameters.contains(&OpenRouterSupportedParameter::Reasoning) {
        let reasoning = capabilities
            .reasoning
            .clone()
            .unwrap_or(ListedModelReasoningCapability {
                supported_efforts: OpenRouterReasoningEffortSupport::NotExposed,
                default_effort: None,
                default_enabled: None,
                supports_max_tokens: None,
                mandatory: None,
            });
        return Some(ReasoningWireDialect::OpenRouter {
            style: OpenRouterReasoningWireStyle::Unified,
            supported_efforts: reasoning.supported_efforts,
            default_effort: reasoning.default_effort,
            default_enabled: reasoning.default_enabled,
            supports_max_tokens: reasoning.supports_max_tokens,
            mandatory: reasoning.mandatory,
        });
    }
    if !parameters.contains(&OpenRouterSupportedParameter::ReasoningEffort) {
        return None;
    }
    let reasoning = capabilities.reasoning.as_ref()?;
    if matches!(
        reasoning.supported_efforts,
        OpenRouterReasoningEffortSupport::NotExposed
    ) || matches!(
        &reasoning.supported_efforts,
        OpenRouterReasoningEffortSupport::Exact(efforts) if efforts.is_empty()
    ) {
        return None;
    }
    Some(ReasoningWireDialect::OpenRouter {
        style: OpenRouterReasoningWireStyle::LegacyReasoningEffort,
        supported_efforts: reasoning.supported_efforts.clone(),
        default_effort: reasoning.default_effort,
        default_enabled: reasoning.default_enabled,
        supports_max_tokens: reasoning.supports_max_tokens,
        mandatory: reasoning.mandatory,
    })
}

fn serialize_reasoning_capability(dialect: ReasoningWireDialect) -> CoreResult<CapabilityValue> {
    serde_json::to_value(dialect)
        .map(CapabilityValue::Structured)
        .map_err(|error| {
            CoreError::new(
                CoreErrorCode::ProviderUnavailable,
                format!("OpenRouter reasoning metadata could not be normalized: {error}"),
                false,
            )
        })
}

fn deterministic_capability_observation_id(
    model_route_id: &ModelRouteId,
    key: CapabilityKey,
    source: ObservationSource,
) -> ObservationId {
    let identity = format!(
        "lorepia:capability-observation:v1\u{0}{}\u{0}{}\u{0}{}",
        model_route_id.as_str(),
        capability_key_identity(key),
        observation_source_identity(source),
    );
    ObservationId::from(Uuid::new_v5(&Uuid::NAMESPACE_URL, identity.as_bytes()).to_string())
}

const fn capability_key_identity(key: CapabilityKey) -> &'static str {
    match key {
        CapabilityKey::Streaming => "streaming",
        CapabilityKey::Reasoning => "reasoning",
        CapabilityKey::PromptCaching => "prompt_caching",
        CapabilityKey::ToolCalling => "tool_calling",
        CapabilityKey::ParallelToolCalling => "parallel_tool_calling",
        CapabilityKey::StructuredOutput => "structured_output",
        CapabilityKey::JsonMode => "json_mode",
        CapabilityKey::ImageInput => "image_input",
        CapabilityKey::AudioInput => "audio_input",
        CapabilityKey::AudioOutput => "audio_output",
        CapabilityKey::Logprobs => "logprobs",
        CapabilityKey::Seed => "seed",
        CapabilityKey::Batch => "batch",
        CapabilityKey::Background => "background",
        CapabilityKey::ContextWindow => "context_window",
        CapabilityKey::MaxOutputTokens => "max_output_tokens",
    }
}

const fn observation_source_identity(source: ObservationSource) -> &'static str {
    match source {
        ObservationSource::ProviderApi => "provider_api",
        ObservationSource::OfficialDocumentation => "official_documentation",
        ObservationSource::SignedLorepiaCatalog => "signed_lorepia_catalog",
        ObservationSource::CapabilityProbe => "capability_probe",
        ObservationSource::UserOverride => "user_override",
        ObservationSource::LlmInference => "llm_inference",
    }
}

pub(crate) fn reconcile_input_routes(
    connection_id: &ProviderConnectionId,
    api_family: ApiFamily,
    existing_routes: &[ModelRoute],
    listed_models: &[ListedModel],
    observed_at: DateTime<Utc>,
) -> CoreResult<ReconciledModelRoutes> {
    let mut existing_by_identity = HashMap::with_capacity(existing_routes.len());
    let mut existing_by_id = HashMap::with_capacity(existing_routes.len());
    for route in existing_routes {
        let identity = (route.api_family, route.model_id.clone());
        if existing_by_identity.insert(identity, route).is_some() {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "provider connection contains duplicate model route identities",
                false,
            ));
        }
        existing_by_id.insert(route.id.clone(), route);
    }

    let mut routes = Vec::with_capacity(listed_models.len());
    let mut newly_seen = Vec::new();
    let mut listed_route_ids = HashSet::with_capacity(listed_models.len());
    for model in listed_models {
        if model.source != ModelRecordSource::ProviderApi {
            return Err(CoreError::new(
                CoreErrorCode::ProviderUnavailable,
                "provider model list contained unsupported provenance",
                false,
            ));
        }
        let identity = (api_family, model.model_id.clone());
        let existing = existing_by_identity.get(&identity).copied();
        let route_id = existing.map_or_else(
            || deterministic_model_route_id(connection_id, api_family, &model.model_id),
            |route| route.id.clone(),
        );
        if !listed_route_ids.insert(route_id.clone()) {
            return Err(CoreError::new(
                CoreErrorCode::ProviderUnavailable,
                "provider model list resolved to duplicate model routes",
                false,
            ));
        }
        if let Some(colliding) = existing_by_id.get(&route_id)
            && (colliding.api_family != api_family || colliding.model_id != model.model_id)
        {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "deterministic model route ID collides with different stored model data",
                false,
            ));
        }
        if existing.is_none() {
            newly_seen.push(route_id.clone());
        }
        routes.push(ModelRoute {
            id: route_id,
            connection_id: connection_id.clone(),
            api_family,
            model_id: model.model_id.clone(),
            // Provider listings cannot silently rename a stable local route.
            // A user-controlled catalog edit may still change this field.
            display_name: existing
                .and_then(|route| route.display_name.clone())
                .or_else(|| model.display_name.clone()),
            route_config: existing.map_or_else(ModelRouteConfig::default, |route| {
                route.route_config.clone()
            }),
            status: model.availability,
            miss_count: 0,
            raw_metadata: Some(listed_model_metadata(model)?),
            metadata_source: ModelMetadataSource::ProviderApi,
            metadata_observed_at: Some(observed_at),
            last_reconciled_sync_job_id: existing
                .and_then(|route| route.last_reconciled_sync_job_id.clone()),
            metadata_sync_job_id: existing.and_then(|route| route.metadata_sync_job_id.clone()),
            first_seen_at: existing.map_or(observed_at, |route| route.first_seen_at),
            last_seen_at: Some(observed_at),
        });
    }

    routes.sort_by(|left, right| {
        left.model_id
            .cmp(&right.model_id)
            .then_with(|| left.id.cmp(&right.id))
    });
    newly_seen.sort();
    let mut missing = existing_routes
        .iter()
        .filter(|route| !listed_route_ids.contains(&route.id))
        .map(|route| route.id.clone())
        .collect::<Vec<_>>();
    missing.sort();
    Ok((routes, newly_seen, missing))
}

fn listed_model_metadata(model: &ListedModel) -> CoreResult<BoundedJson> {
    let mut supported_generation_methods = model.supported_generation_methods.clone();
    supported_generation_methods.sort();
    supported_generation_methods.dedup();
    let mut capabilities = model.capabilities.clone();
    capabilities.supported.sort();
    capabilities.supported.dedup();
    BoundedJson::from_value(&serde_json::json!({
        "max_input_tokens": model.max_input_tokens,
        "max_output_tokens": model.max_output_tokens,
        "supported_generation_methods": supported_generation_methods,
        "capabilities": capabilities,
    }))
    .map_err(|error| {
        CoreError::new(
            CoreErrorCode::ProviderUnavailable,
            format!("provider model metadata could not be normalized: {error}"),
            false,
        )
    })
}

fn deterministic_model_route_id(
    connection_id: &ProviderConnectionId,
    api_family: ApiFamily,
    model_id: &str,
) -> ModelRouteId {
    let identity = format!(
        "lorepia:model-route:v1\u{0}{}\u{0}{}\u{0}{model_id}",
        connection_id.as_str(),
        api_family_wire_name(api_family),
    );
    ModelRouteId::from(Uuid::new_v5(&Uuid::NAMESPACE_URL, identity.as_bytes()).to_string())
}

fn deterministic_initial_preset_id(route_id: &ModelRouteId) -> GenerationPresetId {
    let identity = format!(
        "lorepia:initial-generation-preset:v1\u{0}{}",
        route_id.as_str()
    );
    GenerationPresetId::from(Uuid::new_v5(&Uuid::NAMESPACE_URL, identity.as_bytes()).to_string())
}

pub(crate) fn initial_generation_preset(
    route_id: &ModelRouteId,
    template: &ProviderTemplate,
    observed_at: DateTime<Utc>,
) -> GenerationPreset {
    let reasoning = lorepia_domain::GenerationReasoningSettings {
        preserve_opaque_state: AdapterRegistry::template_supports_opaque_reasoning_state(template),
        ..lorepia_domain::GenerationReasoningSettings::default()
    };
    GenerationPreset {
        id: deterministic_initial_preset_id(route_id),
        model_route_id: route_id.clone(),
        display_name: "Default".to_owned(),
        values: Vec::new(),
        reasoning,
        prompt_cache: lorepia_domain::GenerationPromptCacheSettings::default(),
        created_at: observed_at,
        updated_at: observed_at,
    }
}

pub(crate) fn template_accepts_empty_preset(template: &ProviderTemplate) -> CoreResult<bool> {
    let parameter_engine =
        ParameterEngine::from_manifest_specs(&template.default_manifest.parameters).map_err(
            |error| CoreError::invalid(format!("provider parameter manifest is invalid: {error}")),
        )?;
    Ok(parameter_engine.validate_for_request(&[]).is_ok())
}

fn ensure_model_list_does_not_reflect_credential(
    result: &ModelListResult,
    credential: Option<&str>,
) -> CoreResult<()> {
    let Some(credential) = credential.filter(|value| !value.is_empty()) else {
        return Ok(());
    };
    let reflected = result.models.iter().any(|model| {
        model.model_id.contains(credential)
            || model
                .display_name
                .as_deref()
                .is_some_and(|value| value.contains(credential))
            || model
                .supported_generation_methods
                .iter()
                .any(|value| value.contains(credential))
            || serde_json::to_string(&model.capabilities)
                .is_ok_and(|value| value.contains(credential))
    });
    if reflected {
        return Err(CoreError::new(
            CoreErrorCode::ProviderUnavailable,
            "provider model list reflected credential material",
            false,
        ));
    }
    Ok(())
}

fn record_model_refresh_failure(
    storage: &Storage,
    attempted_connection: &ProviderConnection,
    error: &CoreError,
) -> CoreResult<()> {
    let status = match error.code {
        CoreErrorCode::ProviderAuthFailed => ConnectionStatus::AuthFailed,
        CoreErrorCode::ProviderRateLimited
        | CoreErrorCode::ProviderUnavailable
        | CoreErrorCode::NetworkUnavailable => ConnectionStatus::Unavailable,
        _ => return Ok(()),
    };
    let mut current = storage.get_provider_connection(&attempted_connection.id)?;
    if current != *attempted_connection {
        return Ok(());
    }
    current.status = status;
    current.updated_at = Utc::now();
    storage.save_provider_connection(&current)
}

const fn model_record_source_name(source: ModelRecordSource) -> &'static str {
    match source {
        ModelRecordSource::ProviderApi => "provider_api",
    }
}

const fn api_family_wire_name(family: ApiFamily) -> &'static str {
    match family {
        ApiFamily::OpenAiResponses => "openai_responses",
        ApiFamily::OpenAiChatCompletions => "openai_chat_completions",
        ApiFamily::AnthropicMessages => "anthropic_messages",
        ApiFamily::GeminiGenerateContent => "gemini_generate_content",
        ApiFamily::OllamaNative => "ollama_native",
    }
}

fn validate_provider_template(template: &ProviderTemplate) -> CoreResult<()> {
    if template.manifest_version == 0 {
        return Err(CoreError::invalid(
            "provider template version must be positive",
        ));
    }
    if template.api_family != template.default_manifest.api_family {
        return Err(CoreError::invalid(
            "provider template API family does not match its manifest",
        ));
    }
    validate_connection_fields(&template.connection_fields)?;
    validate_manifest(&template.default_manifest)?;
    Ok(())
}

fn validate_generation_route(
    storage: &Storage,
    model_route_id: &ModelRouteId,
) -> CoreResult<(ModelRoute, ProviderConnection, ProviderTemplate)> {
    let route = storage.get_model_route(model_route_id)?;
    if matches!(
        route.status,
        ModelAvailability::MissingTemporarily
            | ModelAvailability::AccessDenied
            | ModelAvailability::Deprecated
            | ModelAvailability::Retired
    ) {
        return Err(CoreError::invalid(
            "selected model route is not currently available for generation",
        ));
    }
    let connection = storage.get_provider_connection(&route.connection_id)?;
    let template =
        storage.get_provider_template(&connection.template_id, connection.template_version)?;
    validate_provider_template(&template)?;
    if route.api_family != template.api_family {
        return Err(CoreError::invalid(
            "model route API family does not match its provider template",
        ));
    }
    Ok((route, connection, template))
}

fn effective_capability_at(
    storage: &Storage,
    catalog_observations: &[CapabilityObservation],
    model_route_id: &ModelRouteId,
    key: CapabilityKey,
    now: DateTime<Utc>,
) -> CoreResult<Option<EffectiveCapability>> {
    let mut observations = storage
        .list_capability_observations_for_key(model_route_id, key)?
        .into_iter()
        .filter(|observation| observation.source != ObservationSource::SignedLorepiaCatalog)
        .map(|observation| (observation.id.clone(), observation))
        .collect::<HashMap<_, _>>();
    for observation in catalog_observations.iter().filter(|observation| {
        observation.model_route_id == *model_route_id && observation.key == key
    }) {
        observations.insert(observation.id.clone(), observation.clone());
    }
    let observations = observations.into_values().collect::<Vec<_>>();
    if observations.is_empty() {
        return Ok(None);
    }
    let merged = merge_capability_observations(&observations, now)?;
    Ok(Some(EffectiveCapability {
        selected: merged.selected().clone(),
        alternatives: merged.alternatives().to_vec(),
        evaluated_at: now,
        selected_is_stale: merged.selected_is_stale(),
        has_conflict: merged.has_conflict(),
    }))
}

fn validate_capability_wire_metadata(
    route: &ModelRoute,
    template: &ProviderTemplate,
    observation: &CapabilityObservation,
) -> CoreResult<()> {
    let CapabilityValue::Structured(value) = &observation.value else {
        return Ok(());
    };
    match observation.key {
        CapabilityKey::Reasoning => {
            let dialect = parse_reasoning_wire_dialect_metadata(route.api_family, value).map_err(
                |error| {
                    CoreError::invalid(format!(
                        "reasoning capability metadata is invalid for this model route: {error}"
                    ))
                },
            )?;
            if matches!(dialect, ReasoningWireDialect::OpenRouter { .. })
                && !is_exact_built_in_openrouter_template(template)?
            {
                return Err(CoreError::invalid(
                    "OpenRouter reasoning metadata requires the exact built-in OpenRouter template",
                ));
            }
            if dialect == ReasoningWireDialect::Unsupported
                && matches!(
                    observation.status,
                    SupportStatus::Verified | SupportStatus::Documented
                )
            {
                return Err(CoreError::invalid(
                    "a supported reasoning observation requires a concrete wire dialect",
                ));
            }
        }
        CapabilityKey::PromptCaching => {
            let dialect = parse_prompt_cache_wire_dialect_metadata(route.api_family, value)
                .map_err(|error| {
                    CoreError::invalid(format!(
                        "prompt-cache capability metadata is invalid for this model route: {error}"
                    ))
                })?;
            if dialect == PromptCacheWireDialect::Unsupported
                && matches!(
                    observation.status,
                    SupportStatus::Verified | SupportStatus::Documented
                )
            {
                return Err(CoreError::invalid(
                    "a supported prompt-cache observation requires a concrete wire dialect",
                ));
            }
        }
        _ => {}
    }
    Ok(())
}

fn observation_can_drive_wire_mapping(effective: &EffectiveCapability) -> bool {
    !effective.selected_is_stale
        && !effective.has_conflict
        && effective.selected.confidence != Confidence::Low
        && effective.selected.source != ObservationSource::LlmInference
        && matches!(
            effective.selected.status,
            SupportStatus::Verified | SupportStatus::Documented
        )
}

fn effective_reasoning_dialect(
    family: ApiFamily,
    effective: Option<&EffectiveCapability>,
) -> ReasoningWireDialect {
    let Some(effective) = effective.filter(|value| observation_can_drive_wire_mapping(value))
    else {
        return ReasoningWireDialect::Unsupported;
    };
    let CapabilityValue::Structured(value) = &effective.selected.value else {
        return ReasoningWireDialect::Unsupported;
    };
    parse_reasoning_wire_dialect_metadata(family, value)
        .ok()
        .filter(|dialect| *dialect != ReasoningWireDialect::Unsupported)
        .unwrap_or(ReasoningWireDialect::Unsupported)
}

fn effective_prompt_cache_dialect(
    family: ApiFamily,
    effective: Option<&EffectiveCapability>,
) -> PromptCacheWireDialect {
    let Some(effective) = effective.filter(|value| observation_can_drive_wire_mapping(value))
    else {
        return PromptCacheWireDialect::Unsupported;
    };
    let CapabilityValue::Structured(value) = &effective.selected.value else {
        return PromptCacheWireDialect::Unsupported;
    };
    parse_prompt_cache_wire_dialect_metadata(family, value)
        .ok()
        .filter(|dialect| *dialect != PromptCacheWireDialect::Unsupported)
        .unwrap_or(PromptCacheWireDialect::Unsupported)
}

fn is_exact_built_in_openrouter_template(template: &ProviderTemplate) -> CoreResult<bool> {
    let canonical = AdapterRegistry::built_in_template(BuiltInTemplateId::OpenRouter)?;
    Ok(template.source == TemplateSource::BuiltIn
        && template.id == canonical.id
        && template.manifest_version == canonical.manifest_version)
}

fn effective_route_parameter_specs(
    route: &ModelRoute,
    template: &ProviderTemplate,
    base_specs: &[ParameterSpec],
    signed_model_specs: &[ParameterSpec],
    evaluated_at: DateTime<Utc>,
) -> CoreResult<Vec<ParameterSpec>> {
    if !is_exact_built_in_openrouter_template(template)? {
        return Ok(base_specs.to_vec());
    }
    if route.status != ModelAvailability::Available {
        return Ok(Vec::new());
    }
    let Some(metadata) = fresh_openrouter_route_metadata(route, template, evaluated_at)? else {
        return Ok(openrouter_safe_signed_parameter_specs(signed_model_specs));
    };
    let OpenRouterSupportedParameterSupport::Exact(supported) = metadata.capabilities.parameters
    else {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "fresh OpenRouter provider metadata lacks exact supported parameters",
            false,
        ));
    };
    Ok(intersect_openrouter_parameter_specs(
        base_specs,
        &supported,
        metadata.max_output_tokens,
    ))
}

struct FreshOpenRouterRouteMetadata {
    capabilities: ListedModelCapabilities,
    max_output_tokens: Option<u64>,
    observed_at: DateTime<Utc>,
}

fn fresh_openrouter_route_metadata(
    route: &ModelRoute,
    template: &ProviderTemplate,
    evaluated_at: DateTime<Utc>,
) -> CoreResult<Option<FreshOpenRouterRouteMetadata>> {
    if !is_exact_built_in_openrouter_template(template)?
        || route.status != ModelAvailability::Available
        || route.metadata_source != ModelMetadataSource::ProviderApi
    {
        return Ok(None);
    }
    let Some(observed_at) = route.metadata_observed_at else {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "available ProviderApi route lacks a metadata observation time",
            false,
        ));
    };
    if observed_at > evaluated_at {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "provider model metadata has a future observation time",
            false,
        ));
    }
    match (
        route.last_reconciled_sync_job_id.as_ref(),
        route.metadata_sync_job_id.as_ref(),
    ) {
        (None, None) => {}
        (Some(reconciled), Some(metadata)) if reconciled == metadata => {}
        _ => {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "provider model metadata synchronization provenance is inconsistent",
                false,
            ));
        }
    }
    let Some(metadata) = route.raw_metadata.as_ref() else {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "available ProviderApi route lacks normalized model metadata",
            false,
        ));
    };
    validate_provider_api_route_metadata(Some(metadata)).map_err(|error| {
        CoreError::new(
            CoreErrorCode::StorageCorrupted,
            format!(
                "provider model metadata is not canonical: {}",
                error.message
            ),
            false,
        )
    })?;
    let value = serde_json::from_str::<serde_json::Value>(metadata.as_str()).map_err(|_| {
        CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "provider model metadata is invalid JSON",
            false,
        )
    })?;
    let capabilities = serde_json::from_value::<ListedModelCapabilities>(
        value.get("capabilities").cloned().ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "provider model metadata lacks capabilities",
                false,
            )
        })?,
    )
    .map_err(|_| {
        CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "provider model capability metadata is invalid",
            false,
        )
    })?;
    if !matches!(
        capabilities.parameters,
        OpenRouterSupportedParameterSupport::Exact(_)
    ) {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "ProviderApi OpenRouter route lacks exact supported parameters",
            false,
        ));
    }
    let max_output_tokens = value
        .get("max_output_tokens")
        .and_then(serde_json::Value::as_u64);
    if observed_at
        .checked_add_signed(PROVIDER_API_CAPABILITY_FRESHNESS)
        .is_none_or(|expires_at| expires_at <= evaluated_at)
    {
        return Ok(None);
    }
    Ok(Some(FreshOpenRouterRouteMetadata {
        capabilities,
        max_output_tokens,
        observed_at,
    }))
}

fn openrouter_safe_signed_parameter_specs(specs: &[ParameterSpec]) -> Vec<ParameterSpec> {
    let mut safe_specs = Vec::new();
    let mut output_spec = None::<ParameterSpec>;
    let mut output_uses_completion_alias = false;
    for spec in specs {
        if spec.provider_mapping.target != ProviderParameterTarget::RequestBody {
            continue;
        }
        match spec.provider_mapping.field_name.as_str() {
            "max_tokens" | "max_completion_tokens" => {
                let uses_completion_alias =
                    spec.provider_mapping.field_name == "max_completion_tokens";
                let replace = output_spec.as_ref().is_none_or(|current| {
                    (uses_completion_alias && !output_uses_completion_alias)
                        || (uses_completion_alias == output_uses_completion_alias
                            && current.id.as_str() != "max_output_tokens"
                            && spec.id.as_str() == "max_output_tokens")
                });
                if replace {
                    output_spec = Some(spec.clone());
                    output_uses_completion_alias = uses_completion_alias;
                }
            }
            "temperature" | "top_p" | "frequency_penalty" | "presence_penalty" | "stop"
            | "seed"
                if !safe_specs.iter().any(|existing: &ParameterSpec| {
                    existing.id == spec.id || existing.provider_mapping == spec.provider_mapping
                }) =>
            {
                safe_specs.push(spec.clone());
            }
            _ => {}
        }
    }
    if let Some(mut output) = output_spec {
        let safe_maximum = f64::from(u32::MAX);
        output.id = ParameterId::from("max_output_tokens");
        output.label_key.clear();
        output
            .label_key
            .push_str("provider.parameter.max_output_tokens");
        output.description_key =
            Some("provider.parameter.max_output_tokens.description".to_owned());
        let output_field = if output_uses_completion_alias {
            "max_completion_tokens"
        } else {
            "max_tokens"
        };
        output.provider_mapping.field_name.clear();
        output.provider_mapping.field_name.push_str(output_field);
        output.maximum = Some(
            output
                .maximum
                .map_or(safe_maximum, |maximum| maximum.min(safe_maximum)),
        );
        if output.minimum.is_none_or(|minimum| minimum <= safe_maximum) {
            safe_specs.push(output);
        }
    }
    safe_specs
}

fn intersect_openrouter_parameter_specs(
    base_specs: &[ParameterSpec],
    supported: &[OpenRouterSupportedParameter],
    max_output_tokens: Option<u64>,
) -> Vec<ParameterSpec> {
    let mut specs = Vec::new();
    for spec in base_specs
        .iter()
        .filter(|spec| {
            !matches!(
                spec.provider_mapping.field_name.as_str(),
                "max_tokens" | "max_completion_tokens"
            )
        })
        .filter_map(|spec| openrouter_supported_parameter_spec(spec, supported))
    {
        if let Some(existing) = specs.iter_mut().find(|existing: &&mut ParameterSpec| {
            existing.provider_mapping == spec.provider_mapping
        }) {
            if spec.id.as_str() == "max_output_tokens"
                && existing.id.as_str() != "max_output_tokens"
            {
                *existing = spec;
            }
        } else {
            specs.push(spec);
        }
    }
    if let Some(spec) =
        select_openrouter_output_token_spec(base_specs, supported, max_output_tokens)
    {
        specs.push(spec);
    }
    for spec in openrouter_compiled_parameter_specs(supported) {
        if !specs.iter().any(|existing| {
            existing.id == spec.id || existing.provider_mapping == spec.provider_mapping
        }) {
            specs.push(spec);
        }
    }
    specs
}

fn select_openrouter_output_token_spec(
    base_specs: &[ParameterSpec],
    supported: &[OpenRouterSupportedParameter],
    max_output_tokens: Option<u64>,
) -> Option<ParameterSpec> {
    let preferred_field = if supported.contains(&OpenRouterSupportedParameter::MaxCompletionTokens)
    {
        "max_completion_tokens"
    } else if supported.contains(&OpenRouterSupportedParameter::MaxTokens) {
        "max_tokens"
    } else {
        return None;
    };
    let candidates = base_specs.iter().filter(|spec| {
        spec.provider_mapping.target == ProviderParameterTarget::RequestBody
            && matches!(
                spec.provider_mapping.field_name.as_str(),
                "max_tokens" | "max_completion_tokens"
            )
    });
    let selected = candidates
        .clone()
        .filter(|spec| spec.provider_mapping.field_name == preferred_field)
        .min_by_key(|spec| spec.id.as_str() != "max_output_tokens")
        .or_else(|| candidates.min_by_key(|spec| spec.id.as_str() != "max_output_tokens"))?;
    openrouter_output_token_spec(selected, supported, max_output_tokens)
}

fn openrouter_supported_parameter_spec(
    spec: &ParameterSpec,
    supported: &[OpenRouterSupportedParameter],
) -> Option<ParameterSpec> {
    if spec.provider_mapping.target != ProviderParameterTarget::RequestBody {
        return None;
    }
    let field = spec.provider_mapping.field_name.as_str();
    let parameter = match field {
        "temperature" => OpenRouterSupportedParameter::Temperature,
        "top_p" => OpenRouterSupportedParameter::TopP,
        "frequency_penalty" => OpenRouterSupportedParameter::FrequencyPenalty,
        "presence_penalty" => OpenRouterSupportedParameter::PresencePenalty,
        "stop" => OpenRouterSupportedParameter::Stop,
        "seed" => OpenRouterSupportedParameter::Seed,
        _ => return None,
    };
    supported.contains(&parameter).then(|| spec.clone())
}

fn openrouter_output_token_spec(
    spec: &ParameterSpec,
    supported: &[OpenRouterSupportedParameter],
    max_output_tokens: Option<u64>,
) -> Option<ParameterSpec> {
    let supports_max_tokens = supported.contains(&OpenRouterSupportedParameter::MaxTokens);
    let supports_max_completion =
        supported.contains(&OpenRouterSupportedParameter::MaxCompletionTokens);
    let field = match (supports_max_tokens, supports_max_completion) {
        (_, true) => "max_completion_tokens",
        (true, false) => "max_tokens",
        (false, false) => return None,
    };
    let mut normalized = spec.clone();
    normalized.id = ParameterId::from("max_output_tokens");
    normalized.label_key.clear();
    normalized
        .label_key
        .push_str("provider.parameter.max_output_tokens");
    normalized.description_key =
        Some("provider.parameter.max_output_tokens.description".to_owned());
    normalized.provider_mapping.field_name.clear();
    normalized.provider_mapping.field_name.push_str(field);
    let provider_maximum = f64::from(
        max_output_tokens
            .and_then(|maximum| u32::try_from(maximum).ok())
            .unwrap_or(u32::MAX),
    );
    normalized.maximum = Some(
        normalized
            .maximum
            .map_or(provider_maximum, |maximum| maximum.min(provider_maximum)),
    );
    if normalized
        .minimum
        .is_some_and(|minimum| minimum > provider_maximum)
    {
        return None;
    }
    Some(normalized)
}

fn openrouter_compiled_parameter_specs(
    supported: &[OpenRouterSupportedParameter],
) -> Vec<ParameterSpec> {
    [
        (
            OpenRouterSupportedParameter::FrequencyPenalty,
            compiled_openrouter_parameter_spec(
                "frequency_penalty",
                "frequency_penalty",
                ParameterType::Number,
                Some(-2.0),
                Some(2.0),
                None,
                UiParameterLevel::Advanced,
            ),
        ),
        (
            OpenRouterSupportedParameter::PresencePenalty,
            compiled_openrouter_parameter_spec(
                "presence_penalty",
                "presence_penalty",
                ParameterType::Number,
                Some(-2.0),
                Some(2.0),
                None,
                UiParameterLevel::Advanced,
            ),
        ),
        (
            OpenRouterSupportedParameter::Stop,
            compiled_openrouter_parameter_spec(
                "stop",
                "stop",
                ParameterType::StopSequenceList,
                None,
                None,
                None,
                UiParameterLevel::Advanced,
            ),
        ),
        (
            OpenRouterSupportedParameter::Seed,
            compiled_openrouter_parameter_spec(
                "seed",
                "seed",
                ParameterType::Integer,
                None,
                None,
                Some(1.0),
                UiParameterLevel::Advanced,
            ),
        ),
    ]
    .into_iter()
    .filter_map(|(parameter, spec)| supported.contains(&parameter).then_some(spec))
    .collect()
}

#[allow(clippy::too_many_arguments)]
fn compiled_openrouter_parameter_spec(
    id: &str,
    field_name: &str,
    value_type: ParameterType,
    minimum: Option<f64>,
    maximum: Option<f64>,
    step: Option<f64>,
    level: UiParameterLevel,
) -> ParameterSpec {
    ParameterSpec {
        id: ParameterId::from(id),
        label_key: format!("provider.parameter.{id}"),
        description_key: Some(format!("provider.parameter.{id}.description")),
        value_type,
        allowed_values: Vec::new(),
        minimum,
        maximum,
        step,
        default_mode: ParameterDefaultMode::ProviderDefault,
        visibility: None,
        conflicts: Vec::new(),
        provider_mapping: ProviderParameterMapping {
            target: ProviderParameterTarget::RequestBody,
            field_name: field_name.to_owned(),
        },
        level,
    }
}

fn generation_preset_control_context(
    core: &Core,
    preset: &GenerationPreset,
) -> CoreResult<GenerationPresetControlContext> {
    let storage = &core.inner.storage;
    let (route, connection, template) = validate_generation_route(storage, &preset.model_route_id)?;
    let evaluated_at = Utc::now();
    let catalog = core
        .operational_provider_catalog_projection_at(evaluated_at)?
        .route_projection(&route, &connection.template_id);
    let base_parameter_specs = if catalog.matched {
        catalog.parameters.clone()
    } else {
        template.default_manifest.parameters.clone()
    };
    let parameter_specs = effective_route_parameter_specs(
        &route,
        &template,
        &base_parameter_specs,
        &catalog.signed_parameters,
        evaluated_at,
    )?;
    let parameter_engine =
        ParameterEngine::from_manifest_specs_for_family(route.api_family, &parameter_specs)
            .map_err(|error| {
                CoreError::invalid(format!(
                    "provider parameter manifest is invalid for this model route: {error}"
                ))
            })?;
    let reasoning = ReasoningSettings::from(&preset.reasoning);
    let prompt_cache = PromptCacheSettings::from(&preset.prompt_cache);
    let reasoning_capability = effective_capability_at(
        storage,
        &catalog.capability_observations,
        &route.id,
        CapabilityKey::Reasoning,
        evaluated_at,
    )?;
    let cache_capability = effective_capability_at(
        storage,
        &catalog.capability_observations,
        &route.id,
        CapabilityKey::PromptCaching,
        evaluated_at,
    )?;
    let mut reasoning_dialect =
        effective_reasoning_dialect(route.api_family, reasoning_capability.as_ref());
    if matches!(reasoning_dialect, ReasoningWireDialect::OpenRouter { .. }) {
        let exact_template = is_exact_built_in_openrouter_template(&template)?;
        let metadata_matches_route =
            fresh_openrouter_route_metadata(&route, &template, evaluated_at)?.is_some_and(
                |metadata| {
                    let observation_time_matches =
                        reasoning_capability.as_ref().is_some_and(|capability| {
                            capability.selected.source != ObservationSource::ProviderApi
                                || capability.selected.observed_at == metadata.observed_at
                        });
                    observation_time_matches
                        && openrouter_reasoning_dialect_from_capabilities(&metadata.capabilities)
                            .is_some_and(|dialect| dialect == reasoning_dialect)
                },
            );
        if !exact_template || !metadata_matches_route {
            reasoning_dialect = ReasoningWireDialect::Unsupported;
        }
    }
    let cache_dialect = effective_prompt_cache_dialect(route.api_family, cache_capability.as_ref());

    Ok(GenerationPresetControlContext {
        route,
        connection,
        template,
        parameter_engine,
        reasoning,
        prompt_cache,
        reasoning_dialect,
        cache_dialect,
    })
}

fn validate_generation_preset_candidate_plan(
    core: &Core,
    preset: &GenerationPreset,
) -> CoreResult<ValidatedGenerationTarget> {
    let context = generation_preset_control_context(core, preset)?;
    validate_opaque_reasoning_state_support(
        &context.template,
        &context.connection,
        &context.reasoning,
    )?;
    // A family name alone is not evidence that a particular model supports a
    // reasoning or cache control. Only a fresh, non-conflicting, sufficiently
    // confident observation with an exact structured dialect can enable those
    // controls. Provider-default remains the only lossless fallback.
    let request_plan = validate_and_build_provider_request_plan(
        &context.parameter_engine,
        context.route.api_family,
        &preset.values,
        &context.reasoning,
        &context.reasoning_dialect,
        &context.prompt_cache,
        context.cache_dialect,
    )
    .map_err(|error| {
        CoreError::invalid(format!(
            "generation preset cannot be represented by this model route: {error}"
        ))
    })?;

    Ok(ValidatedGenerationTarget {
        route: context.route,
        connection: context.connection,
        template: context.template,
        request_plan,
    })
}

fn validate_opaque_reasoning_state_support(
    template: &ProviderTemplate,
    connection: &ProviderConnection,
    reasoning: &ReasoningSettings,
) -> CoreResult<()> {
    if !reasoning.preserve_opaque_state {
        return Ok(());
    }
    if !AdapterRegistry::template_supports_opaque_reasoning_state(template) {
        let message = if template.api_family == ApiFamily::GeminiGenerateContent {
            GEMINI_OPAQUE_REASONING_TOPOLOGY_ERROR
        } else {
            OPAQUE_REASONING_STATE_UNSUPPORTED_ERROR
        };
        return Err(CoreError::invalid(message));
    }
    if connection.credential_ref.is_some() {
        return Err(CoreError::invalid(OPAQUE_REASONING_STATE_UNSUPPORTED_ERROR));
    }
    Ok(())
}

fn validate_generation_target_plan(
    core: &Core,
    target: &GenerationTarget,
) -> CoreResult<ValidatedGenerationTarget> {
    let mut preset = core
        .inner
        .storage
        .get_generation_preset(&target.generation_preset_id)?;
    if preset.model_route_id != target.model_route_id {
        return Err(CoreError::invalid(
            "generation preset does not belong to the selected model route",
        ));
    }
    let (_, connection, _) =
        validate_generation_route(&core.inner.storage, &preset.model_route_id)?;
    if connection.credential_ref.is_some() {
        preset.reasoning.preserve_opaque_state = false;
    }
    validate_generation_preset_candidate_plan(core, &preset)
}

pub(crate) fn resolve_generation_target(
    core: &Core,
    target: &GenerationTarget,
) -> CoreResult<ResolvedGenerationTarget> {
    let validated = validate_generation_target_plan(core, target)?;
    let preserve_opaque_reasoning_state = validated.connection.credential_ref.is_none()
        && validated.request_plan.preserves_opaque_reasoning_state();
    let provider = AdapterRegistry::new().build_provider_for_route_with_plan(
        &validated.template,
        &validated.connection,
        &validated.route,
        Some(validated.request_plan),
    )?;

    Ok(ResolvedGenerationTarget {
        model: validated.route.model_id,
        provider,
        api_family: validated.route.api_family,
        preserve_opaque_reasoning_state,
    })
}

fn validate_settings_generation_target(core: &Core, settings: &AppSettings) -> CoreResult<()> {
    match (
        settings.selected_model_route_id.as_ref(),
        settings.selected_generation_preset_id.as_ref(),
    ) {
        (None, None) => Ok(()),
        (Some(model_route_id), Some(generation_preset_id)) => {
            validate_generation_target_plan(
                core,
                &GenerationTarget {
                    model_route_id: model_route_id.clone(),
                    generation_preset_id: generation_preset_id.clone(),
                },
            )?;
            Ok(())
        }
        _ => Err(CoreError::invalid(
            "model route and generation preset must be selected together",
        )),
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
        io::{Read, Write},
        net::{IpAddr, TcpListener, TcpStream},
        sync::{Arc, Barrier, mpsc as std_mpsc},
        thread,
        time::{Duration, Instant},
    };

    use async_trait::async_trait;
    use lorepia_domain::{
        ConnectionConfigEntry, ConnectionConfigValue, GenerationPromptCacheMode,
        GenerationPromptCacheSettings, GenerationPromptCacheTtl, GenerationReasoningEffort,
        GenerationReasoningMode, GenerationReasoningSettings, GenerationReasoningSummary,
        GenerationUsage, ModelSyncState, OpenRouterReasoningDetail, OpenRouterReasoningTopology,
        ProviderCapabilities,
    };
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
        captured_temperature: Mutex<Option<std_mpsc::Sender<Option<f64>>>>,
    }

    type OpaqueRequestCapture = (
        bool,
        Vec<OpaqueReasoningContext>,
        Option<GenerationProviderProvenance>,
    );

    struct OpaqueContinuityProvider {
        response: String,
        emitted_state: Option<OpaqueReasoningState>,
        captured_request: Mutex<Option<std_mpsc::Sender<OpaqueRequestCapture>>>,
    }

    struct OverflowUsageProvider;

    fn read_http_headers(stream: &mut TcpStream) -> String {
        stream
            .set_read_timeout(Some(Duration::from_secs(2)))
            .expect("set model-list read timeout");
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4_096];
        loop {
            let read = stream.read(&mut buffer).expect("read model-list request");
            if read == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..read]);
            if request.windows(4).any(|window| window == b"\r\n\r\n") {
                break;
            }
        }
        String::from_utf8(request).expect("model-list request is UTF-8")
    }

    fn spawn_model_list_provider(
        response_bodies: Vec<String>,
    ) -> (CanonicalOrigin, std_mpsc::Receiver<String>) {
        spawn_model_list_http_provider(
            response_bodies
                .into_iter()
                .map(|body| ("200 OK".to_owned(), body))
                .collect(),
        )
    }

    fn spawn_model_list_http_provider(
        responses: Vec<(String, String)>,
    ) -> (CanonicalOrigin, std_mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind model-list provider");
        let address = listener.local_addr().expect("model-list provider address");
        let (request_sender, request_receiver) = std_mpsc::channel();
        thread::spawn(move || {
            for (status, body) in responses {
                let (mut stream, _) = listener.accept().expect("accept model-list request");
                let request = read_http_headers(&mut stream);
                request_sender
                    .send(request)
                    .expect("send captured model-list request");
                write!(
                    stream,
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                )
                .expect("write model-list response");
            }
        });
        (
            CanonicalOrigin::parse(&format!("http://{address}"))
                .expect("canonical model-list origin"),
            request_receiver,
        )
    }

    fn create_openai_chat_connection(
        core: &Core,
        api_origin: &CanonicalOrigin,
    ) -> (ProviderTemplate, ProviderConnection) {
        let template = core
            .list_provider_templates()
            .expect("provider templates")
            .into_iter()
            .find(|template| template.id.as_str() == "openai-chat-compatible-v1")
            .expect("OpenAI-compatible template");
        let api_base_url = format!("{}/v1", api_origin.as_str());
        let connection = core
            .create_provider_connection(ProviderConnectionDraft {
                id: ProviderConnectionId::from(format!("connection-{}", Uuid::new_v4())),
                template_id: template.id.clone(),
                template_version: template.manifest_version,
                display_name: "Synthetic OpenAI-compatible".to_owned(),
                api_origin: api_origin.clone(),
                api_base_path: Some(EndpointPath::parse("/v1").expect("API base path")),
                network_mode: ProviderNetworkMode::LocalLoopback,
                values: vec![ConnectionConfigEntry {
                    key: "api_base_url".to_owned(),
                    value: ConnectionConfigValue::Text(api_base_url),
                }],
                approved_credential_origin: Some(api_origin.clone()),
                local_network_approval: None,
                timeout_seconds: 5,
            })
            .expect("create model-list connection");
        (template, connection)
    }

    fn create_built_in_public_route(
        core: &Core,
        template_id: &str,
        api_base_path: &str,
        model_id: &str,
    ) -> (ProviderTemplate, ModelRoute) {
        let template = core
            .list_provider_templates()
            .expect("provider templates")
            .into_iter()
            .find(|template| template.id.as_str() == template_id)
            .expect("requested built-in template");
        let api_origin = template
            .default_manifest
            .default_api_origin
            .clone()
            .expect("built-in public origin");
        let connection = core
            .create_provider_connection(ProviderConnectionDraft {
                id: ProviderConnectionId::from(format!("connection-{}", Uuid::new_v4())),
                template_id: template.id.clone(),
                template_version: template.manifest_version,
                display_name: format!("Synthetic {template_id}"),
                api_origin: api_origin.clone(),
                api_base_path: Some(
                    EndpointPath::parse(api_base_path).expect("built-in API base path"),
                ),
                network_mode: ProviderNetworkMode::Public,
                values: Vec::new(),
                approved_credential_origin: Some(api_origin),
                local_network_approval: None,
                timeout_seconds: 5,
            })
            .expect("create built-in public connection");
        let now = Utc::now();
        let route = ModelRoute {
            id: ModelRouteId::from(format!("route-{}", Uuid::new_v4())),
            connection_id: connection.id,
            api_family: template.api_family,
            model_id: model_id.to_owned(),
            display_name: Some(model_id.to_owned()),
            route_config: ModelRouteConfig::default(),
            status: ModelAvailability::Available,
            miss_count: 0,
            raw_metadata: None,
            metadata_source: ModelMetadataSource::Legacy,
            metadata_observed_at: None,
            last_reconciled_sync_job_id: None,
            metadata_sync_job_id: None,
            first_seen_at: now,
            last_seen_at: Some(now),
        };
        core.upsert_model_route(route.clone())
            .expect("save built-in model route");
        (template, route)
    }

    fn listed_openrouter_model(
        model_id: &str,
        mut parameters: Vec<OpenRouterSupportedParameter>,
        reasoning: Option<ListedModelReasoningCapability>,
        max_output_tokens: Option<u64>,
    ) -> ListedModel {
        parameters.sort();
        parameters.dedup();
        let mut supported = Vec::new();
        if parameters.iter().any(|parameter| {
            matches!(
                parameter,
                OpenRouterSupportedParameter::Reasoning
                    | OpenRouterSupportedParameter::ReasoningEffort
            )
        }) {
            supported.push(ListedModelCapability::Reasoning);
        }
        if parameters.contains(&OpenRouterSupportedParameter::Tools) {
            supported.push(ListedModelCapability::ToolCalling);
        }
        if parameters.contains(&OpenRouterSupportedParameter::ParallelToolCalls) {
            supported.push(ListedModelCapability::ParallelToolCalling);
        }
        if parameters.contains(&OpenRouterSupportedParameter::StructuredOutputs) {
            supported.push(ListedModelCapability::StructuredOutput);
        }
        if parameters.contains(&OpenRouterSupportedParameter::ResponseFormat) {
            supported.push(ListedModelCapability::JsonMode);
        }
        if parameters.contains(&OpenRouterSupportedParameter::Logprobs) {
            supported.push(ListedModelCapability::Logprobs);
        }
        if parameters.contains(&OpenRouterSupportedParameter::Seed) {
            supported.push(ListedModelCapability::Seed);
        }
        supported.sort();
        ListedModel {
            model_id: model_id.to_owned(),
            display_name: Some(model_id.to_owned()),
            max_input_tokens: Some(128_000),
            max_output_tokens,
            supported_generation_methods: Vec::new(),
            capabilities: ListedModelCapabilities {
                supported,
                parameters: OpenRouterSupportedParameterSupport::Exact(parameters),
                reasoning,
            },
            source: ModelRecordSource::ProviderApi,
            availability: ModelAvailability::Available,
        }
    }

    fn provider_api_openrouter_route(
        connection_id: ProviderConnectionId,
        model: &ListedModel,
        observed_at: DateTime<Utc>,
    ) -> ModelRoute {
        ModelRoute {
            id: ModelRouteId::from(format!("route-{}", Uuid::new_v4())),
            connection_id,
            api_family: ApiFamily::OpenAiChatCompletions,
            model_id: model.model_id.clone(),
            display_name: model.display_name.clone(),
            route_config: ModelRouteConfig::default(),
            status: ModelAvailability::Available,
            miss_count: 0,
            raw_metadata: Some(listed_model_metadata(model).expect("listed model metadata")),
            metadata_source: ModelMetadataSource::ProviderApi,
            metadata_observed_at: Some(observed_at),
            last_reconciled_sync_job_id: None,
            metadata_sync_job_id: None,
            first_seen_at: observed_at,
            last_seen_at: Some(observed_at),
        }
    }

    fn refresh_models_with_review(
        core: &Core,
        connection_id: &ProviderConnectionId,
        credential: Option<&str>,
    ) -> CoreResult<ProviderModelRefreshResult> {
        let job_id =
            core.start_provider_model_sync(connection_id, credential.map(str::to_owned))?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let job = core.get_provider_model_sync(&job_id)?;
            match job.state {
                ModelSyncState::DiffReadyAwaitingReview => {
                    let review = job.review.ok_or_else(|| {
                        CoreError::internal("review-ready model sync has no review")
                    })?;
                    core.approve_provider_model_sync(&job_id, &review.sha256)?;
                    let diff = review.diff;
                    return Ok(ProviderModelRefreshResult {
                        connection_id: diff.connection_id.clone(),
                        model_routes: core.list_model_routes(&diff.connection_id)?,
                        newly_seen_model_route_ids: diff.newly_seen_model_route_ids,
                        missing_model_route_ids: diff.missing_model_route_ids,
                        created_generation_preset_ids: diff
                            .initial_presets
                            .into_iter()
                            .map(|preset| preset.id)
                            .collect(),
                        routes_requiring_preset_configuration: diff
                            .routes_requiring_preset_configuration,
                        provenance: ProviderModelRefreshProvenance {
                            source: diff.provenance.source,
                            api_family: diff.provenance.api_family,
                            api_origin: diff.provenance.api_origin,
                            endpoint_path: diff.provenance.endpoint_path,
                        },
                        pages_fetched: diff.provenance.pages_fetched,
                        response_bytes: diff.provenance.response_bytes,
                        observed_at: diff.observed_at,
                    });
                }
                ModelSyncState::Failed => {
                    let failure = job
                        .failure
                        .ok_or_else(|| CoreError::internal("failed model sync has no failure"))?;
                    let failure_code = match failure.code.as_str() {
                        "invalid_input" => CoreErrorCode::InvalidInput,
                        "unsupported_content" => CoreErrorCode::UnsupportedContent,
                        "unsafe_archive" => CoreErrorCode::UnsafeArchive,
                        "not_found" => CoreErrorCode::NotFound,
                        "permission_denied" => CoreErrorCode::PermissionDenied,
                        "storage_unavailable" => CoreErrorCode::StorageUnavailable,
                        "storage_corrupted" => CoreErrorCode::StorageCorrupted,
                        "provider_auth_failed" => CoreErrorCode::ProviderAuthFailed,
                        "provider_rate_limited" => CoreErrorCode::ProviderRateLimited,
                        "provider_unavailable" => CoreErrorCode::ProviderUnavailable,
                        "network_unavailable" => CoreErrorCode::NetworkUnavailable,
                        "cancelled" => CoreErrorCode::Cancelled,
                        _ => CoreErrorCode::Internal,
                    };
                    return Err(CoreError::new(
                        failure_code,
                        failure.message_key,
                        failure.recoverable,
                    ));
                }
                ModelSyncState::Cancelled => {
                    return Err(CoreError::new(
                        CoreErrorCode::Cancelled,
                        "model synchronization was cancelled",
                        true,
                    ));
                }
                ModelSyncState::Interrupted => {
                    return Err(CoreError::new(
                        CoreErrorCode::StorageUnavailable,
                        "model synchronization was interrupted",
                        true,
                    ));
                }
                ModelSyncState::Created
                | ModelSyncState::Fetching
                | ModelSyncState::Committing
                | ModelSyncState::Completed => {}
            }
            if Instant::now() >= deadline {
                return Err(CoreError::internal(
                    "model synchronization did not reach review state",
                ));
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn create_openai_chat_generation_target(
        core: &Core,
        api_origin: &CanonicalOrigin,
    ) -> (GenerationTarget, ModelRoute) {
        let (template, connection) = create_openai_chat_connection(core, api_origin);
        let now = Utc::now();
        let route = ModelRoute {
            id: ModelRouteId::from(format!("route-{}", Uuid::new_v4())),
            connection_id: connection.id,
            api_family: template.api_family,
            model_id: "reasoning-model".to_owned(),
            display_name: Some("Reasoning Model".to_owned()),
            route_config: ModelRouteConfig::default(),
            status: ModelAvailability::Available,
            miss_count: 0,
            raw_metadata: None,
            metadata_source: ModelMetadataSource::Legacy,
            metadata_observed_at: None,
            last_reconciled_sync_job_id: None,
            metadata_sync_job_id: None,
            first_seen_at: now,
            last_seen_at: Some(now),
        };
        core.upsert_model_route(route.clone())
            .expect("save model route");
        let preset = GenerationPreset {
            id: GenerationPresetId::from(format!("preset-{}", Uuid::new_v4())),
            model_route_id: route.id.clone(),
            display_name: "Reasoning and cache".to_owned(),
            values: Vec::new(),
            reasoning: GenerationReasoningSettings {
                mode: GenerationReasoningMode::Enabled,
                effort: Some(GenerationReasoningEffort::High),
                budget_tokens: None,
                summary: GenerationReasoningSummary::ProviderDefault,
                preserve_opaque_state: false,
            },
            prompt_cache: GenerationPromptCacheSettings {
                mode: GenerationPromptCacheMode::Automatic,
                ttl: GenerationPromptCacheTtl::ProviderDefault,
                context_reference: None,
            },
            created_at: now,
            updated_at: now,
        };
        // Seed a pre-gate stored candidate so the tests below can exercise
        // generation-time repair behavior. Public Core upserts now reject this
        // unsupported reasoning/cache combination before persistence.
        core.inner
            .storage
            .save_generation_preset(&preset)
            .expect("seed legacy generation preset");
        (
            GenerationTarget {
                model_route_id: route.id.clone(),
                generation_preset_id: preset.id,
            },
            route,
        )
    }

    #[test]
    fn provider_connection_update_cannot_rebind_endpoint_or_credential_identity() {
        let root = tempdir().expect("temporary core root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let (api_origin, _) = spawn_model_list_provider(Vec::new());
        let (template, connection) = create_openai_chat_connection(&core, &api_origin);

        let mut ordinary_update = connection.clone();
        ordinary_update.display_name = "Renamed connection".to_owned();
        ordinary_update.timeout_seconds = 9;
        ordinary_update.status = ConnectionStatus::Connected;
        ordinary_update.created_at -= chrono::Duration::days(1);
        let updated = core
            .upsert_provider_connection(ordinary_update)
            .expect("safe connection update");
        assert_eq!(updated.display_name, "Renamed connection");
        assert_eq!(updated.timeout_seconds, 9);
        assert_eq!(updated.status, connection.status);
        assert_eq!(updated.created_at, connection.created_at);

        let mut origin_rebind = updated.clone();
        origin_rebind.api_origin =
            CanonicalOrigin::parse("http://127.0.0.1:65534").expect("other loopback origin");
        let error = core
            .upsert_provider_connection(origin_rebind)
            .expect_err("origin rebinding must fail");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);

        let mut base_path_rebind = updated.clone();
        base_path_rebind.config.api_base_path =
            Some(EndpointPath::parse("/alternate-v1").expect("alternate base path"));
        let error = core
            .upsert_provider_connection(base_path_rebind)
            .expect_err("base-path rebinding must require a new connection");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert!(error.message.contains("endpoint configuration"));

        let mut value_rebind = updated.clone();
        value_rebind.config.values = vec![ConnectionConfigEntry {
            key: "api_base_url".to_owned(),
            value: ConnectionConfigValue::Text(format!("{}/alternate", api_origin.as_str())),
        }];
        let error = core
            .upsert_provider_connection(value_rebind)
            .expect_err("endpoint-affecting config values must require a new connection");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert!(error.message.contains("endpoint configuration"));

        let duplicate_create = core
            .create_provider_connection(ProviderConnectionDraft {
                id: updated.id.clone(),
                template_id: template.id,
                template_version: template.manifest_version,
                display_name: "Duplicate endpoint".to_owned(),
                api_origin: api_origin.clone(),
                api_base_path: Some(
                    EndpointPath::parse("/alternate-v1").expect("alternate base path"),
                ),
                network_mode: ProviderNetworkMode::LocalLoopback,
                values: vec![ConnectionConfigEntry {
                    key: "api_base_url".to_owned(),
                    value: ConnectionConfigValue::Text(format!(
                        "{}/alternate-v1",
                        api_origin.as_str()
                    )),
                }],
                approved_credential_origin: Some(api_origin),
                local_network_approval: None,
                timeout_seconds: 5,
            })
            .expect_err("create cannot be used as an endpoint-identity upsert");
        assert_eq!(duplicate_create.code, CoreErrorCode::InvalidInput);
        assert!(
            duplicate_create
                .message
                .contains("identifier already exists")
        );

        let mut credential_rebind = updated.clone();
        credential_rebind.credential_ref = Some(CredentialRef("another-secret".to_owned()));
        let error = core
            .upsert_provider_connection(credential_rebind)
            .expect_err("credential rebinding must fail");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);

        assert_eq!(
            core.inner
                .storage
                .get_provider_connection(&updated.id)
                .expect("unchanged provider identity")
                .config,
            updated.config
        );
    }

    #[test]
    fn legacy_provider_profile_keeps_endpoint_identity_but_can_select_a_new_model_route() {
        let root = tempdir().expect("temporary core root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let original = ProviderProfile {
            id: format!("legacy-{}", Uuid::new_v4()),
            display_name: "Legacy original".to_owned(),
            base_url: "http://127.0.0.1:65534/v1".to_owned(),
            model: "model-one".to_owned(),
            timeout_seconds: 30,
        };
        core.upsert_provider_profile(original.clone())
            .expect("create legacy provider");
        let connection_id = ProviderConnectionId::from(original.id.as_str());
        let original_route = core
            .list_model_routes(&connection_id)
            .expect("original routes")
            .into_iter()
            .find(|route| route.model_id == "model-one")
            .expect("original model route");

        let safe_update = ProviderProfile {
            display_name: "Legacy renamed".to_owned(),
            model: "model-two".to_owned(),
            timeout_seconds: 45,
            ..original.clone()
        };
        core.upsert_provider_profile(safe_update.clone())
            .expect("display, timeout, and selected model may change");
        let routes = core
            .list_model_routes(&connection_id)
            .expect("preserved legacy routes");
        let new_route = routes
            .iter()
            .find(|route| route.model_id == "model-two")
            .expect("new model route");
        assert_ne!(new_route.id, original_route.id);
        assert!(routes.iter().any(|route| route.id == original_route.id));

        let mut endpoint_rebind = safe_update.clone();
        endpoint_rebind.base_url = "http://127.0.0.1:65534/v2".to_owned();
        let error = core
            .upsert_provider_profile(endpoint_rebind)
            .expect_err("legacy endpoint mutation must require a new provider ID");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert!(
            error
                .message
                .contains("endpoint configuration is immutable")
        );
        assert_eq!(
            core.inner
                .storage
                .get_provider_profile(&safe_update.id)
                .expect("unchanged legacy profile"),
            safe_update
        );
        assert_eq!(
            core.inner
                .storage
                .get_provider_connection(&connection_id)
                .expect("unchanged legacy connection")
                .config
                .api_base_path
                .as_ref()
                .map(EndpointPath::as_str),
            Some("/v1")
        );
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "the reopen scenario keeps one connection fixture and its durable assertions linear"
    )]
    fn approved_lan_connection_reopens_and_drives_preview_and_generation_validation() {
        let root = tempdir().expect("temporary core root");
        let connection_id = ProviderConnectionId::from("approved-lan-core");
        let route_id = ModelRouteId::from("approved-lan-route");
        let preset_id = GenerationPresetId::from("approved-lan-preset");
        {
            let core = Core::open(CoreConfig::new(root.path())).expect("open core");
            let template = core
                .list_provider_templates()
                .expect("provider templates")
                .into_iter()
                .find(|template| template.id.as_str() == "ollama-native-v1")
                .expect("Ollama template");
            let api_origin = CanonicalOrigin::parse("http://ollama.lan:11434").expect("LAN origin");
            let connection = core
                .create_provider_connection(ProviderConnectionDraft {
                    id: connection_id.clone(),
                    template_id: template.id.clone(),
                    template_version: template.manifest_version,
                    display_name: "Approved LAN Ollama".to_owned(),
                    api_origin: api_origin.clone(),
                    api_base_path: Some(EndpointPath::parse("/api").expect("API base path")),
                    network_mode: ProviderNetworkMode::ApprovedLocalNetwork,
                    local_network_approval: Some(ProviderLocalNetworkApproval {
                        origin: api_origin,
                        addresses: vec![
                            "192.168.10.21".parse().expect("LAN address"),
                            "192.168.10.20".parse().expect("LAN address"),
                            "192.168.10.21".parse().expect("duplicate LAN address"),
                        ],
                    }),
                    values: Vec::new(),
                    approved_credential_origin: None,
                    timeout_seconds: 5,
                })
                .expect("create approved LAN connection");
            assert_eq!(
                connection
                    .config
                    .local_network_approval
                    .as_ref()
                    .expect("normalized LAN approval")
                    .addresses,
                vec![
                    "192.168.10.20".parse::<IpAddr>().expect("LAN address"),
                    "192.168.10.21".parse::<IpAddr>().expect("LAN address"),
                ]
            );
            assert_eq!(
                core.list_provider_connections()
                    .expect("provider connections")
                    .into_iter()
                    .find(|candidate| candidate.id == connection_id)
                    .expect("approved LAN connection"),
                connection
            );
            let now = Utc::now();
            core.upsert_model_route(ModelRoute {
                id: route_id.clone(),
                connection_id: connection_id.clone(),
                api_family: template.api_family,
                model_id: "llama-lan".to_owned(),
                display_name: Some("LAN Llama".to_owned()),
                route_config: ModelRouteConfig::default(),
                status: ModelAvailability::Available,
                miss_count: 0,
                raw_metadata: None,
                metadata_source: ModelMetadataSource::Legacy,
                metadata_observed_at: None,
                last_reconciled_sync_job_id: None,
                metadata_sync_job_id: None,
                first_seen_at: now,
                last_seen_at: Some(now),
            })
            .expect("save LAN model route");
            core.upsert_generation_preset(GenerationPreset {
                id: preset_id.clone(),
                model_route_id: route_id.clone(),
                display_name: "LAN defaults".to_owned(),
                values: Vec::new(),
                reasoning: GenerationReasoningSettings {
                    preserve_opaque_state: false,
                    ..GenerationReasoningSettings::default()
                },
                prompt_cache: GenerationPromptCacheSettings::default(),
                created_at: now,
                updated_at: now,
            })
            .expect("save LAN generation preset");
            core.preview_provider_request(&route_id, &preset_id)
                .expect("preview reconstructs persisted LAN policy");
            core.validate_generation_preset(&route_id, &preset_id)
                .expect("generation validation reconstructs persisted LAN policy");
        }
        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen core");
        let connection = reopened
            .list_provider_connections()
            .expect("reopened provider connections")
            .into_iter()
            .find(|candidate| candidate.id == connection_id)
            .expect("reopened approved LAN connection");
        assert_eq!(
            connection.config.network_mode,
            ProviderNetworkMode::ApprovedLocalNetwork
        );
        reopened
            .preview_provider_request(&route_id, &preset_id)
            .expect("reopened preview reconstructs persisted LAN policy");
        reopened
            .validate_generation_preset(&route_id, &preset_id)
            .expect("reopened generation validation reconstructs persisted LAN policy");
    }

    fn assert_directory_does_not_contain(root: &Path, needle: &[u8]) {
        for entry in fs::read_dir(root).expect("read data directory") {
            let entry = entry.expect("data directory entry");
            let path = entry.path();
            if path.is_dir() {
                assert_directory_does_not_contain(&path, needle);
            } else if path.is_file() {
                let contents = fs::read(&path).expect("read persisted data");
                assert!(
                    !contents
                        .windows(needle.len())
                        .any(|window| window == needle),
                    "secret material was persisted in {}",
                    path.display()
                );
            }
        }
    }

    impl CapturingProvider {
        fn new(response: impl Into<String>) -> (Arc<Self>, std_mpsc::Receiver<Vec<String>>) {
            let (sender, receiver) = std_mpsc::channel();
            (
                Arc::new(Self {
                    response: response.into(),
                    captured: Mutex::new(Some(sender)),
                    captured_temperature: Mutex::new(None),
                }),
                receiver,
            )
        }

        fn new_with_temperature_capture(
            response: impl Into<String>,
        ) -> (
            Arc<Self>,
            std_mpsc::Receiver<Vec<String>>,
            std_mpsc::Receiver<Option<f64>>,
        ) {
            let (message_sender, message_receiver) = std_mpsc::channel();
            let (temperature_sender, temperature_receiver) = std_mpsc::channel();
            (
                Arc::new(Self {
                    response: response.into(),
                    captured: Mutex::new(Some(message_sender)),
                    captured_temperature: Mutex::new(Some(temperature_sender)),
                }),
                message_receiver,
                temperature_receiver,
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
            if let Some(sender) = self
                .captured_temperature
                .lock()
                .expect("temperature capture lock")
                .take()
            {
                let _ = sender.send(request.temperature);
            }
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
    impl Provider for OpaqueContinuityProvider {
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
            _credential: Option<&str>,
            sink: ProviderEventSender,
            _cancelled: watch::Receiver<bool>,
        ) -> CoreResult<GenerationUsage> {
            if let Some(sender) = self
                .captured_request
                .lock()
                .expect("opaque request capture lock")
                .take()
            {
                let _ = sender.send((
                    request.preserve_opaque_reasoning_state,
                    request.opaque_reasoning_context,
                    request.provider_provenance,
                ));
            }
            if let Some(state) = self.emitted_state.clone() {
                sink.send(ProviderEvent::OpaqueReasoningState(state))
                    .await
                    .map_err(|_| CoreError::internal("chat event receiver closed"))?;
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
                ..GenerationUsage::default()
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
        assert_eq!(health.schema_version, 11);
    }

    #[test]
    fn provider_template_listing_exposes_only_each_latest_manifest_version() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let built_in = core
            .list_provider_templates()
            .expect("built-in provider templates")
            .into_iter()
            .find(|template| template.id.as_str() == "openai-chat-compatible-v1")
            .expect("OpenAI-compatible template");
        assert_eq!(built_in.manifest_version, 2);

        let mut version_one = built_in.clone();
        version_one.id = "synthetic-template-history".into();
        version_one.display_name = "Synthetic template history".to_owned();
        version_one.manifest_version = 1;
        let mut version_two = version_one.clone();
        version_two.manifest_version = 2;
        core.inner
            .storage
            .save_provider_template(&version_one)
            .expect("save historical template");
        core.inner
            .storage
            .save_provider_template(&version_two)
            .expect("save latest template");

        let stored_versions = core
            .inner
            .storage
            .list_provider_templates()
            .expect("stored template history")
            .into_iter()
            .filter(|template| template.id == version_one.id)
            .map(|template| template.manifest_version)
            .collect::<Vec<_>>();
        assert_eq!(stored_versions, vec![2, 1]);

        let exposed = core
            .list_provider_templates()
            .expect("latest provider templates")
            .into_iter()
            .filter(|template| template.id == version_one.id)
            .collect::<Vec<_>>();
        assert_eq!(exposed.len(), 1);
        assert_eq!(exposed[0].manifest_version, 2);
    }

    #[test]
    fn ollama_template_view_creates_a_loopback_connection_without_native_inference() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let ollama = core
            .list_provider_template_views()
            .expect("provider template views")
            .into_iter()
            .find(|view| view.template.id.as_str() == "ollama-native-v1")
            .expect("Ollama template view");
        assert_eq!(
            ollama.default_network_mode,
            ProviderNetworkMode::LocalLoopback
        );
        let api_origin = ollama
            .template
            .default_manifest
            .default_api_origin
            .clone()
            .expect("Ollama default origin");

        let connection = core
            .create_provider_connection(ProviderConnectionDraft {
                id: ProviderConnectionId::from("ollama-create-regression"),
                template_id: ollama.template.id,
                template_version: ollama.template.manifest_version,
                display_name: "Local Ollama".to_owned(),
                api_origin,
                api_base_path: Some(EndpointPath::parse("/api").expect("Ollama base path")),
                network_mode: ollama.default_network_mode,
                values: Vec::new(),
                approved_credential_origin: None,
                local_network_approval: None,
                timeout_seconds: 30,
            })
            .expect("create Ollama loopback connection");
        assert_eq!(
            connection.config.network_mode,
            ProviderNetworkMode::LocalLoopback
        );
        assert_eq!(connection.api_origin.as_str(), "http://localhost:11434");
        assert!(connection.credential_ref.is_none());
    }

    #[test]
    fn archived_provider_is_hidden_and_rejected_by_generation_and_model_sync() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let profile = ProviderProfile {
            id: "archived-core-provider".to_owned(),
            display_name: "Archived Core provider".to_owned(),
            base_url: "https://archive.example.com/v1".to_owned(),
            model: "historical-model".to_owned(),
            timeout_seconds: 30,
        };
        core.upsert_provider_profile(profile.clone())
            .expect("create provider");
        let connection_id = ProviderConnectionId::from(profile.id.as_str());
        let connection = core
            .inner
            .storage
            .get_provider_connection(&connection_id)
            .expect("active connection");
        let route = core
            .list_model_routes(&connection_id)
            .expect("active routes")
            .into_iter()
            .next()
            .expect("active route");
        let preset = core
            .list_generation_presets(&route.id)
            .expect("active presets")
            .into_iter()
            .next()
            .expect("active preset");
        core.validate_generation_preset(&route.id, &preset.id)
            .expect("active target");

        let unfinished_sync = core
            .inner
            .storage
            .create_model_sync_job(&connection)
            .expect("create durable model sync");
        let archive_error = core
            .delete_provider_connection(&connection_id)
            .expect_err("unfinished model sync must block Core archive");
        assert_eq!(archive_error.code, CoreErrorCode::InvalidInput);
        assert!(archive_error.recoverable);
        assert_eq!(
            archive_error.message,
            "provider connection cannot be archived while model synchronization is unfinished"
        );
        assert_eq!(
            core.list_provider_connections()
                .expect("active connections after rejected archive"),
            vec![connection]
        );
        core.cancel_provider_model_sync(&unfinished_sync.id)
            .expect("cancel durable model sync");
        core.delete_provider_connection(&connection_id)
            .expect("archive provider");
        assert!(
            core.list_provider_connections()
                .expect("active connections")
                .is_empty()
        );
        assert_eq!(
            core.inner
                .storage
                .get_provider_connection(&connection_id)
                .expect_err("archived provider is hidden")
                .code,
            CoreErrorCode::NotFound
        );
        assert_eq!(
            core.validate_generation_preset(&route.id, &preset.id)
                .expect_err("archived provider cannot generate")
                .code,
            CoreErrorCode::NotFound
        );
        assert_eq!(
            core.start_provider_model_sync(&connection_id, None)
                .expect_err("archived provider cannot synchronize")
                .code,
            CoreErrorCode::NotFound
        );
        assert_eq!(
            core.upsert_provider_profile(profile)
                .expect_err("archived provider id cannot be reused")
                .code,
            CoreErrorCode::InvalidInput
        );
    }

    #[test]
    fn provider_model_refresh_lists_routes_with_non_secret_provenance() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let body = r#"{"data":[{"id":"zeta-model"},{"id":"alpha-model"}]}"#.to_owned();
        let response_bytes = u64::try_from(body.len()).expect("response size");
        let (api_origin, requests) = spawn_model_list_provider(vec![body]);
        let (template, connection) = create_openai_chat_connection(&core, &api_origin);
        let secret = "model-refresh-listing-key";

        let result = refresh_models_with_review(&core, &connection.id, Some(secret))
            .expect("refresh provider models");

        let request = requests
            .recv_timeout(Duration::from_secs(2))
            .expect("captured model-list request");
        let request = request.to_ascii_lowercase();
        assert!(request.starts_with("get /v1/models http/1.1\r\n"));
        assert!(request.contains("authorization: bearer model-refresh-listing-key\r\n"));
        assert_eq!(result.connection_id, connection.id);
        assert_eq!(result.pages_fetched, 1);
        assert_eq!(result.response_bytes, response_bytes);
        assert_eq!(result.provenance.source, "provider_api");
        assert_eq!(result.provenance.api_family, template.api_family);
        assert_eq!(result.provenance.api_origin, api_origin);
        assert_eq!(result.provenance.endpoint_path.as_str(), "/v1/models");
        assert_eq!(
            result
                .model_routes
                .iter()
                .map(|route| route.model_id.as_str())
                .collect::<Vec<_>>(),
            vec!["alpha-model", "zeta-model"]
        );
        assert!(result.model_routes.iter().all(|route| {
            route.status == ModelAvailability::Available
                && route.api_family == template.api_family
                && route.connection_id == connection.id
        }));
        assert_eq!(result.newly_seen_model_route_ids.len(), 2);
        assert_eq!(result.created_generation_preset_ids.len(), 2);
        assert!(result.routes_requiring_preset_configuration.is_empty());
        for route in &result.model_routes {
            let expected_id =
                deterministic_model_route_id(&connection.id, template.api_family, &route.model_id);
            assert_eq!(route.id, expected_id);
            let presets = core
                .list_generation_presets(&route.id)
                .expect("initial preset");
            assert_eq!(presets.len(), 1);
            assert!(presets[0].values.is_empty());
        }
        assert_eq!(
            core.inner
                .storage
                .get_provider_connection(&connection.id)
                .expect("refreshed connection")
                .status,
            ConnectionStatus::Connected
        );
        assert!(!format!("{result:?}").contains(secret));
    }

    #[test]
    fn provider_model_token_limits_become_bounded_route_observations() {
        let observed_at = Utc::now();
        let route = ModelRoute {
            id: ModelRouteId::from("token-route"),
            connection_id: ProviderConnectionId::from("token-connection"),
            api_family: ApiFamily::GeminiGenerateContent,
            model_id: "models/token-model".to_owned(),
            display_name: None,
            route_config: ModelRouteConfig::default(),
            status: ModelAvailability::Available,
            miss_count: 0,
            raw_metadata: None,
            metadata_source: ModelMetadataSource::Legacy,
            metadata_observed_at: None,
            last_reconciled_sync_job_id: None,
            metadata_sync_job_id: None,
            first_seen_at: observed_at,
            last_seen_at: Some(observed_at),
        };
        let listed = ListedModel {
            model_id: route.model_id.clone(),
            display_name: None,
            max_input_tokens: Some(1_000_000),
            max_output_tokens: Some(65_536),
            supported_generation_methods: vec!["generateContent".to_owned()],
            capabilities: lorepia_providers::ListedModelCapabilities::default(),
            source: ModelRecordSource::ProviderApi,
            availability: ModelAvailability::Available,
        };
        let observations = provider_api_capability_observations(
            std::slice::from_ref(&route),
            &[listed],
            observed_at,
        )
        .expect("provider API observations");
        assert_eq!(observations.len(), 2);
        assert!(observations.iter().all(|observation| {
            observation.model_route_id == route.id
                && observation.source == ObservationSource::ProviderApi
                && observation.status == SupportStatus::Verified
                && observation.confidence == Confidence::High
                && observation.expires_at == Some(observed_at + PROVIDER_API_CAPABILITY_FRESHNESS)
        }));
        assert_eq!(
            observations
                .iter()
                .find(|observation| observation.key == CapabilityKey::ContextWindow)
                .map(|observation| &observation.value),
            Some(&CapabilityValue::Integer(1_000_000))
        );
        assert_eq!(
            observations
                .iter()
                .find(|observation| observation.key == CapabilityKey::MaxOutputTokens)
                .map(|observation| &observation.value),
            Some(&CapabilityValue::Integer(65_536))
        );
        assert_eq!(
            provider_api_capability_observations(
                &[route],
                &[ListedModel {
                    model_id: "models/token-model".to_owned(),
                    display_name: None,
                    max_input_tokens: Some(0),
                    max_output_tokens: None,
                    supported_generation_methods: Vec::new(),
                    capabilities: lorepia_providers::ListedModelCapabilities::default(),
                    source: ModelRecordSource::ProviderApi,
                    availability: ModelAvailability::Available,
                }],
                observed_at,
            )
            .expect_err("zero token limits must fail closed")
            .code,
            CoreErrorCode::ProviderUnavailable
        );
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "one contract-matrix regression covers source, freshness, alias, and bound interactions"
    )]
    fn openrouter_parameter_specs_intersect_exact_metadata_and_fail_closed_by_source() {
        let template = AdapterRegistry::built_in_template(BuiltInTemplateId::OpenRouter)
            .expect("OpenRouter template");
        let now = Utc::now();
        let model = listed_openrouter_model(
            "openai/exact-parameter-model",
            vec![
                OpenRouterSupportedParameter::FrequencyPenalty,
                OpenRouterSupportedParameter::Logprobs,
                OpenRouterSupportedParameter::MaxCompletionTokens,
                OpenRouterSupportedParameter::MaxTokens,
                OpenRouterSupportedParameter::ParallelToolCalls,
                OpenRouterSupportedParameter::Stop,
                OpenRouterSupportedParameter::Temperature,
                OpenRouterSupportedParameter::ToolChoice,
                OpenRouterSupportedParameter::Tools,
            ],
            None,
            Some(8_192),
        );
        let mut route = provider_api_openrouter_route(
            ProviderConnectionId::from("openrouter-parameter-connection"),
            &model,
            now,
        );
        let mut base = template.default_manifest.parameters.clone();
        base.push(compiled_openrouter_parameter_spec(
            "alternate_output",
            "max_completion_tokens",
            ParameterType::Integer,
            Some(1.0),
            Some(16_384.0),
            Some(1.0),
            UiParameterLevel::Basic,
        ));
        base.push(compiled_openrouter_parameter_spec(
            "logprobs",
            "logprobs",
            ParameterType::Boolean,
            None,
            None,
            None,
            UiParameterLevel::Advanced,
        ));
        base.push(compiled_openrouter_parameter_spec(
            "parallel_tool_calls",
            "parallel_tool_calls",
            ParameterType::Boolean,
            None,
            None,
            None,
            UiParameterLevel::Advanced,
        ));
        base.push(compiled_openrouter_parameter_spec(
            "tool_choice",
            "tool_choice",
            ParameterType::ToolPolicy,
            None,
            None,
            None,
            UiParameterLevel::Advanced,
        ));
        let specs = effective_route_parameter_specs(&route, &template, &base, &[], now)
            .expect("fresh exact parameter specs");
        let ids = specs
            .iter()
            .map(|spec| spec.id.as_str())
            .collect::<Vec<_>>();
        assert!(ids.contains(&"temperature"));
        assert!(ids.contains(&"frequency_penalty"));
        assert!(ids.contains(&"stop"));
        assert!(!ids.contains(&"top_p"));
        assert!(!ids.contains(&"logprobs"));
        assert!(!ids.contains(&"parallel_tool_calls"));
        assert!(!ids.contains(&"tool_choice"));
        let output = specs
            .iter()
            .find(|spec| spec.id.as_str() == "max_output_tokens")
            .expect("stable output-token control");
        assert_eq!(output.provider_mapping.field_name, "max_completion_tokens");
        assert_eq!(output.maximum, Some(8_192.0));
        assert_eq!(
            specs
                .iter()
                .filter(|spec| {
                    matches!(
                        spec.provider_mapping.field_name.as_str(),
                        "max_tokens" | "max_completion_tokens"
                    )
                })
                .count(),
            1
        );
        for (parameters, expected_field) in [
            (
                vec![OpenRouterSupportedParameter::MaxTokens],
                Some("max_tokens"),
            ),
            (
                vec![OpenRouterSupportedParameter::MaxCompletionTokens],
                Some("max_completion_tokens"),
            ),
            (
                vec![
                    OpenRouterSupportedParameter::MaxTokens,
                    OpenRouterSupportedParameter::MaxCompletionTokens,
                ],
                Some("max_completion_tokens"),
            ),
            (Vec::new(), None),
        ] {
            let alias_model =
                listed_openrouter_model("openai/alias-model", parameters, None, Some(u64::MAX));
            let alias_route = provider_api_openrouter_route(
                ProviderConnectionId::from("openrouter-alias-connection"),
                &alias_model,
                now,
            );
            let alias_specs = effective_route_parameter_specs(
                &alias_route,
                &template,
                &template.default_manifest.parameters,
                &[],
                now,
            )
            .expect("alias parameter contract");
            let output = alias_specs
                .iter()
                .find(|spec| spec.id.as_str() == "max_output_tokens");
            assert_eq!(
                output.map(|spec| spec.provider_mapping.field_name.as_str()),
                expected_field
            );
            if let Some(output) = output {
                assert_eq!(output.maximum, Some(f64::from(u32::MAX)));
            }
        }
        let no_numeric_cap = listed_openrouter_model(
            "openai/no-numeric-cap",
            vec![OpenRouterSupportedParameter::MaxTokens],
            None,
            None,
        );
        let no_numeric_route = provider_api_openrouter_route(
            ProviderConnectionId::from("openrouter-no-numeric-cap"),
            &no_numeric_cap,
            now,
        );
        let no_numeric_specs = effective_route_parameter_specs(
            &no_numeric_route,
            &template,
            &template.default_manifest.parameters,
            &[],
            now,
        )
        .expect("missing numeric cap retains the local safe ceiling");
        assert_eq!(
            no_numeric_specs
                .iter()
                .find(|spec| spec.id.as_str() == "max_output_tokens")
                .expect("output control without provider numeric cap")
                .maximum,
            Some(f64::from(u32::MAX))
        );

        route.metadata_observed_at = Some(now - chrono::Duration::hours(25));
        assert!(
            effective_route_parameter_specs(&route, &template, &base, &[], now)
                .expect("stale bundled-only contract")
                .is_empty()
        );
        let signed_max_tokens = compiled_openrouter_parameter_spec(
            "signed_output",
            "max_tokens",
            ParameterType::Integer,
            Some(1.0),
            None,
            Some(1.0),
            UiParameterLevel::Basic,
        );
        let mut signed_max_completion = signed_max_tokens.clone();
        signed_max_completion.id = ParameterId::from("signed_completion");
        signed_max_completion.provider_mapping.field_name = "max_completion_tokens".to_owned();
        signed_max_completion.maximum = Some(12_345.0);
        let signed_unsafe = compiled_openrouter_parameter_spec(
            "signed_logprobs",
            "logprobs",
            ParameterType::Boolean,
            None,
            None,
            None,
            UiParameterLevel::Advanced,
        );
        let signed_parallel = compiled_openrouter_parameter_spec(
            "signed_parallel_tool_calls",
            "parallel_tool_calls",
            ParameterType::Boolean,
            None,
            None,
            None,
            UiParameterLevel::Advanced,
        );
        let signed_tool_choice = compiled_openrouter_parameter_spec(
            "signed_tool_choice",
            "tool_choice",
            ParameterType::ToolPolicy,
            None,
            None,
            None,
            UiParameterLevel::Advanced,
        );
        let signed = openrouter_safe_signed_parameter_specs(&[
            signed_max_tokens,
            signed_max_completion,
            signed_unsafe,
            signed_parallel,
            signed_tool_choice,
        ]);
        assert_eq!(signed.len(), 1);
        assert_eq!(signed[0].id.as_str(), "max_output_tokens");
        assert_eq!(
            signed[0].provider_mapping.field_name,
            "max_completion_tokens"
        );
        assert_eq!(signed[0].maximum, Some(12_345.0));
        assert_eq!(
            effective_route_parameter_specs(&route, &template, &base, &signed, now)
                .expect("fresh signed fallback"),
            signed
        );
        let canonical_raw = route.raw_metadata.clone();
        route.raw_metadata = Some(
            BoundedJson::from_value(&serde_json::json!({"malformed": true}))
                .expect("bounded malformed metadata fixture"),
        );
        assert_eq!(
            effective_route_parameter_specs(&route, &template, &base, &signed, now)
                .expect_err("stale malformed ProviderApi metadata cannot use signed fallback")
                .code,
            CoreErrorCode::StorageCorrupted
        );
        route.raw_metadata = canonical_raw;

        route.status = ModelAvailability::MissingTemporarily;
        assert!(
            effective_route_parameter_specs(&route, &template, &base, &signed, now)
                .expect("unavailable routes remain nonactionable")
                .is_empty()
        );
        route.status = ModelAvailability::Available;
        route.metadata_observed_at = Some(now);
        route.raw_metadata = None;
        assert_eq!(
            effective_route_parameter_specs(&route, &template, &base, &signed, now)
                .expect_err("fresh ProviderApi provenance without metadata is corrupt")
                .code,
            CoreErrorCode::StorageCorrupted
        );
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "the test keeps raw model metadata, its observation, UI, and request wire in one atomic matrix"
    )]
    fn openrouter_reasoning_requires_matching_fresh_raw_metadata_and_uses_exact_wire_style() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let (template, mut route) =
            create_built_in_public_route(&core, "openrouter-v1", "/api/v1", "openai/reasoning");
        let now = Utc::now();
        let reasoning = ListedModelReasoningCapability {
            supported_efforts: OpenRouterReasoningEffortSupport::Exact(vec![
                lorepia_providers::OpenRouterReasoningEffort::High,
            ]),
            default_effort: Some(lorepia_providers::OpenRouterReasoningEffort::High),
            default_enabled: Some(true),
            supports_max_tokens: Some(true),
            mandatory: Some(false),
        };
        let model = listed_openrouter_model(
            &route.model_id,
            vec![
                OpenRouterSupportedParameter::MaxCompletionTokens,
                OpenRouterSupportedParameter::Reasoning,
                OpenRouterSupportedParameter::ReasoningEffort,
                OpenRouterSupportedParameter::Temperature,
            ],
            Some(reasoning),
            Some(4_096),
        );
        route.raw_metadata = Some(listed_model_metadata(&model).expect("normalized metadata"));
        route.metadata_source = ModelMetadataSource::ProviderApi;
        route.metadata_observed_at = Some(now);
        route.last_seen_at = Some(now);
        core.inner
            .storage
            .save_model_route(&route)
            .expect("save trusted route fixture");
        let observations = provider_api_capability_observations(
            std::slice::from_ref(&route),
            std::slice::from_ref(&model),
            now,
        )
        .expect("provider observations");
        core.record_provider_api_capability_observations(observations)
            .expect("persist provider observations");

        let mut preset = initial_generation_preset(&route.id, &template, now);
        preset.reasoning.mode = GenerationReasoningMode::Enabled;
        let rendered = core
            .render_reasoning_control_for_preset(&preset)
            .expect("render default-effort adoption");
        assert_eq!(
            rendered.settings.effort,
            Some(lorepia_providers::parameter_mapping::ReasoningEffort::High)
        );
        assert_eq!(
            core.validate_generation_preset_candidate(&preset)
                .expect_err("render-only default must not become an implicit request")
                .code,
            CoreErrorCode::InvalidInput
        );

        preset.reasoning.effort = Some(GenerationReasoningEffort::High);
        preset.values = vec![lorepia_domain::ParameterValue {
            parameter_id: ParameterId::from("max_output_tokens"),
            state: lorepia_domain::ParameterValueState::Explicit(
                lorepia_domain::ParameterLiteral::Integer(2_048),
            ),
        }];
        let preview = core
            .preview_provider_request_candidate(&preset)
            .expect("preview unified OpenRouter request");
        let lorepia_providers::RequestBodyShape::Object { fields, .. } =
            preview.body().expect("preview body")
        else {
            panic!("OpenRouter preview body must be an object");
        };
        assert!(fields.iter().any(|field| {
            field.name() == "max_completion_tokens"
                && field.shape() == &lorepia_providers::RequestBodyShape::Number
        }));
        assert!(
            fields
                .iter()
                .all(|field| field.name() != "max_tokens" && field.name() != "reasoning_effort")
        );
        let reasoning = fields
            .iter()
            .find(|field| field.name() == "reasoning")
            .expect("nested reasoning field");
        let lorepia_providers::RequestBodyShape::Object {
            fields: reasoning_fields,
            ..
        } = reasoning.shape()
        else {
            panic!("reasoning preview shape must be an object");
        };
        assert!(
            reasoning_fields
                .iter()
                .any(|field| field.name() == "effort")
        );

        route.metadata_observed_at = Some(now - chrono::Duration::hours(25));
        core.inner
            .storage
            .save_model_route(&route)
            .expect("make raw metadata stale");
        assert_eq!(
            core.render_reasoning_control_for_preset(&preset)
                .expect("stale control renders hidden")
                .state,
            lorepia_providers::parameter_mapping::UiControlState::Hidden
        );
        assert_eq!(
            core.validate_generation_preset_candidate(&preset)
                .expect_err("stale raw metadata cannot drive reasoning")
                .code,
            CoreErrorCode::InvalidInput
        );

        route.metadata_observed_at = Some(now);
        let legacy_model = listed_openrouter_model(
            &route.model_id,
            vec![OpenRouterSupportedParameter::ReasoningEffort],
            Some(ListedModelReasoningCapability {
                supported_efforts: OpenRouterReasoningEffortSupport::AllGateway,
                default_effort: None,
                default_enabled: None,
                supports_max_tokens: None,
                mandatory: Some(false),
            }),
            None,
        );
        route.raw_metadata =
            Some(listed_model_metadata(&legacy_model).expect("legacy raw metadata"));
        core.inner
            .storage
            .save_model_route(&route)
            .expect("save mismatched raw style");
        assert_eq!(
            core.render_reasoning_control_for_preset(&preset)
                .expect("mismatched observation is hidden")
                .state,
            lorepia_providers::parameter_mapping::UiControlState::Hidden
        );

        route.raw_metadata = Some(listed_model_metadata(&model).expect("canonical raw metadata"));
        route.metadata_observed_at = Some(now - chrono::Duration::seconds(1));
        core.inner
            .storage
            .save_model_route(&route)
            .expect("save timestamp-mismatched raw metadata");
        assert_eq!(
            core.render_reasoning_control_for_preset(&preset)
                .expect("timestamp-mismatched observation is hidden")
                .state,
            lorepia_providers::parameter_mapping::UiControlState::Hidden
        );
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "the capability conflict scenario is clearer as one chronological state transition"
    )]
    fn effective_capabilities_gate_reasoning_and_cache_with_exact_fresh_metadata() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let api_origin = CanonicalOrigin::parse("http://127.0.0.1:39491").expect("loopback origin");
        let (target, route) = create_openai_chat_generation_target(&core, &api_origin);
        let preset = core
            .inner
            .storage
            .get_generation_preset(&target.generation_preset_id)
            .expect("seeded generation preset");
        assert_eq!(
            core.render_reasoning_control_for_preset(&preset)
                .expect("hidden reasoning controls")
                .state,
            lorepia_providers::parameter_mapping::UiControlState::Hidden
        );
        assert_eq!(
            core.render_prompt_cache_control_for_preset(&preset)
                .expect("hidden cache controls")
                .state,
            lorepia_providers::parameter_mapping::UiControlState::Hidden
        );

        let error = resolve_generation_target(&core, &target)
            .err()
            .expect("family alone must not enable reasoning or prompt caching");
        assert!(error.message.contains("no observed reasoning control"));

        let observed_at = Utc::now();
        let reasoning = CapabilityObservation {
            id: ObservationId::from("reasoning-provider-api"),
            model_route_id: route.id.clone(),
            key: CapabilityKey::Reasoning,
            value: CapabilityValue::Structured(
                serde_json::to_value(ReasoningWireDialect::OpenAiChatCompletions {
                    efforts: vec![
                        lorepia_providers::parameter_mapping::ReasoningEffort::Low,
                        lorepia_providers::parameter_mapping::ReasoningEffort::High,
                    ],
                    supports_disabled: true,
                })
                .expect("reasoning dialect JSON"),
            ),
            status: SupportStatus::Verified,
            source: ObservationSource::ProviderApi,
            confidence: Confidence::High,
            observed_at,
            expires_at: Some(observed_at + chrono::Duration::hours(1)),
            evidence_ref: None,
        };
        core.record_provider_api_capability_observations(vec![reasoning.clone()])
            .expect("store reasoning observation");
        let reasoning_control = core
            .render_reasoning_control_for_preset(&preset)
            .expect("render reasoning controls");
        assert_eq!(
            reasoning_control.state,
            lorepia_providers::parameter_mapping::UiControlState::Ready
        );
        assert_eq!(
            reasoning_control.allowed_efforts,
            vec![
                lorepia_providers::parameter_mapping::ReasoningEffort::Low,
                lorepia_providers::parameter_mapping::ReasoningEffort::High,
            ]
        );
        assert!(reasoning_control.issues.is_empty());
        let error = resolve_generation_target(&core, &target)
            .err()
            .expect("cache control must remain gated independently");
        assert!(
            error.message.contains("no provider prompt-cache control"),
            "{}",
            error.message
        );

        let prompt_cache = CapabilityObservation {
            id: ObservationId::from("cache-provider-api"),
            model_route_id: route.id.clone(),
            key: CapabilityKey::PromptCaching,
            value: CapabilityValue::Structured(
                serde_json::to_value(PromptCacheWireDialect::OpenAiAutomatic {
                    supports_24_hour_retention: false,
                })
                .expect("prompt-cache dialect JSON"),
            ),
            status: SupportStatus::Verified,
            source: ObservationSource::ProviderApi,
            confidence: Confidence::High,
            observed_at,
            expires_at: Some(observed_at + chrono::Duration::hours(1)),
            evidence_ref: None,
        };
        core.record_provider_api_capability_observations(vec![prompt_cache])
            .expect("store cache observation");
        let cache_control = core
            .render_prompt_cache_control_for_preset(&preset)
            .expect("render cache controls");
        assert_eq!(
            cache_control.state,
            lorepia_providers::parameter_mapping::UiControlState::Ready
        );
        assert!(
            cache_control
                .allowed_modes
                .contains(&lorepia_providers::parameter_mapping::PromptCacheMode::Automatic)
        );
        assert!(cache_control.issues.is_empty());
        resolve_generation_target(&core, &target)
            .expect("exact reasoning and cache metadata unlock request mapping");

        let mut invalid_preset = preset.clone();
        invalid_preset.reasoning.effort = Some(GenerationReasoningEffort::Minimal);
        let invalid_control = core
            .render_reasoning_control_for_preset(&invalid_preset)
            .expect("render invalid reasoning controls");
        assert_eq!(
            invalid_control.state,
            lorepia_providers::parameter_mapping::UiControlState::Invalid
        );
        assert!(!invalid_control.issues.is_empty());

        let conflicting = CapabilityObservation {
            id: ObservationId::from("reasoning-probe-conflict"),
            model_route_id: route.id.clone(),
            key: CapabilityKey::Reasoning,
            value: CapabilityValue::Boolean(false),
            status: SupportStatus::Unsupported,
            source: ObservationSource::CapabilityProbe,
            confidence: Confidence::High,
            observed_at: observed_at + chrono::Duration::seconds(1),
            expires_at: Some(observed_at + chrono::Duration::hours(1)),
            evidence_ref: None,
        };
        core.record_probe_capability_observations(vec![conflicting])
            .expect("store conflicting probe");
        let effective = core
            .effective_capability(&route.id, CapabilityKey::Reasoning)
            .expect("effective capability")
            .expect("reasoning capability");
        assert_eq!(
            effective.selected.source,
            ObservationSource::CapabilityProbe
        );
        assert!(!effective.selected_is_stale);
        assert!(effective.has_conflict);
        let error = resolve_generation_target(&core, &target)
            .err()
            .expect("fresh conflicts must fail closed");
        assert!(error.message.contains("no observed reasoning control"));

        core.delete_capability_observation(&effective.selected.id)
            .expect("remove conflicting observation");
        resolve_generation_target(&core, &target)
            .expect("removing conflict restores exact mapping");

        let mut wrong_family = reasoning;
        wrong_family.id = ObservationId::from("wrong-family-dialect");
        wrong_family.observed_at += chrono::Duration::seconds(2);
        wrong_family.value = CapabilityValue::Structured(
            serde_json::to_value(ReasoningWireDialect::GeminiThinkingBudget {
                minimum_budget_tokens: 1,
                maximum_budget_tokens: 1024,
                supports_zero_to_disable: true,
                supports_automatic: true,
                summaries: Vec::new(),
            })
            .expect("wrong-family dialect JSON"),
        );
        assert!(
            core.upsert_capability_observation(wrong_family)
                .expect_err("family-mismatched dialect must be rejected")
                .message
                .contains("does not match the API family")
        );
    }

    #[test]
    fn signed_catalog_observations_cannot_outlive_the_active_catalog_pointer() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let origin = CanonicalOrigin::parse("http://127.0.0.1:11434").expect("loopback origin");
        let (_target, route) = create_openai_chat_generation_target(&core, &origin);
        let observed_at = Utc::now();
        let observation = CapabilityObservation {
            id: ObservationId::from("detached-signed-catalog-observation"),
            model_route_id: route.id.clone(),
            key: CapabilityKey::Streaming,
            value: CapabilityValue::Boolean(true),
            status: SupportStatus::Documented,
            source: ObservationSource::SignedLorepiaCatalog,
            confidence: Confidence::High,
            observed_at,
            expires_at: Some(observed_at + chrono::Duration::days(1)),
            evidence_ref: None,
        };
        assert!(
            core.upsert_capability_observation(observation.clone())
                .expect_err("detached signed catalog facts must not be accepted")
                .message
                .contains("active verified catalog")
        );

        // Legacy rows from a pre-projection build are ignored as well. Only
        // the currently active, signature-verified snapshot may supply this
        // provenance, so rollback cannot leave a detached fact selected.
        core.inner
            .storage
            .upsert_capability_observation(&observation)
            .expect("inject legacy detached row");
        assert!(
            core.list_capability_observations(&route.id)
                .expect("effective observations")
                .iter()
                .all(|value| value.id != observation.id)
        );
        assert!(
            core.effective_capability(&route.id, CapabilityKey::Streaming)
                .expect("effective capability")
                .is_none()
        );
    }

    #[test]
    fn provider_model_refresh_preserves_missing_routes_and_their_presets() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let first = r#"{"data":[{"id":"keep-model"},{"id":"gone-model"}]}"#.to_owned();
        let second = r#"{"data":[{"id":"keep-model"}]}"#.to_owned();
        let (api_origin, requests) = spawn_model_list_provider(vec![first, second]);
        let (_template, connection) = create_openai_chat_connection(&core, &api_origin);

        let first_result = refresh_models_with_review(&core, &connection.id, Some("refresh-key"))
            .expect("initial model refresh");
        requests
            .recv_timeout(Duration::from_secs(2))
            .expect("initial model-list request");
        let keep_before = first_result
            .model_routes
            .iter()
            .find(|route| route.model_id == "keep-model")
            .expect("kept route")
            .clone();
        let gone_before = first_result
            .model_routes
            .iter()
            .find(|route| route.model_id == "gone-model")
            .expect("soon-missing route")
            .clone();
        let mut customized_preset = core
            .list_generation_presets(&gone_before.id)
            .expect("initial missing-route preset")
            .into_iter()
            .next()
            .expect("preset for soon-missing route");
        customized_preset.display_name = "Keep this preset".to_owned();
        customized_preset.updated_at = Utc::now();
        core.upsert_generation_preset(customized_preset.clone())
            .expect("customize missing-route preset");

        let second_result = refresh_models_with_review(&core, &connection.id, Some("refresh-key"))
            .expect("second model refresh");
        requests
            .recv_timeout(Duration::from_secs(2))
            .expect("second model-list request");

        assert!(second_result.newly_seen_model_route_ids.is_empty());
        assert!(second_result.created_generation_preset_ids.is_empty());
        assert_eq!(
            second_result.missing_model_route_ids,
            vec![gone_before.id.clone()]
        );
        let keep_after = second_result
            .model_routes
            .iter()
            .find(|route| route.model_id == "keep-model")
            .expect("kept route after refresh");
        assert_eq!(keep_after.id, keep_before.id);
        assert_eq!(keep_after.first_seen_at, keep_before.first_seen_at);
        assert_eq!(keep_after.status, ModelAvailability::Available);
        let gone_after = second_result
            .model_routes
            .iter()
            .find(|route| route.model_id == "gone-model")
            .expect("missing route remains");
        assert_eq!(gone_after.id, gone_before.id);
        assert_eq!(gone_after.first_seen_at, gone_before.first_seen_at);
        assert_eq!(gone_after.status, ModelAvailability::MissingTemporarily);
        for error in [
            core.validate_generation_preset_candidate(&customized_preset)
                .expect_err("missing route preset validation"),
            core.preview_provider_request_candidate(&customized_preset)
                .expect_err("missing route preview"),
            core.upsert_generation_preset(customized_preset.clone())
                .expect_err("missing route preset save"),
        ] {
            assert_eq!(error.code, CoreErrorCode::InvalidInput);
            assert!(error.message.contains("not currently available"));
        }
        assert_eq!(
            core.list_generation_presets(&gone_before.id)
                .expect("preserved missing-route presets"),
            vec![customized_preset]
        );
    }

    #[test]
    fn provider_model_refresh_never_persists_the_borrowed_credential() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let (api_origin, requests) = spawn_model_list_provider(vec![
            r#"{"data":[{"id":"credential-safe-model"}]}"#.to_owned(),
        ]);
        let (_template, connection) = create_openai_chat_connection(&core, &api_origin);
        let secret = format!("refresh-secret-{}", Uuid::new_v4());

        let result = refresh_models_with_review(&core, &connection.id, Some(&secret))
            .expect("refresh provider models");
        let request = requests
            .recv_timeout(Duration::from_secs(2))
            .expect("captured credential-bearing request");
        assert!(request.contains(&secret));
        assert!(!format!("{result:?}").contains(&secret));
        assert!(
            core.list_model_routes(&connection.id)
                .expect("persisted routes")
                .iter()
                .all(|route| !format!("{route:?}").contains(&secret))
        );

        drop(core);
        assert_directory_does_not_contain(root.path(), secret.as_bytes());
    }

    #[test]
    fn generation_preset_validation_and_preview_share_the_route_plan() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let (api_origin, requests) =
            spawn_model_list_provider(vec![r#"{"data":[{"id":"preview-safe-model"}]}"#.to_owned()]);
        let (_template, connection) = create_openai_chat_connection(&core, &api_origin);

        let result = refresh_models_with_review(&core, &connection.id, Some("request-only-key"))
            .expect("refresh provider models");
        requests
            .recv_timeout(Duration::from_secs(2))
            .expect("captured model-list request");
        let route = result.model_routes.first().expect("refreshed model route");
        let preset = core
            .list_generation_presets(&route.id)
            .expect("generation presets")
            .into_iter()
            .next()
            .expect("initial generation preset");

        core.validate_generation_preset(&route.id, &preset.id)
            .expect("family-aware generation validation");
        let preview = core
            .preview_provider_request(&route.id, &preset.id)
            .expect("safe provider request preview");
        assert_eq!(preview.method(), lorepia_domain::HttpMethod::Post);
        assert_eq!(preview.origin(), &api_origin);
        assert_eq!(preview.path().as_str(), "/v1/chat/completions");
        assert!(preview.body().is_some());
        assert!(!format!("{preview:?}").contains("request-only-key"));

        let mut invalid = preset.clone();
        invalid.id = GenerationPresetId::from(format!("invalid-{}", Uuid::new_v4()));
        invalid.values = vec![lorepia_domain::ParameterValue {
            parameter_id: lorepia_domain::ParameterId::from("unknown-parameter"),
            state: lorepia_domain::ParameterValueState::Explicit(
                lorepia_domain::ParameterLiteral::Integer(1),
            ),
        }];
        let error = core
            .upsert_generation_preset(invalid.clone())
            .expect_err("invalid candidate must fail before persistence");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert!(
            core.list_generation_presets(&route.id)
                .expect("presets after rejected candidate")
                .iter()
                .all(|stored| stored.id != invalid.id)
        );
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "the table-like cross-family policy assertions share one catalog fixture"
    )]
    fn unsupported_opaque_continuity_is_normalized_or_rejected_before_generation() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let now = Utc::now();

        let (gemini_template, gemini_route) = create_built_in_public_route(
            &core,
            "gemini-generate-content-v1",
            "/v1beta",
            "gemini-2.5-flash",
        );
        let gemini_default = initial_generation_preset(&gemini_route.id, &gemini_template, now);
        assert!(!gemini_default.reasoning.preserve_opaque_state);
        let saved = core
            .upsert_generation_preset(gemini_default.clone())
            .expect("Gemini default with opaque continuity disabled");
        let resolved = resolve_generation_target(
            &core,
            &GenerationTarget {
                model_route_id: gemini_route.id.clone(),
                generation_preset_id: saved.id.clone(),
            },
        )
        .expect("Gemini target resolves without deferred continuity failure");
        assert!(!resolved.preserve_opaque_reasoning_state);

        let mut direct = gemini_default.clone();
        direct.id = GenerationPresetId::from(format!("direct-{}", Uuid::new_v4()));
        direct.reasoning.preserve_opaque_state = true;
        let control = core
            .render_reasoning_control_for_preset(&direct)
            .expect("render normalized Gemini control");
        assert!(!control.settings.preserve_opaque_state);
        for error in [
            core.validate_generation_preset_candidate(&direct)
                .expect_err("direct Gemini continuity candidate"),
            core.preview_provider_request_candidate(&direct)
                .expect_err("Gemini preview must share the pre-network gate"),
            core.upsert_generation_preset(direct.clone())
                .expect_err("Gemini continuity must fail before persistence"),
        ] {
            assert_eq!(error.code, CoreErrorCode::InvalidInput);
            assert_eq!(error.message, GEMINI_OPAQUE_REASONING_TOPOLOGY_ERROR);
        }
        assert!(
            core.list_generation_presets(&gemini_route.id)
                .expect("Gemini presets")
                .iter()
                .all(|preset| preset.id != direct.id)
        );

        let mut legacy = gemini_default;
        legacy.reasoning.preserve_opaque_state = true;
        core.inner
            .storage
            .save_generation_preset(&legacy)
            .expect("seed legacy Gemini preset");
        core.validate_generation_preset(&gemini_route.id, &legacy.id)
            .expect("legacy credential-bound preset is normalized off");
        let legacy_resolved = resolve_generation_target(
            &core,
            &GenerationTarget {
                model_route_id: gemini_route.id.clone(),
                generation_preset_id: legacy.id,
            },
        )
        .expect("legacy credential-bound target resolves safely");
        assert!(!legacy_resolved.preserve_opaque_reasoning_state);

        let (responses_template, responses_route) =
            create_built_in_public_route(&core, "openai-responses-v1", "/v1", "gpt-5-fixture");
        let mut responses_default =
            initial_generation_preset(&responses_route.id, &responses_template, now);
        assert!(!responses_default.reasoning.preserve_opaque_state);
        let responses_saved = core
            .upsert_generation_preset(responses_default.clone())
            .expect("OpenAI Responses default disables lossy opaque continuity");
        let responses_resolved = resolve_generation_target(
            &core,
            &GenerationTarget {
                model_route_id: responses_route.id,
                generation_preset_id: responses_saved.id,
            },
        )
        .expect("OpenAI Responses target without opaque continuity");
        assert!(!responses_resolved.preserve_opaque_reasoning_state);
        responses_default.reasoning.preserve_opaque_state = true;
        let responses_error = core
            .validate_generation_preset_candidate(&responses_default)
            .expect_err("OpenAI Responses cannot replay incomplete response topology");
        assert_eq!(
            responses_error.message,
            OPAQUE_REASONING_STATE_UNSUPPORTED_ERROR
        );

        let (openrouter_template, openrouter_route) =
            create_built_in_public_route(&core, "openrouter-v1", "/api/v1", "openai/gpt-fixture");
        let mut openrouter_default =
            initial_generation_preset(&openrouter_route.id, &openrouter_template, now);
        assert!(!openrouter_default.reasoning.preserve_opaque_state);
        assert!(
            !core
                .render_reasoning_control_for_preset(&openrouter_default)
                .expect("render credential-bound OpenRouter control")
                .settings
                .preserve_opaque_state
        );
        let openrouter_preset = core
            .upsert_generation_preset(openrouter_default.clone())
            .expect("credential-bound OpenRouter disables opaque continuity");
        let openrouter = resolve_generation_target(
            &core,
            &GenerationTarget {
                model_route_id: openrouter_route.id.clone(),
                generation_preset_id: openrouter_preset.id,
            },
        )
        .expect("credential-bound OpenRouter target");
        assert!(!openrouter.preserve_opaque_reasoning_state);
        openrouter_default.reasoning.preserve_opaque_state = true;
        for error in [
            core.validate_generation_preset_candidate(&openrouter_default)
                .expect_err("OpenRouter continuity candidate must fail closed"),
            core.preview_provider_request_candidate(&openrouter_default)
                .expect_err("OpenRouter continuity preview must fail closed"),
            core.upsert_generation_preset(openrouter_default.clone())
                .expect_err("OpenRouter continuity save must fail closed"),
        ] {
            assert_eq!(error.code, CoreErrorCode::InvalidInput);
            assert_eq!(error.message, OPAQUE_REASONING_STATE_UNSUPPORTED_ERROR);
        }

        let loopback = CanonicalOrigin::parse("http://127.0.0.1:65534").expect("loopback origin");
        let (generic_template, generic_connection) =
            create_openai_chat_connection(&core, &loopback);
        let generic_route = ModelRoute {
            id: ModelRouteId::from(format!("route-{}", Uuid::new_v4())),
            connection_id: generic_connection.id,
            api_family: generic_template.api_family,
            model_id: "generic-chat".to_owned(),
            display_name: None,
            route_config: ModelRouteConfig::default(),
            status: ModelAvailability::Available,
            miss_count: 0,
            raw_metadata: None,
            metadata_source: ModelMetadataSource::Legacy,
            metadata_observed_at: None,
            last_reconciled_sync_job_id: None,
            metadata_sync_job_id: None,
            first_seen_at: now,
            last_seen_at: Some(now),
        };
        core.upsert_model_route(generic_route.clone())
            .expect("save generic Chat Completions route");
        let mut generic_default =
            initial_generation_preset(&generic_route.id, &generic_template, now);
        assert!(!generic_default.reasoning.preserve_opaque_state);
        let generic_saved = core
            .upsert_generation_preset(generic_default.clone())
            .expect("generic Chat Completions default");
        let generic_resolved = resolve_generation_target(
            &core,
            &GenerationTarget {
                model_route_id: generic_route.id.clone(),
                generation_preset_id: generic_saved.id,
            },
        )
        .expect("generic Chat Completions target");
        assert!(!generic_resolved.preserve_opaque_reasoning_state);
        generic_default.reasoning.preserve_opaque_state = true;
        let generic_error = core
            .validate_generation_preset_candidate(&generic_default)
            .expect_err("generic Chat Completions cannot advertise OpenRouter continuity");
        assert_eq!(
            generic_error.message,
            OPAQUE_REASONING_STATE_UNSUPPORTED_ERROR
        );
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "credential rotation, a legacy row, and reopen assertions must share one fixture"
    )]
    fn opaque_preset_is_provenance_only_but_credential_targets_never_load_or_persist_it() {
        let (root, core, character) = imported_core();
        let conversation = core
            .create_conversation(&character.id, "Opaque continuity", ConversationMode::Chat)
            .expect("conversation");
        let state = core
            .get_conversation_state(&conversation.id)
            .expect("conversation state");
        let (template, route) = create_built_in_public_route(
            &core,
            "openrouter-v1",
            "/api/v1",
            "openrouter/test-model",
        );
        let model = route.model_id.clone();
        let route_id = route.id.clone();
        let source_preset = core
            .upsert_generation_preset(initial_generation_preset(&route_id, &template, Utc::now()))
            .expect("source preset");
        let source_preset_id = source_preset.id.clone();
        assert!(!source_preset.reasoning.preserve_opaque_state);
        let source_target = GenerationTarget {
            model_route_id: route_id.clone(),
            generation_preset_id: source_preset_id.clone(),
        };
        let retained_state = OpaqueReasoningState::OpenRouterReasoning {
            topology: OpenRouterReasoningTopology::new(
                None,
                Some(vec![
                    OpenRouterReasoningDetail::from_value(&serde_json::json!({
                        "type": "reasoning.encrypted",
                        "data": "opaque-state",
                        "id": "detail-1",
                        "format": "openrouter-v1",
                        "index": 0
                    }))
                    .expect("OpenRouter opaque detail"),
                ]),
            )
            .expect("OpenRouter opaque topology"),
        };
        let (source_capture_sender, source_capture_receiver) = std_mpsc::channel();
        let source_provider = Arc::new(OpaqueContinuityProvider {
            response: "source response".to_owned(),
            emitted_state: Some(retained_state.clone()),
            captured_request: Mutex::new(Some(source_capture_sender)),
        });

        // Even an internal caller asking to preserve state is overridden when
        // the actual borrowed credential is non-empty.
        let source_generation_id = core
            .send_message_to_branch_with_provider_options(
                &conversation.id,
                &state.active_branch_id,
                None,
                ConversationMode::Chat,
                "first",
                model.clone(),
                Some(&source_target),
                Some(ApiFamily::OpenAiChatCompletions),
                true,
                None,
                Some(128),
                Some("credential-a".to_owned()),
                source_provider,
            )
            .expect("source generation");
        let (source_preserve, source_contexts, _) = source_capture_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("captured source request");
        assert!(!source_preserve);
        assert!(source_contexts.is_empty());
        let source_generation =
            wait_for_generation_status(&core, &source_generation_id, GenerationStatus::Complete);
        assert!(source_generation.opaque_reasoning_state.is_empty());
        let source_assistant = core
            .list_branch_messages(&state.active_branch_id)
            .expect("source branch messages")
            .into_iter()
            .find(|message| {
                message.role == MessageRole::Assistant
                    && message.generation_id.as_ref() == Some(&source_generation_id)
            })
            .expect("source assistant");

        // Simulate a completed row written by an older release while key A was
        // active. Credentials are intentionally absent from generation rows,
        // so Core must never infer that this state is safe for key B.
        let legacy_generation_id = GenerationId::new();
        let legacy_user = Message::user_after(
            conversation.id.clone(),
            Some(source_assistant.id.clone()),
            "legacy credential-A turn",
        );
        let legacy_assistant = Message::pending_assistant(
            conversation.id.clone(),
            legacy_user.id.clone(),
            legacy_generation_id.clone(),
        );
        let legacy_generation = GenerationRecord {
            id: legacy_generation_id.clone(),
            conversation_id: conversation.id.clone(),
            branch_id: state.active_branch_id.clone(),
            user_message_id: legacy_user.id.clone(),
            assistant_message_id: Some(legacy_assistant.id.clone()),
            mode: ConversationMode::Chat,
            model: model.clone(),
            model_route_id: Some(route_id.clone()),
            generation_preset_id: Some(source_preset_id.clone()),
            provider_family: Some(ApiFamily::OpenAiChatCompletions),
            status: GenerationStatus::Running,
            input_tokens: None,
            cached_read_tokens: None,
            cached_write_tokens: None,
            output_tokens: None,
            reasoning_tokens: None,
            tool_tokens: None,
            provider_raw_summary: None,
            opaque_reasoning_state: Vec::new(),
            error_code: None,
            started_at: Utc::now(),
            finished_at: None,
        };
        core.inner
            .storage
            .append_generation(
                &state.active_branch_id,
                Some(&source_assistant.id),
                &legacy_user,
                &legacy_assistant,
                &legacy_generation,
            )
            .expect("seed running legacy generation");
        let mut legacy_terminal = legacy_assistant;
        legacy_terminal.content = "legacy response".to_owned();
        legacy_terminal.status = MessageStatus::Complete;
        core.inner
            .storage
            .finalize_generation_with_protocol_state(
                &legacy_terminal,
                Some(&GenerationUsage::default()),
                std::slice::from_ref(&retained_state),
                None,
                true,
            )
            .expect("seed legacy credential-A opaque state");
        assert_eq!(
            core.inner
                .storage
                .get_generation(&legacy_generation_id)
                .expect("legacy generation")
                .opaque_reasoning_state,
            vec![retained_state.clone()]
        );

        // Preset ID remains source provenance rather than continuity identity.
        // This dormant loader may match the exact family/model/route/source
        // under a different current preset, while the credential gate below
        // ensures production requests never receive that context.
        let different_current_target = GenerationTarget {
            model_route_id: route_id.clone(),
            generation_preset_id: GenerationPresetId::from("different-current-preset"),
        };
        let dormant_context = load_opaque_reasoning_context(
            &core.inner.storage,
            std::slice::from_ref(&legacy_terminal),
            ApiFamily::OpenAiChatCompletions,
            &model,
            &different_current_target,
        )
        .expect("load dormant context under a different current preset");
        assert_eq!(dormant_context.len(), 1);
        assert_eq!(dormant_context[0].source_message_id, legacy_terminal.id);
        assert_eq!(dormant_context[0].model_route_id, route_id);
        assert_eq!(dormant_context[0].generation_preset_id, source_preset_id);
        assert_ne!(
            dormant_context[0].generation_preset_id,
            different_current_target.generation_preset_id
        );

        let resolved = resolve_generation_target(&core, &source_target)
            .expect("credential-bound target resolves with continuity disabled");
        assert!(!resolved.preserve_opaque_reasoning_state);
        let next_state = OpaqueReasoningState::OpenRouterReasoning {
            topology: OpenRouterReasoningTopology::new(
                Some("new key-B reasoning".to_owned()),
                Some(Vec::new()),
            )
            .expect("new OpenRouter topology"),
        };
        let (capture_sender, capture_receiver) = std_mpsc::channel();
        let next_provider = Arc::new(OpaqueContinuityProvider {
            response: "next response".to_owned(),
            emitted_state: Some(next_state),
            captured_request: Mutex::new(Some(capture_sender)),
        });
        let next_generation_id = core
            .send_message_to_branch_with_provider_options(
                &conversation.id,
                &state.active_branch_id,
                Some(&legacy_terminal.id),
                ConversationMode::Chat,
                "second",
                model.clone(),
                Some(&source_target),
                Some(ApiFamily::OpenAiChatCompletions),
                true,
                None,
                Some(128),
                Some("credential-b".to_owned()),
                next_provider,
            )
            .expect("next generation with a different credential");
        let (preserve, contexts, current_provenance) = capture_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("captured next request");
        assert!(!preserve);
        assert!(contexts.is_empty());
        let next_generation =
            wait_for_generation_status(&core, &next_generation_id, GenerationStatus::Complete);
        assert!(next_generation.opaque_reasoning_state.is_empty());

        assert_eq!(
            current_provenance,
            Some(GenerationProviderProvenance {
                api_family: ApiFamily::OpenAiChatCompletions,
                model_route_id: route_id.clone(),
                generation_preset_id: source_preset_id,
            })
        );
        wait_for_generation_registry_to_drain(&core);
        drop(core);

        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen core");
        assert_eq!(
            reopened
                .inner
                .storage
                .get_generation(&legacy_generation_id)
                .expect("reopened legacy generation")
                .opaque_reasoning_state,
            vec![retained_state]
        );
        assert!(
            reopened
                .inner
                .storage
                .get_generation(&next_generation_id)
                .expect("reopened key-B generation")
                .opaque_reasoning_state
                .is_empty()
        );
    }

    #[test]
    #[allow(
        clippy::too_many_lines,
        reason = "route construction and durable no-auth assertions intentionally share one fixture"
    )]
    fn nonempty_raw_credential_disables_opaque_state_on_a_no_auth_connection() {
        let (root, core, character) = imported_core();
        let conversation = core
            .create_conversation(
                &character.id,
                "No-auth raw credential",
                ConversationMode::Chat,
            )
            .expect("conversation");
        let branch = core
            .get_conversation_state(&conversation.id)
            .expect("conversation state")
            .active_branch_id;
        let template = core
            .list_provider_templates()
            .expect("provider templates")
            .into_iter()
            .find(|template| template.id.as_str() == "ollama-native-v1")
            .expect("Ollama template");
        let api_origin = CanonicalOrigin::parse("http://127.0.0.1:11434").expect("loopback origin");
        let connection = core
            .create_provider_connection(ProviderConnectionDraft {
                id: ProviderConnectionId::from(format!("no-auth-{}", Uuid::new_v4())),
                template_id: template.id.clone(),
                template_version: template.manifest_version,
                display_name: "No-auth Ollama".to_owned(),
                api_origin,
                api_base_path: Some(EndpointPath::parse("/api").expect("API base path")),
                network_mode: ProviderNetworkMode::LocalLoopback,
                values: Vec::new(),
                approved_credential_origin: None,
                local_network_approval: None,
                timeout_seconds: 5,
            })
            .expect("create no-auth connection");
        assert!(connection.credential_ref.is_none());
        let now = Utc::now();
        let route = ModelRoute {
            id: ModelRouteId::from(format!("no-auth-route-{}", Uuid::new_v4())),
            connection_id: connection.id,
            api_family: ApiFamily::OllamaNative,
            model_id: "llama-no-auth".to_owned(),
            display_name: None,
            route_config: ModelRouteConfig::default(),
            status: ModelAvailability::Available,
            miss_count: 0,
            raw_metadata: None,
            metadata_source: ModelMetadataSource::Legacy,
            metadata_observed_at: None,
            last_reconciled_sync_job_id: None,
            metadata_sync_job_id: None,
            first_seen_at: now,
            last_seen_at: Some(now),
        };
        core.upsert_model_route(route.clone())
            .expect("save no-auth route");
        let preset = core
            .upsert_generation_preset(initial_generation_preset(&route.id, &template, now))
            .expect("save no-auth preset");
        let target = GenerationTarget {
            model_route_id: route.id,
            generation_preset_id: preset.id,
        };

        let (capture_sender, capture_receiver) = std_mpsc::channel();
        let provider = Arc::new(OpaqueContinuityProvider {
            response: "safe response".to_owned(),
            emitted_state: Some(OpaqueReasoningState::GeminiThoughtSignature {
                part_index: 0,
                signature: lorepia_domain::OpaqueReasoningData::parse("safe-signature")
                    .expect("signature"),
            }),
            captured_request: Mutex::new(Some(capture_sender)),
        });
        let generation_id = core
            .send_message_to_branch_with_provider_options(
                &conversation.id,
                &branch,
                None,
                ConversationMode::Chat,
                "hello",
                "llama-no-auth".to_owned(),
                Some(&target),
                Some(ApiFamily::OllamaNative),
                true,
                None,
                Some(128),
                Some("unexpected-raw-credential".to_owned()),
                provider,
            )
            .expect("start no-auth generation");
        let (preserve, contexts, provenance) = capture_receiver
            .recv_timeout(Duration::from_secs(2))
            .expect("captured no-auth request");
        assert!(!preserve);
        assert!(contexts.is_empty());
        assert_eq!(
            provenance,
            Some(GenerationProviderProvenance {
                api_family: ApiFamily::OllamaNative,
                model_route_id: target.model_route_id,
                generation_preset_id: target.generation_preset_id,
            })
        );
        let generation =
            wait_for_generation_status(&core, &generation_id, GenerationStatus::Complete);
        assert!(generation.opaque_reasoning_state.is_empty());
        wait_for_generation_registry_to_drain(&core);
        drop(core);

        let reopened = Core::open(CoreConfig::new(root.path())).expect("reopen core");
        assert!(
            reopened
                .inner
                .storage
                .get_generation(&generation_id)
                .expect("reopened no-auth generation")
                .opaque_reasoning_state
                .is_empty()
        );
    }

    #[test]
    fn provider_model_sync_rejects_reflected_credential_without_persisting_it() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let secret = format!("reflected-secret-{}", Uuid::new_v4());
        let body = serde_json::json!({
            "data": [{"id": secret.clone()}],
        })
        .to_string();
        let (api_origin, requests) = spawn_model_list_provider(vec![body]);
        let (_template, connection) = create_openai_chat_connection(&core, &api_origin);

        let error = refresh_models_with_review(&core, &connection.id, Some(&secret))
            .expect_err("credential reflection must fail closed");
        requests
            .recv_timeout(Duration::from_secs(2))
            .expect("captured credential-bearing request");
        assert_eq!(error.code, CoreErrorCode::ProviderUnavailable);
        let jobs = core
            .list_provider_model_syncs(&connection.id, 4)
            .expect("durable failed job");
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].state, ModelSyncState::Failed);
        assert!(jobs[0].review.is_none());
        assert!(!format!("{jobs:?}").contains(&secret));

        drop(core);
        assert_directory_does_not_contain(root.path(), secret.as_bytes());
    }

    #[test]
    fn job_scoped_model_sync_event_poll_does_not_consume_another_job() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        for (id, origin) in [
            ("event-job-a", "https://events-a.example.com/v1"),
            ("event-job-b", "https://events-b.example.com/v1"),
        ] {
            core.upsert_provider_profile(ProviderProfile {
                id: id.to_owned(),
                display_name: id.to_owned(),
                base_url: origin.to_owned(),
                model: "existing-model".to_owned(),
                timeout_seconds: 30,
            })
            .expect("seed provider graph");
        }
        let first_connection = core
            .inner
            .storage
            .get_provider_connection(&ProviderConnectionId::from("event-job-a"))
            .expect("first connection");
        let second_connection = core
            .inner
            .storage
            .get_provider_connection(&ProviderConnectionId::from("event-job-b"))
            .expect("second connection");
        let first_job = core
            .inner
            .storage
            .create_model_sync_job(&first_connection)
            .expect("first model sync job");
        let second_job = core
            .inner
            .storage
            .create_model_sync_job(&second_connection)
            .expect("second model sync job");

        let first_events = core
            .poll_provider_model_sync_events(&first_job.id, 16)
            .expect("poll first job");
        assert_eq!(first_events.len(), 1);
        assert_eq!(first_events[0].job_id, first_job.id);
        assert!(
            core.ack_provider_model_sync_event(&first_job.id, first_events[0].sequence)
                .expect("ack first job")
        );

        let second_events = core
            .poll_provider_model_sync_events(&second_job.id, 16)
            .expect("poll second job");
        assert_eq!(second_events.len(), 1);
        assert_eq!(second_events[0].job_id, second_job.id);
        assert_eq!(
            core.poll_provider_model_sync_events(&second_job.id, 16)
                .expect("second event remains until acknowledged"),
            second_events
        );
        assert!(
            core.ack_provider_model_sync_event(&second_job.id, second_events[0].sequence)
                .expect("ack second job")
        );
    }

    #[test]
    fn provider_model_refresh_records_safe_failure_statuses() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let secret = format!("failure-secret-{}", Uuid::new_v4());

        let (auth_origin, auth_requests) = spawn_model_list_http_provider(vec![(
            "401 Unauthorized".to_owned(),
            r#"{"error":"invalid credential"}"#.to_owned(),
        )]);
        let (_template, auth_connection) = create_openai_chat_connection(&core, &auth_origin);
        let auth_error = refresh_models_with_review(&core, &auth_connection.id, Some(&secret))
            .expect_err("401 model refresh must fail");
        auth_requests
            .recv_timeout(Duration::from_secs(2))
            .expect("captured auth-failing request");
        assert_eq!(auth_error.code, CoreErrorCode::ProviderAuthFailed);
        assert!(!format!("{auth_error:?}").contains(&secret));
        assert_eq!(
            core.inner
                .storage
                .get_provider_connection(&auth_connection.id)
                .expect("auth-failed connection")
                .status,
            ConnectionStatus::AuthFailed
        );

        let (unavailable_origin, unavailable_requests) = spawn_model_list_http_provider(vec![(
            "503 Service Unavailable".to_owned(),
            r#"{"error":"temporarily unavailable"}"#.to_owned(),
        )]);
        let (_template, unavailable_connection) =
            create_openai_chat_connection(&core, &unavailable_origin);
        let unavailable_error =
            refresh_models_with_review(&core, &unavailable_connection.id, Some(&secret))
                .expect_err("503 model refresh must fail");
        unavailable_requests
            .recv_timeout(Duration::from_secs(2))
            .expect("captured unavailable request");
        assert_eq!(unavailable_error.code, CoreErrorCode::ProviderUnavailable);
        assert!(!format!("{unavailable_error:?}").contains(&secret));
        assert_eq!(
            core.inner
                .storage
                .get_provider_connection(&unavailable_connection.id)
                .expect("unavailable connection")
                .status,
            ConnectionStatus::Unavailable
        );
    }

    #[test]
    fn initial_model_preset_is_deferred_when_template_requires_an_explicit_value() {
        let root = tempdir().expect("temp root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let templates = core.list_provider_templates().expect("provider templates");
        let anthropic = templates
            .iter()
            .find(|template| template.id.as_str() == "anthropic-messages-v1")
            .expect("Anthropic template");
        let openai_chat = templates
            .iter()
            .find(|template| template.id.as_str() == "openai-chat-compatible-v1")
            .expect("OpenAI-compatible template");

        assert!(!template_accepts_empty_preset(anthropic).expect("Anthropic preset requirement"));
        assert!(
            template_accepts_empty_preset(openai_chat)
                .expect("OpenAI-compatible preset requirement")
        );
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
            selected_model_route_id: None,
            selected_generation_preset_id: None,
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
            selected_model_route_id: None,
            selected_generation_preset_id: None,
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
    fn generation_assembly_preserves_validated_temperature_and_default_omission() {
        let (_root, core, character) = imported_core();
        let clamped_conversation = core
            .create_conversation(&character.id, "온도 검증", ConversationMode::Chat)
            .expect("clamped conversation");
        let clamped_state = core
            .get_conversation_state(&clamped_conversation.id)
            .expect("clamped state");
        let (provider, _messages, captured_temperature) =
            CapturingProvider::new_with_temperature_capture("응답");

        let invalid = core
            .send_message_to_branch_with_provider_options(
                &clamped_conversation.id,
                &clamped_state.active_branch_id,
                None,
                ConversationMode::Chat,
                "전송되면 안 됨",
                "model".to_owned(),
                None,
                None,
                false,
                Some(f64::NAN),
                Some(1),
                None,
                Arc::new(StaticProvider::new("unused")),
            )
            .expect_err("non-finite temperature must fail before persistence");
        assert_eq!(invalid.code, CoreErrorCode::InvalidInput);
        assert!(
            core.list_branch_messages(&clamped_state.active_branch_id)
                .expect("unchanged branch")
                .is_empty()
        );

        core.send_message_to_branch_with_provider_options(
            &clamped_conversation.id,
            &clamped_state.active_branch_id,
            None,
            ConversationMode::Chat,
            "유한 온도",
            "model".to_owned(),
            None,
            None,
            false,
            Some(3.0),
            Some(1),
            None,
            provider,
        )
        .expect("clamped generation");
        assert_eq!(
            captured_temperature
                .recv_timeout(Duration::from_secs(2))
                .expect("captured clamped temperature"),
            Some(2.0)
        );

        let default_conversation = core
            .create_conversation(&character.id, "기본 온도", ConversationMode::Chat)
            .expect("default conversation");
        let default_state = core
            .get_conversation_state(&default_conversation.id)
            .expect("default state");
        let (provider, _messages, captured_temperature) =
            CapturingProvider::new_with_temperature_capture("응답");
        core.send_message_to_branch_with_provider_options(
            &default_conversation.id,
            &default_state.active_branch_id,
            None,
            ConversationMode::Chat,
            "기본값",
            "model".to_owned(),
            None,
            None,
            false,
            None,
            Some(1),
            None,
            provider,
        )
        .expect("default generation");
        assert_eq!(
            captured_temperature
                .recv_timeout(Duration::from_secs(2))
                .expect("captured omitted temperature"),
            None
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
                model_route_id: None,
                generation_preset_id: None,
                provider_family: None,
                status: GenerationStatus::Running,
                input_tokens: None,
                cached_read_tokens: None,
                cached_write_tokens: None,
                output_tokens: None,
                reasoning_tokens: None,
                tool_tokens: None,
                provider_raw_summary: None,
                opaque_reasoning_state: Vec::new(),
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
