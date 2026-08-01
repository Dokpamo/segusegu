using Lorepia.App.Platform;
using Lorepia.Native;
using System.Collections.ObjectModel;

namespace Lorepia.App.ViewModels;

public sealed class ChatViewModel : ObservableObject
{
    private readonly CoreClient core;
    private readonly IProviderCredentialStore credentials;
    private readonly List<ConversationMessage> persistedMessages = [];
    private readonly object lifecycleGate = new();
    private CancellationTokenSource? lifecycleCancellation;
    private CancellationTokenSource? pollingCancellation;
    private GenerationEventCursor? eventCursor;
    private string? requestedCharacterId;
    private string? conversationId;
    private string liveAssistantText = string.Empty;
    private string draft = string.Empty;
    private string title = "Chat";
    private string status = "Choose a character from Library to start.";
    private GenerationTargetOption? selectedTarget;
    private bool isLoading;
    private bool sendInProgress;
    private long lifecycleEpoch;
    private long sendOperationEpoch;

    internal ChatViewModel(
        CoreClient core,
        IProviderCredentialStore credentials)
    {
        this.core = core;
        this.credentials = credentials;
    }

    public ObservableCollection<ChatMessageItem> Messages { get; } = [];

    public ObservableCollection<GenerationTargetOption> Targets { get; } = [];

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

    public GenerationTargetOption? SelectedTarget
    {
        get => selectedTarget;
        set
        {
            if (SetProperty(ref selectedTarget, value))
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
        && !sendInProgress
        && conversationId is not null
        && SelectedTarget is not null
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
        var lifecycle = BeginLifecycle();
        var characterId = requestedCharacterId;
        IsLoading = true;
        Status = "Restoring the local conversation…";
        try
        {
            var state = await Task.Run(() =>
            {
                var conversations = core.ListConversations();
                Conversation? conversation;
                if (characterId is not null)
                {
                    conversation = conversations
                        .Where(item => string.Equals(
                            item.CharacterId,
                            characterId,
                            StringComparison.Ordinal))
                        .OrderByDescending(item => item.UpdatedAt)
                        .FirstOrDefault()
                        ?? core.OpenConversation(characterId);
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
                var targets = new List<GenerationTargetOption>();
                foreach (var connection in
                    core.ListProviderConnections())
                {
                    foreach (var route in
                        core.ListModelRoutes(connection.Id))
                    {
                        if (route.Availability is
                            ModelAvailability.MissingTemporarily or
                            ModelAvailability.AccessDenied or
                            ModelAvailability.Deprecated or
                            ModelAvailability.Retired)
                        {
                            continue;
                        }

                        foreach (var preset in
                            core.ListGenerationPresets(route.Id))
                        {
                            targets.Add(new GenerationTargetOption(
                                connection.Id,
                                route.Id,
                                preset.Id,
                                $"{connection.DisplayName} · "
                                    + $"{route.DisplayName ?? route.ModelId} · "
                                    + preset.DisplayName));
                        }
                    }
                }

                return (
                    Conversation: conversation,
                    Messages: messages,
                    Targets: targets,
                    Settings: core.GetSettings());
            }, lifecycle.CancellationToken);
            if (!IsCurrentLifecycle(lifecycle))
            {
                return;
            }

            conversationId = state.Conversation?.Id;
            Title = state.Conversation?.Title ?? "Chat";
            Targets.Clear();
            foreach (var target in state.Targets)
            {
                Targets.Add(target);
            }

            SelectedTarget = Targets.FirstOrDefault(target =>
                    string.Equals(
                        target.ModelRouteId,
                        state.Settings.SelectedModelRouteId,
                        StringComparison.Ordinal)
                    && string.Equals(
                        target.GenerationPresetId,
                        state.Settings.SelectedGenerationPresetId,
                        StringComparison.Ordinal))
                ?? Targets.FirstOrDefault(target =>
                    string.Equals(
                        target.ConnectionId,
                        state.Settings.SelectedProviderProfileId,
                        StringComparison.Ordinal))
                ?? Targets.FirstOrDefault();
            eventCursor = null;
            liveAssistantText = string.Empty;
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
                StartPolling(lifecycle);
                Status = "Generation is in progress…";
            }
            else if (conversationId is null)
            {
                Status = "Choose a character from Library to start.";
            }
            else if (Targets.Count == 0)
            {
                Status =
                    "Add a provider connection, model route, and generation preset in Settings before sending.";
            }
            else
            {
                Status = Messages.Count == 0
                    ? "Conversation ready."
                    : "Conversation restored from local storage.";
            }
        }
        catch (OperationCanceledException)
            when (lifecycle.CancellationToken
                .IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (IsCurrentLifecycle(lifecycle))
            {
                conversationId = null;
                eventCursor = null;
                Messages.Clear();
                Status =
                    $"Could not open chat: {exception.Message}";
            }
        }
        finally
        {
            if (IsCurrentLifecycle(lifecycle))
            {
                IsLoading = false;
                NotifyComposerState();
            }
        }
    }

    internal async Task SendAsync()
    {
        if (!TryCaptureLifecycle(out var lifecycle))
        {
            return;
        }

        var conversation = conversationId;
        var target = SelectedTarget;
        var text = Draft.Trim();
        if (conversation is null
            || target is null
            || eventCursor is not null
            || IsLoading
            || text.Length == 0)
        {
            return;
        }
        if (!TryBeginSend(
                lifecycle,
                out var sendOperation))
        {
            return;
        }

        IsLoading = true;
        Status = "Starting generation…";
        try
        {
            lifecycle.CancellationToken
                .ThrowIfCancellationRequested();
            string? credential =
                credentials.Get(target.ConnectionId);
            string generationId;
            try
            {
                generationId = await Task.Run(() =>
                    core.SendMessageWithTarget(
                        conversation,
                        text,
                        new GenerationTarget
                        {
                            ModelRouteId = target.ModelRouteId,
                            GenerationPresetId =
                                target.GenerationPresetId,
                        },
                        target.ConnectionId,
                        credential),
                    lifecycle.CancellationToken);
            }
            finally
            {
                credential = null;
            }
            if (!IsCurrentSend(
                    lifecycle,
                    sendOperation))
            {
                return;
            }

            Draft = string.Empty;
            liveAssistantText = string.Empty;
            eventCursor = new GenerationEventCursor(
                conversation,
                generationId);
            await RefreshMessagesAsync(lifecycle);
            if (!IsCurrentSend(
                    lifecycle,
                    sendOperation))
            {
                return;
            }
            StartPolling(lifecycle);
            Status = "Generating…";
        }
        catch (OperationCanceledException)
            when (lifecycle.CancellationToken
                .IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (IsCurrentSend(
                    lifecycle,
                    sendOperation))
            {
                _ = exception;
                Status =
                    "Could not send message. The credential was not retained by the Windows UI.";
            }
        }
        finally
        {
            if (CompleteSend(
                    lifecycle,
                    sendOperation))
            {
                IsLoading = false;
                NotifyComposerState();
            }
        }
    }

    internal async Task CancelAsync()
    {
        if (!TryCaptureLifecycle(out var lifecycle))
        {
            return;
        }

        var generationId = eventCursor?.GenerationId;
        if (generationId is null)
        {
            return;
        }

        Status = "Cancelling generation…";
        try
        {
            await Task.Run(
                () => core.CancelGeneration(generationId),
                lifecycle.CancellationToken);
            if (!IsCurrentLifecycle(lifecycle))
            {
                return;
            }
        }
        catch (CoreInteropException exception)
            when (exception.Code == "not_found")
        {
            if (!IsCurrentLifecycle(lifecycle))
            {
                return;
            }
            eventCursor = null;
            await RefreshMessagesAsync(lifecycle);
            if (!IsCurrentLifecycle(lifecycle))
            {
                return;
            }
            StopPolling();
            Status = "Generation already finished.";
            NotifyComposerState();
        }
        catch (OperationCanceledException)
            when (lifecycle.CancellationToken
                .IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (IsCurrentLifecycle(lifecycle))
            {
                Status =
                    $"Could not cancel generation: {exception.Message}";
            }
        }
    }

    internal void Stop()
    {
        InvalidateLifecycle();
        IsLoading = false;
        NotifyComposerState();
    }

    private void StartPolling(
        ChatLifecycleToken lifecycle)
    {
        CancellationTokenSource polling;
        lock (lifecycleGate)
        {
            if (!IsCurrentLifecycleLocked(lifecycle))
            {
                return;
            }

            StopPollingLocked();
            polling =
                CancellationTokenSource.CreateLinkedTokenSource(
                    lifecycle.CancellationToken);
            pollingCancellation = polling;
        }
        _ = PollEventsAsync(
            lifecycle,
            polling.Token);
        NotifyComposerState();
    }

    private void StopPolling()
    {
        lock (lifecycleGate)
        {
            StopPollingLocked();
        }
    }

    private async Task PollEventsAsync(
        ChatLifecycleToken lifecycle,
        CancellationToken cancellationToken)
    {
        var emptyPolls = 0;
        try
        {
            while (!cancellationToken.IsCancellationRequested
                   && IsCurrentLifecycle(lifecycle)
                   && eventCursor is not null)
            {
                var batch = await Task.Run(
                    () => core.PollEvents(128),
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                if (!IsCurrentLifecycle(lifecycle))
                {
                    return;
                }
                emptyPolls = batch.Events.Count == 0
                    ? emptyPolls + 1
                    : 0;
                if (batch.DroppedEvents > 0)
                {
                    await RefreshMessagesAsync(lifecycle);
                    if (!IsCurrentLifecycle(lifecycle))
                    {
                        return;
                    }
                    if (!ReconcilePersistedGeneration(
                            lifecycle))
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
                    await RefreshMessagesAsync(lifecycle);
                    if (!IsCurrentLifecycle(lifecycle))
                    {
                        return;
                    }
                    if (!ReconcilePersistedGeneration(
                            lifecycle))
                    {
                        Status = "Response state restored from local storage.";
                    }
                }

                foreach (var chatEvent in batch.Events)
                {
                    if (!IsCurrentLifecycle(lifecycle))
                    {
                        return;
                    }
                    var cursor = eventCursor;
                    if (cursor is null || !cursor.TryAccept(chatEvent))
                    {
                        continue;
                    }

                    await ApplyEventAsync(
                        lifecycle,
                        chatEvent);
                }

                if (IsCurrentLifecycle(lifecycle)
                    && eventCursor is not null)
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
            if (IsCurrentLifecycle(lifecycle))
            {
                Status =
                    $"Event stream stopped: {exception.Message}";
            }
        }
    }

    private async Task ApplyEventAsync(
        ChatLifecycleToken lifecycle,
        ChatEvent chatEvent)
    {
        if (!IsCurrentLifecycle(lifecycle))
        {
            return;
        }

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
            case ChatEventType.ToolCallStarted:
                Status =
                    $"Provider proposed tool “{chatEvent.ToolName ?? "unknown"}”. LorePia did not execute it.";
                break;
            case ChatEventType.ToolCallArgumentsDelta:
                // Provider tool arguments remain inert protocol data. They are
                // never interpreted or executed by the Windows application.
                break;
            case ChatEventType.ToolCallCompleted:
                Status =
                    "Provider tool-call data completed without native execution.";
                break;
            case ChatEventType.UsageUpdated:
                break;
            case ChatEventType.MessageCommitted:
                await RefreshMessagesAsync(lifecycle);
                break;
            case ChatEventType.GenerationCancelled:
                await FinishGenerationAsync(
                    lifecycle,
                    "Generation cancelled.");
                break;
            case ChatEventType.GenerationFailed:
                await FinishGenerationAsync(
                    lifecycle,
                    $"Generation failed: {chatEvent.ErrorMessage}");
                break;
            case ChatEventType.GenerationFinished:
                await FinishGenerationAsync(
                    lifecycle,
                    "Response saved locally.");
                break;
            default:
                throw new InvalidOperationException(
                    $"Unhandled event type {chatEvent.Type}.");
        }
    }

    private async Task FinishGenerationAsync(
        ChatLifecycleToken lifecycle,
        string terminalStatus)
    {
        await RefreshMessagesAsync(lifecycle);
        if (!IsCurrentLifecycle(lifecycle))
        {
            return;
        }
        eventCursor = null;
        liveAssistantText = string.Empty;
        StopPolling();
        Status = terminalStatus;
        NotifyComposerState();
    }

    private async Task RefreshMessagesAsync(
        ChatLifecycleToken lifecycle)
    {
        if (!IsCurrentLifecycle(lifecycle))
        {
            return;
        }
        var conversation = conversationId;
        if (conversation is null)
        {
            return;
        }

        var messages = await Task.Run(
            () => core.ListMessages(conversation),
            lifecycle.CancellationToken);
        if (!IsCurrentLifecycle(lifecycle)
            || !string.Equals(
                conversationId,
                conversation,
                StringComparison.Ordinal))
        {
            return;
        }
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

    private bool ReconcilePersistedGeneration(
        ChatLifecycleToken lifecycle)
    {
        if (!IsCurrentLifecycle(lifecycle))
        {
            return false;
        }

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

    private ChatLifecycleToken BeginLifecycle()
    {
        lock (lifecycleGate)
        {
            StopPollingLocked();
            lifecycleCancellation?.Cancel();
            lifecycleCancellation?.Dispose();
            lifecycleEpoch = checked(lifecycleEpoch + 1);
            sendOperationEpoch =
                checked(sendOperationEpoch + 1);
            sendInProgress = false;
            lifecycleCancellation =
                new CancellationTokenSource();
            return new ChatLifecycleToken(
                lifecycleEpoch,
                lifecycleCancellation.Token);
        }
    }

    private void InvalidateLifecycle()
    {
        lock (lifecycleGate)
        {
            StopPollingLocked();
            lifecycleCancellation?.Cancel();
            lifecycleCancellation?.Dispose();
            lifecycleCancellation = null;
            lifecycleEpoch = checked(lifecycleEpoch + 1);
            sendOperationEpoch =
                checked(sendOperationEpoch + 1);
            sendInProgress = false;
        }
    }

    private bool TryCaptureLifecycle(
        out ChatLifecycleToken lifecycle)
    {
        lock (lifecycleGate)
        {
            if (lifecycleCancellation is null)
            {
                lifecycle = default;
                return false;
            }

            lifecycle = new ChatLifecycleToken(
                lifecycleEpoch,
                lifecycleCancellation.Token);
            return IsCurrentLifecycleLocked(lifecycle);
        }
    }

    private bool IsCurrentLifecycle(
        ChatLifecycleToken lifecycle)
    {
        lock (lifecycleGate)
        {
            return IsCurrentLifecycleLocked(lifecycle);
        }
    }

    private bool IsCurrentLifecycleLocked(
        ChatLifecycleToken lifecycle) =>
        lifecycleCancellation is not null
        && lifecycle.Epoch == lifecycleEpoch
        && lifecycle.CancellationToken ==
            lifecycleCancellation.Token
        && !lifecycle.CancellationToken
            .IsCancellationRequested;

    private bool TryBeginSend(
        ChatLifecycleToken lifecycle,
        out long operationEpoch)
    {
        lock (lifecycleGate)
        {
            if (!IsCurrentLifecycleLocked(lifecycle)
                || sendInProgress)
            {
                operationEpoch = 0;
                return false;
            }

            sendOperationEpoch =
                checked(sendOperationEpoch + 1);
            operationEpoch = sendOperationEpoch;
            sendInProgress = true;
            return true;
        }
    }

    private bool IsCurrentSend(
        ChatLifecycleToken lifecycle,
        long operationEpoch)
    {
        lock (lifecycleGate)
        {
            return IsCurrentLifecycleLocked(lifecycle)
                && sendInProgress
                && operationEpoch == sendOperationEpoch;
        }
    }

    private bool CompleteSend(
        ChatLifecycleToken lifecycle,
        long operationEpoch)
    {
        lock (lifecycleGate)
        {
            if (!IsCurrentLifecycleLocked(lifecycle)
                || !sendInProgress
                || operationEpoch != sendOperationEpoch)
            {
                return false;
            }

            sendInProgress = false;
            return true;
        }
    }

    private void StopPollingLocked()
    {
        pollingCancellation?.Cancel();
        pollingCancellation?.Dispose();
        pollingCancellation = null;
    }
}

public sealed record ChatMessageItem(
    string Id,
    string? GenerationId,
    string Author,
    string Text,
    string Status);

public sealed record GenerationTargetOption(
    string ConnectionId,
    string ModelRouteId,
    string GenerationPresetId,
    string DisplayName);

internal readonly record struct ChatLifecycleToken(
    long Epoch,
    CancellationToken CancellationToken);
