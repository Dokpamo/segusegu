use std::{
    fs::{self, File, OpenOptions},
    io::{BufReader, Read, Write},
    path::{Path, PathBuf},
    sync::{Mutex, MutexGuard},
};

use chrono::{DateTime, Utc};
use lorepia_domain::{
    AppSettings, Character, Conversation, ConversationBranch, ConversationBranchId, ConversationId,
    ConversationMode, ConversationState, CoreError, CoreErrorCode, CoreResult, GenerationId,
    GenerationRecord, GenerationStatus, Message, MessageId, MessageRole, MessageStatus,
    ProviderProfile,
};
use rusqlite::{Connection, OptionalExtension, params};
use sha2::{Digest, Sha256};
use uuid::Uuid;

const SCHEMA_VERSION: u32 = 3;
const MIGRATION_0001: &str = include_str!("../migrations/0001_initial.sql");
const MIGRATION_0002: &str = include_str!("../migrations/0002_import_asset_recovery.sql");
const MIGRATION_0003: &str = include_str!("../migrations/0003_conversation_branches.sql");

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DatabaseStats {
    pub characters: u64,
    pub conversations: u64,
    pub messages: u64,
    pub pending_imports: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageGenerationAction {
    EditUser,
    RegenerateAssistant,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MessageGenerationActionContext {
    pub fork_message_id: Option<MessageId>,
    pub user_text: String,
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

struct StoredGenerationRoute {
    conversation: String,
    branch: String,
    user_message: String,
    assistant_message: Option<String>,
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
        self.save_conversation_with_mode(conversation, ConversationMode::Chat)
            .map(|_| ())
    }

    pub fn save_conversation_with_mode(
        &self,
        conversation: &Conversation,
        mode: ConversationMode,
    ) -> CoreResult<(ConversationBranch, ConversationState)> {
        let branch = ConversationBranch::root(conversation.id.clone());
        let state = ConversationState {
            conversation_id: conversation.id.clone(),
            active_branch_id: branch.id.clone(),
            selected_mode: mode,
            updated_at: conversation.updated_at,
        };
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        transaction
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
        transaction
            .execute(
                "INSERT INTO conversation_branches
                 (id, conversation_id, title, fork_message_id, head_message_id,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, NULL, NULL, ?4, ?5)",
                params![
                    branch.id.0,
                    branch.conversation_id.0,
                    branch.title,
                    branch.created_at.to_rfc3339(),
                    branch.updated_at.to_rfc3339()
                ],
            )
            .map_err(storage_db_error)?;
        transaction
            .execute(
                "INSERT INTO conversation_state
                 (conversation_id, active_branch_id, selected_mode, updated_at)
                 VALUES (?1, ?2, ?3, ?4)",
                params![
                    state.conversation_id.0,
                    state.active_branch_id.0,
                    mode_to_str(state.selected_mode),
                    state.updated_at.to_rfc3339()
                ],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)?;
        Ok((branch, state))
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

    pub fn list_conversations_for_character(
        &self,
        character_id: &str,
    ) -> CoreResult<Vec<Conversation>> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT id, character_id, title, created_at, updated_at
                 FROM conversations
                 WHERE character_id = ?1
                 ORDER BY updated_at DESC, id",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map([character_id], map_conversation)
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
                map_conversation,
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(CoreErrorCode::NotFound, "conversation was not found", false)
            })
    }

    pub fn get_conversation_state(
        &self,
        conversation_id: &ConversationId,
    ) -> CoreResult<ConversationState> {
        self.connection()?
            .query_row(
                "SELECT conversation_id, active_branch_id, selected_mode, updated_at
                 FROM conversation_state
                 WHERE conversation_id = ?1",
                [&conversation_id.0],
                map_conversation_state,
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::NotFound,
                    "conversation state was not found",
                    false,
                )
            })
    }

    pub fn list_conversation_branches(
        &self,
        conversation_id: &ConversationId,
    ) -> CoreResult<Vec<ConversationBranch>> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT id, conversation_id, title, fork_message_id, head_message_id,
                        created_at, updated_at
                 FROM conversation_branches
                 WHERE conversation_id = ?1
                 ORDER BY updated_at DESC, id",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map([&conversation_id.0], map_conversation_branch)
            .map_err(storage_db_error)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(storage_db_error)
    }

    pub fn get_conversation_branch(
        &self,
        branch_id: &ConversationBranchId,
    ) -> CoreResult<ConversationBranch> {
        self.connection()?
            .query_row(
                "SELECT id, conversation_id, title, fork_message_id, head_message_id,
                        created_at, updated_at
                 FROM conversation_branches
                 WHERE id = ?1",
                [&branch_id.0],
                map_conversation_branch,
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::NotFound,
                    "conversation branch was not found",
                    false,
                )
            })
    }

    pub fn create_conversation_branch(
        &self,
        conversation_id: &ConversationId,
        from_message_id: Option<&MessageId>,
        title: Option<String>,
    ) -> CoreResult<ConversationBranch> {
        let branch = ConversationBranch {
            id: ConversationBranchId::new(),
            conversation_id: conversation_id.clone(),
            title,
            fork_message_id: from_message_id.cloned(),
            head_message_id: from_message_id.cloned(),
            created_at: Utc::now(),
            updated_at: Utc::now(),
        };
        let connection = self.connection()?;
        if let Some(message_id) = from_message_id {
            let exists = connection
                .query_row(
                    "SELECT EXISTS(
                       SELECT 1 FROM messages
                       WHERE id = ?1 AND conversation_id = ?2 AND status <> 'pending'
                     )",
                    params![message_id.0, conversation_id.0],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(storage_db_error)?;
            if !exists {
                return Err(CoreError::new(
                    CoreErrorCode::NotFound,
                    "branch source message was not found in the conversation",
                    false,
                ));
            }
        } else {
            let exists = connection
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM conversations WHERE id = ?1)",
                    [&conversation_id.0],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(storage_db_error)?;
            if !exists {
                return Err(CoreError::new(
                    CoreErrorCode::NotFound,
                    "conversation was not found",
                    false,
                ));
            }
        }
        connection
            .execute(
                "INSERT INTO conversation_branches
                 (id, conversation_id, title, fork_message_id, head_message_id,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    branch.id.0,
                    branch.conversation_id.0,
                    branch.title,
                    branch
                        .fork_message_id
                        .as_ref()
                        .map(|message_id| message_id.0.as_str()),
                    branch
                        .head_message_id
                        .as_ref()
                        .map(|message_id| message_id.0.as_str()),
                    branch.created_at.to_rfc3339(),
                    branch.updated_at.to_rfc3339()
                ],
            )
            .map_err(storage_db_error)?;
        Ok(branch)
    }

    pub fn select_conversation_branch(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
    ) -> CoreResult<ConversationState> {
        let now = Utc::now();
        let changed = self
            .connection()?
            .execute(
                "UPDATE conversation_state
                 SET active_branch_id = ?2, updated_at = ?3
                 WHERE conversation_id = ?1
                   AND EXISTS(
                     SELECT 1 FROM conversation_branches
                     WHERE conversation_id = ?1 AND id = ?2
                   )",
                params![conversation_id.0, branch_id.0, now.to_rfc3339()],
            )
            .map_err(storage_db_error)?;
        if changed != 1 {
            return Err(CoreError::new(
                CoreErrorCode::NotFound,
                "conversation branch was not found in the conversation",
                false,
            ));
        }
        self.get_conversation_state(conversation_id)
    }

    pub fn set_conversation_mode(
        &self,
        conversation_id: &ConversationId,
        mode: ConversationMode,
    ) -> CoreResult<ConversationState> {
        let now = Utc::now();
        let changed = self
            .connection()?
            .execute(
                "UPDATE conversation_state
                 SET selected_mode = ?2, updated_at = ?3
                 WHERE conversation_id = ?1",
                params![conversation_id.0, mode_to_str(mode), now.to_rfc3339()],
            )
            .map_err(storage_db_error)?;
        if changed != 1 {
            return Err(CoreError::new(
                CoreErrorCode::NotFound,
                "conversation state was not found",
                false,
            ));
        }
        self.get_conversation_state(conversation_id)
    }

    pub fn save_message(&self, message: &Message) -> CoreResult<()> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        let changed = transaction
            .execute(
                "INSERT INTO messages
                 (id, conversation_id, parent_id, role, content, status, generation_id, created_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                 ON CONFLICT(id) DO UPDATE SET
                   content = excluded.content,
                   status = excluded.status
                 WHERE messages.conversation_id = excluded.conversation_id
                   AND messages.parent_id IS excluded.parent_id
                   AND messages.role = excluded.role
                   AND messages.generation_id IS excluded.generation_id
                   AND messages.created_at = excluded.created_at",
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
        if changed != 1 {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "message identity fields cannot be replaced",
                false,
            ));
        }
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

    pub fn list_branch_messages(
        &self,
        branch_id: &ConversationBranchId,
    ) -> CoreResult<Vec<Message>> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "WITH RECURSIVE lineage(
                   id, conversation_id, parent_id, role, content, status,
                   generation_id, created_at, depth
                 ) AS (
                   SELECT messages.id, messages.conversation_id, messages.parent_id,
                          messages.role, messages.content, messages.status,
                          messages.generation_id, messages.created_at, 0
                   FROM conversation_branches
                   JOIN messages
                     ON messages.conversation_id = conversation_branches.conversation_id
                    AND messages.id = conversation_branches.head_message_id
                   WHERE conversation_branches.id = ?1
                   UNION ALL
                   SELECT parent.id, parent.conversation_id, parent.parent_id,
                          parent.role, parent.content, parent.status,
                          parent.generation_id, parent.created_at, lineage.depth + 1
                   FROM messages AS parent
                   JOIN lineage
                     ON parent.conversation_id = lineage.conversation_id
                    AND parent.id = lineage.parent_id
                 )
                 SELECT id, conversation_id, parent_id, role, content, status,
                        generation_id, created_at
                 FROM lineage
                 ORDER BY depth DESC",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map([&branch_id.0], map_message)
            .map_err(storage_db_error)?;
        rows.collect::<Result<Vec<_>, _>>()
            .map_err(storage_db_error)
    }

    pub fn prepare_message_generation_action(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        target_message_id: &MessageId,
        action: MessageGenerationAction,
    ) -> CoreResult<MessageGenerationActionContext> {
        let connection = self.connection()?;
        load_message_generation_action_context(
            &connection,
            conversation_id,
            branch_id,
            expected_head,
            target_message_id,
            action,
        )
    }

    pub fn list_recent_message_lineage_for_prompt(
        &self,
        conversation_id: &ConversationId,
        head_message_id: Option<&MessageId>,
        max_messages: usize,
        max_message_bytes: usize,
        max_message_chars: usize,
    ) -> CoreResult<Vec<Message>> {
        if head_message_id.is_none()
            || max_messages == 0
            || max_message_bytes == 0
            || max_message_chars == 0
        {
            return Ok(Vec::new());
        }
        let max_messages = i64::try_from(max_messages)
            .map_err(|_| CoreError::invalid("message limit exceeds SQLite integer range"))?;
        let max_message_bytes = i64::try_from(max_message_bytes)
            .map_err(|_| CoreError::invalid("byte limit exceeds SQLite integer range"))?;
        let max_message_chars = i64::try_from(max_message_chars)
            .map_err(|_| CoreError::invalid("character limit exceeds SQLite integer range"))?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "WITH RECURSIVE lineage(
                   id, conversation_id, parent_id, role, content, status,
                   generation_id, created_at, depth
                 ) AS (
                   SELECT id, conversation_id, parent_id, role, content, status,
                          generation_id, created_at, 0
                   FROM messages
                   WHERE conversation_id = ?1 AND id = ?2
                   UNION ALL
                   SELECT parent.id, parent.conversation_id, parent.parent_id,
                          parent.role, parent.content, parent.status,
                          parent.generation_id, parent.created_at, lineage.depth + 1
                   FROM messages AS parent
                   JOIN lineage
                     ON parent.conversation_id = lineage.conversation_id
                    AND parent.id = lineage.parent_id
                   WHERE lineage.depth < 511
                 ),
                 selected AS (
                   SELECT *
                   FROM lineage
                   WHERE role != 'system'
                     AND status != 'pending'
                     AND (status = 'complete' OR length(content) > 0)
                     AND length(CAST(content AS BLOB)) <= ?4
                     AND length(content) <= ?5
                   ORDER BY depth
                   LIMIT ?3
                 )
                 SELECT id, conversation_id, parent_id, role, content, status,
                        generation_id, created_at
                 FROM selected
                 ORDER BY depth DESC",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map(
                params![
                    conversation_id.0,
                    head_message_id.map(|message_id| message_id.0.as_str()),
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

    /// Loads the newest eligible suffix from one selected message lineage.
    pub fn list_recent_branch_messages_for_prompt(
        &self,
        branch_id: &ConversationBranchId,
        max_messages: usize,
        max_message_bytes: usize,
        max_message_chars: usize,
    ) -> CoreResult<Vec<Message>> {
        if max_messages == 0 || max_message_bytes == 0 || max_message_chars == 0 {
            return Ok(Vec::new());
        }
        let max_messages = i64::try_from(max_messages)
            .map_err(|_| CoreError::invalid("message limit exceeds SQLite integer range"))?;
        let max_message_bytes = i64::try_from(max_message_bytes)
            .map_err(|_| CoreError::invalid("byte limit exceeds SQLite integer range"))?;
        let max_message_chars = i64::try_from(max_message_chars)
            .map_err(|_| CoreError::invalid("character limit exceeds SQLite integer range"))?;
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "WITH RECURSIVE lineage(
                   id, conversation_id, parent_id, role, content, status,
                   generation_id, created_at, depth
                 ) AS (
                   SELECT messages.id, messages.conversation_id, messages.parent_id,
                          messages.role, messages.content, messages.status,
                          messages.generation_id, messages.created_at, 0
                   FROM conversation_branches
                   JOIN messages
                     ON messages.conversation_id = conversation_branches.conversation_id
                    AND messages.id = conversation_branches.head_message_id
                   WHERE conversation_branches.id = ?1
                   UNION ALL
                   SELECT parent.id, parent.conversation_id, parent.parent_id,
                          parent.role, parent.content, parent.status,
                          parent.generation_id, parent.created_at, lineage.depth + 1
                   FROM messages AS parent
                   JOIN lineage
                     ON parent.conversation_id = lineage.conversation_id
                    AND parent.id = lineage.parent_id
                   WHERE lineage.depth < 511
                 ),
                 selected AS (
                   SELECT *
                   FROM lineage
                   WHERE role != 'system'
                     AND status != 'pending'
                     AND (status = 'complete' OR length(content) > 0)
                     AND length(CAST(content AS BLOB)) <= ?3
                     AND length(content) <= ?4
                   ORDER BY depth
                   LIMIT ?2
                 )
                 SELECT id, conversation_id, parent_id, role, content, status,
                        generation_id, created_at
                 FROM selected
                 ORDER BY depth DESC",
            )
            .map_err(storage_db_error)?;
        let rows = statement
            .query_map(
                params![
                    branch_id.0,
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

    pub fn append_generation(
        &self,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        user: &Message,
        assistant: &Message,
        generation: &GenerationRecord,
    ) -> CoreResult<()> {
        validate_generation_append(branch_id, expected_head, user, assistant, generation)?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        let stored = transaction
            .query_row(
                "SELECT conversation_id, head_message_id
                 FROM conversation_branches
                 WHERE id = ?1",
                [&branch_id.0],
                |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::NotFound,
                    "conversation branch was not found",
                    false,
                )
            })?;
        if stored.0 != user.conversation_id.0
            || stored.1.as_deref() != expected_head.map(|message_id| message_id.0.as_str())
        {
            return Err(stale_branch_error());
        }
        if let Some(head_id) = expected_head {
            let pending = transaction
                .query_row(
                    "SELECT status = 'pending'
                     FROM messages
                     WHERE conversation_id = ?1 AND id = ?2",
                    params![user.conversation_id.0, head_id.0],
                    |row| row.get::<_, bool>(0),
                )
                .optional()
                .map_err(storage_db_error)?
                .ok_or_else(|| {
                    CoreError::new(
                        CoreErrorCode::NotFound,
                        "expected branch head was not found",
                        false,
                    )
                })?;
            if pending {
                return Err(CoreError::new(
                    CoreErrorCode::InvalidInput,
                    "cannot append while the branch head is still generating",
                    true,
                ));
            }
        }
        insert_message(&transaction, user)?;
        insert_message(&transaction, assistant)?;
        insert_generation(&transaction, generation)?;
        let now = Utc::now().to_rfc3339();
        let changed = transaction
            .execute(
                "UPDATE conversation_branches
                 SET head_message_id = ?3, updated_at = ?4
                 WHERE id = ?1
                   AND conversation_id = ?2
                   AND (
                     (head_message_id IS NULL AND ?5 IS NULL)
                     OR head_message_id = ?5
                   )",
                params![
                    branch_id.0,
                    user.conversation_id.0,
                    assistant.id.0,
                    now,
                    expected_head.map(|message_id| message_id.0.as_str())
                ],
            )
            .map_err(storage_db_error)?;
        if changed != 1 {
            return Err(stale_branch_error());
        }
        transaction
            .execute(
                "UPDATE conversations SET updated_at = ?2 WHERE id = ?1",
                params![user.conversation_id.0, now],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)
    }

    #[allow(clippy::too_many_arguments)]
    pub fn append_message_generation_action(
        &self,
        source_branch_id: &ConversationBranchId,
        expected_source_head: Option<&MessageId>,
        target_message_id: &MessageId,
        action: MessageGenerationAction,
        branch: &ConversationBranch,
        user: &Message,
        assistant: &Message,
        generation: &GenerationRecord,
    ) -> CoreResult<()> {
        validate_generation_append(
            &branch.id,
            branch.fork_message_id.as_ref(),
            user,
            assistant,
            generation,
        )?;
        if branch.conversation_id != user.conversation_id
            || branch.head_message_id.as_ref() != Some(&assistant.id)
            || branch.fork_message_id != user.parent_id
        {
            return Err(CoreError::invalid(
                "message action branch does not own the appended generation",
            ));
        }

        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        let context = load_message_generation_action_context(
            &transaction,
            &user.conversation_id,
            source_branch_id,
            expected_source_head,
            target_message_id,
            action,
        )?;
        if context.fork_message_id != branch.fork_message_id
            || (action == MessageGenerationAction::RegenerateAssistant
                && context.user_text != user.content)
        {
            return Err(stale_branch_error());
        }

        insert_message(&transaction, user)?;
        insert_message(&transaction, assistant)?;
        transaction
            .execute(
                "INSERT INTO conversation_branches
                 (id, conversation_id, title, fork_message_id, head_message_id,
                  created_at, updated_at)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    branch.id.0,
                    branch.conversation_id.0,
                    branch.title,
                    branch
                        .fork_message_id
                        .as_ref()
                        .map(|message_id| message_id.0.as_str()),
                    branch
                        .head_message_id
                        .as_ref()
                        .map(|message_id| message_id.0.as_str()),
                    branch.created_at.to_rfc3339(),
                    branch.updated_at.to_rfc3339()
                ],
            )
            .map_err(storage_db_error)?;
        insert_generation(&transaction, generation)?;
        let now = Utc::now().to_rfc3339();
        let changed = transaction
            .execute(
                "UPDATE conversation_state
                 SET active_branch_id = ?3, updated_at = ?4
                 WHERE conversation_id = ?1
                   AND active_branch_id = ?2",
                params![user.conversation_id.0, source_branch_id.0, branch.id.0, now],
            )
            .map_err(storage_db_error)?;
        if changed != 1 {
            return Err(stale_branch_error());
        }
        transaction
            .execute(
                "UPDATE conversations SET updated_at = ?2 WHERE id = ?1",
                params![user.conversation_id.0, now],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)
    }

    pub fn remove_message_from_branch(
        &self,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        target_message_id: &MessageId,
    ) -> CoreResult<ConversationBranch> {
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        let target = load_branch_action_target(
            &transaction,
            conversation_id,
            branch_id,
            expected_head,
            target_message_id,
        )?;
        if target.status == MessageStatus::Pending {
            return Err(active_generation_action_error());
        }
        if !matches!(target.role, MessageRole::User | MessageRole::Assistant) {
            return Err(CoreError::invalid(
                "only user or assistant messages can be removed from a branch",
            ));
        }
        if let Some(new_head) = target.parent_id.as_ref() {
            let status = transaction
                .query_row(
                    "SELECT status
                     FROM messages
                     WHERE conversation_id = ?1 AND id = ?2",
                    params![conversation_id.0, new_head.0],
                    |row| row.get::<_, String>(0),
                )
                .optional()
                .map_err(storage_db_error)?
                .ok_or_else(|| {
                    CoreError::new(
                        CoreErrorCode::StorageCorrupted,
                        "message action parent was not found",
                        false,
                    )
                })?;
            if str_to_status(&status, 0).map_err(storage_db_error)? == MessageStatus::Pending {
                return Err(active_generation_action_error());
            }
        }

        let now = Utc::now().to_rfc3339();
        let changed = transaction
            .execute(
                "UPDATE conversation_branches
                 SET head_message_id = ?3, updated_at = ?4
                 WHERE id = ?1
                   AND conversation_id = ?2
                   AND (
                     (head_message_id IS NULL AND ?5 IS NULL)
                     OR head_message_id = ?5
                   )",
                params![
                    branch_id.0,
                    conversation_id.0,
                    target
                        .parent_id
                        .as_ref()
                        .map(|message_id| message_id.0.as_str()),
                    now,
                    expected_head.map(|message_id| message_id.0.as_str())
                ],
            )
            .map_err(storage_db_error)?;
        if changed != 1 {
            return Err(stale_branch_error());
        }
        transaction
            .execute(
                "UPDATE conversation_state
                 SET updated_at = ?3
                 WHERE conversation_id = ?1 AND active_branch_id = ?2",
                params![conversation_id.0, branch_id.0, now],
            )
            .map_err(storage_db_error)?;
        transaction
            .execute(
                "UPDATE conversations SET updated_at = ?2 WHERE id = ?1",
                params![conversation_id.0, now],
            )
            .map_err(storage_db_error)?;
        let branch = transaction
            .query_row(
                "SELECT id, conversation_id, title, fork_message_id, head_message_id,
                        created_at, updated_at
                 FROM conversation_branches
                 WHERE id = ?1 AND conversation_id = ?2",
                params![branch_id.0, conversation_id.0],
                map_conversation_branch,
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)?;
        Ok(branch)
    }

    pub fn finalize_generation(
        &self,
        assistant: &Message,
        usage: Option<&lorepia_domain::GenerationUsage>,
        error_code: Option<&str>,
        keep_assistant: bool,
    ) -> CoreResult<()> {
        if assistant.role != MessageRole::Assistant || assistant.status == MessageStatus::Pending {
            return Err(CoreError::invalid(
                "only a terminal assistant message can finalize a generation",
            ));
        }
        let generation_id = assistant.generation_id.as_ref().ok_or_else(|| {
            CoreError::invalid("a terminal assistant message requires a generation id")
        })?;
        let (input_tokens, output_tokens) = usage.map_or((None, None), |usage| {
            (usage.input_tokens, usage.output_tokens)
        });
        let input_tokens = input_tokens.map(u64_to_i64).transpose()?;
        let output_tokens = output_tokens.map(u64_to_i64).transpose()?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        let generation = load_running_generation(&transaction, generation_id)?;
        if generation.conversation != assistant.conversation_id.0
            || generation.assistant_message.as_deref() != Some(assistant.id.0.as_str())
        {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "generation assistant ownership is inconsistent",
                false,
            ));
        }
        let now = Utc::now().to_rfc3339();
        persist_terminal_assistant(
            &transaction,
            assistant,
            generation_id,
            &generation,
            &now,
            keep_assistant,
        )?;
        transaction
            .execute(
                "UPDATE generations
                 SET status = ?2,
                     input_tokens = ?3,
                     output_tokens = ?4,
                     error_code = ?5,
                     finished_at = ?6
                 WHERE id = ?1 AND status = 'running'",
                params![
                    generation_id.0,
                    generation_status_to_str(message_status_to_generation_status(assistant.status)),
                    input_tokens,
                    output_tokens,
                    error_code,
                    now
                ],
            )
            .map_err(storage_db_error)?;
        transaction
            .execute(
                "UPDATE conversations SET updated_at = ?2 WHERE id = ?1",
                params![assistant.conversation_id.0, now],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)
    }

    /// Marks a generation failed after its normal terminal transaction could not complete.
    ///
    /// This intentionally stores only a stable error code. Provider credentials and raw
    /// persistence errors must never enter the conversation database.
    pub fn fail_generation_after_finalize_error(
        &self,
        assistant: &Message,
        keep_assistant: bool,
    ) -> CoreResult<()> {
        if assistant.role != MessageRole::Assistant || assistant.status != MessageStatus::Failed {
            return Err(CoreError::invalid(
                "only a failed assistant message can compensate a generation finalization",
            ));
        }
        let generation_id = assistant.generation_id.as_ref().ok_or_else(|| {
            CoreError::invalid("a failed assistant message requires a generation id")
        })?;
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        let generation = load_running_generation(&transaction, generation_id)?;
        if generation.conversation != assistant.conversation_id.0
            || generation.assistant_message.as_deref() != Some(assistant.id.0.as_str())
        {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "generation assistant ownership is inconsistent",
                false,
            ));
        }
        let now = Utc::now().to_rfc3339();
        compensate_terminal_assistant(
            &transaction,
            assistant,
            generation_id,
            &generation,
            &now,
            keep_assistant,
        )?;
        let changed = transaction
            .execute(
                "UPDATE generations
                SET status = 'failed',
                     input_tokens = NULL,
                     output_tokens = NULL,
                     error_code = 'storage_unavailable',
                     finished_at = ?2
                 WHERE id = ?1 AND status = 'running'",
                params![generation_id.0, now],
            )
            .map_err(storage_db_error)?;
        if changed != 1 {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "generation compensation target was not found",
                false,
            ));
        }
        transaction
            .execute(
                "UPDATE conversations SET updated_at = ?2 WHERE id = ?1",
                params![assistant.conversation_id.0, now],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)
    }

    pub fn get_generation(&self, id: &GenerationId) -> CoreResult<GenerationRecord> {
        self.connection()?
            .query_row(
                "SELECT id, conversation_id, branch_id, user_message_id,
                        assistant_message_id, mode, model, status, input_tokens,
                        output_tokens, error_code, started_at, finished_at
                 FROM generations
                 WHERE id = ?1",
                [&id.0],
                map_generation,
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(CoreErrorCode::NotFound, "generation was not found", false)
            })
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
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        if let Some(profile_id) = settings.selected_provider_profile_id.as_deref() {
            let exists = transaction
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM provider_profiles WHERE id = ?1)",
                    [profile_id],
                    |row| row.get::<_, bool>(0),
                )
                .map_err(storage_db_error)?;
            if !exists {
                return Err(CoreError::new(
                    CoreErrorCode::NotFound,
                    "provider profile was not found",
                    false,
                ));
            }
        }
        transaction
            .execute(
                "INSERT INTO app_settings (key, value_json) VALUES ('application', ?1)
                 ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json",
                [json],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)
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
        let mut connection = self.connection()?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        let settings_json = transaction
            .query_row(
                "SELECT value_json FROM app_settings WHERE key = 'application'",
                [],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(storage_db_error)?;
        if let Some(settings_json) = settings_json {
            let mut settings =
                serde_json::from_str::<AppSettings>(&settings_json).map_err(|error| {
                    CoreError::new(
                        CoreErrorCode::StorageCorrupted,
                        format!("stored settings are invalid: {error}"),
                        false,
                    )
                })?;
            if settings.selected_provider_profile_id.as_deref() == Some(id) {
                settings.selected_provider_profile_id = None;
                let settings_json = serde_json::to_string(&settings).map_err(|error| {
                    CoreError::internal(format!("cannot encode settings: {error}"))
                })?;
                transaction
                    .execute(
                        "UPDATE app_settings SET value_json = ?1 WHERE key = 'application'",
                        [settings_json],
                    )
                    .map_err(storage_db_error)?;
            }
        }
        transaction
            .execute("DELETE FROM provider_profiles WHERE id = ?1", [id])
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)
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
    if current_version < 3 {
        validate_legacy_messages_for_branch_migration(connection)?;
        let transaction = connection.transaction().map_err(storage_db_error)?;
        transaction
            .execute_batch(MIGRATION_0003)
            .map_err(storage_db_error)?;
        let foreign_key_violation = {
            let mut statement = transaction
                .prepare("PRAGMA foreign_key_check")
                .map_err(storage_db_error)?;
            statement
                .query_row([], |_| Ok(()))
                .optional()
                .map_err(storage_db_error)?
                .is_some()
        };
        if foreign_key_violation {
            return Err(CoreError::new(
                CoreErrorCode::StorageCorrupted,
                "conversation branch migration produced a foreign-key violation",
                false,
            ));
        }
        transaction
            .execute(
                "INSERT INTO schema_migrations (version, applied_at) VALUES (?1, ?2)",
                params![3, Utc::now().to_rfc3339()],
            )
            .map_err(storage_db_error)?;
        transaction.commit().map_err(storage_db_error)?;
    }
    Ok(())
}

fn validate_legacy_messages_for_branch_migration(connection: &Connection) -> CoreResult<()> {
    let invalid_enum_count = connection
        .query_row(
            "SELECT COUNT(*)
             FROM messages
             WHERE role NOT IN ('system', 'user', 'assistant')
                OR status NOT IN ('pending', 'complete', 'cancelled', 'failed')
                OR (role = 'assistant' AND generation_id IS NULL)
                OR (role = 'assistant' AND parent_id IS NULL)
                OR (
                  role = 'assistant'
                  AND NOT EXISTS (
                    SELECT 1
                    FROM messages AS parent
                    WHERE parent.conversation_id = messages.conversation_id
                      AND parent.id = messages.parent_id
                      AND parent.role = 'user'
                  )
                )
                OR (role <> 'assistant' AND generation_id IS NOT NULL)
                OR (role <> 'assistant' AND status <> 'complete')",
            [],
            |row| row.get::<_, u64>(0),
        )
        .map_err(storage_db_error)?;
    if invalid_enum_count != 0 {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "legacy messages contain invalid role, status, or generation ownership",
            false,
        ));
    }
    let duplicate_generation_count = connection
        .query_row(
            "SELECT COUNT(*)
             FROM (
               SELECT generation_id
               FROM messages
               WHERE generation_id IS NOT NULL
               GROUP BY generation_id
               HAVING COUNT(*) > 1
             )",
            [],
            |row| row.get::<_, u64>(0),
        )
        .map_err(storage_db_error)?;
    if duplicate_generation_count != 0 {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "legacy messages reuse a generation id",
            false,
        ));
    }
    let inconsistent_parent_count = connection
        .query_row(
            "WITH migration_order AS (
               SELECT message.id,
                      message.conversation_id,
                      message.parent_id,
                      message.role,
                      message.created_at,
                      CASE
                        WHEN message.role = 'assistant' THEN parent.created_at
                        ELSE message.created_at
                      END AS turn_created_at,
                      CASE
                        WHEN message.role = 'assistant' THEN parent.id
                        ELSE message.id
                      END AS turn_id,
                      CASE
                        WHEN message.role = 'assistant' THEN 1
                        ELSE 0
                      END AS turn_position
               FROM messages AS message
               LEFT JOIN messages AS parent
                 ON message.role = 'assistant'
                AND parent.conversation_id = message.conversation_id
                AND parent.id = message.parent_id
                AND parent.role = 'user'
             ),
             lineage AS (
               SELECT parent_id,
                      LAG(id) OVER (
                        PARTITION BY conversation_id
                        ORDER BY turn_created_at, turn_id, turn_position, created_at, id
                      ) AS expected_parent_id
               FROM migration_order
             )
             SELECT COUNT(*)
             FROM lineage
             WHERE parent_id IS NOT NULL
               AND parent_id IS NOT expected_parent_id",
            [],
            |row| row.get::<_, u64>(0),
        )
        .map_err(storage_db_error)?;
    if inconsistent_parent_count != 0 {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "legacy message parents disagree with the persisted timeline order",
            false,
        ));
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
    let recovered_at = Utc::now().to_rfc3339();
    transaction
        .execute(
            "UPDATE generations
             SET status = 'cancelled', finished_at = ?1
             WHERE status = 'running'",
            [&recovered_at],
        )
        .map_err(storage_db_error)?;
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
                "UPDATE conversation_branches
                 SET head_message_id = CASE
                       WHEN head_message_id IN (
                         SELECT id
                         FROM messages
                         WHERE role = 'assistant' AND status = 'pending'
                       )
                       THEN (
                         SELECT parent_id
                         FROM messages
                         WHERE messages.id = conversation_branches.head_message_id
                       )
                       ELSE head_message_id
                     END,
                     fork_message_id = CASE
                       WHEN fork_message_id IN (
                         SELECT id
                         FROM messages
                         WHERE role = 'assistant' AND status = 'pending'
                       )
                       THEN (
                         SELECT parent_id
                         FROM messages
                         WHERE messages.id = conversation_branches.fork_message_id
                       )
                       ELSE fork_message_id
                     END,
                     updated_at = ?1
                 WHERE head_message_id IN (
                         SELECT id
                         FROM messages
                         WHERE role = 'assistant' AND status = 'pending'
                       )
                    OR fork_message_id IN (
                         SELECT id
                         FROM messages
                         WHERE role = 'assistant' AND status = 'pending'
                       )",
                [&recovered_at],
            )
            .map_err(storage_db_error)?;
        transaction
            .execute(
                "UPDATE messages AS child
                 SET parent_id = (
                   SELECT pending.parent_id
                   FROM messages AS pending
                   WHERE pending.id = child.parent_id
                     AND pending.conversation_id = child.conversation_id
                     AND pending.role = 'assistant'
                     AND pending.status = 'pending'
                 )
                 WHERE child.parent_id IN (
                   SELECT id
                   FROM messages
                   WHERE role = 'assistant' AND status = 'pending'
                 )",
                [],
            )
            .map_err(storage_db_error)?;
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

fn validate_generation_append(
    branch_id: &ConversationBranchId,
    expected_head: Option<&MessageId>,
    user: &Message,
    assistant: &Message,
    generation: &GenerationRecord,
) -> CoreResult<()> {
    if user.role != MessageRole::User
        || user.status != MessageStatus::Complete
        || user.generation_id.is_some()
        || user.parent_id.as_ref() != expected_head
    {
        return Err(CoreError::invalid(
            "branch append requires a complete user message parented to the expected head",
        ));
    }
    if assistant.role != MessageRole::Assistant
        || assistant.status != MessageStatus::Pending
        || assistant.parent_id.as_ref() != Some(&user.id)
        || assistant.conversation_id != user.conversation_id
    {
        return Err(CoreError::invalid(
            "branch append requires a pending assistant child of the user message",
        ));
    }
    if generation.status != GenerationStatus::Running
        || generation.finished_at.is_some()
        || generation.id
            != assistant.generation_id.clone().ok_or_else(|| {
                CoreError::invalid("pending assistant message requires a generation id")
            })?
        || generation.conversation_id != user.conversation_id
        || &generation.branch_id != branch_id
        || generation.user_message_id != user.id
        || generation.assistant_message_id.as_ref() != Some(&assistant.id)
    {
        return Err(CoreError::invalid(
            "generation record does not own the appended user and assistant messages",
        ));
    }
    Ok(())
}

fn load_message_generation_action_context(
    connection: &Connection,
    conversation_id: &ConversationId,
    branch_id: &ConversationBranchId,
    expected_head: Option<&MessageId>,
    target_message_id: &MessageId,
    action: MessageGenerationAction,
) -> CoreResult<MessageGenerationActionContext> {
    let target = load_branch_action_target(
        connection,
        conversation_id,
        branch_id,
        expected_head,
        target_message_id,
    )?;
    match action {
        MessageGenerationAction::EditUser => {
            if target.role != MessageRole::User || target.status != MessageStatus::Complete {
                return Err(CoreError::invalid(
                    "only a complete user message can be edited",
                ));
            }
            Ok(MessageGenerationActionContext {
                fork_message_id: target.parent_id,
                user_text: target.content,
            })
        }
        MessageGenerationAction::RegenerateAssistant => {
            if target.role != MessageRole::Assistant {
                return Err(CoreError::invalid(
                    "only an assistant message can be regenerated",
                ));
            }
            if target.status == MessageStatus::Pending {
                return Err(active_generation_action_error());
            }
            let user_message_id = target.parent_id.ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::StorageCorrupted,
                    "assistant message is missing its user parent",
                    false,
                )
            })?;
            let user = connection
                .query_row(
                    "SELECT id, conversation_id, parent_id, role, content, status,
                            generation_id, created_at
                     FROM messages
                     WHERE conversation_id = ?1 AND id = ?2",
                    params![conversation_id.0, user_message_id.0],
                    map_message,
                )
                .optional()
                .map_err(storage_db_error)?
                .ok_or_else(|| {
                    CoreError::new(
                        CoreErrorCode::StorageCorrupted,
                        "assistant message user parent was not found",
                        false,
                    )
                })?;
            if user.role != MessageRole::User || user.status != MessageStatus::Complete {
                return Err(CoreError::new(
                    CoreErrorCode::StorageCorrupted,
                    "assistant message parent is not a complete user message",
                    false,
                ));
            }
            Ok(MessageGenerationActionContext {
                fork_message_id: user.parent_id,
                user_text: user.content,
            })
        }
    }
}

fn load_branch_action_target(
    connection: &Connection,
    conversation_id: &ConversationId,
    branch_id: &ConversationBranchId,
    expected_head: Option<&MessageId>,
    target_message_id: &MessageId,
) -> CoreResult<Message> {
    validate_branch_action_snapshot(connection, conversation_id, branch_id, expected_head)?;

    connection
        .query_row(
            "WITH RECURSIVE lineage(
               id, conversation_id, parent_id, role, content, status,
               generation_id, created_at
             ) AS (
               SELECT messages.id, messages.conversation_id, messages.parent_id,
                      messages.role, messages.content, messages.status,
                      messages.generation_id, messages.created_at
               FROM conversation_branches
               JOIN messages
                 ON messages.conversation_id = conversation_branches.conversation_id
                AND messages.id = conversation_branches.head_message_id
               WHERE conversation_branches.id = ?1
               UNION
               SELECT parent.id, parent.conversation_id, parent.parent_id,
                      parent.role, parent.content, parent.status,
                      parent.generation_id, parent.created_at
               FROM messages AS parent
               JOIN lineage
                 ON parent.conversation_id = lineage.conversation_id
                AND parent.id = lineage.parent_id
             )
             SELECT id, conversation_id, parent_id, role, content, status,
                    generation_id, created_at
             FROM lineage
             WHERE id = ?2
             LIMIT 1",
            params![branch_id.0, target_message_id.0],
            map_message,
        )
        .optional()
        .map_err(storage_db_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "message was not found in the selected branch",
                false,
            )
        })
}

fn validate_branch_action_snapshot(
    connection: &Connection,
    conversation_id: &ConversationId,
    branch_id: &ConversationBranchId,
    expected_head: Option<&MessageId>,
) -> CoreResult<()> {
    let branch = connection
        .query_row(
            "SELECT branches.conversation_id, branches.head_message_id,
                    state.active_branch_id
             FROM conversation_branches AS branches
             JOIN conversation_state AS state
               ON state.conversation_id = branches.conversation_id
             WHERE branches.id = ?1",
            [&branch_id.0],
            |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, Option<String>>(1)?,
                    row.get::<_, String>(2)?,
                ))
            },
        )
        .optional()
        .map_err(storage_db_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "conversation branch was not found",
                false,
            )
        })?;
    if branch.0 != conversation_id.0 {
        return Err(CoreError::new(
            CoreErrorCode::NotFound,
            "conversation branch was not found in the conversation",
            false,
        ));
    }
    if branch.1.as_deref() != expected_head.map(|message_id| message_id.0.as_str())
        || branch.2 != branch_id.0
    {
        return Err(stale_branch_error());
    }
    if let Some(head_message_id) = branch.1.as_deref() {
        let status = connection
            .query_row(
                "SELECT status
                 FROM messages
                 WHERE conversation_id = ?1 AND id = ?2",
                params![conversation_id.0, head_message_id],
                |row| row.get::<_, String>(0),
            )
            .optional()
            .map_err(storage_db_error)?
            .ok_or_else(|| {
                CoreError::new(
                    CoreErrorCode::StorageCorrupted,
                    "conversation branch head was not found",
                    false,
                )
            })?;
        if str_to_status(&status, 0).map_err(storage_db_error)? == MessageStatus::Pending {
            return Err(active_generation_action_error());
        }
    }
    Ok(())
}

fn active_generation_action_error() -> CoreError {
    CoreError::new(
        CoreErrorCode::InvalidInput,
        "message actions are unavailable while the branch is generating",
        true,
    )
}

fn insert_message(transaction: &rusqlite::Transaction<'_>, message: &Message) -> CoreResult<()> {
    transaction
        .execute(
            "INSERT INTO messages
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

fn insert_generation(
    transaction: &rusqlite::Transaction<'_>,
    generation: &GenerationRecord,
) -> CoreResult<()> {
    transaction
        .execute(
            "INSERT INTO generations
             (id, conversation_id, branch_id, user_message_id, assistant_message_id,
              mode, model, status, input_tokens, output_tokens, error_code,
              started_at, finished_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                generation.id.0,
                generation.conversation_id.0,
                generation.branch_id.0,
                generation.user_message_id.0,
                generation
                    .assistant_message_id
                    .as_ref()
                    .map(|value| value.0.as_str()),
                mode_to_str(generation.mode),
                generation.model,
                generation_status_to_str(generation.status),
                generation.input_tokens.map(u64_to_i64).transpose()?,
                generation.output_tokens.map(u64_to_i64).transpose()?,
                generation.error_code,
                generation.started_at.to_rfc3339(),
                generation.finished_at.map(|value| value.to_rfc3339())
            ],
        )
        .map_err(storage_db_error)?;
    Ok(())
}

fn load_running_generation(
    transaction: &rusqlite::Transaction<'_>,
    generation_id: &GenerationId,
) -> CoreResult<StoredGenerationRoute> {
    transaction
        .query_row(
            "SELECT conversation_id, branch_id, user_message_id, assistant_message_id
             FROM generations
             WHERE id = ?1 AND status = 'running'",
            [&generation_id.0],
            |row| {
                Ok(StoredGenerationRoute {
                    conversation: row.get(0)?,
                    branch: row.get(1)?,
                    user_message: row.get(2)?,
                    assistant_message: row.get(3)?,
                })
            },
        )
        .optional()
        .map_err(storage_db_error)?
        .ok_or_else(|| {
            CoreError::new(
                CoreErrorCode::NotFound,
                "running generation was not found",
                false,
            )
        })
}

fn persist_terminal_assistant(
    transaction: &rusqlite::Transaction<'_>,
    assistant: &Message,
    generation_id: &GenerationId,
    generation: &StoredGenerationRoute,
    finished_at: &str,
    keep_assistant: bool,
) -> CoreResult<()> {
    if keep_assistant {
        let changed = transaction
            .execute(
                "UPDATE messages
                 SET content = ?3, status = ?4
                 WHERE id = ?1
                   AND generation_id = ?2
                   AND role = 'assistant'
                   AND status = 'pending'",
                params![
                    assistant.id.0,
                    generation_id.0,
                    assistant.content,
                    status_to_str(assistant.status)
                ],
            )
            .map_err(storage_db_error)?;
        if changed == 1 {
            return Ok(());
        }
        return Err(CoreError::new(
            CoreErrorCode::NotFound,
            "pending assistant finalization target was not found",
            false,
        ));
    }
    transaction
        .execute(
            "UPDATE conversation_branches
             SET head_message_id = ?3, updated_at = ?4
             WHERE id = ?1
               AND conversation_id = ?2
               AND head_message_id = ?5",
            params![
                generation.branch,
                generation.conversation,
                generation.user_message,
                finished_at,
                assistant.id.0
            ],
        )
        .map_err(storage_db_error)?;
    transaction
        .execute("DELETE FROM messages WHERE id = ?1", [&assistant.id.0])
        .map_err(storage_db_error)?;
    Ok(())
}

fn compensate_terminal_assistant(
    transaction: &rusqlite::Transaction<'_>,
    assistant: &Message,
    generation_id: &GenerationId,
    generation: &StoredGenerationRoute,
    finished_at: &str,
    keep_assistant: bool,
) -> CoreResult<()> {
    if keep_assistant {
        let changed = transaction
            .execute(
                "UPDATE messages
                 SET content = ?3, status = 'failed'
                 WHERE id = ?1
                   AND generation_id = ?2
                   AND role = 'assistant'
                   AND status = 'pending'",
                params![assistant.id.0, generation_id.0, assistant.content],
            )
            .map_err(storage_db_error)?;
        if changed == 1 {
            return Ok(());
        }
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "generation assistant compensation target was not found",
            false,
        ));
    }
    let changed = transaction
        .execute(
            "UPDATE conversation_branches
             SET head_message_id = ?3, updated_at = ?4
             WHERE id = ?1
               AND conversation_id = ?2
               AND head_message_id = ?5",
            params![
                generation.branch,
                generation.conversation,
                generation.user_message,
                finished_at,
                assistant.id.0
            ],
        )
        .map_err(storage_db_error)?;
    if changed != 1 {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "generation branch compensation target was not found",
            false,
        ));
    }
    let changed = transaction
        .execute(
            "DELETE FROM messages
             WHERE id = ?1
               AND generation_id = ?2
               AND role = 'assistant'
               AND status = 'pending'",
            params![assistant.id.0, generation_id.0],
        )
        .map_err(storage_db_error)?;
    if changed != 1 {
        return Err(CoreError::new(
            CoreErrorCode::StorageCorrupted,
            "generation assistant compensation target was not found",
            false,
        ));
    }
    Ok(())
}

fn stale_branch_error() -> CoreError {
    CoreError::new(
        CoreErrorCode::InvalidInput,
        "conversation branch head changed; refresh before retrying",
        true,
    )
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
    sync_file(file_path).map_err(storage_io_error)?;
    sync_directory(parent)
}

#[cfg(not(windows))]
fn sync_file(path: &Path) -> std::io::Result<()> {
    File::open(path).and_then(|file| file.sync_all())
}

#[cfg(windows)]
fn sync_file(path: &Path) -> std::io::Result<()> {
    // FlushFileBuffers requires a handle with write access on Windows.
    OpenOptions::new()
        .write(true)
        .open(path)
        .and_then(|file| file.sync_all())
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

fn map_conversation(row: &rusqlite::Row<'_>) -> rusqlite::Result<Conversation> {
    Ok(Conversation {
        id: ConversationId(row.get(0)?),
        character_id: row.get(1)?,
        title: row.get(2)?,
        created_at: parse_datetime_sql(row.get::<_, String>(3)?, 3)?,
        updated_at: parse_datetime_sql(row.get::<_, String>(4)?, 4)?,
    })
}

fn map_conversation_branch(row: &rusqlite::Row<'_>) -> rusqlite::Result<ConversationBranch> {
    Ok(ConversationBranch {
        id: ConversationBranchId(row.get(0)?),
        conversation_id: ConversationId(row.get(1)?),
        title: row.get(2)?,
        fork_message_id: row.get::<_, Option<String>>(3)?.map(MessageId),
        head_message_id: row.get::<_, Option<String>>(4)?.map(MessageId),
        created_at: parse_datetime_sql(row.get::<_, String>(5)?, 5)?,
        updated_at: parse_datetime_sql(row.get::<_, String>(6)?, 6)?,
    })
}

fn map_conversation_state(row: &rusqlite::Row<'_>) -> rusqlite::Result<ConversationState> {
    let mode = row.get::<_, String>(2)?;
    Ok(ConversationState {
        conversation_id: ConversationId(row.get(0)?),
        active_branch_id: ConversationBranchId(row.get(1)?),
        selected_mode: str_to_mode(&mode, 2)?,
        updated_at: parse_datetime_sql(row.get::<_, String>(3)?, 3)?,
    })
}

fn map_generation(row: &rusqlite::Row<'_>) -> rusqlite::Result<GenerationRecord> {
    let mode = row.get::<_, String>(5)?;
    let status = row.get::<_, String>(7)?;
    Ok(GenerationRecord {
        id: GenerationId(row.get(0)?),
        conversation_id: ConversationId(row.get(1)?),
        branch_id: ConversationBranchId(row.get(2)?),
        user_message_id: MessageId(row.get(3)?),
        assistant_message_id: row.get::<_, Option<String>>(4)?.map(MessageId),
        mode: str_to_mode(&mode, 5)?,
        model: row.get(6)?,
        status: str_to_generation_status(&status, 7)?,
        input_tokens: optional_i64_to_u64_sql(row.get(8)?, 8)?,
        output_tokens: optional_i64_to_u64_sql(row.get(9)?, 9)?,
        error_code: row.get(10)?,
        started_at: parse_datetime_sql(row.get::<_, String>(11)?, 11)?,
        finished_at: row
            .get::<_, Option<String>>(12)?
            .map(|value| parse_datetime_sql(value, 12))
            .transpose()?,
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

fn optional_i64_to_u64_sql(value: Option<i64>, column: usize) -> rusqlite::Result<Option<u64>> {
    value
        .map(|value| {
            u64::try_from(value).map_err(|error| {
                rusqlite::Error::FromSqlConversionFailure(
                    column,
                    rusqlite::types::Type::Integer,
                    Box::new(error),
                )
            })
        })
        .transpose()
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

const fn mode_to_str(mode: ConversationMode) -> &'static str {
    match mode {
        ConversationMode::Chat => "chat",
        ConversationMode::Story => "story",
    }
}

fn str_to_mode(value: &str, column: usize) -> rusqlite::Result<ConversationMode> {
    match value {
        "chat" => Ok(ConversationMode::Chat),
        "story" => Ok(ConversationMode::Story),
        other => Err(invalid_enum(column, "conversation mode", other)),
    }
}

const fn generation_status_to_str(status: GenerationStatus) -> &'static str {
    match status {
        GenerationStatus::Running => "running",
        GenerationStatus::Complete => "complete",
        GenerationStatus::Cancelled => "cancelled",
        GenerationStatus::Failed => "failed",
    }
}

fn str_to_generation_status(value: &str, column: usize) -> rusqlite::Result<GenerationStatus> {
    match value {
        "running" => Ok(GenerationStatus::Running),
        "complete" => Ok(GenerationStatus::Complete),
        "cancelled" => Ok(GenerationStatus::Cancelled),
        "failed" => Ok(GenerationStatus::Failed),
        other => Err(invalid_enum(column, "generation status", other)),
    }
}

const fn message_status_to_generation_status(status: MessageStatus) -> GenerationStatus {
    match status {
        MessageStatus::Pending => GenerationStatus::Running,
        MessageStatus::Complete => GenerationStatus::Complete,
        MessageStatus::Cancelled => GenerationStatus::Cancelled,
        MessageStatus::Failed => GenerationStatus::Failed,
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
    use std::{
        io::Write,
        sync::{Arc, Barrier},
        thread,
    };

    use chrono::Duration;
    use tempfile::{NamedTempFile, tempdir};

    use super::*;

    fn append_pending_generation(
        storage: &Storage,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        user_text: &str,
    ) -> (Message, Message, GenerationRecord) {
        let user = Message::user_after(conversation_id.clone(), expected_head.cloned(), user_text);
        let generation_id = GenerationId::new();
        let pending = Message::pending_assistant(
            conversation_id.clone(),
            user.id.clone(),
            generation_id.clone(),
        );
        let generation = GenerationRecord {
            id: generation_id,
            conversation_id: conversation_id.clone(),
            branch_id: branch_id.clone(),
            user_message_id: user.id.clone(),
            assistant_message_id: Some(pending.id.clone()),
            mode: ConversationMode::Chat,
            model: "synthetic".to_owned(),
            status: GenerationStatus::Running,
            input_tokens: None,
            output_tokens: None,
            error_code: None,
            started_at: pending.created_at,
            finished_at: None,
        };
        storage
            .append_generation(branch_id, expected_head, &user, &pending, &generation)
            .expect("append generation");
        (user, pending, generation)
    }

    fn append_complete_generation(
        storage: &Storage,
        conversation_id: &ConversationId,
        branch_id: &ConversationBranchId,
        expected_head: Option<&MessageId>,
        user_text: &str,
        assistant_text: &str,
    ) -> (Message, Message) {
        let (user, pending, _) = append_pending_generation(
            storage,
            conversation_id,
            branch_id,
            expected_head,
            user_text,
        );
        let mut assistant = pending;
        assistant.content = assistant_text.to_owned();
        assistant.status = MessageStatus::Complete;
        storage
            .finalize_generation(&assistant, None, None, true)
            .expect("finalize generation");
        (user, assistant)
    }

    fn imported_storage() -> (
        tempfile::TempDir,
        Storage,
        Conversation,
        ConversationBranchId,
    ) {
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
        let (_, state) = storage
            .save_conversation_with_mode(&conversation, ConversationMode::Chat)
            .expect("save conversation");
        (root, storage, conversation, state.active_branch_id)
    }

    fn version_two_database(root: &std::path::Path) -> Connection {
        fs::create_dir_all(root.join("db")).expect("db directory");
        let connection =
            Connection::open(root.join("db/lorepia.sqlite3")).expect("legacy database");
        connection
            .execute_batch(MIGRATION_0001)
            .expect("initial schema");
        connection
            .execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (1, ?1)",
                ["2026-01-01T00:00:00Z"],
            )
            .expect("version one");
        connection
            .execute_batch(MIGRATION_0002)
            .expect("second migration");
        connection
            .execute(
                "INSERT INTO schema_migrations(version, applied_at) VALUES (2, ?1)",
                ["2026-01-01T00:00:00Z"],
            )
            .expect("version two");
        connection
            .execute(
                "INSERT INTO content_sources
                 (sha256, relative_path, size_bytes, created_at)
                 VALUES (?1, ?2, 1, ?3)",
                params![
                    "a".repeat(64),
                    format!("sources/sha256/aa/{}", "a".repeat(64)),
                    "2026-01-01T00:00:00Z"
                ],
            )
            .expect("legacy source");
        connection
            .execute(
                "INSERT INTO characters
                 (id, name, description, source_hash, avatar_asset_hash, created_at)
                 VALUES ('character', 'Legacy', 'Legacy character', ?1, NULL, ?2)",
                params!["a".repeat(64), "2026-01-01T00:00:00Z"],
            )
            .expect("legacy character");
        connection
            .execute(
                "INSERT INTO conversations
                 (id, character_id, title, created_at, updated_at)
                 VALUES ('conversation', 'character', 'Legacy room', ?1, ?2)",
                params!["2026-01-01T00:00:00Z", "2026-01-01T00:00:04Z"],
            )
            .expect("legacy conversation");
        connection
    }

    fn insert_legacy_message(
        connection: &Connection,
        row: (&str, Option<&str>, &str, &str, &str, Option<&str>, &str),
    ) {
        let (id, parent_id, role, content, status, generation_id, created_at) = row;
        connection
            .execute(
                "INSERT INTO messages
                 (id, conversation_id, parent_id, role, content, status,
                  generation_id, created_at)
                 VALUES (?1, 'conversation', ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    id,
                    parent_id,
                    role,
                    content,
                    status,
                    generation_id,
                    created_at
                ],
            )
            .expect("legacy message");
    }

    #[test]
    fn usage_overflow_can_be_compensated_and_the_branch_accepts_another_generation() {
        let (_root, storage, conversation, branch_id) = imported_storage();
        let (_user, pending, generation) =
            append_pending_generation(&storage, &conversation.id, &branch_id, None, "first");
        let mut assistant = pending.clone();
        assistant.content = "response before invalid usage".to_owned();
        assistant.status = MessageStatus::Complete;
        let error = storage
            .finalize_generation(
                &assistant,
                Some(&lorepia_domain::GenerationUsage {
                    input_tokens: Some(i64::MAX as u64 + 1),
                    output_tokens: Some(1),
                }),
                None,
                true,
            )
            .expect_err("overflow usage must reject normal finalization");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);
        assert_eq!(
            storage
                .get_generation(&generation.id)
                .expect("running generation")
                .status,
            GenerationStatus::Running
        );
        assert_eq!(
            storage
                .list_branch_messages(&branch_id)
                .expect("pending lineage")[1]
                .status,
            MessageStatus::Pending
        );

        assistant.status = MessageStatus::Failed;
        storage
            .fail_generation_after_finalize_error(&assistant, true)
            .expect("compensate overflow");
        let failed = storage
            .get_generation(&generation.id)
            .expect("failed generation");
        assert_eq!(failed.status, GenerationStatus::Failed);
        assert_eq!(failed.input_tokens, None);
        assert_eq!(failed.output_tokens, None);
        assert_eq!(
            failed.error_code.as_deref(),
            Some(CoreErrorCode::StorageUnavailable.as_str())
        );
        assert!(failed.finished_at.is_some());
        let messages = storage
            .list_branch_messages(&branch_id)
            .expect("failed lineage");
        assert_eq!(messages[1].status, MessageStatus::Failed);

        let (_, retry) = append_complete_generation(
            &storage,
            &conversation.id,
            &branch_id,
            Some(&assistant.id),
            "retry",
            "retry succeeded",
        );
        assert_eq!(retry.status, MessageStatus::Complete);
        assert!(
            storage
                .list_branch_messages(&branch_id)
                .expect("retried lineage")
                .iter()
                .all(|message| message.status != MessageStatus::Pending)
        );
    }

    #[test]
    fn terminal_database_failure_is_compensated_without_raw_error_text() {
        let (_root, storage, conversation, branch_id) = imported_storage();
        let (_user, pending, generation) = append_pending_generation(
            &storage,
            &conversation.id,
            &branch_id,
            None,
            "trigger failure",
        );
        storage
            .connection()
            .expect("connection")
            .execute_batch(
                "CREATE TEMP TRIGGER reject_complete_generation
                 BEFORE UPDATE OF status ON generations
                 WHEN NEW.status = 'complete'
                 BEGIN
                   SELECT RAISE(ABORT, 'synthetic terminal database failure');
                 END;",
            )
            .expect("install synthetic failure");

        let mut assistant = pending;
        assistant.content = "completed provider response".to_owned();
        assistant.status = MessageStatus::Complete;
        let error = storage
            .finalize_generation(&assistant, None, None, true)
            .expect_err("synthetic terminal update must fail");
        assert_eq!(error.code, CoreErrorCode::StorageUnavailable);

        assistant.status = MessageStatus::Failed;
        storage
            .fail_generation_after_finalize_error(&assistant, true)
            .expect("compensate terminal database failure");
        let failed = storage
            .get_generation(&generation.id)
            .expect("failed generation");
        assert_eq!(failed.status, GenerationStatus::Failed);
        assert_eq!(
            failed.error_code.as_deref(),
            Some(CoreErrorCode::StorageUnavailable.as_str())
        );
        assert!(
            !failed
                .error_code
                .as_deref()
                .unwrap_or_default()
                .contains("synthetic")
        );
        let messages = storage
            .list_branch_messages(&branch_id)
            .expect("failed lineage");
        assert_eq!(messages[1].status, MessageStatus::Failed);
        assert_eq!(messages[1].content, "completed provider response");
    }

    #[test]
    fn compensation_never_regresses_an_already_terminal_generation() {
        let (_root, storage, conversation, branch_id) = imported_storage();
        let (_, complete) = append_complete_generation(
            &storage,
            &conversation.id,
            &branch_id,
            None,
            "already complete",
            "durable response",
        );
        let generation_id = complete
            .generation_id
            .clone()
            .expect("assistant generation id");
        let mut attempted_compensation = complete.clone();
        attempted_compensation.status = MessageStatus::Failed;
        let error = storage
            .fail_generation_after_finalize_error(&attempted_compensation, true)
            .expect_err("terminal generation must reject compensation");
        assert_eq!(error.code, CoreErrorCode::NotFound);

        let generation = storage
            .get_generation(&generation_id)
            .expect("terminal generation");
        assert_eq!(generation.status, GenerationStatus::Complete);
        assert_eq!(generation.error_code, None);
        let messages = storage
            .list_branch_messages(&branch_id)
            .expect("terminal lineage");
        assert_eq!(messages[1].status, MessageStatus::Complete);
        assert_eq!(messages[1].content, "durable response");
    }

    #[test]
    fn discarded_partial_compensation_rewinds_the_branch_head() {
        let (_root, storage, conversation, branch_id) = imported_storage();
        let (user, pending, generation) = append_pending_generation(
            &storage,
            &conversation.id,
            &branch_id,
            None,
            "discard partial",
        );
        let mut assistant = pending;
        assistant.content = "partial response".to_owned();
        assistant.status = MessageStatus::Failed;
        let error = storage
            .finalize_generation(
                &assistant,
                Some(&lorepia_domain::GenerationUsage {
                    input_tokens: Some(i64::MAX as u64 + 1),
                    output_tokens: None,
                }),
                Some(CoreErrorCode::ProviderUnavailable.as_str()),
                false,
            )
            .expect_err("overflow usage must reject normal finalization");
        assert_eq!(error.code, CoreErrorCode::InvalidInput);

        storage
            .fail_generation_after_finalize_error(&assistant, false)
            .expect("discard compensated partial");
        assert_eq!(
            storage
                .get_generation(&generation.id)
                .expect("failed generation")
                .status,
            GenerationStatus::Failed
        );
        let branch = storage
            .get_conversation_branch(&branch_id)
            .expect("compensated branch");
        assert_eq!(branch.head_message_id, Some(user.id.clone()));
        assert_eq!(
            storage
                .list_branch_messages(&branch_id)
                .expect("rewound lineage"),
            vec![user]
        );
    }

    #[test]
    fn provider_profile_delete_and_selection_clear_are_atomic() {
        let root = tempdir().expect("temp root");
        let storage = Storage::open(root.path()).expect("open storage");
        let profile = ProviderProfile {
            id: "selected".to_owned(),
            display_name: "Selected".to_owned(),
            base_url: "http://127.0.0.1:11434/v1".to_owned(),
            model: "synthetic".to_owned(),
            timeout_seconds: 30,
        };
        storage
            .save_provider_profile(&profile)
            .expect("save provider");
        storage
            .save_settings(&AppSettings {
                preserve_partial_generations: true,
                selected_provider_profile_id: Some(profile.id.clone()),
            })
            .expect("select provider");
        storage
            .connection()
            .expect("connection")
            .execute_batch(
                "CREATE TEMP TRIGGER reject_provider_delete
                 BEFORE DELETE ON provider_profiles
                 BEGIN
                   SELECT RAISE(ABORT, 'synthetic provider delete failure');
                 END;",
            )
            .expect("install synthetic failure");

        let error = storage
            .delete_provider_profile(&profile.id)
            .expect_err("delete trigger must abort");
        assert_eq!(error.code, CoreErrorCode::StorageUnavailable);
        assert_eq!(
            storage
                .load_settings()
                .expect("settings after rollback")
                .selected_provider_profile_id
                .as_deref(),
            Some(profile.id.as_str())
        );
        assert_eq!(
            storage
                .get_provider_profile(&profile.id)
                .expect("provider after rollback"),
            profile
        );

        storage
            .connection()
            .expect("connection")
            .execute_batch("DROP TRIGGER reject_provider_delete;")
            .expect("remove synthetic failure");
        storage
            .delete_provider_profile(&profile.id)
            .expect("delete provider");
        assert!(
            storage
                .list_provider_profiles()
                .expect("providers")
                .is_empty()
        );
        assert_eq!(
            storage
                .load_settings()
                .expect("settings after delete")
                .selected_provider_profile_id,
            None
        );
    }

    #[test]
    fn concurrent_provider_selection_and_delete_cannot_leave_dangling_settings() {
        let root = tempdir().expect("temp root");
        let storage = Arc::new(Storage::open(root.path()).expect("open storage"));

        for index in 0..32 {
            let profile = ProviderProfile {
                id: format!("provider-{index}"),
                display_name: format!("Provider {index}"),
                base_url: "http://127.0.0.1:11434/v1".to_owned(),
                model: "synthetic".to_owned(),
                timeout_seconds: 30,
            };
            storage
                .save_provider_profile(&profile)
                .expect("save provider");
            storage
                .save_settings(&AppSettings {
                    preserve_partial_generations: true,
                    selected_provider_profile_id: None,
                })
                .expect("reset settings");

            let barrier = Arc::new(Barrier::new(3));
            let selecting_storage = Arc::clone(&storage);
            let selecting_barrier = Arc::clone(&barrier);
            let selected_id = profile.id.clone();
            let selection = thread::spawn(move || {
                selecting_barrier.wait();
                selecting_storage.save_settings(&AppSettings {
                    preserve_partial_generations: true,
                    selected_provider_profile_id: Some(selected_id),
                })
            });
            let deleting_storage = Arc::clone(&storage);
            let deleting_barrier = Arc::clone(&barrier);
            let deleted_id = profile.id.clone();
            let deletion = thread::spawn(move || {
                deleting_barrier.wait();
                deleting_storage.delete_provider_profile(&deleted_id)
            });
            barrier.wait();

            let selection = selection.join().expect("selection thread");
            deletion
                .join()
                .expect("deletion thread")
                .expect("delete provider");
            if let Err(error) = selection {
                assert_eq!(error.code, CoreErrorCode::NotFound);
            }
            assert_eq!(
                storage
                    .get_provider_profile(&profile.id)
                    .expect_err("provider must be deleted")
                    .code,
                CoreErrorCode::NotFound
            );
            assert_eq!(
                storage
                    .load_settings()
                    .expect("settings after concurrent operations")
                    .selected_provider_profile_id,
                None
            );
        }
    }

    #[test]
    #[allow(clippy::too_many_lines)]
    fn message_actions_preserve_rows_and_guard_branch_snapshots() {
        let (_root, storage, conversation, source_branch_id) = imported_storage();
        let (original_user, original_assistant) = append_complete_generation(
            &storage,
            &conversation.id,
            &source_branch_id,
            None,
            "original",
            "original response",
        );
        let context = storage
            .prepare_message_generation_action(
                &conversation.id,
                &source_branch_id,
                Some(&original_assistant.id),
                &original_user.id,
                MessageGenerationAction::EditUser,
            )
            .expect("prepare edit");
        assert!(context.fork_message_id.is_none());
        assert_eq!(context.user_text, "original");

        let edited_user = Message::user(conversation.id.clone(), "edited");
        let action_generation_id = GenerationId::new();
        let pending = Message::pending_assistant(
            conversation.id.clone(),
            edited_user.id.clone(),
            action_generation_id.clone(),
        );
        let now = Utc::now();
        let action_branch = ConversationBranch {
            id: ConversationBranchId::new(),
            conversation_id: conversation.id.clone(),
            title: None,
            fork_message_id: None,
            head_message_id: Some(pending.id.clone()),
            created_at: now,
            updated_at: now,
        };
        let generation = GenerationRecord {
            id: action_generation_id,
            conversation_id: conversation.id.clone(),
            branch_id: action_branch.id.clone(),
            user_message_id: edited_user.id.clone(),
            assistant_message_id: Some(pending.id.clone()),
            mode: ConversationMode::Chat,
            model: "synthetic".to_owned(),
            status: GenerationStatus::Running,
            input_tokens: None,
            output_tokens: None,
            error_code: None,
            started_at: pending.created_at,
            finished_at: None,
        };
        storage
            .append_message_generation_action(
                &source_branch_id,
                Some(&original_assistant.id),
                &original_user.id,
                MessageGenerationAction::EditUser,
                &action_branch,
                &edited_user,
                &pending,
                &generation,
            )
            .expect("append edit branch");
        assert_eq!(
            storage
                .get_conversation_state(&conversation.id)
                .expect("state")
                .active_branch_id,
            action_branch.id
        );
        assert_eq!(
            storage
                .list_branch_messages(&source_branch_id)
                .expect("source lineage")
                .iter()
                .map(|message| message.content.as_str())
                .collect::<Vec<_>>(),
            ["original", "original response"]
        );

        let pending_error = storage
            .remove_message_from_branch(
                &conversation.id,
                &action_branch.id,
                Some(&pending.id),
                &pending.id,
            )
            .expect_err("pending branch must reject removal");
        assert_eq!(pending_error.code, CoreErrorCode::InvalidInput);
        assert!(pending_error.recoverable);

        let mut terminal = pending.clone();
        terminal.content = "edited response".to_owned();
        terminal.status = MessageStatus::Complete;
        storage
            .finalize_generation(&terminal, None, None, true)
            .expect("finalize edited response");
        let message_count = storage
            .list_messages(&conversation.id)
            .expect("all rows")
            .len();
        let rewound = storage
            .remove_message_from_branch(
                &conversation.id,
                &action_branch.id,
                Some(&terminal.id),
                &terminal.id,
            )
            .expect("rewind assistant");
        assert_eq!(rewound.head_message_id, Some(edited_user.id.clone()));
        assert_eq!(
            storage
                .list_branch_messages(&action_branch.id)
                .expect("rewound lineage"),
            vec![edited_user]
        );
        assert_eq!(
            storage
                .list_messages(&conversation.id)
                .expect("preserved rows")
                .len(),
            message_count,
            "logical removal must not delete immutable message rows"
        );

        let stale = storage
            .remove_message_from_branch(
                &conversation.id,
                &action_branch.id,
                Some(&terminal.id),
                &original_user.id,
            )
            .expect_err("stale head");
        assert_eq!(stale.code, CoreErrorCode::InvalidInput);
        assert!(stale.recoverable);
    }

    #[test]
    fn message_action_lineage_validation_is_deep_and_cycle_safe() {
        let (_root, storage, conversation, branch_id) = imported_storage();
        let (first_message_id, last_message_id) = {
            let mut connection = storage.connection().expect("connection");
            let transaction = connection.transaction().expect("transaction");
            let mut parent_id = None;
            let mut first_message_id = None;
            let mut last_message_id = None;
            for index in 0..4_105 {
                let message = Message::user_after(
                    conversation.id.clone(),
                    parent_id.clone(),
                    format!("message {index}"),
                );
                first_message_id.get_or_insert_with(|| message.id.clone());
                parent_id = Some(message.id.clone());
                last_message_id = Some(message.id.clone());
                insert_message(&transaction, &message).expect("insert deep message");
            }
            let last_message_id = last_message_id.expect("last message");
            transaction
                .execute(
                    "UPDATE conversation_branches
                     SET head_message_id = ?2
                     WHERE id = ?1",
                    params![branch_id.0, last_message_id.0],
                )
                .expect("update branch head");
            transaction.commit().expect("commit deep lineage");
            (first_message_id.expect("first message"), last_message_id)
        };

        let context = storage
            .prepare_message_generation_action(
                &conversation.id,
                &branch_id,
                Some(&last_message_id),
                &first_message_id,
                MessageGenerationAction::EditUser,
            )
            .expect("find a visible message beyond the former depth cutoff");
        assert!(context.fork_message_id.is_none());

        storage
            .connection()
            .expect("connection")
            .execute(
                "UPDATE messages
                 SET parent_id = ?2
                 WHERE conversation_id = ?1 AND id = ?3",
                params![conversation.id.0, last_message_id.0, first_message_id.0],
            )
            .expect("create synthetic corrupted cycle");
        let error = storage
            .prepare_message_generation_action(
                &conversation.id,
                &branch_id,
                Some(&last_message_id),
                &MessageId("missing-from-cycle".to_owned()),
                MessageGenerationAction::EditUser,
            )
            .expect_err("cycle-safe lookup must terminate");
        assert_eq!(error.code, CoreErrorCode::NotFound);
    }

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
        assert_eq!(reopened.schema_version(), 3);
    }

    #[test]
    fn version_two_equal_timestamps_preserve_generation_parent_lineage() {
        let root = tempdir().expect("temp root");
        let connection = version_two_database(root.path());
        for row in [
            (
                "z-user-1",
                None,
                "user",
                "first",
                "complete",
                None,
                "2026-01-01T00:00:01Z",
            ),
            (
                "a-assistant-1",
                Some("z-user-1"),
                "assistant",
                "one",
                "complete",
                Some("generation-1"),
                "2026-01-01T00:00:01Z",
            ),
            (
                "z-user-2",
                None,
                "user",
                "second",
                "complete",
                None,
                "2026-01-01T00:00:02Z",
            ),
            (
                "a-assistant-2",
                Some("z-user-2"),
                "assistant",
                "two",
                "complete",
                Some("generation-2"),
                "2026-01-01T00:00:02Z",
            ),
        ] {
            insert_legacy_message(&connection, row);
        }
        drop(connection);

        let storage = Storage::open(root.path()).expect("migrate legacy database");
        assert_eq!(storage.schema_version(), 3);
        let conversation_id = ConversationId("conversation".to_owned());
        let state = storage
            .get_conversation_state(&conversation_id)
            .expect("conversation state");
        assert_eq!(state.selected_mode, ConversationMode::Chat);
        let messages = storage
            .list_branch_messages(&state.active_branch_id)
            .expect("migrated lineage");
        assert_eq!(
            messages
                .iter()
                .map(|message| message.content.as_str())
                .collect::<Vec<_>>(),
            ["first", "one", "second", "two"]
        );
        assert_eq!(messages[0].parent_id, None);
        assert_eq!(messages[1].parent_id, Some(messages[0].id.clone()));
        assert_eq!(messages[2].parent_id, Some(messages[1].id.clone()));
        assert_eq!(messages[3].parent_id, Some(messages[2].id.clone()));
        assert_eq!(
            storage
                .get_generation(&GenerationId("generation-2".to_owned()))
                .expect("generation snapshot")
                .mode,
            ConversationMode::Chat
        );
        assert_eq!(
            storage
                .get_generation(&GenerationId("generation-1".to_owned()))
                .expect("first generation snapshot")
                .user_message_id,
            MessageId("z-user-1".to_owned())
        );
    }

    #[test]
    fn version_two_assistant_without_a_user_parent_is_rejected_before_migration() {
        let root = tempdir().expect("temp root");
        let connection = version_two_database(root.path());
        insert_legacy_message(
            &connection,
            (
                "assistant",
                None,
                "assistant",
                "orphan",
                "complete",
                Some("generation"),
                "2026-01-01T00:00:01Z",
            ),
        );
        drop(connection);

        let error = match Storage::open(root.path()) {
            Ok(_) => panic!("orphan assistant must be rejected"),
            Err(error) => error,
        };
        assert_eq!(error.code, CoreErrorCode::StorageCorrupted);

        let connection =
            Connection::open(root.path().join("db/lorepia.sqlite3")).expect("legacy database");
        assert_eq!(
            connection
                .query_row("SELECT MAX(version) FROM schema_migrations", [], |row| row
                    .get::<_, u32>(
                    0
                ))
                .expect("schema version"),
            2
        );
        assert_eq!(
            connection
                .query_row(
                    "SELECT COUNT(*) FROM sqlite_master
                     WHERE type = 'table' AND name = 'generations'",
                    [],
                    |row| row.get::<_, u32>(0)
                )
                .expect("generation table count"),
            0
        );
    }

    #[test]
    fn version_two_recovery_reparents_later_turns_around_discarded_partial_assistant() {
        let root = tempdir().expect("temp root");
        let connection = version_two_database(root.path());
        for row in [
            (
                "user-1",
                None,
                "user",
                "first",
                "complete",
                None,
                "2026-01-01T00:00:01Z",
            ),
            (
                "assistant-1",
                Some("user-1"),
                "assistant",
                "partial",
                "pending",
                Some("generation-1"),
                "2026-01-01T00:00:02Z",
            ),
            (
                "user-2",
                None,
                "user",
                "second",
                "complete",
                None,
                "2026-01-01T00:00:03Z",
            ),
            (
                "assistant-2",
                Some("user-2"),
                "assistant",
                "two",
                "complete",
                Some("generation-2"),
                "2026-01-01T00:00:04Z",
            ),
        ] {
            insert_legacy_message(&connection, row);
        }
        connection
            .execute(
                "INSERT INTO app_settings(key, value_json) VALUES ('application', ?1)",
                [serde_json::to_string(&AppSettings {
                    preserve_partial_generations: false,
                    selected_provider_profile_id: None,
                })
                .expect("settings JSON")],
            )
            .expect("discard-partial settings");
        drop(connection);

        for reopen_index in 0..2 {
            let storage = Storage::open(root.path()).expect("migrate and recover legacy database");
            assert_eq!(storage.schema_version(), 3);
            let state = storage
                .get_conversation_state(&ConversationId("conversation".to_owned()))
                .expect("conversation state");
            let messages = storage
                .list_branch_messages(&state.active_branch_id)
                .expect("recovered lineage");
            assert_eq!(
                messages
                    .iter()
                    .map(|message| message.content.as_str())
                    .collect::<Vec<_>>(),
                ["first", "second", "two"],
                "reopen {reopen_index} must preserve later completed turns"
            );
            assert_eq!(messages[0].parent_id, None);
            assert_eq!(messages[1].parent_id, Some(messages[0].id.clone()));
            assert_eq!(messages[2].parent_id, Some(messages[1].id.clone()));

            let discarded = storage
                .get_generation(&GenerationId("generation-1".to_owned()))
                .expect("discarded generation");
            assert_eq!(discarded.status, GenerationStatus::Cancelled);
            assert_eq!(discarded.assistant_message_id, None);
            assert_eq!(
                storage
                    .get_generation(&GenerationId("generation-2".to_owned()))
                    .expect("completed generation")
                    .status,
                GenerationStatus::Complete
            );
        }
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
