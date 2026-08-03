use std::path::{Path, PathBuf};

use serde::Serialize;
use tauri::{
    Runtime,
    plugin::{PluginHandle, mobile::PluginInvokeError},
};

use crate::{
    CredentialStatus, NativeCredential, PlatformError, PlatformErrorCode, PlatformResult,
    StagedImport,
    model::{
        MobileCredentialResponse, MobileCredentialStatusResponse, MobilePathResponse,
        MobilePickResponse,
    },
    validation::{validate_credential_read, validate_credential_write, validate_reference},
};

pub(crate) struct MobilePlatform<R: Runtime> {
    handle: PluginHandle<R>,
    data_root: PathBuf,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ReferenceArgs<'a> {
    reference: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CredentialArgs<'a> {
    reference: &'a str,
    value: &'a str,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StagedPathArgs<'a> {
    path: &'a str,
}

impl<R: Runtime> MobilePlatform<R> {
    pub(crate) fn new(handle: PluginHandle<R>) -> PlatformResult<Self> {
        let response = handle
            .run_mobile_plugin::<MobilePathResponse>("dataRoot", ())
            .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
        let data_root = PathBuf::from(response.path);
        if !data_root.is_absolute() {
            return Err(PlatformError::new(PlatformErrorCode::StorageUnavailable));
        }
        Ok(Self { handle, data_root })
    }

    pub(crate) fn data_root(&self) -> &Path {
        &self.data_root
    }

    pub(crate) async fn pick_import(&self) -> PlatformResult<Option<StagedImport>> {
        let response = self
            .handle
            .run_mobile_plugin_async::<MobilePickResponse>("pickImport", ())
            .await
            .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
        if !response.selected {
            return Ok(None);
        }

        let path = response
            .path
            .map(PathBuf::from)
            .filter(|path| path.is_absolute())
            .ok_or_else(|| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
        let display_name = response
            .display_name
            .filter(|name| !name.trim().is_empty())
            .ok_or_else(|| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
        let size_bytes = response
            .size_bytes
            .ok_or_else(|| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
        Ok(Some(StagedImport::new(path, display_name, size_bytes)))
    }

    pub(crate) async fn discard_staged_import(&self, staged: &StagedImport) -> PlatformResult<()> {
        let path = staged
            .path()
            .to_str()
            .ok_or_else(|| PlatformError::new(PlatformErrorCode::InvalidInput))?;
        self.handle
            .run_mobile_plugin_async::<()>("discardStagedImport", StagedPathArgs { path })
            .await
            .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))
    }

    pub(crate) async fn credential_status(
        &self,
        reference: &str,
    ) -> PlatformResult<CredentialStatus> {
        validate_reference(reference)?;
        self.handle
            .run_mobile_plugin_async::<MobileCredentialStatusResponse>(
                "credentialStatus",
                ReferenceArgs { reference },
            )
            .await
            .map(|response| response.status)
            .map_err(map_credential_invoke_error)
    }

    pub(crate) async fn read_credential(
        &self,
        reference: &str,
    ) -> PlatformResult<Option<NativeCredential>> {
        validate_reference(reference)?;
        let response = self
            .handle
            .run_mobile_plugin_async::<MobileCredentialResponse>(
                "readCredential",
                ReferenceArgs { reference },
            )
            .await
            .map_err(map_credential_invoke_error)?;
        match response.value {
            Some(value) => {
                validate_credential_read(&value)?;
                Ok(Some(NativeCredential::new(value)))
            }
            None => Ok(None),
        }
    }

    pub(crate) async fn store_credential(
        &self,
        reference: &str,
        value: NativeCredential,
    ) -> PlatformResult<()> {
        validate_reference(reference)?;
        validate_credential_write(value.expose())?;
        self.handle
            .run_mobile_plugin_async::<()>(
                "storeCredential",
                CredentialArgs {
                    reference,
                    value: value.expose(),
                },
            )
            .await
            .map_err(map_credential_invoke_error)
    }

    pub(crate) async fn delete_credential(&self, reference: &str) -> PlatformResult<()> {
        validate_reference(reference)?;
        self.handle
            .run_mobile_plugin_async::<()>("deleteCredential", ReferenceArgs { reference })
            .await
            .map_err(map_credential_invoke_error)
    }
}

fn map_credential_invoke_error(error: PluginInvokeError) -> PlatformError {
    let recovery_required = matches!(
        error,
        PluginInvokeError::InvokeRejected(ref response)
            if matches!(
                response.code.as_deref(),
                Some("credential_recovery_required" | "credential_restore_failed")
            )
    );
    PlatformError::new(if recovery_required {
        PlatformErrorCode::CredentialRecoveryRequired
    } else {
        PlatformErrorCode::CredentialUnavailable
    })
}
