//! Safe inspection of local character cards and CHARX packages.

mod adapters;
mod archive;
mod hashing;
mod path;

use std::{
    fs::File,
    io::{BufReader, Read},
    path::Path,
};

use lorepia_domain::{
    ContentKind, CoreError, CoreErrorCode, CoreResult, ImportInspection, ImportLimits,
    ImportWarning, InspectionId,
};

pub use hashing::sha256_file;

const ZIP_MAGIC: &[u8; 4] = b"PK\x03\x04";

/// Inspect an untrusted staging file without writing to the final library.
pub fn inspect_file(path: &Path, limits: ImportLimits) -> CoreResult<ImportInspection> {
    let metadata = path.metadata().map_err(|error| {
        CoreError::new(
            CoreErrorCode::StorageUnavailable,
            format!("cannot read staging file metadata: {error}"),
            true,
        )
    })?;
    if !metadata.is_file() {
        return Err(CoreError::invalid(
            "the import source is not a regular file",
        ));
    }
    if metadata.len() > limits.max_source_bytes {
        return Err(CoreError::new(
            CoreErrorCode::UnsupportedContent,
            format!(
                "source is {} bytes; maximum is {} bytes",
                metadata.len(),
                limits.max_source_bytes
            ),
            false,
        ));
    }

    let mut reader = BufReader::new(File::open(path).map_err(storage_error)?);
    let mut magic = [0_u8; 4];
    let read = reader.read(&mut magic).map_err(storage_error)?;
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();

    let (kind, metadata, asset_count, estimated_size, mut warnings) =
        if read == ZIP_MAGIC.len() && &magic == ZIP_MAGIC {
            let mut inspected = archive::inspect_archive(path, limits)?;
            if extension != "charx" && extension != "zip" {
                let mut extension_warnings = inspected_extension_warning(&extension, "CHARX/ZIP");
                extension_warnings.append(&mut inspected.warnings);
                inspected.warnings = extension_warnings;
            }
            (
                ContentKind::CharxPackage,
                inspected.metadata,
                inspected.asset_count,
                inspected.total_uncompressed,
                inspected.warnings,
            )
        } else {
            let bytes = std::fs::read(path).map_err(storage_error)?;
            let metadata = adapters::parse_card_json(&bytes)?;
            let estimated_size = metadata.len_bytes;
            let warnings = inspected_extension_warning(&extension, "JSON");
            (
                ContentKind::CharacterCardV3,
                metadata,
                0,
                estimated_size,
                warnings,
            )
        };

    if metadata.name.trim().is_empty() {
        warnings.push(ImportWarning {
            code: "empty_name".to_owned(),
            message: "The character has no display name.".to_owned(),
        });
    }

    Ok(ImportInspection {
        id: InspectionId::new(),
        kind,
        display_name: metadata.name,
        description: metadata.description,
        source_sha256: sha256_file(path)?,
        source_size: metadata_len(path)?,
        estimated_stored_size: estimated_size,
        asset_count,
        warnings,
        blocked_reasons: Vec::new(),
    })
}

fn inspected_extension_warning(extension: &str, detected: &str) -> Vec<ImportWarning> {
    let expected = match detected {
        "JSON" => extension == "json",
        _ => matches!(extension, "charx" | "zip"),
    };
    if expected {
        Vec::new()
    } else {
        vec![ImportWarning {
            code: "extension_mismatch".to_owned(),
            message: format!("File contents are {detected}, but the extension is .{extension}."),
        }]
    }
}

fn metadata_len(path: &Path) -> CoreResult<u64> {
    path.metadata()
        .map(|value| value.len())
        .map_err(storage_error)
}

fn storage_error(error: std::io::Error) -> CoreError {
    CoreError::new(
        CoreErrorCode::StorageUnavailable,
        format!("staging file access failed: {error}"),
        true,
    )
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use tempfile::NamedTempFile;

    use super::*;

    #[test]
    fn inspects_minimal_v3_card() {
        let mut file = NamedTempFile::new().expect("temp file");
        write!(
            file,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Segu","description":"Guide"}}}}"#
        )
        .expect("write fixture");

        let inspection =
            inspect_file(file.path(), ImportLimits::default()).expect("valid inspection");
        assert_eq!(inspection.kind, ContentKind::CharacterCardV3);
        assert_eq!(inspection.display_name, "Segu");
        assert!(inspection.is_allowed());
    }

    #[test]
    fn rejects_oversized_source_before_parsing() {
        let mut file = NamedTempFile::new().expect("temp file");
        file.write_all(b"{}").expect("write fixture");
        let limits = ImportLimits {
            max_source_bytes: 1,
            ..ImportLimits::default()
        };

        let error = inspect_file(file.path(), limits).expect_err("must reject");
        assert_eq!(error.code, CoreErrorCode::UnsupportedContent);
    }
}
