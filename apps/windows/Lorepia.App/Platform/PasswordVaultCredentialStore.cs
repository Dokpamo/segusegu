using Windows.Security.Credentials;

namespace Lorepia.App.Platform;

internal sealed class PasswordVaultCredentialStore : IProviderCredentialStore
{
    private const string Resource = "LorePia.ProviderCredential";
    private readonly PasswordVault vault = new();

    public string? Get(string providerProfileId)
    {
        ValidateProfileId(providerProfileId);
        try
        {
            var credential = vault.Retrieve(Resource, providerProfileId);
            credential.RetrievePassword();
            return credential.Password;
        }
        catch (Exception exception) when (
            PasswordVaultError.IsElementNotFound(exception))
        {
            return null;
        }
    }

    public void Save(string providerProfileId, string credential)
    {
        ValidateProfileId(providerProfileId);
        ArgumentException.ThrowIfNullOrWhiteSpace(credential);
        Delete(providerProfileId);
        vault.Add(new PasswordCredential(
            Resource,
            providerProfileId,
            credential));
    }

    public void Delete(string providerProfileId)
    {
        ValidateProfileId(providerProfileId);
        try
        {
            var credential = vault.Retrieve(Resource, providerProfileId);
            vault.Remove(credential);
        }
        catch (Exception exception) when (
            PasswordVaultError.IsElementNotFound(exception))
        {
            // Removing an already-absent credential is idempotent.
        }
    }

    private static void ValidateProfileId(string providerProfileId)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(providerProfileId);
    }
}
