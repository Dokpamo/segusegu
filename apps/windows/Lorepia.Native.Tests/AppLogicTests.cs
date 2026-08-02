using Lorepia.App.Platform;
using Lorepia.App.ViewModels;

namespace Lorepia.Native.Tests;

public sealed class AppLogicTests
{
    [Fact]
    public async Task BoundedCopy_AcceptsExactLimit()
    {
        var bytes = Enumerable.Range(0, 1024)
            .Select(value => (byte)(value % 251))
            .ToArray();
        await using var input = new MemoryStream(bytes);
        await using var output = new MemoryStream();

        var copied = await BoundedStreamCopier.CopyAsync(
            input,
            output,
            bytes.Length);

        Assert.Equal(bytes.Length, copied);
        Assert.Equal(bytes, output.ToArray());
    }

    [Fact]
    public async Task BoundedCopy_RejectsGrowthPastLimit()
    {
        await using var input = new MemoryStream(new byte[65_537]);
        await using var output = new MemoryStream();

        await Assert.ThrowsAsync<InvalidDataException>(() =>
            BoundedStreamCopier.CopyAsync(input, output, 65_536));

        Assert.True(output.Length <= 65_536);
    }

    [Fact]
    public void GenerationCursor_FiltersConversationGenerationAndSequence()
    {
        var cursor = new GenerationEventCursor("conversation-1", "generation-1");

        Assert.False(cursor.TryAccept(CreateEvent(
            "other-conversation",
            "generation-1",
            1)));
        Assert.False(cursor.TryAccept(CreateEvent(
            "conversation-1",
            "other-generation",
            1)));
        Assert.True(cursor.TryAccept(CreateEvent(
            "conversation-1",
            "generation-1",
            1)));
        Assert.False(cursor.TryAccept(CreateEvent(
            "conversation-1",
            "generation-1",
            1)));
        Assert.False(cursor.TryAccept(CreateEvent(
            "conversation-1",
            "generation-1",
            0)));
        Assert.True(cursor.TryAccept(CreateEvent(
            "conversation-1",
            "generation-1",
            3)));
        Assert.Equal(3UL, cursor.LastSequence);
    }

    private static ChatEvent CreateEvent(
        string conversationId,
        string generationId,
        ulong sequence) =>
        new()
        {
            EventVersion = CoreClient.SupportedChatEventVersion,
            ConversationId = conversationId,
            GenerationId = generationId,
            Sequence = sequence,
            EmittedAt = DateTimeOffset.UtcNow,
            Type = ChatEventType.TextDelta,
            Text = "delta",
        };
}
