namespace Lorepia.App.ViewModels;

internal enum ShellDestination
{
    Library,
    ImportReview,
    Chat,
    Settings,
}

internal sealed class ShellNavigationModel : ObservableObject
{
    private ShellDestination? currentDestination;

    public ShellDestination? CurrentDestination
    {
        get => currentDestination;
        private set => SetProperty(ref currentDestination, value);
    }

    public ShellDestination ResolveSelection(
        string? tag,
        bool isSettingsSelected)
    {
        if (isSettingsSelected)
        {
            return ShellDestination.Settings;
        }

        return tag switch
        {
            "library" => ShellDestination.Library,
            "import" => ShellDestination.ImportReview,
            "chat" => ShellDestination.Chat,
            _ => ShellDestination.Library,
        };
    }

    public void ConfirmRendered(ShellDestination destination)
    {
        CurrentDestination = destination;
    }
}
