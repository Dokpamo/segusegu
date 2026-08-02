using Lorepia.App.Platform;
using Lorepia.App.ViewModels;
using System.Text.Json;

namespace Lorepia.Native.Tests;

public sealed class ChatViewModelProviderTargetTests
{
    [Fact]
    public async Task LoadUsesExactSavedRouteAndPresetTarget()
    {
        var api = new FakeNativeApi
        {
            SettingsJson =
                """
                {
                  "preserve_partial_generations": true,
                  "selected_provider_profile_id": null,
                  "selected_model_route_id": "route-1",
                  "selected_generation_preset_id": "preset-1"
                }
                """,
        };
        using var core = Open(api);
        var viewModel = new ChatViewModel(
            core,
            new RecordingCredentialStore());

        await viewModel.LoadAsync();

        var target = Assert.Single(viewModel.Targets);
        Assert.Same(target, viewModel.SelectedTarget);
        Assert.Equal("connection-1", target.ConnectionId);
        Assert.Equal("route-1", target.ModelRouteId);
        Assert.Equal("preset-1", target.GenerationPresetId);
        Assert.Contains("Model One", target.DisplayName);
        Assert.DoesNotContain("provider profile", viewModel.Status);
    }

    [Theory]
    [InlineData("missing_temporarily")]
    [InlineData("access_denied")]
    [InlineData("deprecated")]
    [InlineData("retired")]
    public async Task LoadExcludesRoutesCoreRejectsForGeneration(
        string availability)
    {
        var api = new FakeNativeApi();
        api.ModelRouteJson = api.ModelRouteJson.Replace(
            "\"availability\": \"available\"",
            $"\"availability\": \"{availability}\"",
            StringComparison.Ordinal);
        using var core = Open(api);
        var viewModel = new ChatViewModel(
            core,
            new RecordingCredentialStore());

        await viewModel.LoadAsync();

        Assert.Empty(viewModel.Targets);
        Assert.Null(viewModel.SelectedTarget);
    }

    [Fact]
    public async Task SendUsesConnectionCredentialAndVersionedTarget()
    {
        var api = new FakeNativeApi
        {
            SettingsJson =
                """
                {
                  "preserve_partial_generations": true,
                  "selected_provider_profile_id": null,
                  "selected_model_route_id": "route-1",
                  "selected_generation_preset_id": "preset-1"
                }
                """,
        };
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save("connection-1", "request-secret");
        var viewModel = new ChatViewModel(core, credentials);
        await viewModel.LoadAsync();
        viewModel.Draft = "hello";

        try
        {
            await viewModel.SendAsync();
        }
        finally
        {
            viewModel.Stop();
        }

        Assert.Equal("request-secret", api.LastCredential);
        using var request =
            JsonDocument.Parse(api.LastTargetRequestJson!);
        var root = request.RootElement;
        Assert.Equal(
            1,
            root.GetProperty("request_schema_version").GetInt32());
        var payload = root.GetProperty("payload");
        Assert.Equal(
            "conversation-1",
            payload.GetProperty("conversation_id").GetString());
        Assert.Equal(
            "route-1",
            payload
                .GetProperty("target")
                .GetProperty("model_route_id")
                .GetString());
        Assert.Equal(
            "preset-1",
            payload
                .GetProperty("target")
                .GetProperty("generation_preset_id")
                .GetString());
        Assert.DoesNotContain(
            "request-secret",
            api.LastTargetRequestJson,
            StringComparison.Ordinal);
    }

    [Fact]
    public async Task StopDuringLoadRejectsLateStateAndPolling()
    {
        var entered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi
        {
            BeforeGetConversations = () =>
            {
                entered.TrySetResult();
                if (!release.Task.Wait(
                        TimeSpan.FromSeconds(5)))
                {
                    throw new TimeoutException(
                        "Test chat load was not released.");
                }
            },
        };
        using var core = Open(api);
        var viewModel = new ChatViewModel(
            core,
            new RecordingCredentialStore());

        var load = viewModel.LoadAsync();
        await entered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        viewModel.Stop();
        release.TrySetResult();
        await load;

        Assert.False(viewModel.IsLoading);
        Assert.Empty(viewModel.Targets);
        Assert.Empty(viewModel.Messages);
        Assert.Equal(0, api.PollEventsCount);
    }

    [Fact]
    public async Task StopDuringAcceptedSendDoesNotRestartDetachedPolling()
    {
        var entered = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var api = new FakeNativeApi();
        using var core = Open(api);
        var credentials = new RecordingCredentialStore();
        credentials.Save(
            "connection-1",
            "request-secret");
        var viewModel =
            new ChatViewModel(core, credentials);
        await viewModel.LoadAsync();
        viewModel.Draft = "hello";
        api.BeforeSendMessageWithTarget = () =>
        {
            entered.TrySetResult();
            if (!release.Task.Wait(
                    TimeSpan.FromSeconds(5)))
            {
                throw new TimeoutException(
                    "Test chat send was not released.");
            }
        };

        var send = viewModel.SendAsync();
        await entered.Task.WaitAsync(
            TimeSpan.FromSeconds(2));
        viewModel.Stop();
        release.TrySetResult();
        await send;
        await Task.Delay(150);

        Assert.False(viewModel.IsLoading);
        Assert.Equal("hello", viewModel.Draft);
        Assert.NotNull(api.LastTargetRequestJson);
        Assert.Equal(0, api.PollEventsCount);
    }

    private static CoreClient Open(FakeNativeApi api)
    {
        return CoreClient.Open(
            api,
            Path.Combine(
                Path.GetTempPath(),
                "lorepia-chat-provider-target-tests",
                Guid.NewGuid().ToString("N")));
    }

    private sealed class RecordingCredentialStore :
        IProviderCredentialStore
    {
        private readonly Dictionary<string, string> values =
            new(StringComparer.Ordinal);

        public string? Get(string connectionId)
        {
            return values.GetValueOrDefault(connectionId);
        }

        public void Save(string connectionId, string credential)
        {
            values[connectionId] = credential;
        }

        public void Delete(string connectionId)
        {
            values.Remove(connectionId);
        }
    }
}
