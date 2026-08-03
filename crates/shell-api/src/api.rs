use std::{fmt, path::Path};

use lorepia_core::{
    CORE_API_VERSION, ConnectionBoundCredential, ConversationBranchId, ConversationId,
    ConversationMode, Core, CoreConfig, CoreError, GenerationId, GenerationTarget, InspectionId,
    MessageId, ProviderConnectionId,
};
use serde::{Deserialize, Serialize};

use crate::{
    BootstrapDto, CharacterDto, ChatEventStream, ConversationBranchDto, ConversationDto,
    ConversationModeDto, ConversationStateDto, GenerationCredential, GenerationStartedDto,
    GenerationTargetDto, HealthDto, ImportInspectionDto, MessageActionGenerationDto, MessageDto,
    ShellError, ShellResult, StagedImportFile, sensitive::GenerationCredentialKind,
};

const MAX_IPC_IDENTIFIER_BYTES: usize = 512;
const MAX_IPC_IDENTIFIER_CHARS: usize = 256;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case", deny_unknown_fields)]
pub enum GenerationSelectionInput {
    LegacyProfile { provider_profile_id: String },
    Target { target: GenerationTargetDto },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SendMessageInput {
    pub conversation_id: String,
    pub branch_id: String,
    pub expected_head: Option<String>,
    pub mode: ConversationModeDto,
    pub text: String,
    pub selection: GenerationSelectionInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct EditUserMessageInput {
    pub conversation_id: String,
    pub branch_id: String,
    pub expected_head: Option<String>,
    pub message_id: String,
    pub replacement_text: String,
    pub selection: GenerationSelectionInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegenerateAssistantMessageInput {
    pub conversation_id: String,
    pub branch_id: String,
    pub expected_head: Option<String>,
    pub message_id: String,
    pub selection: GenerationSelectionInput,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoveMessageInput {
    pub conversation_id: String,
    pub branch_id: String,
    pub expected_head: Option<String>,
    pub message_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateConversationInput {
    pub character_id: String,
    pub title: String,
    pub mode: ConversationModeDto,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CreateConversationBranchInput {
    pub conversation_id: String,
    pub from_message_id: Option<String>,
    pub title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SelectConversationBranchInput {
    pub conversation_id: String,
    pub branch_id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SetConversationModeInput {
    pub conversation_id: String,
    pub mode: ConversationModeDto,
}

#[derive(Clone)]
pub struct ShellApi {
    pub(crate) core: Core,
}

impl ShellApi {
    pub fn open_data_root(data_root: impl AsRef<Path>) -> ShellResult<Self> {
        Self::open(CoreConfig::new(data_root.as_ref()))
    }

    pub fn open(config: CoreConfig) -> ShellResult<Self> {
        Core::open(config)
            .map(Self::from_core)
            .map_err(ShellError::from)
    }

    pub const fn from_core(core: Core) -> Self {
        Self { core }
    }

    pub fn bootstrap(&self) -> ShellResult<BootstrapDto> {
        let health = self.core.health_check().map_err(ShellError::from)?;
        Ok(BootstrapDto {
            core_api_version: CORE_API_VERSION,
            chat_event_version: lorepia_core::CHAT_EVENT_VERSION,
            health: HealthDto::from(health),
        })
    }

    pub fn list_characters(&self) -> ShellResult<Vec<CharacterDto>> {
        self.core
            .list_characters()
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(ShellError::from)
    }

    pub fn get_character(&self, character_id: &str) -> ShellResult<CharacterDto> {
        validate_identifier("character_id", character_id)?;
        self.core
            .get_character(character_id)
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn inspect_import(
        &self,
        staged_file: &StagedImportFile,
    ) -> ShellResult<ImportInspectionDto> {
        self.core
            .inspect_import(staged_file.as_path())
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn commit_import(&self, inspection_id: &str) -> ShellResult<CharacterDto> {
        validate_identifier("inspection_id", inspection_id)?;
        self.core
            .commit_import(&InspectionId(inspection_id.to_owned()))
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn discard_import(&self, inspection_id: &str) -> ShellResult<()> {
        validate_identifier("inspection_id", inspection_id)?;
        self.core
            .discard_import(&InspectionId(inspection_id.to_owned()))
            .map_err(ShellError::from)
    }

    pub fn open_conversation(&self, character_id: &str) -> ShellResult<ConversationDto> {
        validate_identifier("character_id", character_id)?;
        self.core
            .open_conversation(character_id)
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn create_conversation(
        &self,
        input: CreateConversationInput,
    ) -> ShellResult<ConversationDto> {
        validate_identifier("character_id", &input.character_id)?;
        self.core
            .create_conversation(
                &input.character_id,
                input.title,
                ConversationMode::from(input.mode),
            )
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn list_conversations(&self) -> ShellResult<Vec<ConversationDto>> {
        self.core
            .list_conversations()
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(ShellError::from)
    }

    pub fn list_conversations_for_character(
        &self,
        character_id: &str,
    ) -> ShellResult<Vec<ConversationDto>> {
        validate_identifier("character_id", character_id)?;
        self.core
            .list_conversations_for_character(character_id)
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(ShellError::from)
    }

    pub fn get_conversation(&self, conversation_id: &str) -> ShellResult<ConversationDto> {
        validate_identifier("conversation_id", conversation_id)?;
        self.core
            .get_conversation(&ConversationId(conversation_id.to_owned()))
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn get_conversation_state(
        &self,
        conversation_id: &str,
    ) -> ShellResult<ConversationStateDto> {
        validate_identifier("conversation_id", conversation_id)?;
        self.core
            .get_conversation_state(&ConversationId(conversation_id.to_owned()))
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn list_conversation_branches(
        &self,
        conversation_id: &str,
    ) -> ShellResult<Vec<ConversationBranchDto>> {
        validate_identifier("conversation_id", conversation_id)?;
        self.core
            .list_conversation_branches(&ConversationId(conversation_id.to_owned()))
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(ShellError::from)
    }

    pub fn create_conversation_branch(
        &self,
        input: CreateConversationBranchInput,
    ) -> ShellResult<ConversationBranchDto> {
        validate_identifier("conversation_id", &input.conversation_id)?;
        validate_optional_identifier("from_message_id", input.from_message_id.as_deref())?;
        let from_message_id = input.from_message_id.map(MessageId);
        self.core
            .create_conversation_branch(
                &ConversationId(input.conversation_id),
                from_message_id.as_ref(),
                input.title,
            )
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn select_conversation_branch(
        &self,
        input: SelectConversationBranchInput,
    ) -> ShellResult<ConversationStateDto> {
        validate_identifier("conversation_id", &input.conversation_id)?;
        validate_identifier("branch_id", &input.branch_id)?;
        self.core
            .select_conversation_branch(
                &ConversationId(input.conversation_id),
                &ConversationBranchId(input.branch_id),
            )
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn set_conversation_mode(
        &self,
        input: SetConversationModeInput,
    ) -> ShellResult<ConversationStateDto> {
        validate_identifier("conversation_id", &input.conversation_id)?;
        self.core
            .set_conversation_mode(
                &ConversationId(input.conversation_id),
                ConversationMode::from(input.mode),
            )
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn list_branch_messages(&self, branch_id: &str) -> ShellResult<Vec<MessageDto>> {
        validate_identifier("branch_id", branch_id)?;
        self.core
            .list_branch_messages(&ConversationBranchId(branch_id.to_owned()))
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(ShellError::from)
    }

    pub fn list_messages(&self, conversation_id: &str) -> ShellResult<Vec<MessageDto>> {
        validate_identifier("conversation_id", conversation_id)?;
        self.core
            .list_messages(&ConversationId(conversation_id.to_owned()))
            .map(|values| values.into_iter().map(Into::into).collect())
            .map_err(ShellError::from)
    }

    pub fn send_message_to_branch(
        &self,
        input: SendMessageInput,
        credential: GenerationCredential,
    ) -> ShellResult<StartedGeneration> {
        validate_chat_route(
            &input.conversation_id,
            &input.branch_id,
            input.expected_head.as_deref(),
        )?;
        validate_selection(&input.selection)?;
        let receiver = self.core.subscribe_events();
        let expected_head = input.expected_head.map(MessageId);
        let generation_id = match (input.selection, credential.into_kind()) {
            (
                GenerationSelectionInput::LegacyProfile {
                    provider_profile_id,
                },
                GenerationCredentialKind::Legacy(credential),
            ) => self.core.send_message_to_branch(
                &ConversationId(input.conversation_id.clone()),
                &ConversationBranchId(input.branch_id.clone()),
                expected_head.as_ref(),
                input.mode.into(),
                &input.text,
                &provider_profile_id,
                credential.map(crate::SecretCredential::into_core_value),
            ),
            (
                GenerationSelectionInput::Target { target },
                GenerationCredentialKind::Connection {
                    connection_id,
                    credential,
                },
            ) => {
                validate_identifier("connection_id", &connection_id)?;
                let target = GenerationTarget::from(target);
                self.core.send_message_to_branch_with_connection_credential(
                    &ConversationId(input.conversation_id.clone()),
                    &ConversationBranchId(input.branch_id.clone()),
                    expected_head.as_ref(),
                    input.mode.into(),
                    &input.text,
                    &target,
                    ConnectionBoundCredential::new(
                        ProviderConnectionId::from(connection_id),
                        credential.map(crate::SecretCredential::into_core_value),
                    ),
                )
            }
            _ => {
                return Err(ShellError::from(CoreError::invalid(
                    "credential context does not match the generation selection",
                )));
            }
        }
        .map_err(ShellError::from)?;
        Ok(StartedGeneration::new(
            generation_id,
            receiver,
            input.conversation_id,
            input.branch_id,
        ))
    }

    pub fn edit_user_message(
        &self,
        input: EditUserMessageInput,
        credential: GenerationCredential,
    ) -> ShellResult<StartedMessageAction> {
        validate_chat_route(
            &input.conversation_id,
            &input.branch_id,
            input.expected_head.as_deref(),
        )?;
        validate_identifier("message_id", &input.message_id)?;
        validate_selection(&input.selection)?;
        let receiver = self.core.subscribe_events();
        let expected_head = input.expected_head.map(MessageId);
        let action = match (input.selection, credential.into_kind()) {
            (
                GenerationSelectionInput::LegacyProfile {
                    provider_profile_id,
                },
                GenerationCredentialKind::Legacy(credential),
            ) => self.core.edit_user_message(
                &ConversationId(input.conversation_id.clone()),
                &ConversationBranchId(input.branch_id),
                expected_head.as_ref(),
                &MessageId(input.message_id),
                &input.replacement_text,
                &provider_profile_id,
                credential.map(crate::SecretCredential::into_core_value),
            ),
            (
                GenerationSelectionInput::Target { target },
                GenerationCredentialKind::Connection {
                    connection_id,
                    credential,
                },
            ) => {
                validate_identifier("connection_id", &connection_id)?;
                let target = GenerationTarget::from(target);
                self.core.edit_user_message_with_connection_credential(
                    &ConversationId(input.conversation_id.clone()),
                    &ConversationBranchId(input.branch_id),
                    expected_head.as_ref(),
                    &MessageId(input.message_id),
                    &input.replacement_text,
                    &target,
                    ConnectionBoundCredential::new(
                        ProviderConnectionId::from(connection_id),
                        credential.map(crate::SecretCredential::into_core_value),
                    ),
                )
            }
            _ => {
                return Err(ShellError::from(CoreError::invalid(
                    "credential context does not match the generation selection",
                )));
            }
        }
        .map_err(ShellError::from)?;
        Ok(StartedMessageAction::new(
            action,
            receiver,
            input.conversation_id,
        ))
    }

    pub fn regenerate_assistant_message(
        &self,
        input: RegenerateAssistantMessageInput,
        credential: GenerationCredential,
    ) -> ShellResult<StartedMessageAction> {
        validate_chat_route(
            &input.conversation_id,
            &input.branch_id,
            input.expected_head.as_deref(),
        )?;
        validate_identifier("message_id", &input.message_id)?;
        validate_selection(&input.selection)?;
        let receiver = self.core.subscribe_events();
        let expected_head = input.expected_head.map(MessageId);
        let action = match (input.selection, credential.into_kind()) {
            (
                GenerationSelectionInput::LegacyProfile {
                    provider_profile_id,
                },
                GenerationCredentialKind::Legacy(credential),
            ) => self.core.regenerate_assistant_message(
                &ConversationId(input.conversation_id.clone()),
                &ConversationBranchId(input.branch_id),
                expected_head.as_ref(),
                &MessageId(input.message_id),
                &provider_profile_id,
                credential.map(crate::SecretCredential::into_core_value),
            ),
            (
                GenerationSelectionInput::Target { target },
                GenerationCredentialKind::Connection {
                    connection_id,
                    credential,
                },
            ) => {
                validate_identifier("connection_id", &connection_id)?;
                let target = GenerationTarget::from(target);
                self.core
                    .regenerate_assistant_message_with_connection_credential(
                        &ConversationId(input.conversation_id.clone()),
                        &ConversationBranchId(input.branch_id),
                        expected_head.as_ref(),
                        &MessageId(input.message_id),
                        &target,
                        ConnectionBoundCredential::new(
                            ProviderConnectionId::from(connection_id),
                            credential.map(crate::SecretCredential::into_core_value),
                        ),
                    )
            }
            _ => {
                return Err(ShellError::from(CoreError::invalid(
                    "credential context does not match the generation selection",
                )));
            }
        }
        .map_err(ShellError::from)?;
        Ok(StartedMessageAction::new(
            action,
            receiver,
            input.conversation_id,
        ))
    }

    pub fn remove_message_from_branch(
        &self,
        input: RemoveMessageInput,
    ) -> ShellResult<ConversationBranchDto> {
        validate_chat_route(
            &input.conversation_id,
            &input.branch_id,
            input.expected_head.as_deref(),
        )?;
        validate_identifier("message_id", &input.message_id)?;
        let expected_head = input.expected_head.map(MessageId);
        self.core
            .remove_message_from_branch(
                &ConversationId(input.conversation_id),
                &ConversationBranchId(input.branch_id),
                expected_head.as_ref(),
                &MessageId(input.message_id),
            )
            .map(Into::into)
            .map_err(ShellError::from)
    }

    pub fn cancel_generation(&self, generation_id: &str) -> ShellResult<()> {
        validate_identifier("generation_id", generation_id)?;
        self.core
            .cancel_generation(&GenerationId(generation_id.to_owned()))
            .map_err(ShellError::from)
    }
}

impl fmt::Debug for ShellApi {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("ShellApi { core: [OPAQUE] }")
    }
}

pub struct StartedGeneration {
    response: GenerationStartedDto,
    stream: ChatEventStream,
}

impl StartedGeneration {
    fn new(
        generation_id: GenerationId,
        receiver: tokio::sync::broadcast::Receiver<lorepia_core::ChatEvent>,
        conversation_id: String,
        branch_id: String,
    ) -> Self {
        let generation_id = generation_id.0;
        Self {
            response: GenerationStartedDto {
                generation_id: generation_id.clone(),
            },
            stream: ChatEventStream::new(receiver, generation_id, conversation_id, branch_id),
        }
    }

    pub fn response(&self) -> &GenerationStartedDto {
        &self.response
    }

    pub fn into_parts(self) -> (GenerationStartedDto, ChatEventStream) {
        (self.response, self.stream)
    }
}

impl fmt::Debug for StartedGeneration {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StartedGeneration")
            .field("response", &self.response)
            .field("stream", &self.stream)
            .finish()
    }
}

pub struct StartedMessageAction {
    response: MessageActionGenerationDto,
    stream: ChatEventStream,
}

impl StartedMessageAction {
    fn new(
        action: lorepia_core::MessageActionGeneration,
        receiver: tokio::sync::broadcast::Receiver<lorepia_core::ChatEvent>,
        conversation_id: String,
    ) -> Self {
        let generation_id = action.generation_id.0.clone();
        let branch_id = action.branch.id.0.clone();
        Self {
            response: action.into(),
            stream: ChatEventStream::new(receiver, generation_id, conversation_id, branch_id),
        }
    }

    pub fn response(&self) -> &MessageActionGenerationDto {
        &self.response
    }

    pub fn into_parts(self) -> (MessageActionGenerationDto, ChatEventStream) {
        (self.response, self.stream)
    }
}

impl fmt::Debug for StartedMessageAction {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("StartedMessageAction")
            .field("response", &self.response)
            .field("stream", &self.stream)
            .finish()
    }
}

fn validate_chat_route(
    conversation_id: &str,
    branch_id: &str,
    expected_head: Option<&str>,
) -> ShellResult<()> {
    validate_identifier("conversation_id", conversation_id)?;
    validate_identifier("branch_id", branch_id)?;
    validate_optional_identifier("expected_head", expected_head)
}

fn validate_selection(selection: &GenerationSelectionInput) -> ShellResult<()> {
    match selection {
        GenerationSelectionInput::LegacyProfile {
            provider_profile_id,
        } => validate_identifier("provider_profile_id", provider_profile_id),
        GenerationSelectionInput::Target { target } => {
            validate_identifier("model_route_id", &target.model_route_id)?;
            validate_identifier("generation_preset_id", &target.generation_preset_id)
        }
    }
}

fn validate_optional_identifier(field: &str, value: Option<&str>) -> ShellResult<()> {
    value.map_or(Ok(()), |value| validate_identifier(field, value))
}

pub(crate) fn validate_identifier(field: &str, value: &str) -> ShellResult<()> {
    if value.is_empty()
        || value.len() > MAX_IPC_IDENTIFIER_BYTES
        || value.chars().count() > MAX_IPC_IDENTIFIER_CHARS
        || value.chars().any(char::is_control)
    {
        return Err(ShellError::from(CoreError::invalid(format!(
            "{field} is not a bounded identifier"
        ))));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        thread,
        time::Duration,
    };

    use lorepia_core::{Core, CoreConfig, ProviderProfile};
    use tempfile::{NamedTempFile, tempdir};

    use crate::{
        ChatStreamItem, CreateConversationInput, EditUserMessageInput, GenerationCredential,
        GenerationSelectionInput, GenerationTargetDto, RegenerateAssistantMessageInput,
        RemoveMessageInput, SecretCredential, SendMessageInput, ShellApi, ShellErrorCode,
        StagedImportFile, dto::ConversationModeDto,
    };

    const LIVE_CREDENTIAL_CANARY: &str = "sk-shell-live-canary";

    fn imported_shell() -> (tempfile::TempDir, ShellApi, String) {
        let root = tempdir().expect("temporary data root");
        let shell = ShellApi::open(CoreConfig::new(root.path())).expect("open shell");
        let mut source = NamedTempFile::new().expect("temporary source");
        write!(
            source,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Shell","description":"Synthetic"}}}}"#
        )
        .expect("write source");
        let inspection = shell
            .inspect_import(&StagedImportFile::new(source.path()))
            .expect("inspect");
        let character = shell
            .commit_import(&inspection.inspection_id)
            .expect("commit");
        (root, shell, character.id)
    }

    #[test]
    fn bootstrap_and_library_projection_never_expose_data_root() {
        let (root, shell, character_id) = imported_shell();
        let bootstrap = shell.bootstrap().expect("bootstrap");
        let characters = shell.list_characters().expect("characters");
        let json = serde_json::to_string(&(bootstrap, characters)).expect("serialize");

        assert!(!json.contains(root.path().to_string_lossy().as_ref()));
        assert!(json.contains(&character_id));
    }

    #[test]
    fn conversation_collections_remain_whole_vec_mappings() {
        let (_root, shell, character_id) = imported_shell();
        let first = shell
            .create_conversation(CreateConversationInput {
                character_id: character_id.clone(),
                title: "First".into(),
                mode: ConversationModeDto::Chat,
            })
            .expect("first conversation");
        shell
            .create_conversation(CreateConversationInput {
                character_id: character_id.clone(),
                title: "Second".into(),
                mode: ConversationModeDto::Story,
            })
            .expect("second conversation");

        let all = shell.list_conversations().expect("all conversations");
        let filtered = shell
            .list_conversations_for_character(&character_id)
            .expect("filtered conversations");
        assert_eq!(all.len(), 2);
        assert_eq!(filtered.len(), 2);
        assert!(shell.list_messages(&first.id).expect("messages").is_empty());
    }

    #[test]
    fn remove_message_passes_expected_head_instead_of_inventing_a_revision() {
        let (_root, shell, character_id) = imported_shell();
        let conversation = shell
            .open_conversation(&character_id)
            .expect("conversation");
        let state = shell
            .get_conversation_state(&conversation.id)
            .expect("state");

        let error = shell
            .remove_message_from_branch(RemoveMessageInput {
                conversation_id: conversation.id,
                branch_id: state.active_branch_id,
                expected_head: Some("stale-head".into()),
                message_id: "missing-message".into(),
            })
            .expect_err("stale head must fail");

        assert_eq!(error.code, ShellErrorCode::InvalidInput);
    }

    #[test]
    fn target_selection_rejects_unbound_legacy_credential_context() {
        let (_root, shell, character_id) = imported_shell();
        let conversation = shell
            .open_conversation(&character_id)
            .expect("conversation");
        let state = shell
            .get_conversation_state(&conversation.id)
            .expect("conversation state");

        let error = shell
            .send_message_to_branch(
                SendMessageInput {
                    conversation_id: conversation.id,
                    branch_id: state.active_branch_id.clone(),
                    expected_head: None,
                    mode: ConversationModeDto::Chat,
                    text: "must not be stored".to_owned(),
                    selection: GenerationSelectionInput::Target {
                        target: GenerationTargetDto {
                            model_route_id: "synthetic-route".to_owned(),
                            generation_preset_id: "synthetic-preset".to_owned(),
                        },
                    },
                },
                GenerationCredential::legacy(Some(SecretCredential::new(
                    "synthetic-unbound-credential",
                ))),
            )
            .expect_err("target selection must reject an unbound credential");

        assert_eq!(error.code, ShellErrorCode::InvalidInput);
        assert!(
            shell
                .list_branch_messages(&state.active_branch_id)
                .expect("messages after rejected credential context")
                .is_empty()
        );
    }

    #[tokio::test]
    #[allow(
        clippy::too_many_lines,
        reason = "one vertical-slice test keeps the complete immutable-branch action sequence visible"
    )]
    async fn synthetic_core_stream_exercises_send_edit_regenerate_and_remove() {
        let root = tempdir().expect("temporary data root");
        let core = Core::open(CoreConfig::new(root.path())).expect("open core");
        let (base_url, provider_thread) = spawn_completed_provider(3);
        core.upsert_provider_profile(ProviderProfile {
            id: "synthetic-profile".into(),
            display_name: "Synthetic".into(),
            base_url,
            model: "synthetic-model".into(),
            timeout_seconds: 5,
        })
        .expect("save provider");
        let shell = ShellApi::from_core(core);
        let mut source = NamedTempFile::new().expect("temporary source");
        write!(
            source,
            r#"{{"spec":"chara_card_v3","data":{{"name":"Chat","description":"Synthetic"}}}}"#
        )
        .expect("write source");
        let inspection = shell
            .inspect_import(&StagedImportFile::new(source.path()))
            .expect("inspect");
        let character = shell
            .commit_import(&inspection.inspection_id)
            .expect("commit");
        let conversation = shell
            .open_conversation(&character.id)
            .expect("conversation");
        let state = shell
            .get_conversation_state(&conversation.id)
            .expect("state");

        let started = shell
            .send_message_to_branch(
                SendMessageInput {
                    conversation_id: conversation.id.clone(),
                    branch_id: state.active_branch_id.clone(),
                    expected_head: None,
                    mode: ConversationModeDto::Chat,
                    text: "first".into(),
                    selection: synthetic_profile_selection(),
                },
                GenerationCredential::legacy(Some(SecretCredential::new(LIVE_CREDENTIAL_CANARY))),
            )
            .expect("send");
        let (started_response, stream) = started.into_parts();
        assert_stream_finishes(stream, &started_response.generation_id).await;

        let messages = shell
            .list_branch_messages(&state.active_branch_id)
            .expect("first messages");
        assert_eq!(messages.len(), 2);
        let first_user = &messages[0];
        let first_assistant = &messages[1];

        let edit = shell
            .edit_user_message(
                EditUserMessageInput {
                    conversation_id: conversation.id.clone(),
                    branch_id: state.active_branch_id,
                    expected_head: Some(first_assistant.id.clone()),
                    message_id: first_user.id.clone(),
                    replacement_text: "edited".into(),
                    selection: synthetic_profile_selection(),
                },
                GenerationCredential::legacy(None),
            )
            .expect("edit");
        let (edit_response, stream) = edit.into_parts();
        assert_stream_finishes(stream, &edit_response.generation_id).await;

        let edited_messages = shell
            .list_branch_messages(&edit_response.branch.id)
            .expect("edited messages");
        assert_eq!(edited_messages.len(), 2);
        assert_eq!(edited_messages[0].content, "edited");
        let edited_assistant = &edited_messages[1];

        let regenerate = shell
            .regenerate_assistant_message(
                RegenerateAssistantMessageInput {
                    conversation_id: conversation.id.clone(),
                    branch_id: edit_response.branch.id,
                    expected_head: Some(edited_assistant.id.clone()),
                    message_id: edited_assistant.id.clone(),
                    selection: synthetic_profile_selection(),
                },
                GenerationCredential::legacy(None),
            )
            .expect("regenerate");
        let (regenerate_response, stream) = regenerate.into_parts();
        assert_stream_finishes(stream, &regenerate_response.generation_id).await;

        let regenerated_messages = shell
            .list_branch_messages(&regenerate_response.branch.id)
            .expect("regenerated messages");
        let regenerated_assistant = regenerated_messages.last().expect("assistant");
        let shortened = shell
            .remove_message_from_branch(RemoveMessageInput {
                conversation_id: conversation.id,
                branch_id: regenerate_response.branch.id,
                expected_head: Some(regenerated_assistant.id.clone()),
                message_id: regenerated_assistant.id.clone(),
            })
            .expect("remove");
        assert_eq!(
            shortened.head_message_id.as_deref(),
            regenerated_assistant.parent_id.as_deref()
        );

        provider_thread.join().expect("provider thread");
    }

    fn synthetic_profile_selection() -> GenerationSelectionInput {
        GenerationSelectionInput::LegacyProfile {
            provider_profile_id: "synthetic-profile".into(),
        }
    }

    async fn assert_stream_finishes(
        mut stream: crate::ChatEventStream,
        expected_generation_id: &str,
    ) {
        let mut last_sequence = 0;
        loop {
            let item = tokio::time::timeout(Duration::from_secs(5), stream.recv())
                .await
                .expect("stream timeout");
            match item {
                ChatStreamItem::Event(event) => {
                    assert_eq!(event.generation_id, expected_generation_id);
                    assert!(event.sequence > last_sequence);
                    assert!(
                        !serde_json::to_string(&event)
                            .expect("serialize event")
                            .contains(LIVE_CREDENTIAL_CANARY)
                    );
                    last_sequence = event.sequence;
                    if matches!(event.kind, crate::ChatEventKindDto::GenerationFinished) {
                        break;
                    }
                }
                ChatStreamItem::ReconciliationRequired(required) => {
                    panic!("unexpected reconciliation: {required:?}");
                }
                ChatStreamItem::Closed => panic!("stream closed before terminal event"),
            }
        }
    }

    fn spawn_completed_provider(request_count: usize) -> (String, thread::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind provider");
        let address = listener.local_addr().expect("provider address");
        let handle = thread::spawn(move || {
            for _ in 0..request_count {
                let (mut stream, _) = listener.accept().expect("accept provider request");
                read_request(&mut stream);
                let body = concat!(
                    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"reply\"}}]}\n\n",
                    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n",
                    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2}}\n\n",
                    "data: [DONE]\n\n"
                );
                write!(
                    stream,
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                )
                .expect("write provider response");
            }
        });
        (format!("http://{address}/v1"), handle)
    }

    fn read_request(stream: &mut TcpStream) {
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .expect("request timeout");
        let mut request = Vec::new();
        let mut buffer = [0_u8; 4_096];
        loop {
            let read = stream.read(&mut buffer).expect("read request");
            if read == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..read]);
            let Some(header_end) = request.windows(4).position(|value| value == b"\r\n\r\n") else {
                continue;
            };
            let headers = String::from_utf8_lossy(&request[..header_end]);
            let content_length = headers
                .lines()
                .find_map(|line| {
                    let (name, value) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| value.trim().parse::<usize>().ok())
                        .flatten()
                })
                .unwrap_or(0);
            if request.len() >= header_end + 4 + content_length {
                break;
            }
        }
    }
}
