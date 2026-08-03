use std::{path::PathBuf, sync::Mutex};

use core_foundation::{
    base::{CFType, CFTypeRef, TCFType},
    boolean::CFBoolean,
    data::CFData,
    dictionary::CFDictionary,
    string::{CFString, CFStringRef},
};
use objc2::MainThreadMarker;
use objc2_app_kit::{NSModalResponseOK, NSOpenPanel};
use security_framework_sys::{
    access_control::kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    base::{errSecItemNotFound, errSecSuccess},
    item::{
        kSecAttrAccount, kSecAttrService, kSecAttrSynchronizable, kSecClass,
        kSecClassGenericPassword, kSecReturnAttributes, kSecReturnData,
        kSecUseDataProtectionKeychain, kSecValueData,
    },
    keychain_item::{SecItemAdd, SecItemCopyMatching, SecItemDelete, SecItemUpdate},
};
use tauri::{AppHandle, Runtime};
use zeroize::Zeroize;

use crate::{
    CredentialStatus, NativeCredential, PlatformError, PlatformErrorCode, PlatformResult,
    validation::{validate_credential_read, validate_credential_write, validate_reference},
};

#[allow(unsafe_code)]
#[link(name = "Security", kind = "framework")]
unsafe extern "C" {
    #[link_name = "kSecAttrAccessible"]
    static SEC_ATTR_ACCESSIBLE: CFStringRef;
}

static KEYCHAIN_LOCK: Mutex<()> = Mutex::new(());

pub(crate) async fn pick_file<R: Runtime>(app: &AppHandle<R>) -> PlatformResult<Option<PathBuf>> {
    let (sender, receiver) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        let selected = MainThreadMarker::new().and_then(|mtm| {
            let panel = NSOpenPanel::openPanel(mtm);
            panel.setCanChooseFiles(true);
            panel.setCanChooseDirectories(false);
            panel.setAllowsMultipleSelection(false);
            panel.setResolvesAliases(false);
            (panel.runModal() == NSModalResponseOK)
                .then(|| panel.URL())
                .flatten()
                .and_then(|url| url.path())
                .map(|path| PathBuf::from(path.to_string()))
        });
        let _ = sender.send(selected);
    })
    .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
    receiver
        .await
        .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))
}

pub(crate) fn credential_status(
    service: &str,
    migrate_legacy: bool,
    reference: &str,
) -> PlatformResult<CredentialStatus> {
    validate_reference(reference)?;
    let _guard = lock_keychain()?;
    let mut backend = SystemKeychain;
    Ok(
        match read_current_credential(&mut backend, service, reference, migrate_legacy) {
            Ok(Some(_)) => CredentialStatus::Available,
            Ok(None) => CredentialStatus::Missing,
            Err(_) => CredentialStatus::Unreadable,
        },
    )
}

pub(crate) fn read_credential(
    service: &str,
    migrate_legacy: bool,
    reference: &str,
) -> PlatformResult<Option<NativeCredential>> {
    validate_reference(reference)?;
    let _guard = lock_keychain()?;
    read_current_credential(&mut SystemKeychain, service, reference, migrate_legacy)
}

pub(crate) fn store_credential(
    service: &str,
    migrate_legacy: bool,
    reference: &str,
    value: NativeCredential,
) -> PlatformResult<()> {
    validate_reference(reference)?;
    let _guard = lock_keychain()?;
    store_credential_with(
        &mut SystemKeychain,
        service,
        reference,
        &value,
        migrate_legacy,
    )
}

pub(crate) fn delete_credential(
    service: &str,
    migrate_legacy: bool,
    reference: &str,
) -> PlatformResult<()> {
    validate_reference(reference)?;
    let _guard = lock_keychain()?;
    delete_credential_with(&mut SystemKeychain, service, reference, migrate_legacy)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
enum KeychainStore {
    DataProtection,
    Legacy,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum KeychainAccessibility {
    Required,
    Other(String),
    Legacy,
}

struct KeychainRecord {
    value: NativeCredential,
    accessibility: KeychainAccessibility,
}

trait KeychainBackend {
    fn read(
        &mut self,
        service: &str,
        reference: &str,
        store: KeychainStore,
    ) -> PlatformResult<Option<KeychainRecord>>;

    fn upsert_data_protection(
        &mut self,
        service: &str,
        reference: &str,
        record: &KeychainRecord,
    ) -> PlatformResult<()>;

    fn delete(
        &mut self,
        service: &str,
        reference: &str,
        store: KeychainStore,
    ) -> PlatformResult<()>;
}

struct SystemKeychain;

impl KeychainBackend for SystemKeychain {
    fn read(
        &mut self,
        service: &str,
        reference: &str,
        store: KeychainStore,
    ) -> PlatformResult<Option<KeychainRecord>> {
        system_read_record(service, reference, store)
    }

    fn upsert_data_protection(
        &mut self,
        service: &str,
        reference: &str,
        record: &KeychainRecord,
    ) -> PlatformResult<()> {
        system_upsert_data_protection(service, reference, record)
    }

    fn delete(
        &mut self,
        service: &str,
        reference: &str,
        store: KeychainStore,
    ) -> PlatformResult<()> {
        system_delete_record(service, reference, store)
    }
}

fn read_current_credential<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    migrate_legacy: bool,
) -> PlatformResult<Option<NativeCredential>> {
    if let Some(record) =
        read_validated_record(backend, service, reference, KeychainStore::DataProtection)?
    {
        let normalized =
            normalize_credential(record.value.expose()).map_err(|_| credential_unavailable())?;
        harden_data_protection_if_needed(backend, service, reference, &record, &normalized)?;
        if migrate_legacy {
            backend.delete(service, reference, KeychainStore::Legacy)?;
        }
        return Ok(Some(normalized));
    }
    if !migrate_legacy {
        return Ok(None);
    }

    let Some(record) = read_validated_record(backend, service, reference, KeychainStore::Legacy)?
    else {
        return Ok(None);
    };
    let normalized =
        normalize_credential(record.value.expose()).map_err(|_| credential_unavailable())?;
    migrate_legacy_credential(backend, service, reference, &normalized)?;
    Ok(Some(normalized))
}

fn read_validated_record<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    store: KeychainStore,
) -> PlatformResult<Option<KeychainRecord>> {
    let Some(record) = backend.read(service, reference, store)? else {
        return Ok(None);
    };
    validate_credential_read(record.value.expose()).map_err(|_| credential_unavailable())?;
    Ok(Some(record))
}

fn harden_data_protection_if_needed<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    previous: &KeychainRecord,
    normalized: &NativeCredential,
) -> PlatformResult<()> {
    if previous.accessibility == KeychainAccessibility::Required
        && previous.value.expose() == normalized.expose()
    {
        return Ok(());
    }

    // Continuity requires the frozen native policy exactly. Treat every other
    // accessibility value as drift, even if a particular value could be
    // considered stricter in isolation.
    let hardened = KeychainRecord {
        value: NativeCredential::new(normalized.expose().to_owned()),
        accessibility: KeychainAccessibility::Required,
    };
    backend.upsert_data_protection(service, reference, &hardened)?;
    if let Err(error) = verify_data_protection(backend, service, reference, &hardened) {
        restore_data_protection(backend, service, reference, Some(previous))
            .map_err(|_| credential_recovery_required())?;
        return Err(error);
    }
    Ok(())
}

fn migrate_legacy_credential<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    value: &NativeCredential,
) -> PlatformResult<()> {
    let normalized = normalize_credential(value.expose()).map_err(|_| credential_unavailable())?;
    let protected = KeychainRecord {
        value: NativeCredential::new(normalized.expose().to_owned()),
        accessibility: KeychainAccessibility::Required,
    };
    backend.upsert_data_protection(service, reference, &protected)?;
    if let Err(error) = verify_data_protection(backend, service, reference, &protected) {
        // This path is entered only after a protected lookup returned not-found,
        // so deleting the attempted destination cannot remove an older item.
        restore_data_protection(backend, service, reference, None)
            .map_err(|_| credential_recovery_required())?;
        return Err(error);
    }

    // Once the protected copy has been verified, preserve it if the legacy
    // deletion reports failure. That avoids turning an ambiguous delete result
    // into loss of both copies.
    backend.delete(service, reference, KeychainStore::Legacy)
}

fn store_credential_with<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    value: &NativeCredential,
    migrate_legacy: bool,
) -> PlatformResult<()> {
    let normalized = normalize_credential(value.expose())?;
    let previous =
        read_validated_record(backend, service, reference, KeychainStore::DataProtection)?;
    let replacement = KeychainRecord {
        value: NativeCredential::new(normalized.expose().to_owned()),
        accessibility: KeychainAccessibility::Required,
    };

    backend.upsert_data_protection(service, reference, &replacement)?;
    if let Err(error) = verify_data_protection(backend, service, reference, &replacement) {
        restore_data_protection(backend, service, reference, previous.as_ref())
            .map_err(|_| credential_recovery_required())?;
        return Err(error);
    }
    if migrate_legacy && let Err(error) = backend.delete(service, reference, KeychainStore::Legacy)
    {
        // If this was a new protected item, an ambiguous legacy-delete
        // failure must not trigger deletion of the only verified copy.
        // This matches legacy migration's fail-safe behavior.
        if previous.is_some() {
            restore_data_protection(backend, service, reference, previous.as_ref())
                .map_err(|_| credential_recovery_required())?;
        }
        return Err(error);
    }
    Ok(())
}

fn delete_credential_with<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    migrate_legacy: bool,
) -> PlatformResult<()> {
    let previous =
        read_validated_record(backend, service, reference, KeychainStore::DataProtection)?;
    let result = (|| {
        backend.delete(service, reference, KeychainStore::DataProtection)?;
        verify_absent(backend, service, reference, KeychainStore::DataProtection)?;
        if migrate_legacy {
            backend.delete(service, reference, KeychainStore::Legacy)?;
        }
        Ok(())
    })();
    if let Err(error) = result {
        restore_data_protection(backend, service, reference, previous.as_ref())
            .map_err(|_| credential_recovery_required())?;
        return Err(error);
    }
    Ok(())
}

fn verify_data_protection<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    expected: &KeychainRecord,
) -> PlatformResult<()> {
    let actual = read_validated_record(backend, service, reference, KeychainStore::DataProtection)?;
    if actual.as_ref().is_some_and(|actual| {
        actual.value.expose() == expected.value.expose()
            && actual.accessibility == expected.accessibility
    }) {
        Ok(())
    } else {
        Err(credential_unavailable())
    }
}

fn restore_data_protection<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    previous: Option<&KeychainRecord>,
) -> PlatformResult<()> {
    if let Some(previous) = previous {
        backend.upsert_data_protection(service, reference, previous)?;
        verify_data_protection(backend, service, reference, previous)?;
    } else {
        backend.delete(service, reference, KeychainStore::DataProtection)?;
        verify_absent(backend, service, reference, KeychainStore::DataProtection)?;
    }
    Ok(())
}

fn verify_absent<B: KeychainBackend>(
    backend: &mut B,
    service: &str,
    reference: &str,
    store: KeychainStore,
) -> PlatformResult<()> {
    if backend.read(service, reference, store)?.is_none() {
        Ok(())
    } else {
        Err(credential_unavailable())
    }
}

fn system_read_record(
    service: &str,
    reference: &str,
    store: KeychainStore,
) -> PlatformResult<Option<KeychainRecord>> {
    let mut query_pairs = keychain_identity_pairs(service, reference, store);
    query_pairs.push((
        security_constant(unsafe_security_constant(SecurityConstant::ReturnData)),
        CFBoolean::true_value().into_CFType(),
    ));
    if store == KeychainStore::DataProtection {
        query_pairs.push((
            security_constant(unsafe_security_constant(SecurityConstant::ReturnAttributes)),
            CFBoolean::true_value().into_CFType(),
        ));
    }

    let Some(result) = copy_matching(&query_pairs)? else {
        return Ok(None);
    };
    match store {
        KeychainStore::DataProtection => decode_data_protection_record(result).map(Some),
        KeychainStore::Legacy => {
            let data = result
                .downcast_into::<CFData>()
                .ok_or_else(credential_unavailable)?;
            Ok(Some(KeychainRecord {
                value: native_credential_from_data(&data)?,
                accessibility: KeychainAccessibility::Legacy,
            }))
        }
    }
}

#[allow(unsafe_code)]
fn system_upsert_data_protection(
    service: &str,
    reference: &str,
    record: &KeychainRecord,
) -> PlatformResult<()> {
    if record.accessibility == KeychainAccessibility::Legacy {
        return Err(credential_unavailable());
    }

    let identity_pairs = keychain_identity_pairs(service, reference, KeychainStore::DataProtection);
    let query = CFDictionary::from_CFType_pairs(&identity_pairs);
    let attribute_pairs = credential_attribute_pairs(record)?;
    let attributes = CFDictionary::from_CFType_pairs(&attribute_pairs);

    // SAFETY: both dictionaries remain alive for the duration of the call and
    // contain only Security.framework keys with Core Foundation values of the
    // required types. SecItemUpdate does not retain the dictionary pointers.
    let update_status = unsafe {
        SecItemUpdate(
            query.as_concrete_TypeRef(),
            attributes.as_concrete_TypeRef(),
        )
    };
    if update_status == errSecSuccess {
        return Ok(());
    }
    if update_status != errSecItemNotFound {
        return Err(credential_unavailable());
    }

    let mut item_pairs = identity_pairs;
    item_pairs.extend(credential_attribute_pairs(record)?);
    let item = CFDictionary::from_CFType_pairs(&item_pairs);
    // SAFETY: `item` is a complete generic-password item dictionary and
    // remains alive for the call. A result object is not requested.
    let add_status = unsafe { SecItemAdd(item.as_concrete_TypeRef(), std::ptr::null_mut()) };
    if add_status == errSecSuccess {
        Ok(())
    } else {
        // This deliberately includes `errSecDuplicateItem`: a writer outside
        // this process won the add race, and overwriting it would make snapshot
        // rollback unsafe.
        Err(credential_unavailable())
    }
}

#[allow(unsafe_code)]
fn system_delete_record(
    service: &str,
    reference: &str,
    store: KeychainStore,
) -> PlatformResult<()> {
    let query_pairs = keychain_identity_pairs(service, reference, store);
    let query = CFDictionary::from_CFType_pairs(&query_pairs);
    // SAFETY: `query` remains alive for the call and contains a bounded
    // generic-password identity. SecItemDelete does not retain the pointer.
    let status = unsafe { SecItemDelete(query.as_concrete_TypeRef()) };
    if status == errSecSuccess || status == errSecItemNotFound {
        Ok(())
    } else {
        Err(credential_unavailable())
    }
}

fn keychain_identity_pairs(
    service: &str,
    reference: &str,
    store: KeychainStore,
) -> Vec<(CFString, CFType)> {
    let mut pairs = vec![
        (
            security_constant(unsafe_security_constant(SecurityConstant::Class)),
            security_constant(unsafe_security_constant(
                SecurityConstant::GenericPasswordClass,
            ))
            .into_CFType(),
        ),
        (
            security_constant(unsafe_security_constant(SecurityConstant::Service)),
            CFString::new(service).into_CFType(),
        ),
        (
            security_constant(unsafe_security_constant(SecurityConstant::Account)),
            CFString::new(reference).into_CFType(),
        ),
    ];
    pairs.push((
        security_constant(unsafe_security_constant(
            SecurityConstant::UseDataProtectionKeychain,
        )),
        match store {
            KeychainStore::DataProtection => CFBoolean::true_value(),
            KeychainStore::Legacy => CFBoolean::false_value(),
        }
        .into_CFType(),
    ));
    if store == KeychainStore::DataProtection {
        pairs.push((
            security_constant(unsafe_security_constant(SecurityConstant::Synchronizable)),
            CFBoolean::false_value().into_CFType(),
        ));
    }
    pairs
}

fn credential_attribute_pairs(record: &KeychainRecord) -> PlatformResult<Vec<(CFString, CFType)>> {
    let accessibility = match &record.accessibility {
        KeychainAccessibility::Required => required_accessibility(),
        KeychainAccessibility::Other(value) if !value.is_empty() => CFString::new(value),
        KeychainAccessibility::Other(_) | KeychainAccessibility::Legacy => {
            return Err(credential_unavailable());
        }
    };
    Ok(vec![
        (
            security_constant(unsafe_security_constant(SecurityConstant::ValueData)),
            CFData::from_buffer(record.value.expose().as_bytes()).into_CFType(),
        ),
        (accessible_attribute_key(), accessibility.into_CFType()),
    ])
}

#[allow(unsafe_code)]
fn copy_matching(pairs: &[(CFString, CFType)]) -> PlatformResult<Option<CFType>> {
    let query = CFDictionary::from_CFType_pairs(pairs);
    let mut result: CFTypeRef = std::ptr::null();
    // SAFETY: `query` remains alive for the call, `result` is a valid out
    // pointer, and a non-null successful result follows Core Foundation's
    // create rule and is immediately wrapped below.
    let status = unsafe { SecItemCopyMatching(query.as_concrete_TypeRef(), &raw mut result) };
    let returned = if result.is_null() {
        None
    } else {
        // SAFETY: SecItemCopyMatching returned this non-null object under the
        // create rule. CFType now owns the single corresponding release.
        Some(unsafe { CFType::wrap_under_create_rule(result) })
    };
    if status == errSecSuccess {
        returned.map(Some).ok_or_else(credential_unavailable)
    } else if status == errSecItemNotFound {
        Ok(None)
    } else {
        Err(credential_unavailable())
    }
}

fn decode_data_protection_record(result: CFType) -> PlatformResult<KeychainRecord> {
    let dictionary = result
        .downcast_into::<CFDictionary>()
        .ok_or_else(credential_unavailable)?;
    let data = dictionary_value(
        &dictionary,
        unsafe_security_constant(SecurityConstant::ValueData),
    )?
    .downcast_into::<CFData>()
    .ok_or_else(credential_unavailable)?;
    let accessibility = dictionary_value(
        &dictionary,
        unsafe_security_constant(SecurityConstant::Accessible),
    )?
    .downcast_into::<CFString>()
    .ok_or_else(credential_unavailable)?;
    let accessibility = if accessibility == required_accessibility() {
        KeychainAccessibility::Required
    } else {
        KeychainAccessibility::Other(accessibility.to_string())
    };
    Ok(KeychainRecord {
        value: native_credential_from_data(&data)?,
        accessibility,
    })
}

#[allow(unsafe_code)]
fn dictionary_value(dictionary: &CFDictionary, key: CFStringRef) -> PlatformResult<CFType> {
    let value = dictionary
        .find(key.cast::<std::ffi::c_void>())
        .ok_or_else(credential_unavailable)?;
    // SAFETY: `value` is a non-null object owned by `dictionary`. Wrapping
    // under the get rule retains it before the borrowed dictionary is dropped.
    Ok(unsafe { CFType::wrap_under_get_rule(*value) })
}

fn native_credential_from_data(data: &CFData) -> PlatformResult<NativeCredential> {
    if usize::try_from(data.len())
        .ok()
        .is_none_or(|length| length > crate::validation::MAXIMUM_CREDENTIAL_READ_BYTES)
    {
        return Err(credential_unavailable());
    }
    match String::from_utf8(data.bytes().to_vec()) {
        Ok(value) => Ok(NativeCredential::new(value)),
        Err(error) => {
            let mut bytes = error.into_bytes();
            bytes.zeroize();
            Err(credential_unavailable())
        }
    }
}

fn normalize_credential(value: &str) -> PlatformResult<NativeCredential> {
    let normalized = value.trim();
    validate_credential_write(normalized)?;
    Ok(NativeCredential::new(normalized.to_owned()))
}

fn required_accessibility() -> CFString {
    security_constant(unsafe_security_constant(
        SecurityConstant::AccessibleWhenUnlockedThisDeviceOnly,
    ))
}

fn accessible_attribute_key() -> CFString {
    security_constant(unsafe_security_constant(SecurityConstant::Accessible))
}

#[derive(Clone, Copy)]
enum SecurityConstant {
    Class,
    GenericPasswordClass,
    Service,
    Account,
    Synchronizable,
    UseDataProtectionKeychain,
    ReturnData,
    ReturnAttributes,
    ValueData,
    Accessible,
    AccessibleWhenUnlockedThisDeviceOnly,
}

#[allow(unsafe_code)]
fn unsafe_security_constant(constant: SecurityConstant) -> CFStringRef {
    // SAFETY: these are immutable, process-lifetime CFString constants
    // exported by Security.framework. The wrapper created by callers retains
    // the selected value under Core Foundation's get rule.
    unsafe {
        match constant {
            SecurityConstant::Class => kSecClass,
            SecurityConstant::GenericPasswordClass => kSecClassGenericPassword,
            SecurityConstant::Service => kSecAttrService,
            SecurityConstant::Account => kSecAttrAccount,
            SecurityConstant::Synchronizable => kSecAttrSynchronizable,
            SecurityConstant::UseDataProtectionKeychain => kSecUseDataProtectionKeychain,
            SecurityConstant::ReturnData => kSecReturnData,
            SecurityConstant::ReturnAttributes => kSecReturnAttributes,
            SecurityConstant::ValueData => kSecValueData,
            SecurityConstant::Accessible => SEC_ATTR_ACCESSIBLE,
            SecurityConstant::AccessibleWhenUnlockedThisDeviceOnly => {
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            }
        }
    }
}

#[allow(unsafe_code)]
fn security_constant(value: CFStringRef) -> CFString {
    // SAFETY: callers provide only non-null, immutable process-lifetime
    // Security.framework CFString constants.
    unsafe { CFString::wrap_under_get_rule(value) }
}

fn lock_keychain() -> PlatformResult<std::sync::MutexGuard<'static, ()>> {
    KEYCHAIN_LOCK.lock().map_err(|_| credential_unavailable())
}

fn credential_unavailable() -> PlatformError {
    PlatformError::new(PlatformErrorCode::CredentialUnavailable)
}

fn credential_recovery_required() -> PlatformError {
    PlatformError::new(PlatformErrorCode::CredentialRecoveryRequired)
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::{
        KeychainAccessibility, KeychainBackend, KeychainRecord, KeychainStore, NativeCredential,
        PlatformError, PlatformErrorCode, PlatformResult, delete_credential_with,
        migrate_legacy_credential, read_current_credential, store_credential_with,
    };

    const SERVICE: &str = "dev.lorepia.provider-credentials";
    const REFERENCE: &str = "connection-synthetic";

    struct StoredRecord {
        value: String,
        accessibility: KeychainAccessibility,
    }

    #[derive(Default)]
    struct FakeKeychain {
        values: HashMap<KeychainStore, StoredRecord>,
        operations: Vec<&'static str>,
        upsert_count: usize,
        corrupt_upsert_calls: Vec<usize>,
        wrong_accessibility_upsert_calls: Vec<usize>,
        fail_upsert_calls: Vec<usize>,
        fail_legacy_delete: bool,
        fail_protected_delete: bool,
    }

    impl KeychainBackend for FakeKeychain {
        fn read(
            &mut self,
            _service: &str,
            _reference: &str,
            store: KeychainStore,
        ) -> PlatformResult<Option<KeychainRecord>> {
            self.operations.push(match store {
                KeychainStore::DataProtection => "read_protected",
                KeychainStore::Legacy => "read_legacy",
            });
            Ok(self.values.get(&store).map(|record| KeychainRecord {
                value: NativeCredential::new(record.value.clone()),
                accessibility: record.accessibility.clone(),
            }))
        }

        fn upsert_data_protection(
            &mut self,
            _service: &str,
            _reference: &str,
            record: &KeychainRecord,
        ) -> PlatformResult<()> {
            self.operations.push("upsert_protected");
            self.upsert_count += 1;
            if self.fail_upsert_calls.contains(&self.upsert_count) {
                return Err(PlatformError::new(PlatformErrorCode::CredentialUnavailable));
            }
            let value = if self.corrupt_upsert_calls.contains(&self.upsert_count) {
                "corrupted-after-upsert".to_owned()
            } else {
                record.value.expose().to_owned()
            };
            let accessibility = if self
                .wrong_accessibility_upsert_calls
                .contains(&self.upsert_count)
            {
                KeychainAccessibility::Other("unexpected-policy".to_owned())
            } else {
                record.accessibility.clone()
            };
            self.values.insert(
                KeychainStore::DataProtection,
                StoredRecord {
                    value,
                    accessibility,
                },
            );
            Ok(())
        }

        fn delete(
            &mut self,
            _service: &str,
            _reference: &str,
            store: KeychainStore,
        ) -> PlatformResult<()> {
            self.operations.push(match store {
                KeychainStore::DataProtection => "delete_protected",
                KeychainStore::Legacy => "delete_legacy",
            });
            if store == KeychainStore::DataProtection && self.fail_protected_delete {
                return Err(PlatformError::new(PlatformErrorCode::CredentialUnavailable));
            }
            if store == KeychainStore::Legacy && self.fail_legacy_delete {
                return Err(PlatformError::new(PlatformErrorCode::CredentialUnavailable));
            }
            self.values.remove(&store);
            Ok(())
        }
    }

    fn stored(value: &str, accessibility: KeychainAccessibility) -> StoredRecord {
        StoredRecord {
            value: value.to_owned(),
            accessibility,
        }
    }

    fn assert_stored(
        backend: &FakeKeychain,
        store: KeychainStore,
        value: &str,
        accessibility: &KeychainAccessibility,
    ) {
        let record = backend.values.get(&store).expect("stored record");
        assert_eq!(record.value, value);
        assert_eq!(&record.accessibility, accessibility);
    }

    #[test]
    fn migration_verifies_protected_copy_before_deleting_legacy() {
        let mut backend = FakeKeychain::default();
        backend.values.insert(
            KeychainStore::Legacy,
            stored(" synthetic-secret\n", KeychainAccessibility::Legacy),
        );
        let value = NativeCredential::new(" synthetic-secret\n".to_owned());

        migrate_legacy_credential(&mut backend, SERVICE, REFERENCE, &value).expect("migration");

        assert_eq!(
            backend.operations,
            ["upsert_protected", "read_protected", "delete_legacy"]
        );
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "synthetic-secret",
            &KeychainAccessibility::Required,
        );
        assert!(!backend.values.contains_key(&KeychainStore::Legacy));
    }

    #[test]
    fn legacy_delete_failure_keeps_both_verified_copies() {
        let mut backend = FakeKeychain {
            fail_legacy_delete: true,
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::Legacy,
            stored("synthetic-secret", KeychainAccessibility::Legacy),
        );
        let value = NativeCredential::new("synthetic-secret".to_owned());

        assert!(migrate_legacy_credential(&mut backend, SERVICE, REFERENCE, &value).is_err());
        assert_stored(
            &backend,
            KeychainStore::Legacy,
            "synthetic-secret",
            &KeychainAccessibility::Legacy,
        );
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "synthetic-secret",
            &KeychainAccessibility::Required,
        );
        assert_eq!(
            backend.operations,
            ["upsert_protected", "read_protected", "delete_legacy"]
        );
    }

    #[test]
    fn protected_upsert_failure_never_deletes_or_cleans_legacy() {
        let mut backend = FakeKeychain {
            fail_upsert_calls: vec![1],
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::Legacy,
            stored("synthetic-secret", KeychainAccessibility::Legacy),
        );
        let value = NativeCredential::new("synthetic-secret".to_owned());

        assert!(migrate_legacy_credential(&mut backend, SERVICE, REFERENCE, &value).is_err());
        assert!(backend.values.contains_key(&KeychainStore::Legacy));
        assert_eq!(backend.operations, ["upsert_protected"]);
    }

    #[test]
    fn failed_new_install_verification_deletes_and_verifies_attempted_destination() {
        let mut backend = FakeKeychain {
            corrupt_upsert_calls: vec![1],
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::Legacy,
            stored("synthetic-secret", KeychainAccessibility::Legacy),
        );
        let value = NativeCredential::new("synthetic-secret".to_owned());

        assert!(migrate_legacy_credential(&mut backend, SERVICE, REFERENCE, &value).is_err());
        assert!(backend.values.contains_key(&KeychainStore::Legacy));
        assert!(!backend.values.contains_key(&KeychainStore::DataProtection));
        assert_eq!(
            backend.operations,
            [
                "upsert_protected",
                "read_protected",
                "delete_protected",
                "read_protected"
            ]
        );
    }

    #[test]
    fn replacement_uses_atomic_upsert_without_predelete() {
        let mut backend = FakeKeychain::default();
        backend.values.insert(
            KeychainStore::DataProtection,
            stored("previous", KeychainAccessibility::Required),
        );
        let replacement = NativeCredential::new(" \nreplacement\t".to_owned());

        store_credential_with(&mut backend, SERVICE, REFERENCE, &replacement, false)
            .expect("replacement");

        assert_eq!(
            backend.operations,
            ["read_protected", "upsert_protected", "read_protected"]
        );
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "replacement",
            &KeychainAccessibility::Required,
        );

        let mut invalid_backend = FakeKeychain::default();
        let blank = NativeCredential::new(" \n\t".to_owned());
        let error = store_credential_with(&mut invalid_backend, SERVICE, REFERENCE, &blank, false)
            .expect_err("blank input");
        assert_eq!(error.code(), PlatformErrorCode::InvalidInput);
        assert!(invalid_backend.operations.is_empty());
    }

    #[test]
    fn read_normalizes_value_and_rewrites_even_when_accessibility_is_exact() {
        let mut backend = FakeKeychain::default();
        let padded = format!(
            "\u{3000}{}synthetic-secret \r",
            " ".repeat(crate::validation::MAXIMUM_CREDENTIAL_WRITE_BYTES)
        );
        backend.values.insert(
            KeychainStore::DataProtection,
            stored(&padded, KeychainAccessibility::Required),
        );

        let value = read_current_credential(&mut backend, SERVICE, REFERENCE, false)
            .expect("read")
            .expect("credential");

        assert_eq!(value.expose(), "synthetic-secret");
        assert_eq!(
            backend.operations,
            ["read_protected", "upsert_protected", "read_protected"]
        );
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "synthetic-secret",
            &KeychainAccessibility::Required,
        );
    }

    #[test]
    fn oversized_normalized_legacy_value_is_rejected_before_migration() {
        let mut backend = FakeKeychain::default();
        backend.values.insert(
            KeychainStore::Legacy,
            stored(
                &"s".repeat(crate::validation::MAXIMUM_CREDENTIAL_WRITE_BYTES + 1),
                KeychainAccessibility::Legacy,
            ),
        );

        assert!(read_current_credential(&mut backend, SERVICE, REFERENCE, true).is_err());
        assert_eq!(backend.operations, ["read_protected", "read_legacy"]);
        assert!(!backend.values.contains_key(&KeychainStore::DataProtection));
        assert!(backend.values.contains_key(&KeychainStore::Legacy));
    }

    #[test]
    fn new_store_legacy_delete_failure_keeps_both_verified_copies() {
        let mut backend = FakeKeychain {
            fail_legacy_delete: true,
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::Legacy,
            stored("legacy", KeychainAccessibility::Legacy),
        );
        let replacement = NativeCredential::new("replacement".to_owned());

        assert!(
            store_credential_with(&mut backend, SERVICE, REFERENCE, &replacement, true).is_err()
        );
        assert_stored(
            &backend,
            KeychainStore::Legacy,
            "legacy",
            &KeychainAccessibility::Legacy,
        );
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "replacement",
            &KeychainAccessibility::Required,
        );
        assert_eq!(
            backend.operations,
            [
                "read_protected",
                "upsert_protected",
                "read_protected",
                "delete_legacy"
            ]
        );
    }

    #[test]
    fn read_hardens_wrong_accessibility_before_returning() {
        let previous_accessibility =
            KeychainAccessibility::Other("synthetic-weaker-policy".to_owned());
        let mut backend = FakeKeychain::default();
        backend.values.insert(
            KeychainStore::DataProtection,
            stored("synthetic-secret", previous_accessibility),
        );

        let value = read_current_credential(&mut backend, SERVICE, REFERENCE, false)
            .expect("read")
            .expect("credential");

        assert_eq!(value.expose(), "synthetic-secret");
        assert_eq!(
            backend.operations,
            ["read_protected", "upsert_protected", "read_protected"]
        );
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "synthetic-secret",
            &KeychainAccessibility::Required,
        );
    }

    #[test]
    fn failed_hardening_restores_value_and_exact_previous_accessibility() {
        let previous_accessibility =
            KeychainAccessibility::Other("synthetic-weaker-policy".to_owned());
        let mut backend = FakeKeychain {
            corrupt_upsert_calls: vec![1],
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::DataProtection,
            stored("previous", previous_accessibility.clone()),
        );

        assert!(read_current_credential(&mut backend, SERVICE, REFERENCE, false).is_err());
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "previous",
            &previous_accessibility,
        );
        assert_eq!(
            backend.operations,
            [
                "read_protected",
                "upsert_protected",
                "read_protected",
                "upsert_protected",
                "read_protected"
            ]
        );
    }

    #[test]
    fn replacement_verification_failure_restores_previous_record_exactly() {
        let previous_accessibility =
            KeychainAccessibility::Other("synthetic-prior-policy".to_owned());
        let mut backend = FakeKeychain {
            corrupt_upsert_calls: vec![1],
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::DataProtection,
            stored("previous", previous_accessibility.clone()),
        );
        let replacement = NativeCredential::new("replacement".to_owned());

        assert!(
            store_credential_with(&mut backend, SERVICE, REFERENCE, &replacement, false).is_err()
        );
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "previous",
            &previous_accessibility,
        );
    }

    #[test]
    fn wrong_replacement_accessibility_restores_previous_record_exactly() {
        let previous_accessibility =
            KeychainAccessibility::Other("synthetic-prior-policy".to_owned());
        let mut backend = FakeKeychain {
            wrong_accessibility_upsert_calls: vec![1],
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::DataProtection,
            stored("previous", previous_accessibility.clone()),
        );
        let replacement = NativeCredential::new("replacement".to_owned());

        assert!(
            store_credential_with(&mut backend, SERVICE, REFERENCE, &replacement, false).is_err()
        );
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "previous",
            &previous_accessibility,
        );
    }

    #[test]
    fn failed_restore_is_reported_as_recovery_required() {
        let mut backend = FakeKeychain {
            corrupt_upsert_calls: vec![1],
            fail_upsert_calls: vec![2],
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::DataProtection,
            stored("previous", KeychainAccessibility::Required),
        );
        let replacement = NativeCredential::new("replacement".to_owned());

        let error = store_credential_with(&mut backend, SERVICE, REFERENCE, &replacement, false)
            .expect_err("recovery required");

        assert_eq!(error.code(), PlatformErrorCode::CredentialRecoveryRequired);
    }

    #[test]
    fn delete_legacy_failure_restores_previous_protected_record() {
        let previous_accessibility =
            KeychainAccessibility::Other("synthetic-prior-policy".to_owned());
        let mut backend = FakeKeychain {
            fail_legacy_delete: true,
            ..FakeKeychain::default()
        };
        backend.values.insert(
            KeychainStore::DataProtection,
            stored("previous", previous_accessibility.clone()),
        );
        backend.values.insert(
            KeychainStore::Legacy,
            stored("legacy", KeychainAccessibility::Legacy),
        );

        assert!(delete_credential_with(&mut backend, SERVICE, REFERENCE, true).is_err());
        assert_stored(
            &backend,
            KeychainStore::DataProtection,
            "previous",
            &previous_accessibility,
        );
    }
}
