namespace Lorepia.App.Platform;

internal interface IProviderCredentialStore
{
    string? Get(string providerProfileId);

    void Save(string providerProfileId, string credential);

    void Delete(string providerProfileId);
}
