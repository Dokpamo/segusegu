use std::{
    fmt,
    path::{Path, PathBuf},
};

use zeroize::Zeroize;

/// Request-scoped credential material supplied by a native platform service.
///
/// This type intentionally implements neither `Serialize` nor `Clone`.
pub struct SecretCredential(String);

impl SecretCredential {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub(crate) fn into_core_value(mut self) -> String {
        std::mem::take(&mut self.0)
    }

    pub(crate) fn expose_to_core(&self) -> &str {
        &self.0
    }
}

/// Credential context for one generation selection.
///
/// Target credentials retain the Rust-selected provider connection identity
/// across native vault awaits. Legacy profile credentials remain explicitly
/// unbound for compatibility with the frozen native contract.
pub struct GenerationCredential(GenerationCredentialKind);

pub(crate) enum GenerationCredentialKind {
    Legacy(Option<SecretCredential>),
    Connection {
        connection_id: String,
        credential: Option<SecretCredential>,
    },
}

impl GenerationCredential {
    pub fn legacy(credential: Option<SecretCredential>) -> Self {
        Self(GenerationCredentialKind::Legacy(credential))
    }

    pub fn connection(
        connection_id: impl Into<String>,
        credential: Option<SecretCredential>,
    ) -> Self {
        Self(GenerationCredentialKind::Connection {
            connection_id: connection_id.into(),
            credential,
        })
    }

    pub(crate) fn into_kind(self) -> GenerationCredentialKind {
        self.0
    }
}

impl fmt::Debug for GenerationCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("GenerationCredential([REDACTED])")
    }
}

/// Raw, potentially credential-bearing pasted cURL input.
///
/// Core parses this without executing a shell command. Like credentials, this
/// value cannot be cloned, serialized, displayed, or logged.
pub struct SecretProviderCurl(String);

impl SecretProviderCurl {
    pub fn new(value: impl Into<String>) -> Self {
        Self(value.into())
    }

    pub(crate) fn into_core_value(mut self) -> lorepia_core::SecretCurlInput {
        lorepia_core::SecretCurlInput::new(std::mem::take(&mut self.0))
    }
}

impl fmt::Debug for SecretProviderCurl {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretProviderCurl([REDACTED])")
    }
}

impl Drop for SecretProviderCurl {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// Exact signed provider-catalog bytes retained by the native host between
/// review and activation.
///
/// The verified review DTO is serializable; the raw selected file is not.
pub struct SignedCatalogEnvelope(Vec<u8>);

impl SignedCatalogEnvelope {
    pub fn new(value: impl Into<Vec<u8>>) -> Self {
        Self(value.into())
    }

    pub(crate) fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl fmt::Debug for SignedCatalogEnvelope {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SignedCatalogEnvelope([REDACTED])")
    }
}

impl Drop for SignedCatalogEnvelope {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

impl fmt::Debug for SecretCredential {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretCredential([REDACTED])")
    }
}

impl Drop for SecretCredential {
    fn drop(&mut self) {
        self.0.zeroize();
    }
}

/// Platform-owned, bounded transport copy selected by a native file picker.
///
/// The host path can cross the Rust call boundary but cannot be serialized to
/// the frontend. `Core::inspect_import` immediately snapshots it into Core's
/// private staging area.
pub struct StagedImportFile(PathBuf);

impl StagedImportFile {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self(path.into())
    }

    pub(crate) fn as_path(&self) -> &Path {
        &self.0
    }
}

impl fmt::Debug for StagedImportFile {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("StagedImportFile([REDACTED])")
    }
}

#[cfg(test)]
mod tests {
    use std::marker::PhantomData;

    use super::{
        GenerationCredential, SecretCredential, SecretProviderCurl, SignedCatalogEnvelope,
        StagedImportFile,
    };

    trait AmbiguousIfSerialize<Marker> {
        fn marker() {}
    }

    struct SerializeCheck<T: ?Sized>(PhantomData<T>);

    impl<T: ?Sized> AmbiguousIfSerialize<()> for SerializeCheck<T> {}
    impl<T: ?Sized + serde::Serialize> AmbiguousIfSerialize<u8> for SerializeCheck<T> {}

    #[test]
    fn sensitive_boundary_debug_output_is_redacted() {
        let secret = "sk-shell-sensitive-canary";
        let path = "/Users/synthetic/private/card.json";

        assert!(!format!("{:?}", SecretCredential::new(secret)).contains(secret));
        assert!(
            !format!(
                "{:?}",
                GenerationCredential::connection(
                    "synthetic-connection",
                    Some(SecretCredential::new(secret))
                )
            )
            .contains(secret)
        );
        assert!(!format!("{:?}", SecretProviderCurl::new(secret)).contains(secret));
        assert!(
            !format!(
                "{:?}",
                SignedCatalogEnvelope::new(secret.as_bytes().to_vec())
            )
            .contains(secret)
        );
        assert!(!format!("{:?}", StagedImportFile::new(path)).contains(path));
    }

    #[test]
    fn sensitive_boundary_types_do_not_implement_serialize() {
        let _ = <SerializeCheck<SecretCredential> as AmbiguousIfSerialize<_>>::marker;
        let _ = <SerializeCheck<GenerationCredential> as AmbiguousIfSerialize<_>>::marker;
        let _ = <SerializeCheck<SecretProviderCurl> as AmbiguousIfSerialize<_>>::marker;
        let _ = <SerializeCheck<SignedCatalogEnvelope> as AmbiguousIfSerialize<_>>::marker;
        let _ = <SerializeCheck<StagedImportFile> as AmbiguousIfSerialize<_>>::marker;
    }
}
