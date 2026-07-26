namespace Lorepia.Native.Tests;

public sealed class CoreClientTests
{
    [Fact]
    public void MapsVersionAndHealthAndOwnsAllNativeLifetimes()
    {
        var api = new FakeNativeApi();
        var dataRoot = CreateAbsoluteDataRoot();

        using (var client = CoreClient.Open(api, dataRoot))
        {
            Assert.Equal(CoreClient.SupportedAbiVersion, client.AbiVersion);
            Assert.Equal("0.1.0-test", client.GetCoreVersion());

            var health = client.GetHealthCheck();

            Assert.Equal("0.1.0-test", health.CoreVersion);
            Assert.True(health.DatabaseOpen);
            Assert.Equal(3, health.SchemaVersion);
            Assert.True(health.DataRootWritable);
            Assert.True(health.StagingWritable);
            Assert.False(health.RecoveryPending);
            Assert.Equal(2, health.ActiveJobs);
            var characters = client.ListCharacters();
            var character = Assert.Single(characters);
            Assert.Equal("character-1", character.Id);
            Assert.Equal("테스트 캐릭터", character.Name);
            Assert.Equal("합성 테스트 데이터", character.Description);
            Assert.Equal("abc123", character.SourceHash);
            Assert.Equal(3, api.BufferFreeCount);
            Assert.Equal(0, api.DestroyCount);
        }

        using var configuration = System.Text.Json.JsonDocument.Parse(
            api.ConfigurationJson!);
        Assert.Equal(
            Path.GetFullPath(dataRoot),
            configuration.RootElement.GetProperty("data_root").GetString());
        Assert.Equal(1, api.CreateCount);
        Assert.Equal(1, api.DestroyCount);
    }

    [Fact]
    public void Create_RejectsAbiMismatchBeforeCreatingCore()
    {
        var api = new FakeNativeApi
        {
            AbiVersion = CoreClient.SupportedAbiVersion + 1,
        };

        var exception = Assert.Throws<CoreInteropException>(
            () => CoreClient.Open(api, CreateAbsoluteDataRoot()));

        Assert.Contains("Unsupported", exception.Message);
        Assert.Equal(0, api.CreateCount);
        Assert.Equal(0, api.DestroyCount);
    }

    [Fact]
    public void CallsAfterDispose_AreRejected()
    {
        var api = new FakeNativeApi();
        var client = CoreClient.Open(api, CreateAbsoluteDataRoot());
        client.Dispose();

        var calls = new Action[]
        {
            () => _ = client.GetCoreVersion(),
            () => _ = client.GetHealthCheck(),
            () => _ = client.ListCharacters(),
            () => _ = client.GetCharacter("character-1"),
            () => _ = client.InspectImport(
                Path.Combine(CreateAbsoluteDataRoot(), "card.json")),
            () => _ = client.CommitImport("inspection-1"),
            () => client.DiscardImport("inspection-1"),
            () => _ = client.ListConversations(),
            () => _ = client.OpenConversation("character-1"),
            () => _ = client.ListMessages("conversation-1"),
            () => _ = client.SendMessage(
                "conversation-1",
                "hello",
                "provider-1",
                null),
            () => client.CancelGeneration("generation-1"),
            () => _ = client.PollEvents(),
            () => _ = client.GetSettings(),
            () => client.UpdateSettings(new AppSettings()),
            () => _ = client.ListProviderProfiles(),
            () => _ = client.UpsertProviderProfile(new ProviderProfile
            {
                Id = "provider-1",
                DisplayName = "Provider",
                BaseUrl = "https://example.invalid/v1",
                Model = "model",
                TimeoutSeconds = 30,
            }),
            () => client.DeleteProviderProfile("provider-1"),
        };
        foreach (var call in calls)
        {
            Assert.Throws<ObjectDisposedException>(call);
        }
        Assert.Equal(1, api.DestroyCount);
    }

    [Fact]
    public void HealthMapping_RejectsInvalidJsonAndStillFreesBuffer()
    {
        var api = new FakeNativeApi
        {
            HealthJson = "{ definitely-not-json",
        };

        using var client = CoreClient.Open(api, CreateAbsoluteDataRoot());

        Assert.Throws<CoreInteropException>(() => client.GetHealthCheck());
        Assert.Equal(1, api.BufferFreeCount);
    }

    [Fact]
    public void HealthMapping_RejectsMissingCoreVersion()
    {
        var api = new FakeNativeApi
        {
            HealthJson = """{"database_open":true,"schema_version":1}""",
        };

        using var client = CoreClient.Open(api, CreateAbsoluteDataRoot());

        Assert.Throws<CoreInteropException>(() => client.GetHealthCheck());
    }

    [Fact]
    public void Open_SerializesAbsoluteDataRoot()
    {
        var api = new FakeNativeApi();
        var dataRoot = CreateAbsoluteDataRoot("로어피아");

        using var client = CoreClient.Open(api, dataRoot);

        using var configuration = System.Text.Json.JsonDocument.Parse(
            api.ConfigurationJson!);
        Assert.Equal(
            Path.GetFullPath(dataRoot),
            configuration.RootElement.GetProperty("data_root").GetString());
    }

    [Fact]
    public void Open_RejectsRelativeDataRootBeforeCallingNativeApi()
    {
        var api = new FakeNativeApi();

        Assert.Throws<ArgumentException>(
            () => CoreClient.Open(api, "relative/data"));
        Assert.Equal(0, api.CreateCount);
    }

    [Fact]
    public void CharacterMapping_RejectsMissingRequiredFields()
    {
        var api = new FakeNativeApi
        {
            CharactersJson = """[{"id":"one","name":"Missing hash"}]""",
        };

        using var client = CoreClient.Open(api, CreateAbsoluteDataRoot());

        Assert.Throws<CoreInteropException>(() => client.ListCharacters());
        Assert.Equal(1, api.BufferFreeCount);
    }

    private static string CreateAbsoluteDataRoot(string? suffix = null)
    {
        return Path.Combine(
            Path.GetTempPath(),
            "lorepia-native-tests",
            suffix ?? Guid.NewGuid().ToString("N"));
    }
}
