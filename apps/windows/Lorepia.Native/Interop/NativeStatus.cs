namespace Lorepia.Native.Interop;

internal static class NativeStatus
{
    internal const int Success = 0;

    internal static void ThrowIfFailed(string operation, int status)
    {
        if (status == Success)
        {
            return;
        }

        throw new CoreInteropException(
            $"Native operation '{operation}' failed with status {status}.");
    }
}
