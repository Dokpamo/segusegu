use crate::{PlatformError, PlatformErrorCode, PlatformResult};

pub(crate) const MAXIMUM_REFERENCE_BYTES: usize = 256;
pub(crate) const MAXIMUM_CREDENTIAL_READ_BYTES: usize = 32 * 1024;
pub(crate) const MAXIMUM_CREDENTIAL_WRITE_BYTES: usize = 16 * 1024;

pub(crate) fn validate_reference(reference: &str) -> PlatformResult<()> {
    if reference.trim().is_empty() || reference.len() > MAXIMUM_REFERENCE_BYTES {
        return Err(PlatformError::new(PlatformErrorCode::InvalidInput));
    }
    Ok(())
}

pub(crate) fn validate_credential_read(value: &str) -> PlatformResult<()> {
    if value.trim().is_empty() || value.len() > MAXIMUM_CREDENTIAL_READ_BYTES {
        return Err(PlatformError::new(PlatformErrorCode::InvalidInput));
    }
    Ok(())
}

pub(crate) fn validate_credential_write(value: &str) -> PlatformResult<()> {
    if value.trim().is_empty() || value.len() > MAXIMUM_CREDENTIAL_WRITE_BYTES {
        return Err(PlatformError::new(PlatformErrorCode::InvalidInput));
    }
    Ok(())
}

#[cfg(any(desktop, test))]
pub(crate) fn sanitize_display_name(value: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|character| {
            if character.is_control() {
                '\u{fffd}'
            } else {
                character
            }
        })
        .take(255)
        .collect();
    if cleaned.trim().is_empty() {
        "selected-file".to_owned()
    } else {
        cleaned
    }
}

#[cfg(test)]
mod tests {
    use super::{
        sanitize_display_name, validate_credential_read, validate_credential_write,
        validate_reference,
    };

    #[test]
    fn rejects_empty_and_oversized_sensitive_inputs() {
        assert!(validate_reference("").is_err());
        assert!(validate_reference(&"r".repeat(257)).is_err());
        assert!(validate_credential_write("  ").is_err());
        assert!(validate_credential_write(&"s".repeat(16 * 1024 + 1)).is_err());
        assert!(validate_credential_read(&"s".repeat(32 * 1024)).is_ok());
        assert!(validate_credential_read(&"s".repeat(32 * 1024 + 1)).is_err());
    }

    #[test]
    fn display_name_drops_control_characters_and_is_bounded() {
        let output = sanitize_display_name(&format!("a\u{0}{}", "b".repeat(300)));
        assert!(!output.contains('\u{0}'));
        assert_eq!(output.chars().count(), 255);
    }
}
