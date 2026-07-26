namespace Lorepia.Native.Interop;

internal sealed class PInvokeNativeApi : INativeApi
{
    internal static PInvokeNativeApi Instance { get; } = new();

    private PInvokeNativeApi()
    {
        NativeLibraryResolver.EnsureRegistered();
    }

    public uint GetAbiVersion() => NativeMethods.AbiVersion();

    public SafeCoreHandle CreateCore(byte[] configurationJson)
    {
        ArgumentNullException.ThrowIfNull(configurationJson);

        var status = NativeMethods.CoreCreate(
            configurationJson,
            checked((nuint)configurationJson.Length),
            out var pointer);
        NativeStatus.ThrowIfFailed("lorepia_core_create", status);

        return new SafeCoreHandle(pointer, NativeMethods.CoreDestroy);
    }

    public NativeBuffer GetCoreVersion(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreVersion(core, out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_version",
            status,
            buffer);
    }

    public NativeBuffer GetHealthCheckJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreHealthCheckJson(core, out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_health_check_json",
            status,
            buffer);
    }

    public NativeBuffer GetCharactersJson(SafeCoreHandle core)
    {
        ArgumentNullException.ThrowIfNull(core);

        var status = NativeMethods.CoreListCharactersJson(core, out var buffer);
        return OwnSuccessfulBuffer(
            "lorepia_core_list_characters_json",
            status,
            buffer);
    }

    private static NativeBuffer OwnSuccessfulBuffer(
        string operation,
        int status,
        NativeBufferValue buffer)
    {
        if (status != NativeStatus.Success)
        {
            if (buffer.Pointer != IntPtr.Zero || buffer.Length != 0)
            {
                NativeMethods.BufferFree(buffer);
            }

            NativeStatus.ThrowIfFailed(operation, status);
        }

        return new NativeBuffer(buffer, NativeMethods.BufferFree);
    }
}
