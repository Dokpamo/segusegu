using Lorepia.Native.Interop;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace Lorepia.Native.Tests;

internal sealed class FakeNativeApi : INativeApi
{
    internal uint AbiVersion { get; set; } = CoreClient.SupportedAbiVersion;

    internal string Version { get; set; } = "0.1.0-test";

    internal string HealthJson { get; set; } =
        """
        {
          "core_version": "0.1.0-test",
          "database_open": true,
          "schema_version": 3,
          "data_root_writable": true,
          "staging_writable": true,
          "recovery_pending": false,
          "active_jobs": 2
        }
        """;

    internal string CharactersJson { get; set; } =
        """
        [
          {
            "id": "character-1",
            "name": "테스트 캐릭터",
            "description": "합성 테스트 데이터",
            "source_hash": "abc123",
            "avatar_asset_hash": null,
            "created_at": "2026-07-26T00:00:00Z",
            "future_field": "ignored"
          }
        ]
        """;

    internal string InspectionJson { get; set; } =
        """
        {
          "id": "inspection-1",
          "kind": "character_card_v3",
          "display_name": "테스트 캐릭터",
          "description": "합성 테스트 데이터",
          "representative_image": {
            "logical_asset_id": "assets/avatar.png",
            "media_type": "image/png",
            "size_bytes": 70
          },
          "source_sha256": "abc123",
          "source_size": 128,
          "estimated_stored_size": 256,
          "asset_count": 0,
          "warnings": [],
          "blocked_reasons": [],
          "unsupported_optional_fields": [
            "alternate_greetings",
            "creator"
          ]
        }
        """;

    internal string CharacterJson { get; set; } =
        """
        {
          "id": "character-1",
          "name": "테스트 캐릭터",
          "description": "합성 테스트 데이터",
          "source_hash": "abc123",
          "avatar_asset_hash": null,
          "created_at": "2026-07-26T00:00:00Z"
        }
        """;

    internal string ConversationJson { get; set; } =
        """
        {
          "id": "conversation-1",
          "character_id": "character-1",
          "title": "테스트 캐릭터",
          "created_at": "2026-07-26T00:00:00Z",
          "updated_at": "2026-07-26T00:00:00Z"
        }
        """;

    internal string ConversationsJson { get; set; } =
        """
        [
          {
            "id": "conversation-1",
            "character_id": "character-1",
            "title": "테스트 캐릭터",
            "created_at": "2026-07-26T00:00:00Z",
            "updated_at": "2026-07-26T00:00:00Z"
          }
        ]
        """;

    internal string MessagesJson { get; set; } =
        """
        [
          {
            "id": "message-1",
            "conversation_id": "conversation-1",
            "parent_id": null,
            "role": "user",
            "content": "안녕",
            "status": "complete",
            "generation_id": null,
            "created_at": "2026-07-26T00:00:00Z"
          }
        ]
        """;

    internal string GenerationJson { get; set; } = "\"generation-1\"";

    internal string EventsJson { get; set; } =
        """
        {
          "events": [
            {
              "event_version": 4,
              "generation_id": "generation-1",
              "conversation_id": "conversation-1",
              "branch_id": "branch-1",
              "assistant_message_id": "assistant-1",
              "sequence": 1,
              "emitted_at": "2026-07-26T00:00:00Z",
              "kind": {
                "type": "text_delta",
                "payload": "반가워"
              }
            }
          ],
          "dropped_events": 0
        }
        """;

    internal string SettingsJson { get; set; } =
        """
        {
          "preserve_partial_generations": true,
          "selected_provider_profile_id": "provider-1"
        }
        """;

    internal string ProviderProfilesJson { get; set; } =
        """
        [
          {
            "id": "provider-1",
            "display_name": "테스트 공급자",
            "base_url": "https://example.invalid/v1",
            "model": "test-model",
            "timeout_seconds": 30
          }
        ]
        """;

    internal string ProviderProfileJson { get; set; } =
        """
        {
          "id": "provider-1",
          "display_name": "테스트 공급자",
          "base_url": "https://example.invalid/v1",
          "model": "test-model",
          "timeout_seconds": 30
        }
        """;

    internal string ProviderTemplatesJson { get; set; } =
        """
        [
          {
            "id": "openai-chat-compatible-v1",
            "display_name": "OpenAI compatible",
            "manifest_version": 1,
            "source": "built_in",
            "api_family": "openai_chat_completions",
            "default_api_origin": "https://api.example.invalid",
            "default_network_mode": "public",
            "requires_credential": true,
            "auth_binding": {"kind":"bearer_header"},
            "supports_model_listing": true,
            "connection_fields": [],
            "parameter_specs": []
          }
        ]
        """;

    internal string ProviderConnectionJson { get; set; } =
        """
        {
          "id": "connection-1",
          "template_id": "openai-chat-compatible-v1",
          "template_version": 1,
          "display_name": "테스트 연결",
          "api_origin": "https://api.example.invalid",
          "api_base_path": "/v1",
          "network_mode": "public",
          "values": [],
          "credential_slot_required": true,
          "credential_ref": "connection-1",
          "auth_binding": {"kind":"bearer_header"},
          "approved_credential_origins": ["https://api.example.invalid"],
          "credential_redirect_policy": "deny",
          "timeout_seconds": 30,
          "status": "untested",
          "created_at": "2026-07-31T00:00:00Z",
          "updated_at": "2026-07-31T00:00:00Z"
        }
        """;

    internal string ProviderConnectionsJson =>
        $"[{ProviderConnectionJson}]";

    internal string ModelRouteJson { get; set; } =
        """
        {
          "id": "route-1",
          "connection_id": "connection-1",
          "api_family": "openai_chat_completions",
          "model_id": "model-1",
          "display_name": "Model One",
          "route_config": {
            "deployment_id": null,
            "region": null,
            "endpoint_path": null,
            "values": []
          },
          "availability": "available",
          "miss_count": 0,
          "raw_metadata_json": "{\"owned\":true}",
          "metadata_source": "provider_api",
          "metadata_observed_at": "2026-07-31T00:00:00Z",
          "last_reconciled_sync_job_id": "sync-1",
          "metadata_sync_job_id": "sync-1",
          "first_seen_at": "2026-07-31T00:00:00Z",
          "last_seen_at": "2026-07-31T00:00:00Z"
        }
        """;

    internal string? ModelRoutesJsonOverride { get; set; }

    internal string ModelRoutesJson =>
        ModelRoutesJsonOverride ?? $"[{ModelRouteJson}]";

    internal string CapabilityObservationJson { get; set; } =
        """
        {
          "id": "observation-1",
          "model_route_id": "route-1",
          "key": "streaming",
          "value": {"type":"boolean","value":true},
          "status": "verified",
          "source": "user_override",
          "confidence": "high",
          "observed_at": "2026-07-31T00:00:00Z",
          "expires_at": null,
          "evidence_ref": null
        }
        """;

    internal string CapabilityObservationsJson =>
        $"[{CapabilityObservationJson}]";

    internal string EffectiveCapabilityJson { get; set; } =
        """
        {
          "selected": {
            "id": "observation-1",
            "model_route_id": "route-1",
            "key": "streaming",
            "value": {"type":"boolean","value":true},
            "status": "verified",
            "source": "user_override",
            "confidence": "high",
            "observed_at": "2026-07-31T00:00:00Z",
            "expires_at": null,
            "evidence_ref": null
          },
          "alternatives": [],
          "evaluated_at": "2026-07-31T00:00:01Z",
          "selected_is_stale": false,
          "has_conflict": false
        }
        """;

    internal string EffectiveParameterSpecsJson { get; set; } =
        """
        [
          {
            "id": "temperature",
            "label_key": "provider.parameter.temperature",
            "description_key": "provider.parameter.temperature.description",
            "value_type": "number",
            "allowed_values": [],
            "minimum": 0.0,
            "maximum": 2.0,
            "step": 0.1,
            "default_mode": "provider_default",
            "visibility": null,
            "conflicts": [],
            "provider_mapping": {
              "target": "request_body",
              "field_name": "temperature"
            },
            "level": "basic"
          }
        ]
        """;

    internal string ProviderCurlInspectionJson { get; set; } =
        """
        {
          "inspection_schema_version": 1,
          "sanitized_site_url": "https://console.example.invalid/docs",
          "api_origin": "https://api.example.invalid",
          "method": "POST",
          "path": "/v1/chat/completions",
          "header_names": ["authorization", "content-type"],
          "auth_binding_hint": {"kind":"bearer_header"},
          "api_family_hint": "openai_chat_completions",
          "model_hint": "test-model",
          "stream_hint": true,
          "redacted_curl": "curl -H 'authorization: [REDACTED]'",
          "credential_present": true
        }
        """;

    internal string ExtractedCurlCredential { get; set; } =
        "curl-secret";

    internal string ProviderDiscoverySnapshotJson { get; set; } =
        """
        {
          "snapshot_schema_version": 3,
          "session_id": "discovery-1",
          "pending_connection_id": "connection-1",
          "pending_display_name": "Synthetic provider",
          "connection_options": {
            "values": [],
            "api_base_path": "/v1",
            "timeout_seconds": 60,
            "network_mode": "public",
            "local_network_approval": null
          },
          "credential_slot_id": "connection-1",
          "credential_slot_expected": true,
          "revision": 2,
          "state": "awaiting_template_selection",
          "next_event_sequence": 3,
          "steps": [
            {"id":"provider","title_key":"provider","state":"current"},
            {"id":"documents","title_key":"documents","state":"pending"}
          ],
          "action_required": {"kind":"select_template"},
          "active_operation_id": null,
          "recovery_operation": null,
          "unknown_operation": null,
          "manifest_sha256": null,
          "commit_plan_sha256": null,
          "commit_attempt_id": null,
          "committed_connection_id": null,
          "cancellation_pending": false,
          "failure": null,
          "candidates": [
            {
              "id":"candidate-1",
              "proposed_revision":2,
              "summary":{
                "kind":"provider_template",
                "template_id":"openai-chat-compatible-v1",
                "template_version":1
              },
              "evidence_ids":[],
              "created_at":"2026-07-31T00:00:00Z"
            }
          ],
          "evidence": [],
          "approvals": [],
          "review": null,
          "approval_proposal": null,
          "review_proposal": null,
          "assistant_resume_boundary": null,
          "created_at": "2026-07-31T00:00:00Z",
          "updated_at": "2026-07-31T00:00:01Z"
        }
        """;

    internal string ProviderDiscoveryAssistantHostActionJson { get; set; } =
        """
        {
          "kind": "request_more_evidence",
          "session_id": "discovery-1",
          "questions": [
            {
              "id": "question-1",
              "field": {"kind":"models_endpoint"},
              "question": "Where is the official models endpoint documented?",
              "required_evidence": "An official documentation URL"
            }
          ]
        }
        """;

    internal string ProviderDiscoveryEventsJson { get; set; } = "[]";

    internal string ProviderDiscoveriesJson { get; set; } = "[]";

    internal string? ProviderDiscoveryCancelSnapshotJson { get; set; }

    internal string ProviderDiscoveryCompensationStepsJson { get; set; } =
        "[]";

    internal string GenerationPresetJson { get; set; } =
        """
        {
          "id": "preset-1",
          "model_route_id": "route-1",
          "display_name": "Balanced",
          "values": [],
          "reasoning": {
            "mode": "provider_default",
            "effort": null,
            "budget_tokens": null,
            "summary": "provider_default",
            "preserve_opaque_state": false
          },
          "prompt_cache": {
            "mode": "provider_default",
            "ttl": {"kind":"provider_default"},
            "context_reference": null
          },
          "created_at": "2026-07-31T00:00:00Z",
          "updated_at": "2026-07-31T00:00:00Z"
        }
        """;

    internal string GenerationPresetsJson => $"[{GenerationPresetJson}]";

    internal string ProviderRequestPreviewJson { get; set; } =
        """
        {
          "redaction_version": 1,
          "preview": {
            "method": "POST",
            "origin": "https://api.example.invalid",
            "path": "/v1/chat/completions",
            "header_names": ["authorization", "content-type"],
            "body": {
              "kind": "object",
              "fields": [
                {"name":"model","shape":{"kind":"string"}},
                {"name":"messages","shape":{"kind":"redacted"}},
                {"name":"stream","shape":{"kind":"boolean"}}
              ],
              "truncated": false
            }
          },
          "includes_private_message": false,
          "includes_credential_value": false,
          "includes_opaque_reasoning_state": false
        }
        """;

    internal string ProviderModelRefreshJson =>
        $$"""
        {
          "connection_id": "connection-1",
          "model_routes": [{{ModelRouteJson}}],
          "newly_seen_model_route_ids": ["route-1"],
          "missing_model_route_ids": [],
          "created_generation_preset_ids": ["preset-1"],
          "routes_requiring_preset_configuration": [],
          "provenance": {
            "source": "provider_api",
            "api_family": "openai_chat_completions",
            "api_origin": "https://api.example.invalid",
            "endpoint_path": "/v1/models"
          },
          "pages_fetched": 1,
          "response_bytes": 128,
          "observed_at": "2026-07-31T00:00:00Z"
        }
        """;

    internal string ModelSyncStartedJson { get; set; } =
        """{"job_id":"sync-1"}""";

    internal string ModelSyncJobJson { get; set; } =
        """
        {
          "id": "sync-1",
          "connection_id": "connection-1",
          "state": "diff-ready-awaiting-review",
          "revision": 3,
          "review": {
            "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "diff": {
              "connection_id": "connection-1",
              "expected_connection": {
                "id": "connection-1",
                "template_id": "openai-chat-compatible-v1",
                "template_version": 1,
                "display_name": "테스트 연결",
                "api_origin": "https://api.example.invalid",
                "config": {
                  "api_base_path": "/v1",
                  "network_mode": "public",
                  "values": []
                },
                "credential_ref": "connection-1",
                "credential_scope": {
                  "allowed_origins": ["https://api.example.invalid"],
                  "auth_binding": {"kind":"bearer_header"},
                  "redirect_policy": "deny"
                },
                "timeout_seconds": 30,
                "status": "untested",
                "created_at": "2026-07-31T00:00:00Z",
                "updated_at": "2026-07-31T00:00:00Z"
              },
              "expected_model_routes": [],
              "observed_at": "2026-07-31T00:00:01Z",
              "listed_routes": [],
              "newly_seen_model_route_ids": [],
              "missing_model_route_ids": [],
              "initial_presets": [],
              "capability_observations": [],
              "routes_requiring_preset_configuration": [],
              "provenance": {
                "source": "provider_api",
                "api_family": "openai_chat_completions",
                "api_origin": "https://api.example.invalid",
                "endpoint_path": "/v1/models",
                "pages_fetched": 1,
                "response_bytes": 128
              }
            }
          },
          "failure": null,
          "created_at": "2026-07-31T00:00:00Z",
          "updated_at": "2026-07-31T00:00:02Z"
        }
        """;

    internal string? ModelSyncJobsJsonOverride { get; set; }

    internal string ModelSyncJobsJson =>
        ModelSyncJobsJsonOverride ?? $"[{ModelSyncJobJson}]";

    internal int StartProviderModelSyncCount { get; private set; }

    internal string ModelSyncEventsJson { get; set; } =
        """
        [
          {
            "version": 1,
            "job_id": "sync-1",
            "sequence": 3,
            "job_revision": 3,
            "redaction_version": 1,
            "state": "diff-ready-awaiting-review",
            "progress": {
              "completed_steps": 2,
              "total_steps": 4,
              "message_key": "model_sync.awaiting_review"
            },
            "review_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "failure": null,
            "emitted_at": "2026-07-31T00:00:02Z"
          }
        ]
        """;

    internal string ProviderCatalogStatusJson { get; set; } =
        """
        {
          "status_schema_version": 1,
          "state_version": 2,
          "active_revision": 2,
          "active_snapshot_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          "bundled_baseline_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
          "snapshot_count": 2,
          "signed_update_count": 1,
          "highest_accepted_revision": 7,
          "latest_issued_at": "2026-07-31T00:00:00Z",
          "active_signed_revisions": [7]
        }
        """;

    internal string ProviderCatalogDiffJson { get; set; } =
        """
        {
          "diff_schema_version": 1,
          "from_revision": 1,
          "to_revision": 2,
          "added_provider_templates": [],
          "changed_provider_templates": [
            {
              "provider_template_id": "openai-chat-compatible-v1",
              "previous_manifest_version": 1,
              "next_manifest_version": 2,
              "previous_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
              "next_sha256": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
              "changed_sections": ["manifest_version"]
            }
          ],
          "removed_provider_templates": [],
          "added_models": [],
          "changed_models": [],
          "removed_models": []
        }
        """;

    internal string ProviderCatalogHistoryJson { get; set; } =
        """
        {
          "history_schema_version": 1,
          "active_revision": 2,
          "revisions": [
            {
              "revision": 2,
              "captured_at": "2026-07-31T00:00:00Z",
              "snapshot_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              "signed_revisions": [7],
              "active": true
            }
          ],
          "activations": [],
          "next_before_revision": null,
          "next_before_state_version": null
        }
        """;

    internal string ProviderCatalogImportJson { get; set; } =
        """
        {
          "signed_catalog_revision": 7,
          "activated_revision": 2,
          "diff": {
            "diff_schema_version": 1,
            "from_revision": 1,
            "to_revision": 2,
            "added_provider_templates": [],
            "changed_provider_templates": [],
            "removed_provider_templates": [],
            "added_models": [],
            "changed_models": [],
            "removed_models": []
          },
          "status": {
            "status_schema_version": 1,
            "state_version": 2,
            "active_revision": 2,
            "active_snapshot_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "bundled_baseline_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "snapshot_count": 2,
            "signed_update_count": 1,
            "highest_accepted_revision": 7,
            "latest_issued_at": "2026-07-31T00:00:00Z",
            "active_signed_revisions": [7]
          }
        }
        """;

    internal string ProviderCatalogImportPlanJson { get; set; } =
        """
        {
          "review": {
            "plan_schema_version": 1,
            "action_id": "catalog-import-1",
            "expected_state_version": 1,
            "expected_active_revision": 1,
            "expected_active_snapshot_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "expected_highest_accepted_revision": 0,
            "envelope_byte_count": __ENVELOPE_BYTE_COUNT__,
            "envelope_sha256": "__ENVELOPE_SHA256__",
            "signing_key_id": "synthetic-test-key",
            "payload_sha256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "signed_catalog_revision": 7,
            "candidate_revision": 2,
            "candidate_snapshot_sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "prepared_at": "2026-07-31T00:00:00Z",
            "expires_at": "2026-07-31T00:15:00Z",
            "diff": {
              "diff_schema_version": 1,
              "from_revision": 1,
              "to_revision": 2,
              "added_provider_templates": [],
              "changed_provider_templates": [],
              "removed_provider_templates": [],
              "added_models": [],
              "changed_models": [],
              "removed_models": []
            }
          },
          "plan_sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          "plan_json": "{\"review\":{\"action_id\":\"catalog-import-1\",\"expected_state_version\":1,\"envelope_byte_count\":__ENVELOPE_BYTE_COUNT__,\"envelope_sha256\":\"__ENVELOPE_SHA256__\",\"candidate_revision\":2},\"plan_sha256\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\"}"
        }
        """;

    internal string ProviderCatalogRollbackPlanJson { get; set; } =
        """
        {
          "plan_schema_version": 1,
          "action_id": "catalog-rollback-1",
          "expected_state_version": 2,
          "plan_sha256": "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
          "from_revision": 2,
          "to_revision": 1,
          "created_at": "2026-07-31T00:00:00Z",
          "expires_at": "2026-07-31T00:15:00Z",
          "diff": {
            "diff_schema_version": 1,
            "from_revision": 2,
            "to_revision": 1,
            "added_provider_templates": [],
            "changed_provider_templates": [],
            "removed_provider_templates": [],
            "added_models": [],
            "changed_models": [],
            "removed_models": []
          },
          "plan_json": "{\"plan_schema_version\":1,\"action_id\":\"catalog-rollback-1\",\"expected_state_version\":2,\"plan_sha256\":\"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\",\"catalog_plan\":{\"from_revision\":2,\"to_revision\":1}}"
        }
        """;

    internal string ProviderCatalogRollbackResultJson { get; set; } =
        """
        {
          "from_revision": 2,
          "activated_revision": 1,
          "status": {
            "status_schema_version": 1,
            "state_version": 3,
            "active_revision": 1,
            "active_snapshot_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "bundled_baseline_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "snapshot_count": 2,
            "signed_update_count": 1,
            "highest_accepted_revision": 7,
            "latest_issued_at": "2026-07-31T00:00:00Z",
            "active_signed_revisions": []
          }
        }
        """;

    internal string? ConfigurationJson { get; private set; }

    internal string? LastStagedPath { get; private set; }

    internal string? LastInspectionId { get; private set; }

    internal string? LastConversationId { get; private set; }

    internal string? LastSentText { get; private set; }

    internal string? LastProviderProfileId { get; private set; }

    internal string? LastCredential { get; private set; }

    internal string? LastSettingsJson { get; private set; }

    internal string? LastProfileJson { get; private set; }

    internal string? LastDeletedProfileId { get; private set; }

    internal string? LastTargetRequestJson { get; private set; }

    internal string? LastContractRequestJson { get; private set; }

    internal string? LastUpsertGenerationPresetRequestJson { get; private set; }

    internal string? LastPreviewProviderRequestCandidateJson
    {
        get;
        private set;
    }

    internal string? LastContractOperation { get; private set; }

    internal string? LastConnectionId { get; private set; }

    internal string? LastModelRouteId { get; private set; }

    internal string? LastRefreshCredential { get; private set; }

    internal string? LastModelSyncCredential { get; private set; }

    internal string? LastProviderDiscoveryRawCurl { get; private set; }

    internal string? LastBeginProviderDiscoveryRequestJson { get; private set; }

    internal string? LastContinueProviderDiscoveryRequestJson
    {
        get;
        private set;
    }

    internal string? LastProviderCurlInspectionRequestJson { get; private set; }

    internal string? LastProviderDiscoveryCredential { get; private set; }

    internal string? LastAckedProviderDiscoveryEventId { get; private set; }

    internal string? LastCatalogEnvelopeJson { get; private set; }

    internal uint LastMaxEvents { get; private set; }

    internal uint LastModelSyncMaxEvents { get; private set; }

    internal string? LastModelSyncEventJobId { get; private set; }

    internal ulong LastAckedModelSyncSequence { get; private set; }

    internal int DiscardCount { get; private set; }

    internal int CancelCount { get; private set; }

    internal int PollEventsCount { get; private set; }

    internal int CreateCount { get; private set; }

    internal int DestroyCount { get; private set; }

    internal int BufferFreeCount { get; private set; }

    internal int ValidateGenerationPresetCount { get; private set; }

    internal Exception? ValidateGenerationPresetException { get; set; }

    internal int ValidateGenerationPresetCandidateCount { get; private set; }

    internal int RunProviderDiscoveryAssistantTurnCount { get; private set; }

    internal int CreateProviderConnectionCount { get; private set; }

    internal int StartProviderDiscoveryCredentialCompensationCount
    {
        get;
        private set;
    }

    internal int GetProviderDiscoveryCount { get; private set; }

    internal int GetProviderModelSyncCount { get; private set; }

    internal Exception? ValidateGenerationPresetCandidateException
    {
        get;
        set;
    }

    internal Exception? UpsertProviderConnectionException
    {
        get;
        set;
    }

    internal string ReasoningControlJson { get; set; } =
        """
        {
          "state": "ready",
          "settings": {
            "mode": "provider_default",
            "effort": null,
            "budget_tokens": null,
            "summary": "provider_default",
            "preserve_opaque_state": false
          },
          "allowed_modes": ["provider_default", "automatic"],
          "allowed_efforts": ["low", "medium", "high"],
          "allowed_summaries": ["provider_default", "concise"],
          "budget_bounds": {"minimum": 128, "maximum": 8192},
          "effort_field": "enabled",
          "budget_field": "enabled",
          "summary_field": "enabled",
          "issues": []
        }
        """;

    internal string PromptCacheControlJson { get; set; } =
        """
        {
          "state": "ready",
          "settings": {
            "mode": "provider_default",
            "ttl": {"kind": "provider_default"},
            "context_reference": null
          },
          "allowed_modes": ["provider_default", "automatic"],
          "allowed_ttls": [
            {"kind": "provider_default"},
            {"kind": "short"}
          ],
          "supports_custom_ttl": true,
          "custom_ttl_bounds": {
            "minimum_seconds": 60,
            "maximum_seconds": 3600
          },
          "ttl_field": "enabled",
          "context_reference_field": "hidden",
          "issues": []
        }
        """;

    internal Action? BeforeGetCoreVersion { get; set; }

    internal Action? BeforeGetConversations { get; set; }

    internal Action? BeforeSendMessageWithTarget { get; set; }

    internal Action? BeforePollEvents { get; set; }

    internal Action? BeforeCreateProviderConnection { get; set; }

    internal Action? BeforeBeginProviderDiscovery { get; set; }

    internal Action? BeforeGetProviderDiscovery { get; set; }

    internal Action? BeforeListProviderDiscoveries { get; set; }

    internal Action? BeforeStartProviderModelSync { get; set; }

    internal Action? BeforeCompleteProviderDiscoveryCompensation
    {
        get;
        set;
    }

    internal Action? BeforeGetProviderModelSync { get; set; }

    internal Action? BeforeCancelProviderModelSync { get; set; }

    public uint GetAbiVersion() => AbiVersion;

    public SafeCoreHandle CreateCore(byte[] configurationJson)
    {
        ArgumentNullException.ThrowIfNull(configurationJson);
        CreateCount++;
        ConfigurationJson = Encoding.UTF8.GetString(configurationJson);
        return new SafeCoreHandle(
            new IntPtr(0x1234),
            _ => DestroyCount++);
    }

    public NativeBuffer GetCoreVersion(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        BeforeGetCoreVersion?.Invoke();
        return CreateBuffer(Version);
    }

    public NativeBuffer GetHealthCheckJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(HealthJson);
    }

    public NativeBuffer GetCharactersJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(CharactersJson);
    }

    public NativeBuffer InspectImportJson(
        SafeCoreHandle core,
        byte[] stagedPath)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastStagedPath = Decode(stagedPath);
        return CreateBuffer(InspectionJson);
    }

    public NativeBuffer CommitImportJson(
        SafeCoreHandle core,
        byte[] inspectionId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastInspectionId = Decode(inspectionId);
        return CreateBuffer(CharacterJson);
    }

    public void DiscardImport(
        SafeCoreHandle core,
        byte[] inspectionId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastInspectionId = Decode(inspectionId);
        DiscardCount++;
    }

    public NativeBuffer GetCharacterJson(
        SafeCoreHandle core,
        byte[] characterId)
    {
        ArgumentNullException.ThrowIfNull(core);
        _ = Decode(characterId);
        return CreateBuffer(CharacterJson);
    }

    public NativeBuffer OpenConversationJson(
        SafeCoreHandle core,
        byte[] characterId)
    {
        ArgumentNullException.ThrowIfNull(core);
        _ = Decode(characterId);
        return CreateBuffer(ConversationJson);
    }

    public NativeBuffer GetConversationsJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        BeforeGetConversations?.Invoke();
        return CreateBuffer(ConversationsJson);
    }

    public NativeBuffer GetMessagesJson(
        SafeCoreHandle core,
        byte[] conversationId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastConversationId = Decode(conversationId);
        return CreateBuffer(MessagesJson);
    }

    public NativeBuffer SendMessageJson(
        SafeCoreHandle core,
        byte[] conversationId,
        byte[] text,
        byte[] providerProfileId,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastConversationId = Decode(conversationId);
        LastSentText = Decode(text);
        LastProviderProfileId = Decode(providerProfileId);
        LastCredential = credential is null ? null : Decode(credential);
        return CreateBuffer(GenerationJson);
    }

    public NativeBuffer SendMessageWithTargetJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        BeforeSendMessageWithTarget?.Invoke();
        LastTargetRequestJson = Decode(requestJson);
        LastCredential = credential is null ? null : Decode(credential);
        return CreateBuffer(GenerationJson);
    }

    public void CancelGeneration(
        SafeCoreHandle core,
        byte[] generationId)
    {
        ArgumentNullException.ThrowIfNull(core);
        _ = Decode(generationId);
        CancelCount++;
    }

    public NativeBuffer PollEventsJson(
        SafeCoreHandle core,
        uint maxEvents)
    {
        ArgumentNullException.ThrowIfNull(core);
        PollEventsCount++;
        BeforePollEvents?.Invoke();
        LastMaxEvents = maxEvents;
        return CreateBuffer(EventsJson);
    }

    public NativeBuffer GetSettingsJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(SettingsJson);
    }

    public void UpdateSettingsJson(
        SafeCoreHandle core,
        byte[] settingsJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastSettingsJson = Decode(settingsJson);
    }

    public NativeBuffer GetProviderTemplatesJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(ProviderTemplatesJson);
    }

    public NativeBuffer CreateProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("create_provider_connection", requestJson);
        CreateProviderConnectionCount++;
        BeforeCreateProviderConnection?.Invoke();
        using var request = JsonDocument.Parse(requestJson);
        var requestedId = request.RootElement
            .GetProperty("payload")
            .GetProperty("id")
            .GetString();
        return CreateBuffer(
            requestedId is { Length: > 0 }
                ? ProviderConnectionJson.Replace(
                    "connection-1",
                    requestedId,
                    StringComparison.Ordinal)
                : ProviderConnectionJson);
    }

    public NativeBuffer GetProviderConnectionsJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(ProviderConnectionsJson);
    }

    public NativeBuffer UpsertProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("upsert_provider_connection", requestJson);
        if (UpsertProviderConnectionException is { } exception)
        {
            throw exception;
        }
        return CreateBuffer(ProviderConnectionJson);
    }

    public void DeleteProviderConnectionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("delete_provider_connection", requestJson);
    }

    public NativeBuffer GetModelRoutesJson(
        SafeCoreHandle core,
        byte[] connectionId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastConnectionId = Decode(connectionId);
        return CreateBuffer(ModelRoutesJson);
    }

    public NativeBuffer UpsertModelRouteJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("upsert_model_route", requestJson);
        return CreateBuffer(ModelRouteJson);
    }

    public void DeleteModelRouteJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("delete_model_route", requestJson);
    }

    public NativeBuffer GetCapabilityObservationsJson(
        SafeCoreHandle core,
        byte[] modelRouteId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastModelRouteId = Decode(modelRouteId);
        return CreateBuffer(CapabilityObservationsJson);
    }

    public NativeBuffer GetEffectiveCapabilityJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "get_effective_capability",
            requestJson,
            trackOperation: false);
        if (!string.Equals(
                EffectiveCapabilityJson.Trim(),
                "null",
                StringComparison.Ordinal))
        {
            using var request = JsonDocument.Parse(requestJson);
            using var response =
                JsonDocument.Parse(EffectiveCapabilityJson);
            var requestedKey = request.RootElement
                .GetProperty("payload")
                .GetProperty("key")
                .GetString();
            var selectedKey = response.RootElement
                .GetProperty("selected")
                .GetProperty("key")
                .GetString();
            if (!string.Equals(
                    requestedKey,
                    selectedKey,
                    StringComparison.Ordinal))
            {
                return CreateBuffer("null");
            }
        }

        return CreateBuffer(EffectiveCapabilityJson);
    }

    public NativeBuffer GetEffectiveParameterSpecsJson(
        SafeCoreHandle core,
        byte[] modelRouteId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastModelRouteId = Decode(modelRouteId);
        return CreateBuffer(EffectiveParameterSpecsJson);
    }

    public NativeBuffer UpsertUserCapabilityOverrideJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("upsert_user_capability_override", requestJson);
        return CreateBuffer(CapabilityObservationJson);
    }

    public void DeleteUserCapabilityOverrideJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("delete_user_capability_override", requestJson);
    }

    public NativeBuffer RefreshProviderModelsJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("refresh_provider_models", requestJson);
        LastRefreshCredential = credential is null ? null : Decode(credential);
        return CreateBuffer(ProviderModelRefreshJson);
    }

    public NativeBuffer StartProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        StartProviderModelSyncCount++;
        RecordContractRequest("start_provider_model_sync", requestJson);
        LastModelSyncCredential =
            credential is null ? null : Decode(credential);
        BeforeStartProviderModelSync?.Invoke();
        return CreateBuffer(ModelSyncStartedJson);
    }

    public NativeBuffer GetProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "get_provider_model_sync",
            requestJson,
            trackOperation: false);
        GetProviderModelSyncCount++;
        BeforeGetProviderModelSync?.Invoke();
        return CreateBuffer(ModelSyncJobJson);
    }

    public NativeBuffer ListProviderModelSyncsJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "list_provider_model_syncs",
            requestJson,
            trackOperation: false);
        return CreateBuffer(ModelSyncJobsJson);
    }

    public NativeBuffer ApproveProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("approve_provider_model_sync", requestJson);
        return CreateBuffer(ModelSyncJobJson);
    }

    public NativeBuffer CancelProviderModelSyncJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("cancel_provider_model_sync", requestJson);
        BeforeCancelProviderModelSync?.Invoke();
        return CreateBuffer(ModelSyncJobJson);
    }

    public NativeBuffer PollProviderModelSyncJobEventsJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "poll_provider_model_sync_job_events",
            requestJson,
            trackOperation: false);
        using var request = JsonDocument.Parse(requestJson);
        var payload =
            request.RootElement.GetProperty("payload");
        LastModelSyncEventJobId =
            payload.GetProperty("job_id").GetString();
        LastModelSyncMaxEvents =
            payload.GetProperty("limit").GetUInt32();
        return CreateBuffer(ModelSyncEventsJson);
    }

    public NativeBuffer AckProviderModelSyncEventJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "ack_provider_model_sync_event",
            requestJson,
            trackOperation: false);
        using var request = JsonDocument.Parse(requestJson);
        var payload =
            request.RootElement.GetProperty("payload");
        LastModelSyncEventJobId =
            payload.GetProperty("job_id").GetString();
        LastAckedModelSyncSequence =
            payload.GetProperty("sequence").GetUInt64();
        return CreateBuffer("true");
    }

    public (NativeBuffer Metadata, NativeBuffer Credential)
        InspectProviderCurlJson(
            SafeCoreHandle core,
            byte[] requestJson,
            byte[] rawCurl)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "inspect_provider_curl",
            requestJson);
        LastProviderCurlInspectionRequestJson =
            Decode(requestJson);
        LastProviderDiscoveryRawCurl = Decode(rawCurl);
        return (
            CreateBuffer(ProviderCurlInspectionJson),
            CreateBuffer(ExtractedCurlCredential));
    }

    public NativeBuffer BeginProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? rawCurl)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "begin_provider_discovery",
            requestJson);
        BeforeBeginProviderDiscovery?.Invoke();
        LastBeginProviderDiscoveryRequestJson =
            Decode(requestJson);
        LastProviderDiscoveryRawCurl =
            rawCurl is null ? null : Decode(rawCurl);
        using var request = JsonDocument.Parse(requestJson);
        var connectionId = request.RootElement
            .GetProperty("payload")
            .GetProperty("input")
            .GetProperty("connection_id")
            .GetString();
        if (connectionId is { Length: > 0 })
        {
            ProviderDiscoverySnapshotJson =
                ProviderDiscoverySnapshotJson.Replace(
                    "connection-1",
                    connectionId,
                    StringComparison.Ordinal);
        }
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer PrepareProviderDiscoveryActionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "prepare_provider_discovery_action",
            requestJson);
        using var request = JsonDocument.Parse(requestJson);
        var payload =
            request.RootElement.GetProperty("payload");
        return CreateBuffer(JsonSerializer.Serialize(new
        {
            action_id =
                payload.GetProperty("action_id").GetString(),
            expected_revision =
                payload.GetProperty("expected_revision").GetUInt64(),
            request_sha256 = new string('a', 64),
            action = payload.GetProperty("action"),
        }));
    }

    public NativeBuffer GetProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "get_provider_discovery",
            requestJson,
            trackOperation: false);
        GetProviderDiscoveryCount++;
        BeforeGetProviderDiscovery?.Invoke();
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer ListProviderDiscoveriesJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "list_provider_discoveries",
            requestJson,
            trackOperation: false);
        BeforeListProviderDiscoveries?.Invoke();
        return CreateBuffer(ProviderDiscoveriesJson);
    }

    public NativeBuffer ListProviderDiscoveryCandidatesJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        DiscoverySnapshotProperty(
            core,
            requestJson,
            "list_provider_discovery_candidates",
            "candidates");

    public NativeBuffer ListProviderDiscoveryEvidenceJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        DiscoverySnapshotProperty(
            core,
            requestJson,
            "list_provider_discovery_evidence",
            "evidence");

    public NativeBuffer ListProviderDiscoveryApprovalsJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        DiscoverySnapshotProperty(
            core,
            requestJson,
            "list_provider_discovery_approvals",
            "approvals");

    public NativeBuffer GetProviderDiscoveryReviewJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        DiscoverySnapshotProperty(
            core,
            requestJson,
            "get_provider_discovery_review",
            "review");

    public NativeBuffer GetProviderDiscoveryApprovalProposalJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        DiscoverySnapshotProperty(
            core,
            requestJson,
            "get_provider_discovery_approval_proposal",
            "approval_proposal");

    public NativeBuffer GetProviderDiscoveryReviewProposalJson(
        SafeCoreHandle core,
        byte[] requestJson) =>
        DiscoverySnapshotProperty(
            core,
            requestJson,
            "get_provider_discovery_review_proposal",
            "review_proposal");

    public NativeBuffer ContinueProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "continue_provider_discovery",
            requestJson);
        LastContinueProviderDiscoveryRequestJson =
            Decode(requestJson);
        LastProviderDiscoveryCredential =
            credential is null ? null : Decode(credential);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer SupplyProviderDiscoveryEvidenceJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? rawCurl)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "supply_provider_discovery_evidence",
            requestJson);
        LastProviderDiscoveryRawCurl =
            rawCurl is null ? null : Decode(rawCurl);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer CancelProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "cancel_provider_discovery",
            requestJson);
        return CreateBuffer(
            ProviderDiscoveryCancelSnapshotJson
            ?? ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer CommitProviderDiscoveryJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "commit_provider_discovery",
            requestJson);
        using var snapshot =
            JsonDocument.Parse(ProviderDiscoverySnapshotJson);
        var connectionId = snapshot.RootElement
            .GetProperty("pending_connection_id")
            .GetString();
        return CreateBuffer(
            connectionId is { Length: > 0 }
                ? ProviderConnectionJson.Replace(
                    "connection-1",
                    connectionId,
                    StringComparison.Ordinal)
                : ProviderConnectionJson);
    }

    public NativeBuffer RecoverProviderDiscoveriesJson(
        SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer("[]");
    }

    public NativeBuffer PollProviderDiscoveryEventsJson(
        SafeCoreHandle core,
        uint maxEvents)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastMaxEvents = maxEvents;
        return CreateBuffer(ProviderDiscoveryEventsJson);
    }

    public NativeBuffer AckProviderDiscoveryEventJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "ack_provider_discovery_event",
            requestJson,
            trackOperation: false);
        using var request = JsonDocument.Parse(requestJson);
        LastAckedProviderDiscoveryEventId =
            request.RootElement
                .GetProperty("payload")
                .GetProperty("event_id")
                .GetString();
        return CreateBuffer("true");
    }

    public NativeBuffer ListProviderDiscoveryCompensationStepsJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "list_provider_discovery_compensation_steps",
            requestJson,
            trackOperation: false);
        return CreateBuffer(
            ProviderDiscoveryCompensationStepsJson);
    }

    public NativeBuffer StartProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "start_provider_discovery_credential_compensation",
            requestJson);
        StartProviderDiscoveryCredentialCompensationCount++;
        using var steps =
            JsonDocument.Parse(
                ProviderDiscoveryCompensationStepsJson);
        return CreateBuffer(
            steps.RootElement.GetArrayLength() == 0
                ? "{}"
                : steps.RootElement[0].GetRawText());
    }

    public NativeBuffer CompleteProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "complete_provider_discovery_credential_compensation",
            requestJson);
        BeforeCompleteProviderDiscoveryCompensation?.Invoke();
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer FailProviderDiscoveryCredentialCompensationJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "fail_provider_discovery_credential_compensation",
            requestJson);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer MarkProviderDiscoveryCredentialCompensationUnknownJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "mark_provider_discovery_credential_compensation_unknown",
            requestJson);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer RunProviderDiscoveryAssistantTurnJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[]? credential)
    {
        ArgumentNullException.ThrowIfNull(core);
        RunProviderDiscoveryAssistantTurnCount++;
        RecordContractRequest(
            "run_provider_discovery_assistant_turn",
            requestJson);
        LastProviderDiscoveryCredential =
            credential is null ? null : Decode(credential);
        return CreateBuffer(
            ProviderDiscoveryAssistantHostActionJson);
    }

    public NativeBuffer ResumeProviderDiscoveryAssistantCoreHostActionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "resume_provider_discovery_assistant_core_host_action",
            requestJson);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer ApproveProviderDiscoveryAssistantRetryJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "approve_provider_discovery_assistant_retry",
            requestJson);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer RequestProviderDiscoveryAssistantRevisionJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "request_provider_discovery_assistant_revision",
            requestJson);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer AcceptProviderDiscoveryAssistantDraftJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "accept_provider_discovery_assistant_draft",
            requestJson);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer RecordProviderDiscoveryAssistantFailureJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "record_provider_discovery_assistant_failure",
            requestJson);
        return CreateBuffer(ProviderDiscoverySnapshotJson);
    }

    public NativeBuffer GetProviderCatalogStatusJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(ProviderCatalogStatusJson);
    }

    public NativeBuffer GetProviderCatalogHistoryJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "provider_catalog_history",
            requestJson,
            trackOperation: false);
        return CreateBuffer(ProviderCatalogHistoryJson);
    }

    public NativeBuffer PrepareSignedProviderCatalogImportJson(
        SafeCoreHandle core,
        byte[] envelopeJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastContractOperation =
            "prepare_signed_provider_catalog_import";
        LastCatalogEnvelopeJson = Decode(envelopeJson);
        var envelopeSha256 = Convert.ToHexString(
                System.Security.Cryptography.SHA256.HashData(envelopeJson))
            .ToLowerInvariant();
        var planJson = ProviderCatalogImportPlanJson
            .Replace(
                "__ENVELOPE_SHA256__",
                envelopeSha256,
                StringComparison.Ordinal)
            .Replace(
                "__ENVELOPE_BYTE_COUNT__",
                envelopeJson.Length.ToString(
                    System.Globalization.CultureInfo.InvariantCulture),
                StringComparison.Ordinal);
        return CreateBuffer(planJson);
    }

    public NativeBuffer ActivateSignedProviderCatalogImportJson(
        SafeCoreHandle core,
        byte[] requestJson,
        byte[] envelopeJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "activate_signed_provider_catalog_import",
            requestJson);
        LastCatalogEnvelopeJson = Decode(envelopeJson);
        return CreateBuffer(ProviderCatalogImportJson);
    }

    public NativeBuffer DiffProviderCatalogRevisionsJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "diff_provider_catalog_revisions",
            requestJson);
        return CreateBuffer(ProviderCatalogDiffJson);
    }

    public NativeBuffer PrepareProviderCatalogRollbackJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "prepare_provider_catalog_rollback",
            requestJson);
        return CreateBuffer(ProviderCatalogRollbackPlanJson);
    }

    public NativeBuffer ActivateProviderCatalogRollbackJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "activate_provider_catalog_rollback",
            requestJson);
        return CreateBuffer(ProviderCatalogRollbackResultJson);
    }

    public NativeBuffer GetGenerationPresetsJson(
        SafeCoreHandle core,
        byte[] modelRouteId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastModelRouteId = Decode(modelRouteId);
        return CreateBuffer(GenerationPresetsJson);
    }

    public NativeBuffer UpsertGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastUpsertGenerationPresetRequestJson = Decode(requestJson);
        RecordContractRequest("upsert_generation_preset", requestJson);
        return CreateBuffer(GenerationPresetJson);
    }

    public void ValidateGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ValidateGenerationPresetCount++;
        RecordContractRequest("validate_generation_preset", requestJson);
        if (ValidateGenerationPresetException is { } exception)
        {
            throw exception;
        }
    }

    public void ValidateGenerationPresetCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        ValidateGenerationPresetCandidateCount++;
        RecordContractRequest(
            "validate_generation_preset_candidate",
            requestJson);
        if (ValidateGenerationPresetCandidateException is { } exception)
        {
            throw exception;
        }
    }

    public NativeBuffer RenderReasoningControlCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "render_reasoning_control_candidate",
            requestJson);
        return CreateBuffer(ReasoningControlJson);
    }

    public NativeBuffer RenderPromptCacheControlCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            "render_prompt_cache_control_candidate",
            requestJson);
        return CreateBuffer(PromptCacheControlJson);
    }

    public NativeBuffer PreviewProviderRequestJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("preview_provider_request", requestJson);
        return CreateBuffer(ProviderRequestPreviewJson);
    }

    public NativeBuffer PreviewProviderRequestCandidateJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastPreviewProviderRequestCandidateJson =
            Decode(requestJson);
        RecordContractRequest(
            "preview_provider_request_candidate",
            requestJson);
        return CreateBuffer(ProviderRequestPreviewJson);
    }

    public void DeleteGenerationPresetJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("delete_generation_preset", requestJson);
    }

    public NativeBuffer SelectGenerationTargetJson(
        SafeCoreHandle core,
        byte[] requestJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest("select_generation_target", requestJson);
        return CreateBuffer(SettingsJson);
    }

    public NativeBuffer GetProviderProfilesJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);
        return CreateBuffer(ProviderProfilesJson);
    }

    public NativeBuffer UpsertProviderProfileJson(
        SafeCoreHandle core,
        byte[] profileJson)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastProfileJson = Decode(profileJson);
        return CreateBuffer(ProviderProfileJson);
    }

    public void DeleteProviderProfile(
        SafeCoreHandle core,
        byte[] profileId)
    {
        ArgumentNullException.ThrowIfNull(core);
        LastDeletedProfileId = Decode(profileId);
    }

    private NativeBuffer DiscoverySnapshotProperty(
        SafeCoreHandle core,
        byte[] requestJson,
        string operation,
        string property)
    {
        ArgumentNullException.ThrowIfNull(core);
        RecordContractRequest(
            operation,
            requestJson,
            trackOperation: false);
        using var snapshot =
            JsonDocument.Parse(ProviderDiscoverySnapshotJson);
        return CreateBuffer(
            snapshot.RootElement
                .GetProperty(property)
                .GetRawText());
    }

    private void RecordContractRequest(
        string operation,
        byte[] requestJson,
        bool trackOperation = true)
    {
        if (trackOperation)
        {
            LastContractOperation = operation;
        }
        LastContractRequestJson = Decode(requestJson);
    }

    private NativeBuffer CreateBuffer(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        if (bytes.Length > 0)
        {
            Marshal.Copy(bytes, 0, pointer, bytes.Length);
        }

        return new NativeBuffer(
            new NativeBufferValue(pointer, checked((nuint)bytes.Length)),
            value =>
            {
                BufferFreeCount++;
                Marshal.FreeHGlobal(value.Pointer);
            });
    }

    private static string Decode(byte[] bytes) =>
        Encoding.UTF8.GetString(bytes);
}
