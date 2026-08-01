namespace Lorepia.App.ViewModels;

internal readonly record struct ProviderSelectionToken(
    long Revision,
    string? ConnectionId);

/// <summary>
/// Prevents an asynchronous result or credential draft captured for one
/// connection from being applied after the user selects another connection.
/// </summary>
internal sealed class ProviderSelectionGuard
{
    private long revision;
    private string? connectionId;

    internal ProviderSelectionToken MoveTo(string? selectedConnectionId)
    {
        connectionId = Normalize(selectedConnectionId);
        revision = checked(revision + 1);
        return Capture();
    }

    internal ProviderSelectionToken Capture()
    {
        return new ProviderSelectionToken(revision, connectionId);
    }

    internal bool IsCurrent(ProviderSelectionToken token)
    {
        return token.Revision == revision
            && string.Equals(
                token.ConnectionId,
                connectionId,
                StringComparison.Ordinal);
    }

    private static string? Normalize(string? value)
    {
        var normalized = value?.Trim();
        return string.IsNullOrEmpty(normalized) ? null : normalized;
    }
}
