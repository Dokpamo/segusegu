using Lorepia.App.ViewModels;

namespace Lorepia.Native.Tests;

public sealed class ShellNavigationModelTests
{
    [Fact]
    public void ResolveSelection_MapsEveryShellDestination()
    {
        var model = new ShellNavigationModel();

        Assert.Equal(
            ShellDestination.Library,
            model.ResolveSelection("library", isSettingsSelected: false));
        Assert.Equal(
            ShellDestination.ImportReview,
            model.ResolveSelection("import", isSettingsSelected: false));
        Assert.Equal(
            ShellDestination.Chat,
            model.ResolveSelection("chat", isSettingsSelected: false));
        Assert.Equal(
            ShellDestination.Settings,
            model.ResolveSelection("ignored", isSettingsSelected: true));
        Assert.Equal(
            ShellDestination.Library,
            model.ResolveSelection("unknown", isSettingsSelected: false));
    }

    [Fact]
    public void ConfirmRendered_TracksOnlyConfirmedDestinationChanges()
    {
        var model = new ShellNavigationModel();
        var changes = new List<string?>();
        model.PropertyChanged += (_, args) =>
            changes.Add(args.PropertyName);

        model.ConfirmRendered(ShellDestination.Library);
        model.ConfirmRendered(ShellDestination.ImportReview);
        model.ConfirmRendered(ShellDestination.Chat);
        model.ConfirmRendered(ShellDestination.Settings);
        model.ConfirmRendered(ShellDestination.Library);
        model.ConfirmRendered(ShellDestination.Library);

        Assert.Equal(
            ShellDestination.Library,
            model.CurrentDestination);
        Assert.Equal(
            5,
            changes.Count(name =>
                name == nameof(model.CurrentDestination)));
    }
}
