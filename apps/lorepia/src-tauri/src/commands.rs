use lorepia_shell_api::{
    BootstrapDto, CharacterDto, ChatStreamItem, ConversationBranchDto, ConversationDto,
    ConversationStateDto, CreateConversationBranchInput, CreateConversationInput,
    EditUserMessageInput, GenerationCredential, GenerationPresetDto, GenerationSelectionInput,
    GenerationStartedDto, ImportInspectionDto, MessageActionGenerationDto, MessageDto,
    ModelRouteDto, RegenerateAssistantMessageInput, RemoveMessageInput, RequestPreviewDto,
    SecretCredential, SelectConversationBranchInput, SendMessageInput, SetConversationModeInput,
    StagedImportFile,
};
use tauri::{AppHandle, State, ipc::Channel};
use tauri_plugin_lorepia_platform::{LorepiaPlatformExt, NativeCredential};
use uuid::Uuid;

use crate::{
    channels::forward_chat_stream,
    contract::{
        BranchMessagesRequest, CharacterConversationsRequest, CharacterRequest, ChatStreamRequest,
        CredentialStatusDto, CredentialStatusRequest, CredentialTarget, DiscardImportRequest,
        GenerationPresetsRequest, GenerationRequest, ImportTicketDto, InspectionRequest,
        ModelRoutesRequest, PreviewProviderRequest, ProviderOverviewDto, StoreCredentialRequest,
        SubscribeGenerationRequest, TicketRequest,
    },
    error::{CommandError, CommandResult},
    state::{AppState, reject_generation_reattachment},
};

#[tauri::command]
pub fn bootstrap(state: State<'_, AppState>) -> CommandResult<BootstrapDto> {
    state.bootstrap()
}

#[tauri::command]
pub fn list_characters(state: State<'_, AppState>) -> CommandResult<Vec<CharacterDto>> {
    state.shell()?.list_characters().map_err(Into::into)
}

#[tauri::command]
pub fn get_character(
    state: State<'_, AppState>,
    request: CharacterRequest,
) -> CommandResult<CharacterDto> {
    state
        .shell()?
        .get_character(&request.character_id)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn pick_import(
    app: AppHandle,
    state: State<'_, AppState>,
) -> CommandResult<Option<ImportTicketDto>> {
    let Some(staged) = app.lorepia_platform().pick_import().await? else {
        return Ok(None);
    };
    let ticket_id = Uuid::new_v4().to_string();
    let response = ImportTicketDto {
        ticket_id: ticket_id.clone(),
        display_name: staged.display_name().to_owned(),
        size_bytes: staged.size_bytes(),
    };
    state.insert_import_ticket(ticket_id, staged)?;
    Ok(Some(response))
}

#[tauri::command]
pub async fn inspect_import(
    app: AppHandle,
    state: State<'_, AppState>,
    request: TicketRequest,
) -> CommandResult<ImportInspectionDto> {
    let staged = state.take_import_ticket(&request.ticket_id)?;
    let shell = state.shell()?;
    let inspection = shell
        .inspect_import(&StagedImportFile::new(staged.path()))
        .map_err(CommandError::from);
    let cleanup = app
        .lorepia_platform()
        .discard_staged_import(&staged)
        .await
        .map_err(CommandError::from);

    match (inspection, cleanup) {
        (Ok(inspection), Ok(())) => Ok(inspection),
        (Ok(inspection), Err(cleanup_error)) => {
            let _ = shell.discard_import(&inspection.inspection_id);
            Err(cleanup_error)
        }
        (Err(error), _) => Err(error),
    }
}

#[tauri::command]
pub fn commit_import(
    state: State<'_, AppState>,
    request: InspectionRequest,
) -> CommandResult<CharacterDto> {
    state
        .shell()?
        .commit_import(&request.inspection_id)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn discard_import(
    app: AppHandle,
    state: State<'_, AppState>,
    request: DiscardImportRequest,
) -> CommandResult<()> {
    match request {
        DiscardImportRequest::Inspection { inspection_id } => state
            .shell()?
            .discard_import(&inspection_id)
            .map_err(Into::into),
        DiscardImportRequest::Ticket { ticket_id } => {
            let reservation = state.reserve_import_ticket(&ticket_id)?;
            match app
                .lorepia_platform()
                .discard_staged_import(reservation.value())
                .await
            {
                Ok(()) => reservation.complete(),
                Err(error) => Err(error.into()),
            }
        }
    }
}

#[tauri::command]
pub fn create_conversation(
    state: State<'_, AppState>,
    input: CreateConversationInput,
) -> CommandResult<ConversationDto> {
    state
        .shell()?
        .create_conversation(input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn open_conversation(
    state: State<'_, AppState>,
    request: CharacterRequest,
) -> CommandResult<ConversationDto> {
    state
        .shell()?
        .open_conversation(&request.character_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_conversations(state: State<'_, AppState>) -> CommandResult<Vec<ConversationDto>> {
    state.shell()?.list_conversations().map_err(Into::into)
}

#[tauri::command]
pub fn list_conversations_for_character(
    state: State<'_, AppState>,
    request: CharacterConversationsRequest,
) -> CommandResult<Vec<ConversationDto>> {
    state
        .shell()?
        .list_conversations_for_character(&request.character_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn get_conversation(
    state: State<'_, AppState>,
    request: crate::contract::ConversationRequest,
) -> CommandResult<ConversationDto> {
    state
        .shell()?
        .get_conversation(&request.conversation_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn get_conversation_state(
    state: State<'_, AppState>,
    request: crate::contract::ConversationRequest,
) -> CommandResult<ConversationStateDto> {
    state
        .shell()?
        .get_conversation_state(&request.conversation_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_branches(
    state: State<'_, AppState>,
    request: crate::contract::ConversationRequest,
) -> CommandResult<Vec<ConversationBranchDto>> {
    state
        .shell()?
        .list_conversation_branches(&request.conversation_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn create_branch(
    state: State<'_, AppState>,
    input: CreateConversationBranchInput,
) -> CommandResult<ConversationBranchDto> {
    state
        .shell()?
        .create_conversation_branch(input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn select_branch(
    state: State<'_, AppState>,
    input: SelectConversationBranchInput,
) -> CommandResult<ConversationStateDto> {
    state
        .shell()?
        .select_conversation_branch(input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn set_conversation_mode(
    state: State<'_, AppState>,
    input: SetConversationModeInput,
) -> CommandResult<ConversationStateDto> {
    state
        .shell()?
        .set_conversation_mode(input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_branch_messages(
    state: State<'_, AppState>,
    request: BranchMessagesRequest,
) -> CommandResult<Vec<MessageDto>> {
    state
        .shell()?
        .list_branch_messages(&request.branch_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_messages(
    state: State<'_, AppState>,
    request: crate::contract::ConversationRequest,
) -> CommandResult<Vec<MessageDto>> {
    state
        .shell()?
        .list_messages(&request.conversation_id)
        .map_err(Into::into)
}

#[tauri::command]
pub async fn send_message(
    app: AppHandle,
    state: State<'_, AppState>,
    input: SendMessageInput,
    stream_id: String,
    on_event: Channel<ChatStreamItem>,
) -> CommandResult<GenerationStartedDto> {
    let registration = state.register_chat_stream(&stream_id)?;
    let shell = state.shell()?;
    let credential = credential_for_selection(&app, &shell, &input.selection).await?;
    let started = shell.send_message_to_branch(input, credential)?;
    let (response, stream) = started.into_parts();
    forward_chat_stream(stream, on_event, registration);
    Ok(response)
}

#[tauri::command]
pub async fn edit_user_message(
    app: AppHandle,
    state: State<'_, AppState>,
    input: EditUserMessageInput,
    stream_id: String,
    on_event: Channel<ChatStreamItem>,
) -> CommandResult<MessageActionGenerationDto> {
    let registration = state.register_chat_stream(&stream_id)?;
    let shell = state.shell()?;
    let credential = credential_for_selection(&app, &shell, &input.selection).await?;
    let started = shell.edit_user_message(input, credential)?;
    let (response, stream) = started.into_parts();
    forward_chat_stream(stream, on_event, registration);
    Ok(response)
}

#[tauri::command]
pub async fn regenerate_assistant_message(
    app: AppHandle,
    state: State<'_, AppState>,
    input: RegenerateAssistantMessageInput,
    stream_id: String,
    on_event: Channel<ChatStreamItem>,
) -> CommandResult<MessageActionGenerationDto> {
    let registration = state.register_chat_stream(&stream_id)?;
    let shell = state.shell()?;
    let credential = credential_for_selection(&app, &shell, &input.selection).await?;
    let started = shell.regenerate_assistant_message(input, credential)?;
    let (response, stream) = started.into_parts();
    forward_chat_stream(stream, on_event, registration);
    Ok(response)
}

#[tauri::command]
pub fn remove_message_from_branch(
    state: State<'_, AppState>,
    input: RemoveMessageInput,
) -> CommandResult<ConversationBranchDto> {
    state
        .shell()?
        .remove_message_from_branch(input)
        .map_err(Into::into)
}

#[tauri::command]
pub fn cancel_generation(
    state: State<'_, AppState>,
    request: GenerationRequest,
) -> CommandResult<()> {
    state
        .shell()?
        .cancel_generation(&request.generation_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn subscribe_generation(
    request: SubscribeGenerationRequest,
    stream_id: String,
    on_event: Channel<ChatStreamItem>,
) -> CommandResult<()> {
    let _ = (request, stream_id, on_event);
    reject_generation_reattachment()
}

#[tauri::command]
pub fn dispose_chat_stream(
    state: State<'_, AppState>,
    request: ChatStreamRequest,
) -> CommandResult<bool> {
    state.dispose_chat_stream(&request.stream_id)
}

#[tauri::command]
pub async fn credential_status(
    app: AppHandle,
    state: State<'_, AppState>,
    request: CredentialStatusRequest,
) -> CommandResult<CredentialStatusDto> {
    let shell = state.shell()?;
    let reference = credential_target_reference(&shell, &request.target)?;
    let status = app.lorepia_platform().credential_status(&reference).await?;
    Ok(CredentialStatusDto { status })
}

#[tauri::command]
pub async fn set_credential(
    app: AppHandle,
    state: State<'_, AppState>,
    request: StoreCredentialRequest,
) -> CommandResult<()> {
    let shell = state.shell()?;
    let reference = credential_target_reference(&shell, &request.target)?;
    app.lorepia_platform()
        .store_credential(&reference, NativeCredential::new(request.credential))
        .await?;
    Ok(())
}

#[tauri::command]
pub async fn delete_credential(
    app: AppHandle,
    state: State<'_, AppState>,
    request: CredentialStatusRequest,
) -> CommandResult<()> {
    let shell = state.shell()?;
    let reference = credential_target_reference(&shell, &request.target)?;
    app.lorepia_platform().delete_credential(&reference).await?;
    Ok(())
}

#[tauri::command]
pub fn get_provider_overview(state: State<'_, AppState>) -> CommandResult<ProviderOverviewDto> {
    let shell = state.shell()?;
    Ok(ProviderOverviewDto {
        settings: shell.get_settings()?,
        templates: shell.list_provider_templates()?,
        connections: shell.list_provider_connections()?,
        legacy_profiles: shell.list_provider_profiles()?,
    })
}

#[tauri::command]
pub fn list_model_routes(
    state: State<'_, AppState>,
    request: ModelRoutesRequest,
) -> CommandResult<Vec<ModelRouteDto>> {
    state
        .shell()?
        .list_model_routes(&request.connection_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn list_generation_presets(
    state: State<'_, AppState>,
    request: GenerationPresetsRequest,
) -> CommandResult<Vec<GenerationPresetDto>> {
    state
        .shell()?
        .list_generation_presets(&request.model_route_id)
        .map_err(Into::into)
}

#[tauri::command]
pub fn preview_provider_request(
    state: State<'_, AppState>,
    request: PreviewProviderRequest,
) -> CommandResult<RequestPreviewDto> {
    state
        .shell()?
        .preview_provider_request(request.target)
        .map_err(Into::into)
}

async fn credential_for_selection(
    app: &AppHandle,
    shell: &lorepia_shell_api::ShellApi,
    selection: &GenerationSelectionInput,
) -> CommandResult<GenerationCredential> {
    match selection {
        GenerationSelectionInput::LegacyProfile {
            provider_profile_id,
        } => {
            let reference = provider_profile_reference(shell, provider_profile_id)?;
            let credential = app
                .lorepia_platform()
                .read_credential(&reference)
                .await?
                .map(|value| SecretCredential::new(value.expose().to_owned()));
            Ok(GenerationCredential::legacy(credential))
        }
        GenerationSelectionInput::Target { target } => {
            let (connection_id, credential_binding_required) =
                connection_for_route(shell, &target.model_route_id)?;
            let credential = if credential_binding_required {
                app.lorepia_platform()
                    .read_credential(&connection_id)
                    .await?
                    .map(|value| SecretCredential::new(value.expose().to_owned()))
            } else {
                None
            };
            Ok(GenerationCredential::connection(connection_id, credential))
        }
    }
}

fn credential_target_reference(
    shell: &lorepia_shell_api::ShellApi,
    target: &CredentialTarget,
) -> CommandResult<String> {
    match target {
        CredentialTarget::LegacyProfile {
            provider_profile_id,
        } => provider_profile_reference(shell, provider_profile_id),
        CredentialTarget::Connection { connection_id } => {
            let connection = shell
                .list_provider_connections()?
                .into_iter()
                .find(|connection| connection.id == *connection_id)
                .ok_or_else(CommandError::invalid_input)?;
            if !connection.credential_binding_required {
                return Err(CommandError::invalid_input());
            }
            Ok(connection.id)
        }
    }
}

fn provider_profile_reference(
    shell: &lorepia_shell_api::ShellApi,
    provider_profile_id: &str,
) -> CommandResult<String> {
    shell
        .list_provider_profiles()?
        .into_iter()
        .find(|profile| profile.id == provider_profile_id)
        .map(|profile| profile.id)
        .ok_or_else(CommandError::invalid_input)
}

fn connection_for_route(
    shell: &lorepia_shell_api::ShellApi,
    route_id: &str,
) -> CommandResult<(String, bool)> {
    for connection in shell.list_provider_connections()? {
        if shell
            .list_model_routes(&connection.id)?
            .iter()
            .any(|route| route.id == route_id)
        {
            return Ok((connection.id, connection.credential_binding_required));
        }
    }
    Err(CommandError::invalid_input())
}
