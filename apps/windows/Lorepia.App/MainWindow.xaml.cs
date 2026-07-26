using Lorepia.App.Pages;
using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lorepia.App;

public sealed partial class MainWindow : Window
{
    public ShellViewModel ViewModel { get; } = new();

    public MainWindow()
    {
        InitializeComponent();
        Title = "LorePia";
        RootNavigationView.SelectedItem = LibraryItem;
        Navigate(typeof(LibraryPage));
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
        if (args.IsSettingsSelected)
        {
            Navigate(typeof(SettingsPage));
            return;
        }

        if (args.SelectedItemContainer?.Tag is not string tag)
        {
            return;
        }

        Navigate(tag switch
        {
            "library" => typeof(LibraryPage),
            "import" => typeof(ImportReviewPage),
            "chat" => typeof(ChatPage),
            _ => typeof(LibraryPage),
        });
    }

    private void Navigate(Type pageType)
    {
        if (ContentFrame.CurrentSourcePageType != pageType)
        {
            ContentFrame.Navigate(pageType);
        }
    }
}
