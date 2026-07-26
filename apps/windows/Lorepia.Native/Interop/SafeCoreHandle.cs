using Microsoft.Win32.SafeHandles;
using System.Threading;

namespace Lorepia.Native.Interop;

internal sealed class SafeCoreHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    private Action<IntPtr>? release;

    private SafeCoreHandle()
        : base(ownsHandle: true)
    {
    }

    internal SafeCoreHandle(IntPtr handle, Action<IntPtr> release)
        : base(ownsHandle: true)
    {
        ArgumentNullException.ThrowIfNull(release);
        this.release = release;
        SetHandle(handle);
    }

    protected override bool ReleaseHandle()
    {
        var callback = Interlocked.Exchange(ref release, null);
        if (callback is null)
        {
            return true;
        }

        try
        {
            callback(handle);
            return true;
        }
        catch
        {
            return false;
        }
    }
}
