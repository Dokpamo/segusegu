using Microsoft.UI.Xaml;

namespace Lorepia.App;

public partial class App : Application
{
    private const string CiSmokeArgument = "--lorepia-ci-smoke";
    private const string CiSmokeMarkerEnvironment =
        "LOREPIA_CI_SMOKE_MARKER";

    internal static Window? MainWindow { get; private set; }

    internal static AppServices Services { get; private set; } = null!;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (IsCiSmoke(args))
        {
            RunCiSmoke();
            return;
        }

        Services = AppServices.Create();
        MainWindow = new MainWindow(Services);
        MainWindow.Closed += (_, _) => Services.Dispose();
        MainWindow.Activate();
    }

    private static bool IsCiSmoke(LaunchActivatedEventArgs args)
    {
        return string.Equals(
                args.Arguments.Trim(),
                CiSmokeArgument,
                StringComparison.Ordinal)
            || Environment.GetCommandLineArgs().Any(argument =>
                string.Equals(
                    argument,
                    CiSmokeArgument,
                    StringComparison.Ordinal));
    }

    private static async void RunCiSmoke()
    {
        var markerPath = Environment.GetEnvironmentVariable(
            CiSmokeMarkerEnvironment);
        var dataRoot = Path.Combine(
            Path.GetTempPath(),
            "LorePia",
            "ci-smoke",
            Guid.NewGuid().ToString("N"));
        var exitCode = 0;
        AppServices? services = null;
        MainWindow? window = null;
        try
        {
            if (string.IsNullOrWhiteSpace(markerPath)
                || !Path.IsPathFullyQualified(markerPath))
            {
                throw new InvalidOperationException(
                    $"{CiSmokeMarkerEnvironment} must be an absolute path.");
            }

            services = AppServices.Create(dataRoot);
            Services = services;
            window = new MainWindow(services);
            MainWindow = window;
            window.Activate();

            using var timeout = new CancellationTokenSource(
                TimeSpan.FromSeconds(15));
            var routeTrace = await window.RunCiNavigationSmokeAsync(
                timeout.Token);
            var version = services.Core.GetCoreVersion();
            var health = services.Core.GetHealthCheck();
            if (string.IsNullOrWhiteSpace(version)
                || !string.Equals(
                    version,
                    health.CoreVersion,
                    StringComparison.Ordinal)
                || !health.DatabaseOpen
                || !health.DataRootWritable
                || !health.StagingWritable)
            {
                throw new InvalidOperationException(
                    "Core version or health validation failed.");
            }

            File.WriteAllText(
                markerPath,
                $"LOREPIA_CI_SMOKE_OK core={version} schema={health.SchemaVersion} routes={routeTrace}");
        }
        catch (Exception exception)
        {
            exitCode = 1;
            if (!string.IsNullOrWhiteSpace(markerPath)
                && Path.IsPathFullyQualified(markerPath))
            {
                try
                {
                    File.WriteAllText(
                        markerPath,
                        $"LOREPIA_CI_SMOKE_FAILED {exception.GetType().Name}");
                }
                catch
                {
                    // The process exit code remains the authoritative failure.
                }
            }
        }
        finally
        {
            try
            {
                window?.Close();
            }
            catch
            {
                exitCode = 1;
            }

            MainWindow = null;
            try
            {
                services?.Dispose();
            }
            catch
            {
                exitCode = 1;
            }

            Services = null!;
            try
            {
                if (Directory.Exists(dataRoot))
                {
                    Directory.Delete(dataRoot, recursive: true);
                }
            }
            catch
            {
                // Smoke data is isolated under the system temporary directory.
            }
        }

        Environment.Exit(exitCode);
    }
}
