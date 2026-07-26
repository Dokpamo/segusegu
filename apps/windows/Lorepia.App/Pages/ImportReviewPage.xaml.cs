using Lorepia.App.Platform;
using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;
using Windows.Storage.Pickers;

namespace Lorepia.App.Pages;

public sealed partial class ImportReviewPage : Page
{
    private bool committed;
    private bool navigatedAway;
    private CancellationTokenSource? stagingCancellation;

    public ImportReviewViewModel ViewModel { get; }

    public ImportReviewPage()
    {
        ViewModel = new ImportReviewViewModel(App.Services.Core);
        InitializeComponent();
    }

    private async void ChooseFile_Click(object sender, RoutedEventArgs e)
    {
        StagedTransportFile? staged = null;
        CancellationTokenSource? stagingOperation = null;
        try
        {
            var picker = new FileOpenPicker
            {
                SuggestedStartLocation = PickerLocationId.Downloads,
                ViewMode = PickerViewMode.List,
            };
            picker.FileTypeFilter.Add(".json");
            picker.FileTypeFilter.Add(".charx");
            picker.FileTypeFilter.Add(".zip");

            var window = App.MainWindow
                ?? throw new InvalidOperationException(
                    "The application window is unavailable.");
            var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(window);
            WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle);

            var source = await picker.PickSingleFileAsync();
            if (source is null)
            {
                return;
            }

            stagingCancellation?.Cancel();
            stagingCancellation?.Dispose();
            stagingOperation = new CancellationTokenSource();
            stagingCancellation = stagingOperation;
            ViewModel.BeginStaging(source.Name);
            staged = await BoundedStagingCopier.CopyAsync(
                source,
                stagingOperation.Token);
            stagingOperation.Token.ThrowIfCancellationRequested();
            await ViewModel.InspectAsync(staged);
            if (navigatedAway)
            {
                await ViewModel.DiscardAsync();
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception exception)
        {
            ViewModel.SetFailure(
                $"Could not stage or inspect the selected file: {exception.Message}");
        }
        finally
        {
            BoundedStagingCopier.TryDelete(staged?.Path);
            if (ReferenceEquals(stagingCancellation, stagingOperation))
            {
                stagingCancellation = null;
            }

            stagingOperation?.Dispose();
        }
    }

    private async void Cancel_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            await ViewModel.DiscardAsync();
            ViewModel.ClearView();
        }
        catch (Exception exception)
        {
            ViewModel.SetFailure(
                $"Could not discard the inspection: {exception.Message}");
        }
    }

    private async void Approve_Click(object sender, RoutedEventArgs e)
    {
        var character = await ViewModel.ApproveAsync();
        if (character is null)
        {
            return;
        }

        committed = true;
        if (App.MainWindow is MainWindow window)
        {
            window.OpenLibrary();
        }
    }

    protected override async void OnNavigatedFrom(
        NavigationEventArgs e)
    {
        base.OnNavigatedFrom(e);
        navigatedAway = true;
        stagingCancellation?.Cancel();
        if (!committed)
        {
            try
            {
                await ViewModel.DiscardAsync();
            }
            catch
            {
                // Recovery removes abandoned core-owned snapshots at next open.
            }
        }
    }
}
