use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Stable identifier for an inspected staging file.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct InspectionId(pub String);

impl InspectionId {
    pub fn new() -> Self {
        Self(Uuid::new_v4().to_string())
    }
}

impl Default for InspectionId {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ContentKind {
    CharacterCardV3,
    CharxPackage,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportWarning {
    pub code: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportInspection {
    pub id: InspectionId,
    pub kind: ContentKind,
    pub display_name: String,
    pub description: String,
    pub source_sha256: String,
    pub source_size: u64,
    pub estimated_stored_size: u64,
    pub asset_count: u32,
    pub warnings: Vec<ImportWarning>,
    pub blocked_reasons: Vec<String>,
}

impl ImportInspection {
    pub fn is_allowed(&self) -> bool {
        self.blocked_reasons.is_empty()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportLimits {
    pub max_source_bytes: u64,
    pub max_entries: usize,
    pub max_entry_bytes: u64,
    pub max_total_uncompressed_bytes: u64,
    pub max_compression_ratio: u64,
}

impl Default for ImportLimits {
    fn default() -> Self {
        Self {
            max_source_bytes: 128 * 1024 * 1024,
            max_entries: 2_048,
            max_entry_bytes: 64 * 1024 * 1024,
            max_total_uncompressed_bytes: 512 * 1024 * 1024,
            max_compression_ratio: 100,
        }
    }
}
