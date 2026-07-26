using Lorepia.App.Pages;
using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lorepia.App;

public sealed partial class MainWindow : Window
{
    private bool suppressSelectionNavigation;

    public ShellViewModel ViewModel { get; }

    internal ShellNavigationModel Navigation { get; } = new();

    internal MainWindow(AppServices services)
    {
        ViewModel = new ShellViewModel(services.Core);
        InitializeComponent();
        Title = "LorePia";
        RootNavigationView.SelectedItem = LibraryItem;
        Navigate(ShellDestination.Library);
    }

    internal void OpenLibrary()
    {
        SelectWithoutNavigation(LibraryItem);
        Navigate(ShellDestination.Library);
    }

    internal void OpenImportReview()
    {
        SelectWithoutNavigation(ImportItem);
        Navigate(ShellDestination.ImportReview);
    }

    internal void OpenChat()
    {
        SelectWithoutNavigation(ChatItem);
        Navigate(ShellDestination.Chat);
    }

    internal void OpenChat(string characterId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(characterId);
        SelectWithoutNavigation(ChatItem);
        Navigate(ShellDestination.Chat, characterId);
    }

    internal void OpenSettings()
    {
        SelectWithoutNavigation(RootNavigationView.SettingsItem);
        Navigate(ShellDestination.Settings);
    }

    internal async Task<string> RunCiNavigationSmokeAsync(
        CancellationToken cancellationToken)
    {
        var visited = new List<string>(capacity: 5);
        await VisitAsync(
            ShellDestination.Library,
            typeof(LibraryPage),
            LibraryItem,
            OpenLibrary,
            visited,
            cancellationToken);
        await VisitAsync(
            ShellDestination.ImportReview,
            typeof(ImportReviewPage),
            ImportItem,
            OpenImportReview,
            visited,
            cancellationToken);
        await VisitAsync(
            ShellDestination.Chat,
            typeof(ChatPage),
            ChatItem,
            OpenChat,
            visited,
            cancellationToken);
        await VisitAsync(
            ShellDestination.Settings,
            typeof(SettingsPage),
            RootNavigationView.SettingsItem,
            OpenSettings,
            visited,
            cancellationToken);
        await VisitAsync(
            ShellDestination.Library,
            typeof(LibraryPage),
            LibraryItem,
            OpenLibrary,
            visited,
            cancellationToken);
        return string.Join('>', visited);
    }

    private async void RootNavigationView_Loaded(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.RefreshCoreStatusAsync();
    }

    private void RootNavigationView_SelectionChanged(
        NavigationView sender,
        NavigationViewSelectionChangedEventArgs args)
    {
        if (suppressSelectionNavigation)
        {
            return;
        }

        if (args.IsSettingsSelected)
        {
            Navigate(ShellDestination.Settings);
            return;
        }

        if (args.SelectedItemContainer?.Tag is not string tag)
        {
            return;
        }

        Navigate(Navigation.ResolveSelection(
            tag,
            isSettingsSelected: false));
    }

    private void Navigate(
        ShellDestination destination,
        object? parameter = null)
    {
        EnsureUiThread();
        var pageType = PageTypeFor(destination);
        if (parameter is not null
            || ContentFrame.CurrentSourcePageType != pageType)
        {
            var navigated = parameter is null
                ? ContentFrame.Navigate(pageType)
                : ContentFrame.Navigate(pageType, parameter);
            if (!navigated)
            {
                throw new InvalidOperationException(
                    $"Navigation to {destination} was rejected.");
            }
        }

        if (ContentFrame.CurrentSourcePageType != pageType
            || ContentFrame.Content?.GetType() != pageType)
        {
            throw new InvalidOperationException(
                $"Navigation to {destination} did not create {pageType.Name}.");
        }

        Navigation.ConfirmRendered(destination);
    }

    private void SelectWithoutNavigation(object item)
    {
        suppressSelectionNavigation = true;
        try
        {
            RootNavigationView.SelectedItem = item;
        }
        finally
        {
            suppressSelectionNavigation = false;
        }
    }

    private async Task VisitAsync(
        ShellDestination destination,
        Type expectedPageType,
        object expectedSelection,
        Action open,
        ICollection<string> visited,
        CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        open();

        while (true)
        {
            EnsureUiThread();
            if (ContentFrame.Content is FrameworkElement
                {
                    IsLoaded: true,
                })
            {
                break;
            }

            await Task.Delay(10, cancellationToken);
        }

        if (ContentFrame.CurrentSourcePageType != expectedPageType
            || ContentFrame.Content?.GetType() != expectedPageType
            || Navigation.CurrentDestination != destination
            || !ReferenceEquals(
                RootNavigationView.SelectedItem,
                expectedSelection))
        {
            throw new InvalidOperationException(
                $"The rendered shell route did not match {destination}.");
        }

        visited.Add(DisplayNameFor(destination));
    }

    private void EnsureUiThread()
    {
        if (!DispatcherQueue.HasThreadAccess)
        {
            throw new InvalidOperationException(
                "Shell navigation must run on the WinUI thread.");
        }
    }

    private static Type PageTypeFor(ShellDestination destination) =>
        destination switch
        {
            ShellDestination.Library => typeof(LibraryPage),
            ShellDestination.ImportReview => typeof(ImportReviewPage),
            ShellDestination.Chat => typeof(ChatPage),
            ShellDestination.Settings => typeof(SettingsPage),
            _ => throw new ArgumentOutOfRangeException(
                nameof(destination),
                destination,
                "Unknown shell destination."),
        };

    private static string DisplayNameFor(ShellDestination destination) =>
        destination switch
        {
            ShellDestination.Library => "Library",
            ShellDestination.ImportReview => "ImportReview",
            ShellDestination.Chat => "Chat",
            ShellDestination.Settings => "Settings",
            _ => throw new ArgumentOutOfRangeException(
                nameof(destination),
                destination,
                "Unknown shell destination."),
        };
}
