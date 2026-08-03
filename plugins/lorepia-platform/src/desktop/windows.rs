use std::{ffi::OsString, path::PathBuf};

use ::windows::{
    Security::Credentials::{PasswordCredential, PasswordVault},
    Storage::Pickers::FileOpenPicker,
    Win32::{
        Foundation::{E_ABORT, E_POINTER, ERROR_CANCELLED, ERROR_NOT_FOUND, RPC_E_CHANGED_MODE},
        System::WinRT::{RO_INIT_MULTITHREADED, RoInitialize, RoUninitialize},
        UI::Shell::IInitializeWithWindow,
    },
    core::{Error as WindowsError, HRESULT, HSTRING, Interface},
};
use tauri::{AppHandle, Manager, Runtime};
use zeroize::Zeroizing;

use crate::{
    CredentialStatus, NativeCredential, PlatformError, PlatformErrorCode, PlatformResult,
    validation::{validate_credential_read, validate_credential_write, validate_reference},
};

pub(crate) const PRODUCTION_CREDENTIAL_RESOURCE: &str = "LorePia.ProviderCredential";
pub(crate) const DEVELOPMENT_CREDENTIAL_RESOURCE: &str = "LorePia.ProviderCredential.Development";

#[allow(unsafe_code)]
pub(crate) async fn pick_file<R: Runtime>(app: &AppHandle<R>) -> PlatformResult<Option<PathBuf>> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    let window_app = app.clone();
    app.run_on_main_thread(move || {
        let operation = (|| {
            let window = window_app
                .get_webview_window("main")
                .ok_or_else(WindowsError::empty)?;
            let picker = FileOpenPicker::new()?;
            let initialize: IInitializeWithWindow = picker.cast()?;
            let hwnd = window.hwnd().map_err(|_| WindowsError::empty())?;
            // SAFETY: the HWND comes directly from the live Tauri main window
            // and this closure runs on Tauri's UI thread.
            unsafe {
                initialize.Initialize(hwnd)?;
            }
            picker.FileTypeFilter()?.Append(&HSTRING::from("*"))?;
            picker.PickSingleFileAsync()
        })();
        let _ = sender.send(operation);
    })
    .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;

    let operation = receiver
        .await
        .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?
        .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;

    tokio::task::spawn_blocking(move || {
        let _apartment = WinRtApartment::enter()
            .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
        let selected = match operation.get() {
            Ok(selected) => selected,
            Err(error) if is_picker_cancellation(&error) => return Ok(None),
            Err(_) => {
                return Err(PlatformError::new(PlatformErrorCode::SelectionFailed));
            }
        };
        let path = selected
            .Path()
            .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
        if path.is_empty() {
            return Err(PlatformError::new(PlatformErrorCode::SelectionFailed));
        }
        Ok(Some(PathBuf::from(OsString::from(&path))))
    })
    .await
    .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?
}

pub(crate) fn credential_status(
    resource: &str,
    reference: &str,
) -> PlatformResult<CredentialStatus> {
    validate_resource(resource)?;
    validate_reference(reference)?;
    let _apartment = WinRtApartment::enter()?;
    let vault = password_vault()?;
    match retrieve_credential(&vault, resource, reference) {
        Ok(Some(credential)) => {
            let valid = credential_value(&credential)
                .ok()
                .is_some_and(|value| validate_credential_read(&value).is_ok());
            Ok(if valid {
                CredentialStatus::Available
            } else {
                CredentialStatus::Unreadable
            })
        }
        Ok(None) => Ok(CredentialStatus::Missing),
        Err(_) => Ok(CredentialStatus::Unreadable),
    }
}

pub(crate) fn read_credential(
    resource: &str,
    reference: &str,
) -> PlatformResult<Option<NativeCredential>> {
    validate_resource(resource)?;
    validate_reference(reference)?;
    let _apartment = WinRtApartment::enter()?;
    let vault = password_vault()?;
    let Some(credential) = retrieve_credential(&vault, resource, reference)? else {
        return Ok(None);
    };
    let value = credential_value(&credential)?;
    validate_credential_read(value.as_str())
        .map_err(|_| PlatformError::new(PlatformErrorCode::CredentialUnavailable))?;
    Ok(Some(NativeCredential::new(value.as_str().to_owned())))
}

pub(crate) fn store_credential(
    resource: &str,
    reference: &str,
    value: NativeCredential,
) -> PlatformResult<()> {
    validate_resource(resource)?;
    validate_reference(reference)?;
    validate_credential_write(value.expose())?;
    let _apartment = WinRtApartment::enter()?;
    let vault = password_vault()?;
    let replacement = new_credential(resource, reference, value.expose())?;

    let previous = retrieve_credential(&vault, resource, reference)?;
    let previous_value = previous.as_ref().map(credential_value).transpose()?;
    if let Some(previous) = previous.as_ref() {
        vault.Remove(previous).map_err(credential_error)?;
    }

    let replacement_verified = vault.Add(&replacement).is_ok()
        && retrieve_credential(&vault, resource, reference)
            .ok()
            .flatten()
            .and_then(|credential| credential_value(&credential).ok())
            .is_some_and(|stored| stored.as_str() == value.expose());
    if replacement_verified {
        return Ok(());
    }

    let removed_attempt = match retrieve_credential(&vault, resource, reference) {
        Ok(Some(attempted)) => vault.Remove(&attempted).is_ok(),
        Ok(None) => true,
        Err(_) => false,
    };
    if !removed_attempt
        || !restore_credential_value(&vault, resource, reference, previous_value.as_ref())
    {
        return Err(PlatformError::new(
            PlatformErrorCode::CredentialRecoveryRequired,
        ));
    }
    Err(PlatformError::new(PlatformErrorCode::CredentialUnavailable))
}

pub(crate) fn delete_credential(resource: &str, reference: &str) -> PlatformResult<()> {
    validate_resource(resource)?;
    validate_reference(reference)?;
    let _apartment = WinRtApartment::enter()?;
    let vault = password_vault()?;
    let Some(previous) = retrieve_credential(&vault, resource, reference)? else {
        return Ok(());
    };
    let backup = credential_value(&previous).ok();

    if vault.Remove(&previous).is_ok() {
        return Ok(());
    }

    match retrieve_credential(&vault, resource, reference) {
        Ok(Some(_)) => {}
        Ok(None) if restore_credential_value(&vault, resource, reference, backup.as_ref()) => {}
        Ok(None) | Err(_) => {
            return Err(PlatformError::new(
                PlatformErrorCode::CredentialRecoveryRequired,
            ));
        }
    }
    Err(PlatformError::new(PlatformErrorCode::CredentialUnavailable))
}

fn restore_credential_value(
    vault: &PasswordVault,
    resource: &str,
    reference: &str,
    previous: Option<&Zeroizing<String>>,
) -> bool {
    if let Some(previous) = previous {
        let Ok(previous_item) = new_credential(resource, reference, previous.as_str()) else {
            return false;
        };
        if vault.Add(&previous_item).is_err() {
            return false;
        }
        return retrieve_credential(vault, resource, reference)
            .ok()
            .flatten()
            .and_then(|credential| credential_value(&credential).ok())
            .is_some_and(|stored| stored.as_str() == previous.as_str());
    }
    matches!(retrieve_credential(vault, resource, reference), Ok(None))
}

fn retrieve_credential(
    vault: &PasswordVault,
    resource: &str,
    reference: &str,
) -> PlatformResult<Option<PasswordCredential>> {
    let resource = HSTRING::from(resource);
    let reference = HSTRING::from(reference);
    match vault.Retrieve(&resource, &reference) {
        Ok(credential) => Ok(Some(credential)),
        Err(error) if is_missing_credential(&error) => Ok(None),
        Err(_) => Err(PlatformError::new(PlatformErrorCode::CredentialUnavailable)),
    }
}

fn credential_value(credential: &PasswordCredential) -> PlatformResult<Zeroizing<String>> {
    credential.RetrievePassword().map_err(credential_error)?;
    let password = credential.Password().map_err(credential_error)?;
    let password = String::try_from(&password)
        .map_err(|_| PlatformError::new(PlatformErrorCode::CredentialUnavailable))?;
    Ok(Zeroizing::new(password))
}

fn new_credential(
    resource: &str,
    reference: &str,
    value: &str,
) -> PlatformResult<PasswordCredential> {
    PasswordCredential::CreatePasswordCredential(
        &HSTRING::from(resource),
        &HSTRING::from(reference),
        &HSTRING::from(value),
    )
    .map_err(credential_error)
}

fn password_vault() -> PlatformResult<PasswordVault> {
    PasswordVault::new().map_err(credential_error)
}

fn validate_resource(resource: &str) -> PlatformResult<()> {
    if matches!(
        resource,
        PRODUCTION_CREDENTIAL_RESOURCE | DEVELOPMENT_CREDENTIAL_RESOURCE
    ) {
        Ok(())
    } else {
        Err(PlatformError::new(PlatformErrorCode::InvalidInput))
    }
}

fn is_missing_credential(error: &WindowsError) -> bool {
    error.code() == HRESULT::from_win32(ERROR_NOT_FOUND.0)
}

fn is_picker_cancellation(error: &WindowsError) -> bool {
    let code = error.code();
    code == E_ABORT || code == E_POINTER || code == HRESULT::from_win32(ERROR_CANCELLED.0)
}

fn credential_error<E>(_error: E) -> PlatformError {
    PlatformError::new(PlatformErrorCode::CredentialUnavailable)
}

struct WinRtApartment {
    uninitialize: bool,
}

impl WinRtApartment {
    #[allow(unsafe_code)]
    fn enter() -> PlatformResult<Self> {
        // SAFETY: every successful `RoInitialize` on this thread is paired
        // with `RoUninitialize` by this guard. A pre-existing STA is also a
        // valid apartment for PasswordVault and must not be uninitialized here.
        match unsafe { RoInitialize(RO_INIT_MULTITHREADED) } {
            Ok(()) => Ok(Self { uninitialize: true }),
            Err(error) if error.code() == RPC_E_CHANGED_MODE => Ok(Self {
                uninitialize: false,
            }),
            Err(_) => Err(PlatformError::new(PlatformErrorCode::CredentialUnavailable)),
        }
    }
}

impl Drop for WinRtApartment {
    #[allow(unsafe_code)]
    fn drop(&mut self) {
        if self.uninitialize {
            // SAFETY: paired with the successful `RoInitialize` call made by
            // `WinRtApartment::enter` on this same synchronous call stack.
            unsafe {
                RoUninitialize();
            }
        }
    }
}
