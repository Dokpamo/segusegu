use std::{
    fmt,
    path::{Path, PathBuf},
};

use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CredentialStatus {
    Missing,
    Available,
    Unreadable,
}

/// A native credential that can only move farther into Rust.
///
/// It deliberately implements neither `Serialize` nor `Clone`.
pub struct NativeCredential(Zeroizing<String>);

impl NativeCredential {
    pub fn new(value: String) -> Self {
        Self(Zeroizing::new(value))
    }

    pub fn expose(&self) -> &str {
        self.0.as_str()
    }
}

impl fmt::Debug for NativeCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("NativeCredential([REDACTED])")
    }
}

/// An app-owned bounded copy. Its host path is never serializable.
pub struct StagedImport {
    path: PathBuf,
    display_name: String,
    size_bytes: u64,
}

impl StagedImport {
    pub(crate) fn new(path: PathBuf, display_name: String, size_bytes: u64) -> Self {
        Self {
            path,
            display_name,
            size_bytes,
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn display_name(&self) -> &str {
        &self.display_name
    }

    pub const fn size_bytes(&self) -> u64 {
        self.size_bytes
    }
}

impl fmt::Debug for StagedImport {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StagedImport")
            .field("path", &"[REDACTED]")
            .field("display_name", &"[REDACTED]")
            .field("size_bytes", &self.size_bytes)
            .finish()
    }
}

impl Drop for StagedImport {
    fn drop(&mut self) {
        // `StagedImport::new` is crate-private and is only constructed from an
        // app-owned bounded copy. This is the terminal fallback when a window
        // closes before the explicit discard command runs.
        let _ = std::fs::remove_file(&self.path);
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
#[cfg(mobile)]
pub(crate) struct MobilePathResponse {
    pub path: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
#[cfg(mobile)]
pub(crate) struct MobileCredentialResponse {
    pub value: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
#[cfg(mobile)]
pub(crate) struct MobileCredentialStatusResponse {
    pub status: CredentialStatus,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
#[cfg(mobile)]
pub(crate) struct MobilePickResponse {
    pub selected: bool,
    pub path: Option<String>,
    pub display_name: Option<String>,
    pub size_bytes: Option<u64>,
}
