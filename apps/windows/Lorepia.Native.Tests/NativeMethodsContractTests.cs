using Lorepia.Native.Interop;
using System.Reflection;
using System.Runtime.InteropServices;

namespace Lorepia.Native.Tests;

public sealed class NativeMethodsContractTests
{
    private static readonly IReadOnlyDictionary<string, string> ExpectedEntries =
        new Dictionary<string, string>(StringComparer.Ordinal)
        {
            [nameof(NativeMethods.AbiVersion)] = "lorepia_abi_version",
            [nameof(NativeMethods.CoreCreate)] = "lorepia_core_create",
            [nameof(NativeMethods.CoreDestroy)] = "lorepia_core_destroy",
            [nameof(NativeMethods.CoreLastErrorJson)] = "lorepia_core_last_error_json",
            [nameof(NativeMethods.CoreVersion)] = "lorepia_core_version",
            [nameof(NativeMethods.CoreHealthCheckJson)] = "lorepia_core_health_check_json",
            [nameof(NativeMethods.CoreInspectImportJson)] = "lorepia_core_inspect_import_json",
            [nameof(NativeMethods.CoreCommitImportJson)] = "lorepia_core_commit_import_json",
            [nameof(NativeMethods.CoreDiscardImport)] = "lorepia_core_discard_import",
            [nameof(NativeMethods.CoreListCharactersJson)] = "lorepia_core_list_characters_json",
            [nameof(NativeMethods.CoreGetCharacterJson)] = "lorepia_core_get_character_json",
            [nameof(NativeMethods.CoreOpenConversationJson)] = "lorepia_core_open_conversation_json",
            [nameof(NativeMethods.CoreListConversationsJson)] = "lorepia_core_list_conversations_json",
            [nameof(NativeMethods.CoreListMessagesJson)] = "lorepia_core_list_messages_json",
            [nameof(NativeMethods.CoreSendMessageJson)] = "lorepia_core_send_message_json",
            [nameof(NativeMethods.CoreSendMessageWithTargetJson)] = "lorepia_core_send_message_with_target_json",
            [nameof(NativeMethods.CoreSendMessageToBranchWithTargetJson)] = "lorepia_core_send_message_to_branch_with_target_json",
            [nameof(NativeMethods.CoreEditUserMessageWithTargetJson)] = "lorepia_core_edit_user_message_with_target_json",
            [nameof(NativeMethods.CoreRegenerateAssistantMessageWithTargetJson)] = "lorepia_core_regenerate_assistant_message_with_target_json",
            [nameof(NativeMethods.CoreCancelGeneration)] = "lorepia_core_cancel_generation",
            [nameof(NativeMethods.CorePollEventsJson)] = "lorepia_core_poll_events_json",
            [nameof(NativeMethods.CoreGetSettingsJson)] = "lorepia_core_get_settings_json",
            [nameof(NativeMethods.CoreUpdateSettingsJson)] = "lorepia_core_update_settings_json",
            [nameof(NativeMethods.CoreListProviderTemplatesJson)] = "lorepia_core_list_provider_templates_json",
            [nameof(NativeMethods.CoreCreateProviderConnectionJson)] = "lorepia_core_create_provider_connection_json",
            [nameof(NativeMethods.CoreListProviderConnectionsJson)] = "lorepia_core_list_provider_connections_json",
            [nameof(NativeMethods.CoreUpsertProviderConnectionJson)] = "lorepia_core_upsert_provider_connection_json",
            [nameof(NativeMethods.CoreDeleteProviderConnectionJson)] = "lorepia_core_delete_provider_connection_json",
            [nameof(NativeMethods.CoreListModelRoutesJson)] = "lorepia_core_list_model_routes_json",
            [nameof(NativeMethods.CoreUpsertModelRouteJson)] = "lorepia_core_upsert_model_route_json",
            [nameof(NativeMethods.CoreDeleteModelRouteJson)] = "lorepia_core_delete_model_route_json",
            [nameof(NativeMethods.CoreListCapabilityObservationsJson)] = "lorepia_core_list_capability_observations_json",
            [nameof(NativeMethods.CoreGetEffectiveCapabilityJson)] = "lorepia_core_get_effective_capability_json",
            [nameof(NativeMethods.CoreEffectiveParameterSpecsJson)] = "lorepia_core_effective_parameter_specs_json",
            [nameof(NativeMethods.CoreUpsertUserCapabilityOverrideJson)] = "lorepia_core_upsert_user_capability_override_json",
            [nameof(NativeMethods.CoreDeleteUserCapabilityOverrideJson)] = "lorepia_core_delete_user_capability_override_json",
            [nameof(NativeMethods.CoreRefreshProviderModelsJson)] = "lorepia_core_refresh_provider_models_json",
            [nameof(NativeMethods.CoreStartProviderModelSyncJson)] = "lorepia_core_start_provider_model_sync_json",
            [nameof(NativeMethods.CoreGetProviderModelSyncJson)] = "lorepia_core_get_provider_model_sync_json",
            [nameof(NativeMethods.CoreListProviderModelSyncsJson)] = "lorepia_core_list_provider_model_syncs_json",
            [nameof(NativeMethods.CoreApproveProviderModelSyncJson)] = "lorepia_core_approve_provider_model_sync_json",
            [nameof(NativeMethods.CoreCancelProviderModelSyncJson)] = "lorepia_core_cancel_provider_model_sync_json",
            [nameof(NativeMethods.CorePollProviderModelSyncJobEventsJson)] = "lorepia_core_poll_provider_model_sync_job_events_json",
            [nameof(NativeMethods.CoreAckProviderModelSyncEventJson)] = "lorepia_core_ack_provider_model_sync_event_json",
            [nameof(NativeMethods.CoreInspectProviderCurlJson)] = "lorepia_core_inspect_provider_curl_json",
            [nameof(NativeMethods.CoreBeginProviderDiscoveryJson)] = "lorepia_core_begin_provider_discovery_json",
            [nameof(NativeMethods.CorePrepareProviderDiscoveryActionJson)] = "lorepia_core_prepare_provider_discovery_action_json",
            [nameof(NativeMethods.CoreGetProviderDiscoveryJson)] = "lorepia_core_get_provider_discovery_json",
            [nameof(NativeMethods.CoreListProviderDiscoveriesJson)] = "lorepia_core_list_provider_discoveries_json",
            [nameof(NativeMethods.CoreListProviderDiscoveryCandidatesJson)] = "lorepia_core_list_provider_discovery_candidates_json",
            [nameof(NativeMethods.CoreListProviderDiscoveryEvidenceJson)] = "lorepia_core_list_provider_discovery_evidence_json",
            [nameof(NativeMethods.CoreListProviderDiscoveryApprovalsJson)] = "lorepia_core_list_provider_discovery_approvals_json",
            [nameof(NativeMethods.CoreGetProviderDiscoveryReviewJson)] = "lorepia_core_get_provider_discovery_review_json",
            [nameof(NativeMethods.CoreGetProviderDiscoveryApprovalProposalJson)] = "lorepia_core_get_provider_discovery_approval_proposal_json",
            [nameof(NativeMethods.CoreGetProviderDiscoveryReviewProposalJson)] = "lorepia_core_get_provider_discovery_review_proposal_json",
            [nameof(NativeMethods.CoreContinueProviderDiscoveryJson)] = "lorepia_core_continue_provider_discovery_json",
            [nameof(NativeMethods.CoreSupplyProviderDiscoveryEvidenceJson)] = "lorepia_core_supply_provider_discovery_evidence_json",
            [nameof(NativeMethods.CoreCancelProviderDiscoveryJson)] = "lorepia_core_cancel_provider_discovery_json",
            [nameof(NativeMethods.CoreCommitProviderDiscoveryJson)] = "lorepia_core_commit_provider_discovery_json",
            [nameof(NativeMethods.CoreRecoverProviderDiscoveriesJson)] = "lorepia_core_recover_provider_discoveries_json",
            [nameof(NativeMethods.CorePollProviderDiscoveryEventsJson)] = "lorepia_core_poll_provider_discovery_events_json",
            [nameof(NativeMethods.CoreAckProviderDiscoveryEventJson)] = "lorepia_core_ack_provider_discovery_event_json",
            [nameof(NativeMethods.CoreListProviderDiscoveryCompensationStepsJson)] = "lorepia_core_list_provider_discovery_compensation_steps_json",
            [nameof(NativeMethods.CoreStartProviderDiscoveryCredentialCompensationJson)] = "lorepia_core_start_provider_discovery_credential_compensation_json",
            [nameof(NativeMethods.CoreCompleteProviderDiscoveryCredentialCompensationJson)] = "lorepia_core_complete_provider_discovery_credential_compensation_json",
            [nameof(NativeMethods.CoreFailProviderDiscoveryCredentialCompensationJson)] = "lorepia_core_fail_provider_discovery_credential_compensation_json",
            [nameof(NativeMethods.CoreMarkProviderDiscoveryCredentialCompensationUnknownJson)] = "lorepia_core_mark_provider_discovery_credential_compensation_unknown_json",
            [nameof(NativeMethods.CoreRunProviderDiscoveryAssistantTurnJson)] = "lorepia_core_run_provider_discovery_assistant_turn_json",
            [nameof(NativeMethods.CoreResumeProviderDiscoveryAssistantCoreHostActionJson)] = "lorepia_core_resume_provider_discovery_assistant_core_host_action_json",
            [nameof(NativeMethods.CoreApproveProviderDiscoveryAssistantRetryJson)] = "lorepia_core_approve_provider_discovery_assistant_retry_json",
            [nameof(NativeMethods.CoreRequestProviderDiscoveryAssistantRevisionJson)] = "lorepia_core_request_provider_discovery_assistant_revision_json",
            [nameof(NativeMethods.CoreAcceptProviderDiscoveryAssistantDraftJson)] = "lorepia_core_accept_provider_discovery_assistant_draft_json",
            [nameof(NativeMethods.CoreRecordProviderDiscoveryAssistantFailureJson)] = "lorepia_core_record_provider_discovery_assistant_failure_json",
            [nameof(NativeMethods.CoreProviderCatalogStatusJson)] = "lorepia_core_provider_catalog_status_json",
            [nameof(NativeMethods.CoreProviderCatalogHistoryJson)] = "lorepia_core_provider_catalog_history_json",
            [nameof(NativeMethods.CorePrepareSignedProviderCatalogImportJson)] = "lorepia_core_prepare_signed_provider_catalog_import_json",
            [nameof(NativeMethods.CoreActivateSignedProviderCatalogImportJson)] = "lorepia_core_activate_signed_provider_catalog_import_json",
            [nameof(NativeMethods.CoreDiffProviderCatalogRevisionsJson)] = "lorepia_core_diff_provider_catalog_revisions_json",
            [nameof(NativeMethods.CorePrepareProviderCatalogRollbackJson)] = "lorepia_core_prepare_provider_catalog_rollback_json",
            [nameof(NativeMethods.CoreActivateProviderCatalogRollbackJson)] = "lorepia_core_activate_provider_catalog_rollback_json",
            [nameof(NativeMethods.CoreListGenerationPresetsJson)] = "lorepia_core_list_generation_presets_json",
            [nameof(NativeMethods.CoreUpsertGenerationPresetJson)] = "lorepia_core_upsert_generation_preset_json",
            [nameof(NativeMethods.CoreValidateGenerationPresetJson)] = "lorepia_core_validate_generation_preset_json",
            [nameof(NativeMethods.CoreValidateGenerationPresetCandidateJson)] = "lorepia_core_validate_generation_preset_candidate_json",
            [nameof(NativeMethods.CoreRenderReasoningControlCandidateJson)] = "lorepia_core_render_reasoning_control_candidate_json",
            [nameof(NativeMethods.CoreRenderPromptCacheControlCandidateJson)] = "lorepia_core_render_prompt_cache_control_candidate_json",
            [nameof(NativeMethods.CorePreviewProviderRequestJson)] = "lorepia_core_preview_provider_request_json",
            [nameof(NativeMethods.CorePreviewProviderRequestCandidateJson)] = "lorepia_core_preview_provider_request_candidate_json",
            [nameof(NativeMethods.CoreDeleteGenerationPresetJson)] = "lorepia_core_delete_generation_preset_json",
            [nameof(NativeMethods.CoreSelectGenerationTargetJson)] = "lorepia_core_select_generation_target_json",
            [nameof(NativeMethods.CoreListProviderProfilesJson)] = "lorepia_core_list_provider_profiles_json",
            [nameof(NativeMethods.CoreUpsertProviderProfileJson)] = "lorepia_core_upsert_provider_profile_json",
            [nameof(NativeMethods.CoreDeleteProviderProfile)] = "lorepia_core_delete_provider_profile",
            [nameof(NativeMethods.BufferFree)] = "lorepia_buffer_free",
        };

    [Fact]
    public void PInvokeMethods_UseExactCdeclContract()
    {
        var methods = typeof(NativeMethods)
            .GetMethods(BindingFlags.Static | BindingFlags.NonPublic)
            .Where(method => method.GetCustomAttribute<DllImportAttribute>() is not null)
            .ToDictionary(method => method.Name, StringComparer.Ordinal);

        Assert.Equal(ExpectedEntries.Count, methods.Count);

        foreach (var (methodName, entryPoint) in ExpectedEntries)
        {
            var attribute = methods[methodName].GetCustomAttribute<DllImportAttribute>();

            Assert.NotNull(attribute);
            Assert.Equal(NativeMethods.LibraryName, attribute.Value);
            Assert.Equal(entryPoint, attribute.EntryPoint);
            Assert.Equal(CallingConvention.Cdecl, attribute.CallingConvention);
            Assert.True(attribute.ExactSpelling);
        }
    }

    [Fact]
    public void FallibleCalls_ReturnStatusAndUseOutParameters()
    {
        var infallible = new HashSet<string>(StringComparer.Ordinal)
        {
            nameof(NativeMethods.AbiVersion),
            nameof(NativeMethods.CoreDestroy),
            nameof(NativeMethods.BufferFree),
        };
        foreach (var methodName in ExpectedEntries.Keys.Except(infallible))
        {
            Assert.Equal(typeof(int), GetMethod(methodName).ReturnType);
        }

        Assert.True(GetMethod(nameof(NativeMethods.CoreCreate))
            .GetParameters()[2]
            .IsOut);

        var bufferedCalls = new[]
        {
            nameof(NativeMethods.CoreLastErrorJson),
            nameof(NativeMethods.CoreVersion),
            nameof(NativeMethods.CoreHealthCheckJson),
            nameof(NativeMethods.CoreInspectImportJson),
            nameof(NativeMethods.CoreCommitImportJson),
            nameof(NativeMethods.CoreListCharactersJson),
            nameof(NativeMethods.CoreGetCharacterJson),
            nameof(NativeMethods.CoreOpenConversationJson),
            nameof(NativeMethods.CoreListConversationsJson),
            nameof(NativeMethods.CoreListMessagesJson),
            nameof(NativeMethods.CoreSendMessageJson),
            nameof(NativeMethods.CoreSendMessageWithTargetJson),
            nameof(NativeMethods.CoreSendMessageToBranchWithTargetJson),
            nameof(NativeMethods.CoreEditUserMessageWithTargetJson),
            nameof(NativeMethods.CoreRegenerateAssistantMessageWithTargetJson),
            nameof(NativeMethods.CorePollEventsJson),
            nameof(NativeMethods.CoreGetSettingsJson),
            nameof(NativeMethods.CoreListProviderTemplatesJson),
            nameof(NativeMethods.CoreCreateProviderConnectionJson),
            nameof(NativeMethods.CoreListProviderConnectionsJson),
            nameof(NativeMethods.CoreUpsertProviderConnectionJson),
            nameof(NativeMethods.CoreListModelRoutesJson),
            nameof(NativeMethods.CoreUpsertModelRouteJson),
            nameof(NativeMethods.CoreListCapabilityObservationsJson),
            nameof(NativeMethods.CoreGetEffectiveCapabilityJson),
            nameof(NativeMethods.CoreEffectiveParameterSpecsJson),
            nameof(NativeMethods.CoreUpsertUserCapabilityOverrideJson),
            nameof(NativeMethods.CoreRefreshProviderModelsJson),
            nameof(NativeMethods.CoreStartProviderModelSyncJson),
            nameof(NativeMethods.CoreGetProviderModelSyncJson),
            nameof(NativeMethods.CoreListProviderModelSyncsJson),
            nameof(NativeMethods.CoreApproveProviderModelSyncJson),
            nameof(NativeMethods.CoreCancelProviderModelSyncJson),
            nameof(NativeMethods.CorePollProviderModelSyncJobEventsJson),
            nameof(NativeMethods.CoreAckProviderModelSyncEventJson),
            nameof(NativeMethods.CoreInspectProviderCurlJson),
            nameof(NativeMethods.CoreBeginProviderDiscoveryJson),
            nameof(NativeMethods.CorePrepareProviderDiscoveryActionJson),
            nameof(NativeMethods.CoreGetProviderDiscoveryJson),
            nameof(NativeMethods.CoreListProviderDiscoveriesJson),
            nameof(NativeMethods.CoreListProviderDiscoveryCandidatesJson),
            nameof(NativeMethods.CoreListProviderDiscoveryEvidenceJson),
            nameof(NativeMethods.CoreListProviderDiscoveryApprovalsJson),
            nameof(NativeMethods.CoreGetProviderDiscoveryReviewJson),
            nameof(NativeMethods.CoreGetProviderDiscoveryApprovalProposalJson),
            nameof(NativeMethods.CoreGetProviderDiscoveryReviewProposalJson),
            nameof(NativeMethods.CoreContinueProviderDiscoveryJson),
            nameof(NativeMethods.CoreSupplyProviderDiscoveryEvidenceJson),
            nameof(NativeMethods.CoreCancelProviderDiscoveryJson),
            nameof(NativeMethods.CoreCommitProviderDiscoveryJson),
            nameof(NativeMethods.CoreRecoverProviderDiscoveriesJson),
            nameof(NativeMethods.CorePollProviderDiscoveryEventsJson),
            nameof(NativeMethods.CoreAckProviderDiscoveryEventJson),
            nameof(NativeMethods.CoreListProviderDiscoveryCompensationStepsJson),
            nameof(NativeMethods.CoreStartProviderDiscoveryCredentialCompensationJson),
            nameof(NativeMethods.CoreCompleteProviderDiscoveryCredentialCompensationJson),
            nameof(NativeMethods.CoreFailProviderDiscoveryCredentialCompensationJson),
            nameof(NativeMethods.CoreMarkProviderDiscoveryCredentialCompensationUnknownJson),
            nameof(NativeMethods.CoreRunProviderDiscoveryAssistantTurnJson),
            nameof(NativeMethods.CoreResumeProviderDiscoveryAssistantCoreHostActionJson),
            nameof(NativeMethods.CoreApproveProviderDiscoveryAssistantRetryJson),
            nameof(NativeMethods.CoreRequestProviderDiscoveryAssistantRevisionJson),
            nameof(NativeMethods.CoreAcceptProviderDiscoveryAssistantDraftJson),
            nameof(NativeMethods.CoreRecordProviderDiscoveryAssistantFailureJson),
            nameof(NativeMethods.CoreProviderCatalogStatusJson),
            nameof(NativeMethods.CoreProviderCatalogHistoryJson),
            nameof(NativeMethods.CorePrepareSignedProviderCatalogImportJson),
            nameof(NativeMethods.CoreActivateSignedProviderCatalogImportJson),
            nameof(NativeMethods.CoreDiffProviderCatalogRevisionsJson),
            nameof(NativeMethods.CorePrepareProviderCatalogRollbackJson),
            nameof(NativeMethods.CoreActivateProviderCatalogRollbackJson),
            nameof(NativeMethods.CoreListGenerationPresetsJson),
            nameof(NativeMethods.CoreUpsertGenerationPresetJson),
            nameof(NativeMethods.CoreRenderReasoningControlCandidateJson),
            nameof(NativeMethods.CoreRenderPromptCacheControlCandidateJson),
            nameof(NativeMethods.CorePreviewProviderRequestJson),
            nameof(NativeMethods.CorePreviewProviderRequestCandidateJson),
            nameof(NativeMethods.CoreSelectGenerationTargetJson),
            nameof(NativeMethods.CoreListProviderProfilesJson),
            nameof(NativeMethods.CoreUpsertProviderProfileJson),
        };
        foreach (var methodName in bufferedCalls)
        {
            Assert.True(GetMethod(methodName).GetParameters()[^1].IsOut);
        }
    }

    [Fact]
    public void Utf8Arrays_UseExplicitLengthParameters()
    {
        var methods = new[]
        {
            nameof(NativeMethods.CoreCreate),
            nameof(NativeMethods.CoreInspectImportJson),
            nameof(NativeMethods.CoreCommitImportJson),
            nameof(NativeMethods.CoreDiscardImport),
            nameof(NativeMethods.CoreGetCharacterJson),
            nameof(NativeMethods.CoreOpenConversationJson),
            nameof(NativeMethods.CoreListMessagesJson),
            nameof(NativeMethods.CoreSendMessageJson),
            nameof(NativeMethods.CoreSendMessageWithTargetJson),
            nameof(NativeMethods.CoreSendMessageToBranchWithTargetJson),
            nameof(NativeMethods.CoreEditUserMessageWithTargetJson),
            nameof(NativeMethods.CoreRegenerateAssistantMessageWithTargetJson),
            nameof(NativeMethods.CoreCancelGeneration),
            nameof(NativeMethods.CoreUpdateSettingsJson),
            nameof(NativeMethods.CoreCreateProviderConnectionJson),
            nameof(NativeMethods.CoreUpsertProviderConnectionJson),
            nameof(NativeMethods.CoreDeleteProviderConnectionJson),
            nameof(NativeMethods.CoreListModelRoutesJson),
            nameof(NativeMethods.CoreUpsertModelRouteJson),
            nameof(NativeMethods.CoreDeleteModelRouteJson),
            nameof(NativeMethods.CoreListCapabilityObservationsJson),
            nameof(NativeMethods.CoreGetEffectiveCapabilityJson),
            nameof(NativeMethods.CoreEffectiveParameterSpecsJson),
            nameof(NativeMethods.CoreUpsertUserCapabilityOverrideJson),
            nameof(NativeMethods.CoreDeleteUserCapabilityOverrideJson),
            nameof(NativeMethods.CoreRefreshProviderModelsJson),
            nameof(NativeMethods.CoreStartProviderModelSyncJson),
            nameof(NativeMethods.CoreGetProviderModelSyncJson),
            nameof(NativeMethods.CoreListProviderModelSyncsJson),
            nameof(NativeMethods.CoreApproveProviderModelSyncJson),
            nameof(NativeMethods.CoreCancelProviderModelSyncJson),
            nameof(NativeMethods.CorePollProviderModelSyncJobEventsJson),
            nameof(NativeMethods.CoreAckProviderModelSyncEventJson),
            nameof(NativeMethods.CoreInspectProviderCurlJson),
            nameof(NativeMethods.CoreBeginProviderDiscoveryJson),
            nameof(NativeMethods.CorePrepareProviderDiscoveryActionJson),
            nameof(NativeMethods.CoreGetProviderDiscoveryJson),
            nameof(NativeMethods.CoreListProviderDiscoveriesJson),
            nameof(NativeMethods.CoreListProviderDiscoveryCandidatesJson),
            nameof(NativeMethods.CoreListProviderDiscoveryEvidenceJson),
            nameof(NativeMethods.CoreListProviderDiscoveryApprovalsJson),
            nameof(NativeMethods.CoreGetProviderDiscoveryReviewJson),
            nameof(NativeMethods.CoreGetProviderDiscoveryApprovalProposalJson),
            nameof(NativeMethods.CoreGetProviderDiscoveryReviewProposalJson),
            nameof(NativeMethods.CoreContinueProviderDiscoveryJson),
            nameof(NativeMethods.CoreSupplyProviderDiscoveryEvidenceJson),
            nameof(NativeMethods.CoreCancelProviderDiscoveryJson),
            nameof(NativeMethods.CoreCommitProviderDiscoveryJson),
            nameof(NativeMethods.CoreAckProviderDiscoveryEventJson),
            nameof(NativeMethods.CoreListProviderDiscoveryCompensationStepsJson),
            nameof(NativeMethods.CoreStartProviderDiscoveryCredentialCompensationJson),
            nameof(NativeMethods.CoreCompleteProviderDiscoveryCredentialCompensationJson),
            nameof(NativeMethods.CoreFailProviderDiscoveryCredentialCompensationJson),
            nameof(NativeMethods.CoreMarkProviderDiscoveryCredentialCompensationUnknownJson),
            nameof(NativeMethods.CoreRunProviderDiscoveryAssistantTurnJson),
            nameof(NativeMethods.CoreResumeProviderDiscoveryAssistantCoreHostActionJson),
            nameof(NativeMethods.CoreApproveProviderDiscoveryAssistantRetryJson),
            nameof(NativeMethods.CoreRequestProviderDiscoveryAssistantRevisionJson),
            nameof(NativeMethods.CoreAcceptProviderDiscoveryAssistantDraftJson),
            nameof(NativeMethods.CoreRecordProviderDiscoveryAssistantFailureJson),
            nameof(NativeMethods.CoreProviderCatalogHistoryJson),
            nameof(NativeMethods.CorePrepareSignedProviderCatalogImportJson),
            nameof(NativeMethods.CoreActivateSignedProviderCatalogImportJson),
            nameof(NativeMethods.CoreDiffProviderCatalogRevisionsJson),
            nameof(NativeMethods.CorePrepareProviderCatalogRollbackJson),
            nameof(NativeMethods.CoreActivateProviderCatalogRollbackJson),
            nameof(NativeMethods.CoreListGenerationPresetsJson),
            nameof(NativeMethods.CoreUpsertGenerationPresetJson),
            nameof(NativeMethods.CoreValidateGenerationPresetJson),
            nameof(NativeMethods.CoreValidateGenerationPresetCandidateJson),
            nameof(NativeMethods.CoreRenderReasoningControlCandidateJson),
            nameof(NativeMethods.CoreRenderPromptCacheControlCandidateJson),
            nameof(NativeMethods.CorePreviewProviderRequestJson),
            nameof(NativeMethods.CorePreviewProviderRequestCandidateJson),
            nameof(NativeMethods.CoreDeleteGenerationPresetJson),
            nameof(NativeMethods.CoreSelectGenerationTargetJson),
            nameof(NativeMethods.CoreUpsertProviderProfileJson),
            nameof(NativeMethods.CoreDeleteProviderProfile),
        };

        foreach (var methodName in methods)
        {
            var parameters = GetMethod(methodName).GetParameters();
            foreach (var (parameter, index) in parameters.Select((value, index) => (value, index)))
            {
                if (parameter.ParameterType != typeof(byte[]))
                {
                    continue;
                }

                var marshal = parameter.GetCustomAttribute<MarshalAsAttribute>();
                Assert.NotNull(marshal);
                Assert.Equal(UnmanagedType.LPArray, marshal.Value);
                Assert.InRange(marshal.SizeParamIndex, (short)(index + 1), (short)(parameters.Length - 1));
                Assert.Equal(typeof(nuint), parameters[marshal.SizeParamIndex].ParameterType);
            }
        }
    }

    private static MethodInfo GetMethod(string name) =>
        typeof(NativeMethods).GetMethod(
            name,
            BindingFlags.Static | BindingFlags.NonPublic)
        ?? throw new InvalidOperationException($"Missing native method {name}.");
}
