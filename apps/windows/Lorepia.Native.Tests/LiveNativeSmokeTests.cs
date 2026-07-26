namespace Lorepia.Native.Tests;

public sealed class LiveNativeSmokeTests
{
    [Fact]
    public void BuiltRustDllCreatesCoreAndReturnsHealth()
    {
        if (Environment.GetEnvironmentVariable("LOREPIA_RUN_LIVE_NATIVE_TESTS") != "1")
        {
            return;
        }

        Assert.True(OperatingSystem.IsWindows());
        var dataRoot = Path.Combine(
            Path.GetTempPath(),
            "lorepia-live-native-tests",
            Guid.NewGuid().ToString("N"));

        try
        {
            using var client = CoreClient.Open(dataRoot);
            var version = client.GetCoreVersion();
            var health = client.GetHealthCheck();

            Assert.False(string.IsNullOrWhiteSpace(version));
            Assert.Equal(version, health.CoreVersion);
            Assert.True(health.DatabaseOpen);
            Assert.True(health.DataRootWritable);
            Assert.True(health.StagingWritable);
            Assert.Empty(client.ListCharacters());
        }
        finally
        {
            if (Directory.Exists(dataRoot))
            {
                Directory.Delete(dataRoot, recursive: true);
            }
        }
    }
}
