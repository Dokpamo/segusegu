use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    sync::{Arc, Mutex, MutexGuard},
};

use lorepia_shell_api::{
    BootstrapDto, ProviderCatalogImportPlanDto, ProviderCatalogImportResultDto, ShellApi,
    SignedCatalogEnvelope,
};
use tauri_plugin_lorepia_platform::StagedImport;
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::error::{CommandError, CommandResult};

const MAXIMUM_IMPORT_TICKETS: usize = 16;
const MAXIMUM_CATALOG_TICKETS: usize = 4;
const MAXIMUM_CHAT_STREAMS: usize = 32;

pub struct AppState {
    data_root: PathBuf,
    shell: Mutex<Option<ShellApi>>,
    import_tickets: Arc<Mutex<TicketStore<StagedImport>>>,
    catalog_tickets: Mutex<TicketStore<CatalogImportTicket>>,
    chat_streams: Arc<ChatStreamRegistry>,
}

pub struct CatalogImportTicket {
    pub plan: ProviderCatalogImportPlanDto,
    pub envelope: SignedCatalogEnvelope,
}

struct TicketStore<T> {
    values: HashMap<String, T>,
    reservations: HashSet<String>,
    capacity: usize,
}

pub(crate) struct TicketReservation<T> {
    ticket_id: String,
    value: Option<T>,
    store: Arc<Mutex<TicketStore<T>>>,
}

struct ChatStreamRegistry {
    slots: Mutex<HashMap<String, ChatStreamSlot>>,
    capacity: usize,
}

struct ChatStreamSlot {
    marker: Arc<()>,
    dispose: Option<oneshot::Sender<()>>,
}

/// Owns one bounded renderer subscription without owning its Core generation.
///
/// Dropping this value unregisters only the forwarding receiver. Explicit Core
/// cancellation remains a separate command.
pub(crate) struct ChatStreamRegistration {
    stream_id: String,
    marker: Arc<()>,
    dispose: oneshot::Receiver<()>,
    registry: Arc<ChatStreamRegistry>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TicketInsertError {
    Duplicate,
    Busy,
}

impl<T> TicketStore<T> {
    fn new(capacity: usize) -> Self {
        Self {
            values: HashMap::new(),
            reservations: HashSet::new(),
            capacity,
        }
    }

    fn insert(&mut self, id: String, value: T) -> Result<(), TicketInsertError> {
        if self.values.contains_key(&id) || self.reservations.contains(&id) {
            return Err(TicketInsertError::Duplicate);
        }
        if self.values.len() + self.reservations.len() >= self.capacity {
            return Err(TicketInsertError::Busy);
        }
        self.values.insert(id, value);
        Ok(())
    }

    fn take(&mut self, id: &str) -> Option<T> {
        self.values.remove(id)
    }

    fn reserve(&mut self, id: &str) -> Option<T> {
        let value = self.values.remove(id)?;
        let inserted = self.reservations.insert(id.to_owned());
        debug_assert!(inserted, "a live ticket cannot already be reserved");
        Some(value)
    }

    fn release_reservation(&mut self, id: &str) -> bool {
        self.reservations.remove(id)
    }

    fn restore_reservation(&mut self, id: &str, value: T) -> bool {
        if !self.reservations.remove(id) || self.values.contains_key(id) {
            return false;
        }
        self.values.insert(id.to_owned(), value);
        true
    }
}

impl ChatStreamRegistry {
    fn new(capacity: usize) -> Self {
        Self {
            slots: Mutex::new(HashMap::new()),
            capacity,
        }
    }

    fn register(self: &Arc<Self>, stream_id: &str) -> CommandResult<ChatStreamRegistration> {
        validate_stream_id(stream_id)?;
        let mut slots = self.slots.lock().map_err(|_| CommandError::internal())?;
        if slots.contains_key(stream_id) {
            return Err(CommandError::invalid_input());
        }
        if slots.len() >= self.capacity {
            return Err(CommandError::busy());
        }

        let marker = Arc::new(());
        let (dispose, dispose_receiver) = oneshot::channel();
        slots.insert(
            stream_id.to_owned(),
            ChatStreamSlot {
                marker: Arc::clone(&marker),
                dispose: Some(dispose),
            },
        );
        Ok(ChatStreamRegistration {
            stream_id: stream_id.to_owned(),
            marker,
            dispose: dispose_receiver,
            registry: Arc::clone(self),
        })
    }

    fn dispose(&self, stream_id: &str) -> CommandResult<bool> {
        validate_stream_id(stream_id)?;
        let mut slots = self.slots.lock().map_err(|_| CommandError::internal())?;
        let Some(slot) = slots.get_mut(stream_id) else {
            return Ok(false);
        };
        let Some(dispose) = slot.dispose.take() else {
            return Ok(false);
        };
        let _ = dispose.send(());
        Ok(true)
    }

    fn finish(&self, stream_id: &str, marker: &Arc<()>) {
        let Ok(mut slots) = self.slots.lock() else {
            return;
        };
        if slots
            .get(stream_id)
            .is_some_and(|slot| Arc::ptr_eq(&slot.marker, marker))
        {
            slots.remove(stream_id);
        }
    }
}

impl ChatStreamRegistration {
    pub(crate) async fn disposed(&mut self) {
        let _ = (&mut self.dispose).await;
    }
}

impl Drop for ChatStreamRegistration {
    fn drop(&mut self) {
        self.registry.finish(&self.stream_id, &self.marker);
    }
}

fn validate_stream_id(stream_id: &str) -> CommandResult<()> {
    if Uuid::parse_str(stream_id).is_ok_and(|value| value.to_string() == stream_id) {
        Ok(())
    } else {
        Err(CommandError::invalid_input())
    }
}

impl<T> TicketReservation<T> {
    fn new(ticket_id: String, value: T, store: Arc<Mutex<TicketStore<T>>>) -> Self {
        Self {
            ticket_id,
            value: Some(value),
            store,
        }
    }

    pub(crate) fn value(&self) -> &T {
        self.value
            .as_ref()
            .expect("a live reservation retains its ticket value")
    }

    pub(crate) fn complete(mut self) -> CommandResult<()> {
        let released = self
            .store
            .lock()
            .map_err(|_| CommandError::internal())?
            .release_reservation(&self.ticket_id);
        if !released {
            return Err(CommandError::internal());
        }
        drop(self.value.take());
        Ok(())
    }
}

impl<T> Drop for TicketReservation<T> {
    fn drop(&mut self) {
        let Some(value) = self.value.take() else {
            return;
        };
        let mut tickets = self
            .store
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = tickets.restore_reservation(&self.ticket_id, value);
    }
}

impl AppState {
    pub fn new(data_root: PathBuf) -> Self {
        Self {
            data_root,
            shell: Mutex::new(None),
            import_tickets: Arc::new(Mutex::new(TicketStore::new(MAXIMUM_IMPORT_TICKETS))),
            catalog_tickets: Mutex::new(TicketStore::new(MAXIMUM_CATALOG_TICKETS)),
            chat_streams: Arc::new(ChatStreamRegistry::new(MAXIMUM_CHAT_STREAMS)),
        }
    }

    /// Open Core on demand and cache only a successful owner.
    pub fn bootstrap(&self) -> CommandResult<BootstrapDto> {
        let mut slot = self
            .shell
            .lock()
            .map_err(|_| CommandError::core_unavailable())?;
        if slot.is_none() {
            let shell = ShellApi::open_data_root(&self.data_root).map_err(CommandError::from)?;
            *slot = Some(shell);
        }
        slot.as_ref()
            .expect("successful Core is cached")
            .bootstrap()
            .map_err(Into::into)
    }

    pub fn shell(&self) -> CommandResult<ShellApi> {
        self.shell
            .lock()
            .map_err(|_| CommandError::core_unavailable())?
            .as_ref()
            .cloned()
            .ok_or_else(CommandError::core_unavailable)
    }

    pub(crate) fn register_chat_stream(
        &self,
        stream_id: &str,
    ) -> CommandResult<ChatStreamRegistration> {
        self.chat_streams.register(stream_id)
    }

    pub(crate) fn dispose_chat_stream(&self, stream_id: &str) -> CommandResult<bool> {
        self.chat_streams.dispose(stream_id)
    }

    pub fn insert_import_ticket(
        &self,
        ticket_id: String,
        staged: StagedImport,
    ) -> CommandResult<()> {
        let mut tickets = self.tickets()?;
        insert_ticket(&mut tickets, ticket_id, staged)
    }

    pub fn take_import_ticket(&self, ticket_id: &str) -> CommandResult<StagedImport> {
        self.tickets()?
            .take(ticket_id)
            .ok_or_else(CommandError::invalid_input)
    }

    pub(crate) fn reserve_import_ticket(
        &self,
        ticket_id: &str,
    ) -> CommandResult<TicketReservation<StagedImport>> {
        let value = self
            .tickets()?
            .reserve(ticket_id)
            .ok_or_else(CommandError::invalid_input)?;
        Ok(TicketReservation::new(
            ticket_id.to_owned(),
            value,
            Arc::clone(&self.import_tickets),
        ))
    }

    fn tickets(&self) -> CommandResult<MutexGuard<'_, TicketStore<StagedImport>>> {
        self.import_tickets
            .lock()
            .map_err(|_| CommandError::internal())
    }

    pub fn insert_catalog_ticket(
        &self,
        ticket_id: String,
        ticket: CatalogImportTicket,
    ) -> CommandResult<()> {
        let mut tickets = self.catalog_tickets()?;
        insert_ticket(&mut tickets, ticket_id, ticket)
    }

    pub fn take_catalog_ticket(&self, ticket_id: &str) -> CommandResult<CatalogImportTicket> {
        self.catalog_tickets()?
            .take(ticket_id)
            .ok_or_else(CommandError::invalid_input)
    }

    pub fn discard_catalog_ticket(&self, ticket_id: &str) -> CommandResult<()> {
        self.take_catalog_ticket(ticket_id).map(drop)
    }

    /// Preserve the exact verified envelope and plan when Core rejects an
    /// activation so the frontend can explicitly retry or discard it.
    pub fn activate_catalog_ticket(
        &self,
        shell: &ShellApi,
        ticket_id: &str,
    ) -> CommandResult<ProviderCatalogImportResultDto> {
        let mut tickets = self.catalog_tickets()?;
        let ticket = tickets
            .take(ticket_id)
            .ok_or_else(CommandError::invalid_input)?;
        match shell.activate_signed_provider_catalog_import(ticket.plan.clone(), &ticket.envelope) {
            Ok(result) => Ok(result),
            Err(error) => {
                // The slot was removed while this same mutex was held, so
                // reinsertion cannot race the explicit capacity bound.
                tickets
                    .insert(ticket_id.to_owned(), ticket)
                    .expect("catalog retry slot remains reserved");
                Err(error.into())
            }
        }
    }

    fn catalog_tickets(&self) -> CommandResult<MutexGuard<'_, TicketStore<CatalogImportTicket>>> {
        self.catalog_tickets
            .lock()
            .map_err(|_| CommandError::internal())
    }
}

fn insert_ticket<T>(store: &mut TicketStore<T>, id: String, value: T) -> CommandResult<()> {
    store.insert(id, value).map_err(|error| match error {
        TicketInsertError::Duplicate => CommandError::invalid_input(),
        TicketInsertError::Busy => CommandError::busy(),
    })
}

impl Drop for AppState {
    fn drop(&mut self) {
        if let Ok(slot) = self.shell.get_mut() {
            let _ = slot.take();
        }
    }
}

/// Reattachment remains closed until Core can atomically validate the live
/// generation route and establish a terminal-safe event watermark.
pub(crate) fn reject_generation_reattachment() -> CommandResult<()> {
    Err(CommandError::generation_reattachment_unavailable())
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };

    use lorepia_shell_api::ShellApi;
    use tempfile::tempdir;
    use uuid::Uuid;

    use super::AppState;
    use super::{
        ChatStreamRegistry, MAXIMUM_CHAT_STREAMS, TicketInsertError, TicketReservation,
        TicketStore, reject_generation_reattachment,
    };

    struct DropProbe(Arc<AtomicUsize>);

    impl Drop for DropProbe {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn bootstrap_is_lazy_and_drop_releases_core_owner() {
        let root = tempdir().expect("temporary root");
        let state = AppState::new(root.path().to_path_buf());
        assert!(state.shell().is_err());
        state.bootstrap().expect("bootstrap");
        assert!(state.shell().is_ok());
        drop(state);

        ShellApi::open_data_root(root.path()).expect("owner released after state drop");
    }

    #[test]
    fn ticket_store_is_bounded_and_never_replaces_a_live_ticket() {
        let dropped = Arc::new(AtomicUsize::new(0));
        let mut tickets = TicketStore::new(1);
        tickets
            .insert("one".to_owned(), DropProbe(Arc::clone(&dropped)))
            .expect("first");
        assert_eq!(
            tickets.insert("one".to_owned(), DropProbe(Arc::clone(&dropped))),
            Err(TicketInsertError::Duplicate)
        );
        assert_eq!(
            tickets.insert("two".to_owned(), DropProbe(Arc::clone(&dropped))),
            Err(TicketInsertError::Busy)
        );
        assert_eq!(dropped.load(Ordering::SeqCst), 2);

        let consumed = tickets.take("one").expect("consume");
        assert_eq!(dropped.load(Ordering::SeqCst), 2);
        drop(consumed);
        assert_eq!(dropped.load(Ordering::SeqCst), 3);
    }

    #[test]
    fn dropping_ticket_store_discards_every_remaining_value() {
        let dropped = Arc::new(AtomicUsize::new(0));
        {
            let mut tickets = TicketStore::new(2);
            tickets
                .insert("one".to_owned(), DropProbe(Arc::clone(&dropped)))
                .expect("one");
            tickets
                .insert("two".to_owned(), DropProbe(Arc::clone(&dropped)))
                .expect("two");
        }
        assert_eq!(dropped.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn reservation_keeps_a_full_store_full_and_drop_restores_the_same_ticket() {
        let dropped = Arc::new(AtomicUsize::new(0));
        let tickets = Arc::new(std::sync::Mutex::new(TicketStore::new(1)));
        tickets
            .lock()
            .expect("tickets")
            .insert("one".to_owned(), DropProbe(Arc::clone(&dropped)))
            .expect("first");
        let value = tickets
            .lock()
            .expect("tickets")
            .reserve("one")
            .expect("reserve");
        let reservation = TicketReservation::new("one".to_owned(), value, Arc::clone(&tickets));

        let concurrent_store = Arc::clone(&tickets);
        let concurrent_dropped = Arc::clone(&dropped);
        let insertion = std::thread::spawn(move || {
            concurrent_store
                .lock()
                .expect("tickets")
                .insert("two".to_owned(), DropProbe(Arc::clone(&concurrent_dropped)))
        })
        .join()
        .expect("insertion worker");
        assert_eq!(insertion, Err(TicketInsertError::Busy));
        assert_eq!(dropped.load(Ordering::SeqCst), 1);

        drop(reservation);
        let mut tickets = tickets.lock().expect("tickets");
        assert!(tickets.reservations.is_empty());
        assert!(tickets.values.contains_key("one"));
        assert_eq!(
            tickets.insert("one".to_owned(), DropProbe(Arc::clone(&dropped))),
            Err(TicketInsertError::Duplicate)
        );
        assert_eq!(dropped.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn completing_a_reservation_releases_capacity() {
        let dropped = Arc::new(AtomicUsize::new(0));
        let tickets = Arc::new(std::sync::Mutex::new(TicketStore::new(1)));
        tickets
            .lock()
            .expect("tickets")
            .insert("one".to_owned(), DropProbe(Arc::clone(&dropped)))
            .expect("first");
        let value = tickets
            .lock()
            .expect("tickets")
            .reserve("one")
            .expect("reserve");
        TicketReservation::new("one".to_owned(), value, Arc::clone(&tickets))
            .complete()
            .expect("complete");

        assert_eq!(dropped.load(Ordering::SeqCst), 1);
        tickets
            .lock()
            .expect("tickets")
            .insert("two".to_owned(), DropProbe(Arc::clone(&dropped)))
            .expect("released capacity");
    }

    #[tokio::test]
    async fn chat_stream_registry_is_bounded_and_disposal_targets_one_registration() {
        const FIRST_ID: &str = "00000000-0000-4000-8000-000000000001";
        const SECOND_ID: &str = "00000000-0000-4000-8000-000000000002";

        let registry = Arc::new(ChatStreamRegistry::new(1));
        let mut first = registry.register(FIRST_ID).expect("first registration");
        assert_eq!(
            registry
                .register(FIRST_ID)
                .err()
                .expect("duplicate identifier")
                .code,
            "invalid_input"
        );
        assert_eq!(
            registry
                .register(SECOND_ID)
                .err()
                .expect("bounded registry")
                .code,
            "busy"
        );

        assert!(registry.dispose(FIRST_ID).expect("dispose first"));
        assert_eq!(
            registry
                .register(FIRST_ID)
                .err()
                .expect("disposing registration still owns its bounded slot")
                .code,
            "invalid_input"
        );
        first.disposed().await;
        drop(first);

        let second_lifetime = registry
            .register(FIRST_ID)
            .expect("identifier may be reused after forwarder exit");
        assert_eq!(
            registry
                .register(FIRST_ID)
                .err()
                .expect("old cleanup must not remove a reused identifier")
                .code,
            "invalid_input"
        );
        assert!(registry.dispose(FIRST_ID).expect("dispose second lifetime"));
        assert!(!registry.dispose(FIRST_ID).expect("idempotent disposal"));
        drop(second_lifetime);
        assert!(!registry.dispose(FIRST_ID).expect("idempotent disposal"));
    }

    #[test]
    fn chat_stream_registry_rejects_noncanonical_identifiers() {
        let registry = Arc::new(ChatStreamRegistry::new(1));
        assert_eq!(
            registry
                .register("not-an-opaque-stream-id")
                .err()
                .expect("invalid stream identifier")
                .code,
            "invalid_input"
        );
    }

    #[test]
    fn rejected_generation_reattachments_never_consume_chat_stream_capacity() {
        let registry = Arc::new(ChatStreamRegistry::new(MAXIMUM_CHAT_STREAMS));

        for _ in 0..(MAXIMUM_CHAT_STREAMS * 2) {
            let error =
                reject_generation_reattachment().expect_err("reattachment must remain fail-closed");
            assert_eq!(error.code, "generation_reattachment_unavailable");
        }

        let registrations = (0..MAXIMUM_CHAT_STREAMS)
            .map(|index| {
                registry
                    .register(&Uuid::from_u128(index as u128 + 1).to_string())
                    .expect("rejected reattachments leave capacity for initial streams")
            })
            .collect::<Vec<_>>();
        assert_eq!(
            registry
                .register(&Uuid::from_u128(MAXIMUM_CHAT_STREAMS as u128 + 1).to_string())
                .err()
                .expect("the registry retains its original independent bound")
                .code,
            "busy"
        );
        drop(registrations);
    }
}
