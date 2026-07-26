using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Lorepia.Native.Interop;

internal sealed class NativeBuffer : IDisposable
{
    private readonly NativeBufferValue value;
    private Action<NativeBufferValue>? release;
    private int disposed;

    internal NativeBuffer(
        NativeBufferValue value,
        Action<NativeBufferValue> release)
    {
        ArgumentNullException.ThrowIfNull(release);
        this.value = value;
        this.release = release;
    }

    internal string ReadUtf8()
    {
        ObjectDisposedException.ThrowIf(
            Volatile.Read(ref disposed) != 0,
            this);

        var length = checked((int)value.Length);
        if (length == 0)
        {
            return string.Empty;
        }

        if (value.Pointer == IntPtr.Zero)
        {
            throw new CoreInteropException(
                "The native core returned a null buffer with a non-zero length.");
        }

        var bytes = new byte[length];
        Marshal.Copy(value.Pointer, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0)
        {
            return;
        }

        var callback = Interlocked.Exchange(ref release, null);
        callback?.Invoke(value);
    }
}
