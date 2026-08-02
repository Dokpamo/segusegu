namespace Lorepia.App.ViewModels;

internal readonly record struct ProviderCredentialWrite(
    string ConnectionId,
    string Credential);

internal sealed class ProviderCredentialDraftGuard
{
    private bool hasDraft;
    private string boundConnectionId = string.Empty;

    internal void Update(
        bool hasCredential,
        string? connectionId)
    {
        if (!hasCredential)
        {
            Invalidate();
            return;
        }

        if (hasDraft)
        {
            return;
        }

        hasDraft = true;
        boundConnectionId = Normalize(connectionId);
    }

    internal bool ConnectionIdChanged(string? connectionId)
    {
        if (!hasDraft || string.IsNullOrEmpty(boundConnectionId))
        {
            return false;
        }

        if (!string.Equals(
                boundConnectionId,
                Normalize(connectionId),
                StringComparison.Ordinal))
        {
            Invalidate();
            return true;
        }

        return false;
    }

    internal void Invalidate()
    {
        hasDraft = false;
        boundConnectionId = string.Empty;
    }

    internal ProviderCredentialWrite? Capture(
        string? connectionId,
        string? credential)
    {
        var targetConnectionId = Normalize(connectionId);
        if (string.IsNullOrEmpty(credential)
            || string.IsNullOrEmpty(targetConnectionId)
            || !hasDraft)
        {
            return null;
        }

        if (!string.IsNullOrEmpty(boundConnectionId)
            && !string.Equals(
                boundConnectionId,
                targetConnectionId,
                StringComparison.Ordinal))
        {
            Invalidate();
            return null;
        }

        Invalidate();
        return new ProviderCredentialWrite(
            targetConnectionId,
            credential);
    }

    private static string Normalize(string? profileId)
    {
        return profileId?.Trim() ?? string.Empty;
    }
}
