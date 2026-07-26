use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CoreErrorCode {
    InvalidInput,
    UnsupportedContent,
    UnsafeArchive,
    NotFound,
    PermissionDenied,
    StorageUnavailable,
    StorageCorrupted,
    ProviderAuthFailed,
    ProviderRateLimited,
    ProviderUnavailable,
    NetworkUnavailable,
    Cancelled,
    Internal,
}

impl CoreErrorCode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::InvalidInput => "invalid_input",
            Self::UnsupportedContent => "unsupported_content",
            Self::UnsafeArchive => "unsafe_archive",
            Self::NotFound => "not_found",
            Self::PermissionDenied => "permission_denied",
            Self::StorageUnavailable => "storage_unavailable",
            Self::StorageCorrupted => "storage_corrupted",
            Self::ProviderAuthFailed => "provider_auth_failed",
            Self::ProviderRateLimited => "provider_rate_limited",
            Self::ProviderUnavailable => "provider_unavailable",
            Self::NetworkUnavailable => "network_unavailable",
            Self::Cancelled => "cancelled",
            Self::Internal => "internal",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Error)]
#[error("{code:?}: {message}")]
pub struct CoreError {
    pub code: CoreErrorCode,
    pub message: String,
    pub recoverable: bool,
    pub operation_id: String,
}

impl CoreError {
    pub fn new(code: CoreErrorCode, message: impl Into<String>, recoverable: bool) -> Self {
        Self {
            code,
            message: message.into(),
            recoverable,
            operation_id: Uuid::new_v4().to_string(),
        }
    }

    pub fn invalid(message: impl Into<String>) -> Self {
        Self::new(CoreErrorCode::InvalidInput, message, false)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::new(CoreErrorCode::Internal, message, false)
    }
}

pub type CoreResult<T> = Result<T, CoreError>;
