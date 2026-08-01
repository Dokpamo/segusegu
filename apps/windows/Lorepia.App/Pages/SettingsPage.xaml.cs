using Lorepia.App.Platform;
using Lorepia.App.ViewModels;
using Lorepia.Native;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage.Pickers;

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

    private void Page_Unloaded(object sender, RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        CurlExampleBox.Text = string.Empty;
        ViewModel.StopMonitoring();
    }

    private async void Refresh_Click(object sender, RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        CurlExampleBox.Text = string.Empty;
        await ViewModel.RefreshAsync();
    }

    private async void ProviderConnection_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        await ViewModel.SelectConnectionAsync(
            (sender as ComboBox)?.SelectedItem
                as ProviderConnection);
    }

    private async void ModelRoute_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        await ViewModel.SelectModelRouteAsync(
            (sender as ComboBox)?.SelectedItem as ModelRoute);
    }

    private async void GenerationPreset_SelectionChanged(
        object sender,
        SelectionChangedEventArgs e)
    {
        ViewModel.SelectGenerationPreset(
            (sender as ComboBox)?.SelectedItem as GenerationPreset);
        await ViewModel.LoadRequestPreviewAsync();
    }

    private void CredentialBox_PasswordChanged(
        object sender,
        RoutedEventArgs e)
    {
        ViewModel.UpdateCredentialDraft(
            !string.IsNullOrEmpty(CredentialBox.Password));
    }

    private void NewConnection_Click(
        object sender,
        RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        CurlExampleBox.Text = string.Empty;
        ViewModel.BeginNewConnection();
    }

    private async void SaveConnection_Click(
        object sender,
        RoutedEventArgs e)
    {
        try
        {
            await ViewModel.SaveConnectionAsync(
                CredentialBox.Password);
        }
        finally
        {
            CredentialBox.Password = string.Empty;
        }
    }

    private async void StartDiscovery_Click(
        object sender,
        RoutedEventArgs e)
    {
        try
        {
            await ViewModel.StartDiscoveryAsync(
                CredentialBox.Password,
                CurlExampleBox.Text,
                AssistantConsentBox.IsChecked == true,
                ProbeConsentBox.IsChecked == true);
        }
        finally
        {
            CredentialBox.Password = string.Empty;
            CurlExampleBox.Text = string.Empty;
        }
    }

    private async void CancelDiscovery_Click(
        object sender,
        RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        CurlExampleBox.Text = string.Empty;
        await ViewModel.CancelDiscoveryAsync();
    }

    private async void ContinueDiscovery_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.ContinueDiscoveryAsync();
    }

    private async void ApproveAssistantGrant_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.ApproveAssistantGrantAsync();
    }

    private async void DeclineAssistantGrant_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.DeclineAssistantGrantAsync();
    }

    private async void SupplyDiscoveryEvidence_Click(
        object sender,
        RoutedEventArgs e)
    {
        try
        {
            await ViewModel.SupplyDiscoveryEvidenceAsync(
                CurlExampleBox.Text);
        }
        finally
        {
            CurlExampleBox.Text = string.Empty;
        }
    }

    private async void CommitDiscovery_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.CommitDiscoveryAsync();
    }

    private async void AcceptAssistantDraft_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.AcceptAssistantDraftAsync();
    }

    private async void RequestAssistantRevision_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.RequestAssistantRevisionAsync();
    }

    private async void RetryAssistant_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.RetryAssistantAsync();
    }

    private async void DeleteConnection_Click(
        object sender,
        RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        await ViewModel.DeleteSelectedConnectionAsync();
    }

    private void RemoveCredential_Click(
        object sender,
        RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        ViewModel.RemoveSelectedCredential();
    }

    private async void RefreshModels_Click(
        object sender,
        RoutedEventArgs e)
    {
        CredentialBox.Password = string.Empty;
        await ViewModel.RefreshModelsAsync();
    }

    private async void ApproveModelSync_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.ApproveModelSyncAsync();
    }

    private async void CancelModelSync_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.CancelModelSyncAsync();
    }

    private void NewPreset_Click(
        object sender,
        RoutedEventArgs e)
    {
        ViewModel.BeginNewPreset();
    }

    private async void SavePreset_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.SavePresetAsync();
    }

    private async void RefreshRequestPreview_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.LoadRequestPreviewAsync();
    }

    private async void DeletePreset_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.DeleteSelectedPresetAsync();
    }

    private async void SaveSettings_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.SaveAppSettingsAsync();
    }

    private async void ImportSignedCatalog_Click(
        object sender,
        RoutedEventArgs e)
    {
        try
        {
            var picker = new FileOpenPicker
            {
                SuggestedStartLocation =
                    PickerLocationId.Downloads,
                ViewMode = PickerViewMode.List,
            };
            picker.FileTypeFilter.Add(".json");
            var window = App.MainWindow
                ?? throw new InvalidOperationException(
                    "The application window is unavailable.");
            var windowHandle =
                WinRT.Interop.WindowNative.GetWindowHandle(window);
            WinRT.Interop.InitializeWithWindow.Initialize(
                picker,
                windowHandle);
            var source = await picker.PickSingleFileAsync();
            if (source is null)
            {
                return;
            }

            await using var input =
                await source.OpenStreamForReadAsync();
            await using var output = new MemoryStream();
            await BoundedStreamCopier.CopyAsync(
                input,
                output,
                2L * 1024 * 1024);
            var bytes = output.ToArray();
            try
            {
                await ViewModel.PrepareSignedCatalogImportAsync(
                    bytes);
            }
            finally
            {
                Array.Clear(bytes);
            }
        }
        catch
        {
            ViewModel.ReportCatalogReadFailure();
        }
    }

    private async void ActivateSignedCatalog_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.ActivateSignedCatalogImportAsync();
    }

    private async void ReviewCatalogDiff_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.ReviewSelectedCatalogRevisionAsync();
    }

    private async void PrepareCatalogRollback_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.PrepareCatalogRollbackAsync();
    }

    private async void ActivateCatalogRollback_Click(
        object sender,
        RoutedEventArgs e)
    {
        await ViewModel.ActivateCatalogRollbackAsync();
    }
}
