using Lorepia.Native;
using Lorepia.App.Platform;

namespace Lorepia.App.ViewModels;

public sealed class SettingsViewModel : ObservableObject
{
    private string abiVersion = "—";
    private string coreVersion = "—";
    private string database = "—";
    private string dataRoot = "—";
    private string staging = "—";
    private string recovery = "—";
    private string status = "Not checked";
    private bool isRefreshing;

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

    public bool IsRefreshing
    {
        get => isRefreshing;
        private set => SetProperty(ref isRefreshing, value);
    }

    public async Task RefreshAsync()
    {
        if (IsRefreshing)
        {
            return;
        }

        IsRefreshing = true;
        Status = "Checking native core…";

        try
        {
            var result = await Task.Run(() =>
            {
                using var client = CoreClient.Open(
                    WindowsDataRoot.GetOrCreate());
                return (
                    client.AbiVersion,
                    Version: client.GetCoreVersion(),
                    Health: client.GetHealthCheck());
            });

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
        }
        catch (Exception exception)
        {
            Status = exception.Message;
        }
        finally
        {
            IsRefreshing = false;
        }
    }
}
