using Lorepia.Native.Interop;

namespace Lorepia.Native.Tests;

public sealed class NativeStatusTests
{
    [Fact]
    public void Success_DoesNotThrow()
    {
        NativeStatus.ThrowIfFailed("operation", NativeStatus.Success);
    }

    [Fact]
    public void Failure_PreservesOperationAndRawStatus()
    {
        var exception = Assert.Throws<CoreInteropException>(
            () => NativeStatus.ThrowIfFailed("lorepia_core_version", -7));

        Assert.Contains("lorepia_core_version", exception.Message);
        Assert.Contains("-7", exception.Message);
    }
}
