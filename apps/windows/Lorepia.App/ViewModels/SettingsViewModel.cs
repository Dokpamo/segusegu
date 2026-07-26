using Lorepia.App.Platform;
using Lorepia.Native;
using System.Collections.ObjectModel;

namespace Lorepia.App.ViewModels;

public sealed class SettingsViewModel : ObservableObject
{
    private readonly CoreClient core;
    private readonly IProviderCredentialStore credentials;
    private string abiVersion = "—";
    private string coreVersion = "—";
    private string database = "—";
    private string dataRoot = "—";
    private string staging = "—";
    private string recovery = "—";
    private string status = "Not checked";
    private string providerStatus = "Provider profiles are stored locally.";
    private string profileId = string.Empty;
    private string profileDisplayName = string.Empty;
    private string profileBaseUrl = string.Empty;
    private string profileModel = string.Empty;
    private string profileTimeoutSeconds = "60";
    private ProviderProfile? selectedProfile;
    private ProviderProfile? selectedDefaultProfile;
    private bool preservePartialGenerations = true;
    private bool isRefreshing;

    internal SettingsViewModel(
        CoreClient core,
        IProviderCredentialStore credentials)
    {
        this.core = core;
        this.credentials = credentials;
    }

    public ObservableCollection<ProviderProfile> Profiles { get; } = [];

    public string AbiVersion
    {
        get => abiVersion;
        private set => SetProperty(ref abiVersion, value);
    }

    public string CoreVersion
    {
        get => coreVersion;
        private set => SetProperty(ref coreVersion, value);
    }

    public string Database
    {
        get => database;
        private set => SetProperty(ref database, value);
    }

    public string DataRoot
    {
        get => dataRoot;
        private set => SetProperty(ref dataRoot, value);
    }

    public string Staging
    {
        get => staging;
        private set => SetProperty(ref staging, value);
    }

    public string Recovery
    {
        get => recovery;
        private set => SetProperty(ref recovery, value);
    }

    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public string ProviderStatus
    {
        get => providerStatus;
        private set => SetProperty(ref providerStatus, value);
    }

    public string ProfileId
    {
        get => profileId;
        set => SetProperty(ref profileId, value);
    }

    public string ProfileDisplayName
    {
        get => profileDisplayName;
        set => SetProperty(ref profileDisplayName, value);
    }

    public string ProfileBaseUrl
    {
        get => profileBaseUrl;
        set => SetProperty(ref profileBaseUrl, value);
    }

    public string ProfileModel
    {
        get => profileModel;
        set => SetProperty(ref profileModel, value);
    }

    public string ProfileTimeoutSeconds
    {
        get => profileTimeoutSeconds;
        set => SetProperty(ref profileTimeoutSeconds, value);
    }

    public ProviderProfile? SelectedProfile
    {
        get => selectedProfile;
        set
        {
            if (SetProperty(ref selectedProfile, value) && value is not null)
            {
                ProfileId = value.Id;
                ProfileDisplayName = value.DisplayName;
                ProfileBaseUrl = value.BaseUrl;
                ProfileModel = value.Model;
                ProfileTimeoutSeconds = value.TimeoutSeconds.ToString();
                ProviderStatus =
                    "Profile loaded. A saved credential stays hidden in Windows PasswordVault.";
            }
        }
    }

    public ProviderProfile? SelectedDefaultProfile
    {
        get => selectedDefaultProfile;
        set => SetProperty(ref selectedDefaultProfile, value);
    }

    public bool PreservePartialGenerations
    {
        get => preservePartialGenerations;
        set => SetProperty(ref preservePartialGenerations, value);
    }

    public bool IsRefreshing
    {
        get => isRefreshing;
        private set => SetProperty(ref isRefreshing, value);
    }

    internal async Task RefreshAsync()
    {
        if (IsRefreshing)
        {
            return;
        }

        IsRefreshing = true;
        Status = "Checking native core…";
        ProviderStatus = "Loading provider profiles…";
        try
        {
            var result = await Task.Run(() => (
                core.AbiVersion,
                Version: core.GetCoreVersion(),
                Health: core.GetHealthCheck(),
                Profiles: core.ListProviderProfiles(),
                Settings: core.GetSettings()));

            AbiVersion = result.AbiVersion.ToString();
            CoreVersion = result.Version;
            Database = result.Health.DatabaseOpen
                ? $"Open · schema {result.Health.SchemaVersion}"
                : "Closed";
            DataRoot = result.Health.DataRootWritable
                ? "Writable"
                : "Not writable";
            Staging = result.Health.StagingWritable
                ? "Writable"
                : "Not writable";
            Recovery = result.Health.RecoveryPending
                ? "Pending"
                : "Clear";
            Status = $"Healthy · {result.Health.ActiveJobs} active job(s)";
            ReplaceProfiles(result.Profiles);
            PreservePartialGenerations =
                result.Settings.PreservePartialGenerations;
            SelectedDefaultProfile = Profiles.FirstOrDefault(profile =>
                string.Equals(
                    profile.Id,
                    result.Settings.SelectedProviderProfileId,
                    StringComparison.Ordinal));
            ProviderStatus = Profiles.Count == 0
                ? "No provider profile. Add one to enable chat."
                : $"{Profiles.Count} provider profile(s) stored locally.";
        }
        catch (Exception exception)
        {
            Status = exception.Message;
            ProviderStatus = "Could not load provider settings.";
        }
        finally
        {
            IsRefreshing = false;
        }
    }

    internal void BeginNewProfile()
    {
        SelectedProfile = null;
        ProfileId = string.Empty;
        ProfileDisplayName = string.Empty;
        ProfileBaseUrl = string.Empty;
        ProfileModel = string.Empty;
        ProfileTimeoutSeconds = "60";
        ProviderStatus = "Enter a new OpenAI-compatible provider profile.";
    }

    internal async Task<bool> SaveProfileAsync(string? credential)
    {
        if (!uint.TryParse(
                ProfileTimeoutSeconds,
                out var timeoutSeconds)
            || timeoutSeconds is 0 or > 600)
        {
            ProviderStatus = "Timeout must be a whole number from 1 to 600.";
            return false;
        }

        var profile = new ProviderProfile
        {
            Id = ProfileId.Trim(),
            DisplayName = ProfileDisplayName.Trim(),
            BaseUrl = ProfileBaseUrl.Trim(),
            Model = ProfileModel.Trim(),
            TimeoutSeconds = timeoutSeconds,
        };

        IsRefreshing = true;
        ProviderStatus = "Saving provider profile…";
        try
        {
            var saved = await Task.Run(() =>
                core.UpsertProviderProfile(profile));
            if (!string.IsNullOrWhiteSpace(credential))
            {
                credentials.Save(saved.Id, credential);
            }

            var profiles = await Task.Run(() =>
                core.ListProviderProfiles());
            ReplaceProfiles(profiles);
            SelectedProfile = Profiles.First(item =>
                string.Equals(
                    item.Id,
                    saved.Id,
                    StringComparison.Ordinal));
            ProviderStatus =
                "Provider saved. Credentials are held only by Windows PasswordVault.";
            return true;
        }
        catch (Exception exception)
        {
            ProviderStatus = $"Could not save provider: {exception.Message}";
            return false;
        }
        finally
        {
            IsRefreshing = false;
        }
    }

    internal async Task DeleteSelectedProfileAsync()
    {
        var profile = SelectedProfile;
        if (profile is null)
        {
            return;
        }

        IsRefreshing = true;
        ProviderStatus = "Deleting provider profile…";
        try
        {
            await Task.Run(() => core.DeleteProviderProfile(profile.Id));
            credentials.Delete(profile.Id);
            var state = await Task.Run(() => (
                Profiles: core.ListProviderProfiles(),
                Settings: core.GetSettings()));
            ReplaceProfiles(state.Profiles);
            SelectedDefaultProfile = Profiles.FirstOrDefault(item =>
                string.Equals(
                    item.Id,
                    state.Settings.SelectedProviderProfileId,
                    StringComparison.Ordinal));
            BeginNewProfile();
            ProviderStatus = "Provider profile and its PasswordVault credential were removed.";
        }
        catch (Exception exception)
        {
            ProviderStatus = $"Could not delete provider: {exception.Message}";
        }
        finally
        {
            IsRefreshing = false;
        }
    }

    internal void RemoveSelectedCredential()
    {
        var profile = SelectedProfile;
        if (profile is null)
        {
            return;
        }

        credentials.Delete(profile.Id);
        ProviderStatus = "The PasswordVault credential was removed.";
    }

    internal async Task SaveAppSettingsAsync()
    {
        IsRefreshing = true;
        ProviderStatus = "Saving chat settings…";
        try
        {
            var settings = new AppSettings
            {
                PreservePartialGenerations = PreservePartialGenerations,
                SelectedProviderProfileId = SelectedDefaultProfile?.Id,
            };
            await Task.Run(() => core.UpdateSettings(settings));
            ProviderStatus = "Chat settings saved locally.";
        }
        catch (Exception exception)
        {
            ProviderStatus = $"Could not save chat settings: {exception.Message}";
        }
        finally
        {
            IsRefreshing = false;
        }
    }

    private void ReplaceProfiles(IReadOnlyList<ProviderProfile> profiles)
    {
        var selectedId = SelectedProfile?.Id;
        Profiles.Clear();
        foreach (var profile in profiles)
        {
            Profiles.Add(profile);
        }

        SelectedProfile = Profiles.FirstOrDefault(profile =>
            string.Equals(
                profile.Id,
                selectedId,
                StringComparison.Ordinal));
    }
}
