using System.Runtime.InteropServices;
using Lorepia.App.Platform;

namespace Lorepia.Native.Tests;

public sealed class PasswordVaultErrorTests
{
    [Fact]
    public void ExactElementNotFoundHResultIsRecognized()
    {
        var exception = new COMException(
            "synthetic missing credential",
            PasswordVaultError.ElementNotFoundHResult);

        Assert.True(PasswordVaultError.IsElementNotFound(exception));
    }

    [Theory]
    [InlineData(unchecked((int)0x80070005))]
    [InlineData(unchecked((int)0x80004005))]
    [InlineData(unchecked((int)0x80070057))]
    public void OtherComFailuresAreNotRecognized(int hresult)
    {
        var exception = new COMException("synthetic vault failure", hresult);

        Assert.False(PasswordVaultError.IsElementNotFound(exception));
    }
}
