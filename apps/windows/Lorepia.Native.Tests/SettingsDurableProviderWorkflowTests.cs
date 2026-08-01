using Lorepia.App.Platform;
using Lorepia.App.ViewModels;
using System.Text.Json;

namespace Lorepia.Native.Tests;

public sealed class SettingsDurableProviderWorkflowTests
{
    private const string ReviewSha256 =
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    [Fact]
    public async Task StopMonitoringDuringRefreshRejectsLateStateAndMonitor()
    {
        var refreshEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseRefresh = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
            BeforeGetCoreVersion = () =>
            {
                refreshEntered.TrySetResult();
                if (!releaseRefresh.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test settings refresh was not released.");
                }
            },
        };
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());

        var refresh = viewModel.RefreshAsync();
        await refreshEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        viewModel.StopMonitoring();
        releaseRefresh.TrySetResult();
        await refresh.WaitAsync(TimeSpan.FromSeconds(2));

        Assert.False(viewModel.IsBusy);
        Assert.Equal("—", viewModel.CoreVersion);
        Assert.Empty(viewModel.ProviderTemplates);
        Assert.Empty(viewModel.ProviderConnections);
        Assert.False(viewModel.HasActiveDiscovery);
        Assert.Equal(0, api.GetProviderDiscoveryCount);
    }

    [Fact]
    public async Task StopMonitoringDuringModelSyncStartRejectsLateJobAndMonitor()
    {
        var startEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseStart = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "model-sync-secret");
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        api.BeforeStartProviderModelSync = () =>
        {
            startEntered.TrySetResult();
            if (!releaseStart.Task.Wait(
                    TimeSpan.FromSeconds(5)))
            {
                throw new TimeoutException(
                    "Test model-sync start was not released.");
            }
        };

        var refresh = viewModel.RefreshModelsAsync();
        await startEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        viewModel.StopMonitoring();
        releaseStart.TrySetResult();
        await refresh.WaitAsync(TimeSpan.FromSeconds(2));

        Assert.False(viewModel.IsBusy);
        Assert.False(viewModel.CanCancelModelSync);
        Assert.Empty(viewModel.ModelSyncReview);
        Assert.Equal(1, api.StartProviderModelSyncCount);
        Assert.Equal(0, api.GetProviderModelSyncCount);
    }

    [Fact]
    public async Task OlderRefreshCannotReleaseNewerRefreshOwnership()
    {
        var olderListEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOlderList = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var newerVersionEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseNewerVersion = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var listCalls = 0;
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
            BeforeListProviderDiscoveries = () =>
            {
                if (Interlocked.Increment(ref listCalls) != 1)
                {
                    return;
                }

                olderListEntered.TrySetResult();
                if (!releaseOlderList.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test older settings refresh was not released.");
                }
            },
        };
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());

        var olderRefresh = viewModel.RefreshAsync();
        await olderListEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        api.BeforeGetCoreVersion = () =>
        {
            newerVersionEntered.TrySetResult();
            if (!releaseNewerVersion.Task.Wait(
                    TimeSpan.FromSeconds(5)))
            {
                throw new TimeoutException(
                    "Test newer settings refresh was not released.");
            }
        };
        viewModel.StopMonitoring();
        var newerRefresh = viewModel.RefreshAsync();

        bool newerOwnedBusyAfterOlderCompleted;
        bool newerWasStillBlocked;
        string coreVersionBeforeNewerResult;
        try
        {
            releaseOlderList.TrySetResult();
            await newerVersionEntered.Task.WaitAsync(
                TimeSpan.FromSeconds(2));
            await olderRefresh.WaitAsync(
                TimeSpan.FromSeconds(2));
            newerOwnedBusyAfterOlderCompleted =
                viewModel.IsBusy;
            newerWasStillBlocked = !newerRefresh.IsCompleted;
            coreVersionBeforeNewerResult =
                viewModel.CoreVersion;
        }
        finally
        {
            releaseOlderList.TrySetResult();
            releaseNewerVersion.TrySetResult();
        }

        await newerRefresh.WaitAsync(TimeSpan.FromSeconds(2));
        var newerMonitorSurvived =
            viewModel.HasActiveDiscovery;
        viewModel.StopMonitoring();

        Assert.True(newerOwnedBusyAfterOlderCompleted);
        Assert.True(newerWasStillBlocked);
        Assert.Equal("—", coreVersionBeforeNewerResult);
        Assert.Equal("0.1.0-test", viewModel.CoreVersion);
        Assert.True(newerMonitorSurvived);
        Assert.False(viewModel.IsBusy);
    }

    [Fact]
    public async Task OlderModelSyncCannotReleaseNewerOperationOwnership()
    {
        var olderStartEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseOlderStart = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var newerStartEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseNewerStart = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var newerMonitorEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseNewerMonitor = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var startCalls = 0;
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "model-sync-secret");
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        api.BeforeStartProviderModelSync = () =>
        {
            var call = Interlocked.Increment(
                ref startCalls);
            var entered = call == 1
                ? olderStartEntered
                : newerStartEntered;
            var release = call == 1
                ? releaseOlderStart
                : releaseNewerStart;
            entered.TrySetResult();
            if (!release.Task.Wait(TimeSpan.FromSeconds(5)))
            {
                throw new TimeoutException(
                    $"Test model-sync start {call} was not released.");
            }
        };
        api.BeforeGetProviderModelSync = () =>
        {
            newerMonitorEntered.TrySetResult();
            if (!releaseNewerMonitor.Task.Wait(
                    TimeSpan.FromSeconds(5)))
            {
                throw new TimeoutException(
                    "Test newer model-sync monitor was not released.");
            }
        };

        var olderRefresh = viewModel.RefreshModelsAsync();
        await olderStartEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        viewModel.StopMonitoring();
        var newerRefresh = viewModel.RefreshModelsAsync();

        bool newerOwnedBusyAfterOlderCompleted;
        bool newerStartWasStillBlocked;
        bool newerMonitorOwnedBusy;
        bool newerMonitorOwnedJob;
        try
        {
            releaseOlderStart.TrySetResult();
            await newerStartEntered.Task.WaitAsync(
                TimeSpan.FromSeconds(2));
            await olderRefresh.WaitAsync(
                TimeSpan.FromSeconds(2));
            newerOwnedBusyAfterOlderCompleted =
                viewModel.IsBusy;
            newerStartWasStillBlocked =
                !newerRefresh.IsCompleted;

            releaseNewerStart.TrySetResult();
            await newerMonitorEntered.Task.WaitAsync(
                TimeSpan.FromSeconds(2));
            newerMonitorOwnedBusy = viewModel.IsBusy;
            newerMonitorOwnedJob =
                viewModel.CanCancelModelSync;
        }
        finally
        {
            releaseOlderStart.TrySetResult();
            releaseNewerStart.TrySetResult();
            releaseNewerMonitor.TrySetResult();
        }

        await newerRefresh.WaitAsync(TimeSpan.FromSeconds(2));
        var newerReviewSurvived =
            viewModel.ModelSyncReview.Any(item =>
                item.Label == "Exact review digest");
        viewModel.StopMonitoring();

        Assert.True(newerOwnedBusyAfterOlderCompleted);
        Assert.True(newerStartWasStillBlocked);
        Assert.True(newerMonitorOwnedBusy);
        Assert.True(newerMonitorOwnedJob);
        Assert.True(newerReviewSurvived);
        Assert.Equal(2, api.StartProviderModelSyncCount);
        Assert.Equal(1, api.GetProviderModelSyncCount);
        Assert.False(viewModel.IsBusy);
    }

    [Fact]
    public async Task ModelSyncStopsForExactReviewWithoutExposingCredential()
    {
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "model-sync-secret");
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());

        await viewModel.RefreshModelsAsync();

        Assert.Equal(
            "start_provider_model_sync",
            api.LastContractOperation);
        Assert.Equal(
            "model-sync-secret",
            api.LastModelSyncCredential);
        Assert.Contains(
            viewModel.ModelSyncReview,
            item => item.Label == "Exact review digest"
                && item.Detail == ReviewSha256);
        var displayed = string.Join(
            "\n",
            viewModel.ModelSyncReview.Select(item =>
                $"{item.Label}:{item.Detail}"));
        Assert.DoesNotContain(
            "model-sync-secret",
            displayed,
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            "model-sync-secret",
            viewModel.ProviderStatus,
            StringComparison.Ordinal);

        await viewModel.RefreshModelsAsync();

        Assert.Equal(1, api.StartProviderModelSyncCount);
        Assert.Contains(
            viewModel.ModelSyncReview,
            item => item.Label == "Exact review digest"
                && item.Detail == ReviewSha256);
        Assert.Contains(
            "current model synchronization",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ModelSyncCancelRetainsBusyOwnershipAfterMonitorStops()
    {
        var monitorEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseMonitor = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var cancelEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseCancel = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
            ModelSyncEventsJson = "[]",
            BeforeGetProviderModelSync = () =>
            {
                monitorEntered.TrySetResult();
                if (!releaseMonitor.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test model-sync monitor was not released.");
                }
            },
            BeforeCancelProviderModelSync = () =>
            {
                cancelEntered.TrySetResult();
                if (!releaseCancel.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test model-sync cancellation was not released.");
                }
            },
        };
        api.ModelSyncJobJson =
            api.ModelSyncJobJson.Replace(
                "\"state\": \"diff-ready-awaiting-review\"",
                "\"state\": \"cancelled\"",
                StringComparison.Ordinal);
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "model-sync-secret");
        credentials.Writes.Clear();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());

        var refresh = viewModel.RefreshModelsAsync();
        await monitorEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        var cancellation = viewModel.CancelModelSyncAsync();
        releaseMonitor.TrySetResult();
        await cancelEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        await refresh.WaitAsync(TimeSpan.FromSeconds(2));

        try
        {
            Assert.False(cancellation.IsCompleted);
            Assert.True(viewModel.IsBusy);
            Assert.False(viewModel.CanSaveConnection);
            Assert.False(
                viewModel.CanRemoveSelectedCredential);
            viewModel.RemoveSelectedCredential();
            Assert.Empty(credentials.Deletes);
            Assert.Equal(
                "model-sync-secret",
                credentials.Get("connection-1"));
        }
        finally
        {
            releaseCancel.TrySetResult();
        }

        await cancellation;
        Assert.False(viewModel.IsBusy);
        Assert.True(viewModel.CanRemoveSelectedCredential);
    }

    [Fact]
    public async Task ApprovalUsesReviewDigestCapturedFromJob()
    {
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "model-sync-secret");
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        await viewModel.RefreshModelsAsync();
        api.ModelSyncJobJson =
            """
            {
              "id": "sync-1",
              "connection_id": "connection-1",
              "state": "completed",
              "revision": 4,
              "review": null,
              "failure": null,
              "created_at": "2026-07-31T00:00:00Z",
              "updated_at": "2026-07-31T00:00:03Z"
            }
            """;

        await viewModel.ApproveModelSyncAsync();

        Assert.Equal(
            "approve_provider_model_sync",
            api.LastContractOperation);
        using var request =
            JsonDocument.Parse(api.LastContractRequestJson!);
        Assert.Equal(
            ReviewSha256,
            request.RootElement
                .GetProperty("payload")
                .GetProperty("review_sha256")
                .GetString());
        Assert.DoesNotContain(
            "model-sync-secret",
            api.LastContractRequestJson,
            StringComparison.Ordinal);
        Assert.Contains(
            "committed",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task CatalogRollbackRequiresPreparedStateBoundPlan()
    {
        var api = new FakeNativeApi
        {
            ProviderCatalogHistoryJson =
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
                    },
                    {
                      "revision": 1,
                      "captured_at": "2026-07-30T00:00:00Z",
                      "snapshot_sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
                      "signed_revisions": [],
                      "active": false
                    }
                  ],
                  "activations": [],
                  "next_before_revision": null,
                  "next_before_state_version": null
                }
                """,
        };
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await viewModel.RefreshAsync();
        viewModel.SelectedCatalogRevision =
            viewModel.CatalogRevisions.Single(item =>
                item.Revision == 1);
        Assert.Equal(
            1UL,
            viewModel.SelectedCatalogRevision?.Revision);
        Assert.False(viewModel.IsBusy);

        await viewModel.ActivateCatalogRollbackAsync();
        Assert.Null(api.LastContractOperation);
        Assert.Contains(
            "Prepare",
            viewModel.CatalogStatus,
            StringComparison.OrdinalIgnoreCase);

        await viewModel.PrepareCatalogRollbackAsync();
        Assert.DoesNotContain(
            "already active",
            viewModel.CatalogStatus,
            StringComparison.OrdinalIgnoreCase);
        Assert.Equal(
            "prepare_provider_catalog_rollback",
            api.LastContractOperation);
        Assert.Contains(
            viewModel.CatalogReview,
            item => item.Label == "Rollback plan digest"
                && item.Detail.Length == 64);
        using (var prepareRequest =
               JsonDocument.Parse(api.LastContractRequestJson!))
        {
            Assert.Equal(
                1UL,
                prepareRequest.RootElement
                    .GetProperty("payload")
                    .GetProperty("target_revision")
                    .GetUInt64());
        }

        await viewModel.ActivateCatalogRollbackAsync();
        Assert.Equal(
            "activate_provider_catalog_rollback",
            api.LastContractOperation);
        Assert.Contains(
            viewModel.CatalogReview,
            item => item.Label == "Rollback activated"
                && item.Detail.Contains(
                    "→ 1",
                    StringComparison.Ordinal));
    }

    [Fact]
    public async Task RouteEditorUsesEffectiveSpecsAndCandidatePreview()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        await viewModel.SelectModelRouteAsync(
            viewModel.ModelRoutes.Single());

        var parameter = Assert.Single(viewModel.ParameterEditors);
        Assert.Equal("temperature", parameter.Id);
        parameter.UseProviderDefault = false;
        parameter.Input = "0.7";

        var loaded = await viewModel.LoadRequestPreviewAsync();

        Assert.True(loaded, viewModel.RequestPreview);
        Assert.Equal(
            "preview_provider_request_candidate",
            api.LastContractOperation);
        Assert.Equal(1, api.ValidateGenerationPresetCandidateCount);
        Assert.Contains(
            "redaction_version: 1",
            viewModel.RequestPreview,
            StringComparison.Ordinal);
        Assert.Contains(
            "authorization",
            viewModel.RequestPreview,
            StringComparison.Ordinal);
        Assert.Contains(
            "messages",
            viewModel.RequestPreview,
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            "0.75",
            viewModel.RequestPreview,
            StringComparison.Ordinal);
        Assert.Contains(
            "private_message=false",
            viewModel.RequestPreview,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task ConditionalParameterClearsHiddenExplicitValue()
    {
        var api = new FakeNativeApi
        {
            EffectiveParameterSpecsJson =
                ConditionalParameterSpecsJson,
        };
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await LoadOnlyRouteAsync(viewModel);

        Assert.DoesNotContain(
            viewModel.ParameterEditors,
            editor => editor.Id == "advanced_value");
        var mode = viewModel.ParameterEditors.Single(
            editor => editor.Id == "mode");
        mode.UseProviderDefault = false;
        mode.Input = "advanced";
        var advanced = viewModel.ParameterEditors.Single(
            editor => editor.Id == "advanced_value");
        advanced.UseProviderDefault = false;
        advanced.Input = "stale-value";

        mode.Input = "basic";

        Assert.DoesNotContain(
            viewModel.ParameterEditors,
            editor => editor.Id == "advanced_value");
        mode.Input = "advanced";
        advanced = viewModel.ParameterEditors.Single(
            editor => editor.Id == "advanced_value");
        Assert.True(advanced.UseProviderDefault);
        Assert.Equal(string.Empty, advanced.Input);
    }

    [Fact]
    public async Task MutualExclusionDisablesPeerAndBlocksStaleConflict()
    {
        var api = new FakeNativeApi
        {
            EffectiveParameterSpecsJson =
                ConditionalParameterSpecsJson,
        };
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await LoadOnlyRouteAsync(viewModel);
        var left = viewModel.ParameterEditors.Single(
            editor => editor.Id == "left_option");
        var right = viewModel.ParameterEditors.Single(
            editor => editor.Id == "right_option");

        left.UseProviderDefault = false;
        left.Input = "true";

        Assert.False(right.IsEnabled);
        Assert.Contains(
            "exclusive-options",
            right.PolicyMessage,
            StringComparison.Ordinal);

        right.UseProviderDefault = false;
        right.Input = "true";
        var saved = await viewModel.SavePresetAsync();

        Assert.False(saved);
        Assert.Equal(
            0,
            api.ValidateGenerationPresetCandidateCount);
        Assert.Contains(
            "exclusive-options",
            viewModel.ProviderStatus,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task RequiredPeerBlocksPresetBeforeCoreValidation()
    {
        var api = new FakeNativeApi
        {
            EffectiveParameterSpecsJson =
                ConditionalParameterSpecsJson,
        };
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await LoadOnlyRouteAsync(viewModel);
        var dependent = viewModel.ParameterEditors.Single(
            editor => editor.Id == "dependent_option");

        dependent.UseProviderDefault = false;
        dependent.Input = "true";
        var saved = await viewModel.SavePresetAsync();

        Assert.False(saved);
        Assert.Equal(
            0,
            api.ValidateGenerationPresetCandidateCount);
        Assert.Contains(
            "requires-prerequisite",
            dependent.PolicyMessage,
            StringComparison.Ordinal);
        Assert.Contains(
            "requires-prerequisite",
            viewModel.ProviderStatus,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task RouteEditorRendersCoreOwnedReasoningAndCacheControls()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());

        await viewModel.SelectModelRouteAsync(
            viewModel.ModelRoutes.Single());

        Assert.True(viewModel.ReasoningControlsEnabled);
        Assert.False(viewModel.ReasoningBudgetEnabled);
        Assert.Equal(
            new[] { "provider_default", "automatic" },
            viewModel.ReasoningModes);
        Assert.True(viewModel.PromptCacheControlsEnabled);
        Assert.Contains(
            "custom_seconds",
            viewModel.PromptCacheTtls);
        Assert.Contains(
            "128–8192",
            viewModel.PresetControlStatus,
            StringComparison.Ordinal);
        Assert.Contains(
            "60–3600",
            viewModel.PresetControlStatus,
            StringComparison.Ordinal);

        viewModel.ReasoningMode = "automatic";
        Assert.True(await viewModel.RefreshPresetControlsAsync());
        Assert.True(viewModel.ReasoningBudgetEnabled);
    }

    [Fact]
    public async Task VisibleRenderedReasoningDefaultIsAdoptedAndReused()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await LoadOnlyRouteAsync(viewModel);
        api.ReasoningControlJson =
            VisibleReasoningDefaultControlJson;

        viewModel.ReasoningMode = "enabled";

        Assert.True(await viewModel.LoadRequestPreviewAsync());
        Assert.Equal("high", viewModel.ReasoningEffort);
        Assert.True(viewModel.ReasoningEffortEnabled);
        AssertReasoningCandidate(
            api.LastPreviewProviderRequestCandidateJson!,
            "enabled",
            "high",
            null,
            "provider_default");

        viewModel.ReasoningMode = "provider_default";
        viewModel.ReasoningMode = "enabled";
        api.GenerationPresetJson =
            EnabledHighGenerationPresetJson;
        Assert.True(await viewModel.SavePresetAsync());
        AssertReasoningCandidate(
            api.LastUpsertGenerationPresetRequestJson!,
            "enabled",
            "high",
            null,
            "provider_default");
        Assert.Equal(
            "high",
            viewModel.SelectedGenerationPreset?.Reasoning.Effort);
    }

    [Fact]
    public async Task ExplicitReasoningEffortIsNotOverwrittenByRenderedDefault()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await LoadOnlyRouteAsync(viewModel);
        api.ReasoningControlJson =
            VisibleReasoningDefaultControlJson;

        viewModel.ReasoningMode = "enabled";
        viewModel.ReasoningEffort = "low";

        Assert.True(await viewModel.RefreshPresetControlsAsync());
        Assert.Equal("low", viewModel.ReasoningEffort);
        Assert.True(await viewModel.LoadRequestPreviewAsync());
        AssertReasoningCandidate(
            api.LastPreviewProviderRequestCandidateJson!,
            "enabled",
            "low",
            null,
            "provider_default");
    }

    [Fact]
    public async Task HiddenReasoningEffortRemainsNullWhenEnabled()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await LoadOnlyRouteAsync(viewModel);
        api.ReasoningControlJson =
            HiddenReasoningEffortControlJson;

        viewModel.ReasoningMode = "enabled";

        Assert.True(await viewModel.RefreshPresetControlsAsync());
        Assert.Equal(string.Empty, viewModel.ReasoningEffort);
        Assert.False(viewModel.ReasoningEffortEnabled);
        Assert.True(await viewModel.LoadRequestPreviewAsync());
        AssertReasoningCandidate(
            api.LastPreviewProviderRequestCandidateJson!,
            "enabled",
            null,
            null,
            "provider_default");
    }

    [Fact]
    public async Task ProviderDefaultClearsAndOmitsReasoningOverrides()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await LoadOnlyRouteAsync(viewModel);

        viewModel.ReasoningMode = "enabled";
        viewModel.ReasoningEffort = "high";
        viewModel.ReasoningBudgetTokens = "2048";
        viewModel.ReasoningSummary = "concise";
        viewModel.ReasoningMode = "provider_default";

        Assert.Equal(string.Empty, viewModel.ReasoningEffort);
        Assert.Equal(string.Empty, viewModel.ReasoningBudgetTokens);
        Assert.Equal(
            "provider_default",
            viewModel.ReasoningSummary);

        viewModel.ReasoningEffort = "high";
        viewModel.ReasoningBudgetTokens = "not-a-number";
        viewModel.ReasoningSummary = "concise";

        Assert.True(await viewModel.RefreshPresetControlsAsync());
        Assert.False(viewModel.ReasoningEffortEnabled);
        Assert.False(viewModel.ReasoningBudgetEnabled);
        Assert.False(viewModel.ReasoningSummaryEnabled);
        Assert.True(await viewModel.LoadRequestPreviewAsync());
        AssertReasoningCandidate(
            api.LastPreviewProviderRequestCandidateJson!,
            "provider_default",
            null,
            null,
            "provider_default");

        Assert.True(await viewModel.SavePresetAsync());
        AssertReasoningCandidate(
            api.LastUpsertGenerationPresetRequestJson!,
            "provider_default",
            null,
            null,
            "provider_default");
    }

    [Fact]
    public async Task CredentialBearingRouteForcesOpaqueReasoningReplayOff()
    {
        var defaults = new FakeNativeApi();
        var api = new FakeNativeApi
        {
            GenerationPresetJson =
                defaults.GenerationPresetJson.Replace(
                    "\"preserve_opaque_state\": false",
                    "\"preserve_opaque_state\": true",
                    StringComparison.Ordinal),
            ReasoningControlJson =
                defaults.ReasoningControlJson.Replace(
                    "\"preserve_opaque_state\": false",
                    "\"preserve_opaque_state\": true",
                    StringComparison.Ordinal),
        };
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());

        await LoadOnlyRouteAsync(viewModel);

        Assert.True(viewModel.ReasoningControlsEnabled);
        Assert.False(viewModel.CanPreserveOpaqueReasoningState);
        Assert.False(viewModel.PreserveOpaqueReasoningState);
        Assert.False(
            viewModel.SelectedGenerationPreset!
                .Reasoning.PreserveOpaqueState);
        Assert.Contains(
            "disabled for credential-bearing connections",
            viewModel.PresetControlStatus,
            StringComparison.OrdinalIgnoreCase);

        viewModel.PreserveOpaqueReasoningState = true;
        Assert.False(viewModel.PreserveOpaqueReasoningState);

        Assert.True(await viewModel.SavePresetAsync());
        using var request = JsonDocument.Parse(
            api.LastUpsertGenerationPresetRequestJson!);
        Assert.False(
            request.RootElement
                .GetProperty("payload")
                .GetProperty("reasoning")
                .GetProperty("preserve_opaque_state")
                .GetBoolean());
        Assert.False(
            viewModel.SelectedGenerationPreset!
                .Reasoning.PreserveOpaqueState);
    }

    [Fact]
    public async Task CredentialFreeRouteCanUseCoreOpaqueReasoningPolicy()
    {
        var defaults = new FakeNativeApi();
        var api = new FakeNativeApi
        {
            ProviderTemplatesJson =
                defaults.ProviderTemplatesJson
                    .Replace(
                        "\"requires_credential\": true",
                        "\"requires_credential\": false",
                        StringComparison.Ordinal)
                    .Replace(
                        "\"auth_binding\": {\"kind\":\"bearer_header\"}",
                        "\"auth_binding\": {\"kind\":\"none\"}",
                        StringComparison.Ordinal),
            ProviderConnectionJson =
                defaults.ProviderConnectionJson
                    .Replace(
                        "\"credential_slot_required\": true",
                        "\"credential_slot_required\": false",
                        StringComparison.Ordinal)
                    .Replace(
                        "\"credential_ref\": \"connection-1\"",
                        "\"credential_ref\": null",
                        StringComparison.Ordinal)
                    .Replace(
                        "\"auth_binding\": {\"kind\":\"bearer_header\"}",
                        "\"auth_binding\": {\"kind\":\"none\"}",
                        StringComparison.Ordinal)
                    .Replace(
                        "\"approved_credential_origins\": [\"https://api.example.invalid\"]",
                        "\"approved_credential_origins\": []",
                        StringComparison.Ordinal),
            GenerationPresetJson =
                defaults.GenerationPresetJson.Replace(
                    "\"preserve_opaque_state\": false",
                    "\"preserve_opaque_state\": true",
                    StringComparison.Ordinal),
            ReasoningControlJson =
                defaults.ReasoningControlJson.Replace(
                    "\"preserve_opaque_state\": false",
                    "\"preserve_opaque_state\": true",
                    StringComparison.Ordinal),
        };
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());

        await LoadOnlyRouteAsync(viewModel);

        Assert.True(viewModel.CanPreserveOpaqueReasoningState);
        Assert.True(viewModel.PreserveOpaqueReasoningState);
        Assert.True(
            viewModel.SelectedGenerationPreset!
                .Reasoning.PreserveOpaqueState);
    }

    [Fact]
    public async Task HiddenControlsDoNotEraseStoredExplicitPresetValues()
    {
        var api = new FakeNativeApi
        {
            GenerationPresetJson =
                """
                {
                  "id": "preset-1",
                  "model_route_id": "route-1",
                  "display_name": "Preserve explicit state",
                  "values": [],
                  "reasoning": {
                    "mode": "enabled",
                    "effort": null,
                    "budget_tokens": 2048,
                    "summary": "concise",
                    "preserve_opaque_state": true
                  },
                  "prompt_cache": {
                    "mode": "explicit_context",
                    "ttl": {"kind":"long"},
                    "context_reference": "cachedContents/synthetic"
                  },
                  "created_at": "2026-07-31T00:00:00Z",
                  "updated_at": "2026-07-31T00:00:00Z"
                }
                """,
            ReasoningControlJson =
                """
                {
                  "state": "hidden",
                  "settings": {
                    "mode": "enabled",
                    "effort": null,
                    "budget_tokens": 2048,
                    "summary": "concise",
                    "preserve_opaque_state": true
                  },
                  "allowed_modes": [],
                  "allowed_efforts": [],
                  "allowed_summaries": [],
                  "budget_bounds": null,
                  "effort_field": "hidden",
                  "budget_field": "hidden",
                  "summary_field": "hidden",
                  "issues": []
                }
                """,
            PromptCacheControlJson =
                """
                {
                  "state": "hidden",
                  "settings": {
                    "mode": "explicit_context",
                    "ttl": {"kind":"long"},
                    "context_reference": "cachedContents/synthetic"
                  },
                  "allowed_modes": [],
                  "allowed_ttls": [],
                  "supports_custom_ttl": false,
                  "custom_ttl_bounds": null,
                  "ttl_field": "hidden",
                  "context_reference_field": "hidden",
                  "issues": []
                }
                """,
        };
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());

        await viewModel.SelectModelRouteAsync(
            viewModel.ModelRoutes.Single());

        Assert.False(viewModel.ReasoningControlsEnabled);
        Assert.Equal("enabled", viewModel.ReasoningMode);
        Assert.Equal("2048", viewModel.ReasoningBudgetTokens);
        Assert.Equal("concise", viewModel.ReasoningSummary);
        Assert.False(viewModel.PreserveOpaqueReasoningState);
        Assert.False(
            viewModel.SelectedGenerationPreset!
                .Reasoning.PreserveOpaqueState);
        Assert.False(viewModel.PromptCacheControlsEnabled);
        Assert.Equal(
            "explicit_context",
            viewModel.PromptCacheMode);
        Assert.Equal("long", viewModel.PromptCacheTtl);
        Assert.Equal(
            "cachedContents/synthetic",
            viewModel.PromptCacheContextReference);
    }

    [Fact]
    public async Task SignedCatalogRequiresPreparedReviewBeforeActivation()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await viewModel.RefreshAsync();
        var envelope = System.Text.Encoding.UTF8.GetBytes(
            """{"envelope_version":1}""");

        await viewModel.PrepareSignedCatalogImportAsync(envelope);

        Assert.True(viewModel.HasPendingCatalogImport);
        Assert.Equal(
            "prepare_signed_provider_catalog_import",
            api.LastContractOperation);
        Assert.Contains(
            viewModel.CatalogReview,
            item => item.Label == "Exact import-plan digest");
        Assert.DoesNotContain(
            "activated",
            viewModel.CatalogStatus,
            StringComparison.OrdinalIgnoreCase);

        await viewModel.ActivateSignedCatalogImportAsync();

        Assert.False(viewModel.HasPendingCatalogImport);
        Assert.Equal(
            "activate_signed_provider_catalog_import",
            api.LastContractOperation);
        Assert.Contains(
            viewModel.CatalogReview,
            item => item.Label == "Reviewed catalog activated");
        Assert.Equal(
            System.Text.Encoding.UTF8.GetString(envelope),
            api.LastCatalogEnvelopeJson);
    }

    [Fact]
    public async Task InvalidCandidateNeverReachesPresetUpsert()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        await viewModel.SelectModelRouteAsync(
            viewModel.ModelRoutes.Single());
        api.ValidateGenerationPresetCandidateException =
            new CoreInteropException(
                "Synthetic candidate validation failure.");

        var saved = await viewModel.SavePresetAsync();

        Assert.False(saved);
        Assert.Equal(1, api.ValidateGenerationPresetCandidateCount);
        Assert.Equal(
            "validate_generation_preset_candidate",
            api.LastContractOperation);
        Assert.Contains(
            "Could not save generation preset",
            viewModel.ProviderStatus,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task ChatSettingsPersistExactTargetPairInOneSettingsWrite()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "assistant-secret");
        var viewModel = new SettingsViewModel(
            core,
            credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        await viewModel.SelectModelRouteAsync(
            viewModel.ModelRoutes.Single());
        viewModel.SelectedDefaultPreset =
            viewModel.GenerationPresets.Single();
        viewModel.PreservePartialGenerations = false;

        await viewModel.SaveAppSettingsAsync();

        using var settings =
            JsonDocument.Parse(api.LastSettingsJson!);
        Assert.Equal(
            "route-1",
            settings.RootElement
                .GetProperty("selected_model_route_id")
                .GetString());
        Assert.Equal(
            "preset-1",
            settings.RootElement
                .GetProperty("selected_generation_preset_id")
                .GetString());
        Assert.Equal(
            JsonValueKind.Null,
            settings.RootElement
                .GetProperty("selected_provider_profile_id")
                .ValueKind);
        Assert.False(
            settings.RootElement
                .GetProperty("preserve_partial_generations")
                .GetBoolean());
        Assert.Equal(
            "route-1",
            viewModel.SelectedAssistantModelRoute?.Id);
    }

    [Fact]
    public async Task ExistingPresetIdCannotBeSilentlyRetargeted()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        await viewModel.SelectModelRouteAsync(
            viewModel.ModelRoutes.Single());
        viewModel.PresetId = "renamed-preset";

        var saved = await viewModel.SavePresetAsync();

        Assert.False(saved);
        Assert.Equal(0, api.ValidateGenerationPresetCandidateCount);
        Assert.Contains(
            "preset ID is immutable",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task FreshDiscoveryUsesVisibleExecutableAppDefaultTarget()
    {
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
            SettingsJson =
                SettingsWithDefaultRoute(
                    "route-1",
                    "preset-1"),
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "assistant-secret");
        var viewModel = new SettingsViewModel(
            core,
            credentials);
        await viewModel.RefreshAsync();
        viewModel.SelectedSetupMode =
            viewModel.SetupModes.Single(option =>
                option.Mode ==
                ProviderSetupMode.WebsiteDiscovery);
        viewModel.SiteUrl =
            "https://console.example.invalid/api-keys";
        viewModel.AssistantConsentRequested = true;

        var selected =
            Assert.IsType<AssistantModelRouteOption>(
                viewModel.SelectedAssistantModelRoute);
        Assert.Equal("preset-1", selected.Preset.Id);
        Assert.Contains(
            "executable app-default route and preset",
            viewModel.AssistantModelRouteSelectionSummary,
            StringComparison.OrdinalIgnoreCase);
        Assert.True(viewModel.CanStartDiscovery);

        await viewModel.StartDiscoveryAsync(
            credential: null,
            curlExample: null,
            assistantConsent: true,
            probeConsent: false);
        viewModel.StopMonitoring();

        using var request = JsonDocument.Parse(
            api.LastBeginProviderDiscoveryRequestJson!);
        Assert.Equal(
            "route-1",
            request.RootElement
                .GetProperty("payload")
                .GetProperty("input")
                .GetProperty(
                    "preferred_assistant_model_route_id")
                .GetString());
    }

    [Fact]
    public async Task DeterministicDiscoveryStartsWithoutAssistantRoute()
    {
        var api = new FakeNativeApi
        {
            ModelRoutesJsonOverride = "[]",
            ModelSyncJobsJsonOverride = "[]",
        };
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());
        await viewModel.RefreshAsync();
        viewModel.SelectedSetupMode =
            viewModel.SetupModes.Single(option =>
                option.Mode ==
                ProviderSetupMode.WebsiteDiscovery);
        viewModel.SiteUrl =
            "https://console.example.invalid/api-keys";
        viewModel.AssistantConsentRequested = true;

        Assert.Null(viewModel.SelectedAssistantModelRoute);
        Assert.False(viewModel.AssistantConsentRequested);
        Assert.True(viewModel.CanStartDiscovery);

        await viewModel.StartDiscoveryAsync(
            credential: null,
            curlExample: null,
            assistantConsent: true,
            probeConsent: false);

        viewModel.StopMonitoring();

        using var request = JsonDocument.Parse(
            api.LastBeginProviderDiscoveryRequestJson!);
        Assert.Equal(
            JsonValueKind.Null,
            request.RootElement
                .GetProperty("payload")
                .GetProperty("input")
                .GetProperty(
                    "preferred_assistant_model_route_id")
                .ValueKind);
    }

    [Theory]
    [InlineData("retired", true, "preset-1")]
    [InlineData("access_denied", true, "preset-1")]
    [InlineData("available", false, "preset-1")]
    [InlineData("available", true, "missing-preset")]
    public async Task IneligibleDefaultNeverBecomesAssistantTarget(
        string availability,
        bool hasCredential,
        string presetId)
    {
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
            SettingsJson =
                SettingsWithDefaultRoute(
                    "route-1",
                    presetId),
        };
        api.ModelRouteJson =
            api.ModelRouteJson.Replace(
                "\"availability\": \"available\"",
                $"\"availability\": \"{availability}\"",
                StringComparison.Ordinal);
        var credentials = new RecordingCredentialStore();
        if (hasCredential)
        {
            credentials.Save(
                "connection-1",
                "assistant-secret");
        }
        using var core = Open(api);
        var viewModel =
            new SettingsViewModel(core, credentials);

        await viewModel.RefreshAsync();
        viewModel.SelectedSetupMode =
            viewModel.SetupModes.Single(option =>
                option.Mode ==
                ProviderSetupMode.WebsiteDiscovery);
        viewModel.SiteUrl =
            "https://console.example.invalid/api-keys";
        viewModel.AssistantConsentRequested = true;

        Assert.Null(viewModel.SelectedAssistantModelRoute);
        Assert.False(viewModel.AssistantConsentRequested);
        Assert.True(viewModel.CanStartDiscovery);

        await viewModel.StartDiscoveryAsync(
            credential: null,
            curlExample: null,
            assistantConsent: true,
            probeConsent: false);
        viewModel.StopMonitoring();

        using var request = JsonDocument.Parse(
            api.LastBeginProviderDiscoveryRequestJson!);
        Assert.Equal(
            JsonValueKind.Null,
            request.RootElement
                .GetProperty("payload")
                .GetProperty("input")
                .GetProperty(
                    "preferred_assistant_model_route_id")
                .ValueKind);
    }

    [Fact]
    public async Task RestoredPreGrantSessionNeverGuessesChangedDefaultRoute()
    {
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
        };
        var routeTwo = api.ModelRouteJson
            .Replace(
                "\"route-1\"",
                "\"route-2\"",
                StringComparison.Ordinal)
            .Replace(
                "\"model-1\"",
                "\"model-2\"",
                StringComparison.Ordinal)
            .Replace(
                "\"Model One\"",
                "\"Model Two\"",
                StringComparison.Ordinal);
        api.ModelRoutesJsonOverride =
            $"[{api.ModelRouteJson},{routeTwo}]";
        api.SettingsJson = SettingsWithDefaultRoute(
            "route-1",
            "preset-1");
        api.ProviderDiscoverySnapshotJson =
            AwaitingMoreEvidenceSnapshot(
                api.ProviderDiscoverySnapshotJson);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "assistant-secret");

        using (var firstCore = Open(api))
        {
            var first = new SettingsViewModel(
                firstCore,
                credentials);
            await first.RefreshAsync();
            first.SelectedSetupMode =
                first.SetupModes.Single(option =>
                    option.Mode ==
                    ProviderSetupMode.WebsiteDiscovery);
            first.SiteUrl =
                "https://console.example.invalid/api-keys";
            first.AssistantConsentRequested = true;

            Assert.Equal(
                "route-1",
                first.SelectedAssistantModelRoute?.Id);
            await first.StartDiscoveryAsync(
                credential: null,
                curlExample: null,
                assistantConsent: true,
                probeConsent: false);
            Assert.True(first.CanContinueDiscovery);
            first.StopMonitoring();
        }

        api.GenerationPresetJson =
            api.GenerationPresetJson
                .Replace(
                    "\"preset-1\"",
                    "\"preset-2\"",
                    StringComparison.Ordinal)
                .Replace(
                    "\"route-1\"",
                    "\"route-2\"",
                    StringComparison.Ordinal);
        api.SettingsJson = SettingsWithDefaultRoute(
            "route-2",
            "preset-2");
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var restartedCore = Open(api);
        var restarted = new SettingsViewModel(
            restartedCore,
            credentials);

        await restarted.RefreshAsync();
        restarted.StopMonitoring();

        Assert.Null(
            restarted.SelectedAssistantModelRoute);
        Assert.False(restarted.CanContinueDiscovery);
        Assert.Contains(
            "does not expose its frozen assistant route",
            restarted.AssistantModelRouteSelectionSummary,
            StringComparison.OrdinalIgnoreCase);

        await restarted.ContinueDiscoveryAsync();

        Assert.Null(
            api.LastContinueProviderDiscoveryRequestJson);
        Assert.Contains(
            "cannot prove which assistant route was frozen",
            restarted.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task RestoredApprovedGrantNeverSubstitutesChangedDefaultRoute()
    {
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
        };
        var routeTwo = api.ModelRouteJson
            .Replace(
                "\"route-1\"",
                "\"route-2\"",
                StringComparison.Ordinal)
            .Replace(
                "\"model-1\"",
                "\"model-2\"",
                StringComparison.Ordinal)
            .Replace(
                "\"Model One\"",
                "\"Model Two\"",
                StringComparison.Ordinal);
        api.ModelRoutesJsonOverride =
            $"[{api.ModelRouteJson},{routeTwo}]";
        api.GenerationPresetJson =
            api.GenerationPresetJson
                .Replace(
                    "\"preset-1\"",
                    "\"preset-2\"",
                    StringComparison.Ordinal)
                .Replace(
                    "\"route-1\"",
                    "\"route-2\"",
                    StringComparison.Ordinal);
        api.SettingsJson = SettingsWithDefaultRoute(
            "route-2",
            "preset-2");
        api.ProviderDiscoverySnapshotJson =
            ApprovedAssistantResumeSnapshot(
                api.ProviderDiscoverySnapshotJson);
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        var credentials = new RecordingCredentialStore();
        credentials.Save(
            "connection-1",
            "assistant-secret");
        using var core = Open(api);
        var viewModel =
            new SettingsViewModel(core, credentials);

        await viewModel.RefreshAsync();
        viewModel.StopMonitoring();

        Assert.Null(viewModel.SelectedAssistantModelRoute);
        Assert.True(viewModel.CanRetryAssistant);
        Assert.Contains(
            "route route-1",
            viewModel.AssistantModelRouteSelectionSummary,
            StringComparison.OrdinalIgnoreCase);

        await viewModel.RetryAssistantAsync();

        Assert.Null(api.LastContractOperation);
        Assert.Contains(
            "no model call was made",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task AssistantGrantShowsExactIdentityAndNeedsDedicatedApproval()
    {
        var api = new FakeNativeApi
        {
            ModelSyncJobsJsonOverride = "[]",
            SettingsJson =
                SettingsWithDefaultRoute(
                    "route-1",
                    "preset-1"),
        };
        api.ProviderDiscoverySnapshotJson =
            AssistantConsentSnapshot(
                api.ProviderDiscoverySnapshotJson);
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "assistant-secret");
        var viewModel =
            new SettingsViewModel(core, credentials);

        await viewModel.RefreshAsync();
        viewModel.StopMonitoring();

        Assert.Equal(
            "route-1",
            viewModel.SelectedAssistantModelRoute?.Id);
        Assert.Contains(
            viewModel.AssistantGrantReview,
            item => item.Label ==
                    "Assistant model identity"
                && item.Detail.Contains(
                    "route route-1",
                    StringComparison.Ordinal));
        Assert.Contains(
            viewModel.AssistantGrantReview,
            item => item.Label ==
                    "Allowed document origin"
                && item.Detail ==
                    "https://docs.example.invalid");
        Assert.Contains(
            viewModel.AssistantGrantReview,
            item => item.Label == "Evidence ID"
                && item.Detail == "evidence-doc-1");
        Assert.Contains(
            viewModel.AssistantGrantReview,
            item => item.Label ==
                    "Bounded assistant budget"
                && item.Detail.Contains(
                    "2 call(s)",
                    StringComparison.Ordinal)
                && item.Detail.Contains(
                    "tools ≤3",
                    StringComparison.Ordinal)
                && item.Detail.Contains(
                    "cost ≤50000",
                    StringComparison.Ordinal));
        Assert.True(viewModel.CanApproveAssistantGrant);
        Assert.True(viewModel.CanDeclineAssistantGrant);
        Assert.False(viewModel.CanContinueDiscovery);

        await viewModel.ContinueDiscoveryAsync();

        Assert.Null(
            api.LastContinueProviderDiscoveryRequestJson);
        Assert.Contains(
            "exact assistant grant approval",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);

        await viewModel.ApproveAssistantGrantAsync();

        using var request = JsonDocument.Parse(
            api.LastContinueProviderDiscoveryRequestJson!);
        var action = request.RootElement
            .GetProperty("payload")
            .GetProperty("envelope")
            .GetProperty("action");
        Assert.Equal(
            "approve_assistant",
            action.GetProperty("kind").GetString());
        Assert.Equal(
            "assistant-approval-1",
            action.GetProperty("approval_id").GetString());
        Assert.Equal(
            new string('d', 64),
            action.GetProperty(
                "approval_grant_sha256").GetString());
    }

    [Fact]
    public async Task RestartedAssistantEvidenceUsesPersistedExactNetworkPolicy()
    {
        var api = new FakeNativeApi();
        api.ProviderDiscoverySnapshotJson =
            api.ProviderDiscoverySnapshotJson
                .Replace(
                    "\"state\": \"awaiting_template_selection\"",
                    "\"state\": \"awaiting_more_evidence\"",
                    StringComparison.Ordinal)
                .Replace(
                    "{\"kind\":\"select_template\"}",
                    "{\"kind\":\"supply_more_evidence\"}",
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
                      "checkpoint": "awaiting_more_evidence",
                      "action": "supply_more_evidence",
                      "questions": [
                        {
                          "id": "question-1",
                          "field": {"kind":"models_endpoint"},
                          "question": "Where is the official models endpoint documented?",
                          "required_evidence": "One official document URL or redacted cURL"
                        }
                      ],
                      "draft_review": null
                    }
                    """,
                    StringComparison.Ordinal);
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel =
            new SettingsViewModel(core, credentials);

        await viewModel.RefreshAsync();

        Assert.True(viewModel.CanSupplyDiscoveryEvidence);
        Assert.Equal(
            ProviderNetworkMode.ApprovedLocalNetwork,
            viewModel.SelectedNetworkMode?.Mode);
        Assert.Equal(
            "http://models.lan:11434",
            viewModel.LocalNetworkOrigin);
        Assert.Contains(
            viewModel.DiscoveryProgress,
            item => item.Label.Contains(
                "models endpoint",
                StringComparison.OrdinalIgnoreCase));

        const string rawSecret = "supplemental-secret";
        await viewModel.SupplyDiscoveryEvidenceAsync(
            $"curl https://api.example.invalid/v1/models -H 'Authorization: Bearer {rawSecret}'");

        Assert.Equal(
            [("connection-1", "curl-secret")],
            credentials.Writes);
        Assert.Equal(
            "curl -H 'authorization: [REDACTED]'",
            api.LastProviderDiscoveryRawCurl);
        Assert.DoesNotContain(
            rawSecret,
            api.LastProviderDiscoveryRawCurl,
            StringComparison.Ordinal);
        using var inspectionRequest = JsonDocument.Parse(
            api.LastProviderCurlInspectionRequestJson!);
        var options = inspectionRequest.RootElement
            .GetProperty("payload")
            .GetProperty("connection_options");
        Assert.Equal(
            "approved_local_network",
            options.GetProperty("network_mode").GetString());
        Assert.Equal(
            "http://models.lan:11434",
            options.GetProperty("local_network_approval")
                .GetProperty("origin")
                .GetString());
        viewModel.StopMonitoring();
    }

    [Fact]
    public async Task RestartedCoreHostActionRequiresExplicitResumeAndNoModelCall()
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
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());

        await viewModel.RefreshAsync();
        viewModel.StopMonitoring();

        Assert.True(viewModel.CanRetryAssistant);
        Assert.Null(api.LastContractOperation);

        await viewModel.RetryAssistantAsync();

        Assert.Equal(
            "resume_provider_discovery_assistant_core_host_action",
            api.LastContractOperation);
        Assert.Null(api.LastProviderDiscoveryCredential);
        Assert.Contains(
            "without a model call",
            viewModel.DiscoveryActionSummary,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task RestartedTypedDraftCanBeReviewedAndAccepted()
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
                    "\"assistant_resume_boundary\": null",
                    """
                    "assistant_resume_boundary": {
                      "checkpoint": "draft_ready",
                      "action": "review_draft",
                      "questions": [],
                      "draft_review": {
                        "draft": {
                          "manifest": {
                            "schema_version": 1,
                            "api_family": "openai_chat_completions",
                            "sources": [],
                            "default_api_origin": null,
                            "auth": {"kind":"none"},
                            "endpoints": {
                              "models": null,
                              "generate": {
                                "method": "POST",
                                "path": "/v1/chat/completions"
                              }
                            },
                            "decoders": {
                              "response": "open_ai_json_v1",
                              "streaming": null
                            },
                            "parameters": []
                          },
                          "evidence_mappings": [],
                          "conflicts": [],
                          "unresolved_questions": [],
                          "confidence": [],
                          "summary": "Restart-safe typed provider draft"
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
                    StringComparison.Ordinal);
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());

        await viewModel.RefreshAsync();

        Assert.True(viewModel.CanAcceptAssistantDraft);
        Assert.Contains(
            viewModel.DiscoveryProgress,
            item => item.Label ==
                "Assistant draft awaiting review");

        await viewModel.AcceptAssistantDraftAsync();

        Assert.Equal(
            "accept_provider_discovery_assistant_draft",
            api.LastContractOperation);
        viewModel.StopMonitoring();
    }

    [Fact]
    public async Task CredentialCompensationUsesOnlyExactPendingSlot()
    {
        var monitorEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseMonitor = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            BeforeGetProviderDiscovery = () =>
            {
                monitorEntered.TrySetResult();
                if (!releaseMonitor.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test discovery monitor was not released.");
                }
            },
        };
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "credential");
        credentials.Writes.Clear();
        var viewModel =
            new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await monitorEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        api.ProviderDiscoverySnapshotJson =
            CompensatingSnapshot(api.ProviderDiscoverySnapshotJson);
        api.ProviderDiscoveryCompensationStepsJson =
            CompensationStepsJson("connection-1");

        var cancellation = viewModel.CancelDiscoveryAsync();
        Assert.False(cancellation.IsCompleted);
        releaseMonitor.TrySetResult();
        await cancellation;

        Assert.Equal(["connection-1"], credentials.Deletes);
        Assert.Equal(
            1,
            api.StartProviderDiscoveryCredentialCompensationCount);
        Assert.Equal(
            "complete_provider_discovery_credential_compensation",
            api.LastContractOperation);
        viewModel.StopMonitoring();
    }

    [Fact]
    public async Task CompensationCompletionKeepsProviderSelectionLocked()
    {
        var completionEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseCompletion = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            BeforeCompleteProviderDiscoveryCompensation = () =>
            {
                completionEntered.TrySetResult();
                if (!releaseCompletion.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test compensation completion was not released.");
                }
            },
        };
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "credential");
        credentials.Writes.Clear();
        var viewModel =
            new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.StopMonitoring();
        api.ProviderDiscoverySnapshotJson =
            CompensatingSnapshot(api.ProviderDiscoverySnapshotJson);
        api.ProviderDiscoveryCompensationStepsJson =
            CompensationStepsJson("connection-1");

        var cancellation = viewModel.CancelDiscoveryAsync();
        await completionEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        var originalConnectionId = viewModel.ConnectionId;
        viewModel.BeginNewConnection();
        try
        {
            Assert.False(cancellation.IsCompleted);
            Assert.True(viewModel.HasActiveDiscovery);
            Assert.Equal(
                originalConnectionId,
                viewModel.ConnectionId);
            api.ProviderDiscoverySnapshotJson =
                api.ProviderDiscoverySnapshotJson.Replace(
                    "\"state\": \"compensating\"",
                    "\"state\": \"cancelled\"",
                    StringComparison.Ordinal);
        }
        finally
        {
            releaseCompletion.TrySetResult();
        }

        await cancellation;
        Assert.Equal(
            originalConnectionId,
            viewModel.ConnectionId);
        Assert.False(viewModel.HasActiveDiscovery);
        Assert.Equal(["connection-1"], credentials.Deletes);
    }

    [Fact]
    public async Task UnknownCredentialCompensationIsNeverRetriedOnRefresh()
    {
        var api = new FakeNativeApi();
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var credentials =
            new UnknownDeleteCredentialStore(api);
        var viewModel =
            new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.StopMonitoring();
        api.ProviderDiscoverySnapshotJson =
            CompensatingSnapshot(api.ProviderDiscoverySnapshotJson);
        api.ProviderDiscoveryCompensationStepsJson =
            CompensationStepsJson("connection-1");

        await viewModel.CancelDiscoveryAsync();

        Assert.Equal(1, credentials.DeleteCount);
        Assert.Equal(
            "mark_provider_discovery_credential_compensation_unknown",
            api.LastContractOperation);
        Assert.Contains(
            "will not be retried automatically",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);

        await viewModel.RefreshAsync();
        await Task.Delay(100);

        Assert.Equal(1, credentials.DeleteCount);
        viewModel.StopMonitoring();
    }

    [Fact]
    public async Task InvalidDiscoveryEventIsNeverDisplayedOrAcknowledged()
    {
        var api = new FakeNativeApi
        {
            ProviderDiscoveryEventsJson =
                """
                [
                  {
                    "event": {
                      "event_version": 3,
                      "event_id": "future-event",
                      "session_id": "discovery-1",
                      "sequence": 1,
                      "session_revision": 2,
                      "state": "awaiting_template_selection",
                      "progress": null,
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
                """,
        };
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var viewModel = new SettingsViewModel(
            core,
            new RecordingCredentialStore());

        await viewModel.RefreshAsync();
        await Task.Delay(100);

        Assert.Null(
            api.LastAckedProviderDiscoveryEventId);
        Assert.DoesNotContain(
            viewModel.DiscoveryProgress,
            item => item.Detail.Contains(
                "future-event",
                StringComparison.Ordinal));
        viewModel.StopMonitoring();
    }

    private static string CompensatingSnapshot(
        string snapshot) =>
        snapshot
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

    private static string CompensationStepsJson(
        string connectionId) =>
        $$"""
        [
          {
            "id": "credential-step-1",
            "commit_attempt_id": "attempt-1",
            "ordinal": 1,
            "action_id": "compensation-action-1",
            "kind": "remove_credential_slot",
            "target": {
              "kind": "remove_credential_slot",
              "connection_id": "{{connectionId}}",
              "credential_ref": "{{connectionId}}"
            },
            "status": "pending",
            "attempt_count": 0,
            "last_failure": null,
            "created_at": "2026-07-31T00:00:00Z",
            "updated_at": "2026-07-31T00:00:00Z",
            "completed_at": null
          }
        ]
        """;

    private static string SettingsWithDefaultRoute(
        string routeId,
        string presetId) =>
        $$"""
        {
          "preserve_partial_generations": true,
          "selected_provider_profile_id": null,
          "selected_model_route_id": "{{routeId}}",
          "selected_generation_preset_id": "{{presetId}}"
        }
        """;

    private static string AwaitingMoreEvidenceSnapshot(
        string snapshot) =>
        snapshot
            .Replace(
                "\"state\": \"awaiting_template_selection\"",
                "\"state\": \"awaiting_more_evidence\"",
                StringComparison.Ordinal)
            .Replace(
                "{\"kind\":\"select_template\"}",
                "{\"kind\":\"supply_more_evidence\"}",
                StringComparison.Ordinal);

    private static string AssistantConsentSnapshot(
        string snapshot) =>
        snapshot
            .Replace(
                "\"state\": \"awaiting_template_selection\"",
                "\"state\": \"awaiting_assistant_consent\"",
                StringComparison.Ordinal)
            .Replace(
                "{\"kind\":\"select_template\"}",
                "{\"kind\":\"approve_assistant\"}",
                StringComparison.Ordinal)
            .Replace(
                "\"approval_proposal\": null",
                $$"""
                "approval_proposal": {
                  "approval_id": "assistant-approval-1",
                  "grant": {
                    "kind": "assistant_consent",
                    "candidate_id": null,
                    "assistant_model_route_id": "route-1",
                    "evidence_ids": ["evidence-doc-1"],
                    "allowed_document_origins": [
                      "https://docs.example.invalid"
                    ],
                    "max_calls": 2,
                    "max_input_tokens": 1200,
                    "max_output_tokens": 300,
                    "max_tool_calls": 3,
                    "max_retries": 1,
                    "max_cost_micro_units": 50000,
                    "origin": null,
                    "auth_binding": null,
                    "manifest_sha256": null,
                    "model_route_ids": null,
                    "budget": null,
                    "review_sha256": null,
                    "graph_sha256": null,
                    "operation": null,
                    "resolution": null
                  },
                  "grant_sha256": "{{new string('d', 64)}}"
                }
                """,
                StringComparison.Ordinal);

    private static string ApprovedAssistantResumeSnapshot(
        string snapshot) =>
        snapshot
            .Replace(
                "\"state\": \"awaiting_template_selection\"",
                "\"state\": \"building_assistant_manifest_draft\"",
                StringComparison.Ordinal)
            .Replace(
                "\"action_required\": {\"kind\":\"select_template\"}",
                "\"action_required\": null",
                StringComparison.Ordinal)
            .Replace(
                "\"approvals\": []",
                """
                "approvals": [
                  {
                    "id": "assistant-approval-1",
                    "session_revision": 2,
                    "decision": "approved",
                    "grant": {
                      "kind": "assistant_consent",
                      "candidate_id": null,
                      "assistant_model_route_id": "route-1",
                      "evidence_ids": ["evidence-doc-1"],
                      "allowed_document_origins": [
                        "https://docs.example.invalid"
                      ],
                      "max_calls": 2,
                      "max_input_tokens": 1200,
                      "max_output_tokens": 300,
                      "max_tool_calls": 3,
                      "max_retries": 1,
                      "max_cost_micro_units": 50000,
                      "origin": null,
                      "auth_binding": null,
                      "manifest_sha256": null,
                      "model_route_ids": null,
                      "budget": null,
                      "review_sha256": null,
                      "graph_sha256": null,
                      "operation": null,
                      "resolution": null
                    },
                    "created_at": "2026-07-31T00:00:01Z"
                  }
                ]
                """,
                StringComparison.Ordinal)
            .Replace(
                "\"assistant_resume_boundary\": null",
                """
                "assistant_resume_boundary": {
                  "checkpoint": "ready",
                  "action": "run_assistant",
                  "questions": [],
                  "draft_review": null
                }
                """,
                StringComparison.Ordinal);

    private static void AssertReasoningCandidate(
        string requestJson,
        string expectedMode,
        string? expectedEffort,
        uint? expectedBudgetTokens,
        string expectedSummary)
    {
        using var request = JsonDocument.Parse(requestJson);
        var reasoning = request.RootElement
            .GetProperty("payload")
            .GetProperty("reasoning");
        Assert.Equal(
            expectedMode,
            reasoning.GetProperty("mode").GetString());
        if (expectedEffort is null)
        {
            Assert.Equal(
                JsonValueKind.Null,
                reasoning.GetProperty("effort").ValueKind);
        }
        else
        {
            Assert.Equal(
                expectedEffort,
                reasoning.GetProperty("effort").GetString());
        }
        if (expectedBudgetTokens is null)
        {
            Assert.Equal(
                JsonValueKind.Null,
                reasoning.GetProperty("budget_tokens").ValueKind);
        }
        else
        {
            Assert.Equal(
                expectedBudgetTokens.Value,
                reasoning.GetProperty("budget_tokens").GetUInt32());
        }
        Assert.Equal(
            expectedSummary,
            reasoning.GetProperty("summary").GetString());
    }

    private static CoreClient Open(FakeNativeApi api)
    {
        return CoreClient.Open(
            api,
            Path.Combine(
                Path.GetTempPath(),
                "lorepia-settings-durable-provider-tests",
                Guid.NewGuid().ToString("N")));
    }

    private static async Task LoadOnlyRouteAsync(
        SettingsViewModel viewModel)
    {
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        await viewModel.SelectModelRouteAsync(
            viewModel.ModelRoutes.Single());
    }

    private const string VisibleReasoningDefaultControlJson =
        """
        {
          "state": "ready",
          "settings": {
            "mode": "enabled",
            "effort": "high",
            "budget_tokens": null,
            "summary": "provider_default",
            "preserve_opaque_state": false
          },
          "allowed_modes": ["provider_default", "enabled"],
          "allowed_efforts": ["low", "high"],
          "allowed_summaries": ["provider_default"],
          "budget_bounds": null,
          "effort_field": "enabled",
          "budget_field": "hidden",
          "summary_field": "hidden",
          "issues": []
        }
        """;

    private const string HiddenReasoningEffortControlJson =
        """
        {
          "state": "ready",
          "settings": {
            "mode": "enabled",
            "effort": null,
            "budget_tokens": null,
            "summary": "provider_default",
            "preserve_opaque_state": false
          },
          "allowed_modes": ["provider_default", "enabled"],
          "allowed_efforts": [],
          "allowed_summaries": ["provider_default"],
          "budget_bounds": null,
          "effort_field": "hidden",
          "budget_field": "hidden",
          "summary_field": "hidden",
          "issues": []
        }
        """;

    private const string EnabledHighGenerationPresetJson =
        """
        {
          "id": "preset-1",
          "model_route_id": "route-1",
          "display_name": "Balanced",
          "values": [],
          "reasoning": {
            "mode": "enabled",
            "effort": "high",
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

    private const string ConditionalParameterSpecsJson =
        """
        [
          {
            "id": "mode",
            "label_key": "Mode",
            "description_key": null,
            "value_type": "enum",
            "allowed_values": [
              {"value":{"type":"enum","value":"basic"},"label_key":"Basic"},
              {"value":{"type":"enum","value":"advanced"},"label_key":"Advanced"}
            ],
            "minimum": null,
            "maximum": null,
            "step": null,
            "default_mode": "provider_default",
            "visibility": null,
            "conflicts": [],
            "provider_mapping":{"target":"request_body","field_name":"mode"},
            "level":"basic"
          },
          {
            "id": "advanced_value",
            "label_key": "Advanced value",
            "description_key": null,
            "value_type": "string",
            "allowed_values": [],
            "minimum": null,
            "maximum": null,
            "step": null,
            "default_mode": "provider_default",
            "visibility": {
              "parameter_id": "mode",
              "operator": "equals",
              "value":{"type":"enum","value":"advanced"}
            },
            "conflicts": [],
            "provider_mapping":{"target":"request_body","field_name":"advanced_value"},
            "level":"advanced"
          },
          {
            "id": "left_option",
            "label_key": "Left option",
            "description_key": null,
            "value_type": "boolean",
            "allowed_values": [],
            "minimum": null,
            "maximum": null,
            "step": null,
            "default_mode": "provider_default",
            "visibility": null,
            "conflicts": [
              {
                "parameter_id":"right_option",
                "kind":"mutually_exclusive",
                "message_key":"exclusive-options"
              }
            ],
            "provider_mapping":{"target":"request_body","field_name":"left"},
            "level":"advanced"
          },
          {
            "id": "right_option",
            "label_key": "Right option",
            "description_key": null,
            "value_type": "boolean",
            "allowed_values": [],
            "minimum": null,
            "maximum": null,
            "step": null,
            "default_mode": "provider_default",
            "visibility": null,
            "conflicts": [],
            "provider_mapping":{"target":"request_body","field_name":"right"},
            "level":"advanced"
          },
          {
            "id": "prerequisite",
            "label_key": "Prerequisite",
            "description_key": null,
            "value_type": "string",
            "allowed_values": [],
            "minimum": null,
            "maximum": null,
            "step": null,
            "default_mode": "provider_default",
            "visibility": null,
            "conflicts": [],
            "provider_mapping":{"target":"request_body","field_name":"prerequisite"},
            "level":"advanced"
          },
          {
            "id": "dependent_option",
            "label_key": "Dependent option",
            "description_key": null,
            "value_type": "boolean",
            "allowed_values": [],
            "minimum": null,
            "maximum": null,
            "step": null,
            "default_mode": "provider_default",
            "visibility": null,
            "conflicts": [
              {
                "parameter_id":"prerequisite",
                "kind":"requires",
                "message_key":"requires-prerequisite"
              }
            ],
            "provider_mapping":{"target":"request_body","field_name":"dependent"},
            "level":"advanced"
          }
        ]
        """;

    private sealed class RecordingCredentialStore :
        IProviderCredentialStore
    {
        private readonly Dictionary<string, string> values =
            new(StringComparer.Ordinal);

        internal List<(string ConnectionId, string Credential)> Writes
        {
            get;
        } = [];

        internal List<string> Deletes { get; } = [];

        public string? Get(string connectionId)
        {
            return values.GetValueOrDefault(connectionId);
        }

        public void Save(string connectionId, string credential)
        {
            values[connectionId] = credential;
            Writes.Add((connectionId, credential));
        }

        public void Delete(string connectionId)
        {
            values.Remove(connectionId);
            Deletes.Add(connectionId);
        }
    }

    private sealed class UnknownDeleteCredentialStore(
        FakeNativeApi api) : IProviderCredentialStore
    {
        internal int DeleteCount { get; private set; }

        public string? Get(string connectionId) =>
            "credential";

        public void Save(
            string connectionId,
            string credential)
        {
        }

        public void Delete(string connectionId)
        {
            DeleteCount += 1;
            var unknown = api.ProviderDiscoverySnapshotJson
                .Replace(
                    "\"state\": \"compensating\"",
                    "\"state\": \"unknown_outcome\"",
                    StringComparison.Ordinal)
                .Replace(
                    "\"unknown_operation\": null",
                    "\"unknown_operation\": \"compensation\"",
                    StringComparison.Ordinal)
                .Replace(
                    "\"action_required\": null",
                    """
                    "action_required": {
                      "kind": "reconcile_unknown_outcome",
                      "operation": "compensation"
                    }
                    """,
                    StringComparison.Ordinal);
            api.ProviderDiscoverySnapshotJson = unknown;
            api.ProviderDiscoveriesJson = $"[{unknown}]";
            throw new InvalidOperationException(
                "Synthetic uncertain PasswordVault delete.");
        }
    }
}
