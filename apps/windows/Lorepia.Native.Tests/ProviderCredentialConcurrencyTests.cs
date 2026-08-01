using Lorepia.App.Platform;
using Lorepia.App.ViewModels;

namespace Lorepia.Native.Tests;

public sealed class ProviderCredentialConcurrencyTests
{
    [Fact]
    public async Task InFlightSaveRejectsReentryAndCredentialRemoval()
    {
        var entered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            BeforeCreateProviderConnection = () =>
            {
                entered.TrySetResult();
                if (!release.Task.Wait(TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test provider creation was not released.");
                }
            },
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        var existingConnection =
            Assert.Single(viewModel.ProviderConnections);
        const string connectionId =
            "connection-concurrent-new";
        PrepareNewConnection(
            viewModel,
            connectionId);

        const string credential = "single-save-secret";
        var firstSave =
            viewModel.SaveConnectionAsync(credential);
        try
        {
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
            Assert.True(viewModel.IsBusy);
            Assert.False(viewModel.CanSaveConnection);
            Assert.Null(viewModel.SelectedConnection);
            Assert.Equal(
                credential,
                credentials.Get(connectionId));

            Assert.False(
                await viewModel.SaveConnectionAsync(credential));
            Assert.Null(viewModel.SelectedConnection);
            Assert.Equal(1, api.CreateProviderConnectionCount);
            Assert.Equal(0, credentials.DeleteCount);
            Assert.Equal(
                credential,
                credentials.Get(connectionId));

            var sameSlotConnection = existingConnection with
            {
                Id = connectionId,
                CredentialRef = connectionId,
            };
            await viewModel.SelectConnectionAsync(
                sameSlotConnection);
            Assert.Null(viewModel.SelectedConnection);
            Assert.False(
                viewModel.CanRemoveSelectedCredential);

            var deletesBefore = credentials.DeleteCount;
            viewModel.RemoveSelectedCredential();
            Assert.Equal(
                deletesBefore,
                credentials.DeleteCount);
            Assert.Equal(
                credential,
                credentials.Get(connectionId));

            api.ProviderConnectionJson =
                api.ProviderConnectionJson.Replace(
                    existingConnection.Id,
                    connectionId,
                    StringComparison.Ordinal);
        }
        finally
        {
            release.TrySetResult();
        }

        Assert.True(await firstSave);
        Assert.False(viewModel.IsBusy);
        Assert.True(viewModel.CanSaveConnection);
        Assert.True(viewModel.CanRemoveSelectedCredential);
        Assert.Equal(1, api.CreateProviderConnectionCount);
        Assert.Equal(
            connectionId,
            Assert.Single(viewModel.ProviderConnections).Id);
        Assert.Equal(
            credential,
            credentials.Get(connectionId));
    }

    [Fact]
    public async Task FailedInFlightSaveCompensatesAndReleasesGuard()
    {
        var entered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            BeforeCreateProviderConnection = () =>
            {
                entered.TrySetResult();
                if (!release.Task.Wait(TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test provider creation was not released.");
                }

                throw new InvalidOperationException(
                    "Synthetic Core create failure.");
            },
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        var existingConnectionId =
            Assert.Single(viewModel.ProviderConnections).Id;
        const string connectionId =
            "connection-failed-new";
        PrepareNewConnection(viewModel, connectionId);

        var save =
            viewModel.SaveConnectionAsync("failed-save-secret");
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        Assert.Equal(
            "failed-save-secret",
            credentials.Get(connectionId));
        release.TrySetResult();

        Assert.False(await save);
        Assert.Null(credentials.Get(connectionId));
        Assert.Equal(1, credentials.DeleteCount);
        Assert.False(viewModel.IsBusy);
        Assert.True(viewModel.CanSaveConnection);

        api.BeforeCreateProviderConnection = null;
        api.ProviderConnectionJson =
            api.ProviderConnectionJson.Replace(
                existingConnectionId,
                connectionId,
                StringComparison.Ordinal);
        viewModel.UpdateCredentialDraft(hasCredential: true);

        Assert.True(
            await viewModel.SaveConnectionAsync(
                "retry-save-secret"));
        Assert.Equal(2, api.CreateProviderConnectionCount);
        Assert.Equal(
            "retry-save-secret",
            credentials.Get(connectionId));
        Assert.Equal(
            connectionId,
            Assert.Single(viewModel.ProviderConnections).Id);
    }

    [Fact]
    public async Task InFlightDiscoveryBlocksProviderSelectionAndStaleApply()
    {
        var beginEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseBegin = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            BeforeBeginProviderDiscovery = () =>
            {
                beginEntered.TrySetResult();
                if (!releaseBegin.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test provider discovery was not released.");
                }
            },
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        var existingConnection =
            Assert.Single(viewModel.ProviderConnections);
        viewModel.BeginNewConnection();
        viewModel.ConnectionDisplayName =
            "Selection race discovery";
        viewModel.ApiOrigin =
            "https://api.example.invalid";
        var originalConnectionId = viewModel.ConnectionId;
        var originalSetupMode = viewModel.SelectedSetupMode;
        var originalTemplate = viewModel.SelectedTemplate;

        const string credential = "discovery-race-secret";
        var discovery = viewModel.StartDiscoveryAsync(
            credential,
            curlExample: null,
            assistantConsent: false,
            probeConsent: false);
        await beginEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        try
        {
            Assert.True(viewModel.IsBusy);
            Assert.False(
                viewModel.CanChangeProviderSelection);
            Assert.False(viewModel.CanChooseProviderTemplate);
            Assert.Equal(
                credential,
                credentials.Get(originalConnectionId));

            viewModel.BeginNewConnection();
            Assert.Equal(
                originalConnectionId,
                viewModel.ConnectionId);

            viewModel.SelectedSetupMode =
                viewModel.SetupModes.Single(option =>
                    option.Mode ==
                    ProviderSetupMode.WebsiteDiscovery);
            Assert.Same(
                originalSetupMode,
                viewModel.SelectedSetupMode);

            viewModel.SelectedTemplate = null;
            Assert.Same(
                originalTemplate,
                viewModel.SelectedTemplate);

            await viewModel.SelectConnectionAsync(
                existingConnection);
            Assert.Null(viewModel.SelectedConnection);
            Assert.Equal(
                originalConnectionId,
                viewModel.ConnectionId);

            viewModel.ConnectionId =
                "connection-defensive-selection-change";
        }
        finally
        {
            releaseBegin.TrySetResult();
        }

        await discovery;
        Assert.False(viewModel.IsBusy);
        Assert.True(viewModel.CanChangeProviderSelection);
        Assert.False(viewModel.HasActiveDiscovery);
        Assert.Equal(
            "connection-defensive-selection-change",
            viewModel.ConnectionId);
        Assert.Equal(
            credential,
            credentials.Get(originalConnectionId));
        Assert.Null(
            credentials.Get(
                "connection-defensive-selection-change"));
        Assert.Equal(0, credentials.DeleteCount);
        Assert.Equal(
            "cancel_provider_discovery",
            api.LastContractOperation);
    }

    [Fact]
    public async Task CancelDuringBeginIsAppliedAfterExactSessionReturns()
    {
        var beginEntered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseBegin = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            BeforeBeginProviderDiscovery = () =>
            {
                beginEntered.TrySetResult();
                if (!releaseBegin.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test provider discovery was not released.");
                }
            },
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel =
            new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.BeginNewConnection();
        viewModel.ConnectionDisplayName =
            "Cancelable discovery";
        viewModel.ApiOrigin =
            "https://api.example.invalid";
        var connectionId = viewModel.ConnectionId;
        api.ProviderDiscoveryCancelSnapshotJson =
            api.ProviderDiscoverySnapshotJson
                .Replace(
                    "connection-1",
                    connectionId,
                    StringComparison.Ordinal)
                .Replace(
                    "\"state\": \"awaiting_template_selection\"",
                    "\"state\": \"cancelled\"",
                    StringComparison.Ordinal);

        var start = viewModel.StartDiscoveryAsync(
            "cancel-secret",
            curlExample: null,
            assistantConsent: false,
            probeConsent: false);
        await beginEntered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));

        await viewModel.CancelDiscoveryAsync();
        Assert.True(viewModel.IsBusy);
        Assert.Contains(
            "Cancelling",
            viewModel.ProviderStatus,
            StringComparison.Ordinal);

        releaseBegin.TrySetResult();
        await start;

        Assert.False(viewModel.IsBusy);
        Assert.False(viewModel.HasActiveDiscovery);
        Assert.False(
            viewModel.CanCancelProviderOperation);
        Assert.Equal(
            "cancel-secret",
            credentials.Get(connectionId));
        Assert.Equal(
            "cancel_provider_discovery",
            api.LastContractOperation);
        Assert.Contains(
            "cancelled",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    private static void PrepareNewConnection(
        SettingsViewModel viewModel,
        string connectionId)
    {
        viewModel.BeginNewConnection();
        viewModel.ConnectionId = connectionId;
        viewModel.ConnectionDisplayName =
            "Credential concurrency test";
        viewModel.ApiOrigin =
            "https://api.example.invalid";
        viewModel.CredentialOriginApproved = true;
        viewModel.UpdateCredentialDraft(hasCredential: true);
    }

    private static CoreClient Open(FakeNativeApi api)
    {
        return CoreClient.Open(
            api,
            Path.GetFullPath(
                Path.Combine(
                    Path.GetTempPath(),
                    $"lorepia-credential-concurrency-{Guid.NewGuid():N}")));
    }

    private sealed class RecordingCredentialStore :
        IProviderCredentialStore
    {
        private readonly Dictionary<string, string> values =
            new(StringComparer.Ordinal);

        internal int DeleteCount { get; private set; }

        public string? Get(string connectionId)
        {
            return values.GetValueOrDefault(connectionId);
        }

        public void Save(
            string connectionId,
            string credential)
        {
            values[connectionId] = credential;
        }

        public void Delete(string connectionId)
        {
            DeleteCount++;
            values.Remove(connectionId);
        }
    }
}
