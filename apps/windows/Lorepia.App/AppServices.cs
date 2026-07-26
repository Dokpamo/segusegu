using Lorepia.App.Platform;
using Lorepia.Native;

namespace Lorepia.App;

internal sealed class AppServices : IDisposable
{
    private int disposed;

    internal AppServices(
        CoreClient core,
        IProviderCredentialStore credentials)
    {
        Core = core;
        Credentials = credentials;
    }

    internal CoreClient Core { get; }

    internal IProviderCredentialStore Credentials { get; }

    internal static AppServices Create(string? dataRoot = null)
    {
        var core = CoreClient.Open(
            dataRoot ?? WindowsDataRoot.GetOrCreate());
        return new AppServices(core, new PasswordVaultCredentialStore());
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) == 0)
        {
            Core.Dispose();
        }
    }
}
