use lorepia_domain::{CoreError, CoreErrorCode, CoreResult};
use serde_json::Value;

pub(crate) const MAX_METADATA_BYTES: usize = 4 * 1024 * 1024;
pub(crate) const MAX_CHARACTER_NAME_BYTES: usize = 1_024;
pub(crate) const MAX_CHARACTER_NAME_CHARS: usize = 256;
pub(crate) const MAX_CHARACTER_DESCRIPTION_BYTES: usize = 256 * 1024;
pub(crate) const MAX_CHARACTER_DESCRIPTION_CHARS: usize = 64 * 1024;
pub(crate) const MAX_UNSUPPORTED_OPTIONAL_FIELDS: usize = 128;
pub(crate) const MAX_OPTIONAL_FIELD_KEY_BYTES: usize = 256;
pub(crate) const MAX_OPTIONAL_FIELD_KEY_CHARS: usize = 128;
const CHARACTER_CARD_V3_SPEC: &str = "chara_card_v3";

#[derive(Debug, Clone)]
pub(crate) struct CardMetadata {
    pub(crate) name: String,
    pub(crate) description: String,
    pub(crate) unsupported_optional_fields: Vec<String>,
    pub(crate) len_bytes: u64,
}

pub(crate) fn parse_card_json(bytes: &[u8]) -> CoreResult<CardMetadata> {
    if bytes.is_empty() {
        return Err(unsupported("character metadata is empty"));
    }
    if bytes.len() > MAX_METADATA_BYTES {
        return Err(unsupported("character metadata exceeds 4 MiB"));
    }

    let value: Value = serde_json::from_slice(bytes)
        .map_err(|error| unsupported(format!("invalid character JSON: {error}")))?;
    let object = value
        .as_object()
        .ok_or_else(|| unsupported("character metadata must be a JSON object"))?;
    let spec = object
        .get("spec")
        .and_then(Value::as_str)
        .ok_or_else(|| unsupported("character metadata must declare a string spec"))?;
    if spec != CHARACTER_CARD_V3_SPEC {
        return Err(unsupported(format!("unsupported character spec: {spec}")));
    }

    let data = object
        .get("data")
        .and_then(Value::as_object)
        .ok_or_else(|| unsupported("CCv3 metadata must contain a data object"))?;
    let name = data
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| unsupported("CCv3 metadata must contain a string data.name"))?
        .trim();
    if name.is_empty() {
        return Err(unsupported("CCv3 data.name must not be empty"));
    }
    validate_metadata_text(
        "data.name",
        name,
        MAX_CHARACTER_NAME_BYTES,
        MAX_CHARACTER_NAME_CHARS,
    )?;

    let (description_field, description) =
        if let Some(description) = data.get("description").and_then(Value::as_str) {
            (Some("description"), description.trim())
        } else if let Some(personality) = data.get("personality").and_then(Value::as_str) {
            (Some("personality"), personality.trim())
        } else {
            (None, "")
        };
    validate_metadata_text(
        "data.description",
        description,
        MAX_CHARACTER_DESCRIPTION_BYTES,
        MAX_CHARACTER_DESCRIPTION_CHARS,
    )?;
    let unsupported_optional_fields =
        collect_unsupported_optional_fields(data.keys(), description_field)?;

    Ok(CardMetadata {
        name: name.to_owned(),
        description: description.to_owned(),
        unsupported_optional_fields,
        len_bytes: bytes.len() as u64,
    })
}

fn collect_unsupported_optional_fields<'a>(
    keys: impl Iterator<Item = &'a String>,
    description_field: Option<&str>,
) -> CoreResult<Vec<String>> {
    let mut fields = Vec::new();
    for key in keys {
        if key == "name" || description_field == Some(key.as_str()) {
            continue;
        }
        if key.is_empty()
            || key.chars().any(char::is_control)
            || key.len() > MAX_OPTIONAL_FIELD_KEY_BYTES
            || key.chars().count() > MAX_OPTIONAL_FIELD_KEY_CHARS
        {
            return Err(unsupported(format!(
                "CCv3 optional data field name must be non-empty, printable, and at most \
                 {MAX_OPTIONAL_FIELD_KEY_BYTES} bytes or {MAX_OPTIONAL_FIELD_KEY_CHARS} characters"
            )));
        }
        if fields.len() == MAX_UNSUPPORTED_OPTIONAL_FIELDS {
            return Err(unsupported(format!(
                "CCv3 metadata has more than {MAX_UNSUPPORTED_OPTIONAL_FIELDS} unsupported \
                 optional data fields"
            )));
        }
        fields.push(key.clone());
    }
    fields.sort();
    fields.dedup();
    Ok(fields)
}

fn validate_metadata_text(
    field: &str,
    value: &str,
    max_bytes: usize,
    max_chars: usize,
) -> CoreResult<()> {
    if value.len() > max_bytes || value.chars().count() > max_chars {
        return Err(unsupported(format!(
            "CCv3 {field} exceeds the {max_bytes}-byte or {max_chars}-character limit"
        )));
    }
    Ok(())
}

fn unsupported(message: impl Into<String>) -> CoreError {
    CoreError::new(CoreErrorCode::UnsupportedContent, message, false)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn assert_unsupported(bytes: &[u8]) {
        let error = parse_card_json(bytes).expect_err("metadata must be rejected");
        assert_eq!(error.code, CoreErrorCode::UnsupportedContent);
        assert!(!error.recoverable);
    }

    #[test]
    fn requires_an_object_with_v3_spec_data_and_name() {
        for bytes in [
            b"".as_slice(),
            b"null".as_slice(),
            br"[]".as_slice(),
            br"{}".as_slice(),
            br#"{"spec":3,"data":{"name":"Segu"}}"#.as_slice(),
            br#"{"spec":"chara_card_v2","data":{"name":"Segu"}}"#.as_slice(),
            br#"{"spec":"chara_card_v3"}"#.as_slice(),
            br#"{"spec":"chara_card_v3","data":[]}"#.as_slice(),
            br#"{"spec":"chara_card_v3","data":{}}"#.as_slice(),
            br#"{"spec":"chara_card_v3","data":{"name":3}}"#.as_slice(),
            br#"{"spec":"chara_card_v3","data":{"name":"  "}}"#.as_slice(),
        ] {
            assert_unsupported(bytes);
        }
    }

    #[test]
    fn parses_required_and_optional_fields() {
        let metadata = parse_card_json(
            br#"{"spec":"chara_card_v3","data":{"name":" Segu ","description":" Guide "}}"#,
        )
        .expect("valid CCv3 metadata");

        assert_eq!(metadata.name, "Segu");
        assert_eq!(metadata.description, "Guide");
        assert!(metadata.unsupported_optional_fields.is_empty());
    }

    #[test]
    fn reports_sorted_unsupported_fields_and_excludes_only_consumed_text() {
        let description = parse_card_json(
            br#"{
                "spec":"chara_card_v3",
                "data":{
                    "name":"Segu",
                    "description":"Guide",
                    "personality":"Unused fallback",
                    "z_unknown":true,
                    "alternate_greetings":[],
                    "creator":"Synthetic"
                }
            }"#,
        )
        .expect("valid CCv3 metadata");
        assert_eq!(
            description.unsupported_optional_fields,
            ["alternate_greetings", "creator", "personality", "z_unknown"]
        );

        let fallback = parse_card_json(
            br#"{
                "spec":"chara_card_v3",
                "data":{
                    "name":"Segu",
                    "description":null,
                    "personality":"Fallback",
                    "scenario":"Synthetic"
                }
            }"#,
        )
        .expect("valid fallback metadata");
        assert_eq!(fallback.description, "Fallback");
        assert_eq!(
            fallback.unsupported_optional_fields,
            ["description", "scenario"]
        );

        let duplicate = parse_card_json(
            br#"{
                "spec":"chara_card_v3",
                "data":{
                    "name":"Segu",
                    "creator":"First",
                    "creator":"Last"
                }
            }"#,
        )
        .expect("duplicate optional keys remain bounded");
        assert_eq!(duplicate.unsupported_optional_fields, ["creator"]);
    }

    #[test]
    fn bounds_optional_field_names_and_count() {
        let oversized_key = "k".repeat(MAX_OPTIONAL_FIELD_KEY_BYTES + 1);
        let oversized = serde_json::json!({
            "spec": CHARACTER_CARD_V3_SPEC,
            "data": {
                "name": "Segu",
                oversized_key: true,
            }
        });
        assert_unsupported(&serde_json::to_vec(&oversized).expect("encode"));

        let mut data = serde_json::Map::new();
        data.insert("name".to_owned(), Value::String("Segu".to_owned()));
        for index in 0..=MAX_UNSUPPORTED_OPTIONAL_FIELDS {
            data.insert(format!("optional_{index:03}"), Value::Bool(true));
        }
        let too_many = serde_json::json!({
            "spec": CHARACTER_CARD_V3_SPEC,
            "data": data,
        });
        assert_unsupported(&serde_json::to_vec(&too_many).expect("encode"));

        let control_key = serde_json::json!({
            "spec": CHARACTER_CARD_V3_SPEC,
            "data": {
                "name": "Segu",
                "unsafe\nlabel": true,
            }
        });
        assert_unsupported(&serde_json::to_vec(&control_key).expect("encode"));
    }

    #[test]
    fn metadata_limits_are_inclusive_at_multibyte_utf8_boundaries() {
        let name = "😀".repeat(MAX_CHARACTER_NAME_CHARS);
        assert_eq!(name.len(), MAX_CHARACTER_NAME_BYTES);
        let description = "😀".repeat(MAX_CHARACTER_DESCRIPTION_CHARS);
        assert_eq!(description.len(), MAX_CHARACTER_DESCRIPTION_BYTES);
        let json = serde_json::json!({
            "spec": CHARACTER_CARD_V3_SPEC,
            "data": {
                "name": name,
                "description": description,
            }
        });

        let metadata =
            parse_card_json(&serde_json::to_vec(&json).expect("encode")).expect("exact limits");
        assert_eq!(metadata.name.chars().count(), MAX_CHARACTER_NAME_CHARS);
        assert_eq!(
            metadata.description.chars().count(),
            MAX_CHARACTER_DESCRIPTION_CHARS
        );
    }

    #[test]
    fn metadata_limits_reject_one_complete_multibyte_scalar_over_the_boundary() {
        let oversized_name = "😀".repeat(MAX_CHARACTER_NAME_CHARS + 1);
        let name_json = serde_json::json!({
            "spec": CHARACTER_CARD_V3_SPEC,
            "data": {"name": oversized_name}
        });
        let name_error =
            parse_card_json(&serde_json::to_vec(&name_json).expect("encode")).expect_err("name");
        assert_eq!(name_error.code, CoreErrorCode::UnsupportedContent);
        assert_eq!(
            name_error.message,
            "CCv3 data.name exceeds the 1024-byte or 256-character limit"
        );

        let oversized_description = "😀".repeat(MAX_CHARACTER_DESCRIPTION_CHARS + 1);
        let description_json = serde_json::json!({
            "spec": CHARACTER_CARD_V3_SPEC,
            "data": {
                "name": "Segu",
                "description": oversized_description,
            }
        });
        let description_error =
            parse_card_json(&serde_json::to_vec(&description_json).expect("encode"))
                .expect_err("description");
        assert_eq!(description_error.code, CoreErrorCode::UnsupportedContent);
        assert_eq!(
            description_error.message,
            "CCv3 data.description exceeds the 262144-byte or 65536-character limit"
        );
    }
}
