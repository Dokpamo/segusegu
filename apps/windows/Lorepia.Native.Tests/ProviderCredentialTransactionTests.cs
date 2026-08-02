using Lorepia.App.Platform;

namespace Lorepia.Native.Tests;

public sealed class ProviderCredentialTransactionTests
{
    [Fact]
    public async Task NewCredentialIsRemovedWhenCoreSaveFails()
    {
        var credentials = new RecordingCredentialStore();

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            ProviderCredentialTransaction.PersistAsync(
                credentials,
                "connection-a",
                "new-secret",
                () => Task.FromException(
                    new InvalidOperationException("core rejected"))));

        Assert.Null(credentials.Get("connection-a"));
        Assert.DoesNotContain(
            credentials.Operations,
            operation => operation.Contains(
                "new-secret",
                StringComparison.Ordinal));
    }

    [Fact]
    public async Task PreviousCredentialIsRestoredWhenCoreUpdateFails()
    {
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-a", "old-secret");
        credentials.Operations.Clear();

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            ProviderCredentialTransaction.PersistAsync(
                credentials,
                "connection-a",
                "replacement-secret",
                () => Task.FromException(
                    new InvalidOperationException("core rejected"))));

        Assert.Equal("old-secret", credentials.Get("connection-a"));
        Assert.Equal(
            [
                "get:connection-a",
                "save:connection-a",
                "save:connection-a",
                "get:connection-a",
            ],
            credentials.Operations);
    }

    [Fact]
    public async Task CoreDeleteFailureRestoresPasswordVaultEntry()
    {
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-a", "secret");
        credentials.Operations.Clear();

        await Assert.ThrowsAsync<InvalidOperationException>(() =>
            ProviderCredentialTransaction.DeleteAsync(
                credentials,
                "connection-a",
                () => Task.FromException(
                    new InvalidOperationException("route still references connection"))));

        Assert.Equal("secret", credentials.Get("connection-a"));
        Assert.Equal(
            [
                "get:connection-a",
                "delete:connection-a",
                "save:connection-a",
                "get:connection-a",
            ],
            credentials.Operations);
    }

    [Fact]
    public async Task CompensationFailureIsReportedWithoutCredentialMaterial()
    {
        var credentials = new RecordingCredentialStore
        {
            FailSaveAfter = 2,
        };
        credentials.Save("connection-a", "old-secret");
        credentials.Operations.Clear();

        var exception = await Assert.ThrowsAsync<
            ProviderCredentialCompensationException>(() =>
                ProviderCredentialTransaction.PersistAsync(
                    credentials,
                    "connection-a",
                    "replacement-secret",
                    () => Task.FromException(
                        new InvalidOperationException("core rejected"))));

        Assert.DoesNotContain(
            "old-secret",
            exception.Message,
            StringComparison.Ordinal);
        Assert.DoesNotContain(
            "replacement-secret",
            exception.Message,
            StringComparison.Ordinal);
        Assert.IsType<InvalidOperationException>(exception.PrimaryFailure);
        Assert.IsType<CredentialStoreTestException>(
            exception.CompensationFailure);
    }

    private sealed class RecordingCredentialStore :
        IProviderCredentialStore
    {
        private readonly Dictionary<string, string> values =
            new(StringComparer.Ordinal);
        private int saveCount;

        internal List<string> Operations { get; } = [];

        internal int? FailSaveAfter { get; init; }

        public string? Get(string connectionId)
        {
            Operations.Add($"get:{connectionId}");
            return values.GetValueOrDefault(connectionId);
        }

        public void Save(string connectionId, string credential)
        {
            saveCount++;
            if (FailSaveAfter is { } threshold
                && saveCount > threshold)
            {
                throw new CredentialStoreTestException();
            }

            Operations.Add($"save:{connectionId}");
            values[connectionId] = credential;
        }

        public void Delete(string connectionId)
        {
            Operations.Add($"delete:{connectionId}");
            values.Remove(connectionId);
        }
    }

    private sealed class CredentialStoreTestException : Exception;
}
