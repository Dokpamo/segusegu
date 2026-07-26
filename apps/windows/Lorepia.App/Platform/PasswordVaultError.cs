namespace Lorepia.App.Platform;

internal static class PasswordVaultError
{
    // HRESULT_FROM_WIN32(ERROR_NOT_FOUND), returned by PasswordVault.Retrieve
    // when the resource/user pair does not exist.
    internal const int ElementNotFoundHResult = unchecked((int)0x80070490);

    internal static bool IsElementNotFound(Exception exception)
    {
        ArgumentNullException.ThrowIfNull(exception);
        return exception.HResult == ElementNotFoundHResult;
    }
}
