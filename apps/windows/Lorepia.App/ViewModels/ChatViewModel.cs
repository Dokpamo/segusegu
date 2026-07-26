using System.Collections.ObjectModel;

namespace Lorepia.App.ViewModels;

public sealed class ChatViewModel : ObservableObject
{
    private string draft = string.Empty;

    public ObservableCollection<ChatMessage> Messages { get; } = [];

    public string Draft
    {
        get => draft;
        set => SetProperty(ref draft, value);
    }

    public bool IsComposerEnabled => false;

    public string Status =>
        "The current frame ABI exposes diagnostics only. Chat stays disabled until Rust provides high-level generation calls.";
}

public sealed record ChatMessage(
    string Id,
    string Author,
    string Text);
