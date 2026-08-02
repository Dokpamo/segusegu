using System.Text.Json;

namespace Lorepia.Native.Tests;

public sealed class ProviderCoreClientTests
{
    [Fact]
    public void MapsProviderConnectionRoutePresetAndSelectionContracts()
    {
        var api = new FakeNativeApi
        {
            SettingsJson =
                """
                {
                  "preserve_partial_generations": true,
                  "selected_provider_profile_id": null,
                  "selected_model_route_id": "route-1",
                  "selected_generation_preset_id": "preset-1"
                }
                """,
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        var template = Assert.Single(client.ListProviderTemplates());
        Assert.Equal("openai-chat-compatible-v1", template.Id);
        Assert.Equal(
            ProviderApiFamily.OpenaiChatCompletions,
            template.ApiFamily);
        Assert.Equal(
            ProviderNetworkMode.Public,
            template.DefaultNetworkMode);
        Assert.True(template.RequiresCredential);
        Assert.Equal("bearer_header", template.AuthBinding.Kind);

        var created = client.CreateProviderConnection(
            new ProviderConnectionDraft
            {
                Id = "connection-1",
                TemplateId = template.Id,
                TemplateVersion = template.ManifestVersion,
                DisplayName = "테스트 연결",
                ApiOrigin = "https://api.example.invalid",
                ApiBasePath = "/v1",
                NetworkMode = ProviderNetworkMode.Public,
                Values =
                [
                    new ConnectionConfigEntry
                    {
                        Key = "organization",
                        Value = ConnectionConfigValue.Text("org-1"),
                    },
                ],
                ApprovedCredentialOrigin =
                    "https://api.example.invalid",
                TimeoutSeconds = 30,
            });
        Assert.True(created.CredentialSlotRequired);
        Assert.Equal(
            "connection-1",
            created.CredentialRef);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "openai-chat-compatible-v1",
                    payload.GetProperty("template_id").GetString());
                Assert.Equal(
                    "public",
                    payload.GetProperty("network_mode").GetString());
                Assert.False(payload.TryGetProperty("credential", out _));
                Assert.Equal(
                    "text",
                    payload.GetProperty("values")[0]
                        .GetProperty("value")
                        .GetProperty("type")
                        .GetString());
            });

        Assert.Single(client.ListProviderConnections());
        var updated = client.UpsertProviderConnection(
            created with { DisplayName = "변경된 연결" },
            credentialSlotReady: true);
        Assert.Equal("connection-1", updated.Id);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "변경된 연결",
                    payload.GetProperty("display_name").GetString());
                Assert.Equal(
                    "/v1",
                    payload.GetProperty("api_base_path").GetString());
                Assert.Equal(
                    "bearer_header",
                    payload.GetProperty("auth_binding")
                        .GetProperty("kind")
                        .GetString());
                Assert.True(
                    payload.GetProperty("credential_slot_ready")
                        .GetBoolean());
                Assert.Equal(
                    "https://api.example.invalid",
                    payload.GetProperty("approved_credential_origins")[0]
                        .GetString());
                Assert.Equal(
                    "deny",
                    payload.GetProperty("credential_redirect_policy")
                        .GetString());
                Assert.False(payload.TryGetProperty("config", out _));
                Assert.False(payload.TryGetProperty(
                    "credential_ref",
                    out _));
                Assert.False(payload.TryGetProperty(
                    "credential_scope",
                    out _));
                Assert.False(payload.TryGetProperty(
                    "credential_slot_required",
                    out _));
            });

        var route = Assert.Single(client.ListModelRoutes(created.Id));
        Assert.Equal(created.Id, api.LastConnectionId);
        Assert.Equal(
            ProviderApiFamily.OpenaiChatCompletions,
            route.ApiFamily);
        Assert.Equal(ModelAvailability.Available, route.Availability);
        Assert.Equal(ModelMetadataSource.ProviderApi, route.MetadataSource);
        Assert.Equal("{\"owned\":true}", route.RawMetadataJson);
        Assert.Equal("sync-1", route.LastReconciledSyncJobId);
        Assert.Equal("sync-1", route.MetadataSyncJobId);
        client.UpsertModelRoute(route with { DisplayName = "변경된 모델" });
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "openai_chat_completions",
                    payload.GetProperty("api_family").GetString());
                Assert.Equal(
                    "available",
                    payload.GetProperty("status").GetString());
                Assert.False(payload.TryGetProperty("availability", out _));
                Assert.Equal(
                    "{\"owned\":true}",
                    payload.GetProperty("raw_metadata").GetString());
                Assert.False(payload.TryGetProperty(
                    "raw_metadata_json",
                    out _));
                Assert.Equal(
                    "provider_api",
                    payload.GetProperty("metadata_source").GetString());
                Assert.Equal(
                    "sync-1",
                    payload.GetProperty("metadata_sync_job_id").GetString());
            });

        var preset = Assert.Single(client.ListGenerationPresets(route.Id));
        Assert.Equal(route.Id, api.LastModelRouteId);
        client.UpsertGenerationPreset(
            preset with
            {
                Values =
                [
                    new ProviderParameterValue
                    {
                        ParameterId = "temperature",
                        State = new ProviderParameterValueState
                        {
                            State = "explicit",
                            Value = new ProviderParameterLiteral
                            {
                                Type = "number",
                                Value = JsonSerializer.SerializeToElement(0.4),
                            },
                        },
                    },
                ],
            });
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                var state = payload.GetProperty("values")[0]
                    .GetProperty("state");
                Assert.Equal("explicit", state.GetProperty("state").GetString());
                Assert.Equal(
                    "number",
                    state.GetProperty("value").GetProperty("type").GetString());
            });

        var target = new GenerationTarget
        {
            ModelRouteId = route.Id,
            GenerationPresetId = preset.Id,
        };
        var settings = client.SelectGenerationTarget(target);
        Assert.Equal(route.Id, settings.SelectedModelRouteId);
        Assert.Equal(preset.Id, settings.SelectedGenerationPresetId);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload => Assert.Equal(
                route.Id,
                payload.GetProperty("target")
                    .GetProperty("model_route_id")
                    .GetString()));

        client.DeleteGenerationPreset(preset.Id);
        Assert.Equal("delete_generation_preset", api.LastContractOperation);
        client.DeleteModelRoute(route.Id);
        Assert.Equal("delete_model_route", api.LastContractOperation);
        client.DeleteProviderConnection(created.Id);
        Assert.Equal("delete_provider_connection", api.LastContractOperation);
    }

    [Fact]
    public void ApprovedLanConnectionCarriesExactOriginAndAddressGrant()
    {
        var api = new FakeNativeApi();
        api.ProviderConnectionJson = api.ProviderConnectionJson
            .Replace(
                "https://api.example.invalid",
                "http://models.lan:11434",
                StringComparison.Ordinal)
            .Replace(
                "\"network_mode\": \"public\",",
                """
                "network_mode": "approved_local_network",
                "local_network_approval": {
                  "origin": "http://models.lan:11434",
                  "addresses": ["192.168.10.24", "fd00::24"]
                },
                """,
                StringComparison.Ordinal);
        using var client = CoreClient.Open(api, CreateDataRoot());
        var approval = new ProviderLocalNetworkApproval
        {
            Origin = "http://models.lan:11434",
            Addresses = ["192.168.10.24", "fd00::24"],
        };

        var created = client.CreateProviderConnection(
            new ProviderConnectionDraft
            {
                Id = "connection-1",
                TemplateId = "openai-chat-compatible-v1",
                TemplateVersion = 1,
                DisplayName = "LAN model server",
                ApiOrigin = approval.Origin,
                NetworkMode =
                    ProviderNetworkMode.ApprovedLocalNetwork,
                LocalNetworkApproval = approval,
                ApprovedCredentialOrigin = approval.Origin,
                TimeoutSeconds = 30,
            });

        Assert.Equal(
            ProviderNetworkMode.ApprovedLocalNetwork,
            created.NetworkMode);
        Assert.Equal(
            approval.Origin,
            created.LocalNetworkApproval?.Origin);
        Assert.Equal(
            approval.Addresses,
            created.LocalNetworkApproval?.Addresses);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "approved_local_network",
                    payload.GetProperty("network_mode").GetString());
                var grant =
                    payload.GetProperty("local_network_approval");
                Assert.Equal(
                    approval.Origin,
                    grant.GetProperty("origin").GetString());
                Assert.Equal(
                    approval.Addresses,
                    grant.GetProperty("addresses")
                        .EnumerateArray()
                        .Select(item => item.GetString()!)
                        .ToArray());
            });
    }

    [Fact]
    public void MapsCapabilitiesAndKeepsRefreshCredentialOutOfJson()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        var observation = Assert.Single(
            client.ListCapabilityObservations("route-1"));
        Assert.Equal("route-1", api.LastModelRouteId);
        Assert.Equal(CapabilityKey.Streaming, observation.Key);
        Assert.Equal(
            CapabilityObservationSource.UserOverride,
            observation.Source);
        Assert.True(observation.Value.Value.GetBoolean());

        var effective = client.GetEffectiveCapability(
            "route-1",
            CapabilityKey.Streaming);
        Assert.NotNull(effective);
        Assert.False(effective.SelectedIsStale);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload => Assert.Equal(
                "streaming",
                payload.GetProperty("key").GetString()));

        var saved = client.UpsertUserCapabilityOverride(observation);
        Assert.Equal(observation.Id, saved.Id);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "user_override",
                    payload.GetProperty("source").GetString());
                Assert.Equal(
                    "boolean",
                    payload.GetProperty("value")
                        .GetProperty("type")
                        .GetString());
            });

        client.DeleteUserCapabilityOverride(
            observation.ModelRouteId,
            observation.Id);
        Assert.Equal(
            "delete_user_capability_override",
            api.LastContractOperation);

        const string secret = "synthetic-secret-credential";
        var refresh = client.RefreshProviderModels("connection-1", secret);
        Assert.Equal("connection-1", refresh.ConnectionId);
        Assert.Equal(secret, api.LastRefreshCredential);
        Assert.Single(refresh.ModelRoutes);
        Assert.DoesNotContain(secret, api.LastContractRequestJson);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload => Assert.Equal(
                "connection-1",
                payload.GetProperty("connection_id").GetString()));
    }

    [Fact]
    public void MapsEffectiveParametersValidationAndScalarFreeRequestPreview()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        var parameter = Assert.Single(
            client.GetEffectiveParameterSpecs("route-1"));
        Assert.Equal("route-1", api.LastModelRouteId);
        Assert.Equal("temperature", parameter.Id);
        Assert.Equal("number", parameter.ValueType);
        Assert.Equal(0.0, parameter.Minimum);
        Assert.Equal(2.0, parameter.Maximum);
        Assert.Equal("request_body", parameter.ProviderMapping.Target);

        client.ValidateGenerationPreset("route-1", "preset-1");
        Assert.Equal(1, api.ValidateGenerationPresetCount);
        Assert.Equal(
            "validate_generation_preset",
            api.LastContractOperation);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "route-1",
                    payload.GetProperty("model_route_id").GetString());
                Assert.Equal(
                    "preset-1",
                    payload.GetProperty("generation_preset_id").GetString());
            });

        var result = client.PreviewProviderRequest(
            "route-1",
            "preset-1");
        Assert.Equal(1u, result.RedactionVersion);
        Assert.False(result.IncludesPrivateMessage);
        Assert.False(result.IncludesCredentialValue);
        Assert.False(result.IncludesOpaqueReasoningState);
        Assert.Equal("POST", result.Preview.Method);
        Assert.Equal(
            "https://api.example.invalid",
            result.Preview.Origin);
        Assert.Equal(
            "/v1/chat/completions",
            result.Preview.Path);
        Assert.Equal(
            ["authorization", "content-type"],
            result.Preview.HeaderNames);
        Assert.NotNull(result.Preview.Body);
        Assert.Equal("object", result.Preview.Body.Kind);
        var fields = result.Preview.Body.Fields!;
        Assert.Equal(
            ["model", "messages", "stream"],
            fields.Select(field => field.Name));
        Assert.Equal(
            ["string", "redacted", "boolean"],
            fields.Select(field => field.Shape.Kind));
        Assert.Equal(
            "preview_provider_request",
            api.LastContractOperation);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload => Assert.Equal(
                "preset-1",
                payload.GetProperty("generation_preset_id").GetString()));
    }

    [Fact]
    public void PreviewProviderRequest_RejectsFailedRedactionGuarantee()
    {
        var api = new FakeNativeApi
        {
            ProviderRequestPreviewJson =
                """
                {
                  "redaction_version": 1,
                  "preview": {
                    "method": "POST",
                    "origin": "https://api.example.invalid",
                    "path": "/v1/chat/completions",
                    "header_names": [],
                    "body": null
                  },
                  "includes_private_message": false,
                  "includes_credential_value": true,
                  "includes_opaque_reasoning_state": false
                }
                """,
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        var exception = Assert.Throws<CoreInteropException>(
            () => client.PreviewProviderRequest(
                "route-1",
                "preset-1"));

        Assert.Contains("redaction", exception.Message);
        Assert.Equal(1, api.BufferFreeCount);
    }

    [Fact]
    public void ValidateGenerationPreset_PropagatesNativeValidationFailure()
    {
        var api = new FakeNativeApi
        {
            ValidateGenerationPresetException =
                new CoreInteropException("synthetic incompatible preset"),
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        var exception = Assert.Throws<CoreInteropException>(
            () => client.ValidateGenerationPreset(
                "route-1",
                "preset-1"));

        Assert.Contains("incompatible", exception.Message);
        Assert.Equal(1, api.ValidateGenerationPresetCount);
        Assert.Equal(
            "validate_generation_preset",
            api.LastContractOperation);
    }

    [Fact]
    public void CandidateValidationAndPreview_SendUnsavedPresetDirectly()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());
        var candidate = Assert.Single(
            client.ListGenerationPresets("route-1")) with
        {
            DisplayName = "Unsaved candidate",
        };

        client.ValidateGenerationPresetCandidate(candidate);

        Assert.Equal(1, api.ValidateGenerationPresetCandidateCount);
        Assert.Equal(
            "validate_generation_preset_candidate",
            api.LastContractOperation);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "preset-1",
                    payload.GetProperty("id").GetString());
                Assert.Equal(
                    "Unsaved candidate",
                    payload.GetProperty("display_name").GetString());
                Assert.False(payload.TryGetProperty("preset", out _));
            });

        var preview =
            client.PreviewProviderRequestCandidate(candidate);

        Assert.Equal("POST", preview.Preview.Method);
        Assert.Equal(
            "preview_provider_request_candidate",
            api.LastContractOperation);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload => Assert.Equal(
                "route-1",
                payload.GetProperty("model_route_id").GetString()));
    }

    [Fact]
    public void CandidateControlsComeFromRustOwnedRenderModels()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());
        var candidate = Assert.Single(
            client.ListGenerationPresets("route-1"));

        var reasoning =
            client.RenderReasoningControlCandidate(candidate);
        Assert.Equal("ready", reasoning.State);
        Assert.Equal(
            new[] { "provider_default", "automatic" },
            reasoning.AllowedModes);
        Assert.Equal(128u, reasoning.BudgetBounds?.Minimum);
        Assert.Equal(
            "render_reasoning_control_candidate",
            api.LastContractOperation);

        var promptCache =
            client.RenderPromptCacheControlCandidate(candidate);
        Assert.Equal("ready", promptCache.State);
        Assert.True(promptCache.SupportsCustomTtl);
        Assert.Equal(
            new[] { "provider_default", "short" },
            promptCache.AllowedTtls.Select(ttl => ttl.Kind));
        Assert.Equal(
            3600u,
            promptCache.CustomTtlBounds?.MaximumSeconds);
        Assert.Equal(
            "render_prompt_cache_control_candidate",
            api.LastContractOperation);
    }

    [Fact]
    public void CandidateValidation_PropagatesFailureBeforePersistence()
    {
        var api = new FakeNativeApi
        {
            ValidateGenerationPresetCandidateException =
                new CoreInteropException("synthetic candidate rejected"),
        };
        using var client = CoreClient.Open(api, CreateDataRoot());
        var candidate = Assert.Single(
            client.ListGenerationPresets("route-1"));

        var exception = Assert.Throws<CoreInteropException>(
            () => client.ValidateGenerationPresetCandidate(candidate));

        Assert.Contains("candidate rejected", exception.Message);
        Assert.Equal(1, api.ValidateGenerationPresetCandidateCount);
        Assert.Equal(
            "validate_generation_preset_candidate",
            api.LastContractOperation);
    }

    [Fact]
    public void EffectiveParameterSpecs_RejectInvalidMappedHeader()
    {
        var api = new FakeNativeApi
        {
            EffectiveParameterSpecsJson =
                """
                [
                  {
                    "id": "organization",
                    "label_key": "provider.parameter.organization",
                    "description_key": null,
                    "value_type": "string",
                    "allowed_values": [],
                    "minimum": null,
                    "maximum": null,
                    "step": null,
                    "default_mode": "provider_default",
                    "visibility": null,
                    "conflicts": [],
                    "provider_mapping": {
                      "target": "request_header",
                      "field_name": "bad header"
                    },
                    "level": "advanced"
                  }
                ]
                """,
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        var exception = Assert.Throws<CoreInteropException>(
            () => client.GetEffectiveParameterSpecs("route-1"));

        Assert.Contains("unsafe mapped field", exception.Message);
        Assert.Equal(1, api.BufferFreeCount);
    }

    [Fact]
    public void SendsWithAtomicTargetAndMapsVersionFourToolEvents()
    {
        var api = new FakeNativeApi
        {
            EventsJson =
                """
                {
                  "events": [
                    {
                      "event_version": 4,
                      "generation_id": "generation-1",
                      "conversation_id": "conversation-1",
                      "sequence": 1,
                      "emitted_at": "2026-07-31T00:00:00Z",
                      "kind": {
                        "type": "tool_call_started",
                        "payload": {"id":"call-1","name":"weather"}
                      }
                    },
                    {
                      "event_version": 4,
                      "generation_id": "generation-1",
                      "conversation_id": "conversation-1",
                      "sequence": 2,
                      "emitted_at": "2026-07-31T00:00:01Z",
                      "kind": {
                        "type": "tool_call_arguments_delta",
                        "payload": {"id":"call-1","delta":"{\"city\":\"서울\"}"}
                      }
                    },
                    {
                      "event_version": 4,
                      "generation_id": "generation-1",
                      "conversation_id": "conversation-1",
                      "sequence": 3,
                      "emitted_at": "2026-07-31T00:00:02Z",
                      "kind": {
                        "type": "tool_call_completed",
                        "payload": {"id":"call-1"}
                      }
                    },
                    {
                      "event_version": 4,
                      "generation_id": "generation-1",
                      "conversation_id": "conversation-1",
                      "sequence": 4,
                      "emitted_at": "2026-07-31T00:00:03Z",
                      "kind": {
                        "type": "usage_updated",
                        "payload": {
                          "input_tokens": 10,
                          "cached_read_tokens": 7,
                          "cached_write_tokens": 2,
                          "output_tokens": 5,
                          "reasoning_tokens": 3,
                          "tool_tokens": 1,
                          "provider_raw_summary": "{\"cache_hit\":true}"
                        }
                      }
                    }
                  ],
                  "dropped_events": 0
                }
                """,
        };
        using var client = CoreClient.Open(api, CreateDataRoot());
        var target = new GenerationTarget
        {
            ModelRouteId = "route-1",
            GenerationPresetId = "preset-1",
        };

        var generationId = client.SendMessageWithTarget(
            "conversation-1",
            "도구를 써줘",
            target,
            "connection-1",
            "synthetic-token");
        Assert.Equal("generation-1", generationId);
        Assert.Equal("synthetic-token", api.LastCredential);
        Assert.DoesNotContain("synthetic-token", api.LastTargetRequestJson);
        AssertVersionedRequest(
            api.LastTargetRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "route-1",
                    payload.GetProperty("target")
                        .GetProperty("model_route_id")
                        .GetString());
                Assert.Equal(
                    "preset-1",
                    payload.GetProperty("target")
                        .GetProperty("generation_preset_id")
                        .GetString());
            });

        var events = client.PollEvents().Events;
        Assert.Equal(ChatEventType.ToolCallStarted, events[0].Type);
        Assert.Equal("call-1", events[0].ToolCallId);
        Assert.Equal("weather", events[0].ToolName);
        Assert.Equal(ChatEventType.ToolCallArgumentsDelta, events[1].Type);
        Assert.Equal("{\"city\":\"서울\"}", events[1].ToolArgumentsDelta);
        Assert.Equal(ChatEventType.ToolCallCompleted, events[2].Type);
        Assert.Equal(7UL, events[3].CachedReadTokens);
        Assert.Equal(2UL, events[3].CachedWriteTokens);
        Assert.Equal(3UL, events[3].ReasoningTokens);
        Assert.Equal(1UL, events[3].ToolTokens);
        Assert.Equal("{\"cache_hit\":true}", events[3].ProviderRawSummary);
    }

    [Fact]
    public void EffectiveCapability_AllowsExplicitNull()
    {
        var api = new FakeNativeApi
        {
            EffectiveCapabilityJson = "null",
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Null(client.GetEffectiveCapability(
            "route-1",
            CapabilityKey.AudioOutput));
    }

    [Fact]
    public void RouteAndPresetListsRejectMismatchedParents()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        api.ModelRouteJson = api.ModelRouteJson.Replace(
            "\"connection_id\": \"connection-1\"",
            "\"connection_id\": \"connection-other\"",
            StringComparison.Ordinal);
        Assert.Throws<CoreInteropException>(() =>
            client.ListModelRoutes("connection-1"));

        api.ModelRouteJson = api.ModelRouteJson.Replace(
            "\"connection_id\": \"connection-other\"",
            "\"connection_id\": \"connection-1\"",
            StringComparison.Ordinal);
        api.GenerationPresetJson =
            api.GenerationPresetJson.Replace(
                "\"model_route_id\": \"route-1\"",
                "\"model_route_id\": \"route-other\"",
                StringComparison.Ordinal);
        Assert.Throws<CoreInteropException>(() =>
            client.ListGenerationPresets("route-1"));
    }

    [Fact]
    public void GenerationTargetRejectsCredentialConnectionMismatchBeforeSend()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Throws<CoreInteropException>(() =>
            client.SendMessageWithTarget(
                "conversation-1",
                "hello",
                new GenerationTarget
                {
                    ModelRouteId = "route-1",
                    GenerationPresetId = "preset-1",
                },
                "connection-other",
                "must-not-cross-targets"));

        Assert.Null(api.LastTargetRequestJson);
        Assert.Null(api.LastCredential);
    }

    [Fact]
    public void EffectiveCapability_RejectsMismatchedRouteOrKey()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Throws<CoreInteropException>(() =>
            client.GetEffectiveCapability(
                "different-route",
                CapabilityKey.Streaming));
    }

    private static void AssertVersionedRequest(
        string json,
        Action<JsonElement> assertPayload)
    {
        using var document = JsonDocument.Parse(json);
        Assert.Equal(
            1u,
            document.RootElement
                .GetProperty("request_schema_version")
                .GetUInt32());
        assertPayload(document.RootElement.GetProperty("payload"));
    }

    private static string CreateDataRoot() =>
        Path.Combine(
            Path.GetTempPath(),
            "lorepia-native-provider-tests",
            Guid.NewGuid().ToString("N"));
}
