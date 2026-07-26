using System.Runtime.InteropServices;

namespace Lorepia.Native.Interop;

internal static class NativeMethods
{
    internal const string LibraryName = "lorepia_core";

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_abi_version",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern uint AbiVersion();

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_create",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreCreate(
        [In, MarshalAs(
            UnmanagedType.LPArray,
            ArraySubType = UnmanagedType.U1,
            SizeParamIndex = 1)]
        byte[] configurationJson,
        nuint configurationJsonLength,
        out IntPtr core);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_destroy",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern void CoreDestroy(IntPtr core);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_version",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreVersion(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_health_check_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreHealthCheckJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_core_list_characters_json",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern int CoreListCharactersJson(
        SafeCoreHandle core,
        out NativeBufferValue buffer);

    [DllImport(
        LibraryName,
        EntryPoint = "lorepia_buffer_free",
        CallingConvention = CallingConvention.Cdecl,
        ExactSpelling = true)]
    internal static extern void BufferFree(NativeBufferValue buffer);
}
