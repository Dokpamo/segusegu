using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lorepia.App.Pages;

public sealed partial class SettingsPage : Page
{
    public SettingsViewModel ViewModel { get; } = new();

    public SettingsPage()
    {
        InitializeComponent();
    }

    private async void Page_Loaded(object sender, RoutedEventArgs e)
    {
        await ViewModel.RefreshAsync();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.RefreshAsync();
    }
}
