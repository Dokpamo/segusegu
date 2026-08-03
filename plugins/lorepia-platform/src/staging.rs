use std::{fs::OpenOptions, io::Read};

#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt;
#[cfg(any(desktop, test))]
use std::{
    io::Write,
    path::{Path, PathBuf},
};
#[cfg(any(desktop, test))]
use uuid::Uuid;

#[cfg(any(desktop, test))]
use crate::validation::sanitize_display_name;
use crate::{PlatformError, PlatformErrorCode, PlatformResult, StagedImport};

#[cfg(any(desktop, test))]
const COPY_BUFFER_BYTES: usize = 64 * 1024;
#[cfg(any(desktop, test))]
pub(crate) const OWNED_STAGING_PREFIX: &str = "lorepia-tauri-";

#[cfg(any(desktop, test))]
pub(crate) fn stage_file(
    source_path: &Path,
    staging_root: &Path,
    maximum_bytes: u64,
) -> PlatformResult<StagedImport> {
    if maximum_bytes == 0 {
        return Err(PlatformError::new(PlatformErrorCode::InvalidInput));
    }
    let source_metadata = std::fs::symlink_metadata(source_path)
        .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
    if !source_metadata.file_type().is_file() {
        return Err(PlatformError::new(PlatformErrorCode::SelectionFailed));
    }
    if source_metadata.len() > maximum_bytes {
        return Err(PlatformError::new(PlatformErrorCode::SelectedFileTooLarge));
    }

    let display_name = source_path.file_name().map_or_else(
        || "selected-file".to_owned(),
        |name| sanitize_display_name(&name.to_string_lossy()),
    );
    let suffix = safe_suffix(&display_name);
    let basename = format!("{OWNED_STAGING_PREFIX}{}", Uuid::new_v4());
    let destination = staging_root.join(format!("{basename}{suffix}"));
    let partial = staging_root.join(format!("{basename}{suffix}.partial"));

    let result = copy_bounded(source_path, &partial, maximum_bytes).and_then(|copied| {
        std::fs::rename(&partial, &destination)
            .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
        Ok(StagedImport::new(destination.clone(), display_name, copied))
    });
    if result.is_err() {
        let _ = std::fs::remove_file(&partial);
        let _ = std::fs::remove_file(&destination);
    }
    result
}

pub(crate) fn read_staged_file(
    staged: &StagedImport,
    maximum_bytes: u64,
) -> PlatformResult<Vec<u8>> {
    if maximum_bytes == 0 || staged.size_bytes() > maximum_bytes {
        return Err(PlatformError::new(PlatformErrorCode::SelectedFileTooLarge));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    let source = options
        .open(staged.path())
        .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
    let metadata = source
        .metadata()
        .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
    if !metadata.is_file() || metadata.len() > maximum_bytes {
        return Err(PlatformError::new(PlatformErrorCode::SelectedFileTooLarge));
    }

    let bounded_length = maximum_bytes
        .checked_add(1)
        .ok_or_else(|| PlatformError::new(PlatformErrorCode::InvalidInput))?;
    let mut bytes = Vec::new();
    source
        .take(bounded_length)
        .read_to_end(&mut bytes)
        .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
    if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > maximum_bytes {
        return Err(PlatformError::new(PlatformErrorCode::SelectedFileTooLarge));
    }
    Ok(bytes)
}

#[cfg(any(desktop, test))]
fn copy_bounded(
    source_path: &Path,
    partial_path: &Path,
    maximum_bytes: u64,
) -> PlatformResult<u64> {
    let mut source_options = OpenOptions::new();
    source_options.read(true);
    #[cfg(unix)]
    source_options.custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW);
    let mut source = source_options
        .open(source_path)
        .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
    let metadata = source
        .metadata()
        .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
    if !metadata.is_file() {
        return Err(PlatformError::new(PlatformErrorCode::SelectionFailed));
    }

    let mut destination_options = OpenOptions::new();
    destination_options.write(true).create_new(true);
    #[cfg(unix)]
    destination_options.mode(0o600);
    let mut destination = destination_options
        .open(partial_path)
        .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;

    let mut copied = 0_u64;
    let mut buffer = vec![0_u8; COPY_BUFFER_BYTES];
    loop {
        let count = source
            .read(&mut buffer)
            .map_err(|_| PlatformError::new(PlatformErrorCode::SelectionFailed))?;
        if count == 0 {
            break;
        }
        copied = copied
            .checked_add(count as u64)
            .ok_or_else(|| PlatformError::new(PlatformErrorCode::SelectedFileTooLarge))?;
        if copied > maximum_bytes {
            return Err(PlatformError::new(PlatformErrorCode::SelectedFileTooLarge));
        }
        destination
            .write_all(&buffer[..count])
            .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
    }
    destination
        .sync_all()
        .map_err(|_| PlatformError::new(PlatformErrorCode::StorageUnavailable))?;
    Ok(copied)
}

#[cfg(any(desktop, test))]
fn safe_suffix(display_name: &str) -> &'static str {
    match PathBuf::from(display_name)
        .extension()
        .and_then(|value| value.to_str())
        .map(str::to_ascii_lowercase)
        .as_deref()
    {
        Some("charx") => ".charx",
        Some("zip") => ".zip",
        Some("json") => ".json",
        _ => ".pending",
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use tempfile::tempdir;

    use super::{read_staged_file, stage_file};

    #[test]
    fn stage_file_uses_random_app_owned_name_and_enforces_limit() {
        let root = tempdir().expect("root");
        let source = root.path().join("private-name.json");
        std::fs::File::create(&source)
            .and_then(|mut file| file.write_all(b"synthetic"))
            .expect("write source");
        let staging = root.path().join("staging");
        std::fs::create_dir(&staging).expect("create staging");

        let staged = stage_file(&source, &staging, 9).expect("stage");
        assert_eq!(staged.display_name(), "private-name.json");
        assert_eq!(staged.size_bytes(), 9);
        assert_eq!(staged.path().parent(), Some(staging.as_path()));
        assert_ne!(staged.path().file_name(), source.file_name());
        assert_eq!(
            read_staged_file(&staged, 9).expect("read staged"),
            b"synthetic"
        );
        assert!(read_staged_file(&staged, 8).is_err());
        assert!(stage_file(&source, &staging, 8).is_err());
    }
}
