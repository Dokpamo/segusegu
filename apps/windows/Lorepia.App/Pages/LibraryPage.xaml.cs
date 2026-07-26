using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Lorepia.App.Pages;

public sealed partial class LibraryPage : Page
{
    public LibraryViewModel ViewModel { get; }

    public LibraryPage()
    {
        ViewModel = new LibraryViewModel(App.Services.Core);
        InitializeComponent();
    }

    private async void Page_Loaded(object sender, RoutedEventArgs e)
    {
        await ViewModel.LoadAsync();
    }

    private void ReviewImport_Click(object sender, RoutedEventArgs e)
    {
        if (App.MainWindow is MainWindow window)
        {
            window.OpenImportReview();
        }
    }

    private void Character_ItemClick(
        object sender,
        ItemClickEventArgs e)
    {
        if (e.ClickedItem is Lorepia.Native.CharacterSummary character)
        {
            if (App.MainWindow is MainWindow window)
            {
                window.OpenChat(character.Id);
            }
        }
    }
}
