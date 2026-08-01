namespace Lorepia.App.Platform;

/// <summary>
/// Coordinates PasswordVault writes with non-secret Core records.
///
/// The credential is written before a new Core record so a successful Core
/// connection never points at a missing vault entry. If the Core operation
/// fails, the previous vault state is restored. Deletes use the inverse order
/// and restore the vault entry when Core refuses the delete.
/// </summary>
internal static class ProviderCredentialTransaction
{
    internal static async Task PersistAsync(
        IProviderCredentialStore credentials,
        string connectionId,
        string? replacementCredential,
        Func<Task> persistNonSecretState)
    {
        ArgumentNullException.ThrowIfNull(credentials);
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionId);
        ArgumentNullException.ThrowIfNull(persistNonSecretState);

        if (string.IsNullOrEmpty(replacementCredential))
        {
            await persistNonSecretState().ConfigureAwait(false);
            return;
        }

        var previousCredential = credentials.Get(connectionId);
        credentials.Save(connectionId, replacementCredential);
        try
        {
            await persistNonSecretState().ConfigureAwait(false);
        }
        catch (Exception primary)
        {
            try
            {
                Restore(
                    credentials,
                    connectionId,
                    previousCredential);
            }
            catch (Exception compensation)
            {
                throw new ProviderCredentialCompensationException(
                    "The provider could not be saved and the previous PasswordVault state could not be restored.",
                    primary,
                    compensation);
            }

            throw;
        }
    }

    internal static async Task DeleteAsync(
        IProviderCredentialStore credentials,
        string connectionId,
        Func<Task> deleteNonSecretState)
    {
        ArgumentNullException.ThrowIfNull(credentials);
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionId);
        ArgumentNullException.ThrowIfNull(deleteNonSecretState);

        var previousCredential = credentials.Get(connectionId);
        if (previousCredential is not null)
        {
            credentials.Delete(connectionId);
        }

        try
        {
            await deleteNonSecretState().ConfigureAwait(false);
        }
        catch (Exception primary)
        {
            if (previousCredential is null)
            {
                throw;
            }

            try
            {
                credentials.Save(connectionId, previousCredential);
            }
            catch (Exception compensation)
            {
                throw new ProviderCredentialCompensationException(
                    "The provider could not be deleted and its PasswordVault entry could not be restored.",
                    primary,
                    compensation);
            }

            throw;
        }
    }

    private static void Restore(
        IProviderCredentialStore credentials,
        string connectionId,
        string? previousCredential)
    {
        if (previousCredential is null)
        {
            credentials.Delete(connectionId);
            return;
        }

        credentials.Save(connectionId, previousCredential);
    }
}

internal sealed class ProviderCredentialCompensationException : Exception
{
    internal ProviderCredentialCompensationException(
        string message,
        Exception primaryFailure,
        Exception compensationFailure)
        : base(
            message,
            new AggregateException(primaryFailure, compensationFailure))
    {
        PrimaryFailure = primaryFailure;
        CompensationFailure = compensationFailure;
    }

    internal Exception PrimaryFailure { get; }

    internal Exception CompensationFailure { get; }
}
