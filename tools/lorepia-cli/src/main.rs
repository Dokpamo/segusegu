use std::{path::PathBuf, process::ExitCode};

use clap::{Parser, Subcommand};
use lorepia_content::inspect_file;
use lorepia_domain::ImportLimits;
use lorepia_storage::Storage;

#[derive(Parser)]
#[command(name = "lorepia", version, about = "LorePia developer diagnostics")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Print the shared core version.
    Version,
    /// Safely inspect a local character card or CHARX package.
    Inspect { file: PathBuf },
    /// Inspect a `LorePia` data directory.
    Database {
        #[command(subcommand)]
        command: DatabaseCommand,
    },
}

#[derive(Subcommand)]
enum DatabaseCommand {
    Check { path: PathBuf },
    Stats { path: PathBuf },
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!(
                "{}: {} (operation {})",
                error.code.as_str(),
                error.message,
                error.operation_id
            );
            ExitCode::FAILURE
        }
    }
}

fn run(cli: Cli) -> lorepia_domain::CoreResult<()> {
    match cli.command {
        Command::Version => {
            println!("{}", lorepia_core::core_version());
        }
        Command::Inspect { file } => {
            let inspection = inspect_file(&file, ImportLimits::default())?;
            println!(
                "{}",
                serde_json::to_string_pretty(&inspection).map_err(|error| {
                    lorepia_domain::CoreError::internal(format!(
                        "cannot encode inspection: {error}"
                    ))
                })?
            );
        }
        Command::Database { command } => match command {
            DatabaseCommand::Check { path } => {
                let storage = Storage::open(path)?;
                println!(
                    "schema={} recovery_pending={}",
                    storage.schema_version(),
                    storage.recovery_pending()?
                );
            }
            DatabaseCommand::Stats { path } => {
                let stats = Storage::open(path)?.stats()?;
                println!(
                    "characters={} conversations={} messages={} pending_imports={}",
                    stats.characters, stats.conversations, stats.messages, stats.pending_imports
                );
            }
        },
    }
    Ok(())
}
