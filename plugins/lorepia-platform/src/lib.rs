//! Native platform services for the Tauri shell.
//!
//! No command from this plugin is registered with the webview. The high-level
//! app backend calls these services and returns only safe projections.

mod error;
mod model;
mod staging;
#[cfg(any(
    target_os = "android",
    target_os = "ios",
    target_os = "macos",
    windows,
    test
))]
mod validation;

#[cfg(desktop)]
mod desktop;
#[cfg(mobile)]
mod mobile;

use std::path::Path;
use zeroize::Zeroize;

pub use error::{PlatformError, PlatformErrorCode, PlatformResult};
pub use model::{CredentialStatus, NativeCredential, StagedImport};
use tauri::{Manager, Runtime, plugin::TauriPlugin};

pub struct LorepiaPlatform<R: Runtime> {
    #[cfg(desktop)]
    inner: desktop::DesktopPlatform<R>,
    #[cfg(mobile)]
    inner: mobile::MobilePlatform<R>,
}

impl<R: Runtime> LorepiaPlatform<R> {
    pub fn data_root(&self) -> &Path {
        self.inner.data_root()
    }

    pub async fn pick_import(&self) -> PlatformResult<Option<StagedImport>> {
        self.inner.pick_import().await
    }

    /// Pick a file and consume a bounded app-owned copy entirely in Rust.
    ///
    /// This is intended for sensitive signed inputs which must never expose a
    /// host path or raw bytes to the webview.
    pub async fn pick_bounded_file(&self, maximum_bytes: u64) -> PlatformResult<Option<Vec<u8>>> {
        let Some(staged) = self.pick_import().await? else {
            return Ok(None);
        };
        let mut bytes = staging::read_staged_file(&staged, maximum_bytes)?;
        if self.discard_staged_import(&staged).await.is_err() {
            bytes.zeroize();
            return Err(PlatformError::new(PlatformErrorCode::StorageUnavailable));
        }
        Ok(Some(bytes))
    }

    pub fn discard_staged_import<'a>(
        &'a self,
        staged: &'a StagedImport,
    ) -> impl std::future::Future<Output = PlatformResult<()>> + 'a {
        #[cfg(desktop)]
        {
            std::future::ready(self.inner.discard_staged_import(staged))
        }
        #[cfg(mobile)]
        {
            self.inner.discard_staged_import(staged)
        }
    }

    pub fn credential_status<'a>(
        &'a self,
        reference: &'a str,
    ) -> impl std::future::Future<Output = PlatformResult<CredentialStatus>> + 'a {
        #[cfg(desktop)]
        {
            std::future::ready(self.inner.credential_status(reference))
        }
        #[cfg(mobile)]
        {
            self.inner.credential_status(reference)
        }
    }

    pub fn read_credential<'a>(
        &'a self,
        reference: &'a str,
    ) -> impl std::future::Future<Output = PlatformResult<Option<NativeCredential>>> + 'a {
        #[cfg(desktop)]
        {
            std::future::ready(self.inner.read_credential(reference))
        }
        #[cfg(mobile)]
        {
            self.inner.read_credential(reference)
        }
    }

    pub fn store_credential<'a>(
        &'a self,
        reference: &'a str,
        value: NativeCredential,
    ) -> impl std::future::Future<Output = PlatformResult<()>> + 'a {
        #[cfg(desktop)]
        {
            std::future::ready(self.inner.store_credential(reference, value))
        }
        #[cfg(mobile)]
        {
            self.inner.store_credential(reference, value)
        }
    }

    pub fn delete_credential<'a>(
        &'a self,
        reference: &'a str,
    ) -> impl std::future::Future<Output = PlatformResult<()>> + 'a {
        #[cfg(desktop)]
        {
            std::future::ready(self.inner.delete_credential(reference))
        }
        #[cfg(mobile)]
        {
            self.inner.delete_credential(reference)
        }
    }
}

pub trait LorepiaPlatformExt<R: Runtime> {
    fn lorepia_platform(&self) -> &LorepiaPlatform<R>;
}

impl<R: Runtime, T: Manager<R>> LorepiaPlatformExt<R> for T {
    fn lorepia_platform(&self) -> &LorepiaPlatform<R> {
        self.state::<LorepiaPlatform<R>>().inner()
    }
}

pub fn init<R: Runtime>() -> TauriPlugin<R> {
    tauri::plugin::Builder::<R>::new("lorepia-platform")
        .setup(|app, _api| {
            #[cfg(target_os = "android")]
            let inner =
                mobile::MobilePlatform::new(_api.register_android_plugin(
                    "dev.lorepia.tauri.platform",
                    "LorepiaPlatformPlugin",
                )?)
                .map_err(|error| Box::new(error) as Box<dyn std::error::Error>)?;

            #[cfg(target_os = "ios")]
            let inner = mobile::MobilePlatform::new(
                _api.register_ios_plugin(init_plugin_lorepia_platform)?,
            )
            .map_err(|error| Box::new(error) as Box<dyn std::error::Error>)?;

            #[cfg(desktop)]
            let inner = desktop::DesktopPlatform::new(app.app_handle().clone())
                .map_err(|error| Box::new(error) as Box<dyn std::error::Error>)?;

            app.manage(LorepiaPlatform { inner });
            Ok(())
        })
        .build()
}

#[cfg(target_os = "ios")]
tauri::ios_plugin_binding!(init_plugin_lorepia_platform);

#[cfg(test)]
mod tests {
    use super::{NativeCredential, StagedImport};
    use std::path::PathBuf;

    #[test]
    fn sensitive_debug_views_are_redacted() {
        let secret = "sk-platform-canary";
        let path = "/Users/synthetic/private/card.json";
        let display_name = "private-card.json";
        assert!(!format!("{:?}", NativeCredential::new(secret.to_owned())).contains(secret));
        let staged = format!(
            "{:?}",
            StagedImport::new(PathBuf::from(path), display_name.to_owned(), 4)
        );
        assert!(!staged.contains(path));
        assert!(!staged.contains(display_name));
        assert!(staged.contains("[REDACTED]"));
    }
}
