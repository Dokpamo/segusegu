//! Thin `UniFFI` surface consumed by Android and Apple applications.

use std::sync::Arc;

use lorepia_core::{Core, CoreConfig, CoreError, ImportInspection, InspectionId};

uniffi::setup_scaffolding!();

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCoreConfig {
    pub data_root: String,
}

#[derive(Debug, Clone, uniffi::Record)]
#[allow(clippy::struct_excessive_bools)]
pub struct FfiHealthReport {
    pub core_version: String,
    pub database_open: bool,
    pub schema_version: u32,
    pub data_root_writable: bool,
    pub staging_writable: bool,
    pub recovery_pending: bool,
    pub active_jobs: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiCharacter {
    pub id: String,
    pub name: String,
    pub description: String,
    pub source_hash: String,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct FfiImportInspection {
    pub id: String,
    pub content_kind: String,
    pub display_name: String,
    pub description: String,
    pub source_sha256: String,
    pub source_size: u64,
    pub asset_count: u32,
    pub warnings: Vec<String>,
    pub blocked_reasons: Vec<String>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiError {
    #[error("{code}: {detail}")]
    Core {
        code: String,
        detail: String,
        recoverable: bool,
        operation_id: String,
    },
}

impl From<CoreError> for FfiError {
    fn from(error: CoreError) -> Self {
        Self::Core {
            code: error.code.as_str().to_owned(),
            detail: error.message,
            recoverable: error.recoverable,
            operation_id: error.operation_id,
        }
    }
}

#[derive(uniffi::Object)]
pub struct LorepiaCore {
    core: Core,
}

#[uniffi::export]
pub fn core_version() -> String {
    lorepia_core::core_version().to_owned()
}

#[uniffi::export]
impl LorepiaCore {
    #[uniffi::constructor]
    pub fn open(config: FfiCoreConfig) -> Result<Arc<Self>, FfiError> {
        Ok(Arc::new(Self {
            core: Core::open(CoreConfig::new(config.data_root))?,
        }))
    }

    pub fn health_check(&self) -> Result<FfiHealthReport, FfiError> {
        let report = self.core.health_check()?;
        Ok(FfiHealthReport {
            core_version: report.core_version,
            database_open: report.database_open,
            schema_version: report.schema_version,
            data_root_writable: report.data_root_writable,
            staging_writable: report.staging_writable,
            recovery_pending: report.recovery_pending,
            active_jobs: report.active_jobs,
        })
    }

    pub fn inspect_import(&self, staged_path: String) -> Result<FfiImportInspection, FfiError> {
        self.core
            .inspect_import(staged_path)
            .map(map_inspection)
            .map_err(Into::into)
    }

    pub fn commit_import(&self, inspection_id: String) -> Result<FfiCharacter, FfiError> {
        self.core
            .commit_import(&InspectionId(inspection_id))
            .map(map_character)
            .map_err(Into::into)
    }

    pub fn list_characters(&self) -> Result<Vec<FfiCharacter>, FfiError> {
        self.core
            .list_characters()
            .map(|characters| characters.into_iter().map(map_character).collect())
            .map_err(Into::into)
    }
}

fn map_character(character: lorepia_core::Character) -> FfiCharacter {
    FfiCharacter {
        id: character.id,
        name: character.name,
        description: character.description,
        source_hash: character.source_hash,
    }
}

fn map_inspection(inspection: ImportInspection) -> FfiImportInspection {
    FfiImportInspection {
        id: inspection.id.0,
        content_kind: format!("{:?}", inspection.kind).to_ascii_lowercase(),
        display_name: inspection.display_name,
        description: inspection.description,
        source_sha256: inspection.source_sha256,
        source_size: inspection.source_size,
        asset_count: inspection.asset_count,
        warnings: inspection
            .warnings
            .into_iter()
            .map(|warning| format!("{}: {}", warning.code, warning.message))
            .collect(),
        blocked_reasons: inspection.blocked_reasons,
    }
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn opens_core_and_maps_health() {
        let root = tempdir().expect("temp root");
        let core = LorepiaCore::open(FfiCoreConfig {
            data_root: root.path().to_string_lossy().into_owned(),
        })
        .expect("open");
        let health = core.health_check().expect("health");
        assert!(health.database_open);
        assert_eq!(health.core_version, core_version());
    }
}
