use std::path::{Component, Path};

use unicode_normalization::UnicodeNormalization;

pub(crate) fn validate_archive_path(name: &str) -> Result<String, &'static str> {
    if name.is_empty() || name.contains('\0') {
        return Err("archive entry has an empty or NUL-containing path");
    }
    if name.starts_with('/') || name.starts_with('\\') {
        return Err("archive entry uses an absolute path");
    }
    let normalized_slashes = name.replace('\\', "/");
    if normalized_slashes
        .split('/')
        .next()
        .is_some_and(|part| part.len() == 2 && part.ends_with(':'))
    {
        return Err("archive entry uses a Windows drive path");
    }
    let path = Path::new(&normalized_slashes);
    for component in path.components() {
        if matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        ) {
            return Err("archive entry attempts path traversal");
        }
    }

    let collision_key = normalized_slashes.nfkc().collect::<String>().to_lowercase();
    Ok(collision_key)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_traversal_and_absolute_paths() {
        assert!(validate_archive_path("../secret").is_err());
        assert!(validate_archive_path("/etc/passwd").is_err());
        assert!(validate_archive_path(r"C:\secret").is_err());
    }

    #[test]
    fn normalizes_case_for_collision_detection() {
        assert_eq!(
            validate_archive_path("Assets/Hero.PNG").expect("valid"),
            "assets/hero.png"
        );
    }
}
