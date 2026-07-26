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

/// Platform-neutral metadata for an image inside an inspected archive.
///
/// `logical_asset_id` is the validated, normalized archive path. It is not a
/// host filesystem path and does not grant access to staged bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportImagePreview {
    pub logical_asset_id: String,
    pub media_type: String,
    pub size_bytes: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ImportInspection {
    pub id: InspectionId,
    pub kind: ContentKind,
    pub display_name: String,
    pub description: String,
    pub representative_image: Option<ImportImagePreview>,
    pub source_sha256: String,
    pub source_size: u64,
    pub estimated_stored_size: u64,
    pub asset_count: u32,
    pub warnings: Vec<ImportWarning>,
    pub blocked_reasons: Vec<String>,
    pub unsupported_optional_fields: Vec<String>,
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

#[cfg(test)]
mod tests {
    use super::{ContentKind, ImportInspection, ImportLimits, InspectionId};

    #[test]
    fn import_is_allowed_only_without_blocked_reasons() {
        let mut inspection = ImportInspection {
            id: InspectionId::new(),
            kind: ContentKind::CharacterCardV3,
            display_name: "Synthetic character".into(),
            description: String::new(),
            representative_image: None,
            source_sha256: "00".repeat(32),
            source_size: 1,
            estimated_stored_size: 1,
            asset_count: 0,
            warnings: Vec::new(),
            blocked_reasons: Vec::new(),
            unsupported_optional_fields: Vec::new(),
        };

        assert!(inspection.is_allowed());
        inspection.blocked_reasons.push("unsafe input".into());
        assert!(!inspection.is_allowed());
    }

    #[test]
    fn default_import_limits_are_finite_and_internally_ordered() {
        let limits = ImportLimits::default();

        assert!(limits.max_source_bytes > 0);
        assert!(limits.max_entries > 0);
        assert!(limits.max_entry_bytes <= limits.max_total_uncompressed_bytes);
        assert!(limits.max_compression_ratio > 1);
    }
}
