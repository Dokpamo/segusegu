use std::{
    ffi::OsString,
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, Subcommand, ValueEnum};
use zip::{ZipWriter, write::SimpleFileOptions};

#[derive(Parser)]
#[command(about = "Repository automation for LorePia")]
struct Cli {
    #[command(subcommand)]
    command: Task,
}

#[derive(Subcommand)]
enum Task {
    Bindings { language: BindingLanguage },
    Build { platform: Platform },
    Check { target: CheckTarget },
    Testdata { action: TestdataAction },
}

#[derive(Clone, Copy, ValueEnum)]
enum BindingLanguage {
    Kotlin,
    Swift,
}

#[derive(Clone, Copy, ValueEnum)]
enum Platform {
    Android,
    Apple,
    Windows,
}

#[derive(Clone, Copy, ValueEnum)]
enum CheckTarget {
    Repository,
}

#[derive(Clone, Copy, ValueEnum)]
enum TestdataAction {
    Regenerate,
}

fn main() -> Result<()> {
    let root = workspace_root()?;
    match Cli::parse().command {
        Task::Bindings { language } => generate_bindings(&root, language),
        Task::Build { platform } => run_platform_build(&root, platform),
        Task::Check {
            target: CheckTarget::Repository,
        } => check_repository(&root),
        Task::Testdata {
            action: TestdataAction::Regenerate,
        } => regenerate_testdata(&root),
    }
}

fn workspace_root() -> Result<PathBuf> {
    let manifest = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    manifest
        .ancestors()
        .nth(2)
        .map(Path::to_path_buf)
        .ok_or_else(|| anyhow!("cannot locate workspace root"))
}

fn generate_bindings(root: &Path, language: BindingLanguage) -> Result<()> {
    run(
        root,
        "cargo",
        ["build", "-p", "lorepia-uniffi"].map(OsString::from),
    )?;
    let library = root.join("target/debug").join(native_library_name());
    if !library.is_file() {
        bail!("UniFFI library was not built at {}", library.display());
    }
    let (language_name, output) = match language {
        BindingLanguage::Kotlin => ("kotlin", root.join("apps/android/app/src/main/generated")),
        BindingLanguage::Swift => (
            "swift",
            root.join("apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated"),
        ),
    };
    fs::create_dir_all(&output)?;
    let arguments = vec![
        OsString::from("run"),
        OsString::from("-p"),
        OsString::from("lorepia-uniffi"),
        OsString::from("--bin"),
        OsString::from("uniffi-bindgen"),
        OsString::from("--"),
        OsString::from("generate"),
        OsString::from("--library"),
        library.into_os_string(),
        OsString::from("--language"),
        OsString::from(language_name),
        OsString::from("--out-dir"),
        output.into_os_string(),
        OsString::from("--config"),
        root.join("bindings/uniffi/uniffi.toml").into_os_string(),
    ];
    run(root, "cargo", arguments)
}

fn native_library_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "lorepia_uniffi.dll"
    } else if cfg!(target_os = "macos") {
        "liblorepia_uniffi.dylib"
    } else {
        "liblorepia_uniffi.so"
    }
}

fn run_platform_build(root: &Path, platform: Platform) -> Result<()> {
    match platform {
        Platform::Android => run(root, "bash", [OsString::from("scripts/build-android.sh")]),
        Platform::Apple => run(root, "bash", [OsString::from("scripts/build-apple.sh")]),
        Platform::Windows => {
            if cfg!(target_os = "windows") {
                run(root, "pwsh", [OsString::from("scripts/build-windows.ps1")])
            } else {
                bail!("Windows build requires a Windows host")
            }
        }
    }
}

fn check_repository(root: &Path) -> Result<()> {
    let output = Command::new("git")
        .args(["ls-files", "-z"])
        .current_dir(root)
        .output()
        .context("run git ls-files")?;
    if !output.status.success() {
        bail!("git ls-files failed");
    }
    let tracked_files = output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|p| !p.is_empty())
        .map(|bytes| String::from_utf8_lossy(bytes).into_owned())
        .collect::<Vec<_>>();
    let mut testdata_total_bytes = 0_u64;
    for relative in &tracked_files {
        let path = root.join(relative);
        if is_license_file(relative) {
            bail!("this private-code repository must not track a license file: {relative}");
        }
        if is_forbidden_tracked_name(relative) {
            bail!("forbidden tracked file: {relative}");
        }
        if has_forbidden_tracked_extension(&path) {
            bail!("forbidden binary, credential, or diagnostic file: {relative}");
        }
        if contains_generated_bundle_component(relative) {
            bail!("forbidden generated bundle: {relative}");
        }
        let file_size = path.metadata()?.len();
        if is_source_file(&path) && path.metadata()?.len() == 0 {
            bail!("empty source file: {relative}");
        }
        if relative.starts_with("testdata/") && file_size > 2 * 1024 * 1024 {
            bail!("testdata file exceeds 2 MiB: {relative}");
        }
        if relative.starts_with("testdata/") {
            testdata_total_bytes = testdata_total_bytes.saturating_add(file_size);
        }
        if file_size > 5 * 1024 * 1024 {
            bail!("tracked file exceeds 5 MiB: {relative}");
        }
    }
    if testdata_total_bytes > 16 * 1024 * 1024 {
        bail!("tracked testdata exceeds 16 MiB in total");
    }

    for relative in tracked_files.iter().filter(|relative| {
        Path::new(relative)
            .extension()
            .is_some_and(|extension| extension.eq_ignore_ascii_case("md"))
    }) {
        let path = root.join(relative);
        let text = fs::read_to_string(&path)?;
        if text.trim().is_empty() {
            bail!("empty documentation file: {}", path.display());
        }
        check_markdown_links(root, &path, &text)?;
    }
    check_generated_source_headers(root)?;
    println!("repository checks passed");
    Ok(())
}

fn is_license_file(relative: &str) -> bool {
    let Some(name) = Path::new(relative)
        .file_name()
        .and_then(|name| name.to_str())
    else {
        return false;
    };
    let normalized = name.to_ascii_uppercase();
    ["LICENSE", "LICENCE", "COPYING"].iter().any(|stem| {
        normalized == *stem
            || normalized
                .strip_prefix(stem)
                .is_some_and(|suffix| suffix.starts_with('.'))
    })
}

fn is_forbidden_tracked_name(relative: &str) -> bool {
    let Some(name) = Path::new(relative)
        .file_name()
        .and_then(|name| name.to_str())
    else {
        return false;
    };
    let normalized = name.to_ascii_lowercase();
    normalized == "lorepia_new_multiplatform_repository_private_guide.md"
        || normalized == ".ds_store"
        || normalized == ".env"
        || (normalized.starts_with(".env.") && normalized != ".env.example")
        || [
            "keystore.properties",
            "secrets.properties",
            "local.properties",
        ]
        .contains(&normalized.as_str())
}

fn has_forbidden_tracked_extension(path: &Path) -> bool {
    let Some(extension) = path.extension().and_then(|value| value.to_str()) else {
        return false;
    };
    let normalized = extension.to_ascii_lowercase();
    [
        "a",
        "aab",
        "apk",
        "app",
        "appx",
        "dll",
        "dylib",
        "exe",
        "framework",
        "ipa",
        "jks",
        "key",
        "keystore",
        "lib",
        "log",
        "mobileprovision",
        "msix",
        "p12",
        "p8",
        "pdb",
        "pem",
        "pfx",
        "so",
        "sqlite",
        "sqlite3",
        "xcframework",
    ]
    .contains(&normalized.as_str())
}

fn contains_generated_bundle_component(relative: &str) -> bool {
    Path::new(relative).components().any(|component| {
        let normalized = component.as_os_str().to_string_lossy().to_ascii_lowercase();
        if normalized == "lorepia.app"
            && (relative == "apps/windows/Lorepia.App"
                || relative.starts_with("apps/windows/Lorepia.App/"))
        {
            return false;
        }
        [".app", ".framework", ".xcarchive", ".xcframework"]
            .iter()
            .any(|suffix| normalized.ends_with(suffix))
    })
}

fn check_markdown_links(root: &Path, document: &Path, text: &str) -> Result<()> {
    let mut remaining = text;
    while let Some(label_end) = remaining.find("](") {
        remaining = &remaining[label_end + 2..];
        let Some(target_end) = remaining.find(')') else {
            break;
        };
        let target = remaining[..target_end].trim().trim_matches(['<', '>']);
        remaining = &remaining[target_end + 1..];
        if target.is_empty()
            || target.starts_with('#')
            || target.contains("://")
            || target.starts_with("mailto:")
        {
            continue;
        }
        let path_part = target.split(['#', '?']).next().unwrap_or(target);
        if path_part.is_empty() {
            continue;
        }
        let resolved = document
            .parent()
            .unwrap_or(root)
            .join(path_part.replace("%20", " "));
        if !resolved.exists() {
            let relative_document = document.strip_prefix(root).unwrap_or(document);
            bail!(
                "broken documentation link in {}: {target}",
                relative_document.display()
            );
        }
    }
    Ok(())
}

fn check_generated_source_headers(root: &Path) -> Result<()> {
    for relative in [
        "apps/android/app/src/main/generated/dev/lorepia/core/lorepia_uniffi.kt",
        "apps/apple/Packages/LorepiaKit/Sources/LorepiaKit/Bridge/Generated/LorepiaCore.swift",
    ] {
        let path = root.join(relative);
        let text = fs::read_to_string(&path)
            .with_context(|| format!("read generated source header: {relative}"))?;
        if !text
            .lines()
            .take(4)
            .any(|line| line.contains("autogenerated"))
        {
            bail!("generated source is missing its provenance header: {relative}");
        }
    }
    let canonical_header = fs::read(root.join("bindings/c-api/include/lorepia.h"))?;
    let windows_header = fs::read(root.join("apps/windows/include/lorepia.h"))?;
    if canonical_header != windows_header {
        bail!("Windows C header mirror differs from bindings/c-api/include/lorepia.h");
    }
    Ok(())
}

fn is_source_file(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .is_some_and(|extension| {
            [
                "rs",
                "kt",
                "kts",
                "swift",
                "cs",
                "xaml",
                "c",
                "h",
                "cpp",
                "hpp",
                "sh",
                "ps1",
                "sql",
                "xml",
                "properties",
                "json",
                "toml",
                "yml",
                "yaml",
                "md",
            ]
            .contains(&extension)
        })
}

fn regenerate_testdata(root: &Path) -> Result<()> {
    let testdata = root.join("testdata");
    fs::create_dir_all(testdata.join("cards"))?;
    fs::create_dir_all(testdata.join("packages"))?;
    fs::create_dir_all(testdata.join("archives"))?;
    fs::write(
        testdata.join("cards/minimal-v3.json"),
        concat!(
            "{\n",
            "  \"spec\": \"chara_card_v3\",\n",
            "  \"spec_version\": \"3.0\",\n",
            "  \"data\": {\n",
            "    \"name\": \"Synthetic Guide\",\n",
            "    \"description\": \"Project-owned test character.\"\n",
            "  }\n",
            "}\n"
        ),
    )?;
    write_zip(
        &testdata.join("packages/minimal.charx"),
        &[(
            "card.json",
            br#"{"spec":"chara_card_v3","data":{"name":"Synthetic CHARX","description":"Test package"}}"#,
        )],
    )?;
    write_zip(
        &testdata.join("packages/with-avatar.charx"),
        &[
            (
                "card.json",
                br#"{"spec":"chara_card_v3","data":{"name":"Synthetic Avatar","description":"Asset persistence fixture"}}"#,
            ),
            ("assets/avatar.png", TINY_PNG),
        ],
    )?;
    write_zip(
        &testdata.join("archives/traversal.zip"),
        &[("../escape.json", b"{}")],
    )?;
    write_zip(
        &testdata.join("archives/absolute-path.zip"),
        &[("/absolute.json", b"{}")],
    )?;
    write_zip(
        &testdata.join("archives/case-collision.zip"),
        &[("Assets/A.png", b"one"), ("assets/a.PNG", b"two")],
    )?;
    write_zip(
        &testdata.join("archives/unicode-collision.zip"),
        &[("cafe\u{301}.json", b"{}"), ("caf\u{e9}.json", b"{}")],
    )?;
    let compressible_payload = vec![b'a'; 128 * 1024];
    write_zip(
        &testdata.join("archives/high-ratio.zip"),
        &[("card.json", &compressible_payload)],
    )?;
    write_zip(
        &testdata.join("archives/mime-mismatch.zip"),
        &[
            (
                "card.json",
                br#"{"spec":"chara_card_v3","data":{"name":"MIME test","description":"Synthetic"}}"#,
            ),
            ("image.png", b"not-a-png"),
        ],
    )?;
    println!("regenerated synthetic testdata");
    Ok(())
}

const TINY_PNG: &[u8] = &[
    0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, b'I', b'H', b'D', b'R',
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0d, b'I', b'D', b'A', b'T', 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, b'I', b'E',
    b'N', b'D', 0xae, 0x42, 0x60, 0x82,
];

fn write_zip(path: &Path, entries: &[(&str, &[u8])]) -> Result<()> {
    let file = File::create(path)?;
    let mut archive = ZipWriter::new(file);
    let options = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .unix_permissions(0o644);
    for (name, bytes) in entries {
        archive.start_file(*name, options)?;
        archive.write_all(bytes)?;
    }
    archive.finish()?;
    Ok(())
}

fn run(root: &Path, program: &str, arguments: impl IntoIterator<Item = OsString>) -> Result<()> {
    let status = Command::new(program)
        .args(arguments)
        .current_dir(root)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .status()
        .with_context(|| format!("run {program}"))?;
    if !status.success() {
        bail!("{program} failed with {status}");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{
        contains_generated_bundle_component, has_forbidden_tracked_extension,
        is_forbidden_tracked_name, is_license_file, is_source_file,
    };
    use std::path::Path;

    #[test]
    fn recognizes_license_name_variants() {
        assert!(is_license_file("LICENSE"));
        assert!(is_license_file("docs/LICENSE.txt"));
        assert!(is_license_file("LICENCE.md"));
        assert!(is_license_file("COPYING"));
        assert!(!is_license_file("docs/licensing-policy.md"));
    }

    #[test]
    fn recognizes_files_inside_generated_bundles() {
        assert!(contains_generated_bundle_component(
            "Artifacts/Core.xcframework/Info.plist"
        ));
        assert!(contains_generated_bundle_component(
            "Build/LorePia.framework/Headers/LorePia.h"
        ));
        assert!(contains_generated_bundle_component(
            "Build/LorePia.app/Contents/MacOS/LorePia"
        ));
        assert!(contains_generated_bundle_component(
            "Build/LorePia.xcarchive/Info.plist"
        ));
        assert!(!contains_generated_bundle_component(
            "apps/windows/Lorepia.App/App.xaml"
        ));
        assert!(!contains_generated_bundle_component(
            "apps/apple/project.yml"
        ));
    }

    #[test]
    fn recognizes_credentials_logs_and_native_outputs_case_insensitively() {
        for path in [
            "signing.JKS",
            "developer.keystore",
            "auth.PEM",
            "private.KEY",
            "apple/AuthKey.P8",
            "build/diagnostic.LOG",
            "output/LorePia.EXE",
            "signing/windows.PFX",
            "fixtures/private.SQLITE",
            "fixtures/private.SQLITE3",
        ] {
            assert!(
                has_forbidden_tracked_extension(Path::new(path)),
                "missed {path}"
            );
        }
        assert!(!has_forbidden_tracked_extension(Path::new(
            "docs/signing.md"
        )));
    }

    #[test]
    fn recognizes_sensitive_names_but_allows_environment_template() {
        for path in [
            ".env",
            "config/.env.production",
            "android/keystore.properties",
            "android/secrets.properties",
            "android/local.properties",
            "LorePia_new_multiplatform_repository_private_guide.md",
        ] {
            assert!(is_forbidden_tracked_name(path), "missed {path}");
        }
        assert!(!is_forbidden_tracked_name(".env.example"));
    }

    #[test]
    fn source_file_guard_covers_build_and_contract_sources() {
        for path in [
            "script.sh",
            "script.ps1",
            "migration.sql",
            "header.h",
            "manifest.xml",
            "gradle.properties",
            "fixture.json",
        ] {
            assert!(is_source_file(Path::new(path)), "missed {path}");
        }
    }
}
