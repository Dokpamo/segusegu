using Lorepia.App.ViewModels;

namespace Lorepia.Native.Tests;

public sealed class ProviderSelectionGuardTests
{
    [Fact]
    public void ResultCapturedForPreviousConnectionCannotUpdateNewSelection()
    {
        var guard = new ProviderSelectionGuard();
        guard.MoveTo("connection-a");
        var operation = guard.Capture();

        guard.MoveTo("connection-b");

        Assert.False(guard.IsCurrent(operation));
    }

    [Fact]
    public void ReSelectingSameIdStillInvalidatesOlderOperation()
    {
        var guard = new ProviderSelectionGuard();
        var operation = guard.MoveTo("connection-a");

        guard.MoveTo("connection-a");

        Assert.False(guard.IsCurrent(operation));
        Assert.True(guard.IsCurrent(guard.Capture()));
    }

    [Fact]
    public void WhitespaceAndBlankSelectionAreNormalized()
    {
        var guard = new ProviderSelectionGuard();
        var selected = guard.MoveTo(" connection-a ");

        Assert.Equal("connection-a", selected.ConnectionId);

        var cleared = guard.MoveTo(" ");
        Assert.Null(cleared.ConnectionId);
    }
}
