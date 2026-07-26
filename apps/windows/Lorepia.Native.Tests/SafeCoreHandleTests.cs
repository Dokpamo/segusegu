using Lorepia.Native.Interop;

namespace Lorepia.Native.Tests;

public sealed class SafeCoreHandleTests
{
    [Fact]
    public void Dispose_ReleasesOwnedHandleExactlyOnce()
    {
        var releaseCount = 0;
        var releasedPointer = IntPtr.Zero;
        var handle = new SafeCoreHandle(
            new IntPtr(0xBEEF),
            pointer =>
            {
                releaseCount++;
                releasedPointer = pointer;
            });

        handle.Dispose();
        handle.Dispose();

        Assert.Equal(1, releaseCount);
        Assert.Equal(new IntPtr(0xBEEF), releasedPointer);
        Assert.True(handle.IsClosed);
    }
}
