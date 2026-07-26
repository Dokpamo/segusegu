//! Stable C ABI consumed by the Windows P/Invoke wrapper.

#![allow(unsafe_code)]
#![deny(unsafe_op_in_unsafe_fn)]

use std::{
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice,
};

use lorepia_engine::{Core, CoreConfig, CoreErrorCode};
use serde::Deserialize;

pub const ABI_VERSION: u32 = 1;
const STATUS_OK: i32 = 0;
const STATUS_INVALID_ARGUMENT: i32 = 1;
const STATUS_NOT_FOUND: i32 = 2;
const STATUS_STORAGE_ERROR: i32 = 3;
const STATUS_INTERNAL_ERROR: i32 = 255;

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

#[repr(C)]
pub struct LorepiaCoreHandle {
    core: Core,
}

#[derive(Deserialize)]
struct CApiConfig {
    data_root: String,
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
/// be a valid writable pointer. The returned handle must be destroyed exactly
/// once with [`lorepia_core_destroy`].
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_create(
    config_json: *const u8,
    config_len: usize,
    out_core: *mut *mut LorepiaCoreHandle,
) -> i32 {
    ffi_guard(|| {
        if config_json.is_null() || out_core.is_null() {
            return STATUS_INVALID_ARGUMENT;
        }
        // SAFETY: pointers were checked for null and the caller promises that
        // `config_json` references `config_len` readable bytes.
        let bytes = unsafe { slice::from_raw_parts(config_json, config_len) };
        let config: CApiConfig = match serde_json::from_slice(bytes) {
            Ok(config) => config,
            Err(_) => return STATUS_INVALID_ARGUMENT,
        };
        let core = match Core::open(CoreConfig::new(config.data_root)) {
            Ok(core) => core,
            Err(error) => return status_for_error(error.code),
        };
        let handle = Box::new(LorepiaCoreHandle { core });
        // SAFETY: `out_core` is a valid writable pointer by caller contract.
        unsafe { out_core.write(Box::into_raw(handle)) };
        STATUS_OK
    })
}

/// Destroys a handle returned by [`lorepia_core_create`]. A null handle is
/// ignored.
///
/// # Safety
///
/// `core` must be null or a live handle returned by this library and not
/// previously destroyed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_destroy(core: *mut LorepiaCoreHandle) {
    if !core.is_null() {
        // SAFETY: guaranteed by the caller contract.
        drop(unsafe { Box::from_raw(core) });
    }
}

/// Returns the core version as an owned UTF-8 buffer.
///
/// # Safety
///
/// `core` must be a live handle and `out_buffer` a writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_version(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    ffi_guard(|| {
        if core.is_null() || out_buffer.is_null() {
            return STATUS_INVALID_ARGUMENT;
        }
        write_buffer(
            out_buffer,
            lorepia_engine::core_version().as_bytes().to_vec(),
        )
    })
}

/// Serializes the health report as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be a live handle and `out_buffer` a writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_health_check_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    ffi_guard(|| {
        // SAFETY: validation and dereference are contained in `with_core_json`.
        unsafe { with_core_json(core, out_buffer, |handle| handle.core.health_check()) }
    })
}

/// Serializes the local character list as UTF-8 JSON.
///
/// # Safety
///
/// `core` must be a live handle and `out_buffer` a writable pointer.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn lorepia_core_list_characters_json(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
) -> i32 {
    ffi_guard(|| {
        // SAFETY: validation and dereference are contained in `with_core_json`.
        unsafe { with_core_json(core, out_buffer, |handle| handle.core.list_characters()) }
    })
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

unsafe fn with_core_json<T: serde::Serialize>(
    core: *const LorepiaCoreHandle,
    out_buffer: *mut LorepiaBuffer,
    operation: impl FnOnce(&LorepiaCoreHandle) -> lorepia_engine::CoreResult<T>,
) -> i32 {
    if core.is_null() || out_buffer.is_null() {
        return STATUS_INVALID_ARGUMENT;
    }
    // SAFETY: pointers were validated and are live by caller contract.
    let handle = unsafe { &*core };
    match operation(handle) {
        Ok(value) => match serde_json::to_vec(&value) {
            Ok(bytes) => write_buffer(out_buffer, bytes),
            Err(_) => STATUS_INTERNAL_ERROR,
        },
        Err(error) => status_for_error(error.code),
    }
}

fn write_buffer(out_buffer: *mut LorepiaBuffer, bytes: Vec<u8>) -> i32 {
    let mut boxed = bytes.into_boxed_slice();
    let buffer = LorepiaBuffer {
        ptr: boxed.as_mut_ptr(),
        len: boxed.len(),
    };
    std::mem::forget(boxed);
    // SAFETY: all call sites validate `out_buffer` before calling.
    unsafe { out_buffer.write(buffer) };
    STATUS_OK
}

fn status_for_error(code: CoreErrorCode) -> i32 {
    match code {
        CoreErrorCode::InvalidInput | CoreErrorCode::UnsupportedContent => STATUS_INVALID_ARGUMENT,
        CoreErrorCode::NotFound => STATUS_NOT_FOUND,
        CoreErrorCode::StorageUnavailable | CoreErrorCode::StorageCorrupted => STATUS_STORAGE_ERROR,
        _ => STATUS_INTERNAL_ERROR,
    }
}

fn ffi_guard(operation: impl FnOnce() -> i32) -> i32 {
    catch_unwind(AssertUnwindSafe(operation)).unwrap_or(STATUS_INTERNAL_ERROR)
}

#[cfg(test)]
mod tests {
    use std::ptr;

    use tempfile::tempdir;

    use super::*;

    #[test]
    fn c_abi_core_lifetime_and_buffer_round_trip() {
        let root = tempdir().expect("temp root");
        let config = serde_json::json!({
            "data_root": root.path().to_string_lossy()
        })
        .to_string();
        let mut handle = ptr::null_mut();
        // SAFETY: test passes valid pointers and follows the C ABI lifecycle.
        let status = unsafe { lorepia_core_create(config.as_ptr(), config.len(), &raw mut handle) };
        assert_eq!(status, STATUS_OK);
        assert!(!handle.is_null());

        let mut buffer = LorepiaBuffer::default();
        // SAFETY: handle and output pointer are live.
        let status = unsafe { lorepia_core_version(handle, &raw mut buffer) };
        assert_eq!(status, STATUS_OK);
        // SAFETY: returned buffer remains live until freed below.
        let version = unsafe { slice::from_raw_parts(buffer.ptr, buffer.len) };
        assert_eq!(version, lorepia_engine::core_version().as_bytes());

        // SAFETY: each resource is released exactly once.
        unsafe {
            lorepia_buffer_free(buffer);
            lorepia_core_destroy(handle);
        }
    }
}
