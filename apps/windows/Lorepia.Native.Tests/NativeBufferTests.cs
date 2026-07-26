using Lorepia.Native.Interop;
using System.Runtime.InteropServices;
using System.Text;

namespace Lorepia.Native.Tests;

public sealed class NativeBufferTests
{
    [Fact]
    public void ReadUtf8_DecodesUnicodeAndFreesExactlyOnce()
    {
        const string expected = "로어피아 🌿";
        var bytes = Encoding.UTF8.GetBytes(expected);
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        var freeCount = 0;

        var buffer = new NativeBuffer(
            new NativeBufferValue(pointer, checked((nuint)bytes.Length)),
            value =>
            {
                freeCount++;
                Marshal.FreeHGlobal(value.Pointer);
            });

        Assert.Equal(expected, buffer.ReadUtf8());

        buffer.Dispose();
        buffer.Dispose();

        Assert.Equal(1, freeCount);
        Assert.Throws<ObjectDisposedException>(() => buffer.ReadUtf8());
    }

    [Fact]
    public void ReadUtf8_RejectsNullPointerWithLength()
    {
        using var buffer = new NativeBuffer(
            new NativeBufferValue(IntPtr.Zero, 4),
            _ => { });

        Assert.Throws<CoreInteropException>(() => buffer.ReadUtf8());
    }

    [Fact]
    public void NativeBufferValue_MatchesTwoPointerAbiLayout()
    {
        Assert.Equal(IntPtr.Size * 2, Marshal.SizeOf<NativeBufferValue>());
    }
}
