using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lorepia.App.Pages;

public sealed partial class SettingsPage : Page
{
    public SettingsViewModel ViewModel { get; }

    public SettingsPage()
    {
        ViewModel = new SettingsViewModel(
            App.Services.Core,
            App.Services.Credentials);
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

    private void NewProfile_Click(object sender, RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        ViewModel.BeginNewProfile();
    }

    private async void SaveProfile_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await ViewModel.SaveProfileAsync(CredentialBox.Password);
        }
        finally
        {
            CredentialBox.Password = string.Empty;
        }
    }

    private async void DeleteProfile_Click(object sender, RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        await ViewModel.DeleteSelectedProfileAsync();
    }

    private void RemoveCredential_Click(object sender, RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        ViewModel.RemoveSelectedCredential();
    }

    private async void SaveSettings_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.SaveAppSettingsAsync();
    }
}
