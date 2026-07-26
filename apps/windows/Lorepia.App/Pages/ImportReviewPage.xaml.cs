using Lorepia.App.ViewModels;
using Lorepia.App.Platform;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Storage;
using Windows.Storage.Pickers;

namespace Lorepia.App.Pages;

public sealed partial class ImportReviewPage : Page
{
    private const ulong MaxStagingBytes = 512UL * 1024 * 1024;
    private StorageFile? stagedFile;

    public ImportReviewViewModel ViewModel { get; } = new();

    public ImportReviewPage()
    {
        InitializeComponent();
    }

    private async void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var picker = new FileOpenPicker
            {
                SuggestedStartLocation = PickerLocationId.Downloads,
                ViewMode = PickerViewMode.List,
            };
            picker.FileTypeFilter.Add("*");

            var window = App.MainWindow
                ?? throw new InvalidOperationException("The application window is unavailable.");
            var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(window);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle);

            var source = await picker.PickSingleFileAsync();
            if (source is null)
            {
                return;
            }

            var properties = await source.GetBasicPropertiesAsync();
            if (properties.Size > MaxStagingBytes)
            {
                ViewModel.SetFailure(
                    "The selected file exceeds the Windows staging transport limit of 512 MB.");
                return;
            }

            ViewModel.BeginStaging();
            await DeleteStagedFileAsync();

            var dataRoot = await StorageFolder.GetFolderFromPathAsync(
                WindowsDataRoot.GetOrCreate());
            var staging = await dataRoot.CreateFolderAsync(
                "staging",
                CreationCollisionOption.OpenIfExists);
            stagedFile = await source.CopyAsync(
                staging,
                source.Name,
                NameCollisionOption.GenerateUniqueName);

            ViewModel.SetStagedFile(
                stagedFile.Name,
                stagedFile.Path,
                properties.Size);
        }
        catch (Exception exception)
        {
            ViewModel.SetFailure($"Could not stage the selected file: {exception.Message}");
        }
    }

    private async void Cancel_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await DeleteStagedFileAsync();
            ViewModel.Clear();
        }
        catch (Exception exception)
        {
            ViewModel.SetFailure($"Could not clear the staged file: {exception.Message}");
        }
    }

    private async Task DeleteStagedFileAsync()
    {
        if (stagedFile is null)
        {
            return;
        }

        await stagedFile.DeleteAsync(StorageDeleteOption.PermanentDelete);
        stagedFile = null;
    }
}
