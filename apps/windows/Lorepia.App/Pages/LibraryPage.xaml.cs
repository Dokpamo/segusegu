using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lorepia.App.Pages;

public sealed partial class LibraryPage : Page
{
    public LibraryViewModel ViewModel { get; } = new();

    public LibraryPage()
    {
        InitializeComponent();
    }

    private async void Page_Loaded(object sender, RoutedEventArgs e)
    {
        await ViewModel.LoadAsync();
    }

    private void ReviewImport_Click(object sender, RoutedEventArgs e)
    {
        Frame.Navigate(typeof(ImportReviewPage));
    }
}
