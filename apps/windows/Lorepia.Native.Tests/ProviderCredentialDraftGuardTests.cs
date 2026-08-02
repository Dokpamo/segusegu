using Lorepia.App.Platform;
using Lorepia.App.ViewModels;
using Lorepia.Native;
using System.Text.Json;

namespace Lorepia.Native.Tests;

public sealed class ProviderCredentialDraftGuardTests
{
    [Fact]
    public void ConnectionSelectionInvalidatesThePreviousCredentialDraft()
    {
        var guard = new ProviderCredentialDraftGuard();
        guard.Update(hasCredential: true, "connection-a");

        guard.Invalidate();

        Assert.Null(guard.Capture("connection-b", "key-for-a"));
    }

    [Fact]
    public void ReturningToOriginalConnectionDoesNotReviveInvalidatedDraft()
    {
        var guard = new ProviderCredentialDraftGuard();
        guard.Update(hasCredential: true, "connection-a");

        guard.Invalidate();
        guard.Invalidate();

        Assert.Null(guard.Capture("connection-a", "stale-key"));
    }

    [Fact]
    public void BlankOrInvalidatedDraftNeverCreatesCredentialWrite()
    {
        var guard = new ProviderCredentialDraftGuard();
        guard.Update(hasCredential: false, "connection-a");
        Assert.Null(guard.Capture("connection-a", string.Empty));

        guard.Update(hasCredential: true, "connection-a");
        guard.Invalidate();
        Assert.Null(guard.Capture("connection-b", "key-for-a"));
    }

    [Fact]
    public void CapturedWriteKeepsConnectionAcrossLaterSelectionChanges()
    {
        var guard = new ProviderCredentialDraftGuard();
        guard.Update(hasCredential: true, "connection-a");

        var write = guard.Capture("connection-a", "key-for-a");
        guard.Invalidate();

        Assert.Equal("connection-a", write?.ConnectionId);
        Assert.Equal("key-for-a", write?.Credential);
        Assert.Null(guard.Capture("connection-b", "key-for-a"));
    }

    [Fact]
    public void CredentialTypedBeforeConnectionIdBindsToCompletedId()
    {
        var guard = new ProviderCredentialDraftGuard();
        guard.Update(hasCredential: true, string.Empty);
        guard.ConnectionIdChanged("c");
        guard.ConnectionIdChanged("connection");
        guard.ConnectionIdChanged("connection-a");

        var write = guard.Capture("connection-a", "draft-key");

        Assert.Equal("connection-a", write?.ConnectionId);
        Assert.Equal("draft-key", write?.Credential);
    }

    [Fact]
    public void ChangingIdAfterCredentialEntryInvalidatesBinding()
    {
        var guard = new ProviderCredentialDraftGuard();
        guard.Update(hasCredential: true, "connection-a");

        guard.ConnectionIdChanged("connection-b");

        Assert.Null(guard.Capture("connection-b", "key-for-a"));
    }

    [Fact]
    public async Task SettingsUsesGeneratedConnectionIdAsCredentialSlot()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.BeginNewConnection();
        viewModel.ConnectionDisplayName = "Test connection";
        viewModel.ApiOrigin = "https://api.example.invalid";
        viewModel.CredentialOriginApproved = true;

        viewModel.UpdateCredentialDraft(hasCredential: true);
        var generatedConnectionId = viewModel.ConnectionId;

        Assert.True(await viewModel.SaveConnectionAsync("key-for-new"));
        Assert.Equal(
            [(generatedConnectionId, "key-for-new")],
            credentials.Writes);
        Assert.StartsWith(
            "connection-",
            generatedConnectionId,
            StringComparison.Ordinal);
        Assert.Equal(
            "create_provider_connection",
            api.LastContractOperation);
    }

    [Fact]
    public async Task SettingsIdChangeAfterCredentialEntryFailsBeforeCoreCall()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.BeginNewConnection();
        viewModel.ConnectionId = "connection-1";
        viewModel.ConnectionDisplayName = "Test connection";
        viewModel.ApiOrigin = "https://api.example.invalid";
        viewModel.CredentialOriginApproved = true;

        viewModel.UpdateCredentialDraft(hasCredential: true);
        viewModel.ConnectionId = "connection-2";

        Assert.Contains(
            "connection ID changed",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
        Assert.False(
            await viewModel.SaveConnectionAsync("key-for-connection-1"));
        Assert.Empty(credentials.Writes);
        Assert.Null(api.LastContractOperation);
        Assert.Contains(
            "could not be bound",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task SelectingAnotherConnectionInvalidatesCredentialDraft()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.BeginNewConnection();
        viewModel.ConnectionId = "connection-1";
        viewModel.UpdateCredentialDraft(hasCredential: true);

        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        viewModel.BeginNewConnection();
        viewModel.ConnectionId = "connection-1";
        viewModel.ConnectionDisplayName = "Test connection";
        viewModel.ApiOrigin = "https://api.example.invalid";
        viewModel.CredentialOriginApproved = true;

        Assert.False(
            await viewModel.SaveConnectionAsync("stale-key"));
        Assert.Empty(credentials.Writes);
    }

    [Fact]
    public async Task ExistingConnectionCredentialReplacementRequiresNewId()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "current-account-key");
        credentials.Writes.Clear();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        viewModel.UpdateCredentialDraft(hasCredential: true);

        var saved = await viewModel.SaveConnectionAsync(
            "different-account-key");

        Assert.False(saved);
        Assert.Equal(
            "current-account-key",
            credentials.Get("connection-1"));
        Assert.Empty(credentials.Writes);
        Assert.Null(api.LastContractOperation);
        Assert.Contains(
            "Create a new connection ID",
            viewModel.ProviderStatus,
            StringComparison.Ordinal);
        Assert.Contains(
            "leave the field blank",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task RejectedExistingConfigEditNeverOverwritesVault()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "current-account-key");
        credentials.Writes.Clear();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        viewModel.ApiBasePath = "/immutable-other-path";
        api.UpsertProviderConnectionException =
            new CoreInteropException(
                "Provider endpoint configuration is immutable.");

        var saved = await viewModel.SaveConnectionAsync(null);

        Assert.False(saved);
        Assert.Equal(
            "current-account-key",
            credentials.Get("connection-1"));
        Assert.Empty(credentials.Writes);
        Assert.Equal(
            "upsert_provider_connection",
            api.LastContractOperation);
    }

    [Fact]
    public async Task ExistingCredentialOriginCannotBeRetargeted()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        await viewModel.SelectConnectionAsync(
            viewModel.ProviderConnections.Single());
        viewModel.ApiOrigin = "https://other.example.invalid";
        viewModel.CredentialOriginApproved = true;

        var saved = await viewModel.SaveConnectionAsync(null);

        Assert.False(saved);
        Assert.Empty(credentials.Writes);
        Assert.Null(api.LastContractOperation);
        Assert.Contains(
            "credential origin is immutable",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ApprovedLanSaveUsesTypedExactGrant()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.BeginNewConnection();
        viewModel.ConnectionDisplayName = "LAN model server";
        viewModel.ApiOrigin = "http://models.lan:11434";
        viewModel.SelectedNetworkMode =
            viewModel.NetworkModes.Single(option =>
                option.Mode ==
                ProviderNetworkMode.ApprovedLocalNetwork);
        viewModel.LocalNetworkOrigin =
            "http://models.lan:11434";
        viewModel.LocalNetworkAddresses =
            $"fd00::24{Environment.NewLine}192.168.10.24";
        viewModel.LocalNetworkAccessApproved = true;
        viewModel.CredentialOriginApproved = true;
        viewModel.UpdateCredentialDraft(hasCredential: true);

        Assert.True(
            await viewModel.SaveConnectionAsync("lan-key"),
            viewModel.ProviderStatus);

        using var request =
            JsonDocument.Parse(api.LastContractRequestJson!);
        var payload =
            request.RootElement.GetProperty("payload");
        Assert.Equal(
            "approved_local_network",
            payload.GetProperty("network_mode").GetString());
        var approval =
            payload.GetProperty("local_network_approval");
        Assert.Equal(
            "http://models.lan:11434",
            approval.GetProperty("origin").GetString());
        Assert.Equal(
            new[] { "192.168.10.24", "fd00::24" },
            approval.GetProperty("addresses")
                .EnumerateArray()
                .Select(item => item.GetString())
                .ToArray());
        Assert.DoesNotContain(
            "local_loopback",
            api.LastContractRequestJson,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task ApprovedLanRejectsPublicOrImplicitAddresses()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.BeginNewConnection();
        viewModel.ConnectionDisplayName = "Invalid LAN server";
        viewModel.ApiOrigin = "http://models.lan:11434";
        viewModel.SelectedNetworkMode =
            viewModel.NetworkModes.Single(option =>
                option.Mode ==
                ProviderNetworkMode.ApprovedLocalNetwork);
        viewModel.LocalNetworkOrigin =
            "http://models.lan:11434";
        viewModel.LocalNetworkAddresses = "8.8.8.8";
        viewModel.LocalNetworkAccessApproved = true;
        viewModel.CredentialOriginApproved = true;
        viewModel.UpdateCredentialDraft(hasCredential: true);

        Assert.False(
            await viewModel.SaveConnectionAsync("lan-key"));
        Assert.Empty(credentials.Writes);
        Assert.Null(api.LastContractOperation);
        Assert.Contains(
            "not an RFC1918",
            viewModel.ProviderStatus,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task CurlDiscoveryInspectsOnceAndBeginsWithRedactedCurl()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.SelectedSetupMode =
            viewModel.SetupModes.Single(option =>
                option.Mode == ProviderSetupMode.CurlExample);
        viewModel.ConnectionDisplayName = "cURL provider";
        var connectionId = viewModel.ConnectionId;

        const string rawSecret = "raw-curl-secret";
        await viewModel.StartDiscoveryAsync(
            credential: null,
            curlExample:
                $"curl https://api.example.invalid/v1/models -H 'Authorization: Bearer {rawSecret}'",
            assistantConsent: false,
            probeConsent: false);
        viewModel.StopMonitoring();

        Assert.Equal(
            "begin_provider_discovery",
            api.LastContractOperation);
        Assert.Equal(
            "curl -H 'authorization: [REDACTED]'",
            api.LastProviderDiscoveryRawCurl);
        Assert.DoesNotContain(
            rawSecret,
            api.LastProviderDiscoveryRawCurl,
            StringComparison.Ordinal);
        Assert.Equal(
            [(connectionId, "curl-secret")],
            credentials.Writes);
    }

    [Fact]
    public async Task WebsiteDiscoveryStartsWithoutManualDisplayName()
    {
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();
        viewModel.SelectedSetupMode =
            viewModel.SetupModes.Single(option =>
                option.Mode ==
                ProviderSetupMode.WebsiteDiscovery);
        var connectionId = viewModel.ConnectionId;
        viewModel.SiteUrl =
            "https://console.example.invalid/api-keys";

        Assert.Equal(
            "Website provider",
            viewModel.ConnectionDisplayName);

        await viewModel.StartDiscoveryAsync(
            credential: "site-api-key",
            curlExample: null,
            assistantConsent: false,
            probeConsent: false);
        viewModel.StopMonitoring();

        Assert.Equal(
            "begin_provider_discovery",
            api.LastContractOperation);
        Assert.Equal(
            [(connectionId, "site-api-key")],
            credentials.Writes);
        using var request =
            JsonDocument.Parse(
                api.LastBeginProviderDiscoveryRequestJson!);
        var payload =
            request.RootElement.GetProperty("payload");
        Assert.Equal(
            "Website provider",
            payload.GetProperty("input")
                .GetProperty("display_name")
                .GetString());
        Assert.Equal(
            "site",
            payload.GetProperty("source")
                .GetProperty("kind")
                .GetString());
    }

    [Fact]
    public async Task SupplementalCurlDiscardsCredentialForKeylessSession()
    {
        var api = new FakeNativeApi();
        api.ProviderDiscoverySnapshotJson =
            api.ProviderDiscoverySnapshotJson
                .Replace(
                    "\"credential_slot_id\": \"connection-1\"",
                    "\"credential_slot_id\": null",
                    StringComparison.Ordinal)
                .Replace(
                    "\"credential_slot_expected\": true",
                    "\"credential_slot_expected\": false",
                    StringComparison.Ordinal)
                .Replace(
                    "\"state\": \"awaiting_template_selection\"",
                    "\"state\": \"awaiting_more_evidence\"",
                    StringComparison.Ordinal)
                .Replace(
                    "{\"kind\":\"select_template\"}",
                    "{\"kind\":\"supply_more_evidence\"}",
                    StringComparison.Ordinal);
        api.ProviderDiscoveriesJson =
            $"[{api.ProviderDiscoverySnapshotJson}]";
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        var viewModel = new SettingsViewModel(core, credentials);
        await viewModel.RefreshAsync();

        await viewModel.SupplyDiscoveryEvidenceAsync(
            "curl https://api.example.invalid/v1/models -H 'Authorization: Bearer supplemental-secret'");

        Assert.Equal(
            "inspect_provider_curl",
            api.LastContractOperation);
        Assert.Empty(credentials.Writes);
        Assert.Contains(
            "credential-free",
            viewModel.ProviderStatus,
            StringComparison.OrdinalIgnoreCase);
    }

    private static CoreClient Open(FakeNativeApi api)
    {
        return CoreClient.Open(
            api,
            Path.GetFullPath(
                Path.Combine(
                    Path.GetTempPath(),
                    $"lorepia-settings-{Guid.NewGuid():N}")));
    }

    private sealed class RecordingCredentialStore :
        IProviderCredentialStore
    {
        private readonly Dictionary<string, string> values =
            new(StringComparer.Ordinal);

        internal List<(string ConnectionId, string Credential)> Writes
        {
            get;
        } = [];

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
        }
    }
}
