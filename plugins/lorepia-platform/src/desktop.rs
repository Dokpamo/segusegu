use std::path::{Path, PathBuf};

#[cfg(any(target_os = "macos", windows, test))]
use std::time::{Duration, SystemTime};

use tauri::{AppHandle, Runtime};

use crate::{
    CredentialStatus, NativeCredential, PlatformError, PlatformErrorCode, PlatformResult,
    StagedImport,
};

#[cfg(target_os = "macos")]
mod macos;
#[cfg(windows)]
mod windows;

pub(crate) struct DesktopPlatform<R: Runtime> {
    #[cfg(any(target_os = "macos", windows))]
    app: AppHandle<R>,
    #[cfg(not(any(target_os = "macos", windows)))]
    _runtime: std::marker::PhantomData<R>,
    data_root: PathBuf,
    staging_root: PathBuf,
    #[cfg(any(target_os = "macos", windows))]
    credential_namespace: &'static str,
    #[cfg(target_os = "macos")]
    migrate_legacy_credentials: bool,
}

impl<R: Runtime> DesktopPlatform<R> {
    pub(crate) fn new(app: AppHandle<R>) -> PlatformResult<Self> {
        #[cfg(any(target_os = "macos", windows))]
        {
            let policy = platform_policy(&app.config().identifier)?;
            #[cfg(windows)]
            debug_assert!(!policy.migrate_legacy_credentials);
            let staging_root = policy.data_root.join(policy.staging_name);
            std::fs::create_dir_all(&policy.data_root)
                .and_then(|()| std::fs::create_dir_all(&staging_root))
                .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
            cleanup_abandoned_staging(&staging_root, Duration::from_hours(24));
            Ok(Self {
                app,
                data_root: policy.data_root,
                staging_root,
                credential_namespace: policy.credential_namespace,
                #[cfg(target_os = "macos")]
                migrate_legacy_credentials: policy.migrate_legacy_credentials,
            })
        }
        #[cfg(not(any(target_os = "macos", windows)))]
        {
            drop(app);
            unsupported_platform()
        }
    }

    pub(crate) fn data_root(&self) -> &Path {
        &self.data_root
    }

    pub(crate) async fn pick_import(&self) -> PlatformResult<Option<StagedImport>> {
        #[cfg(any(target_os = "macos", windows))]
        {
            #[cfg(target_os = "macos")]
            let selection = macos::pick_file(&self.app).await?;
            #[cfg(windows)]
            let selection = windows::pick_file(&self.app).await?;

            let Some(selection) = selection else {
                return Ok(None);
            };
            stage_selected_file(selection, self.staging_root.clone()).await
        }
        #[cfg(not(any(target_os = "macos", windows)))]
        {
            unsupported_platform()
        }
    }

    pub(crate) fn discard_staged_import(&self, staged: &StagedImport) -> PlatformResult<()> {
        if staged.path().parent() != Some(self.staging_root.as_path()) {
            return Err(PlatformError::new(PlatformErrorCode::InvalidInput));
        }
        match std::fs::remove_file(staged.path()) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(_) => Err(PlatformError::new(PlatformErrorCode::StorageUnavailable)),
        }
    }

    pub(crate) fn credential_status(&self, reference: &str) -> PlatformResult<CredentialStatus> {
        #[cfg(target_os = "macos")]
        return macos::credential_status(
            self.credential_namespace,
            self.migrate_legacy_credentials,
            reference,
        );
        #[cfg(windows)]
        return windows::credential_status(self.credential_namespace, reference);
        #[cfg(not(any(target_os = "macos", windows)))]
        {
            let _ = reference;
            unsupported_platform()
        }
    }

    pub(crate) fn read_credential(
        &self,
        reference: &str,
    ) -> PlatformResult<Option<NativeCredential>> {
        #[cfg(target_os = "macos")]
        return macos::read_credential(
            self.credential_namespace,
            self.migrate_legacy_credentials,
            reference,
        );
        #[cfg(windows)]
        return windows::read_credential(self.credential_namespace, reference);
        #[cfg(not(any(target_os = "macos", windows)))]
        {
            let _ = reference;
            unsupported_platform()
        }
    }

    pub(crate) fn store_credential(
        &self,
        reference: &str,
        value: NativeCredential,
    ) -> PlatformResult<()> {
        #[cfg(target_os = "macos")]
        return macos::store_credential(
            self.credential_namespace,
            self.migrate_legacy_credentials,
            reference,
            value,
        );
        #[cfg(windows)]
        return windows::store_credential(self.credential_namespace, reference, value);
        #[cfg(not(any(target_os = "macos", windows)))]
        {
            let _ = reference;
            drop(value);
            unsupported_platform()
        }
    }

    pub(crate) fn delete_credential(&self, reference: &str) -> PlatformResult<()> {
        #[cfg(target_os = "macos")]
        return macos::delete_credential(
            self.credential_namespace,
            self.migrate_legacy_credentials,
            reference,
        );
        #[cfg(windows)]
        return windows::delete_credential(self.credential_namespace, reference);
        #[cfg(not(any(target_os = "macos", windows)))]
        {
            let _ = reference;
            unsupported_platform()
        }
    }
}

/// Best-effort cleanup is deliberately restricted to old, regular files with
/// the random prefix created by this plugin. A fresh file may belong to
/// another process which has not opened Core yet, so it is never removed.
#[cfg(any(target_os = "macos", windows, test))]
fn cleanup_abandoned_staging(staging_root: &Path, minimum_age: Duration) {
    let Ok(entries) = std::fs::read_dir(staging_root) else {
        return;
    };
    let now = SystemTime::now();
    for entry in entries.flatten() {
        let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
            continue;
        };
        if !name.starts_with(crate::staging::OWNED_STAGING_PREFIX) {
            continue;
        }
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if !file_type.is_file() {
            continue;
        }
        let Ok(modified) = entry.metadata().and_then(|metadata| metadata.modified()) else {
            continue;
        };
        if now
            .duration_since(modified)
            .is_ok_and(|age| age >= minimum_age)
        {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(any(target_os = "macos", windows, test))]
struct DesktopPolicy {
    data_root: PathBuf,
    staging_name: &'static str,
    credential_namespace: &'static str,
    migrate_legacy_credentials: bool,
}

#[cfg(target_os = "macos")]
fn platform_policy(identifier: &str) -> PlatformResult<DesktopPolicy> {
    use objc2_foundation::{
        NSSearchPathDirectory, NSSearchPathDomainMask, NSSearchPathForDirectoriesInDomains,
    };

    let application_support = NSSearchPathForDirectoriesInDomains(
        NSSearchPathDirectory::ApplicationSupportDirectory,
        NSSearchPathDomainMask::UserDomainMask,
        true,
    )
    .firstObject()
    .map(|value| PathBuf::from(value.to_string()))
    .filter(|path| path.is_absolute())
    .ok_or_else(|| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
    macos_policy_from_application_support(application_support, identifier)
}

#[cfg(any(target_os = "macos", test))]
fn macos_policy_from_application_support(
    application_support: PathBuf,
    identifier: &str,
) -> PlatformResult<DesktopPolicy> {
    match identifier {
        "dev.lorepia.mac" => Ok(DesktopPolicy {
            data_root: application_support.join("LorePia"),
            staging_name: "native-staging",
            credential_namespace: "dev.lorepia.provider-credentials",
            migrate_legacy_credentials: true,
        }),
        "dev.lorepia.mac.dev" => Ok(DesktopPolicy {
            data_root: application_support.join("LorePia Development"),
            staging_name: "native-staging",
            credential_namespace: "dev.lorepia.provider-credentials.dev",
            migrate_legacy_credentials: false,
        }),
        _ => Err(PlatformError::new(PlatformErrorCode::Internal)),
    }
}

#[cfg(windows)]
fn platform_policy(identifier: &str) -> PlatformResult<DesktopPolicy> {
    windows_policy_from_local_app_data(windows_local_app_data()?, identifier)
}

#[cfg(windows)]
#[allow(unsafe_code)]
fn windows_local_app_data() -> PlatformResult<PathBuf> {
    use std::{ffi::OsString, os::windows::ffi::OsStringExt};

    use ::windows::Win32::{
        System::Com::CoTaskMemFree,
        UI::Shell::{FOLDERID_LocalAppData, KNOWN_FOLDER_FLAG, SHGetKnownFolderPath},
    };

    // SAFETY: `SHGetKnownFolderPath` initializes an owned, NUL-terminated
    // buffer on success. We copy its UTF-16 contents before releasing that
    // buffer exactly once with `CoTaskMemFree`.
    let raw_path =
        unsafe { SHGetKnownFolderPath(&FOLDERID_LocalAppData, KNOWN_FOLDER_FLAG(0), None) }
            .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
    if raw_path.is_null() {
        return Err(PlatformError::new(PlatformErrorCode::StorageUnavailable));
    }
    // SAFETY: the successful API result is valid through the terminating NUL
    // until the matching `CoTaskMemFree` below.
    let path = PathBuf::from(OsString::from_wide(unsafe { raw_path.as_wide() }));
    // SAFETY: the pointer was allocated by `SHGetKnownFolderPath` and has not
    // been freed or transferred.
    unsafe {
        CoTaskMemFree(Some(
            raw_path.as_ptr().cast::<std::ffi::c_void>().cast_const(),
        ));
    }
    if !path.is_absolute() {
        return Err(PlatformError::new(PlatformErrorCode::StorageUnavailable));
    }
    Ok(path)
}

#[cfg(any(windows, test))]
fn windows_policy_from_local_app_data(
    local_app_data: PathBuf,
    identifier: &str,
) -> PlatformResult<DesktopPolicy> {
    match identifier {
        "dev.lorepia.windows" => Ok(DesktopPolicy {
            data_root: local_app_data.join("LorePia"),
            staging_name: "transport-staging",
            credential_namespace: "LorePia.ProviderCredential",
            migrate_legacy_credentials: false,
        }),
        "dev.lorepia.windows.dev" => Ok(DesktopPolicy {
            data_root: local_app_data.join("LorePia Development"),
            staging_name: "transport-staging",
            credential_namespace: "LorePia.ProviderCredential.Development",
            migrate_legacy_credentials: false,
        }),
        _ => Err(PlatformError::new(PlatformErrorCode::Internal)),
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
fn unsupported_platform<T>() -> PlatformResult<T> {
    Err(PlatformError::new(PlatformErrorCode::UnsupportedPlatform))
}

#[cfg(any(target_os = "macos", windows))]
async fn stage_selected_file(
    selection: PathBuf,
    staging_root: PathBuf,
) -> PlatformResult<Option<StagedImport>> {
    tokio::task::spawn_blocking(move || {
        crate::staging::stage_file(&selection, &staging_root, 128 * 1024 * 1024).map(Some)
    })
    .await
    .map_err(|_| PlatformError::new(PlatformErrorCode::Internal))?
}

#[cfg(test)]
mod tests {
    use std::{path::PathBuf, time::Duration};

    use tempfile::tempdir;

    use super::{
        cleanup_abandoned_staging, macos_policy_from_application_support,
        windows_policy_from_local_app_data,
    };

    #[test]
    fn root_policy_keeps_development_away_from_production_data_and_credentials() {
        let home = PathBuf::from("/synthetic/home");
        let application_support = home.join("Library/Application Support");
        let production =
            macos_policy_from_application_support(application_support.clone(), "dev.lorepia.mac")
                .expect("production");
        let development =
            macos_policy_from_application_support(application_support, "dev.lorepia.mac.dev")
                .expect("development");

        assert_eq!(
            production.data_root,
            home.join("Library/Application Support/LorePia")
        );
        assert_eq!(
            development.data_root,
            home.join("Library/Application Support/LorePia Development")
        );
        assert_ne!(production.data_root, development.data_root);
        assert_ne!(
            production.credential_namespace,
            development.credential_namespace
        );
        assert!(production.migrate_legacy_credentials);
        assert!(!development.migrate_legacy_credentials);
    }

    #[test]
    fn root_policy_rejects_an_unrecognized_identifier() {
        assert!(
            macos_policy_from_application_support(
                PathBuf::from("/synthetic/home/Library/Application Support"),
                "dev.lorepia.app",
            )
            .is_err()
        );
    }

    #[test]
    fn windows_root_policy_preserves_legacy_production_root_and_isolates_dev() {
        let local_app_data = PathBuf::from("C:/synthetic/LocalAppData");
        let production =
            windows_policy_from_local_app_data(local_app_data.clone(), "dev.lorepia.windows")
                .expect("production");
        let development =
            windows_policy_from_local_app_data(local_app_data.clone(), "dev.lorepia.windows.dev")
                .expect("development");

        assert_eq!(production.data_root, local_app_data.join("LorePia"));
        assert_eq!(
            development.data_root,
            local_app_data.join("LorePia Development")
        );
        assert_ne!(production.data_root, development.data_root);
        assert_eq!(
            production.credential_namespace,
            "LorePia.ProviderCredential"
        );
        assert_eq!(
            development.credential_namespace,
            "LorePia.ProviderCredential.Development"
        );
    }

    #[test]
    fn abandoned_cleanup_stays_inside_owned_regular_files() {
        let root = tempdir().expect("root");
        let staging = root.path().join("staging");
        std::fs::create_dir(&staging).expect("staging");
        let owned = staging.join("lorepia-tauri-synthetic.json");
        let unrelated = staging.join("user-file.json");
        let owned_directory = staging.join("lorepia-tauri-directory");
        std::fs::write(&owned, b"owned").expect("owned");
        std::fs::write(&unrelated, b"unrelated").expect("unrelated");
        std::fs::create_dir(&owned_directory).expect("owned directory");

        cleanup_abandoned_staging(&staging, Duration::ZERO);

        assert!(!owned.exists());
        assert!(unrelated.exists());
        assert!(owned_directory.is_dir());
    }

    #[test]
    fn abandoned_cleanup_preserves_fresh_owned_files() {
        let root = tempdir().expect("root");
        let staging = root.path().join("staging");
        std::fs::create_dir(&staging).expect("staging");
        let fresh = staging.join("lorepia-tauri-fresh.partial");
        std::fs::write(&fresh, b"fresh").expect("fresh");

        cleanup_abandoned_staging(&staging, Duration::from_mins(1));

        assert!(fresh.exists());
    }

    #[cfg(not(any(target_os = "macos", windows)))]
    #[test]
    fn unsupported_desktop_platform_fails_closed() {
        let error = super::unsupported_platform::<()>().expect_err("unsupported platform");

        assert_eq!(error.code(), crate::PlatformErrorCode::UnsupportedPlatform);
    }
}
