using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Navigation;

namespace Lorepia.App.Pages;

public sealed partial class ChatPage : Page
{
    public ChatViewModel ViewModel { get; }

    public ChatPage()
    {
        ViewModel = new ChatViewModel(
            App.Services.Core,
            App.Services.Credentials);
        InitializeComponent();
    }

    protected override async void OnNavigatedTo(NavigationEventArgs e)
    {
        base.OnNavigatedTo(e);
        ViewModel.SetRequestedCharacter(e.Parameter as string);
        await ViewModel.LoadAsync();
    }

    protected override void OnNavigatedFrom(NavigationEventArgs e)
    {
        ViewModel.Stop();
        base.OnNavigatedFrom(e);
    }

    private async void Send_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.SendAsync();
    }

    private async void Cancel_Click(object sender, RoutedEventArgs e)
    {
        await ViewModel.CancelAsync();
    }
}
