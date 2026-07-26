using System.Runtime.InteropServices;

namespace Lorepia.Native.Interop;

[StructLayout(LayoutKind.Sequential)]
internal readonly struct NativeBufferValue
{
    internal NativeBufferValue(IntPtr pointer, nuint length)
    {
        Pointer = pointer;
        Length = length;
    }

    internal readonly IntPtr Pointer;

    internal readonly nuint Length;
}
