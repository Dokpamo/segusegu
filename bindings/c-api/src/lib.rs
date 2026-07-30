//! Stable C ABI consumed by the Windows P/Invoke wrapper.

#![allow(unsafe_code)]
#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    cell::RefCell,
    panic::{AssertUnwindSafe, catch_unwind},
    path::Path,
    ptr, slice, str,
    sync::Mutex,
};

use lorepia_engine::{
    AppSettings, ChatEvent, ConversationId, Core, CoreConfig, CoreError, CoreErrorCode, CoreResult,
    GenerationId, InspectionId, ProviderProfile,
};
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

pub const ABI_VERSION: u32 = 3;

const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_UNSUPPORTED_CONTENT: i32 = 2;
const STATUS_UNSAFE_ARCHIVE: i32 = 3;
const STATUS_NOT_FOUND: i32 = 4;
const STATUS_PERMISSION_DENIED: i32 = 5;
const STATUS_STORAGE_UNAVAILABLE: i32 = 6;
const STATUS_STORAGE_CORRUPTED: i32 = 7;
const STATUS_PROVIDER_AUTH_FAILED: i32 = 8;
const STATUS_PROVIDER_RATE_LIMITED: i32 = 9;
const STATUS_PROVIDER_UNAVAILABLE: i32 = 10;
const STATUS_NETWORK_UNAVAILABLE: i32 = 11;
const STATUS_CANCELLED: i32 = 12;
const STATUS_INTERNAL_ERROR: i32 = 255;
const MAX_EVENT_BATCH_SIZE: u32 = 1_024;

thread_local! {
    static THREAD_LAST_ERROR: RefCell<Option<ErrorPayload>> = const { RefCell::new(None) };
}

#[repr(C)]
pub struct LorepiaBuffer {
    pub ptr: *mut u8,
    pub len: usize,
}

impl Default for LorepiaBuffer {
    fn default() -> Self {
        Self {
            ptr: ptr::null_mut(),
            len: 0,
        }
    }
}

pub struct LorepiaCoreHandle {
    core: Core,
    events: Mutex<broadcast::Receiver<ChatEvent>>,
    last_error: Mutex<Option<ErrorPayload>>,
}

#[derive(Deserialize)]
struct CApiConfig {
    data_root: String,
}

#[derive(Clone, Serialize)]
struct ErrorPayload {
    status: i32,
    code: String,
    message: String,
    recoverable: bool,
    operation_id: String,
}

impl ErrorPayload {
    fn from_core(error: CoreError) -> Self {
        Self {
            status: status_for_error(error.code),
            code: error.code.as_str().to_owned(),
            message: error.message,
            recoverable: error.recoverable,
            operation_id: error.operation_id,
        }
    }
}

#[derive(Serialize)]
struct EventBatch {
    events: Vec<ChatEvent>,
    dropped_events: u64,
}

#[unsafe(no_mangle)]
pub extern "C" fn lorepia_abi_version() -> u32 {
    ABI_VERSION
}

/// Creates a core from UTF-8 JSON.
///
/// # Safety
///
/// `config_json` must reference `config_len` readable bytes and `out_core` must
/// be a valid writable pointer. The returned handle is owned by the caller and
/// must be destroyed exactly once with [`lorepia_core_destroy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_create(
    config_json: *const u8,
    config_len: usize,
    out_core: *mut *mut LorepiaCoreHandle,
) -> i32 {
    clear_thread_error();
    if out_core.is_null() {
        return fail_without_handle(CoreError::invalid("out_core must not be null"));
    }
    // SAFETY: `out_core` was checked and is writable by caller contract.
    unsafe { out_core.write(ptr::null_mut()) };

    match catch_unwind(AssertUnwindSafe(|| {
        // SAFETY: the caller guarantees the input range is readable.
        let config_text = unsafe { read_utf8(config_json, config_len, "config_json") }?;
        let config: CApiConfig = serde_json::from_str(config_text)
            .map_err(|_| CoreError::invalid("config_json must be valid configuration JSON"))?;
        if config.data_root.trim().is_empty() || !Path::new(&config.data_root).is_absolute() {
            return Err(CoreError::invalid(
                "config_json.data_root must be a non-empty absolute path",
            ));
        }
        let core = Core::open(CoreConfig::new(config.data_root))?;
        let events = core.subscribe_events();
        let handle = Box::new(LorepiaCoreHandle {
            core,
            events: Mutex::new(events),
            last_error: Mutex::new(None),
        });
        // SAFETY: `out_core` is a valid writable pointer by caller contract.
        unsafe { out_core.write(Box::into_raw(handle)) };
        Ok(())
    })) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => fail_without_handle(error),
        Err(_) => fail_without_handle(CoreError::internal(
            "panic was contained at the C ABI boundary",
        )),
    }
}

/// Destroys an owned core handle. A null handle is ignored.
///
/// # Safety
///
/// `core` must be null or a live handle returned by this library and not
/// previously destroyed. No call may race with destruction.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_destroy(core: *mut LorepiaCoreHandle) {
    if !core.is_null() {
        // SAFETY: guaranteed by the caller contract.
        drop(unsafe { Box::from_raw(core) });
    }
}

/// Returns the last structured error as UTF-8 JSON.
///
/// Pass a live handle for the most recent error on that handle. Pass null to
/// retrieve a create-time or null-handle error for the current thread. A JSON
/// `null` means there is no recorded error.
///
/// # Safety
///
/// A non-null `core` must be a live handle and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_last_error_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    if out_buffer.is_null() {
        return fail_without_handle(CoreError::invalid("out_buffer must not be null"));
    }
    // SAFETY: `out_buffer` is writable by caller contract.
    unsafe { out_buffer.write(LorepiaBuffer::default()) };

    match catch_unwind(AssertUnwindSafe(|| {
        let error = if core.is_null() {
            THREAD_LAST_ERROR.with(|slot| slot.borrow().clone())
        } else {
            // SAFETY: a non-null handle is live by caller contract.
            last_error(unsafe { &*core })
        };
        let bytes = serde_json::to_vec(&error)
            .map_err(|_| CoreError::internal("cannot serialize the last C ABI error"))?;
        // SAFETY: `out_buffer` was initialized above and remains writable.
        unsafe { write_buffer(out_buffer, bytes) }
    })) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => fail_without_handle(error),
        Err(_) => fail_without_handle(CoreError::internal(
            "panic was contained while reading the last C ABI error",
        )),
    }
}

/// Returns the core version as an owned UTF-8 buffer.
///
/// # Safety
///
/// `core` must be a live handle and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_version(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            prepare_output(out_buffer)?;
            write_buffer(
                out_buffer,
                lorepia_engine::core_version().as_bytes().to_vec(),
            )?;
            let _ = handle;
            Ok(())
        })
    }
}

/// Serializes the health report as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be a live handle and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_health_check_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe { core_json(core, out_buffer, |handle| handle.core.health_check()) }
}

/// Inspects a staged content file and returns the review model as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `staged_path` must reference `staged_path_len` readable
/// UTF-8 bytes, and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_inspect_import_json(
    core: *const LorepiaCoreHandle,
    staged_path: *const u8,
    staged_path_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let path = read_utf8(staged_path, staged_path_len, "staged_path")?;
            handle.core.inspect_import(path)
        })
    }
}

/// Commits a previously approved inspection and returns the character as JSON.
///
/// # Safety
///
/// `core` must be live, `inspection_id` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_commit_import_json(
    core: *const LorepiaCoreHandle,
    inspection_id: *const u8,
    inspection_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let id = read_utf8(inspection_id, inspection_id_len, "inspection_id")?;
            handle.core.commit_import(&InspectionId(id.to_owned()))
        })
    }
}

/// Discards a pending inspection and its core-owned staging snapshot.
///
/// # Safety
///
/// `core` must be live and `inspection_id` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_discard_import(
    core: *const LorepiaCoreHandle,
    inspection_id: *const u8,
    inspection_id_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let id = read_utf8(inspection_id, inspection_id_len, "inspection_id")?;
            handle.core.discard_import(&InspectionId(id.to_owned()))
        })
    }
}

/// Serializes the local character list as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_characters_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe { core_json(core, out_buffer, |handle| handle.core.list_characters()) }
}

/// Serializes one local character as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `character_id` must reference readable UTF-8 bytes, and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_character_json(
    core: *const LorepiaCoreHandle,
    character_id: *const u8,
    character_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let id = read_utf8(character_id, character_id_len, "character_id")?;
            handle.core.get_character(id)
        })
    }
}

/// Opens a new conversation for a character and returns it as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `character_id` must reference readable UTF-8 bytes, and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_open_conversation_json(
    core: *const LorepiaCoreHandle,
    character_id: *const u8,
    character_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let id = read_utf8(character_id, character_id_len, "character_id")?;
            handle.core.open_conversation(id)
        })
    }
}

/// Serializes all local conversations as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_conversations_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe { core_json(core, out_buffer, |handle| handle.core.list_conversations()) }
}

/// Serializes all messages in a conversation as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `conversation_id` must reference readable UTF-8 bytes,
/// and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_messages_json(
    core: *const LorepiaCoreHandle,
    conversation_id: *const u8,
    conversation_id_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let id = read_utf8(conversation_id, conversation_id_len, "conversation_id")?;
            handle.core.list_messages(&ConversationId(id.to_owned()))
        })
    }
}

/// Starts one generation and returns its generation ID as UTF-8 JSON.
///
/// Set `credential_present` to zero and pass a null pointer with zero length
/// when no credential is available. Set it to one for a present credential.
///
/// # Safety
///
/// `core` must be live. Every present text pointer must reference its declared
/// number of readable UTF-8 bytes. `out_buffer` must be writable.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn lorepia_core_send_message_json(
    core: *const LorepiaCoreHandle,
    conversation_id: *const u8,
    conversation_id_len: usize,
    text: *const u8,
    text_len: usize,
    provider_profile_id: *const u8,
    provider_profile_id_len: usize,
    credential: *const u8,
    credential_len: usize,
    credential_present: u8,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let conversation_id =
                read_utf8(conversation_id, conversation_id_len, "conversation_id")?;
            let text = read_utf8(text, text_len, "text")?;
            let provider_profile_id = read_utf8(
                provider_profile_id,
                provider_profile_id_len,
                "provider_profile_id",
            )?;
            let credential =
                read_optional_utf8(credential, credential_len, credential_present, "credential")?;
            handle.core.send_message(
                &ConversationId(conversation_id.to_owned()),
                text,
                provider_profile_id,
                credential.map(str::to_owned),
            )
        })
    }
}

/// Cancels an active generation.
///
/// # Safety
///
/// `core` must be live and `generation_id` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_cancel_generation(
    core: *const LorepiaCoreHandle,
    generation_id: *const u8,
    generation_id_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let id = read_utf8(generation_id, generation_id_len, "generation_id")?;
            handle.core.cancel_generation(&GenerationId(id.to_owned()))
        })
    }
}

/// Returns up to `max_events` queued events as one UTF-8 JSON batch.
///
/// The result has `events` and `dropped_events` fields. A non-zero
/// `dropped_events` value tells the caller to refresh persisted messages.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_poll_events_json(
    core: *const LorepiaCoreHandle,
    max_events: u32,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            if max_events == 0 || max_events > MAX_EVENT_BATCH_SIZE {
                return Err(CoreError::invalid("max_events must be between 1 and 1024"));
            }
            let mut receiver = lock(&handle.events, "event receiver")?;
            let mut events = Vec::with_capacity(max_events as usize);
            let mut dropped_events = 0_u64;
            while events.len() < max_events as usize {
                match receiver.try_recv() {
                    Ok(event) => events.push(event),
                    Err(
                        broadcast::error::TryRecvError::Empty
                        | broadcast::error::TryRecvError::Closed,
                    ) => break,
                    Err(broadcast::error::TryRecvError::Lagged(count)) => {
                        dropped_events = dropped_events.saturating_add(count);
                    }
                }
            }
            Ok(EventBatch {
                events,
                dropped_events,
            })
        })
    }
}

/// Serializes the current app settings as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_get_settings_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe { core_json(core, out_buffer, |handle| handle.core.get_settings()) }
}

/// Replaces app settings from UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `settings_json` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_update_settings_json(
    core: *const LorepiaCoreHandle,
    settings_json: *const u8,
    settings_json_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let json = read_utf8(settings_json, settings_json_len, "settings_json")?;
            let settings: AppSettings = parse_json(json, "settings_json")?;
            handle.core.update_settings(&settings)
        })
    }
}

/// Serializes all provider profiles as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live and `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_provider_profiles_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            handle.core.list_provider_profiles()
        })
    }
}

/// Creates or replaces a provider profile from UTF-8 JSON and returns the
/// normalized profile as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be live, `profile_json` must reference readable UTF-8 bytes, and
/// `out_buffer` must be writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_upsert_provider_profile_json(
    core: *const LorepiaCoreHandle,
    profile_json: *const u8,
    profile_json_len: usize,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        core_json(core, out_buffer, |handle| {
            let json = read_utf8(profile_json, profile_json_len, "profile_json")?;
            let profile: ProviderProfile = parse_json(json, "profile_json")?;
            handle.core.upsert_provider_profile(profile)
        })
    }
}

/// Deletes a provider profile.
///
/// # Safety
///
/// `core` must be live and `profile_id` must reference readable UTF-8 bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_delete_provider_profile(
    core: *const LorepiaCoreHandle,
    profile_id: *const u8,
    profile_id_len: usize,
) -> i32 {
    // SAFETY: pointer validity is part of this public function's contract.
    unsafe {
        run_core_call(core, |handle| {
            let id = read_utf8(profile_id, profile_id_len, "profile_id")?;
            handle.core.delete_provider_profile(id)
        })
    }
}

/// Releases a buffer returned by this library. An empty buffer is ignored.
///
/// # Safety
///
/// `buffer` must be empty or an unmodified buffer returned by this library and
/// not previously freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_buffer_free(buffer: LorepiaBuffer) {
    if !buffer.ptr.is_null() && buffer.len != 0 {
        let raw = ptr::slice_from_raw_parts_mut(buffer.ptr, buffer.len);
        // SAFETY: guaranteed by the caller contract and allocated by
        // `write_buffer` as `Box<[u8]>`.
        drop(unsafe { Box::from_raw(raw) });
    }
}

unsafe fn core_json<T: Serialize>(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
    operation: impl FnOnce(&LorepiaCoreHandle) -> CoreResult<T>,
) -> i32 {
    // SAFETY: callers forward their documented pointer contracts.
    unsafe {
        run_core_call(core, |handle| {
            prepare_output(out_buffer)?;
            let value = operation(handle)?;
            let bytes = serde_json::to_vec(&value)
                .map_err(|_| CoreError::internal("cannot serialize C ABI response JSON"))?;
            write_buffer(out_buffer, bytes)
        })
    }
}

unsafe fn run_core_call(
    core: *const LorepiaCoreHandle,
    operation: impl FnOnce(&LorepiaCoreHandle) -> CoreResult<()>,
) -> i32 {
    if core.is_null() {
        return fail_without_handle(CoreError::invalid("core handle must not be null"));
    }
    // SAFETY: a non-null handle is live by caller contract.
    let handle = unsafe { &*core };
    replace_last_error(handle, None);
    match catch_unwind(AssertUnwindSafe(|| operation(handle))) {
        Ok(Ok(())) => STATUS_OK,
        Ok(Err(error)) => fail_with_handle(handle, error),
        Err(_) => fail_with_handle(
            handle,
            CoreError::internal("panic was contained at the C ABI boundary"),
        ),
    }
}

unsafe fn prepare_output(out_buffer: *mut LorepiaBuffer) -> CoreResult<()> {
    if out_buffer.is_null() {
        return Err(CoreError::invalid("out_buffer must not be null"));
    }
    // SAFETY: `out_buffer` is writable by caller contract.
    unsafe { out_buffer.write(LorepiaBuffer::default()) };
    Ok(())
}

unsafe fn write_buffer(out_buffer: *mut LorepiaBuffer, bytes: Vec<u8>) -> CoreResult<()> {
    if out_buffer.is_null() {
        return Err(CoreError::invalid("out_buffer must not be null"));
    }
    if bytes.is_empty() {
        // SAFETY: `out_buffer` is writable by caller contract.
        unsafe { out_buffer.write(LorepiaBuffer::default()) };
        return Ok(());
    }
    let mut boxed = bytes.into_boxed_slice();
    let buffer = LorepiaBuffer {
        ptr: boxed.as_mut_ptr(),
        len: boxed.len(),
    };
    std::mem::forget(boxed);
    // SAFETY: `out_buffer` is writable by caller contract.
    unsafe { out_buffer.write(buffer) };
    Ok(())
}

unsafe fn read_utf8<'a>(value: *const u8, value_len: usize, field: &str) -> CoreResult<&'a str> {
    if value.is_null() {
        return Err(CoreError::invalid(format!("{field} must not be null")));
    }
    // SAFETY: the caller guarantees that the input range is readable.
    let bytes = unsafe { slice::from_raw_parts(value, value_len) };
    str::from_utf8(bytes).map_err(|_| CoreError::invalid(format!("{field} must be valid UTF-8")))
}

unsafe fn read_optional_utf8<'a>(
    value: *const u8,
    value_len: usize,
    present: u8,
    field: &str,
) -> CoreResult<Option<&'a str>> {
    match present {
        0 if value.is_null() && value_len == 0 => Ok(None),
        0 => Err(CoreError::invalid(format!(
            "{field} must be null with zero length when absent"
        ))),
        1 => {
            // SAFETY: the present optional value follows the same contract as
            // a required UTF-8 input.
            unsafe { read_utf8(value, value_len, field) }.map(Some)
        }
        _ => Err(CoreError::invalid(format!(
            "{field}_present must be zero or one"
        ))),
    }
}

fn parse_json<T: for<'de> Deserialize<'de>>(json: &str, field: &str) -> CoreResult<T> {
    serde_json::from_str(json)
        .map_err(|_| CoreError::invalid(format!("{field} must be valid JSON")))
}

fn lock<'a, T>(mutex: &'a Mutex<T>, label: &str) -> CoreResult<std::sync::MutexGuard<'a, T>> {
    mutex
        .lock()
        .map_err(|_| CoreError::internal(format!("{label} lock was poisoned")))
}

fn last_error(handle: &LorepiaCoreHandle) -> Option<ErrorPayload> {
    match handle.last_error.lock() {
        Ok(error) => error.clone(),
        Err(poisoned) => poisoned.into_inner().clone(),
    }
}

fn replace_last_error(handle: &LorepiaCoreHandle, error: Option<ErrorPayload>) {
    match handle.last_error.lock() {
        Ok(mut slot) => *slot = error,
        Err(poisoned) => *poisoned.into_inner() = error,
    }
}

fn clear_thread_error() {
    THREAD_LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = None;
    });
}

fn fail_without_handle(error: CoreError) -> i32 {
    let error = ErrorPayload::from_core(error);
    let status = error.status;
    THREAD_LAST_ERROR.with(|slot| {
        *slot.borrow_mut() = Some(error);
    });
    status
}

fn fail_with_handle(handle: &LorepiaCoreHandle, error: CoreError) -> i32 {
    let error = ErrorPayload::from_core(error);
    let status = error.status;
    replace_last_error(handle, Some(error));
    status
}

const fn status_for_error(code: CoreErrorCode) -> i32 {
    match code {
        CoreErrorCode::InvalidInput => STATUS_INVALID_ARGUMENT,
        CoreErrorCode::UnsupportedContent => STATUS_UNSUPPORTED_CONTENT,
        CoreErrorCode::UnsafeArchive => STATUS_UNSAFE_ARCHIVE,
        CoreErrorCode::NotFound => STATUS_NOT_FOUND,
        CoreErrorCode::PermissionDenied => STATUS_PERMISSION_DENIED,
        CoreErrorCode::StorageUnavailable => STATUS_STORAGE_UNAVAILABLE,
        CoreErrorCode::StorageCorrupted => STATUS_STORAGE_CORRUPTED,
        CoreErrorCode::ProviderAuthFailed => STATUS_PROVIDER_AUTH_FAILED,
        CoreErrorCode::ProviderRateLimited => STATUS_PROVIDER_RATE_LIMITED,
        CoreErrorCode::ProviderUnavailable => STATUS_PROVIDER_UNAVAILABLE,
        CoreErrorCode::NetworkUnavailable => STATUS_NETWORK_UNAVAILABLE,
        CoreErrorCode::Cancelled => STATUS_CANCELLED,
        CoreErrorCode::Internal => STATUS_INTERNAL_ERROR,
    }
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::mpsc,
        thread,
        time::{Duration, Instant},
    };

    use serde_json::Value;
    use tempfile::{NamedTempFile, tempdir};

    use super::*;

    unsafe fn create_core(root: &Path) -> *mut LorepiaCoreHandle {
        let config = serde_json::json!({
            "data_root": root.to_string_lossy()
        })
        .to_string();
        let mut handle = ptr::null_mut();
        // SAFETY: the test passes valid pointers and owns the returned handle.
        let status = unsafe { lorepia_core_create(config.as_ptr(), config.len(), &raw mut handle) };
        assert_eq!(status, STATUS_OK);
        assert!(!handle.is_null());
        handle
    }

    unsafe fn take_buffer(buffer: LorepiaBuffer) -> String {
        // SAFETY: tests call this only for a live library-owned buffer.
        let bytes = unsafe { slice::from_raw_parts(buffer.ptr, buffer.len) };
        let text = str::from_utf8(bytes).expect("UTF-8 response").to_owned();
        // SAFETY: the buffer is freed exactly once.
        unsafe { lorepia_buffer_free(buffer) };
        text
    }

    unsafe fn json_call(call: impl FnOnce(*mut LorepiaBuffer) -> i32) -> Value {
        let mut buffer = LorepiaBuffer::default();
        assert_eq!(call(&raw mut buffer), STATUS_OK);
        // SAFETY: the successful call returned one owned JSON buffer.
        serde_json::from_str(&unsafe { take_buffer(buffer) }).expect("JSON response")
    }

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

    fn start_sse_server() -> String {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind SSE server");
        let address = listener.local_addr().expect("server address");
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            read_request(&mut stream);
            let body = concat!(
                "data: {\"choices\":[{\"delta\":{\"content\":\"Hello from ABI\"}}],",
                "\"usage\":null}\n\n",
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],",
                "\"usage\":null}\n\n",
                "data: [DONE]\n\n"
            );
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n",
            )
            .expect("response head");
            write!(
                stream,
                "Content-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .expect("response body");
        });
        format!("http://{address}/v1")
    }

    fn start_stalling_sse_server() -> (String, mpsc::Receiver<()>, mpsc::Sender<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind SSE server");
        let address = listener.local_addr().expect("server address");
        let (ready_sender, ready_receiver) = mpsc::channel();
        let (stop_sender, stop_receiver) = mpsc::channel();
        thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept request");
            read_request(&mut stream);
            let event = "data: {\"choices\":[{\"delta\":{\"content\":\"부분😀\"}}]}\n\n";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n",
            )
            .expect("response head");
            write!(
                stream,
                "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n{:X}\r\n{}\r\n",
                event.len(),
                event
            )
            .expect("response chunk");
            stream.flush().expect("flush response chunk");
            ready_sender.send(()).expect("server ready");
            let _ = stop_receiver.recv_timeout(Duration::from_secs(5));
            let _ = stream.write_all(b"0\r\n\r\n");
        });
        (format!("http://{address}/v1"), ready_receiver, stop_sender)
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn c_abi_v3_exercises_import_chat_profiles_settings_and_events() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            assert_eq!(lorepia_abi_version(), 3);

            let mut version_buffer = LorepiaBuffer::default();
            assert_eq!(
                lorepia_core_version(handle, &raw mut version_buffer),
                STATUS_OK
            );
            assert_eq!(take_buffer(version_buffer), lorepia_engine::core_version());

            let health = json_call(|out| lorepia_core_health_check_json(handle, out));
            assert_eq!(health["core_version"], lorepia_engine::core_version());
            assert_eq!(health["database_open"], true);
            assert_eq!(health["data_root_writable"], true);
            assert_eq!(health["staging_writable"], true);
            assert_eq!(
                json_call(|out| lorepia_core_list_characters_json(handle, out)),
                serde_json::json!([])
            );
            assert_eq!(
                json_call(|out| lorepia_core_list_conversations_json(handle, out)),
                serde_json::json!([])
            );
            assert_eq!(
                json_call(|out| lorepia_core_list_provider_profiles_json(handle, out)),
                serde_json::json!([])
            );
            assert!(
                json_call(|out| lorepia_core_get_settings_json(handle, out))
                    ["selected_provider_profile_id"]
                    .is_null()
            );

            let name = "세구 😀 e\u{301}";
            let description = "큰문자열😀".repeat(8_192);
            let mut card = NamedTempFile::new().expect("card file");
            write!(
                card,
                r#"{{"spec":"chara_card_v3","data":{{
                    "name":"{name}",
                    "description":"{description}",
                    "personality":"unused fallback",
                    "creator":"Synthetic"
                }}}}"#
            )
            .expect("write card");
            let path = card.path().to_string_lossy();

            let discarded = json_call(|out| {
                lorepia_core_inspect_import_json(handle, path.as_ptr(), path.len(), out)
            });
            let discarded_id = discarded["id"].as_str().expect("inspection id");
            assert_eq!(
                lorepia_core_discard_import(handle, discarded_id.as_ptr(), discarded_id.len()),
                STATUS_OK
            );

            let inspection = json_call(|out| {
                lorepia_core_inspect_import_json(handle, path.as_ptr(), path.len(), out)
            });
            assert_eq!(inspection["kind"], "character_card_v3");
            assert_eq!(inspection["display_name"], name);
            assert_eq!(inspection["description"], description);
            assert!(inspection["representative_image"].is_null());
            assert_eq!(
                inspection["unsupported_optional_fields"],
                serde_json::json!(["creator", "personality"])
            );
            let inspection_id = inspection["id"].as_str().expect("inspection id");
            let character = json_call(|out| {
                lorepia_core_commit_import_json(
                    handle,
                    inspection_id.as_ptr(),
                    inspection_id.len(),
                    out,
                )
            });
            let character_id = character["id"].as_str().expect("character id");
            assert!(character["avatar_asset_hash"].is_null());

            let fetched = json_call(|out| {
                lorepia_core_get_character_json(
                    handle,
                    character_id.as_ptr(),
                    character_id.len(),
                    out,
                )
            });
            assert_eq!(fetched["name"], name);
            assert_eq!(fetched["description"], description);
            let characters = json_call(|out| lorepia_core_list_characters_json(handle, out));
            assert_eq!(characters.as_array().expect("characters").len(), 1);

            let package = Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../testdata/packages/with-avatar.charx");
            let package_path = package.to_string_lossy();
            let package_inspection = json_call(|out| {
                lorepia_core_inspect_import_json(
                    handle,
                    package_path.as_ptr(),
                    package_path.len(),
                    out,
                )
            });
            assert_eq!(
                package_inspection["representative_image"],
                serde_json::json!({
                    "logical_asset_id": "assets/avatar.png",
                    "media_type": "image/png",
                    "size_bytes": 70
                })
            );
            let package_inspection_id = package_inspection["id"]
                .as_str()
                .expect("package inspection id");
            assert_eq!(
                lorepia_core_discard_import(
                    handle,
                    package_inspection_id.as_ptr(),
                    package_inspection_id.len()
                ),
                STATUS_OK
            );

            let conversation = json_call(|out| {
                lorepia_core_open_conversation_json(
                    handle,
                    character_id.as_ptr(),
                    character_id.len(),
                    out,
                )
            });
            assert_eq!(conversation["title"], name);
            let conversation_id = conversation["id"].as_str().expect("conversation id");
            let conversations = json_call(|out| lorepia_core_list_conversations_json(handle, out));
            assert_eq!(conversations.as_array().expect("conversations").len(), 1);
            assert_eq!(
                json_call(|out| {
                    lorepia_core_list_messages_json(
                        handle,
                        conversation_id.as_ptr(),
                        conversation_id.len(),
                        out,
                    )
                }),
                serde_json::json!([])
            );

            let profile = serde_json::json!({
                "id": "local",
                "display_name": "Local test",
                "base_url": start_sse_server(),
                "model": "test",
                "timeout_seconds": 5
            })
            .to_string();
            let normalized = json_call(|out| {
                lorepia_core_upsert_provider_profile_json(
                    handle,
                    profile.as_ptr(),
                    profile.len(),
                    out,
                )
            });
            assert_eq!(normalized["id"], "local");
            let profiles = json_call(|out| lorepia_core_list_provider_profiles_json(handle, out));
            assert_eq!(profiles.as_array().expect("profiles").len(), 1);

            let settings = serde_json::json!({
                "preserve_partial_generations": false,
                "selected_provider_profile_id": "local"
            })
            .to_string();
            assert_eq!(
                lorepia_core_update_settings_json(handle, settings.as_ptr(), settings.len()),
                STATUS_OK
            );
            let loaded_settings = json_call(|out| lorepia_core_get_settings_json(handle, out));
            assert_eq!(loaded_settings["selected_provider_profile_id"], "local");

            let text = "질문😀".repeat(4_096);
            let profile_id = "local";
            let generation = json_call(|out| {
                lorepia_core_send_message_json(
                    handle,
                    conversation_id.as_ptr(),
                    conversation_id.len(),
                    text.as_ptr(),
                    text.len(),
                    profile_id.as_ptr(),
                    profile_id.len(),
                    ptr::null(),
                    0,
                    0,
                    out,
                )
            });
            assert!(generation.as_str().is_some());

            let deadline = Instant::now() + Duration::from_secs(5);
            let mut finished = false;
            let mut terminal = false;
            let mut events = Vec::new();
            while Instant::now() < deadline {
                let batch = json_call(|out| lorepia_core_poll_events_json(handle, 64, out));
                let batch_events = batch["events"].as_array().expect("events");
                finished |= batch_events
                    .iter()
                    .any(|event| event["kind"]["type"] == "generation_finished");
                terminal |= batch_events.iter().any(|event| {
                    matches!(
                        event["kind"]["type"].as_str(),
                        Some("generation_finished" | "generation_failed" | "generation_cancelled")
                    )
                });
                events.extend(batch_events.iter().cloned());
                if terminal {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
            assert!(finished, "generation did not finish: {events:?}");

            let messages = json_call(|out| {
                lorepia_core_list_messages_json(
                    handle,
                    conversation_id.as_ptr(),
                    conversation_id.len(),
                    out,
                )
            });
            let messages = messages.as_array().expect("messages");
            assert_eq!(messages.len(), 2);
            assert_eq!(messages[0]["content"], text);
            assert_eq!(messages[0]["role"], "user");
            assert!(messages[0]["parent_id"].is_null());
            assert!(messages[0]["generation_id"].is_null());
            assert_eq!(messages[1]["content"], "Hello from ABI");
            assert_eq!(messages[1]["role"], "assistant");
            assert_eq!(messages[1]["status"], "complete");
            assert!(messages[1]["generation_id"].is_string());
            assert!(
                events
                    .windows(2)
                    .all(|pair| pair[0]["sequence"].as_u64() < pair[1]["sequence"].as_u64())
            );
            assert_eq!(events[0]["kind"]["type"], "generation_started");
            assert!(
                events
                    .iter()
                    .any(|event| event["kind"]["type"] == "text_delta")
            );
            assert_eq!(
                events.last().expect("terminal event")["kind"]["type"],
                "generation_finished"
            );

            let unknown_generation = "unknown";
            assert_eq!(
                lorepia_core_cancel_generation(
                    handle,
                    unknown_generation.as_ptr(),
                    unknown_generation.len()
                ),
                STATUS_NOT_FOUND
            );
            let error = json_call(|out| lorepia_core_last_error_json(handle, out));
            assert_eq!(error["code"], "not_found");
            assert_eq!(error["status"], STATUS_NOT_FOUND);

            assert_eq!(
                lorepia_core_delete_provider_profile(handle, profile_id.as_ptr(), profile_id.len()),
                STATUS_OK
            );
            lorepia_core_destroy(handle);
        }
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn c_abi_cancels_generation_and_preserves_event_order() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            let mut card = NamedTempFile::new().expect("card file");
            write!(
                card,
                r#"{{"spec":"chara_card_v3","data":{{"name":"취소 테스트","description":"Synthetic"}}}}"#
            )
            .expect("write card");
            let path = card.path().to_string_lossy();
            let inspection = json_call(|out| {
                lorepia_core_inspect_import_json(handle, path.as_ptr(), path.len(), out)
            });
            let inspection_id = inspection["id"].as_str().expect("inspection id");
            let character = json_call(|out| {
                lorepia_core_commit_import_json(
                    handle,
                    inspection_id.as_ptr(),
                    inspection_id.len(),
                    out,
                )
            });
            let character_id = character["id"].as_str().expect("character id");
            let conversation = json_call(|out| {
                lorepia_core_open_conversation_json(
                    handle,
                    character_id.as_ptr(),
                    character_id.len(),
                    out,
                )
            });
            let conversation_id = conversation["id"].as_str().expect("conversation id");

            let (base_url, provider_ready, provider_stop) = start_stalling_sse_server();
            let profile = serde_json::json!({
                "id": "cancellation",
                "display_name": "Cancellation test",
                "base_url": base_url,
                "model": "test",
                "timeout_seconds": 5
            })
            .to_string();
            let saved_profile = json_call(|out| {
                lorepia_core_upsert_provider_profile_json(
                    handle,
                    profile.as_ptr(),
                    profile.len(),
                    out,
                )
            });
            let profile_id = saved_profile["id"].as_str().expect("profile id");
            let text = "중지해";
            let generation = json_call(|out| {
                lorepia_core_send_message_json(
                    handle,
                    conversation_id.as_ptr(),
                    conversation_id.len(),
                    text.as_ptr(),
                    text.len(),
                    profile_id.as_ptr(),
                    profile_id.len(),
                    ptr::null(),
                    0,
                    0,
                    out,
                )
            });
            let generation_id = generation.as_str().expect("generation id");
            provider_ready
                .recv_timeout(Duration::from_secs(2))
                .expect("provider started streaming");

            let deadline = Instant::now() + Duration::from_secs(5);
            let mut events = Vec::new();
            loop {
                let batch = json_call(|out| lorepia_core_poll_events_json(handle, 64, out));
                events.extend(
                    batch["events"]
                        .as_array()
                        .expect("events")
                        .iter()
                        .filter(|event| event["generation_id"] == generation_id)
                        .cloned(),
                );
                if events
                    .iter()
                    .any(|event| event["kind"]["type"] == "text_delta")
                {
                    break;
                }
                assert!(Instant::now() < deadline, "text delta did not arrive");
                thread::sleep(Duration::from_millis(10));
            }

            assert_eq!(
                lorepia_core_cancel_generation(handle, generation_id.as_ptr(), generation_id.len(),),
                STATUS_OK
            );
            loop {
                let batch = json_call(|out| lorepia_core_poll_events_json(handle, 64, out));
                events.extend(
                    batch["events"]
                        .as_array()
                        .expect("events")
                        .iter()
                        .filter(|event| event["generation_id"] == generation_id)
                        .cloned(),
                );
                if events
                    .iter()
                    .any(|event| event["kind"]["type"] == "generation_cancelled")
                {
                    break;
                }
                assert!(
                    Instant::now() < deadline,
                    "cancellation event did not arrive"
                );
                thread::sleep(Duration::from_millis(10));
            }
            let _ = provider_stop.send(());

            assert!(
                events
                    .windows(2)
                    .all(|pair| pair[0]["sequence"].as_u64() < pair[1]["sequence"].as_u64())
            );
            assert_eq!(events[0]["kind"]["type"], "generation_started");
            assert_eq!(
                events.last().expect("terminal event")["kind"]["type"],
                "generation_cancelled"
            );
            let messages = json_call(|out| {
                lorepia_core_list_messages_json(
                    handle,
                    conversation_id.as_ptr(),
                    conversation_id.len(),
                    out,
                )
            });
            let messages = messages.as_array().expect("messages");
            assert_eq!(messages[1]["content"], "부분😀");
            assert_eq!(messages[1]["status"], "cancelled");
            lorepia_core_destroy(handle);
        }
    }

    #[test]
    fn invalid_utf8_and_create_failures_have_structured_errors() {
        let root = tempdir().expect("temp root");
        // SAFETY: this test follows the documented handle and buffer lifetimes.
        unsafe {
            let handle = create_core(root.path());
            let invalid = [0xff_u8];
            let mut output = LorepiaBuffer::default();
            assert_eq!(
                lorepia_core_get_character_json(
                    handle,
                    invalid.as_ptr(),
                    invalid.len(),
                    &raw mut output,
                ),
                STATUS_INVALID_ARGUMENT
            );
            assert!(output.ptr.is_null());
            let error = json_call(|out| lorepia_core_last_error_json(handle, out));
            assert_eq!(error["code"], "invalid_input");
            lorepia_core_destroy(handle);

            let invalid_config = b"not-json";
            let mut failed_handle = ptr::null_mut();
            assert_eq!(
                lorepia_core_create(
                    invalid_config.as_ptr(),
                    invalid_config.len(),
                    &raw mut failed_handle,
                ),
                STATUS_INVALID_ARGUMENT
            );
            assert!(failed_handle.is_null());
            let error = json_call(|out| lorepia_core_last_error_json(ptr::null(), out));
            assert_eq!(error["code"], "invalid_input");
        }
    }
}
