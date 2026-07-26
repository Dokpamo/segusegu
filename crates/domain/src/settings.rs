use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppSettings {
    pub preserve_partial_generations: bool,
    pub selected_provider_profile_id: Option<String>,
}

impl Default for AppSettings {
    fn default() -> Self {
        Self {
            preserve_partial_generations: true,
            selected_provider_profile_id: None,
        }
    }
}
