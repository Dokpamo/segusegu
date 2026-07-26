using System.Text.Json;

namespace Lorepia.Native.Tests;

public sealed class CoreClientV2Tests
{
    [Fact]
    public void MapsCompleteV2ContractAndUtf8Inputs()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());
        var stagedPath = Path.Combine(CreateDataRoot(), "캐릭터.charx");

        var inspection = client.InspectImport(stagedPath);
        Assert.Equal("inspection-1", inspection.Id);
        Assert.Equal("character_card_v3", inspection.Kind);
        Assert.True(inspection.IsAllowed);
        Assert.Equal((ulong)256, inspection.EstimatedStoredSize);
        Assert.NotNull(inspection.RepresentativeImage);
        Assert.Equal(
            "assets/avatar.png",
            inspection.RepresentativeImage.LogicalAssetId);
        Assert.Equal("image/png", inspection.RepresentativeImage.MediaType);
        Assert.Equal(70UL, inspection.RepresentativeImage.SizeBytes);
        Assert.Equal(
            new[] { "alternate_greetings", "creator" },
            inspection.UnsupportedOptionalFields);
        Assert.Equal(Path.GetFullPath(stagedPath), api.LastStagedPath);

        var committed = client.CommitImport(inspection.Id);
        Assert.Equal("character-1", committed.Id);
        client.DiscardImport("inspection-to-discard");
        Assert.Equal("inspection-to-discard", api.LastInspectionId);
        Assert.Equal(1, api.DiscardCount);
        Assert.Equal("character-1", client.GetCharacter("character-1").Id);

        var opened = client.OpenConversation("character-1");
        Assert.Equal("conversation-1", opened.Id);
        Assert.Single(client.ListConversations());
        var message = Assert.Single(client.ListMessages(opened.Id));
        Assert.Equal("안녕", message.Content);

        var generationId = client.SendMessage(
            opened.Id,
            "새 메시지",
            "provider-1",
            "비밀 토큰");
        Assert.Equal("generation-1", generationId);
        Assert.Equal("새 메시지", api.LastSentText);
        Assert.Equal("provider-1", api.LastProviderProfileId);
        Assert.Equal("비밀 토큰", api.LastCredential);

        var batch = client.PollEvents(32);
        var chatEvent = Assert.Single(batch.Events);
        Assert.Equal(ChatEventType.TextDelta, chatEvent.Type);
        Assert.Equal("반가워", chatEvent.Text);
        Assert.Equal(1UL, chatEvent.Sequence);
        Assert.Equal((uint)32, api.LastMaxEvents);

        client.CancelGeneration(generationId);
        Assert.Equal(1, api.CancelCount);

        var settings = client.GetSettings();
        Assert.True(settings.PreservePartialGenerations);
        Assert.Equal("provider-1", settings.SelectedProviderProfileId);
        client.UpdateSettings(new AppSettings
        {
            PreservePartialGenerations = false,
            SelectedProviderProfileId = null,
        });
        using (var document = JsonDocument.Parse(api.LastSettingsJson!))
        {
            Assert.False(document.RootElement
                .GetProperty("preserve_partial_generations")
                .GetBoolean());
            Assert.Equal(
                JsonValueKind.Null,
                document.RootElement
                    .GetProperty("selected_provider_profile_id")
                    .ValueKind);
        }

        var profile = Assert.Single(client.ListProviderProfiles());
        Assert.Equal("provider-1", profile.Id);
        var saved = client.UpsertProviderProfile(profile);
        Assert.Equal(profile, saved);
        using (var document = JsonDocument.Parse(api.LastProfileJson!))
        {
            Assert.Equal(
                "https://example.invalid/v1",
                document.RootElement.GetProperty("base_url").GetString());
            Assert.False(document.RootElement.TryGetProperty(
                "credential",
                out _));
        }

        client.DeleteProviderProfile(profile.Id);
        Assert.Equal(profile.Id, api.LastDeletedProfileId);
    }

    [Fact]
    public void SendMessage_RepresentsMissingCredentialAsAbsent()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        client.SendMessage(
            "conversation-1",
            "hello",
            "provider-1",
            string.Empty);

        Assert.Null(api.LastCredential);
    }

    [Fact]
    public void PreservesEmptyListsNullablesLargeUnicodeAndEventOrder()
    {
        var largeUnicode = string.Concat(
            Enumerable.Repeat("큰문자열😀", 8_192));
        var character = new CharacterSummary
        {
            Id = "character-unicode",
            Name = "세구 😀 e\u0301",
            Description = largeUnicode,
            SourceHash = "abc123",
            AvatarAssetHash = null,
            CreatedAt = DateTimeOffset.Parse("2026-07-26T00:00:00Z"),
        };
        var message = new ConversationMessage
        {
            Id = "message-unicode",
            ConversationId = "conversation-1",
            ParentId = null,
            Role = "assistant",
            Content = largeUnicode,
            Status = "cancelled",
            GenerationId = "generation-1",
            CreatedAt = DateTimeOffset.Parse("2026-07-26T00:00:00Z"),
        };
        var api = new FakeNativeApi
        {
            CharactersJson = "[]",
            ConversationsJson = "[]",
            ProviderProfilesJson = "[]",
            SettingsJson = JsonSerializer.Serialize(new AppSettings
            {
                PreservePartialGenerations = true,
                SelectedProviderProfileId = null,
            }),
            EventsJson =
                """
                {
                  "events": [
                    {
                      "event_version": 1,
                      "generation_id": "generation-1",
                      "conversation_id": "conversation-1",
                      "sequence": 41,
                      "emitted_at": "2026-07-26T00:00:00Z",
                      "kind": {"type":"text_delta","payload":"부분😀"}
                    },
                    {
                      "event_version": 1,
                      "generation_id": "generation-1",
                      "conversation_id": "conversation-1",
                      "sequence": 42,
                      "emitted_at": "2026-07-26T00:00:01Z",
                      "kind": {
                        "type":"usage_updated",
                        "payload":{"input_tokens":null,"output_tokens":2}
                      }
                    },
                    {
                      "event_version": 1,
                      "generation_id": "generation-1",
                      "conversation_id": "conversation-1",
                      "sequence": 43,
                      "emitted_at": "2026-07-26T00:00:02Z",
                      "kind": {"type":"generation_cancelled"}
                    }
                  ],
                  "dropped_events": 0
                }
                """,
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Empty(client.ListCharacters());
        Assert.Empty(client.ListConversations());
        Assert.Empty(client.ListProviderProfiles());
        Assert.Null(client.GetSettings().SelectedProviderProfileId);

        api.CharacterJson = JsonSerializer.Serialize(character);
        api.CharactersJson = JsonSerializer.Serialize(new[] { character });
        api.MessagesJson = JsonSerializer.Serialize(new[] { message });
        Assert.Equal(largeUnicode, client.GetCharacter(character.Id).Description);
        Assert.Null(client.GetCharacter(character.Id).AvatarAssetHash);
        Assert.Equal(
            largeUnicode,
            Assert.Single(client.ListCharacters()).Description);
        var mappedMessage = Assert.Single(
            client.ListMessages(message.ConversationId));
        Assert.Equal("assistant", mappedMessage.Role);
        Assert.Equal("cancelled", mappedMessage.Status);
        Assert.Null(mappedMessage.ParentId);
        Assert.Equal(largeUnicode, mappedMessage.Content);

        client.SendMessage(
            "conversation-1",
            largeUnicode,
            "provider-1",
            null);
        Assert.Equal(largeUnicode, api.LastSentText);
        Assert.Null(api.LastCredential);

        var events = client.PollEvents().Events;
        Assert.Equal(
            new[] { 41UL, 42UL, 43UL },
            events.Select(chatEvent => chatEvent.Sequence));
        Assert.Equal(ChatEventType.TextDelta, events[0].Type);
        Assert.Equal("부분😀", events[0].Text);
        Assert.Equal(ChatEventType.UsageUpdated, events[1].Type);
        Assert.Null(events[1].InputTokens);
        Assert.Equal(2UL, events[1].OutputTokens);
        Assert.Equal(ChatEventType.GenerationCancelled, events[2].Type);
    }

    [Fact]
    public void InputGuards_RunBeforeNativeCalls()
    {
        var api = new FakeNativeApi();
        using var client = CoreClient.Open(api, CreateDataRoot());

        Assert.Throws<ArgumentException>(() =>
            client.InspectImport("relative.charx"));
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            client.PollEvents(0));
        Assert.Throws<ArgumentOutOfRangeException>(() =>
            client.PollEvents(1025));
        Assert.Equal(0u, api.LastMaxEvents);
    }

    [Fact]
    public async Task Dispose_WaitsForAnInFlightCallBeforeDestroyingHandle()
    {
        var api = new FakeNativeApi();
        using var callEntered = new ManualResetEventSlim();
        using var releaseCall = new ManualResetEventSlim();
        api.BeforeGetCoreVersion = () =>
        {
            callEntered.Set();
            releaseCall.Wait(TimeSpan.FromSeconds(5));
        };
        var client = CoreClient.Open(api, CreateDataRoot());

        var call = Task.Run(client.GetCoreVersion);
        Assert.True(callEntered.Wait(TimeSpan.FromSeconds(5)));
        var dispose = Task.Run(client.Dispose);
        await Task.Delay(50);
        Assert.Equal(0, api.DestroyCount);

        releaseCall.Set();
        Assert.Equal("0.1.0-test", await call);
        await dispose;
        Assert.Equal(1, api.DestroyCount);
    }

    [Theory]
    [InlineData("generation_started", ChatEventType.GenerationStarted)]
    [InlineData("generation_cancelled", ChatEventType.GenerationCancelled)]
    [InlineData("generation_finished", ChatEventType.GenerationFinished)]
    public void MapsUnitChatEvents(
        string type,
        ChatEventType expected)
    {
        var api = new FakeNativeApi
        {
            EventsJson = EventBatch($$"""
                {"type":"{{type}}"}
                """),
        };
        using var client = CoreClient.Open(api, CreateDataRoot());

        var chatEvent = Assert.Single(client.PollEvents().Events);

        Assert.Equal(expected, chatEvent.Type);
    }

    [Fact]
    public void MapsStructuredChatEventPayloads()
    {
        var cases = new Dictionary<string, Action<ChatEvent>>
        {
            [
                """
                {"type":"reasoning_delta","payload":"thought"}
                """
            ] = chatEvent =>
            {
                Assert.Equal(ChatEventType.ReasoningDelta, chatEvent.Type);
                Assert.Equal("thought", chatEvent.Text);
            },
            [
                """
                {"type":"usage_updated","payload":{"input_tokens":12,"output_tokens":34}}
                """
            ] = chatEvent =>
            {
                Assert.Equal(ChatEventType.UsageUpdated, chatEvent.Type);
                Assert.Equal(12UL, chatEvent.InputTokens);
                Assert.Equal(34UL, chatEvent.OutputTokens);
            },
            [
                """
                {"type":"message_committed","payload":{"message_id":"m1","status":"complete"}}
                """
            ] = chatEvent =>
            {
                Assert.Equal(ChatEventType.MessageCommitted, chatEvent.Type);
                Assert.Equal("m1", chatEvent.MessageId);
                Assert.Equal("complete", chatEvent.MessageStatus);
            },
            [
                """
                {"type":"generation_failed","payload":{"code":"network_unavailable","message":"offline"}}
                """
            ] = chatEvent =>
            {
                Assert.Equal(ChatEventType.GenerationFailed, chatEvent.Type);
                Assert.Equal("network_unavailable", chatEvent.ErrorCode);
                Assert.Equal("offline", chatEvent.ErrorMessage);
            },
        };

        foreach (var (kind, assertEvent) in cases)
        {
            var api = new FakeNativeApi
            {
                EventsJson = EventBatch(kind),
            };
            using var client = CoreClient.Open(api, CreateDataRoot());
            assertEvent(Assert.Single(client.PollEvents().Events));
        }
    }

    [Fact]
    public void RejectsUnknownEventVersionAndType()
    {
        var wrongVersion = new FakeNativeApi
        {
            EventsJson = EventBatch(
                """{"type":"generation_started"}""",
                eventVersion: 2),
        };
        using (var client = CoreClient.Open(wrongVersion, CreateDataRoot()))
        {
            Assert.Throws<CoreInteropException>(() => client.PollEvents());
        }

        var wrongType = new FakeNativeApi
        {
            EventsJson = EventBatch("""{"type":"future_event"}"""),
        };
        using (var client = CoreClient.Open(wrongType, CreateDataRoot()))
        {
            Assert.Throws<CoreInteropException>(() => client.PollEvents());
        }
    }

    [Fact]
    public void StructuredException_PreservesStableErrorMetadata()
    {
        var payload = new NativeErrorPayload
        {
            Status = 11,
            Code = "network_unavailable",
            Message = "offline",
            Recoverable = true,
            OperationId = "operation-1",
        };

        var exception = new CoreInteropException(
            "lorepia_core_send_message_json",
            11,
            payload);

        Assert.Equal(11, exception.Status);
        Assert.Equal("network_unavailable", exception.Code);
        Assert.True(exception.Recoverable);
        Assert.Equal("operation-1", exception.OperationId);
        Assert.DoesNotContain("credential", exception.Message);
    }

    private static string EventBatch(
        string kind,
        uint eventVersion = 1) =>
        $$"""
        {
          "events": [
            {
              "event_version": {{eventVersion}},
              "generation_id": "generation-1",
              "conversation_id": "conversation-1",
              "sequence": 1,
              "emitted_at": "2026-07-26T00:00:00Z",
              "kind": {{kind}}
            }
          ],
          "dropped_events": 0
        }
        """;

    private static string CreateDataRoot() =>
        Path.Combine(
            Path.GetTempPath(),
            "lorepia-native-v2-tests",
            Guid.NewGuid().ToString("N"));
}
