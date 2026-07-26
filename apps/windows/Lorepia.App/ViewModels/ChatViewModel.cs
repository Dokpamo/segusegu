using Lorepia.App.Platform;
using Lorepia.Native;
using System.Collections.ObjectModel;

namespace Lorepia.App.ViewModels;

public sealed class ChatViewModel : ObservableObject
{
    private readonly CoreClient core;
    private readonly IProviderCredentialStore credentials;
    private readonly List<ConversationMessage> persistedMessages = [];
    private CancellationTokenSource? pollingCancellation;
    private GenerationEventCursor? eventCursor;
    private string? requestedCharacterId;
    private string? conversationId;
    private string liveAssistantText = string.Empty;
    private string draft = string.Empty;
    private string title = "Chat";
    private string status = "Choose a character from Library to start.";
    private ProviderProfile? selectedProfile;
    private bool isLoading;

    internal ChatViewModel(
        CoreClient core,
        IProviderCredentialStore credentials)
    {
        this.core = core;
        this.credentials = credentials;
    }

    public ObservableCollection<ChatMessageItem> Messages { get; } = [];

    public ObservableCollection<ProviderProfile> Profiles { get; } = [];

    public string Draft
    {
        get => draft;
        set
        {
            if (SetProperty(ref draft, value))
            {
                OnPropertyChanged(nameof(IsComposerEnabled));
            }
        }
    }

    public string Title
    {
        get => title;
        private set => SetProperty(ref title, value);
    }

    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public ProviderProfile? SelectedProfile
    {
        get => selectedProfile;
        set
        {
            if (SetProperty(ref selectedProfile, value))
            {
                OnPropertyChanged(nameof(IsComposerEnabled));
            }
        }
    }

    public bool IsLoading
    {
        get => isLoading;
        private set
        {
            if (SetProperty(ref isLoading, value))
            {
                NotifyComposerState();
            }
        }
    }

    public bool IsComposerEnabled =>
        !IsLoading
        && conversationId is not null
        && SelectedProfile is not null
        && eventCursor is null
        && !string.IsNullOrWhiteSpace(Draft);

    public bool CanCancel => eventCursor is not null;

    internal void SetRequestedCharacter(string? characterId)
    {
        requestedCharacterId = string.IsNullOrWhiteSpace(characterId)
            ? null
            : characterId;
    }

    internal async Task LoadAsync()
    {
        StopPolling();
        IsLoading = true;
        Status = "Restoring the local conversation…";
        try
        {
            var state = await Task.Run(() =>
            {
                var conversations = core.ListConversations();
                Conversation? conversation;
                if (requestedCharacterId is not null)
                {
                    conversation = conversations
                        .Where(item => string.Equals(
                            item.CharacterId,
                            requestedCharacterId,
                            StringComparison.Ordinal))
                        .OrderByDescending(item => item.UpdatedAt)
                        .FirstOrDefault()
                        ?? core.OpenConversation(requestedCharacterId);
                }
                else
                {
                    conversation = conversations
                        .OrderByDescending(item => item.UpdatedAt)
                        .FirstOrDefault();
                }

                var messages = conversation is null
                    ? Array.Empty<ConversationMessage>()
                    : core.ListMessages(conversation.Id);
                return (
                    Conversation: conversation,
                    Messages: messages,
                    Profiles: core.ListProviderProfiles(),
                    Settings: core.GetSettings());
            });

            conversationId = state.Conversation?.Id;
            Title = state.Conversation?.Title ?? "Chat";
            Profiles.Clear();
            foreach (var profile in state.Profiles)
            {
                Profiles.Add(profile);
            }

            SelectedProfile = Profiles.FirstOrDefault(profile =>
                    string.Equals(
                        profile.Id,
                        state.Settings.SelectedProviderProfileId,
                        StringComparison.Ordinal))
                ?? Profiles.FirstOrDefault();
            SetPersistedMessages(state.Messages);

            var pending = state.Messages
                .LastOrDefault(message =>
                    string.Equals(
                        message.Role,
                        "assistant",
                        StringComparison.Ordinal)
                    && string.Equals(
                        message.Status,
                        "pending",
                        StringComparison.Ordinal)
                    && !string.IsNullOrWhiteSpace(message.GenerationId));
            if (conversationId is not null && pending?.GenerationId is not null)
            {
                eventCursor = new GenerationEventCursor(
                    conversationId,
                    pending.GenerationId);
                liveAssistantText = pending.Content;
                StartPolling();
                Status = "Generation is in progress…";
            }
            else if (conversationId is null)
            {
                Status = "Choose a character from Library to start.";
            }
            else if (Profiles.Count == 0)
            {
                Status = "Add a provider profile in Settings before sending.";
            }
            else
            {
                Status = Messages.Count == 0
                    ? "Conversation ready."
                    : "Conversation restored from local storage.";
            }
        }
        catch (Exception exception)
        {
            conversationId = null;
            eventCursor = null;
            Messages.Clear();
            Status = $"Could not open chat: {exception.Message}";
        }
        finally
        {
            IsLoading = false;
            NotifyComposerState();
        }
    }

    internal async Task SendAsync()
    {
        var conversation = conversationId;
        var profile = SelectedProfile;
        var text = Draft.Trim();
        if (conversation is null
            || profile is null
            || eventCursor is not null
            || text.Length == 0)
        {
            return;
        }

        IsLoading = true;
        Status = "Starting generation…";
        try
        {
            var credential = credentials.Get(profile.Id);
            var generationId = await Task.Run(() =>
                core.SendMessage(
                    conversation,
                    text,
                    profile.Id,
                    credential));
            Draft = string.Empty;
            liveAssistantText = string.Empty;
            eventCursor = new GenerationEventCursor(
                conversation,
                generationId);
            await RefreshMessagesAsync();
            StartPolling();
            Status = "Generating…";
        }
        catch (Exception exception)
        {
            Status = $"Could not send message: {exception.Message}";
        }
        finally
        {
            IsLoading = false;
            NotifyComposerState();
        }
    }

    internal async Task CancelAsync()
    {
        var generationId = eventCursor?.GenerationId;
        if (generationId is null)
        {
            return;
        }

        Status = "Cancelling generation…";
        try
        {
            await Task.Run(() => core.CancelGeneration(generationId));
        }
        catch (CoreInteropException exception)
            when (exception.Code == "not_found")
        {
            eventCursor = null;
            await RefreshMessagesAsync();
            StopPolling();
            Status = "Generation already finished.";
            NotifyComposerState();
        }
        catch (Exception exception)
        {
            Status = $"Could not cancel generation: {exception.Message}";
        }
    }

    internal void Stop()
    {
        StopPolling();
    }

    private void StartPolling()
    {
        StopPolling();
        pollingCancellation = new CancellationTokenSource();
        _ = PollEventsAsync(pollingCancellation.Token);
        NotifyComposerState();
    }

    private void StopPolling()
    {
        pollingCancellation?.Cancel();
        pollingCancellation?.Dispose();
        pollingCancellation = null;
    }

    private async Task PollEventsAsync(CancellationToken cancellationToken)
    {
        var emptyPolls = 0;
        try
        {
            while (!cancellationToken.IsCancellationRequested
                   && eventCursor is not null)
            {
                var batch = await Task.Run(
                    () => core.PollEvents(128),
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                emptyPolls = batch.Events.Count == 0
                    ? emptyPolls + 1
                    : 0;
                if (batch.DroppedEvents > 0)
                {
                    await RefreshMessagesAsync();
                    if (!ReconcilePersistedGeneration())
                    {
                        Status =
                            $"Recovered persisted messages after {batch.DroppedEvents} dropped event(s).";
                    }
                    else
                    {
                        Status =
                            $"Refreshed after {batch.DroppedEvents} dropped event(s).";
                    }
                }
                else if (emptyPolls >= 10)
                {
                    emptyPolls = 0;
                    await RefreshMessagesAsync();
                    if (!ReconcilePersistedGeneration())
                    {
                        Status = "Response state restored from local storage.";
                    }
                }

                foreach (var chatEvent in batch.Events)
                {
                    var cursor = eventCursor;
                    if (cursor is null || !cursor.TryAccept(chatEvent))
                    {
                        continue;
                    }

                    await ApplyEventAsync(chatEvent);
                }

                if (eventCursor is not null)
                {
                    await Task.Delay(100, cancellationToken);
                }
            }
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            Status = $"Event stream stopped: {exception.Message}";
        }
    }

    private async Task ApplyEventAsync(ChatEvent chatEvent)
    {
        switch (chatEvent.Type)
        {
            case ChatEventType.GenerationStarted:
                Status = "Generating…";
                break;
            case ChatEventType.ReasoningDelta:
                break;
            case ChatEventType.TextDelta:
                liveAssistantText += chatEvent.Text;
                RebuildMessages();
                break;
            case ChatEventType.UsageUpdated:
                break;
            case ChatEventType.MessageCommitted:
                await RefreshMessagesAsync();
                break;
            case ChatEventType.GenerationCancelled:
                await FinishGenerationAsync("Generation cancelled.");
                break;
            case ChatEventType.GenerationFailed:
                await FinishGenerationAsync(
                    $"Generation failed: {chatEvent.ErrorMessage}");
                break;
            case ChatEventType.GenerationFinished:
                await FinishGenerationAsync("Response saved locally.");
                break;
            default:
                throw new InvalidOperationException(
                    $"Unhandled event type {chatEvent.Type}.");
        }
    }

    private async Task FinishGenerationAsync(string terminalStatus)
    {
        await RefreshMessagesAsync();
        eventCursor = null;
        liveAssistantText = string.Empty;
        StopPolling();
        Status = terminalStatus;
        NotifyComposerState();
    }

    private async Task RefreshMessagesAsync()
    {
        var conversation = conversationId;
        if (conversation is null)
        {
            return;
        }

        var messages = await Task.Run(() =>
            core.ListMessages(conversation));
        SetPersistedMessages(messages);
    }

    private void SetPersistedMessages(
        IReadOnlyList<ConversationMessage> messages)
    {
        persistedMessages.Clear();
        persistedMessages.AddRange(messages);
        RebuildMessages();
    }

    private void RebuildMessages()
    {
        Messages.Clear();
        foreach (var message in persistedMessages)
        {
            var text = message.Content;
            if (eventCursor is not null
                && string.Equals(
                    message.GenerationId,
                    eventCursor.GenerationId,
                    StringComparison.Ordinal)
                && liveAssistantText.Length > 0)
            {
                text = liveAssistantText;
            }

            Messages.Add(new ChatMessageItem(
                message.Id,
                message.GenerationId,
                string.Equals(
                    message.Role,
                    "user",
                    StringComparison.Ordinal)
                    ? "You"
                    : "Assistant",
                text,
                message.Status));
        }
    }

    private void NotifyComposerState()
    {
        OnPropertyChanged(nameof(IsComposerEnabled));
        OnPropertyChanged(nameof(CanCancel));
    }

    private bool ReconcilePersistedGeneration()
    {
        var activeGeneration = eventCursor?.GenerationId;
        var remainsPending = activeGeneration is not null
            && persistedMessages.Any(message =>
                string.Equals(
                    message.GenerationId,
                    activeGeneration,
                    StringComparison.Ordinal)
                && string.Equals(
                    message.Status,
                    "pending",
                    StringComparison.Ordinal));
        if (remainsPending)
        {
            return true;
        }

        eventCursor = null;
        liveAssistantText = string.Empty;
        StopPolling();
        NotifyComposerState();
        return false;
    }
}

public sealed record ChatMessageItem(
    string Id,
    string? GenerationId,
    string Author,
    string Text,
    string Status);
