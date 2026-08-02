namespace Lorepia.Native.Tests;

public sealed class CoreClientTests
{
    [Fact]
    public void PublicContract_DeclaresAbiVersionSeven()
    {
        Assert.Equal(7u, CoreClient.SupportedAbiVersion);
    }

    [Fact]
    public void FrozenAbiTwoClient_RejectsAbiSevenBeforeCreatingCore()
    {
        var api = new FakeNativeApi
        {
            AbiVersion = CoreClient.SupportedAbiVersion,
        };

        var exception = Assert.Throws<CoreInteropException>(
            () => FrozenAbiTwoClient.Open(api));

        Assert.Contains("version 7", exception.Message);
        Assert.Contains("expected 2", exception.Message);
        Assert.Equal(0, api.CreateCount);
        Assert.Equal(0, api.DestroyCount);
    }

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

    [Theory]
    [InlineData(3u)]
    [InlineData(4u)]
    [InlineData(5u)]
    [InlineData(6u)]
    [InlineData(8u)]
    public void Create_RejectsAbiMismatchBeforeCreatingCore(uint abiVersion)
    {
        var api = new FakeNativeApi
        {
            AbiVersion = abiVersion,
        };

        var exception = Assert.Throws<CoreInteropException>(
            () => CoreClient.Open(api, CreateAbsoluteDataRoot()));

        Assert.Contains("Unsupported", exception.Message);
        Assert.Contains("expected 7", exception.Message);
        Assert.Equal(0, api.CreateCount);
        Assert.Equal(0, api.DestroyCount);
    }

    [Fact]
    public void CallsAfterDispose_AreRejected()
    {
        var api = new FakeNativeApi();
        var client = CoreClient.Open(api, CreateAbsoluteDataRoot());
        var candidate = new GenerationPreset
        {
            Id = "preset-1",
            ModelRouteId = "route-1",
            DisplayName = "Candidate",
            CreatedAt = DateTimeOffset.UtcNow,
            UpdatedAt = DateTimeOffset.UtcNow,
        };
        var catalogEnvelope =
            System.Text.Encoding.UTF8.GetBytes("{}");
        var catalogImportPlan =
            client.PrepareSignedProviderCatalogImport(
                catalogEnvelope);
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
            () => _ = client.SendMessageWithTarget(
                "conversation-1",
                "hello",
                new GenerationTarget
                {
                    ModelRouteId = "route-1",
                    GenerationPresetId = "preset-1",
                },
                "connection-1",
                null),
            () => client.CancelGeneration("generation-1"),
            () => _ = client.PollEvents(),
            () => _ = client.GetSettings(),
            () => client.UpdateSettings(new AppSettings()),
            () => _ = client.ListProviderTemplates(),
            () => _ = client.ListProviderConnections(),
            () => client.DeleteProviderConnection("connection-1"),
            () => _ = client.ListModelRoutes("connection-1"),
            () => client.DeleteModelRoute("route-1"),
            () => _ = client.ListCapabilityObservations("route-1"),
            () => _ = client.GetEffectiveCapability(
                "route-1",
                CapabilityKey.Streaming),
            () => _ = client.GetEffectiveParameterSpecs("route-1"),
            () => client.DeleteUserCapabilityOverride(
                "route-1",
                "observation-1"),
            () => _ = client.RefreshProviderModels("connection-1", null),
            () => _ = client.StartProviderModelSync("connection-1", null),
            () => _ = client.GetProviderModelSync("sync-1"),
            () => _ = client.ListProviderModelSyncs("connection-1"),
            () => _ = client.ApproveProviderModelSync(
                "sync-1",
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            () => _ = client.CancelProviderModelSync("sync-1"),
            () => _ = client.PollProviderModelSyncEvents(
                "sync-1"),
            () => _ = client.AckProviderModelSyncEvent(
                "sync-1",
                1),
            () => _ = client.GetProviderCatalogStatus(),
            () => _ = client.GetProviderCatalogHistory(),
            () => _ = client.PrepareSignedProviderCatalogImport(
                catalogEnvelope),
            () => _ = client.ActivateSignedProviderCatalogImport(
                catalogImportPlan,
                catalogEnvelope),
            () => _ = client.DiffProviderCatalogRevisions(1, 2),
            () => _ = client.PrepareProviderCatalogRollback(1),
            () => _ = client.ListGenerationPresets("route-1"),
            () => client.ValidateGenerationPreset("route-1", "preset-1"),
            () => client.ValidateGenerationPresetCandidate(candidate),
            () => _ = client.RenderReasoningControlCandidate(candidate),
            () => _ = client.RenderPromptCacheControlCandidate(candidate),
            () => _ = client.PreviewProviderRequest("route-1", "preset-1"),
            () => _ = client.PreviewProviderRequestCandidate(candidate),
            () => client.DeleteGenerationPreset("preset-1"),
            () => _ = client.SelectGenerationTarget(null),
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

    private static class FrozenAbiTwoClient
    {
        private const uint SupportedAbiVersion = 2;

        internal static void Open(FakeNativeApi nativeApi)
        {
            var abiVersion = nativeApi.GetAbiVersion();
            if (abiVersion != SupportedAbiVersion)
            {
                throw new CoreInteropException(
                    $"Unsupported LorePia C ABI version {abiVersion}; expected {SupportedAbiVersion}.");
            }

            using var core = nativeApi.CreateCore(Array.Empty<byte>());
        }
    }
}
