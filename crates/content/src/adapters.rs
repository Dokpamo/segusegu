use lorepia_domain::{CoreError, CoreErrorCode, CoreResult};
use serde_json::Value;

#[derive(Debug, Clone)]
pub(crate) struct CardMetadata {
    pub(crate) name: String,
    pub(crate) description: String,
    pub(crate) len_bytes: u64,
}

pub(crate) fn parse_card_json(bytes: &[u8]) -> CoreResult<CardMetadata> {
    const MAX_METADATA_BYTES: usize = 4 * 1024 * 1024;
    if bytes.len() > MAX_METADATA_BYTES {
        return Err(CoreError::new(
            CoreErrorCode::UnsupportedContent,
            "character metadata exceeds 4 MiB",
            false,
        ));
    }

    let value: Value = serde_json::from_slice(bytes).map_err(|error| {
        CoreError::new(
            CoreErrorCode::UnsupportedContent,
            format!("invalid character JSON: {error}"),
            false,
        )
    })?;
    let data = value.get("data").unwrap_or(&value);
    let name = data
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_owned();
    let description = data
        .get("description")
        .or_else(|| data.get("personality"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_owned();

    if !value.is_object() {
        return Err(CoreError::new(
            CoreErrorCode::UnsupportedContent,
            "character metadata must be a JSON object",
            false,
        ));
    }

    Ok(CardMetadata {
        name,
        description,
        len_bytes: bytes.len() as u64,
    })
}
