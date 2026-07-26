use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// A locally imported AI character.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Character {
    pub id: String,
    pub name: String,
    pub description: String,
    pub source_hash: String,
    pub avatar_asset_hash: Option<String>,
    pub created_at: DateTime<Utc>,
}

impl Character {
    pub fn new(
        name: impl Into<String>,
        description: impl Into<String>,
        source_hash: impl Into<String>,
    ) -> Self {
        Self {
            id: Uuid::new_v4().to_string(),
            name: name.into(),
            description: description.into(),
            source_hash: source_hash.into(),
            avatar_asset_hash: None,
            created_at: Utc::now(),
        }
    }
}
