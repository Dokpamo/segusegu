use std::path::PathBuf;

use lorepia_content::inspect_file;
use lorepia_domain::{ContentKind, CoreErrorCode, ImportLimits};

fn fixture(relative: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../testdata")
        .join(relative)
}

#[test]
fn accepts_project_owned_valid_fixtures() {
    let json = inspect_file(&fixture("cards/minimal-v3.json"), ImportLimits::default())
        .expect("minimal JSON");
    assert_eq!(json.kind, ContentKind::CharacterCardV3);

    let charx = inspect_file(&fixture("packages/minimal.charx"), ImportLimits::default())
        .expect("minimal CHARX");
    assert_eq!(charx.kind, ContentKind::CharxPackage);
}

#[test]
fn blocks_unsafe_archive_paths_and_collisions() {
    for relative in [
        "archives/traversal.zip",
        "archives/absolute-path.zip",
        "archives/case-collision.zip",
        "archives/unicode-collision.zip",
        "archives/high-ratio.zip",
    ] {
        let error = inspect_file(&fixture(relative), ImportLimits::default())
            .expect_err("unsafe archive must be blocked");
        assert_eq!(error.code, CoreErrorCode::UnsafeArchive, "{relative}");
    }
}

#[test]
fn reports_asset_mime_mismatch() {
    let inspection = inspect_file(
        &fixture("archives/mime-mismatch.zip"),
        ImportLimits::default(),
    )
    .expect("package remains reviewable");
    assert!(
        inspection
            .warnings
            .iter()
            .any(|warning| warning.code == "mime_mismatch")
    );
}
