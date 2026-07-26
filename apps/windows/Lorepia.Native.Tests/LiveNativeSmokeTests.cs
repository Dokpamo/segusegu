using System.Net;
using System.Net.Sockets;
using System.Text;

namespace Lorepia.Native.Tests;

public sealed class LiveNativeSmokeTests
{
    [Fact]
    public async Task BuiltRustDllExercisesImportChatSettingsAndRestart()
    {
        if (Environment.GetEnvironmentVariable(
                "LOREPIA_RUN_LIVE_NATIVE_TESTS") != "1")
        {
            return;
        }

        Assert.True(OperatingSystem.IsWindows());
        var dataRoot = Path.Combine(
            Path.GetTempPath(),
            "lorepia-live-native-tests",
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dataRoot);
        var cardPath = Path.Combine(dataRoot, "synthetic-card.json");
        var largeDescription = string.Concat(
            Enumerable.Repeat("큰문자열😀", 8_192));
        await File.WriteAllTextAsync(
            cardPath,
            System.Text.Json.JsonSerializer.Serialize(new
            {
                spec = "chara_card_v3",
                data = new
                {
                    name = "Windows 합성 😀 e\u0301",
                    description = largeDescription,
                },
            }));

        try
        {
            string conversationId;
            await using (var server = await SingleResponseSseServer.StartAsync(
                             "Hello from Windows ABI"))
            using (var client = CoreClient.Open(dataRoot))
            {
                var version = client.GetCoreVersion();
                var health = client.GetHealthCheck();
                Assert.False(string.IsNullOrWhiteSpace(version));
                Assert.Equal(version, health.CoreVersion);
                Assert.True(health.DatabaseOpen);
                Assert.True(health.DataRootWritable);
                Assert.True(health.StagingWritable);
                Assert.Empty(client.ListCharacters());
                Assert.Empty(client.ListConversations());
                Assert.Empty(client.ListProviderProfiles());
                Assert.Null(
                    client.GetSettings().SelectedProviderProfileId);
                Assert.Empty(client.PollEvents().Events);

                var discarded = client.InspectImport(cardPath);
                client.DiscardImport(discarded.Id);

                var inspection = client.InspectImport(cardPath);
                Assert.True(inspection.IsAllowed);
                Assert.Equal("character_card_v3", inspection.Kind);
                Assert.Equal("Windows 합성 😀 e\u0301", inspection.DisplayName);
                Assert.Equal(largeDescription, inspection.Description);
                var character = client.CommitImport(inspection.Id);
                Assert.Equal(
                    "Windows 합성 😀 e\u0301",
                    client.GetCharacter(character.Id).Name);
                Assert.Equal(
                    largeDescription,
                    client.GetCharacter(character.Id).Description);
                Assert.Null(character.AvatarAssetHash);
                Assert.Single(client.ListCharacters());

                var conversation = client.OpenConversation(character.Id);
                conversationId = conversation.Id;
                Assert.Single(client.ListConversations());

                var profile = client.UpsertProviderProfile(new ProviderProfile
                {
                    Id = "windows-live",
                    DisplayName = "Windows live test",
                    BaseUrl = server.BaseUrl,
                    Model = "synthetic",
                    TimeoutSeconds = 5,
                });
                client.UpdateSettings(new AppSettings
                {
                    PreservePartialGenerations = false,
                    SelectedProviderProfileId = profile.Id,
                });
                Assert.Equal(
                    profile.Id,
                    client.GetSettings().SelectedProviderProfileId);

                var generationId = client.SendMessage(
                    conversation.Id,
                    "질문😀",
                    profile.Id,
                    null);
                var deadline = DateTimeOffset.UtcNow.AddSeconds(10);
                var finished = false;
                var events = new List<ChatEvent>();
                while (DateTimeOffset.UtcNow < deadline && !finished)
                {
                    var batch = client.PollEvents(64);
                    events.AddRange(batch.Events.Where(chatEvent =>
                        chatEvent.GenerationId == generationId));
                    finished = events.Any(chatEvent =>
                        chatEvent.Type == ChatEventType.GenerationFinished);
                    if (!finished)
                    {
                        await Task.Delay(20);
                    }
                }

                Assert.True(finished);
                Assert.Equal(
                    ChatEventType.GenerationStarted,
                    events.First().Type);
                Assert.Equal(
                    ChatEventType.GenerationFinished,
                    events.Last().Type);
                Assert.True(events.Zip(events.Skip(1)).All(pair =>
                    pair.First.Sequence < pair.Second.Sequence));
                var messages = client.ListMessages(conversation.Id);
                Assert.Equal(2, messages.Count);
                Assert.Equal("질문😀", messages[0].Content);
                Assert.Equal("user", messages[0].Role);
                Assert.Null(messages[0].ParentId);
                Assert.Null(messages[0].GenerationId);
                Assert.Equal("Hello from Windows ABI", messages[1].Content);
                Assert.Equal("assistant", messages[1].Role);
                Assert.Equal("complete", messages[1].Status);
                Assert.NotNull(messages[1].GenerationId);

                var exception = Assert.Throws<CoreInteropException>(() =>
                    client.CancelGeneration("unknown-generation"));
                Assert.Equal("not_found", exception.Code);

                await using var cancellationServer =
                    await StallingSseServer.StartAsync("부분😀");
                var cancellationConversation =
                    client.OpenConversation(character.Id);
                var cancellationProfile = client.UpsertProviderProfile(
                    new ProviderProfile
                    {
                        Id = "windows-cancellation",
                        DisplayName = "Windows cancellation",
                        BaseUrl = cancellationServer.BaseUrl,
                        Model = "synthetic",
                        TimeoutSeconds = 5,
                    });
                var cancellationId = client.SendMessage(
                    cancellationConversation.Id,
                    "중지해",
                    cancellationProfile.Id,
                    null);
                await cancellationServer.WaitUntilStreamingAsync();

                deadline = DateTimeOffset.UtcNow.AddSeconds(10);
                var cancellationEvents = new List<ChatEvent>();
                while (DateTimeOffset.UtcNow < deadline
                    && !cancellationEvents.Any(chatEvent =>
                        chatEvent.Type == ChatEventType.TextDelta))
                {
                    cancellationEvents.AddRange(
                        client.PollEvents(64).Events.Where(chatEvent =>
                            chatEvent.GenerationId == cancellationId));
                    await Task.Delay(20);
                }
                Assert.Contains(
                    cancellationEvents,
                    chatEvent => chatEvent.Type == ChatEventType.TextDelta);

                client.CancelGeneration(cancellationId);
                while (DateTimeOffset.UtcNow < deadline
                    && !cancellationEvents.Any(chatEvent =>
                        chatEvent.Type == ChatEventType.GenerationCancelled))
                {
                    cancellationEvents.AddRange(
                        client.PollEvents(64).Events.Where(chatEvent =>
                            chatEvent.GenerationId == cancellationId));
                    await Task.Delay(20);
                }
                Assert.Equal(
                    ChatEventType.GenerationStarted,
                    cancellationEvents.First().Type);
                Assert.Equal(
                    ChatEventType.GenerationCancelled,
                    cancellationEvents.Last().Type);
                Assert.True(
                    cancellationEvents
                        .Zip(cancellationEvents.Skip(1))
                        .All(pair =>
                            pair.First.Sequence < pair.Second.Sequence));
                var cancelledMessages = client.ListMessages(
                    cancellationConversation.Id);
                Assert.Equal("부분😀", cancelledMessages[1].Content);
                Assert.Equal("assistant", cancelledMessages[1].Role);
                Assert.Equal("cancelled", cancelledMessages[1].Status);
            }

            using (var reopened = CoreClient.Open(dataRoot))
            {
                var messages = reopened.ListMessages(conversationId);
                Assert.Equal(2, messages.Count);
                Assert.Equal("Hello from Windows ABI", messages[1].Content);
            }
        }
        finally
        {
            if (Directory.Exists(dataRoot))
            {
                Directory.Delete(dataRoot, recursive: true);
            }
        }
    }

    private sealed class StallingSseServer : IAsyncDisposable
    {
        private readonly TcpListener listener;
        private readonly Task serverTask;
        private readonly TaskCompletionSource streaming =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource release =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        private StallingSseServer(
            TcpListener listener,
            string baseUrl,
            string responseText)
        {
            this.listener = listener;
            BaseUrl = baseUrl;
            serverTask = ServeAsync(responseText);
        }

        internal string BaseUrl { get; }

        internal static Task<StallingSseServer> StartAsync(
            string responseText)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var endpoint = (IPEndPoint)listener.LocalEndpoint;
            return Task.FromResult(new StallingSseServer(
                listener,
                $"http://127.0.0.1:{endpoint.Port}/v1",
                responseText));
        }

        internal async Task WaitUntilStreamingAsync()
        {
            await streaming.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }

        public async ValueTask DisposeAsync()
        {
            release.TrySetResult();
            try
            {
                await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (Exception exception) when (
                exception is IOException
                or OperationCanceledException
                or ObjectDisposedException
                or SocketException
                or TimeoutException)
            {
            }
            finally
            {
                listener.Stop();
            }
        }

        private async Task ServeAsync(string responseText)
        {
            using var client = await listener.AcceptTcpClientAsync();
            await using var stream = client.GetStream();
            var requestBuffer = new byte[16 * 1024];
            _ = await stream.ReadAsync(requestBuffer);

            var escaped = System.Text.Json.JsonSerializer.Serialize(
                responseText);
            var eventText =
                $"data: {{\"choices\":[{{\"delta\":{{\"content\":{escaped}}}}}]}}\n\n";
            var eventBytes = Encoding.UTF8.GetBytes(eventText);
            var header = Encoding.ASCII.GetBytes(
                "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/event-stream\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "Connection: close\r\n\r\n"
                + $"{eventBytes.Length:X}\r\n");
            await stream.WriteAsync(header);
            await stream.WriteAsync(eventBytes);
            await stream.WriteAsync(Encoding.ASCII.GetBytes("\r\n"));
            await stream.FlushAsync();
            streaming.TrySetResult();

            try
            {
                await release.Task.WaitAsync(TimeSpan.FromSeconds(5));
                await stream.WriteAsync(
                    Encoding.ASCII.GetBytes("0\r\n\r\n"));
                await stream.FlushAsync();
            }
            catch (Exception exception) when (
                exception is IOException
                or ObjectDisposedException
                or SocketException
                or TimeoutException)
            {
            }
        }
    }

    private sealed class SingleResponseSseServer : IAsyncDisposable
    {
        private readonly TcpListener listener;
        private readonly Task serverTask;

        private SingleResponseSseServer(
            TcpListener listener,
            Task serverTask,
            string baseUrl)
        {
            this.listener = listener;
            this.serverTask = serverTask;
            BaseUrl = baseUrl;
        }

        internal string BaseUrl { get; }

        internal static Task<SingleResponseSseServer> StartAsync(
            string responseText)
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            var endpoint = (IPEndPoint)listener.LocalEndpoint;
            var task = ServeOnceAsync(listener, responseText);
            return Task.FromResult(new SingleResponseSseServer(
                listener,
                task,
                $"http://127.0.0.1:{endpoint.Port}/v1"));
        }

        public async ValueTask DisposeAsync()
        {
            listener.Stop();
            try
            {
                await serverTask.WaitAsync(TimeSpan.FromSeconds(5));
            }
            catch (Exception exception) when (
                exception is OperationCanceledException
                or ObjectDisposedException
                or SocketException
                or TimeoutException)
            {
            }
        }

        private static async Task ServeOnceAsync(
            TcpListener listener,
            string responseText)
        {
            using var client = await listener.AcceptTcpClientAsync();
            await using var stream = client.GetStream();
            var requestBuffer = new byte[16 * 1024];
            _ = await stream.ReadAsync(requestBuffer);

            var escaped = System.Text.Json.JsonSerializer.Serialize(
                responseText);
            var body =
                $"data: {{\"choices\":[{{\"delta\":{{\"content\":{escaped}}}}}],\"usage\":null}}\n\n"
                + "data: [DONE]\n\n";
            var bodyBytes = Encoding.UTF8.GetBytes(body);
            var header = Encoding.ASCII.GetBytes(
                "HTTP/1.1 200 OK\r\n"
                + "Content-Type: text/event-stream\r\n"
                + $"Content-Length: {bodyBytes.Length}\r\n"
                + "Connection: close\r\n\r\n");
            await stream.WriteAsync(header);
            await stream.WriteAsync(bodyBytes);
            await stream.FlushAsync();
        }
    }
}
