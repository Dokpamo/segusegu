use std::{
    ffi::OsString,
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
    process::{Command, Stdio},
};

use anyhow::{Context, Result, anyhow, bail};
use clap::{Parser, Subcommand, ValueEnum};
use walkdir::WalkDir;
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
    if root.join("LICENSE").exists() || root.join("LICENSE.md").exists() {
        bail!("this private-code repository must not contain a license file");
    }
    let output = Command::new("git")
        .args(["ls-files", "-z"])
        .current_dir(root)
        .output()
        .context("run git ls-files")?;
    if !output.status.success() {
        bail!("git ls-files failed");
    }
    let forbidden_names = [
        "LorePia_new_multiplatform_repository_private_guide.md",
        ".env",
        ".DS_Store",
    ];
    let forbidden_extensions = [
        "apk",
        "aab",
        "dll",
        "dylib",
        "so",
        "pdb",
        "xcframework",
        "appx",
        "msix",
    ];
    for bytes in output
        .stdout
        .split(|byte| *byte == 0)
        .filter(|p| !p.is_empty())
    {
        let relative = String::from_utf8_lossy(bytes);
        let path = root.join(relative.as_ref());
        if forbidden_names
            .iter()
            .any(|name| relative == *name || relative.ends_with(&format!("/{name}")))
        {
            bail!("forbidden tracked file: {relative}");
        }
        if path
            .extension()
            .and_then(|value| value.to_str())
            .is_some_and(|extension| forbidden_extensions.contains(&extension))
        {
            bail!("forbidden generated binary: {relative}");
        }
        if is_source_file(&path) && path.metadata()?.len() == 0 {
            bail!("empty source file: {relative}");
        }
        if relative.starts_with("testdata/") && path.metadata()?.len() > 2 * 1024 * 1024 {
            bail!("testdata file exceeds 2 MiB: {relative}");
        }
    }

    for entry in WalkDir::new(root.join("docs"))
        .into_iter()
        .filter_map(Result::ok)
    {
        if entry.file_type().is_file() && entry.path().extension().is_some_and(|ext| ext == "md") {
            let text = fs::read_to_string(entry.path())?;
            if text.trim().is_empty() {
                bail!("empty documentation file: {}", entry.path().display());
            }
        }
    }
    println!("repository checks passed");
    Ok(())
}

fn is_source_file(path: &Path) -> bool {
    path.extension()
        .and_then(|value| value.to_str())
        .is_some_and(|extension| {
            [
                "rs", "kt", "kts", "swift", "cs", "xaml", "toml", "yml", "yaml", "md",
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
