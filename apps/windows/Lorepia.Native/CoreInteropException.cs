namespace Lorepia.Native;

public sealed class CoreInteropException : Exception
{
    public int? Status { get; }

    public string? Code { get; }

    public bool? Recoverable { get; }

    public string? OperationId { get; }

    public CoreInteropException(string message)
        : base(message)
    {
    }

    public CoreInteropException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

    internal CoreInteropException(
        string operation,
        int status,
        NativeErrorPayload? payload)
        : base(CreateMessage(operation, status, payload))
    {
        Status = status;
        Code = payload?.Code;
        Recoverable = payload?.Recoverable;
        OperationId = payload?.OperationId;
    }

    private static string CreateMessage(
        string operation,
        int status,
        NativeErrorPayload? payload)
    {
        if (payload is null)
        {
            return $"{operation} failed with native status {status}.";
        }

        return $"{operation} failed ({payload.Code}, status {status}): {payload.Message}";
    }
}
