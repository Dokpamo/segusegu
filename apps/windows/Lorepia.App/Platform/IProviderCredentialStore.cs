namespace Lorepia.App.Platform;

internal interface IProviderCredentialStore
{
    string? Get(string connectionId);

    void Save(string connectionId, string credential);

    void Delete(string connectionId);
}
