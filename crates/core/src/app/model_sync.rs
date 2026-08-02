use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use chrono::Utc;
use lorepia_domain::{
    CoreError, CoreErrorCode, CoreResult, ModelSyncDiff, ModelSyncEvent, ModelSyncFailure,
    ModelSyncJob, ModelSyncJobId, ModelSyncReview, ModelSyncSourceProvenance, ModelSyncState,
    ProviderConnectionId,
};
use lorepia_providers::{AdapterRegistry, ModelListRequest};
use lorepia_storage::Storage;
use tokio::sync::watch;

use super::{
    Core, ModelRecordSource, ensure_model_list_does_not_reflect_credential,
    initial_generation_preset, model_record_source_name, provider_api_capability_observations,
    reconcile_input_routes, record_model_refresh_failure, template_accepts_empty_preset,
    validate_provider_template,
};

#[derive(Default)]
pub(super) struct ModelSyncRegistry {
    active: Mutex<HashMap<ModelSyncJobId, watch::Sender<bool>>>,
}

impl ModelSyncRegistry {
    fn register(&self, id: ModelSyncJobId, sender: watch::Sender<bool>) -> CoreResult<()> {
        let replaced = self
            .active
            .lock()
            .map_err(|_| CoreError::internal("model synchronization registry lock was poisoned"))?
            .insert(id, sender);
        if replaced.is_some() {
            return Err(CoreError::internal(
                "model synchronization was registered more than once",
            ));
        }
        Ok(())
    }

    fn cancel(&self, id: &ModelSyncJobId) {
        let sender = self
            .active
            .lock()
            .ok()
            .and_then(|active| active.get(id).cloned());
        if let Some(sender) = sender {
            let _ = sender.send(true);
        }
    }

    fn remove(&self, id: &ModelSyncJobId) {
        if let Ok(mut active) = self.active.lock() {
            active.remove(id);
        }
    }

    pub(super) fn cancel_all(&self) {
        if let Ok(active) = self.active.lock() {
            for sender in active.values() {
                let _ = sender.send(true);
            }
        }
    }

    pub(super) fn len(&self) -> usize {
        self.active.lock().map_or(0, |active| active.len())
    }
}

struct ModelSyncTask {
    storage: Arc<Storage>,
    registry: Arc<ModelSyncRegistry>,
    job_id: ModelSyncJobId,
    connection_id: ProviderConnectionId,
    credential: Option<String>,
    cancel_receiver: watch::Receiver<bool>,
}

impl Core {
    /// Starts one durable, review-gated model synchronization.
    ///
    /// `credential` lives only in the spawned request task. It is never
    /// serialized into the job, review, outbox, route metadata, or error.
    pub fn start_provider_model_sync(
        &self,
        connection_id: &ProviderConnectionId,
        credential: Option<String>,
    ) -> CoreResult<ModelSyncJobId> {
        let connection = self.inner.storage.get_provider_connection(connection_id)?;
        let template = self
            .inner
            .storage
            .get_provider_template(&connection.template_id, connection.template_version)?;
        validate_provider_template(&template)?;
        // Build before creating the job so unsupported templates do not leave
        // an inert active row behind.
        AdapterRegistry::new().build_model_listing(&template, &connection)?;

        let job = self.inner.storage.create_model_sync_job(&connection)?;
        let (cancel_sender, cancel_receiver) = watch::channel(false);
        if let Err(error) = self
            .inner
            .active_model_syncs
            .register(job.id.clone(), cancel_sender)
        {
            let _ = self.inner.storage.cancel_model_sync_job(&job.id);
            return Err(error);
        }
        let task = ModelSyncTask {
            storage: Arc::clone(&self.inner.storage),
            registry: Arc::clone(&self.inner.active_model_syncs),
            job_id: job.id.clone(),
            connection_id: connection_id.clone(),
            credential,
            cancel_receiver,
        };
        self.inner.runtime.spawn(run_model_sync(task));
        Ok(job.id)
    }

    pub fn get_provider_model_sync(&self, id: &ModelSyncJobId) -> CoreResult<ModelSyncJob> {
        self.inner.storage.get_model_sync_job(id)
    }

    pub fn list_provider_model_syncs(
        &self,
        connection_id: &ProviderConnectionId,
        limit: u32,
    ) -> CoreResult<Vec<ModelSyncJob>> {
        self.inner
            .storage
            .list_model_sync_jobs(connection_id, limit)
    }

    /// Approves exactly the currently stored canonical diff hash.
    pub fn approve_provider_model_sync(
        &self,
        id: &ModelSyncJobId,
        review_sha256: &str,
    ) -> CoreResult<ModelSyncJob> {
        let current = self.inner.storage.get_model_sync_job(id)?;
        if current.state == ModelSyncState::Completed {
            let review = current.review.as_ref().ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::StorageCorrupted,
                    "completed model synchronization is missing its review",
                    false,
                )
            })?;
            review.verify().map_err(|message| {
                CoreError::new(CoreErrorCode::StorageCorrupted, message, false)
            })?;
            if review.sha256 == review_sha256 {
                return Ok(current);
            }
            return Err(CoreError::invalid(
                "approved model synchronization hash does not match the completed review",
            ));
        }
        if current.state != ModelSyncState::DiffReadyAwaitingReview {
            return Err(CoreError::invalid(
                "model synchronization is not awaiting review",
            ));
        }
        let review = current.review.as_ref().ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "review-ready model synchronization is missing its review",
                false,
            )
        })?;
        review
            .verify()
            .map_err(|message| CoreError::new(CoreErrorCode::StorageCorrupted, message, false))?;
        if review.sha256 != review_sha256 {
            return Err(CoreError::invalid(
                "approved model synchronization hash does not match the current review",
            ));
        }

        let committing = self.inner.storage.mark_model_sync_job_committing(
            id,
            current.revision,
            review_sha256,
        )?;
        match self
            .inner
            .storage
            .commit_model_sync_job(id, committing.revision)
        {
            Ok(completed) => Ok(completed),
            Err(error) => {
                let failure = ModelSyncFailure::from_core_error(&error);
                let _ = self
                    .inner
                    .storage
                    .fail_model_sync_job(id, committing.revision, &failure);
                Err(error)
            }
        }
    }

    pub fn cancel_provider_model_sync(&self, id: &ModelSyncJobId) -> CoreResult<ModelSyncJob> {
        let cancelled = self.inner.storage.cancel_model_sync_job(id)?;
        self.inner.active_model_syncs.cancel(id);
        Ok(cancelled)
    }

    /// Polls durable progress events for one job with at-least-once delivery.
    ///
    /// Events remain available until the host acknowledges their exact
    /// `(job_id, sequence)` identity.
    pub fn poll_provider_model_sync_events(
        &self,
        id: &ModelSyncJobId,
        limit: u32,
    ) -> CoreResult<Vec<ModelSyncEvent>> {
        self.inner.storage.poll_model_sync_events_for_job(id, limit)
    }

    /// Acknowledges one event previously polled for this exact job.
    pub fn ack_provider_model_sync_event(
        &self,
        id: &ModelSyncJobId,
        sequence: u64,
    ) -> CoreResult<bool> {
        self.inner.storage.ack_model_sync_event(id, sequence)
    }
}

async fn run_model_sync(mut task: ModelSyncTask) {
    let outcome = run_model_sync_inner(&mut task).await;
    // Failure payloads are intentionally created from the stable error code
    // only. Provider bodies/messages and credential text are never persisted.
    if let Err((revision, error)) = outcome {
        if error.code != CoreErrorCode::Cancelled
            && let Ok(connection) = task.storage.get_provider_connection(&task.connection_id)
        {
            let _ = record_model_refresh_failure(&task.storage, &connection, &error);
        }
        let failure = ModelSyncFailure::from_core_error(&error);
        let _ = task
            .storage
            .fail_model_sync_job(&task.job_id, revision, &failure);
    }
    task.credential = None;
    task.registry.remove(&task.job_id);
}

#[allow(
    clippy::too_many_lines,
    reason = "the sync state machine keeps each durable checkpoint in one ordered workflow"
)]
async fn run_model_sync_inner(task: &mut ModelSyncTask) -> Result<(), (u64, CoreError)> {
    let created = task
        .storage
        .get_model_sync_job(&task.job_id)
        .map_err(|error| (1, error))?;
    let fetching = task
        .storage
        .transition_model_sync_job_to_fetching(&task.job_id, created.revision)
        .map_err(|error| (created.revision, error))?;
    let connection = task
        .storage
        .get_provider_connection(&task.connection_id)
        .map_err(|error| (fetching.revision, error))?;
    let template = task
        .storage
        .get_provider_template(&connection.template_id, connection.template_version)
        .map_err(|error| (fetching.revision, error))?;
    validate_provider_template(&template).map_err(|error| (fetching.revision, error))?;
    let listing = AdapterRegistry::new()
        .build_model_listing(&template, &connection)
        .map_err(|error| (fetching.revision, error))?;
    let listed = listing
        .list_models(ModelListRequest::new(
            task.credential.as_deref(),
            task.cancel_receiver.clone(),
        ))
        .await
        .map_err(|error| (fetching.revision, error))?;
    ensure_model_list_does_not_reflect_credential(&listed, task.credential.as_deref())
        .map_err(|error| (fetching.revision, error))?;
    if *task.cancel_receiver.borrow() {
        return Err((
            fetching.revision,
            CoreError::new(CoreErrorCode::Cancelled, "operation was cancelled", true),
        ));
    }

    let current_connection = task
        .storage
        .get_provider_connection(&task.connection_id)
        .map_err(|error| (fetching.revision, error))?;
    if current_connection != connection {
        return Err((
            fetching.revision,
            CoreError::invalid("provider connection changed while its model list was refreshing"),
        ));
    }
    let observed_at = Utc::now();
    let existing_routes = task
        .storage
        .list_model_routes(&task.connection_id)
        .map_err(|error| (fetching.revision, error))?;
    let (mut listed_routes, newly_seen_model_route_ids, missing_model_route_ids) =
        reconcile_input_routes(
            &task.connection_id,
            template.api_family,
            &existing_routes,
            &listed.models,
            observed_at,
        )
        .map_err(|error| (fetching.revision, error))?;
    for route in &mut listed_routes {
        route.last_reconciled_sync_job_id = Some(task.job_id.clone());
        route.metadata_sync_job_id = Some(task.job_id.clone());
    }
    let can_create_initial_preset =
        template_accepts_empty_preset(&template).map_err(|error| (fetching.revision, error))?;
    let mut initial_presets = Vec::new();
    let mut routes_requiring_preset_configuration = Vec::new();
    for route_id in &newly_seen_model_route_ids {
        if can_create_initial_preset {
            initial_presets.push(initial_generation_preset(route_id, &template, observed_at));
        } else {
            routes_requiring_preset_configuration.push(route_id.clone());
        }
    }
    let capability_observations =
        provider_api_capability_observations(&listed_routes, &listed.models, observed_at)
            .map_err(|error| (fetching.revision, error))?;
    if listed.provenance.source != ModelRecordSource::ProviderApi {
        return Err((
            fetching.revision,
            CoreError::new(
                CoreErrorCode::ProviderUnavailable,
                "provider model list contained unsupported provenance",
                false,
            ),
        ));
    }
    let review = ModelSyncReview::new(ModelSyncDiff {
        connection_id: task.connection_id.clone(),
        expected_connection: connection,
        expected_model_routes: existing_routes,
        observed_at,
        listed_routes,
        newly_seen_model_route_ids,
        missing_model_route_ids,
        initial_presets,
        capability_observations,
        routes_requiring_preset_configuration,
        provenance: ModelSyncSourceProvenance {
            source: model_record_source_name(listed.provenance.source).to_owned(),
            api_family: listed.provenance.api_family,
            api_origin: listed.provenance.api_origin,
            endpoint_path: listed.provenance.endpoint_path,
            pages_fetched: listed.pages_fetched,
            response_bytes: listed.response_bytes,
        },
    })
    .map_err(|message| (fetching.revision, CoreError::internal(message)))?;
    task.storage
        .store_model_sync_review(&task.job_id, fetching.revision, &review)
        .map_err(|error| (fetching.revision, error))?;
    Ok(())
}
