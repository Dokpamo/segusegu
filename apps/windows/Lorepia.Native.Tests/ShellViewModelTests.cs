using Lorepia.App.ViewModels;

namespace Lorepia.Native.Tests;

public sealed class ShellViewModelTests
{
    [Fact]
    public async Task RefreshCoreStatus_MapsFakeCoreAndRaisesProperties()
    {
        var api = new FakeNativeApi();
        using var core = CoreClient.Open(api, CreateDataRoot());
        var viewModel = new ShellViewModel(core);
        var changes = new List<string?>();
        viewModel.PropertyChanged += (_, args) =>
            changes.Add(args.PropertyName);

        await viewModel.RefreshCoreStatusAsync();

        Assert.Equal("Core 0.1.0-test · ABI 2", viewModel.CoreVersionLabel);
        Assert.Equal("DB schema 3", viewModel.HealthLabel);
        Assert.Contains(nameof(viewModel.CoreVersionLabel), changes);
        Assert.Contains(nameof(viewModel.HealthLabel), changes);
    }

    [Fact]
    public async Task RefreshCoreStatus_ExposesPendingStateDuringRefresh()
    {
        var api = new FakeNativeApi();
        using var core = CoreClient.Open(api, CreateDataRoot());
        var viewModel = new ShellViewModel(core);
        await viewModel.RefreshCoreStatusAsync();

        var entered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        using var release = new ManualResetEventSlim();
        api.BeforeGetCoreVersion = () =>
        {
            entered.SetResult();
            if (!release.Wait(TimeSpan.FromSeconds(5)))
            {
                throw new TimeoutException("Test refresh was not released.");
            }
        };

        var refresh = viewModel.RefreshCoreStatusAsync();
        await entered.Task.WaitAsync(TimeSpan.FromSeconds(2));
        try
        {
            Assert.Equal("Core: checking…", viewModel.CoreVersionLabel);
            Assert.Equal("Health check pending", viewModel.HealthLabel);
        }
        finally
        {
            release.Set();
        }

        await refresh;
        Assert.Equal("Core 0.1.0-test · ABI 2", viewModel.CoreVersionLabel);
        Assert.Equal("DB schema 3", viewModel.HealthLabel);
    }

    [Fact]
    public async Task RefreshCoreStatus_MapsFailureToVisibleState()
    {
        var api = new FakeNativeApi
        {
            BeforeGetCoreVersion = () =>
                throw new InvalidOperationException(
                    "synthetic status failure"),
        };
        using var core = CoreClient.Open(api, CreateDataRoot());
        var viewModel = new ShellViewModel(core);
        var changes = new List<string?>();
        viewModel.PropertyChanged += (_, args) =>
            changes.Add(args.PropertyName);

        await viewModel.RefreshCoreStatusAsync();

        Assert.Equal("Core unavailable", viewModel.CoreVersionLabel);
        Assert.Equal("synthetic status failure", viewModel.HealthLabel);
        Assert.Contains(nameof(viewModel.CoreVersionLabel), changes);
        Assert.Contains(nameof(viewModel.HealthLabel), changes);
    }

    private static string CreateDataRoot() =>
        Path.Combine(
            Path.GetTempPath(),
            "lorepia-shell-view-model-tests",
            Guid.NewGuid().ToString("N"));
}
