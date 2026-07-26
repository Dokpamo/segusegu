namespace Lorepia.Native;

public sealed class CoreInteropException : Exception
{
    public CoreInteropException(string message)
        : base(message)
    {
    }

    public CoreInteropException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
