namespace Lorepia.Native.Interop;

internal interface INativeApi
{
    uint GetAbiVersion();

    SafeCoreHandle CreateCore(byte[] configurationJson);

    NativeBuffer GetCoreVersion(SafeCoreHandle core);

    NativeBuffer GetHealthCheckJson(SafeCoreHandle core);

    NativeBuffer GetCharactersJson(SafeCoreHandle core);
}
