use std::{
    fs::{self, File},
    path::{Path, PathBuf},
    sync::{Mutex, MutexGuard},
};

use chrono::{DateTime, Utc};
use lorepia_domain::{
    AppSettings, Character, Conversation, ConversationId, CoreError, CoreErrorCode, CoreResult,
    GenerationId, Message, MessageId, MessageRole, MessageStatus,
};
use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

const SCHEMA_VERSION: u32 = 1;
const MIGRATION_0001: &str = include_str!("../migrations/0001_initial.sql");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatabaseStats {
    pub characters: u64,
    pub conversations: u64,
    pub messages: u64,
    pub pending_imports: u64,
}

pub struct Storage {
    root: PathBuf,
    connection: Mutex<Connection>,
}

impl Storage {
    pub fn open(root: impl AsRef<Path>) -> CoreResult<Self> {
        let root = root.as_ref().to_path_buf();
        for relative in [
            "db",
            "sources/sha256",
            "assets/sha256",
            "cache/thumbnails",
            "cache/extracted",
            "staging",
            "recovery",
        ] {
            fs::create_dir_all(root.join(relative)).map_err(storage_io_error)?;
        }

        let mut connection =
            Connection::open(root.join("db/lorepia.sqlite3")).map_err(storage_db_error)?;
        connection
            .pragma_update(None, "foreign_keys", true)
            .map_err(storage_db_error)?;
        connection
            .pragma_update(None, "journal_mode", "WAL")
            .map_err(storage_db_error)?;
        apply_migrations(&mut connection)?;

        Ok(Self {
            root,
            connection: Mutex::new(connection),
        })
    }

    pub fn data_root(&self) -> &Path {
        &self.root
    }

    pub fn staging_dir(&self) -> PathBuf {
        self.root.join("staging")
    }

    pub const fn schema_version(&self) -> u32 {
        SCHEMA_VERSION
    }

    pub fn recovery_pending(&self) -> CoreResult<bool> {
        self.connection()?
            .query_row("SELECT EXISTS(SELECT 1 FROM import_jobs)", [], |row| {
                row.get::<_, bool>(0)
            })
            .map_err(storage_db_error)
    }

    pub fn commit_character_import(
        &self,
        staged_path: &Path,
        character: &Character,
        source_size: u64,
        import_job_id: &str,
    ) -> CoreResult<()> {
        let now = Utc::now().to_rfc3339();
        {
            let connection = self.connection()?;
            connection
                .execute(
                    "INSERT OR REPLACE INTO import_jobs
                     (id, source_hash, staging_path, state, updated_at)
                     VALUES (?1, ?2, ?3, 'preparing', ?4)",
                    params![
                        import_job_id,
                        character.source_hash,
                        staged_path.to_string_lossy(),
                        now
                    ],
                )
                .map_err(storage_db_error)?;
        }

        let relative_path = content_relative_path(&character.source_hash)?;
        let final_path = self.root.join("sources").join(&relative_path);
        let mut created_source = false;
        if !final_path.exists() {
            let parent = final_path
                .parent()
                .ok_or_else(|| CoreError::internal("source path has no parent"))?;
            fs::create_dir_all(parent).map_err(storage_io_error)?;
            let temp_path = parent.join(format!(".{}.partial", Uuid::new_v4()));
            fs::copy(staged_path, &temp_path).map_err(storage_io_error)?;
            File::open(&temp_path)
                .and_then(|file| file.sync_all())
                .map_err(storage_io_error)?;
            fs::rename(&temp_path, &final_path).map_err(storage_io_error)?;
            created_source = true;
        }

        {
            let connection = self.connection()?;
            connection
                .execute(
                    "UPDATE import_jobs SET state = 'file_stored', updated_at = ?2 WHERE id = ?1",
                    params![import_job_id, Utc::now().to_rfc3339()],
                )
                .map_err(storage_db_error)?;
        }

        let result = (|| {
            let mut connection = self.connection()?;
            let transaction = connection.transaction().map_err(storage_db_error)?;
            transaction
                .execute(
                    "INSERT OR IGNORE INTO content_sources
                     (sha256, relative_path, size_bytes, created_at)
                     VALUES (?1, ?2, ?3, ?4)",
                    params![
                        character.source_hash,
                        format!("sources/{relative_path}"),
                        u64_to_i64(source_size)?,
                        Utc::now().to_rfc3339()
                    ],
                )
                .map_err(storage_db_error)?;
            transaction
                .execute(
                    "INSERT INTO characters
                     (id, name, description, source_hash, avatar_asset_hash, created_at)
                     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        character.id,
                        character.name,
                        character.description,
                        character.source_hash,
                        character.avatar_asset_hash,
                        character.created_at.to_rfc3339()
                    ],
                )
                .map_err(storage_db_error)?;
            transaction
                .execute("DELETE FROM import_jobs WHERE id = ?1", [import_job_id])
                .map_err(storage_db_error)?;
            transaction.commit().map_err(storage_db_error)
        })();

        if result.is_err() && created_source {
            // Keep the immutable content-addressed source. A later successful import can
            // reuse it, and the import journal records the unfinished database step.
        }
        result
    }

    pub fn list_characters(&self) -> CoreResult<Vec<Character>> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT id, name, description, source_hash, avatar_asset_hash, created_at
                 FROM characters ORDER BY name COLLATE NOCASE, id",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map([], map_character)
            .map_err(storage_db_error)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(storage_db_error)
    }

    pub fn get_character(&self, id: &str) -> CoreResult<Character> {
        self.connection()?
            .query_row(
                "SELECT id, name, description, source_hash, avatar_asset_hash, created_at
                 FROM characters WHERE id = ?1",
                [id],
                map_character,
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(CoreErrorCode::NotFound, "character was not found", false)
            })
    }

    pub fn save_conversation(&self, conversation: &Conversation) -> CoreResult<()> {
        self.connection()?
            .execute(
                "INSERT INTO conversations
                 (id, character_id, title, created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5)",
                params![
                    conversation.id.0,
                    conversation.character_id,
                    conversation.title,
                    conversation.created_at.to_rfc3339(),
                    conversation.updated_at.to_rfc3339()
                ],
            )
            .map_err(storage_db_error)?;
        Ok(())
    }

    pub fn list_conversations(&self) -> CoreResult<Vec<Conversation>> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT id, character_id, title, created_at, updated_at
                 FROM conversations ORDER BY updated_at DESC, id",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok(Conversation {
                    id: ConversationId(row.get(0)?),
                    character_id: row.get(1)?,
                    title: row.get(2)?,
                    created_at: parse_datetime_sql(row.get::<_, String>(3)?, 3)?,
                    updated_at: parse_datetime_sql(row.get::<_, String>(4)?, 4)?,
                })
            })
            .map_err(storage_db_error)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(storage_db_error)
    }

    pub fn get_conversation(&self, id: &ConversationId) -> CoreResult<Conversation> {
        self.connection()?
            .query_row(
                "SELECT id, character_id, title, created_at, updated_at
                 FROM conversations WHERE id = ?1",
                [&id.0],
                |row| {
                    Ok(Conversation {
                        id: ConversationId(row.get(0)?),
                        character_id: row.get(1)?,
                        title: row.get(2)?,
                        created_at: parse_datetime_sql(row.get::<_, String>(3)?, 3)?,
                        updated_at: parse_datetime_sql(row.get::<_, String>(4)?, 4)?,
                    })
                },
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(CoreErrorCode::NotFound, "conversation was not found", false)
            })
    }

    pub fn save_message(&self, message: &Message) -> CoreResult<()> {
        self.connection()?
            .execute(
                "INSERT OR REPLACE INTO messages
                 (id, conversation_id, parent_id, role, content, status, generation_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                params![
                    message.id.0,
                    message.conversation_id.0,
                    message.parent_id.as_ref().map(|value| value.0.as_str()),
                    role_to_str(message.role),
                    message.content,
                    status_to_str(message.status),
                    message.generation_id.as_ref().map(|value| value.0.as_str()),
                    message.created_at.to_rfc3339()
                ],
            )
            .map_err(storage_db_error)?;
        Ok(())
    }

    pub fn list_messages(&self, conversation_id: &ConversationId) -> CoreResult<Vec<Message>> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT id, conversation_id, parent_id, role, content, status,
                        generation_id, created_at
                 FROM messages WHERE conversation_id = ?1
                 ORDER BY created_at, id",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map([&conversation_id.0], |row| {
                let role: String = row.get(3)?;
                let status: String = row.get(5)?;
                Ok(Message {
                    id: MessageId(row.get(0)?),
                    conversation_id: ConversationId(row.get(1)?),
                    parent_id: row.get::<_, Option<String>>(2)?.map(MessageId),
                    role: str_to_role(&role, 3)?,
                    content: row.get(4)?,
                    status: str_to_status(&status, 5)?,
                    generation_id: row.get::<_, Option<String>>(6)?.map(GenerationId),
                    created_at: parse_datetime_sql(row.get::<_, String>(7)?, 7)?,
                })
            })
            .map_err(storage_db_error)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(storage_db_error)
    }

    pub fn load_settings(&self) -> CoreResult<AppSettings> {
        let json = self
            .connection()?
            .query_row(
                "SELECT value_json FROM app_settings WHERE key = 'application'",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(storage_db_error)?;
        json.map_or_else(
            || Ok(AppSettings::default()),
            |value| {
                serde_json::from_str(&value).map_err(|error| {
                    CoreError::new(
                        CoreErrorCode::StorageCorrupted,
                        format!("stored settings are invalid: {error}"),
                        false,
                    )
                })
            },
        )
    }

    pub fn save_settings(&self, settings: &AppSettings) -> CoreResult<()> {
        let json = serde_json::to_string(settings)
            .map_err(|error| CoreError::internal(format!("cannot encode settings: {error}")))?;
        self.connection()?
            .execute(
                "INSERT INTO app_settings (key, value_json) VALUES ('application', ?1)
                 ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json",
                [json],
            )
            .map_err(storage_db_error)?;
        Ok(())
    }

    pub fn stats(&self) -> CoreResult<DatabaseStats> {
        let connection = self.connection()?;
        Ok(DatabaseStats {
            characters: count(&connection, "characters")?,
            conversations: count(&connection, "conversations")?,
            messages: count(&connection, "messages")?,
            pending_imports: count(&connection, "import_jobs")?,
        })
    }

    fn connection(&self) -> CoreResult<MutexGuard<'_, Connection>> {
        self.connection.lock().map_err(|_| {
            CoreError::new(
                CoreErrorCode::StorageUnavailable,
                "database lock was poisoned",
                true,
            )
        })
    }
}

fn apply_migrations(connection: &mut Connection) -> CoreResult<()> {
    connection
        .execute_batch(MIGRATION_0001)
        .map_err(storage_db_error)?;
    connection
        .execute(
            "INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (?1, ?2)",
            params![SCHEMA_VERSION, Utc::now().to_rfc3339()],
        )
        .map_err(storage_db_error)?;
    Ok(())
}

fn content_relative_path(hash: &str) -> CoreResult<String> {
    if hash.len() != 64 || !hash.bytes().all(|value| value.is_ascii_hexdigit()) {
        return Err(CoreError::invalid(
            "source hash is not a SHA-256 hex digest",
        ));
    }
    Ok(format!("sha256/{}/{}", &hash[..2], &hash[2..]))
}

fn map_character(row: &rusqlite::Row<'_>) -> rusqlite::Result<Character> {
    Ok(Character {
        id: row.get(0)?,
        name: row.get(1)?,
        description: row.get(2)?,
        source_hash: row.get(3)?,
        avatar_asset_hash: row.get(4)?,
        created_at: parse_datetime_sql(row.get::<_, String>(5)?, 5)?,
    })
}

fn parse_datetime_sql(value: String, column: usize) -> rusqlite::Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(&value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| {
            rusqlite::Error::FromSqlConversionFailure(
                column,
                rusqlite::types::Type::Text,
                Box::new(error),
            )
        })
}

fn role_to_str(role: MessageRole) -> &'static str {
    match role {
        MessageRole::System => "system",
        MessageRole::User => "user",
        MessageRole::Assistant => "assistant",
    }
}

fn str_to_role(value: &str, column: usize) -> rusqlite::Result<MessageRole> {
    match value {
        "system" => Ok(MessageRole::System),
        "user" => Ok(MessageRole::User),
        "assistant" => Ok(MessageRole::Assistant),
        other => Err(invalid_enum(column, "message role", other)),
    }
}

fn status_to_str(status: MessageStatus) -> &'static str {
    match status {
        MessageStatus::Pending => "pending",
        MessageStatus::Complete => "complete",
        MessageStatus::Cancelled => "cancelled",
        MessageStatus::Failed => "failed",
    }
}

fn str_to_status(value: &str, column: usize) -> rusqlite::Result<MessageStatus> {
    match value {
        "pending" => Ok(MessageStatus::Pending),
        "complete" => Ok(MessageStatus::Complete),
        "cancelled" => Ok(MessageStatus::Cancelled),
        "failed" => Ok(MessageStatus::Failed),
        other => Err(invalid_enum(column, "message status", other)),
    }
}

fn invalid_enum(column: usize, kind: &str, value: &str) -> rusqlite::Error {
    rusqlite::Error::FromSqlConversionFailure(
        column,
        rusqlite::types::Type::Text,
        format!("invalid {kind}: {value}").into(),
    )
}

fn count(connection: &Connection, table: &str) -> CoreResult<u64> {
    let sql = format!("SELECT COUNT(*) FROM {table}");
    let value = connection
        .query_row(&sql, [], |row| row.get::<_, i64>(0))
        .map_err(storage_db_error)?;
    u64::try_from(value).map_err(|_| CoreError::internal("negative database row count"))
}

fn u64_to_i64(value: u64) -> CoreResult<i64> {
    i64::try_from(value).map_err(|_| CoreError::invalid("value exceeds SQLite integer range"))
}

fn storage_io_error(error: std::io::Error) -> CoreError {
    CoreError::new(
        CoreErrorCode::StorageUnavailable,
        format!("local storage operation failed: {error}"),
        true,
    )
}

fn storage_db_error(error: rusqlite::Error) -> CoreError {
    CoreError::new(
        CoreErrorCode::StorageUnavailable,
        format!("SQLite operation failed: {error}"),
        true,
    )
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use tempfile::{NamedTempFile, tempdir};

    use super::*;

    #[test]
    fn persists_character_and_settings_across_reopen() {
        let root = tempdir().expect("temp root");
        let mut staged = NamedTempFile::new_in(root.path()).expect("staging");
        staged.write_all(b"character").expect("source");
        let character = Character::new("Segu", "Guide", "a".repeat(64));

        {
            let storage = Storage::open(root.path()).expect("open storage");
            storage
                .commit_character_import(staged.path(), &character, 9, &Uuid::new_v4().to_string())
                .expect("commit import");
            storage
                .save_settings(&AppSettings {
                    preserve_partial_generations: false,
                    selected_provider_profile_id: Some("local".to_owned()),
                })
                .expect("save settings");
        }

        let reopened = Storage::open(root.path()).expect("reopen storage");
        assert_eq!(reopened.list_characters().expect("list").len(), 1);
        assert!(
            !reopened
                .load_settings()
                .expect("load settings")
                .preserve_partial_generations
        );
    }
}
