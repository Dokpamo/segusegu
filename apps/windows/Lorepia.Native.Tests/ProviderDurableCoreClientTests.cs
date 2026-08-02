using System.Text.Json;

namespace Lorepia.Native.Tests;

public sealed class ProviderDurableCoreClientTests
{
    private const string ReviewSha256 =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    [Fact]
    public void MapsDurableModelSyncStartReviewApprovalCancelAndEvents()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        const string credential = "synthetic-sync-credential";
        var started = client.StartProviderModelSync(
            "connection-1",
            credential);
        Assert.Equal("sync-1", started.JobId);
        Assert.Equal(credential, api.LastModelSyncCredential);
        Assert.DoesNotContain(credential, api.LastContractRequestJson);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload => Assert.Equal(
                "connection-1",
                payload.GetProperty("connection_id").GetString()));

        var job = client.GetProviderModelSync(started.JobId);
        Assert.Equal(ModelSyncStates.DiffReadyAwaitingReview, job.State);
        Assert.Equal(3UL, job.Revision);
        Assert.NotNull(job.Review);
        Assert.Equal(ReviewSha256, job.Review.Sha256);
        Assert.Equal(
            "connection-1",
            job.Review.Diff.ExpectedConnection.CredentialRef);
        Assert.Equal(
            ProviderApiFamily.OpenaiChatCompletions,
            job.Review.Diff.Provenance.ApiFamily);

        var listed = Assert.Single(
            client.ListProviderModelSyncs("connection-1", 16));
        Assert.Equal(job.Id, listed.Id);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "connection-1",
                    payload.GetProperty("connection_id").GetString());
                Assert.Equal(16u, payload.GetProperty("limit").GetUInt32());
            });

        var approved = client.ApproveProviderModelSync(
            job.Id,
            job.Review.Sha256);
        Assert.Equal(job.Id, approved.Id);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload => Assert.Equal(
                ReviewSha256,
                payload.GetProperty("review_sha256").GetString()));

        var cancelled = client.CancelProviderModelSync(job.Id);
        Assert.Equal(job.Id, cancelled.Id);
        Assert.Equal(
            "cancel_provider_model_sync",
            api.LastContractOperation);

        var modelSyncEvent = Assert.Single(
            client.PollProviderModelSyncEvents(
                job.Id,
                64));
        Assert.Equal(64u, api.LastModelSyncMaxEvents);
        Assert.Equal(job.Id, api.LastModelSyncEventJobId);
        Assert.Equal(1u, modelSyncEvent.Version);
        Assert.Equal(1u, modelSyncEvent.RedactionVersion);
        Assert.Equal(job.Id, modelSyncEvent.JobId);
        Assert.Equal(
            ModelSyncStates.DiffReadyAwaitingReview,
            modelSyncEvent.State);
        Assert.Equal(ReviewSha256, modelSyncEvent.ReviewSha256);
        Assert.True(
            client.AckProviderModelSyncEvent(
                job.Id,
                modelSyncEvent.Sequence));
        Assert.Equal(
            modelSyncEvent.Sequence,
            api.LastAckedModelSyncSequence);
    }

    [Fact]
    public void MapsSignedCatalogStatusHistoryImportDiffAndRollback()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        var status = client.GetProviderCatalogStatus();
        Assert.Equal(2UL, status.ActiveRevision);
        Assert.Equal(7UL, status.HighestAcceptedRevision);
        Assert.Equal(new ulong[] { 7 }, status.ActiveSignedRevisions);

        var history = client.GetProviderCatalogHistory(
            limit: 25,
            beforeRevision: 9,
            beforeStateVersion: 8);
        Assert.Equal(2UL, history.ActiveRevision);
        Assert.True(Assert.Single(history.Revisions).Active);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(25u, payload.GetProperty("limit").GetUInt32());
                Assert.Equal(
                    9UL,
                    payload.GetProperty("before_revision").GetUInt64());
                Assert.Equal(
                    8UL,
                    payload.GetProperty("before_state_version").GetUInt64());
            });

        const string envelope =
            """
            {
              "envelope_version": 1,
              "signing_key_id": "synthetic",
              "payload_base64": "e30=",
              "signature_base64": "synthetic"
            }
            """;
        var envelopeBytes =
            System.Text.Encoding.UTF8.GetBytes(envelope);
        var importPlan =
            client.PrepareSignedProviderCatalogImport(
                envelopeBytes);
        Assert.Equal(
            checked((ulong)envelopeBytes.Length),
            importPlan.Review.EnvelopeByteCount);
        Assert.Equal(
            7UL,
            importPlan.Review.SignedCatalogRevision);
        var import =
            client.ActivateSignedProviderCatalogImport(
                importPlan,
                envelopeBytes);
        Assert.Equal(envelope, api.LastCatalogEnvelopeJson);
        Assert.Equal(7UL, import.SignedCatalogRevision);
        Assert.Equal(2UL, import.ActivatedRevision);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    importPlan.PlanJson,
                    payload.GetProperty("plan_json").GetString());
                Assert.False(payload.TryGetProperty("plan", out _));
            });

        var diff = client.DiffProviderCatalogRevisions(1, 2);
        Assert.Equal(1UL, diff.FromRevision);
        Assert.Equal(2UL, diff.ToRevision);
        var manifest = Assert.Single(
            diff.ChangedProviderTemplates);
        Assert.Equal(
            new[] { ManifestChangedSection.ManifestVersion },
            manifest.ChangedSections);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    1UL,
                    payload.GetProperty("from_revision").GetUInt64());
                Assert.Equal(
                    2UL,
                    payload.GetProperty("to_revision").GetUInt64());
            });

        var plan = client.PrepareProviderCatalogRollback(1);
        Assert.Equal("catalog-rollback-1", plan.ActionId);
        Assert.Equal(2UL, plan.FromRevision);
        Assert.Equal(1UL, plan.ToRevision);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload => Assert.Equal(
                1UL,
                payload.GetProperty("target_revision").GetUInt64()));

        var rollback = client.ActivateProviderCatalogRollback(plan);
        Assert.Equal(2UL, rollback.FromRevision);
        Assert.Equal(1UL, rollback.ActivatedRevision);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    plan.PlanJson,
                    payload.GetProperty("plan_json").GetString());
                Assert.False(payload.TryGetProperty("plan", out _));
            });
    }

    [Fact]
    public void RejectsModelSyncAndCatalogBoundsBeforeNativeCalls()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Throws<ArgumentOutOfRangeException>(
            () => client.ListProviderModelSyncs("connection-1", 0));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => client.PollProviderModelSyncEvents(
                "sync-1",
                513));
        Assert.Throws<ArgumentException>(
            () => client.ApproveProviderModelSync("sync-1", "not-a-hash"));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => client.GetProviderCatalogHistory(101));
        Assert.Throws<ArgumentOutOfRangeException>(
            () => client.DiffProviderCatalogRevisions(0, 1));
        Assert.Throws<ArgumentException>(
            () => client.PrepareSignedProviderCatalogImport(
                System.Text.Encoding.UTF8.GetBytes("[]")));

        Assert.Equal(0u, api.LastModelSyncMaxEvents);
        Assert.Null(api.LastCatalogEnvelopeJson);
    }

    [Fact]
    public void CatalogActivationRejectsOpaquePlanMismatchBeforeNativeCall()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());
        var envelope = System.Text.Encoding.UTF8.GetBytes(
            """
            {
              "envelope_version": 1,
              "signing_key_id": "synthetic",
              "payload_base64": "e30=",
              "signature_base64": "synthetic"
            }
            """);
        var importPlan =
            client.PrepareSignedProviderCatalogImport(envelope);
        var tamperedImport = importPlan with
        {
            PlanJson = importPlan.PlanJson.Replace(
                "catalog-import-1",
                "catalog-import-other",
                StringComparison.Ordinal),
        };

        Assert.Throws<CoreInteropException>(() =>
            client.ActivateSignedProviderCatalogImport(
                tamperedImport,
                envelope));
        Assert.Equal(
            "prepare_signed_provider_catalog_import",
            api.LastContractOperation);

        var rollbackPlan =
            client.PrepareProviderCatalogRollback(1);
        var tamperedRollback = rollbackPlan with
        {
            PlanJson = rollbackPlan.PlanJson.Replace(
                "\"to_revision\":1",
                "\"to_revision\":9",
                StringComparison.Ordinal),
        };

        Assert.Throws<CoreInteropException>(() =>
            client.ActivateProviderCatalogRollback(
                tamperedRollback));
        Assert.Equal(
            "prepare_provider_catalog_rollback",
            api.LastContractOperation);
    }

    [Fact]
    public void MapsHighLevelAssistantBoundaryAndKeepsCredentialScalar()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        const string credential = "assistant-only-secret";
        var outcome = client.RunProviderDiscoveryAssistantTurn(
            "discovery-1",
            new ProviderDiscoveryAssistantCallEstimate
            {
                InputTokens = 4096,
                MaximumOutputTokens = 2048,
                MaximumCostMicroUnits = 250_000,
            },
            "route-1",
            "connection-1",
            credential);

        Assert.Equal("request_more_evidence", outcome.Kind);
        Assert.Equal("discovery-1", outcome.SessionId);
        Assert.Equal(
            "models_endpoint",
            Assert.Single(outcome.Questions!).Field?.Kind);
        Assert.Equal(credential, api.LastProviderDiscoveryCredential);
        Assert.DoesNotContain(
            credential,
            api.LastContractRequestJson,
            StringComparison.Ordinal);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                Assert.Equal(
                    "discovery-1",
                    payload.GetProperty("session_id").GetString());
                Assert.Equal(
                    4096UL,
                    payload.GetProperty("estimate")
                        .GetProperty("input_tokens")
                        .GetUInt64());
            });

        _ = client.ApproveProviderDiscoveryAssistantRetry(
            "discovery-1");
        Assert.Equal(
            "approve_provider_discovery_assistant_retry",
            api.LastContractOperation);
        _ = client.ResumeProviderDiscoveryAssistantCoreHostAction(
            "discovery-1");
        Assert.Equal(
            "resume_provider_discovery_assistant_core_host_action",
            api.LastContractOperation);
        _ = client.RequestProviderDiscoveryAssistantRevision(
            "discovery-1");
        Assert.Equal(
            "request_provider_discovery_assistant_revision",
            api.LastContractOperation);
        _ = client.AcceptProviderDiscoveryAssistantDraft(
            "discovery-1");
        Assert.Equal(
            "accept_provider_discovery_assistant_draft",
            api.LastContractOperation);
        _ = client.RecordProviderDiscoveryAssistantFailure(
            "discovery-1",
            "timeout",
            retryable: true);
        Assert.Equal(
            "record_provider_discovery_assistant_failure",
            api.LastContractOperation);
    }

    [Fact]
    public void MapsDiscoveryBeginContinueCancelCommitAndSecretBoundaries()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());
        var options = new ProviderDiscoveryConnectionOptions
        {
            Values =
            [
                new ConnectionConfigEntry
                {
                    Key = "region",
                    Value =
                        ConnectionConfigValue.Text("test-region"),
                },
            ],
            ApiBasePath = "/v1",
            TimeoutSeconds = 45,
            NetworkMode = ProviderNetworkMode.Public,
        };
        string? extracted = null;
        const string rawSecret = "raw-discovery-secret";
        var inspection = client.InspectProviderCurl(
            $"curl https://api.example.invalid/v1/models -H 'Authorization: Bearer {rawSecret}'",
            options,
            credential => extracted = credential);
        Assert.Equal("curl-secret", extracted);
        Assert.True(inspection.CredentialPresent);
        Assert.DoesNotContain(
            rawSecret,
            api.LastContractRequestJson,
            StringComparison.Ordinal);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                var submitted =
                    payload.GetProperty(
                        "connection_options");
                Assert.Equal(
                    "/v1",
                    submitted.GetProperty(
                        "api_base_path").GetString());
                Assert.Equal(
                    45u,
                    submitted.GetProperty(
                        "timeout_seconds").GetUInt32());
                Assert.Equal(
                    "public",
                    submitted.GetProperty(
                        "network_mode").GetString());
            });

        var snapshot = client.BeginProviderDiscovery(
            new ProviderDiscoveryInput
            {
                ConnectionId = "connection-generated",
                DisplayName = "Generated provider",
                CredentialSlotReady = true,
                ConnectionOptions = options,
            },
            new ProviderDiscoverySource
            {
                Kind = "curl",
            },
            inspection.RedactedCurl);
        Assert.Equal(
            "connection-generated",
            snapshot.PendingConnectionId);
        Assert.Equal(
            "connection-generated",
            snapshot.CredentialSlotId);
        Assert.Equal(
            inspection.RedactedCurl,
            api.LastProviderDiscoveryRawCurl);
        Assert.DoesNotContain(
            "curl-secret",
            api.LastContractRequestJson,
            StringComparison.Ordinal);
        AssertVersionedRequest(
            api.LastContractRequestJson!,
            payload =>
            {
                var input = payload.GetProperty("input");
                Assert.Equal(
                    "connection-generated",
                    input.GetProperty(
                        "connection_id").GetString());
                Assert.True(
                    input.GetProperty(
                        "credential_slot_ready").GetBoolean());
                Assert.Equal(
                    "curl",
                    payload.GetProperty("source")
                        .GetProperty("kind").GetString());
            });

        var envelope =
            client.PrepareProviderDiscoveryAction(
                "action-select",
                snapshot.Revision,
                new ProviderDiscoveryAction
                {
                    Kind = "select_template",
                    CandidateId = "candidate-1",
                });
        const string actionCredential =
            "continue-only-secret";
        _ = client.ContinueProviderDiscovery(
            snapshot.SessionId,
            envelope,
            actionCredential);
        Assert.Equal(
            actionCredential,
            api.LastProviderDiscoveryCredential);
        Assert.DoesNotContain(
            actionCredential,
            api.LastContractRequestJson,
            StringComparison.Ordinal);

        _ = client.CancelProviderDiscovery(
            snapshot.SessionId,
            snapshot.Revision);
        Assert.Equal(
            "cancel_provider_discovery",
            api.LastContractOperation);
        var committed = client.CommitProviderDiscovery(
            snapshot.SessionId,
            snapshot.PendingConnectionId,
            credentialReferenceConfirmed: true);
        Assert.Equal(
            snapshot.PendingConnectionId,
            committed.Id);
        Assert.Equal(
            "commit_provider_discovery",
            api.LastContractOperation);
    }

    [Fact]
    public void MapsTypedAssistantDraftReviewWithoutNestedJsonStrings()
    {
        var api = new FakeNativeApi
        {
            ProviderDiscoveryAssistantHostActionJson =
                """
                {
                  "kind": "review_draft",
                  "draft_review": {
                    "draft": {
                      "manifest": {
                        "schema_version": 1,
                        "api_family": "openai_chat_completions",
                        "sources": [
                          {
                            "kind": "official_documentation",
                            "url": "https://docs.example.invalid/api",
                            "content_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                          }
                        ],
                        "default_api_origin": "https://api.example.invalid",
                        "auth": {"kind":"bearer_header"},
                        "endpoints": {
                          "models": {"method":"GET","path":"/v1/models"},
                          "generate": {"method":"POST","path":"/v1/chat/completions"}
                        },
                        "decoders": {
                          "response": "open_ai_json_v1",
                          "streaming": "open_ai_sse_v1"
                        },
                        "parameters": []
                      },
                      "evidence_mappings": [
                        {
                          "field": {"kind":"api_family"},
                          "evidence_ids": ["evidence-1"],
                          "explanation": "Official request and response schema"
                        }
                      ],
                      "conflicts": [],
                      "unresolved_questions": [],
                      "confidence": [
                        {
                          "field": {"kind":"api_family"},
                          "level": "high",
                          "rationale": "The official documentation is explicit"
                        }
                      ],
                      "summary": "Evidence-backed OpenAI-compatible draft"
                    },
                    "unresolved_conflicts": [],
                    "requirements": {
                      "required_checks": [
                        "manifest_validation",
                        "url_policy_validation",
                        "credential_origin_approval",
                        "user_review"
                      ],
                      "persistence": "blocked_until_checks_pass"
                    }
                  }
                }
                """,
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        var outcome = client.RunProviderDiscoveryAssistantTurn(
            "discovery-1",
            new ProviderDiscoveryAssistantCallEstimate
            {
                InputTokens = 100,
                MaximumOutputTokens = 100,
                MaximumCostMicroUnits = 1,
            },
            "route-1",
            "connection-1",
            assistantCredential: null);

        Assert.Equal("review_draft", outcome.Kind);
        var review = Assert.IsType<ProviderDiscoveryAssistantDraftReview>(
            outcome.DraftReview);
        Assert.Equal(
            ProviderApiFamily.OpenaiChatCompletions,
            review.Draft.Manifest.ApiFamily);
        Assert.Equal(
            "/v1/chat/completions",
            review.Draft.Manifest.Endpoints.Generate.Path);
        Assert.Equal(
            "api_family",
            Assert.Single(review.Draft.EvidenceMappings).Field.Kind);
        Assert.DoesNotContain(
            "json",
            review.Draft.Summary,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void MapsSchemaThreeAssistantResumeBoundaryAndPersistedPolicy()
    {
        var api = new FakeNativeApi();
        api.ProviderDiscoverySnapshotJson =
            api.ProviderDiscoverySnapshotJson
                .Replace(
                    "\"state\": \"awaiting_template_selection\"",
                    "\"state\": \"building_assistant_manifest_draft\"",
                    StringComparison.Ordinal)
                .Replace(
                    "\"action_required\": {\"kind\":\"select_template\"}",
                    "\"action_required\": null",
                    StringComparison.Ordinal)
                .Replace(
                    "\"network_mode\": \"public\"",
                    "\"network_mode\": \"approved_local_network\"",
                    StringComparison.Ordinal)
                .Replace(
                    "\"local_network_approval\": null",
                    """
                    "local_network_approval": {
                      "origin": "http://models.lan:11434",
                      "addresses": ["192.168.10.24", "fd00::24"]
                    }
                    """,
                    StringComparison.Ordinal)
                .Replace(
                    "\"assistant_resume_boundary\": null",
                    """
                    "assistant_resume_boundary": {
                      "checkpoint": "awaiting_tool_result",
                      "action": "resume_core_host_action",
                      "questions": [],
                      "draft_review": null
                    }
                    """,
                    StringComparison.Ordinal);
        using var client = CoreClient.Open(api, CreateDataRoot());

        var snapshot =
            client.GetProviderDiscovery("discovery-1");

        Assert.Equal(3u, snapshot.SnapshotSchemaVersion);
        Assert.Equal(
            ProviderNetworkMode.ApprovedLocalNetwork,
            snapshot.ConnectionOptions.NetworkMode);
        Assert.Equal(
            "http://models.lan:11434",
            snapshot.ConnectionOptions.LocalNetworkApproval?.Origin);
        Assert.Equal(
            ProviderDiscoveryAssistantCheckpoint.AwaitingToolResult,
            snapshot.AssistantResumeBoundary?.Checkpoint);
        Assert.Equal(
            ProviderDiscoveryAssistantResumeAction.ResumeCoreHostAction,
            snapshot.AssistantResumeBoundary?.Action);

        _ = client.ResumeProviderDiscoveryAssistantCoreHostAction(
            snapshot.SessionId);
        Assert.Equal(
            "resume_provider_discovery_assistant_core_host_action",
            api.LastContractOperation);
    }

    [Fact]
    public void DiscoveryEventsRejectOldAndFutureVersionsBeforeAck()
    {
        var api = new FakeNativeApi
        {
            ProviderDiscoveryEventsJson =
                DiscoveryOutboxJson(eventVersion: 2),
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        var current = Assert.Single(
            client.PollProviderDiscoveryEvents());
        Assert.Equal(
            CoreClient.SupportedProviderDiscoveryEventVersion,
            current.Event.EventVersion);
        Assert.True(
            client.AckProviderDiscoveryEvent(
                current.Event.EventId));
        Assert.Equal(
            current.Event.EventId,
            api.LastAckedProviderDiscoveryEventId);

        api.ProviderDiscoveryEventsJson =
            DiscoveryOutboxJson(eventVersion: 1);
        Assert.Throws<CoreInteropException>(() =>
            client.PollProviderDiscoveryEvents());
        api.ProviderDiscoveryEventsJson =
            DiscoveryOutboxJson(eventVersion: 3);
        Assert.Throws<CoreInteropException>(() =>
            client.PollProviderDiscoveryEvents());
        Assert.Equal(
            current.Event.EventId,
            api.LastAckedProviderDiscoveryEventId);
    }

    [Fact]
    public void ModelSyncPollingAndAcknowledgementRemainScopedAcrossTwoJobs()
    {
        var api = new FakeNativeApi();
        var baseEvents = api.ModelSyncEventsJson;
        using var client = CoreClient.Open(api, CreateDataRoot());

        api.ModelSyncEventsJson =
            baseEvents.Replace(
                "sync-1",
                "sync-a",
                StringComparison.Ordinal);
        var first = Assert.Single(
            client.PollProviderModelSyncEvents(
                "sync-a"));
        Assert.Equal("sync-a", first.JobId);
        Assert.Equal("sync-a", api.LastModelSyncEventJobId);
        Assert.True(
            client.AckProviderModelSyncEvent(
                first.JobId,
                first.Sequence));
        Assert.Equal("sync-a", api.LastModelSyncEventJobId);

        api.ModelSyncEventsJson =
            baseEvents.Replace(
                "sync-1",
                "sync-b",
                StringComparison.Ordinal);
        var second = Assert.Single(
            client.PollProviderModelSyncEvents(
                "sync-b"));
        Assert.Equal("sync-b", second.JobId);
        Assert.Equal("sync-b", api.LastModelSyncEventJobId);
        Assert.True(
            client.AckProviderModelSyncEvent(
                second.JobId,
                second.Sequence));
        Assert.Equal("sync-b", api.LastModelSyncEventJobId);
    }

    [Fact]
    public void DurableResponsesRejectMismatchedJobSessionAndConnection()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        api.ModelSyncJobJson = api.ModelSyncJobJson.Replace(
            "\"id\": \"sync-1\"",
            "\"id\": \"sync-other\"",
            StringComparison.Ordinal);
        Assert.Throws<CoreInteropException>(() =>
            client.GetProviderModelSync(
                "sync-1",
                "connection-1"));

        api.ModelSyncJobJson = api.ModelSyncJobJson.Replace(
            "\"id\": \"sync-other\"",
            "\"id\": \"sync-1\"",
            StringComparison.Ordinal);
        Assert.Throws<CoreInteropException>(() =>
            client.GetProviderModelSync(
                "sync-1",
                "connection-other"));

        api.ProviderDiscoverySnapshotJson =
            api.ProviderDiscoverySnapshotJson.Replace(
                "\"session_id\": \"discovery-1\"",
                "\"session_id\": \"discovery-other\"",
                StringComparison.Ordinal);
        Assert.Throws<CoreInteropException>(() =>
            client.GetProviderDiscovery(
                "discovery-1",
                "connection-1"));
    }

    [Fact]
    public void ModelSyncReviewRejectsMismatchedNestedConnection()
    {
        var api = new FakeNativeApi();
        api.ModelSyncJobJson = api.ModelSyncJobJson.Replace(
            "\"id\": \"connection-1\",",
            "\"id\": \"connection-other\",",
            StringComparison.Ordinal);
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Throws<CoreInteropException>(() =>
            client.GetProviderModelSync(
                "sync-1",
                "connection-1"));
    }

    [Fact]
    public void AssistantCredentialRejectsRouteConnectionMismatchBeforeCall()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Throws<CoreInteropException>(() =>
            client.RunProviderDiscoveryAssistantTurn(
                "discovery-1",
                new ProviderDiscoveryAssistantCallEstimate
                {
                    InputTokens = 100,
                    MaximumOutputTokens = 100,
                    MaximumCostMicroUnits = 1,
                },
                "route-1",
                "connection-other",
                "must-not-cross-targets"));

        Assert.Null(api.LastProviderDiscoveryCredential);
        Assert.Null(api.LastContractRequestJson);
    }

    [Fact]
    public void CompensationListRejectsAnotherCommitAttempt()
    {
        var api = new FakeNativeApi
        {
            ProviderDiscoveryCompensationStepsJson =
                """
                [
                  {
                    "id": "step-1",
                    "commit_attempt_id": "attempt-other",
                    "ordinal": 0,
                    "action_id": "action-1",
                    "kind": "remove_credential_slot",
                    "target": {
                      "kind": "remove_credential_slot",
                      "connection_id": "connection-1",
                      "credential_ref": "connection-1",
                      "previous_selection": null
                    },
                    "status": "pending",
                    "attempt_count": 0,
                    "last_failure": null,
                    "created_at": "2026-07-31T00:00:00Z",
                    "updated_at": "2026-07-31T00:00:00Z",
                    "completed_at": null
                  }
                ]
                """,
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Throws<CoreInteropException>(() =>
            client.ListProviderDiscoveryCompensationSteps(
                "attempt-requested"));
    }

    [Fact]
    public void CompensationTerminalResponsesRequireExactBindings()
    {
        var api = new FakeNativeApi();
        var exactSnapshot = api.ProviderDiscoverySnapshotJson
            .Replace(
                "\"state\": \"awaiting_template_selection\"",
                "\"state\": \"compensating\"",
                StringComparison.Ordinal)
            .Replace(
                "\"action_required\": {\"kind\":\"select_template\"}",
                "\"action_required\": null",
                StringComparison.Ordinal)
            .Replace(
                "\"commit_attempt_id\": null",
                "\"commit_attempt_id\": \"attempt-1\"",
                StringComparison.Ordinal);
        api.ProviderDiscoverySnapshotJson = exactSnapshot;
        using var client = CoreClient.Open(
            api,
            CreateDataRoot());
        var failure = new ProviderDiscoveryFailure
        {
            Code = "synthetic_failure",
            MessageKey = "synthetic_failure",
            Recoverable = true,
        };

        Assert.Equal(
            "attempt-1",
            client.CompleteProviderDiscoveryCredentialCompensation(
                "discovery-1",
                "credential-step-1",
                "connection-1",
                "attempt-1").CommitAttemptId);
        Assert.Equal(
            "attempt-1",
            client.MarkProviderDiscoveryCredentialCompensationUnknown(
                "discovery-1",
                "credential-step-1",
                "connection-1",
                "attempt-1").CommitAttemptId);
        Assert.Equal(
            "attempt-1",
            client.FailProviderDiscoveryCredentialCompensation(
                "discovery-1",
                "credential-step-1",
                "connection-1",
                "attempt-1",
                failure).CommitAttemptId);

        void AssertAllTerminalCallsRejectForeignResponse()
        {
            Assert.Throws<CoreInteropException>(() =>
                client.CompleteProviderDiscoveryCredentialCompensation(
                    "discovery-1",
                    "credential-step-1",
                    "connection-1",
                    "attempt-1"));
            Assert.Throws<CoreInteropException>(() =>
                client.MarkProviderDiscoveryCredentialCompensationUnknown(
                    "discovery-1",
                    "credential-step-1",
                    "connection-1",
                    "attempt-1"));
            Assert.Throws<CoreInteropException>(() =>
                client.FailProviderDiscoveryCredentialCompensation(
                    "discovery-1",
                    "credential-step-1",
                    "connection-1",
                    "attempt-1",
                    failure));
        }

        api.ProviderDiscoverySnapshotJson =
            exactSnapshot.Replace(
                "\"session_id\": \"discovery-1\"",
                "\"session_id\": \"discovery-other\"",
                StringComparison.Ordinal);
        AssertAllTerminalCallsRejectForeignResponse();

        api.ProviderDiscoverySnapshotJson =
            exactSnapshot.Replace(
                "connection-1",
                "connection-other",
                StringComparison.Ordinal);
        AssertAllTerminalCallsRejectForeignResponse();

        api.ProviderDiscoverySnapshotJson =
            exactSnapshot.Replace(
                "\"commit_attempt_id\": \"attempt-1\"",
                "\"commit_attempt_id\": \"attempt-other\"",
                StringComparison.Ordinal);
        AssertAllTerminalCallsRejectForeignResponse();
    }

    private static string DiscoveryOutboxJson(uint eventVersion) =>
        $$"""
        [
          {
            "event": {
              "event_version": {{eventVersion}},
              "event_id": "discovery-event-1",
              "session_id": "discovery-1",
              "sequence": 1,
              "session_revision": 2,
              "state": "awaiting_template_selection",
              "progress": {
                "phase": "provider_candidates",
                "completed": 1,
                "total": 1
              },
              "action_required": {"kind":"select_template"},
              "warning": null,
              "action_id": "action-1",
              "failure": null
            },
            "delivery_attempts": 0,
            "available_at": "2026-07-31T00:00:01Z",
            "created_at": "2026-07-31T00:00:00Z"
          }
        ]
        """;

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
            "lorepia-native-durable-provider-tests",
            Guid.NewGuid().ToString("N"));
}
