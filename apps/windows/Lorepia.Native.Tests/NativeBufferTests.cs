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
    public void ReadUtf8_RejectsMalformedUtf8AndStillFrees()
    {
        var pointer = Marshal.AllocHGlobal(2);
        Marshal.Copy(new byte[] { 0xc3, 0x28 }, 0, pointer, 2);
        var freeCount = 0;
        using (var buffer = new NativeBuffer(
                   new NativeBufferValue(pointer, 2),
                   value =>
                   {
                       freeCount++;
                       Marshal.FreeHGlobal(value.Pointer);
                   }))
        {
            Assert.Throws<CoreInteropException>(() => buffer.ReadUtf8());
        }

        Assert.Equal(1, freeCount);
    }

    [Fact]
    public void NativeBufferValue_MatchesTwoPointerAbiLayout()
    {
        Assert.Equal(IntPtr.Size * 2, Marshal.SizeOf<NativeBufferValue>());
    }
}
