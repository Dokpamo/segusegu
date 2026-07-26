use std::{
    fs::{self, File, OpenOptions},
    io::{BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::{Mutex, MutexGuard},
};

use chrono::{DateTime, Utc};
use lorepia_domain::{
    AppSettings, Character, Conversation, ConversationId, CoreError, CoreErrorCode, CoreResult,
    GenerationId, Message, MessageId, MessageRole, MessageStatus, ProviderProfile,
};
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const SCHEMA_VERSION: u32 = 2;
const MIGRATION_0001: &str = include_str!("../migrations/0001_initial.sql");
const MIGRATION_0002: &str = include_str!("../migrations/0002_import_asset_recovery.sql");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatabaseStats {
    pub characters: u64,
    pub conversations: u64,
    pub messages: u64,
    pub pending_imports: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StagedAssetImport {
    pub staged_path: PathBuf,
    pub sha256: String,
    pub media_type: String,
    pub size_bytes: u64,
}

pub struct Storage {
    root: PathBuf,
    connection: Mutex<Connection>,
}

struct InterruptedImport {
    id: String,
    source_hash: String,
    staging_path: String,
    state: String,
    asset_hashes: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ImportCommitPhase {
    JournalCreated,
    CasFilesDurable,
    JournalMarkedFileStored,
    RecordsCommitted,
}

impl Storage {
    pub fn open(root: impl AsRef<Path>) -> CoreResult<Self> {
        let root = root.as_ref().to_path_buf();
        fs::create_dir_all(&root).map_err(storage_io_error)?;
        for relative in [
            "db",
            "sources/sha256",
            "assets/sha256",
            "cache/thumbnails",
            "cache/extracted",
            "staging",
            "recovery",
        ] {
            create_owned_directory_tree(&root, Path::new(relative))?;
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
        recover_interrupted_work(&root, &mut connection)?;
        remove_abandoned_staging_files(&root.join("staging"))?;

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
        staged_assets: &[StagedAssetImport],
    ) -> CoreResult<()> {
        self.commit_character_import_observed(
            staged_path,
            character,
            source_size,
            import_job_id,
            staged_assets,
            |_| {},
        )
    }

    fn commit_character_import_observed(
        &self,
        staged_path: &Path,
        character: &Character,
        source_size: u64,
        import_job_id: &str,
        staged_assets: &[StagedAssetImport],
        mut observe: impl FnMut(ImportCommitPhase),
    ) -> CoreResult<()> {
        validate_staged_assets(character, staged_assets)?;
        self.create_import_journal(staged_path, character, import_job_id, staged_assets)?;
        observe(ImportCommitPhase::JournalCreated);
        self.store_import_files(staged_path, character, source_size, staged_assets)?;
        observe(ImportCommitPhase::CasFilesDurable);
        self.connection()?
            .execute(
                "UPDATE import_jobs SET state = 'file_stored', updated_at = ?2 WHERE id = ?1",
                params![import_job_id, Utc::now().to_rfc3339()],
            )
            .map_err(storage_db_error)?;
        observe(ImportCommitPhase::JournalMarkedFileStored);
        self.commit_import_records(character, source_size, import_job_id, staged_assets)?;
        observe(ImportCommitPhase::RecordsCommitted);
        Ok(())
    }

    fn create_import_journal(
        &self,
        staged_path: &Path,
        character: &Character,
        import_job_id: &str,
        staged_assets: &[StagedAssetImport],
    ) -> CoreResult<()> {
        let asset_hashes = staged_assets
            .iter()
            .map(|asset| asset.sha256.as_str())
            .collect::<Vec<_>>();
        let asset_hashes_json = serde_json::to_string(&asset_hashes).map_err(|error| {
            CoreError::internal(format!("cannot encode import asset journal: {error}"))
        })?;
        self.connection()?
            .execute(
                "INSERT OR REPLACE INTO import_jobs
                 (id, source_hash, staging_path, state, updated_at, asset_hashes_json)
                 VALUES (?1, ?2, ?3, 'preparing', ?4, ?5)",
                params![
                    import_job_id,
                    character.source_hash,
                    staged_path.to_string_lossy(),
                    Utc::now().to_rfc3339(),
                    asset_hashes_json
                ],
            )
            .map_err(storage_db_error)?;
        Ok(())
    }

    fn store_import_files(
        &self,
        staged_path: &Path,
        character: &Character,
        source_size: u64,
        staged_assets: &[StagedAssetImport],
    ) -> CoreResult<()> {
        let relative_path = content_relative_path(&character.source_hash)?;
        let source_cas_root = self.root.join("sources/sha256");
        store_verified_source(
            staged_path,
            &self.root.join("sources").join(relative_path),
            &source_cas_root,
            &character.source_hash,
            source_size,
        )?;
        let asset_cas_root = self.root.join("assets/sha256");
        for asset in staged_assets {
            let relative_path = content_relative_path(&asset.sha256)?;
            store_verified_source(
                &asset.staged_path,
                &self.root.join("assets").join(relative_path),
                &asset_cas_root,
                &asset.sha256,
                asset.size_bytes,
            )?;
        }
        Ok(())
    }

    fn commit_import_records(
        &self,
        character: &Character,
        source_size: u64,
        import_job_id: &str,
        staged_assets: &[StagedAssetImport],
    ) -> CoreResult<()> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        insert_content_source(&transaction, character, source_size)?;
        for asset in staged_assets {
            insert_asset(&transaction, asset)?;
        }
        insert_character(&transaction, character)?;
        for asset in staged_assets {
            link_character_asset(&transaction, character, asset)?;
        }
        transaction
            .execute("DELETE FROM import_jobs WHERE id = ?1", [import_job_id])
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)
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
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        transaction
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
        transaction
            .execute(
                "UPDATE conversations SET updated_at = ?2 WHERE id = ?1",
                params![message.conversation_id.0, Utc::now().to_rfc3339()],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)?;
        Ok(())
    }

    /// Updates only the content of the matching in-flight assistant row.
    ///
    /// This conditional update prevents a delayed streaming checkpoint from
    /// replacing a terminal message or a row owned by another generation.
    pub fn checkpoint_pending_assistant(&self, message: &Message) -> CoreResult<()> {
        if message.role != MessageRole::Assistant || message.status != MessageStatus::Pending {
            return Err(CoreError::invalid(
                "only a pending assistant message can be checkpointed",
            ));
        }
        let generation_id = message.generation_id.as_ref().ok_or_else(|| {
            CoreError::invalid("a pending assistant checkpoint requires a generation id")
        })?;
        let changed = self
            .connection()?
            .execute(
                "UPDATE messages
                 SET content = ?3
                 WHERE id = ?1
                   AND generation_id = ?2
                   AND role = 'assistant'
                   AND status = 'pending'",
                params![message.id.0, generation_id.0, message.content],
            )
            .map_err(storage_db_error)?;
        if changed == 1 {
            Ok(())
        } else {
            Err(CoreError::new(
                CoreErrorCode::NotFound,
                "pending assistant checkpoint target was not found",
                false,
            ))
        }
    }

    pub fn delete_message(&self, id: &MessageId) -> CoreResult<()> {
        self.connection()?
            .execute("DELETE FROM messages WHERE id = ?1", [&id.0])
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
            .query_map([&conversation_id.0], map_message)
            .map_err(storage_db_error)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(storage_db_error)
    }

    /// Loads a bounded recent suffix without materializing oversized legacy rows.
    pub fn list_recent_messages_for_prompt(
        &self,
        conversation_id: &ConversationId,
        max_messages: usize,
        max_message_bytes: usize,
        max_message_chars: usize,
    ) -> CoreResult<Vec<Message>> {
        if max_messages == 0 || max_message_bytes == 0 || max_message_chars == 0 {
            return Ok(Vec::new());
        }
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT id, conversation_id, parent_id, role, content, status,
                        generation_id, created_at
                 FROM (
                   SELECT id, conversation_id, parent_id, role, content, status,
                          generation_id, created_at
                   FROM messages
                   WHERE conversation_id = ?1
                     AND role != 'system'
                     AND length(CAST(content AS BLOB)) <= ?3
                     AND length(content) <= ?4
                   ORDER BY created_at DESC, id DESC
                   LIMIT ?2
                 )
                 ORDER BY created_at, id",
            )
            .map_err(storage_db_error)?;
        let max_messages = i64::try_from(max_messages)
            .map_err(|_| CoreError::invalid("message limit exceeds SQLite integer range"))?;
        let max_message_bytes = i64::try_from(max_message_bytes)
            .map_err(|_| CoreError::invalid("byte limit exceeds SQLite integer range"))?;
        let max_message_chars = i64::try_from(max_message_chars)
            .map_err(|_| CoreError::invalid("character limit exceeds SQLite integer range"))?;
        let rows = statement
            .query_map(
                params![
                    conversation_id.0,
                    max_messages,
                    max_message_bytes,
                    max_message_chars
                ],
                map_message,
            )
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

    pub fn list_provider_profiles(&self) -> CoreResult<Vec<ProviderProfile>> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT id, display_name, base_url, model, timeout_seconds
                 FROM provider_profiles ORDER BY display_name COLLATE NOCASE, id",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map([], map_provider_profile)
            .map_err(storage_db_error)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(storage_db_error)
    }

    pub fn get_provider_profile(&self, id: &str) -> CoreResult<ProviderProfile> {
        self.connection()?
            .query_row(
                "SELECT id, display_name, base_url, model, timeout_seconds
                 FROM provider_profiles WHERE id = ?1",
                [id],
                map_provider_profile,
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::NotFound,
                    "provider profile was not found",
                    false,
                )
            })
    }

    pub fn save_provider_profile(&self, profile: &ProviderProfile) -> CoreResult<()> {
        self.connection()?
            .execute(
                "INSERT INTO provider_profiles
                 (id, display_name, base_url, model, timeout_seconds)
                 VALUES (?1, ?2, ?3, ?4, ?5)
                 ON CONFLICT(id) DO UPDATE SET
                   display_name = excluded.display_name,
                   base_url = excluded.base_url,
                   model = excluded.model,
                   timeout_seconds = excluded.timeout_seconds",
                params![
                    profile.id,
                    profile.display_name,
                    profile.base_url,
                    profile.model,
                    profile.timeout_seconds
                ],
            )
            .map_err(storage_db_error)?;
        Ok(())
    }

    pub fn delete_provider_profile(&self, id: &str) -> CoreResult<()> {
        self.connection()?
            .execute("DELETE FROM provider_profiles WHERE id = ?1", [id])
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

fn validate_staged_assets(
    character: &Character,
    staged_assets: &[StagedAssetImport],
) -> CoreResult<()> {
    if let Some(avatar_hash) = character.avatar_asset_hash.as_deref()
        && !staged_assets
            .iter()
            .any(|asset| asset.sha256 == avatar_hash)
    {
        return Err(CoreError::invalid(
            "character avatar does not reference a staged asset",
        ));
    }
    for asset in staged_assets {
        let _ = content_relative_path(&asset.sha256)?;
    }
    Ok(())
}

fn insert_content_source(
    transaction: &rusqlite::Transaction<'_>,
    character: &Character,
    source_size: u64,
) -> CoreResult<()> {
    let relative_path = content_relative_path(&character.source_hash)?;
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
    Ok(())
}

fn insert_asset(
    transaction: &rusqlite::Transaction<'_>,
    asset: &StagedAssetImport,
) -> CoreResult<()> {
    let relative_path = content_relative_path(&asset.sha256)?;
    transaction
        .execute(
            "INSERT OR IGNORE INTO assets
             (sha256, relative_path, media_type, size_bytes, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                asset.sha256,
                format!("assets/{relative_path}"),
                asset.media_type,
                u64_to_i64(asset.size_bytes)?,
                Utc::now().to_rfc3339()
            ],
        )
        .map_err(storage_db_error)?;
    Ok(())
}

fn insert_character(
    transaction: &rusqlite::Transaction<'_>,
    character: &Character,
) -> CoreResult<()> {
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
    Ok(())
}

fn link_character_asset(
    transaction: &rusqlite::Transaction<'_>,
    character: &Character,
    asset: &StagedAssetImport,
) -> CoreResult<()> {
    let role = if character.avatar_asset_hash.as_deref() == Some(asset.sha256.as_str()) {
        "avatar"
    } else {
        "attachment"
    };
    transaction
        .execute(
            "INSERT OR IGNORE INTO character_assets
             (character_id, asset_hash, role)
             VALUES (?1, ?2, ?3)",
            params![character.id, asset.sha256, role],
        )
        .map_err(storage_db_error)?;
    Ok(())
}

fn apply_migrations(connection: &mut Connection) -> CoreResult<()> {
    connection
        .execute_batch(MIGRATION_0001)
        .map_err(storage_db_error)?;
    let current_version = connection
        .query_row(
            "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
            [],
            |row| row.get::<_, u32>(0),
        )
        .map_err(storage_db_error)?;
    if current_version > SCHEMA_VERSION {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            format!(
                "database schema {current_version} is newer than supported schema {SCHEMA_VERSION}"
            ),
            false,
        ));
    }
    connection
        .execute(
            "INSERT OR IGNORE INTO schema_migrations (version, applied_at) VALUES (?1, ?2)",
            params![1, Utc::now().to_rfc3339()],
        )
        .map_err(storage_db_error)?;
    if current_version < 2 {
        let transaction = connection.transaction().map_err(storage_db_error)?;
        transaction
            .execute_batch(MIGRATION_0002)
            .map_err(storage_db_error)?;
        transaction
            .execute(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, ?2)",
                params![2, Utc::now().to_rfc3339()],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)?;
    }
    Ok(())
}

fn recover_interrupted_work(root: &Path, connection: &mut Connection) -> CoreResult<()> {
    let jobs = load_interrupted_imports(connection)?;
    validate_and_cleanup_imports(root, connection, &jobs)?;
    let settings = load_recovery_settings(connection)?;
    apply_recovery_transaction(connection, &jobs, &settings)?;
    remove_partial_files(&root.join("sources/sha256"))?;
    remove_partial_files(&root.join("assets/sha256"))?;
    Ok(())
}

fn load_interrupted_imports(connection: &Connection) -> CoreResult<Vec<InterruptedImport>> {
    let raw_jobs = {
        let mut statement = connection
            .prepare(
                "SELECT id, source_hash, staging_path, state, asset_hashes_json FROM import_jobs",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, String>(4)?,
                ))
            })
            .map_err(storage_db_error)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(storage_db_error)?
    };
    let jobs = raw_jobs
        .into_iter()
        .map(
            |(id, source_hash, staging_path, state, asset_hashes_json)| {
                let asset_hashes = serde_json::from_str::<Vec<String>>(&asset_hashes_json)
                    .map_err(|error| {
                        CoreError::new(
                            CoreErrorCode::StorageCorrupted,
                            format!("import journal asset hashes are invalid: {error}"),
                            false,
                        )
                    })?;
                Ok(InterruptedImport {
                    id,
                    source_hash,
                    staging_path,
                    state,
                    asset_hashes,
                })
            },
        )
        .collect::<CoreResult<Vec<_>>>()?;
    Ok(jobs)
}

fn validate_and_cleanup_imports(
    root: &Path,
    connection: &Connection,
    jobs: &[InterruptedImport],
) -> CoreResult<()> {
    for job in jobs {
        if !matches!(job.state.as_str(), "preparing" | "file_stored") {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                format!("import journal contains unknown state: {}", job.state),
                false,
            ));
        }
        let _ = content_relative_path(&job.source_hash)?;
        for asset_hash in &job.asset_hashes {
            let _ = content_relative_path(asset_hash)?;
        }
    }

    for job in jobs {
        remove_owned_staging_file(root, &job.staging_path)?;
        remove_unreferenced_cas(
            root,
            connection,
            "content_sources",
            "sources",
            &job.source_hash,
        )?;
        for asset_hash in &job.asset_hashes {
            remove_unreferenced_cas(root, connection, "assets", "assets", asset_hash)?;
        }
    }
    Ok(())
}

fn load_recovery_settings(connection: &Connection) -> CoreResult<AppSettings> {
    connection
        .query_row(
            "SELECT value_json FROM app_settings WHERE key = 'application'",
            [],
            |row| row.get::<_, String>(0),
        )
        .optional()
        .map_err(storage_db_error)?
        .map_or_else(
            || Ok(AppSettings::default()),
            |value| {
                serde_json::from_str::<AppSettings>(&value).map_err(|error| {
                    CoreError::new(
                        CoreErrorCode::StorageCorrupted,
                        format!("stored settings are invalid: {error}"),
                        false,
                    )
                })
            },
        )
}

fn apply_recovery_transaction(
    connection: &mut Connection,
    jobs: &[InterruptedImport],
    settings: &AppSettings,
) -> CoreResult<()> {
    let transaction = connection.transaction().map_err(storage_db_error)?;
    for job in jobs {
        transaction
            .execute("DELETE FROM import_jobs WHERE id = ?1", [&job.id])
            .map_err(storage_db_error)?;
    }
    if settings.preserve_partial_generations {
        transaction
            .execute(
                "UPDATE messages SET status = 'cancelled' WHERE status = 'pending'",
                [],
            )
            .map_err(storage_db_error)?;
    } else {
        transaction
            .execute(
                "DELETE FROM messages WHERE role = 'assistant' AND status = 'pending'",
                [],
            )
            .map_err(storage_db_error)?;
    }
    transaction.commit().map_err(storage_db_error)?;
    Ok(())
}

fn remove_unreferenced_cas(
    root: &Path,
    connection: &Connection,
    table: &str,
    directory: &str,
    hash: &str,
) -> CoreResult<()> {
    let query = match table {
        "content_sources" => "SELECT EXISTS(SELECT 1 FROM content_sources WHERE sha256 = ?1)",
        "assets" => "SELECT EXISTS(SELECT 1 FROM assets WHERE sha256 = ?1)",
        _ => return Err(CoreError::internal("unsupported recovery table")),
    };
    let referenced = connection
        .query_row(query, [hash], |row| row.get::<_, bool>(0))
        .map_err(storage_db_error)?;
    if referenced {
        return Ok(());
    }
    let relative = content_relative_path(hash)?;
    let path = root.join(directory).join(&relative);
    let cas_root = root.join(directory).join("sha256");
    ensure_real_directory(&cas_root)?;
    let prefix = path
        .parent()
        .ok_or_else(|| CoreError::internal("CAS recovery path has no parent"))?;
    match fs::symlink_metadata(prefix) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => {
            return Err(storage_corrupted(
                "CAS recovery hash-prefix path is not a real directory",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(storage_io_error(error)),
    }
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(storage_io_error(error)),
    }
}

fn remove_owned_staging_file(root: &Path, candidate: &str) -> CoreResult<()> {
    let candidate = PathBuf::from(candidate);
    if !candidate.is_file() {
        return Ok(());
    }
    let staging = root.join("staging");
    let staging = fs::canonicalize(staging).map_err(storage_io_error)?;
    let candidate = fs::canonicalize(candidate).map_err(storage_io_error)?;
    if candidate.parent() == Some(staging.as_path()) {
        fs::remove_file(candidate).map_err(storage_io_error)?;
    }
    Ok(())
}

fn remove_partial_files(root: &Path) -> CoreResult<()> {
    match fs::symlink_metadata(root) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => {
            return Err(storage_corrupted(
                "CAS recovery root is not a real directory",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(storage_io_error(error)),
    }
    for prefix in fs::read_dir(root).map_err(storage_io_error)? {
        let prefix = prefix.map_err(storage_io_error)?;
        if !prefix.file_type().map_err(storage_io_error)?.is_dir() {
            return Err(storage_corrupted(
                "CAS hash-prefix path is not a real directory",
            ));
        }
        for entry in fs::read_dir(prefix.path()).map_err(storage_io_error)? {
            let entry = entry.map_err(storage_io_error)?;
            let file_type = entry.file_type().map_err(storage_io_error)?;
            if !file_type.is_file() {
                return Err(storage_corrupted("CAS entry is not a regular file"));
            }
            let path = entry.path();
            if path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with('.') && name.ends_with(".partial"))
            {
                fs::remove_file(path).map_err(storage_io_error)?;
            }
        }
    }
    Ok(())
}

fn remove_abandoned_staging_files(staging: &Path) -> CoreResult<()> {
    if !staging.is_dir() {
        return Ok(());
    }
    for entry in fs::read_dir(staging).map_err(storage_io_error)? {
        let entry = entry.map_err(storage_io_error)?;
        let metadata = fs::symlink_metadata(entry.path()).map_err(storage_io_error)?;
        if metadata.file_type().is_file() || metadata.file_type().is_symlink() {
            fs::remove_file(entry.path()).map_err(storage_io_error)?;
        }
    }
    Ok(())
}

fn create_owned_directory_tree(root: &Path, relative: &Path) -> CoreResult<()> {
    let mut current = root.to_path_buf();
    for component in relative.components() {
        let std::path::Component::Normal(component) = component else {
            return Err(CoreError::internal(
                "owned storage directory must use a relative normal path",
            ));
        };
        current.push(component);
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_dir() => {}
            Ok(_) => {
                return Err(storage_corrupted(format!(
                    "owned storage path is not a real directory: {}",
                    current.display()
                )));
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                fs::create_dir(&current).map_err(storage_io_error)?;
                if let Some(parent) = current.parent() {
                    sync_directory(parent)?;
                }
            }
            Err(error) => return Err(storage_io_error(error)),
        }
    }
    sync_directory(&current)
}

fn store_verified_source(
    source: &Path,
    final_path: &Path,
    cas_root: &Path,
    expected_sha256: &str,
    expected_size: u64,
) -> CoreResult<()> {
    let parent = final_path
        .parent()
        .ok_or_else(|| CoreError::internal("source path has no parent"))?;
    create_and_sync_cas_directory(cas_root, parent)?;

    match fs::symlink_metadata(final_path) {
        Ok(metadata) if metadata.file_type().is_file() => {
            verify_file(final_path, expected_sha256, expected_size)?;
            sync_file_and_parent(final_path, parent)?;
            return Ok(());
        }
        Ok(_) => {
            return Err(storage_corrupted(
                "content-addressed destination is not a regular file",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(storage_io_error(error)),
    }

    let temp_path = parent.join(format!(".{}.partial", Uuid::new_v4()));
    let copy_result = copy_and_hash(source, &temp_path);
    let (actual_sha256, actual_size) = match copy_result {
        Ok(result) => result,
        Err(error) => {
            let _ = fs::remove_file(&temp_path);
            return Err(error);
        }
    };
    if actual_sha256 != expected_sha256 || actual_size != expected_size {
        let _ = fs::remove_file(&temp_path);
        return Err(CoreError::new(
            CoreErrorCode::UnsafeArchive,
            "staging source changed while it was being committed",
            false,
        ));
    }

    match publish_temp_noclobber(&temp_path, final_path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
            fs::remove_file(&temp_path).map_err(storage_io_error)?;
            ensure_regular_file(final_path)?;
            verify_file(final_path, expected_sha256, expected_size)?;
        }
        Err(error) => {
            let _ = fs::remove_file(&temp_path);
            return Err(storage_io_error(error));
        }
    }

    sync_file_and_parent(final_path, parent)?;
    Ok(())
}

#[cfg(any(target_os = "android", target_os = "linux", target_vendor = "apple"))]
fn publish_temp_noclobber(temp_path: &Path, final_path: &Path) -> std::io::Result<()> {
    use rustix::fs::{CWD, RenameFlags, renameat_with};

    renameat_with(CWD, temp_path, CWD, final_path, RenameFlags::NOREPLACE)
        .map_err(|error| std::io::Error::from_raw_os_error(error.raw_os_error()))
}

#[cfg(not(any(target_os = "android", target_os = "linux", target_vendor = "apple")))]
fn publish_temp_noclobber(temp_path: &Path, final_path: &Path) -> std::io::Result<()> {
    fs::hard_link(temp_path, final_path)?;
    fs::remove_file(temp_path)
}

fn create_and_sync_cas_directory(cas_root: &Path, path: &Path) -> CoreResult<()> {
    let relative = path
        .strip_prefix(cas_root)
        .map_err(|_| CoreError::internal("CAS destination escaped its owned root"))?;
    if relative.components().count() != 1 {
        return Err(CoreError::internal(
            "CAS destination must have exactly one hash-prefix directory",
        ));
    }
    ensure_real_directory(cas_root)?;
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => {}
        Ok(_) => {
            return Err(storage_corrupted(
                "CAS hash-prefix path is not a real directory",
            ));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            fs::create_dir(path).map_err(storage_io_error)?;
            sync_directory(cas_root)?;
        }
        Err(error) => return Err(storage_io_error(error)),
    }
    ensure_real_directory(path)?;
    sync_directory(path)
}

fn ensure_real_directory(path: &Path) -> CoreResult<()> {
    let metadata = fs::symlink_metadata(path).map_err(storage_io_error)?;
    if !metadata.file_type().is_dir() {
        return Err(storage_corrupted(format!(
            "owned CAS path is not a real directory: {}",
            path.display()
        )));
    }
    Ok(())
}

fn ensure_regular_file(path: &Path) -> CoreResult<()> {
    let metadata = fs::symlink_metadata(path).map_err(storage_io_error)?;
    if !metadata.file_type().is_file() {
        return Err(storage_corrupted(
            "content-addressed destination is not a regular file",
        ));
    }
    Ok(())
}

fn sync_file_and_parent(file_path: &Path, parent: &Path) -> CoreResult<()> {
    File::open(file_path)
        .and_then(|file| file.sync_all())
        .map_err(storage_io_error)?;
    sync_directory(parent)
}

#[cfg(unix)]
fn sync_directory(path: &Path) -> CoreResult<()> {
    File::open(path)
        .and_then(|directory| directory.sync_all())
        .map_err(storage_io_error)
}

#[cfg(windows)]
fn sync_directory(path: &Path) -> CoreResult<()> {
    use std::os::windows::fs::OpenOptionsExt;

    const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x0200_0000;
    let result = OpenOptions::new()
        .read(true)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS)
        .open(path)
        .and_then(|directory| directory.sync_all());
    match result {
        Ok(()) => Ok(()),
        // Windows does not guarantee FlushFileBuffers support for directory
        // handles on every filesystem. The CAS file itself was synced above.
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::InvalidInput
                    | std::io::ErrorKind::PermissionDenied
                    | std::io::ErrorKind::Unsupported
            ) =>
        {
            Ok(())
        }
        Err(error) => Err(storage_io_error(error)),
    }
}

#[cfg(not(any(unix, windows)))]
fn sync_directory(_path: &Path) -> CoreResult<()> {
    Ok(())
}

fn copy_and_hash(source: &Path, destination: &Path) -> CoreResult<(String, u64)> {
    let source = File::open(source).map_err(storage_io_error)?;
    let destination = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(destination)
        .map_err(storage_io_error)?;
    let mut reader = BufReader::new(source);
    let mut writer = destination;
    let mut digest = Sha256::new();
    let mut size = 0_u64;
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buffer).map_err(storage_io_error)?;
        if read == 0 {
            break;
        }
        writer
            .write_all(&buffer[..read])
            .map_err(storage_io_error)?;
        digest.update(&buffer[..read]);
        size = size
            .checked_add(
                u64::try_from(read)
                    .map_err(|_| CoreError::internal("source byte count overflow"))?,
            )
            .ok_or_else(|| CoreError::internal("source size overflow"))?;
    }
    writer.flush().map_err(storage_io_error)?;
    writer.sync_all().map_err(storage_io_error)?;
    Ok((hex::encode(digest.finalize()), size))
}

fn verify_file(path: &Path, expected_sha256: &str, expected_size: u64) -> CoreResult<()> {
    let (actual_sha256, actual_size) = hash_file(path)?;
    if actual_sha256 != expected_sha256 || actual_size != expected_size {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "content-addressed source does not match its recorded digest",
            false,
        ));
    }
    Ok(())
}

fn hash_file(path: &Path) -> CoreResult<(String, u64)> {
    let source = File::open(path).map_err(storage_io_error)?;
    let mut reader = BufReader::new(source);
    let mut digest = Sha256::new();
    let mut size = 0_u64;
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buffer).map_err(storage_io_error)?;
        if read == 0 {
            break;
        }
        digest.update(&buffer[..read]);
        size = size
            .checked_add(
                u64::try_from(read)
                    .map_err(|_| CoreError::internal("source byte count overflow"))?,
            )
            .ok_or_else(|| CoreError::internal("source size overflow"))?;
    }
    Ok((hex::encode(digest.finalize()), size))
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

fn map_provider_profile(row: &rusqlite::Row<'_>) -> rusqlite::Result<ProviderProfile> {
    let timeout_seconds = row.get::<_, i64>(4)?;
    let timeout_seconds = u32::try_from(timeout_seconds).map_err(|error| {
        rusqlite::Error::FromSqlConversionFailure(
            4,
            rusqlite::types::Type::Integer,
            Box::new(error),
        )
    })?;
    Ok(ProviderProfile {
        id: row.get(0)?,
        display_name: row.get(1)?,
        base_url: row.get(2)?,
        model: row.get(3)?,
        timeout_seconds,
    })
}

fn map_message(row: &rusqlite::Row<'_>) -> rusqlite::Result<Message> {
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

fn storage_corrupted(message: impl Into<String>) -> CoreError {
    CoreError::new(CoreErrorCode::StorageCorrupted, message, false)
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

    use chrono::Duration;
    use tempfile::{NamedTempFile, tempdir};

    use super::*;

    #[test]
    fn persists_character_and_settings_across_reopen() {
        let root = tempdir().expect("temp root");
        let mut staged = NamedTempFile::new_in(root.path()).expect("staging");
        staged.write_all(b"character").expect("source");
        let character = Character::new("Segu", "Guide", hex::encode(Sha256::digest(b"character")));

        {
            let storage = Storage::open(root.path()).expect("open storage");
            storage
                .commit_character_import(
                    staged.path(),
                    &character,
                    9,
                    &Uuid::new_v4().to_string(),
                    &[],
                )
                .expect("commit import");
            let conversation = Conversation::new(&character.id, &character.name);
            storage
                .save_conversation(&conversation)
                .expect("save conversation");
            let user = Message::user(conversation.id.clone(), "Hello");
            storage.save_message(&user).expect("save user");
            let pending = Message::pending_assistant(
                conversation.id.clone(),
                user.id.clone(),
                GenerationId::new(),
            );
            storage.save_message(&pending).expect("save pending");
            storage
                .save_provider_profile(&ProviderProfile {
                    id: "local".to_owned(),
                    display_name: "Local model".to_owned(),
                    base_url: "http://127.0.0.1:11434/v1".to_owned(),
                    model: "test".to_owned(),
                    timeout_seconds: 30,
                })
                .expect("save provider");
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
        assert_eq!(
            reopened
                .list_provider_profiles()
                .expect("provider profiles")
                .len(),
            1
        );
        assert_eq!(
            reopened
                .list_messages(&reopened.list_conversations().expect("conversations")[0].id)
                .expect("messages")
                .len(),
            1,
            "discard policy removes interrupted assistant messages"
        );
    }

    #[test]
    fn partial_checkpoint_cannot_overwrite_a_terminal_assistant_message() {
        let root = tempdir().expect("temp root");
        let mut staged = NamedTempFile::new_in(root.path()).expect("staging");
        staged.write_all(b"character").expect("source");
        let character = Character::new("Segu", "Guide", hex::encode(Sha256::digest(b"character")));
        let storage = Storage::open(root.path()).expect("open storage");
        storage
            .commit_character_import(
                staged.path(),
                &character,
                9,
                &Uuid::new_v4().to_string(),
                &[],
            )
            .expect("commit import");
        let conversation = Conversation::new(&character.id, &character.name);
        storage
            .save_conversation(&conversation)
            .expect("save conversation");
        let user = Message::user(conversation.id.clone(), "Hello");
        storage.save_message(&user).expect("save user");
        let mut pending =
            Message::pending_assistant(conversation.id.clone(), user.id, GenerationId::new());
        storage.save_message(&pending).expect("save pending");

        pending.content = "checkpoint".to_owned();
        storage
            .checkpoint_pending_assistant(&pending)
            .expect("checkpoint pending");
        let mut terminal = pending.clone();
        terminal.content = "final".to_owned();
        terminal.status = MessageStatus::Complete;
        storage.save_message(&terminal).expect("save terminal");

        pending.content = "stale checkpoint".to_owned();
        let error = storage
            .checkpoint_pending_assistant(&pending)
            .expect_err("terminal row must reject a stale checkpoint");
        assert_eq!(error.code, CoreErrorCode::NotFound);
        let messages = storage.list_messages(&conversation.id).expect("messages");
        assert_eq!(messages[1].content, "final");
        assert_eq!(messages[1].status, MessageStatus::Complete);
    }

    #[test]
    fn restart_recovers_import_journal_cas_files_and_staging() {
        let root = tempdir().expect("temp root");
        let source_bytes = b"orphan source";
        let asset_bytes = b"orphan asset";
        let source_hash = hex::encode(Sha256::digest(source_bytes));
        let asset_hash = hex::encode(Sha256::digest(asset_bytes));
        let source_path = root
            .path()
            .join("sources")
            .join(content_relative_path(&source_hash).expect("source path"));
        let asset_path = root
            .path()
            .join("assets")
            .join(content_relative_path(&asset_hash).expect("asset path"));
        let staging_path = root.path().join("staging/inspection-recovery.json");
        let staged_asset = root
            .path()
            .join("staging/inspection-recovery-asset.partial");

        {
            let storage = Storage::open(root.path()).expect("open storage");
            fs::create_dir_all(source_path.parent().expect("source parent"))
                .expect("source directory");
            fs::create_dir_all(asset_path.parent().expect("asset parent"))
                .expect("asset directory");
            fs::write(&source_path, source_bytes).expect("source CAS");
            fs::write(&asset_path, asset_bytes).expect("asset CAS");
            fs::write(&staging_path, b"staging").expect("source staging");
            fs::write(&staged_asset, b"asset staging").expect("asset staging");
            storage
                .connection()
                .expect("connection")
                .execute(
                    "INSERT INTO import_jobs
                     (id, source_hash, staging_path, state, updated_at, asset_hashes_json)
                     VALUES (?1, ?2, ?3, 'file_stored', ?4, ?5)",
                    params![
                        "recovery-job",
                        source_hash,
                        staging_path.to_string_lossy(),
                        Utc::now().to_rfc3339(),
                        serde_json::to_string(&vec![asset_hash.clone()]).expect("asset hashes")
                    ],
                )
                .expect("insert recovery journal");
        }

        let reopened = Storage::open(root.path()).expect("recover storage");
        assert!(!source_path.exists());
        assert!(!asset_path.exists());
        assert!(!staging_path.exists());
        assert!(!staged_asset.exists());
        assert!(!reopened.recovery_pending().expect("recovery status"));
        assert_eq!(reopened.schema_version(), 2);
    }

    #[test]
    fn prompt_history_query_bounds_rows_and_multibyte_content_before_loading() {
        let root = tempdir().expect("temp root");
        let mut staged = NamedTempFile::new_in(root.path()).expect("staging");
        staged.write_all(b"character").expect("source");
        let character = Character::new("Segu", "Guide", hex::encode(Sha256::digest(b"character")));
        let storage = Storage::open(root.path()).expect("open storage");
        storage
            .commit_character_import(
                staged.path(),
                &character,
                9,
                &Uuid::new_v4().to_string(),
                &[],
            )
            .expect("commit import");
        let conversation = Conversation::new(&character.id, &character.name);
        storage
            .save_conversation(&conversation)
            .expect("save conversation");

        let base = Utc::now();
        for (index, content) in ["old", "😀😀", "😀😀😀", "latest"].into_iter().enumerate()
        {
            let mut message = Message::user(conversation.id.clone(), content);
            message.created_at =
                base + Duration::seconds(i64::try_from(index).expect("small fixture index"));
            storage.save_message(&message).expect("save message");
        }

        let history = storage
            .list_recent_messages_for_prompt(&conversation.id, 3, 8, 8)
            .expect("bounded history");
        let contents = history
            .iter()
            .map(|message| message.content.as_str())
            .collect::<Vec<_>>();
        assert_eq!(contents, vec!["old", "😀😀", "latest"]);

        let recent = storage
            .list_recent_messages_for_prompt(&conversation.id, 2, 64, 64)
            .expect("recent history");
        assert_eq!(recent.len(), 2);
        assert_eq!(recent[1].content, "latest");
    }

    #[test]
    fn import_commit_observer_proves_cas_durability_precedes_sqlite_commit() {
        let root = tempdir().expect("temp root");
        let mut source = NamedTempFile::new_in(root.path()).expect("source staging");
        source.write_all(b"character").expect("source");
        let mut asset = NamedTempFile::new_in(root.path()).expect("asset staging");
        asset.write_all(b"avatar").expect("asset");
        let source_hash = hex::encode(Sha256::digest(b"character"));
        let asset_hash = hex::encode(Sha256::digest(b"avatar"));
        let mut character = Character::new("Segu", "Guide", &source_hash);
        character.avatar_asset_hash = Some(asset_hash.clone());
        let staged_assets = vec![StagedAssetImport {
            staged_path: asset.path().to_path_buf(),
            sha256: asset_hash.clone(),
            media_type: "image/png".to_owned(),
            size_bytes: 6,
        }];
        let storage = Storage::open(root.path()).expect("open storage");
        let source_cas = root
            .path()
            .join("sources")
            .join(content_relative_path(&source_hash).expect("source path"));
        let asset_cas = root
            .path()
            .join("assets")
            .join(content_relative_path(&asset_hash).expect("asset path"));
        let mut phases = Vec::new();

        storage
            .commit_character_import_observed(
                source.path(),
                &character,
                9,
                "observed-import",
                &staged_assets,
                |phase| {
                    let stats = storage.stats().expect("stats at phase");
                    match phase {
                        ImportCommitPhase::JournalCreated
                        | ImportCommitPhase::JournalMarkedFileStored => {
                            assert_eq!(stats.pending_imports, 1);
                            assert_eq!(stats.characters, 0);
                        }
                        ImportCommitPhase::CasFilesDurable => {
                            assert!(source_cas.is_file());
                            assert!(asset_cas.is_file());
                            assert_eq!(stats.pending_imports, 1);
                            assert_eq!(stats.characters, 0);
                        }
                        ImportCommitPhase::RecordsCommitted => {
                            assert_eq!(stats.pending_imports, 0);
                            assert_eq!(stats.characters, 1);
                        }
                    }
                    phases.push(phase);
                },
            )
            .expect("observed import");

        assert_eq!(
            phases,
            vec![
                ImportCommitPhase::JournalCreated,
                ImportCommitPhase::CasFilesDurable,
                ImportCommitPhase::JournalMarkedFileStored,
                ImportCommitPhase::RecordsCommitted,
            ]
        );
    }

    #[test]
    fn atomic_cas_publish_never_replaces_an_existing_destination() {
        let root = tempdir().expect("temp root");
        let temp_path = root.path().join("new.partial");
        let final_path = root.path().join("final");
        fs::write(&temp_path, b"new").expect("temporary content");
        fs::write(&final_path, b"existing").expect("existing content");

        let error =
            publish_temp_noclobber(&temp_path, &final_path).expect_err("must not overwrite");
        assert_eq!(error.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&final_path).expect("final content"), b"existing");
        assert_eq!(fs::read(&temp_path).expect("temporary content"), b"new");
    }

    #[cfg(unix)]
    #[test]
    fn recovery_rejects_a_symlinked_cas_hash_prefix() {
        use std::os::unix::fs::symlink;

        let root = tempdir().expect("temp root");
        let source_hash = format!("aa{}", "0".repeat(62));
        let staging_path = root.path().join("staging/inspection-symlink.json");
        {
            let storage = Storage::open(root.path()).expect("open storage");
            fs::write(&staging_path, b"staging").expect("staging");
            storage
                .connection()
                .expect("connection")
                .execute(
                    "INSERT INTO import_jobs
                     (id, source_hash, staging_path, state, updated_at, asset_hashes_json)
                     VALUES (?1, ?2, ?3, 'file_stored', ?4, '[]')",
                    params![
                        "symlink-job",
                        source_hash,
                        staging_path.to_string_lossy(),
                        Utc::now().to_rfc3339()
                    ],
                )
                .expect("journal");
        }
        let outside = root.path().join("outside");
        fs::create_dir(&outside).expect("outside");
        symlink(&outside, root.path().join("sources/sha256/aa")).expect("prefix symlink");

        let Err(error) = Storage::open(root.path()) else {
            panic!("symlinked CAS prefix must be rejected");
        };
        assert_eq!(error.code, CoreErrorCode::StorageCorrupted);
        assert_eq!(
            error.message,
            "CAS recovery hash-prefix path is not a real directory"
        );
    }
}
