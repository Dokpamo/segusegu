use std::{collections::HashSet, fs::File, io::Read, path::Path};

use lorepia_domain::{CoreError, CoreErrorCode, CoreResult, ImportLimits, ImportWarning};
use zip::ZipArchive;

use crate::{adapters, path::validate_archive_path};

pub(crate) struct ArchiveInspection {
    pub(crate) metadata: adapters::CardMetadata,
    pub(crate) asset_count: u32,
    pub(crate) total_uncompressed: u64,
    pub(crate) warnings: Vec<ImportWarning>,
}

pub(crate) fn inspect_archive(path: &Path, limits: ImportLimits) -> CoreResult<ArchiveInspection> {
    let file = File::open(path).map_err(archive_io_error)?;
    let mut archive = ZipArchive::new(file).map_err(|error| unsafe_archive(error.to_string()))?;
    if archive.len() > limits.max_entries {
        return Err(unsafe_archive(format!(
            "archive has {} entries; maximum is {}",
            archive.len(),
            limits.max_entries
        )));
    }

    let mut collision_keys = HashSet::new();
    let mut total_uncompressed = 0_u64;
    let mut metadata_bytes = None;
    let mut asset_count = 0_u32;
    let mut warnings = Vec::new();

    for index in 0..archive.len() {
        let mut entry = archive
            .by_index(index)
            .map_err(|error| unsafe_archive(error.to_string()))?;
        let name = entry.name().to_owned();
        let collision_key =
            validate_archive_path(&name).map_err(|message| unsafe_archive(message.to_owned()))?;
        if !collision_keys.insert(collision_key) {
            return Err(unsafe_archive(format!(
                "archive path collides after normalization: {name}"
            )));
        }
        if entry
            .unix_mode()
            .is_some_and(|mode| mode & 0o170_000 == 0o120_000)
        {
            return Err(unsafe_archive(format!(
                "symbolic links are not allowed: {name}"
            )));
        }
        if entry.size() > limits.max_entry_bytes {
            return Err(unsafe_archive(format!(
                "archive entry exceeds size limit: {name}"
            )));
        }
        total_uncompressed = total_uncompressed
            .checked_add(entry.size())
            .ok_or_else(|| unsafe_archive("archive size overflow".to_owned()))?;
        if total_uncompressed > limits.max_total_uncompressed_bytes {
            return Err(unsafe_archive(
                "archive exceeds total uncompressed size limit".to_owned(),
            ));
        }
        let compressed = entry.compressed_size().max(1);
        if entry.size() / compressed > limits.max_compression_ratio {
            return Err(unsafe_archive(format!(
                "archive entry exceeds compression ratio limit: {name}"
            )));
        }

        let extension = Path::new(&name)
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase();
        if metadata_bytes.is_none() && extension == "json" {
            if entry.size() > 4 * 1024 * 1024 {
                return Err(unsafe_archive(
                    "character metadata exceeds 4 MiB".to_owned(),
                ));
            }
            let capacity = usize::try_from(entry.size()).map_err(|_| {
                unsafe_archive("archive entry is too large for this device".to_owned())
            })?;
            let mut bytes = Vec::with_capacity(capacity);
            entry.read_to_end(&mut bytes).map_err(archive_io_error)?;
            metadata_bytes = Some(bytes);
        } else if is_asset_extension(&extension) && !entry.is_dir() {
            asset_count = asset_count.saturating_add(1);
            let mut header = [0_u8; 16];
            let header_len = entry.read(&mut header).map_err(archive_io_error)?;
            if !asset_signature_matches(&extension, &header[..header_len]) {
                warnings.push(ImportWarning {
                    code: "mime_mismatch".to_owned(),
                    message: format!("Asset extension does not match file signature: {name}"),
                });
            }
        }
    }

    let metadata = metadata_bytes
        .ok_or_else(|| unsafe_archive("CHARX package contains no character JSON".to_owned()))
        .and_then(|bytes| adapters::parse_card_json(&bytes))?;

    Ok(ArchiveInspection {
        metadata,
        asset_count,
        total_uncompressed,
        warnings,
    })
}

fn is_asset_extension(extension: &str) -> bool {
    matches!(
        extension,
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "avif" | "mp3" | "wav" | "ogg"
    )
}

fn asset_signature_matches(extension: &str, header: &[u8]) -> bool {
    if extension == "png" {
        header.starts_with(b"\x89PNG\r\n\x1a\n")
    } else if matches!(extension, "jpg" | "jpeg") {
        header.starts_with(b"\xff\xd8\xff")
    } else if extension == "gif" {
        header.starts_with(b"GIF87a") || header.starts_with(b"GIF89a")
    } else if extension == "webp" {
        header.starts_with(b"RIFF") && header.get(8..12) == Some(b"WEBP")
    } else if extension == "wav" {
        header.starts_with(b"RIFF") && header.get(8..12) == Some(b"WAVE")
    } else if extension == "ogg" {
        header.starts_with(b"OggS")
    } else if extension == "mp3" {
        header.starts_with(b"ID3")
            || header
                .get(..2)
                .is_some_and(|bytes| bytes[0] == 0xff && bytes[1] & 0xe0 == 0xe0)
    } else {
        true
    }
}

fn archive_io_error(error: std::io::Error) -> CoreError {
    CoreError::new(
        CoreErrorCode::StorageUnavailable,
        format!("cannot read archive: {error}"),
        true,
    )
}

fn unsafe_archive(message: String) -> CoreError {
    CoreError::new(CoreErrorCode::UnsafeArchive, message, false)
}
