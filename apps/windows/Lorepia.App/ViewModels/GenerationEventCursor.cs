using Lorepia.Native;

namespace Lorepia.App.ViewModels;

internal sealed class GenerationEventCursor
{
    private ulong lastSequence;

    internal GenerationEventCursor(
        string conversationId,
        string generationId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(conversationId);
        ArgumentException.ThrowIfNullOrWhiteSpace(generationId);
        ConversationId = conversationId;
        GenerationId = generationId;
    }

    internal string ConversationId { get; }

    internal string GenerationId { get; }

    internal ulong LastSequence => lastSequence;

    internal bool TryAccept(ChatEvent chatEvent)
    {
        ArgumentNullException.ThrowIfNull(chatEvent);
        if (!string.Equals(
                chatEvent.ConversationId,
                ConversationId,
                StringComparison.Ordinal)
            || !string.Equals(
                chatEvent.GenerationId,
                GenerationId,
                StringComparison.Ordinal)
            || chatEvent.Sequence <= lastSequence)
        {
            return false;
        }

        lastSequence = chatEvent.Sequence;
        return true;
    }
}
