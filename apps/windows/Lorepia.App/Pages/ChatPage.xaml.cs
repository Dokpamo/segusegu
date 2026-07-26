using Lorepia.App.ViewModels;
using Microsoft.UI.Xaml.Controls;

namespace Lorepia.App.Pages;

public sealed partial class ChatPage : Page
{
    public ChatViewModel ViewModel { get; } = new();

    public ChatPage()
    {
        InitializeComponent();
    }
}
