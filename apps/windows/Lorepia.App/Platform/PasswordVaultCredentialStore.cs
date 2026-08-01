using Windows.Security.Credentials;

namespace Lorepia.App.Platform;

internal sealed class PasswordVaultCredentialStore : IProviderCredentialStore
{
    private const string Resource = "LorePia.ProviderCredential";
    private readonly PasswordVault vault = new();

    public string? Get(string connectionId)
    {
        ValidateConnectionId(connectionId);
        try
        {
            var credential = vault.Retrieve(Resource, connectionId);
            credential.RetrievePassword();
            return credential.Password;
        }
        catch (Exception exception) when (
            PasswordVaultError.IsElementNotFound(exception))
        {
            return null;
        }
    }

    public void Save(string connectionId, string credential)
    {
        ValidateConnectionId(connectionId);
        ArgumentException.ThrowIfNullOrWhiteSpace(credential);
        var previous = Get(connectionId);
        Delete(connectionId);
        try
        {
            vault.Add(new PasswordCredential(
                Resource,
                connectionId,
                credential));
        }
        catch (Exception primaryFailure)
        {
            if (previous is not null)
            {
                try
                {
                    vault.Add(new PasswordCredential(
                        Resource,
                        connectionId,
                        previous));
                }
                catch (Exception compensationFailure)
                {
                    throw new ProviderCredentialCompensationException(
                        "The replacement PasswordVault write failed and the previous credential could not be restored.",
                        primaryFailure,
                        compensationFailure);
                }
            }

            throw;
        }
    }

    public void Delete(string connectionId)
    {
        ValidateConnectionId(connectionId);
        try
        {
            var credential = vault.Retrieve(Resource, connectionId);
            vault.Remove(credential);
        }
        catch (Exception exception) when (
            PasswordVaultError.IsElementNotFound(exception))
        {
            // Removing an already-absent credential is idempotent.
        }
    }

    private static void ValidateConnectionId(string connectionId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(connectionId);
    }
}
