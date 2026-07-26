using Lorepia.Native;

namespace Lorepia.App.ViewModels;

public sealed class ShellViewModel : ObservableObject
{
    private readonly CoreClient core;
    private string coreVersionLabel = "Core: checking…";
    private string healthLabel = "Health check pending";

    public string CoreVersionLabel
    {
        get => coreVersionLabel;
        private set => SetProperty(ref coreVersionLabel, value);
    }

    public string HealthLabel
    {
        get => healthLabel;
        private set => SetProperty(ref healthLabel, value);
    }

    internal ShellViewModel(CoreClient core)
    {
        this.core = core;
    }

    public async Task RefreshCoreStatusAsync()
    {
        CoreVersionLabel = "Core: checking…";
        HealthLabel = "Health check pending";

        try
        {
            var result = await Task.Run(() =>
            {
                var version = core.GetCoreVersion();
                var health = core.GetHealthCheck();
                return (core.AbiVersion, version, health);
            });

            CoreVersionLabel = $"Core {result.version} · ABI {result.AbiVersion}";
            HealthLabel = result.health.DatabaseOpen
                ? $"DB schema {result.health.SchemaVersion}"
                : "Core ready · database closed";
        }
        catch (Exception exception)
        {
            CoreVersionLabel = "Core unavailable";
            HealthLabel = exception.Message;
        }
    }
}
