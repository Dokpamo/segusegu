using Lorepia.Native.Interop;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;

namespace Lorepia.Native;

public sealed class CoreClient : IDisposable
{
    public const uint SupportedAbiVersion = 7;
    public const uint SupportedChatEventVersion = 4;
    public const uint SupportedProviderDiscoveryEventVersion = 2;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = false,
        UnmappedMemberHandling =
            System.Text.Json.Serialization.JsonUnmappedMemberHandling.Skip,
    };

    private readonly INativeApi nativeApi;
    private readonly SafeCoreHandle core;
    private readonly object callGate = new();
    private int disposed;

    private CoreClient(
        INativeApi nativeApi,
        SafeCoreHandle core,
        uint abiVersion)
    {
        this.nativeApi = nativeApi;
        this.core = core;
        AbiVersion = abiVersion;
    }

    public uint AbiVersion { get; }

    public static CoreClient Open(string dataRoot)
    {
        return Open(PInvokeNativeApi.Instance, dataRoot);
    }

    internal static CoreClient Open(
        INativeApi nativeApi,
        string dataRoot)
    {
        ArgumentNullException.ThrowIfNull(nativeApi);
        ArgumentException.ThrowIfNullOrWhiteSpace(dataRoot);

        if (!Path.IsPathFullyQualified(dataRoot))
        {
            throw new ArgumentException(
                "The LorePia data root must be an absolute path.",
                nameof(dataRoot));
        }

        var normalizedDataRoot = Path.GetFullPath(dataRoot);
        var configurationJson = JsonSerializer.SerializeToUtf8Bytes(
            new CoreConfiguration(normalizedDataRoot),
            JsonOptions);

        var abiVersion = nativeApi.GetAbiVersion();
        if (abiVersion != SupportedAbiVersion)
        {
            throw new CoreInteropException(
                $"Unsupported LorePia C ABI version {abiVersion}; expected {SupportedAbiVersion}.");
        }

        var core = nativeApi.CreateCore(configurationJson);
        if (core.IsInvalid)
        {
            core.Dispose();
            throw new CoreInteropException(
                "The native core could not create a core handle.");
        }

        return new CoreClient(nativeApi, core, abiVersion);
    }

    public string GetCoreVersion()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetCoreVersion(core);
            var version = buffer.ReadUtf8();
            if (string.IsNullOrWhiteSpace(version))
            {
                throw new CoreInteropException(
                    "The native core returned an empty version string.");
            }

            return version;
        });
    }

    public CoreHealth GetHealthCheck()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetHealthCheckJson(core);
            return CoreHealthMapper.Parse(buffer.ReadUtf8());
        });
    }

    public ImportInspection InspectImport(string stagedPath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(stagedPath);
        if (!Path.IsPathFullyQualified(stagedPath))
        {
            throw new ArgumentException(
                "The staged import path must be absolute.",
                nameof(stagedPath));
        }

        return Invoke(() =>
        {
            using var buffer = nativeApi.InspectImportJson(
                core,
                Utf8(Path.GetFullPath(stagedPath)));
            var inspection = Parse<ImportInspection>(
                buffer.ReadUtf8(),
                "import-inspection");
            Require(inspection.Id, "inspection id");
            Require(inspection.Kind, "inspection kind");
            Require(inspection.SourceSha256, "inspection source_sha256");
            if (inspection.RepresentativeImage is { } image)
            {
                Require(image.LogicalAssetId, "representative image logical_asset_id");
                Require(image.MediaType, "representative image media_type");
            }
            return inspection;
        });
    }

    public CharacterSummary CommitImport(string inspectionId)
    {
        RequireArgument(inspectionId, nameof(inspectionId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.CommitImportJson(
                core,
                Utf8(inspectionId));
            return ParseCharacter(buffer.ReadUtf8(), "committed character");
        });
    }

    public void DiscardImport(string inspectionId)
    {
        RequireArgument(inspectionId, nameof(inspectionId));
        Invoke(() => nativeApi.DiscardImport(core, Utf8(inspectionId)));
    }

    public IReadOnlyList<CharacterSummary> ListCharacters()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetCharactersJson(core);
            return CharacterSummaryMapper.Parse(buffer.ReadUtf8());
        });
    }

    public CharacterSummary GetCharacter(string characterId)
    {
        RequireArgument(characterId, nameof(characterId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetCharacterJson(
                core,
                Utf8(characterId));
            return ParseCharacter(buffer.ReadUtf8(), "character");
        });
    }

    public Conversation OpenConversation(string characterId)
    {
        RequireArgument(characterId, nameof(characterId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.OpenConversationJson(
                core,
                Utf8(characterId));
            return ParseConversation(buffer.ReadUtf8());
        });
    }

    public IReadOnlyList<Conversation> ListConversations()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetConversationsJson(core);
            var conversations = Parse<List<Conversation>>(
                buffer.ReadUtf8(),
                "conversation-list");
            foreach (var conversation in conversations)
            {
                ValidateConversation(conversation);
            }

            return conversations;
        });
    }

    public IReadOnlyList<ConversationMessage> ListMessages(
        string conversationId)
    {
        RequireArgument(conversationId, nameof(conversationId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetMessagesJson(
                core,
                Utf8(conversationId));
            var messages = Parse<List<ConversationMessage>>(
                buffer.ReadUtf8(),
                "message-list");
            foreach (var message in messages)
            {
                Require(message.Id, "message id");
                Require(message.ConversationId, "message conversation_id");
                Require(message.Role, "message role");
                Require(message.Status, "message status");
            }

            return messages;
        });
    }

    public string SendMessage(
        string conversationId,
        string text,
        string providerProfileId,
        string? credential)
    {
        RequireArgument(conversationId, nameof(conversationId));
        RequireArgument(text, nameof(text));
        RequireArgument(providerProfileId, nameof(providerProfileId));
        if (credential is not null && credential.Length == 0)
        {
            credential = null;
        }

        var credentialBytes = credential is null ? null : Utf8(credential);
        try
        {
            return Invoke(() =>
            {
                using var buffer = nativeApi.SendMessageJson(
                    core,
                    Utf8(conversationId),
                    Utf8(text),
                    Utf8(providerProfileId),
                    credentialBytes);
                var generationId = Parse<string>(
                    buffer.ReadUtf8(),
                    "generation id");
                Require(generationId, "generation id");
                return generationId;
            });
        }
        finally
        {
            if (credentialBytes is not null)
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(
                    credentialBytes);
            }
        }
    }

    public string SendMessageWithTarget(
        string conversationId,
        string text,
        GenerationTarget target,
        string credentialConnectionId,
        string? credential)
    {
        RequireArgument(conversationId, nameof(conversationId));
        RequireArgument(text, nameof(text));
        ArgumentNullException.ThrowIfNull(target);
        ValidateGenerationTarget(target);
        RequireArgument(
            credentialConnectionId,
            nameof(credentialConnectionId));
        if (credential is not null && credential.Length == 0)
        {
            credential = null;
        }

        var request = SerializeVersioned(new SendMessageWithTargetPayload(
            conversationId,
            text,
            target));
        var credentialBytes = credential is null ? null : Utf8(credential);
        try
        {
            return Invoke(() =>
            {
                ValidateGenerationTargetCredentialBinding(
                    credentialConnectionId,
                    target);
                using var buffer = nativeApi.SendMessageWithTargetJson(
                    core,
                    request,
                    credentialBytes);
                var generationId = Parse<string>(
                    buffer.ReadUtf8(),
                    "generation id");
                Require(generationId, "generation id");
                return generationId;
            });
        }
        finally
        {
            if (credentialBytes is not null)
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(
                    credentialBytes);
            }
        }
    }

    public void CancelGeneration(string generationId)
    {
        RequireArgument(generationId, nameof(generationId));
        Invoke(() => nativeApi.CancelGeneration(core, Utf8(generationId)));
    }

    public ChatEventBatch PollEvents(uint maxEvents = 128)
    {
        if (maxEvents is 0 or > 1024)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maxEvents),
                "Event batch size must be between 1 and 1024.");
        }

        return Invoke(() =>
        {
            using var buffer = nativeApi.PollEventsJson(core, maxEvents);
            var payload = Parse<ChatEventBatchPayload>(
                buffer.ReadUtf8(),
                "chat-event batch");
            return new ChatEventBatch(
                payload.Events.Select(MapEvent).ToArray(),
                payload.DroppedEvents);
        });
    }

    public AppSettings GetSettings()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetSettingsJson(core);
            var settings = Parse<AppSettings>(
                buffer.ReadUtf8(),
                "app settings");
            ValidateSelectedTarget(settings);
            return settings;
        });
    }

    public void UpdateSettings(AppSettings settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        ValidateSelectedTarget(settings);
        Invoke(() => nativeApi.UpdateSettingsJson(
            core,
            JsonSerializer.SerializeToUtf8Bytes(settings, JsonOptions)));
    }

    public IReadOnlyList<ProviderTemplate> ListProviderTemplates()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetProviderTemplatesJson(core);
            var templates = Parse<List<ProviderTemplate>>(
                buffer.ReadUtf8(),
                "provider-template list");
            foreach (var template in templates)
            {
                ValidateProviderTemplate(template);
            }

            return templates;
        });
    }

    public ProviderConnection CreateProviderConnection(
        ProviderConnectionDraft draft)
    {
        ArgumentNullException.ThrowIfNull(draft);
        ValidateProviderConnectionDraft(draft);
        return Invoke(() =>
        {
            using var buffer = nativeApi.CreateProviderConnectionJson(
                core,
                SerializeVersioned(draft));
            var connection = Parse<ProviderConnection>(
                buffer.ReadUtf8(),
                "provider connection");
            ValidateProviderConnection(connection);
            RequireExactBinding(
                connection.Id,
                draft.Id,
                "created provider connection");
            return connection;
        });
    }

    public IReadOnlyList<ProviderConnection> ListProviderConnections()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetProviderConnectionsJson(core);
            var connections = Parse<List<ProviderConnection>>(
                buffer.ReadUtf8(),
                "provider-connection list");
            foreach (var connection in connections)
            {
                ValidateProviderConnection(connection);
            }

            return connections;
        });
    }

    public ProviderConnection UpsertProviderConnection(
        ProviderConnection connection,
        bool credentialSlotReady)
    {
        ArgumentNullException.ThrowIfNull(connection);
        ValidateProviderConnection(connection);
        if (credentialSlotReady
            && !connection.CredentialSlotRequired)
        {
            throw new ArgumentException(
                "A credential-free provider connection cannot claim a ready credential slot.",
                nameof(credentialSlotReady));
        }
        var payload = ProviderConnectionWire.FromPublic(
            connection,
            credentialSlotReady);
        return Invoke(() =>
        {
            using var buffer = nativeApi.UpsertProviderConnectionJson(
                core,
                SerializeVersioned(payload));
            var saved = Parse<ProviderConnection>(
                buffer.ReadUtf8(),
                "provider connection");
            ValidateProviderConnection(saved);
            RequireExactBinding(
                saved.Id,
                connection.Id,
                "saved provider connection");
            return saved;
        });
    }

    public void DeleteProviderConnection(string connectionId)
    {
        RequireArgument(connectionId, nameof(connectionId));
        Invoke(() => nativeApi.DeleteProviderConnectionJson(
            core,
            SerializeVersioned(new DeleteProviderConnectionPayload(
                connectionId))));
    }

    public IReadOnlyList<ModelRoute> ListModelRoutes(string connectionId)
    {
        RequireArgument(connectionId, nameof(connectionId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetModelRoutesJson(
                core,
                Utf8(connectionId));
            var routes = Parse<List<ModelRoute>>(
                buffer.ReadUtf8(),
                "model-route list");
            foreach (var route in routes)
            {
                ValidateModelRoute(route);
                RequireExactBinding(
                    route.ConnectionId,
                    connectionId,
                    "model route connection");
            }

            return routes;
        });
    }

    public ModelRoute UpsertModelRoute(ModelRoute route)
    {
        ArgumentNullException.ThrowIfNull(route);
        ValidateModelRoute(route);
        return Invoke(() =>
        {
            using var buffer = nativeApi.UpsertModelRouteJson(
                core,
                SerializeVersioned(ModelRouteWire.FromPublic(route)));
            var saved = Parse<ModelRoute>(
                buffer.ReadUtf8(),
                "model route");
            ValidateModelRoute(saved);
            RequireExactBinding(
                saved.Id,
                route.Id,
                "saved model route");
            RequireExactBinding(
                saved.ConnectionId,
                route.ConnectionId,
                "saved model route connection");
            return saved;
        });
    }

    public void DeleteModelRoute(string modelRouteId)
    {
        RequireArgument(modelRouteId, nameof(modelRouteId));
        Invoke(() => nativeApi.DeleteModelRouteJson(
            core,
            SerializeVersioned(new DeleteModelRoutePayload(modelRouteId))));
    }

    public IReadOnlyList<CapabilityObservation> ListCapabilityObservations(
        string modelRouteId)
    {
        RequireArgument(modelRouteId, nameof(modelRouteId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetCapabilityObservationsJson(
                core,
                Utf8(modelRouteId));
            var observations = Parse<List<CapabilityObservation>>(
                buffer.ReadUtf8(),
                "capability-observation list");
            foreach (var observation in observations)
            {
                ValidateCapabilityObservation(observation);
                RequireExactBinding(
                    observation.ModelRouteId,
                    modelRouteId,
                    "capability observation model route");
            }

            return observations;
        });
    }

    public EffectiveCapability? GetEffectiveCapability(
        string modelRouteId,
        CapabilityKey key)
    {
        RequireArgument(modelRouteId, nameof(modelRouteId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetEffectiveCapabilityJson(
                core,
                SerializeVersioned(new EffectiveCapabilityPayload(
                    modelRouteId,
                    key)));
            var effective = ParseOptional<EffectiveCapability>(
                buffer.ReadUtf8(),
                "effective capability");
            if (effective is not null)
            {
                ValidateCapabilityObservation(effective.Selected);
                ValidateCapabilityTarget(
                    effective.Selected,
                    modelRouteId,
                    key);
                foreach (var alternative in effective.Alternatives)
                {
                    ValidateCapabilityObservation(alternative);
                    ValidateCapabilityTarget(
                        alternative,
                        modelRouteId,
                        key);
                }
                if (effective.EvaluatedAt == default)
                {
                    throw new CoreInteropException(
                        "An effective capability is missing evaluated_at.");
                }
            }

            return effective;
        });
    }

    public IReadOnlyList<ProviderParameterSpec> GetEffectiveParameterSpecs(
        string modelRouteId)
    {
        RequireArgument(modelRouteId, nameof(modelRouteId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetEffectiveParameterSpecsJson(
                core,
                Utf8(modelRouteId));
            var parameters = Parse<List<ProviderParameterSpec>>(
                buffer.ReadUtf8(),
                "effective parameter-spec list");
            var parameterIds = new HashSet<string>(StringComparer.Ordinal);
            foreach (var parameter in parameters)
            {
                ValidateProviderParameterSpec(parameter);
                if (!parameterIds.Add(parameter.Id))
                {
                    throw new CoreInteropException(
                        $"The effective parameter contract contains duplicate parameter '{parameter.Id}'.");
                }
            }

            return parameters;
        });
    }

    public CapabilityObservation UpsertUserCapabilityOverride(
        CapabilityObservation observation)
    {
        ArgumentNullException.ThrowIfNull(observation);
        ValidateUserCapabilityOverride(observation);
        return Invoke(() =>
        {
            using var buffer = nativeApi.UpsertUserCapabilityOverrideJson(
                core,
                SerializeVersioned(observation));
            var saved = Parse<CapabilityObservation>(
                buffer.ReadUtf8(),
                "capability observation");
            ValidateCapabilityObservation(saved);
            RequireExactBinding(
                saved.Id,
                observation.Id,
                "saved capability observation");
            RequireExactBinding(
                saved.ModelRouteId,
                observation.ModelRouteId,
                "saved capability observation model route");
            if (saved.Key != observation.Key)
            {
                throw new CoreInteropException(
                    "The saved capability observation changed its capability key.");
            }
            return saved;
        });
    }

    public void DeleteUserCapabilityOverride(
        string modelRouteId,
        string observationId)
    {
        RequireArgument(modelRouteId, nameof(modelRouteId));
        RequireArgument(observationId, nameof(observationId));
        Invoke(() => nativeApi.DeleteUserCapabilityOverrideJson(
            core,
            SerializeVersioned(new DeleteCapabilityOverridePayload(
                modelRouteId,
                observationId))));
    }

    public ProviderModelRefreshResult RefreshProviderModels(
        string connectionId,
        string? credential)
    {
        RequireArgument(connectionId, nameof(connectionId));
        if (credential is not null && credential.Length == 0)
        {
            credential = null;
        }

        var request = SerializeVersioned(
            new RefreshProviderModelsPayload(connectionId));
        var credentialBytes = credential is null ? null : Utf8(credential);
        try
        {
            return Invoke(() =>
            {
                using var buffer = nativeApi.RefreshProviderModelsJson(
                    core,
                    request,
                    credentialBytes);
                var result = Parse<ProviderModelRefreshResult>(
                    buffer.ReadUtf8(),
                    "provider-model refresh result");
                Require(result.ConnectionId, "refresh connection_id");
                RequireExactBinding(
                    result.ConnectionId,
                    connectionId,
                    "provider-model refresh connection");
                foreach (var route in result.ModelRoutes)
                {
                    ValidateModelRoute(route);
                    RequireExactBinding(
                        route.ConnectionId,
                        connectionId,
                        "provider-model refresh route connection");
                }

                return result;
            });
        }
        finally
        {
            if (credentialBytes is not null)
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(
                    credentialBytes);
            }
        }
    }

    public ModelSyncStarted StartProviderModelSync(
        string connectionId,
        string? credential)
    {
        RequireArgument(connectionId, nameof(connectionId));
        if (credential is not null && credential.Length == 0)
        {
            credential = null;
        }

        var request = SerializeVersioned(
            new StartProviderModelSyncPayload(connectionId));
        var credentialBytes = credential is null ? null : Utf8(credential);
        try
        {
            return Invoke(() =>
            {
                using var buffer = nativeApi.StartProviderModelSyncJson(
                    core,
                    request,
                    credentialBytes);
                var started = Parse<ModelSyncStarted>(
                    buffer.ReadUtf8(),
                    "model-sync start result");
                Require(started.JobId, "model-sync job_id");
                return started;
            });
        }
        finally
        {
            if (credentialBytes is not null)
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(
                    credentialBytes);
            }
        }
    }

    public ModelSyncJob GetProviderModelSync(
        string jobId,
        string? expectedConnectionId = null)
    {
        RequireArgument(jobId, nameof(jobId));
        if (expectedConnectionId is not null)
        {
            RequireArgument(
                expectedConnectionId,
                nameof(expectedConnectionId));
        }
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetProviderModelSyncJson(
                core,
                SerializeVersioned(new ProviderModelSyncJobPayload(jobId)));
            var job = Parse<ModelSyncJob>(
                buffer.ReadUtf8(),
                "model-sync job");
            ValidateModelSyncJob(
                job,
                expectedJobId: jobId,
                expectedConnectionId: expectedConnectionId);
            return job;
        });
    }

    public IReadOnlyList<ModelSyncJob> ListProviderModelSyncs(
        string connectionId,
        uint limit = 32)
    {
        RequireArgument(connectionId, nameof(connectionId));
        if (limit is 0 or > 256)
        {
            throw new ArgumentOutOfRangeException(
                nameof(limit),
                "Model-sync job limit must be between 1 and 256.");
        }
        return Invoke(() =>
        {
            using var buffer = nativeApi.ListProviderModelSyncsJson(
                core,
                SerializeVersioned(new ListProviderModelSyncsPayload(
                    connectionId,
                    limit)));
            var jobs = Parse<List<ModelSyncJob>>(
                buffer.ReadUtf8(),
                "model-sync job list");
            foreach (var job in jobs)
            {
                ValidateModelSyncJob(
                    job,
                    expectedJobId: null,
                    expectedConnectionId: connectionId);
            }
            return jobs;
        });
    }

    public ModelSyncJob ApproveProviderModelSync(
        string jobId,
        string reviewSha256,
        string? expectedConnectionId = null)
    {
        RequireArgument(jobId, nameof(jobId));
        RequireArgument(reviewSha256, nameof(reviewSha256));
        if (expectedConnectionId is not null)
        {
            RequireArgument(
                expectedConnectionId,
                nameof(expectedConnectionId));
        }
        ValidateSha256(reviewSha256, nameof(reviewSha256));
        return Invoke(() =>
        {
            using var buffer = nativeApi.ApproveProviderModelSyncJson(
                core,
                SerializeVersioned(new ApproveProviderModelSyncPayload(
                    jobId,
                    reviewSha256)));
            var job = Parse<ModelSyncJob>(
                buffer.ReadUtf8(),
                "approved model-sync job");
            ValidateModelSyncJob(
                job,
                expectedJobId: jobId,
                expectedConnectionId: expectedConnectionId);
            return job;
        });
    }

    public ModelSyncJob CancelProviderModelSync(
        string jobId,
        string? expectedConnectionId = null)
    {
        RequireArgument(jobId, nameof(jobId));
        if (expectedConnectionId is not null)
        {
            RequireArgument(
                expectedConnectionId,
                nameof(expectedConnectionId));
        }
        return Invoke(() =>
        {
            using var buffer = nativeApi.CancelProviderModelSyncJson(
                core,
                SerializeVersioned(new ProviderModelSyncJobPayload(jobId)));
            var job = Parse<ModelSyncJob>(
                buffer.ReadUtf8(),
                "cancelled model-sync job");
            ValidateModelSyncJob(
                job,
                expectedJobId: jobId,
                expectedConnectionId: expectedConnectionId);
            return job;
        });
    }

    public IReadOnlyList<ModelSyncEvent> PollProviderModelSyncEvents(
        string jobId,
        uint maxEvents = 128)
    {
        RequireArgument(jobId, nameof(jobId));
        if (maxEvents is 0 or > 512)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maxEvents),
                "Model-sync event batch size must be between 1 and 512.");
        }
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.PollProviderModelSyncJobEventsJson(
                    core,
                    SerializeVersioned(
                        new PollProviderModelSyncEventsPayload(
                            jobId,
                            maxEvents)));
            var events = Parse<List<ModelSyncEvent>>(
                buffer.ReadUtf8(),
                "model-sync event list");
            foreach (var modelSyncEvent in events)
            {
                ValidateModelSyncEvent(modelSyncEvent);
                if (!string.Equals(
                        modelSyncEvent.JobId,
                        jobId,
                        StringComparison.Ordinal))
                {
                    throw new CoreInteropException(
                        "A model-sync event does not match the requested job.");
                }
            }
            return events;
        });
    }

    public bool AckProviderModelSyncEvent(
        string jobId,
        ulong sequence)
    {
        RequireArgument(jobId, nameof(jobId));
        if (sequence == 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(sequence));
        }
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.AckProviderModelSyncEventJson(
                    core,
                    SerializeVersioned(
                        new AckProviderModelSyncEventPayload(
                            jobId,
                            sequence)));
            return Parse<bool>(
                buffer.ReadUtf8(),
                "model-sync event acknowledgement");
        });
    }

    public ProviderCurlInspection InspectProviderCurl(
        string rawCurl,
        ProviderDiscoveryConnectionOptions connectionOptions,
        Action<string> consumeCredential)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(rawCurl);
        ArgumentNullException.ThrowIfNull(connectionOptions);
        ArgumentNullException.ThrowIfNull(consumeCredential);
        ValidateProviderDiscoveryConnectionOptions(connectionOptions);
        var rawCurlBytes = Utf8(rawCurl);
        try
        {
            return Invoke(() =>
            {
                var buffers = nativeApi.InspectProviderCurlJson(
                    core,
                    SerializeVersioned(
                        new InspectProviderCurlPayload(
                            connectionOptions)),
                    rawCurlBytes);
                using var metadataBuffer = buffers.Metadata;
                using var credentialBuffer = buffers.Credential;
                var inspection = Parse<ProviderCurlInspection>(
                    metadataBuffer.ReadUtf8(),
                    "provider cURL inspection");
                ValidateProviderCurlInspection(inspection);
                var credential =
                    credentialBuffer.ReadSecretUtf8();
                if (inspection.CredentialPresent !=
                    (credential.Length > 0))
                {
                    throw new CoreInteropException(
                        "The provider cURL inspection credential buffer did not match its secret-free metadata.");
                }
                if (credential.Length > 0)
                {
                    consumeCredential(credential);
                }
                return inspection;
            });
        }
        finally
        {
            CryptographicOperations.ZeroMemory(rawCurlBytes);
        }
    }

    public ProviderDiscoverySnapshot BeginProviderDiscovery(
        ProviderDiscoveryInput input,
        ProviderDiscoverySource source,
        string? rawCurl = null)
    {
        ArgumentNullException.ThrowIfNull(input);
        ArgumentNullException.ThrowIfNull(source);
        ValidateProviderDiscoveryInput(input);
        ValidateProviderDiscoverySource(source, rawCurl);
        var rawCurlBytes = rawCurl is null ? null : Utf8(rawCurl);
        try
        {
            return Invoke(() =>
            {
                using var buffer =
                    nativeApi.BeginProviderDiscoveryJson(
                        core,
                        SerializeVersioned(
                            new BeginProviderDiscoveryPayload(
                                input,
                                source)),
                        rawCurlBytes);
                return ParseAndValidateDiscoverySnapshot(
                    buffer.ReadUtf8(),
                    expectedPendingConnectionId:
                        input.ConnectionId);
            });
        }
        finally
        {
            if (rawCurlBytes is not null)
            {
                CryptographicOperations.ZeroMemory(
                    rawCurlBytes);
            }
        }
    }

    public ProviderDiscoveryActionEnvelope
        PrepareProviderDiscoveryAction(
            string actionId,
            ulong expectedRevision,
            ProviderDiscoveryAction action)
    {
        RequireArgument(actionId, nameof(actionId));
        ArgumentNullException.ThrowIfNull(action);
        Require(action.Kind, "provider-discovery action kind");
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.PrepareProviderDiscoveryActionJson(
                    core,
                    SerializeVersioned(
                        new PrepareProviderDiscoveryActionPayload(
                            actionId,
                            expectedRevision,
                            action)));
            var envelope =
                Parse<ProviderDiscoveryActionEnvelope>(
                    buffer.ReadUtf8(),
                    "provider-discovery action envelope");
            Require(
                envelope.ActionId,
                "provider-discovery action envelope action_id");
            ValidateSha256(
                envelope.RequestSha256,
                "provider-discovery action request_sha256");
            if (envelope.ExpectedRevision != expectedRevision
                || !string.Equals(
                    envelope.ActionId,
                    actionId,
                    StringComparison.Ordinal))
            {
                throw new CoreInteropException(
                    "The provider-discovery action envelope did not preserve its binding.");
            }
            return envelope;
        });
    }

    public ProviderDiscoverySnapshot ContinueProviderDiscovery(
        string sessionId,
        ProviderDiscoveryActionEnvelope envelope,
        string? credential = null,
        string? expectedPendingConnectionId = null)
    {
        RequireArgument(sessionId, nameof(sessionId));
        ArgumentNullException.ThrowIfNull(envelope);
        ValidateSha256(
            envelope.RequestSha256,
            "provider-discovery action request_sha256");
        var credentialBytes =
            credential is null ? null : Utf8(credential);
        try
        {
            return Invoke(() =>
            {
                using var buffer =
                    nativeApi.ContinueProviderDiscoveryJson(
                        core,
                        SerializeVersioned(
                            new ContinueProviderDiscoveryPayload(
                                sessionId,
                                envelope.ActionId,
                                envelope.ExpectedRevision,
                                envelope.RequestSha256,
                                envelope.Action)),
                        credentialBytes);
                return ParseAndValidateDiscoverySnapshot(
                    buffer.ReadUtf8(),
                    expectedSessionId: sessionId,
                    expectedPendingConnectionId:
                        expectedPendingConnectionId);
            });
        }
        finally
        {
            if (credentialBytes is not null)
            {
                CryptographicOperations.ZeroMemory(
                    credentialBytes);
            }
        }
    }

    public ProviderDiscoverySnapshot GetProviderDiscovery(
        string sessionId,
        string? expectedPendingConnectionId = null)
    {
        RequireArgument(sessionId, nameof(sessionId));
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.GetProviderDiscoveryJson(
                    core,
                    SerializeVersioned(
                        new ProviderDiscoverySessionPayload(
                            sessionId)));
            return ParseAndValidateDiscoverySnapshot(
                buffer.ReadUtf8(),
                expectedSessionId: sessionId,
                expectedPendingConnectionId:
                    expectedPendingConnectionId);
        });
    }

    public IReadOnlyList<ProviderDiscoverySnapshot>
        ListProviderDiscoveries(uint limit = 32)
    {
        if (limit is 0 or > 100)
        {
            throw new ArgumentOutOfRangeException(
                nameof(limit));
        }
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.ListProviderDiscoveriesJson(
                    core,
                    SerializeVersioned(
                        new ListProviderDiscoveriesPayload(
                            limit)));
            var snapshots =
                Parse<List<ProviderDiscoverySnapshot>>(
                    buffer.ReadUtf8(),
                    "provider-discovery list");
            foreach (var snapshot in snapshots)
            {
                ValidateProviderDiscoverySnapshot(snapshot);
            }
            return snapshots;
        });
    }

    public ProviderDiscoverySnapshot SupplyProviderDiscoveryDocument(
        string sessionId,
        ulong expectedRevision,
        string documentUrl,
        string? expectedPendingConnectionId = null)
    {
        RequireArgument(sessionId, nameof(sessionId));
        RequireArgument(documentUrl, nameof(documentUrl));
        return SupplyProviderDiscoveryEvidence(
            new SupplyProviderDiscoveryEvidencePayload(
                sessionId,
                expectedRevision,
                new ProviderDiscoveryEvidenceSource(
                    "document_url",
                    documentUrl)),
            rawCurl: null,
            expectedPendingConnectionId:
                expectedPendingConnectionId);
    }

    public ProviderDiscoverySnapshot SupplyProviderDiscoveryCurl(
        string sessionId,
        ulong expectedRevision,
        string rawCurl,
        string? expectedPendingConnectionId = null)
    {
        RequireArgument(sessionId, nameof(sessionId));
        ArgumentException.ThrowIfNullOrWhiteSpace(rawCurl);
        return SupplyProviderDiscoveryEvidence(
            new SupplyProviderDiscoveryEvidencePayload(
                sessionId,
                expectedRevision,
                new ProviderDiscoveryEvidenceSource(
                    "curl",
                    null)),
            rawCurl,
            expectedPendingConnectionId);
    }

    public ProviderDiscoverySnapshot CancelProviderDiscovery(
        string sessionId,
        ulong expectedRevision,
        string? expectedPendingConnectionId = null)
    {
        RequireArgument(sessionId, nameof(sessionId));
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.CancelProviderDiscoveryJson(
                    core,
                    SerializeVersioned(
                        new CancelProviderDiscoveryPayload(
                            sessionId,
                            expectedRevision)));
            return ParseAndValidateDiscoverySnapshot(
                buffer.ReadUtf8(),
                expectedSessionId: sessionId,
                expectedPendingConnectionId:
                    expectedPendingConnectionId);
        });
    }

    public ProviderConnection CommitProviderDiscovery(
        string sessionId,
        string expectedConnectionId,
        bool credentialReferenceConfirmed)
    {
        RequireArgument(sessionId, nameof(sessionId));
        RequireArgument(
            expectedConnectionId,
            nameof(expectedConnectionId));
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.CommitProviderDiscoveryJson(
                    core,
                    SerializeVersioned(
                        new CommitProviderDiscoveryPayload(
                            sessionId,
                            credentialReferenceConfirmed)));
            var connection = Parse<ProviderConnection>(
                buffer.ReadUtf8(),
                "committed provider connection");
            ValidateProviderConnection(connection);
            RequireExactBinding(
                connection.Id,
                expectedConnectionId,
                "committed provider connection");
            return connection;
        });
    }

    public IReadOnlyList<ProviderDiscoveryRecoveryResult>
        RecoverProviderDiscoveries()
    {
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.RecoverProviderDiscoveriesJson(core);
            var recoveries =
                Parse<List<ProviderDiscoveryRecoveryResult>>(
                buffer.ReadUtf8(),
                "provider-discovery recovery results");
            foreach (var recovery in recoveries)
            {
                Require(
                    recovery.OperationId,
                    "provider-discovery recovery operation_id");
                Require(
                    recovery.SessionId,
                    "provider-discovery recovery session_id");
                ValidateProviderDiscoveryState(
                    recovery.State);
                ValidateProviderDiscoveryEvent(
                    recovery.Event);
                if (!string.Equals(
                        recovery.SessionId,
                        recovery.Event.SessionId,
                        StringComparison.Ordinal)
                    || !string.Equals(
                        recovery.State,
                        recovery.Event.State,
                        StringComparison.Ordinal))
                {
                    throw new CoreInteropException(
                        "A provider-discovery recovery result is not bound to its event.");
                }
            }
            return recoveries;
        });
    }

    public IReadOnlyList<ProviderDiscoveryOutboxEvent>
        PollProviderDiscoveryEvents(uint maxEvents = 128)
    {
        if (maxEvents is 0 or > 1000)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maxEvents));
        }
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.PollProviderDiscoveryEventsJson(
                    core,
                    maxEvents);
            var events = Parse<List<ProviderDiscoveryOutboxEvent>>(
                buffer.ReadUtf8(),
                "provider-discovery event list");
            foreach (var item in events)
            {
                ValidateProviderDiscoveryEvent(item.Event);
                if (item.AvailableAt == default
                    || item.CreatedAt == default)
                {
                    throw new CoreInteropException(
                        "A provider-discovery outbox event is missing its durable timestamps.");
                }
            }
            return events;
        });
    }

    public bool AckProviderDiscoveryEvent(string eventId)
    {
        RequireArgument(eventId, nameof(eventId));
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.AckProviderDiscoveryEventJson(
                    core,
                    SerializeVersioned(
                        new AckProviderDiscoveryEventPayload(
                            eventId)));
            return Parse<bool>(
                buffer.ReadUtf8(),
                "provider-discovery event acknowledgement");
        });
    }

    public IReadOnlyList<ProviderDiscoveryCompensationStep>
        ListProviderDiscoveryCompensationSteps(
            string commitAttemptId)
    {
        RequireArgument(commitAttemptId, nameof(commitAttemptId));
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.ListProviderDiscoveryCompensationStepsJson(
                    core,
                    SerializeVersioned(
                        new ListProviderDiscoveryCompensationPayload(
                            commitAttemptId)));
            var steps = Parse<List<ProviderDiscoveryCompensationStep>>(
                buffer.ReadUtf8(),
                "provider-discovery compensation steps");
            foreach (var step in steps)
            {
                ValidateProviderDiscoveryCompensationStep(step);
                RequireExactBinding(
                    step.CommitAttemptId,
                    commitAttemptId,
                    "provider-discovery compensation attempt");
            }
            return steps;
        });
    }

    public ProviderDiscoveryCompensationStep
        StartProviderDiscoveryCredentialCompensation(
            string sessionId,
            string stepId,
            string commitAttemptId) =>
        RunDiscoveryCompensationStep<ProviderDiscoveryCompensationStep>(
            nativeApi.StartProviderDiscoveryCredentialCompensationJson,
            "started provider-discovery compensation step",
            sessionId,
            stepId,
            expectedPendingConnectionId: null,
            expectedCommitAttemptId:
                commitAttemptId);

    public ProviderDiscoverySnapshot
        CompleteProviderDiscoveryCredentialCompensation(
            string sessionId,
            string stepId,
            string pendingConnectionId,
            string commitAttemptId) =>
        RunDiscoveryCompensationStep<ProviderDiscoverySnapshot>(
            nativeApi.CompleteProviderDiscoveryCredentialCompensationJson,
            "completed provider-discovery compensation",
            sessionId,
            stepId,
            pendingConnectionId,
            commitAttemptId);

    public ProviderDiscoverySnapshot
        MarkProviderDiscoveryCredentialCompensationUnknown(
            string sessionId,
            string stepId,
            string pendingConnectionId,
            string commitAttemptId) =>
        RunDiscoveryCompensationStep<ProviderDiscoverySnapshot>(
            nativeApi.MarkProviderDiscoveryCredentialCompensationUnknownJson,
            "unknown provider-discovery compensation",
            sessionId,
            stepId,
            pendingConnectionId,
            commitAttemptId);

    public ProviderDiscoverySnapshot
        FailProviderDiscoveryCredentialCompensation(
            string sessionId,
            string stepId,
            string pendingConnectionId,
            string commitAttemptId,
            ProviderDiscoveryFailure failure)
    {
        RequireArgument(sessionId, nameof(sessionId));
        RequireArgument(stepId, nameof(stepId));
        RequireArgument(
            pendingConnectionId,
            nameof(pendingConnectionId));
        RequireArgument(
            commitAttemptId,
            nameof(commitAttemptId));
        ArgumentNullException.ThrowIfNull(failure);
        Require(failure.Code, "provider-discovery compensation failure code");
        Require(
            failure.MessageKey,
            "provider-discovery compensation failure message_key");
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.FailProviderDiscoveryCredentialCompensationJson(
                    core,
                    SerializeVersioned(
                        new FailProviderDiscoveryCompensationStepPayload(
                            sessionId,
                            stepId,
                            failure.Code,
                            failure.MessageKey,
                            failure.Recoverable)));
            return ParseAndValidateDiscoverySnapshot(
                buffer.ReadUtf8(),
                expectedSessionId: sessionId,
                expectedPendingConnectionId:
                    pendingConnectionId,
                expectedCommitAttemptId:
                    commitAttemptId);
        });
    }

    public ProviderDiscoveryAssistantHostAction
        RunProviderDiscoveryAssistantTurn(
            string sessionId,
            ProviderDiscoveryAssistantCallEstimate estimate,
            string assistantModelRouteId,
            string assistantConnectionId,
            string? assistantCredential)
    {
        RequireArgument(sessionId, nameof(sessionId));
        ArgumentNullException.ThrowIfNull(estimate);
        RequireArgument(
            assistantModelRouteId,
            nameof(assistantModelRouteId));
        RequireArgument(
            assistantConnectionId,
            nameof(assistantConnectionId));
        if (estimate.InputTokens == 0
            || estimate.MaximumOutputTokens == 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(estimate),
                "The setup-assistant input and maximum output token estimates must be positive.");
        }
        var credentialBytes = assistantCredential is null
            ? null
            : Utf8(assistantCredential);
        try
        {
            return Invoke(() =>
            {
                ValidateModelRouteCredentialBinding(
                    assistantConnectionId,
                    assistantModelRouteId);
                using var buffer =
                    nativeApi.RunProviderDiscoveryAssistantTurnJson(
                        core,
                        SerializeVersioned(
                            new RunProviderDiscoveryAssistantTurnPayload(
                                sessionId,
                                estimate)),
                        credentialBytes);
                var action =
                    Parse<ProviderDiscoveryAssistantHostAction>(
                        buffer.ReadUtf8(),
                        "provider-discovery assistant host action");
                ValidateProviderDiscoveryAssistantHostAction(
                    action,
                    sessionId);
                return action;
            });
        }
        finally
        {
            if (credentialBytes is not null)
            {
                CryptographicOperations.ZeroMemory(
                    credentialBytes);
            }
        }
    }

    public ProviderDiscoverySnapshot
        ResumeProviderDiscoveryAssistantCoreHostAction(
            string sessionId) =>
        RunProviderDiscoveryAssistantSnapshotCall(
            nativeApi.ResumeProviderDiscoveryAssistantCoreHostActionJson,
            "resumed provider-discovery assistant Core host action",
            sessionId);

    public ProviderDiscoverySnapshot
        ApproveProviderDiscoveryAssistantRetry(
            string sessionId) =>
        RunProviderDiscoveryAssistantSnapshotCall(
            nativeApi.ApproveProviderDiscoveryAssistantRetryJson,
            "approved provider-discovery assistant retry",
            sessionId);

    public ProviderDiscoverySnapshot
        RequestProviderDiscoveryAssistantRevision(
            string sessionId) =>
        RunProviderDiscoveryAssistantSnapshotCall(
            nativeApi.RequestProviderDiscoveryAssistantRevisionJson,
            "provider-discovery assistant revision request",
            sessionId);

    public ProviderDiscoverySnapshot
        AcceptProviderDiscoveryAssistantDraft(
            string sessionId) =>
        RunProviderDiscoveryAssistantSnapshotCall(
            nativeApi.AcceptProviderDiscoveryAssistantDraftJson,
            "accepted provider-discovery assistant draft",
            sessionId);

    public ProviderDiscoverySnapshot
        RecordProviderDiscoveryAssistantFailure(
            string sessionId,
            string kind,
            bool retryable)
    {
        RequireArgument(sessionId, nameof(sessionId));
        var normalizedKind = kind.Trim();
        _ = normalizedKind switch
        {
            "transport" or
            "timeout" or
            "rate_limited" or
            "invalid_structured_output" or
            "draft_revision_required" or
            "provider_rejected" or
            "internal" => true,
            _ => throw new ArgumentException(
                "The provider-discovery assistant failure kind is unsupported.",
                nameof(kind)),
        };
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.RecordProviderDiscoveryAssistantFailureJson(
                    core,
                    SerializeVersioned(
                        new RecordProviderDiscoveryAssistantFailurePayload(
                            sessionId,
                            normalizedKind,
                            retryable)));
            return ParseAndValidateDiscoverySnapshot(
                buffer.ReadUtf8(),
                expectedSessionId: sessionId);
        });
    }

    public ProviderCatalogStatus GetProviderCatalogStatus()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetProviderCatalogStatusJson(core);
            var status = Parse<ProviderCatalogStatus>(
                buffer.ReadUtf8(),
                "provider-catalog status");
            ValidateProviderCatalogStatus(status);
            return status;
        });
    }

    public ProviderCatalogHistory GetProviderCatalogHistory(
        uint limit = 50,
        ulong? beforeRevision = null,
        ulong? beforeStateVersion = null)
    {
        if (limit is 0 or > 100)
        {
            throw new ArgumentOutOfRangeException(
                nameof(limit),
                "Provider-catalog history page size must be between 1 and 100.");
        }
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetProviderCatalogHistoryJson(
                core,
                SerializeVersioned(new ProviderCatalogHistoryPayload(
                    limit,
                    beforeRevision,
                    beforeStateVersion)));
            var history = Parse<ProviderCatalogHistory>(
                buffer.ReadUtf8(),
                "provider-catalog history");
            ValidateProviderCatalogHistory(history);
            return history;
        });
    }

    public ProviderCatalogImportPlan PrepareSignedProviderCatalogImport(
        byte[] envelopeJson)
    {
        ValidateSignedCatalogEnvelope(
            envelopeJson,
            nameof(envelopeJson));
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.PrepareSignedProviderCatalogImportJson(
                    core,
                    envelopeJson);
            var plan = Parse<ProviderCatalogImportPlan>(
                buffer.ReadUtf8(),
                "provider-catalog import plan");
            ValidateProviderCatalogImportPlan(plan, envelopeJson);
            return plan;
        });
    }

    public ProviderCatalogImportResult ActivateSignedProviderCatalogImport(
        ProviderCatalogImportPlan plan,
        byte[] envelopeJson)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ValidateSignedCatalogEnvelope(
            envelopeJson,
            nameof(envelopeJson));
        ValidateProviderCatalogImportPlan(plan, envelopeJson);
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.ActivateSignedProviderCatalogImportJson(
                    core,
                    SerializeVersioned(
                        new ActivateSignedProviderCatalogImportPayload(
                            plan.PlanJson)),
                    envelopeJson);
            var result = Parse<ProviderCatalogImportResult>(
                buffer.ReadUtf8(),
                "provider-catalog import result");
            if (result.SignedCatalogRevision == 0
                || result.ActivatedRevision == 0)
            {
                throw new CoreInteropException(
                    "A provider-catalog import result contains an invalid revision.");
            }
            ValidateProviderCatalogDiff(result.Diff);
            ValidateProviderCatalogStatus(result.Status);
            return result;
        });
    }

    public ProviderCatalogDiff DiffProviderCatalogRevisions(
        ulong fromRevision,
        ulong toRevision)
    {
        if (fromRevision == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(fromRevision));
        }
        if (toRevision == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(toRevision));
        }
        return Invoke(() =>
        {
            using var buffer = nativeApi.DiffProviderCatalogRevisionsJson(
                core,
                SerializeVersioned(new ProviderCatalogDiffPayload(
                    fromRevision,
                    toRevision)));
            var diff = Parse<ProviderCatalogDiff>(
                buffer.ReadUtf8(),
                "provider-catalog diff");
            ValidateProviderCatalogDiff(diff);
            return diff;
        });
    }

    public ProviderCatalogRollbackPlan PrepareProviderCatalogRollback(
        ulong targetRevision)
    {
        if (targetRevision == 0)
        {
            throw new ArgumentOutOfRangeException(nameof(targetRevision));
        }
        return Invoke(() =>
        {
            using var buffer = nativeApi.PrepareProviderCatalogRollbackJson(
                core,
                SerializeVersioned(new PrepareProviderCatalogRollbackPayload(
                    targetRevision)));
            var plan = Parse<ProviderCatalogRollbackPlan>(
                buffer.ReadUtf8(),
                "provider-catalog rollback plan");
            ValidateProviderCatalogRollbackPlan(plan);
            return plan;
        });
    }

    public ProviderCatalogRollbackResult ActivateProviderCatalogRollback(
        ProviderCatalogRollbackPlan plan)
    {
        ArgumentNullException.ThrowIfNull(plan);
        ValidateProviderCatalogRollbackPlan(plan);
        return Invoke(() =>
        {
            using var buffer = nativeApi.ActivateProviderCatalogRollbackJson(
                core,
                SerializeVersioned(
                    new ActivateProviderCatalogRollbackPayload(
                        plan.PlanJson)));
            var result = Parse<ProviderCatalogRollbackResult>(
                buffer.ReadUtf8(),
                "provider-catalog rollback result");
            if (result.FromRevision == 0
                || result.ActivatedRevision == 0)
            {
                throw new CoreInteropException(
                    "A provider-catalog rollback result contains an invalid revision.");
            }
            ValidateProviderCatalogStatus(result.Status);
            return result;
        });
    }

    public IReadOnlyList<GenerationPreset> ListGenerationPresets(
        string modelRouteId)
    {
        RequireArgument(modelRouteId, nameof(modelRouteId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetGenerationPresetsJson(
                core,
                Utf8(modelRouteId));
            var presets = Parse<List<GenerationPreset>>(
                buffer.ReadUtf8(),
                "generation-preset list");
            foreach (var preset in presets)
            {
                ValidateGenerationPreset(preset);
                RequireExactBinding(
                    preset.ModelRouteId,
                    modelRouteId,
                    "generation preset model route");
            }

            return presets;
        });
    }

    public GenerationPreset UpsertGenerationPreset(
        GenerationPreset preset)
    {
        ArgumentNullException.ThrowIfNull(preset);
        ValidateGenerationPreset(preset);
        return Invoke(() =>
        {
            using var buffer = nativeApi.UpsertGenerationPresetJson(
                core,
                SerializeVersioned(preset));
            var saved = Parse<GenerationPreset>(
                buffer.ReadUtf8(),
                "generation preset");
            ValidateGenerationPreset(saved);
            RequireExactBinding(
                saved.Id,
                preset.Id,
                "saved generation preset");
            RequireExactBinding(
                saved.ModelRouteId,
                preset.ModelRouteId,
                "saved generation preset model route");
            return saved;
        });
    }

    public void ValidateGenerationPreset(
        string modelRouteId,
        string generationPresetId)
    {
        RequireArgument(modelRouteId, nameof(modelRouteId));
        RequireArgument(generationPresetId, nameof(generationPresetId));
        Invoke(() => nativeApi.ValidateGenerationPresetJson(
            core,
            SerializeVersioned(new GenerationPresetTargetPayload(
                modelRouteId,
                generationPresetId))));
    }

    public void ValidateGenerationPresetCandidate(GenerationPreset preset)
    {
        ArgumentNullException.ThrowIfNull(preset);
        ValidateGenerationPreset(preset);
        Invoke(() => nativeApi.ValidateGenerationPresetCandidateJson(
            core,
            SerializeVersioned(preset)));
    }

    public ReasoningControlModel RenderReasoningControlCandidate(
        GenerationPreset preset)
    {
        ArgumentNullException.ThrowIfNull(preset);
        ValidateGenerationPreset(preset);
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.RenderReasoningControlCandidateJson(
                    core,
                    SerializeVersioned(preset));
            var control = Parse<ReasoningControlModel>(
                buffer.ReadUtf8(),
                "reasoning control");
            ValidateReasoningControl(control);
            return control;
        });
    }

    public PromptCacheControlModel RenderPromptCacheControlCandidate(
        GenerationPreset preset)
    {
        ArgumentNullException.ThrowIfNull(preset);
        ValidateGenerationPreset(preset);
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.RenderPromptCacheControlCandidateJson(
                    core,
                    SerializeVersioned(preset));
            var control = Parse<PromptCacheControlModel>(
                buffer.ReadUtf8(),
                "prompt-cache control");
            ValidatePromptCacheControl(control);
            return control;
        });
    }

    public ProviderRequestPreview PreviewProviderRequest(
        string modelRouteId,
        string generationPresetId)
    {
        RequireArgument(modelRouteId, nameof(modelRouteId));
        RequireArgument(generationPresetId, nameof(generationPresetId));
        return Invoke(() =>
        {
            using var buffer = nativeApi.PreviewProviderRequestJson(
                core,
                SerializeVersioned(new GenerationPresetTargetPayload(
                    modelRouteId,
                    generationPresetId)));
            var preview = Parse<ProviderRequestPreview>(
                buffer.ReadUtf8(),
                "provider request preview");
            ValidateProviderRequestPreview(preview);
            return preview;
        });
    }

    public ProviderRequestPreview PreviewProviderRequestCandidate(
        GenerationPreset preset)
    {
        ArgumentNullException.ThrowIfNull(preset);
        ValidateGenerationPreset(preset);
        return Invoke(() =>
        {
            using var buffer =
                nativeApi.PreviewProviderRequestCandidateJson(
                    core,
                    SerializeVersioned(preset));
            var preview = Parse<ProviderRequestPreview>(
                buffer.ReadUtf8(),
                "provider request candidate preview");
            ValidateProviderRequestPreview(preview);
            return preview;
        });
    }

    public void DeleteGenerationPreset(string generationPresetId)
    {
        RequireArgument(generationPresetId, nameof(generationPresetId));
        Invoke(() => nativeApi.DeleteGenerationPresetJson(
            core,
            SerializeVersioned(new DeleteGenerationPresetPayload(
                generationPresetId))));
    }

    public AppSettings SelectGenerationTarget(GenerationTarget? target)
    {
        if (target is not null)
        {
            ValidateGenerationTarget(target);
        }

        return Invoke(() =>
        {
            using var buffer = nativeApi.SelectGenerationTargetJson(
                core,
                SerializeVersioned(new SelectGenerationTargetPayload(target)));
            var settings = Parse<AppSettings>(
                buffer.ReadUtf8(),
                "app settings");
            ValidateSelectedTarget(settings);
            ValidateSelectedTargetResponse(
                settings,
                target);
            return settings;
        });
    }

    public IReadOnlyList<ProviderProfile> ListProviderProfiles()
    {
        return Invoke(() =>
        {
            using var buffer = nativeApi.GetProviderProfilesJson(core);
            var profiles = Parse<List<ProviderProfile>>(
                buffer.ReadUtf8(),
                "provider-profile list");
            foreach (var profile in profiles)
            {
                ValidateProviderProfile(profile);
            }

            return profiles;
        });
    }

    public ProviderProfile UpsertProviderProfile(ProviderProfile profile)
    {
        ArgumentNullException.ThrowIfNull(profile);
        ValidateProviderProfile(profile);
        return Invoke(() =>
        {
            using var buffer = nativeApi.UpsertProviderProfileJson(
                core,
                JsonSerializer.SerializeToUtf8Bytes(profile, JsonOptions));
            var normalized = Parse<ProviderProfile>(
                buffer.ReadUtf8(),
                "provider profile");
            ValidateProviderProfile(normalized);
            return normalized;
        });
    }

    public void DeleteProviderProfile(string profileId)
    {
        RequireArgument(profileId, nameof(profileId));
        Invoke(() => nativeApi.DeleteProviderProfile(
            core,
            Utf8(profileId)));
    }

    private ProviderDiscoverySnapshot
        SupplyProviderDiscoveryEvidence(
            SupplyProviderDiscoveryEvidencePayload payload,
            string? rawCurl,
            string? expectedPendingConnectionId)
    {
        var rawCurlBytes =
            rawCurl is null ? null : Utf8(rawCurl);
        try
        {
            return Invoke(() =>
            {
                using var buffer =
                    nativeApi.SupplyProviderDiscoveryEvidenceJson(
                        core,
                        SerializeVersioned(payload),
                        rawCurlBytes);
                return ParseAndValidateDiscoverySnapshot(
                    buffer.ReadUtf8(),
                    expectedSessionId: payload.SessionId,
                    expectedPendingConnectionId:
                        expectedPendingConnectionId);
            });
        }
        finally
        {
            if (rawCurlBytes is not null)
            {
                CryptographicOperations.ZeroMemory(
                    rawCurlBytes);
            }
        }
    }

    private delegate NativeBuffer DiscoveryCompensationCall(
        SafeCoreHandle core,
        byte[] requestJson);

    private T RunDiscoveryCompensationStep<T>(
        DiscoveryCompensationCall call,
        string label,
        string sessionId,
        string stepId,
        string? expectedPendingConnectionId,
        string? expectedCommitAttemptId)
    {
        RequireArgument(sessionId, nameof(sessionId));
        RequireArgument(stepId, nameof(stepId));
        if (expectedPendingConnectionId is not null)
        {
            RequireArgument(
                expectedPendingConnectionId,
                nameof(expectedPendingConnectionId));
        }
        if (expectedCommitAttemptId is not null)
        {
            RequireArgument(
                expectedCommitAttemptId,
                nameof(expectedCommitAttemptId));
        }
        return Invoke(() =>
        {
            using var buffer = call(
                core,
                SerializeVersioned(
                    new ProviderDiscoveryCompensationStepPayload(
                        sessionId,
                        stepId)));
            var result = Parse<T>(
                buffer.ReadUtf8(),
                label);
            if (result is ProviderDiscoverySnapshot snapshot)
            {
                ValidateProviderDiscoverySnapshot(snapshot);
                RequireExactBinding(
                    snapshot.SessionId,
                    sessionId,
                    "provider-discovery compensation session");
                if (expectedPendingConnectionId is not null)
                {
                    RequireExactBinding(
                        snapshot.PendingConnectionId,
                        expectedPendingConnectionId,
                        "provider-discovery compensation pending connection");
                }
                if (expectedCommitAttemptId is not null)
                {
                    RequireExactBinding(
                        snapshot.CommitAttemptId
                            ?? string.Empty,
                        expectedCommitAttemptId,
                        "provider-discovery compensation attempt");
                }
            }
            else if (result is ProviderDiscoveryCompensationStep step)
            {
                ValidateProviderDiscoveryCompensationStep(step);
                RequireExactBinding(
                    step.Id,
                    stepId,
                    "provider-discovery compensation step");
                if (expectedCommitAttemptId is not null)
                {
                    RequireExactBinding(
                        step.CommitAttemptId,
                        expectedCommitAttemptId,
                        "provider-discovery compensation attempt");
                }
            }
            return result;
        });
    }

    private ProviderDiscoverySnapshot
        RunProviderDiscoveryAssistantSnapshotCall(
            DiscoveryCompensationCall call,
            string label,
            string sessionId)
    {
        RequireArgument(sessionId, nameof(sessionId));
        return Invoke(() =>
        {
            using var buffer = call(
                core,
                SerializeVersioned(
                    new ProviderDiscoverySessionPayload(
                        sessionId)));
            return ParseAndValidateDiscoverySnapshot(
                buffer.ReadUtf8(),
                expectedSessionId: sessionId,
                label: label);
        });
    }

    public void Dispose()
    {
        lock (callGate)
        {
            if (Interlocked.Exchange(ref disposed, 1) == 0)
            {
                core.Dispose();
            }
        }
    }

    private T Invoke<T>(Func<T> operation)
    {
        lock (callGate)
        {
            ThrowIfDisposed();
            return operation();
        }
    }

    private void Invoke(Action operation)
    {
        lock (callGate)
        {
            ThrowIfDisposed();
            operation();
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(
            Volatile.Read(ref disposed) != 0,
            this);
    }

    private static CharacterSummary ParseCharacter(
        string json,
        string payloadName)
    {
        var character = Parse<CharacterSummary>(json, payloadName);
        Require(character.Id, $"{payloadName} id");
        Require(character.Name, $"{payloadName} name");
        Require(character.SourceHash, $"{payloadName} source_hash");
        return character;
    }

    private static Conversation ParseConversation(string json)
    {
        var conversation = Parse<Conversation>(json, "conversation");
        ValidateConversation(conversation);
        return conversation;
    }

    private static void ValidateConversation(Conversation conversation)
    {
        Require(conversation.Id, "conversation id");
        Require(conversation.CharacterId, "conversation character_id");
        Require(conversation.Title, "conversation title");
    }

    private static void ValidateProviderProfile(ProviderProfile profile)
    {
        Require(profile.Id, "provider profile id");
        Require(profile.DisplayName, "provider profile display_name");
        Require(profile.BaseUrl, "provider profile base_url");
        Require(profile.Model, "provider profile model");
        if (profile.TimeoutSeconds is 0 or > 600)
        {
            throw new CoreInteropException(
                "A provider profile timeout_seconds must be between 1 and 600.");
        }
    }

    private static void ValidateProviderTemplate(ProviderTemplate template)
    {
        Require(template.Id, "provider template id");
        Require(template.DisplayName, "provider template display_name");
        if (template.ManifestVersion == 0)
        {
            throw new CoreInteropException(
                "A provider template manifest_version must be positive.");
        }

        ValidateAuthBinding(template.AuthBinding);
        foreach (var field in template.ConnectionFields)
        {
            Require(field.Key, "provider connection-field key");
            Require(field.LabelKey, "provider connection-field label_key");
        }
        foreach (var parameter in template.ParameterSpecs)
        {
            ValidateProviderParameterSpec(parameter);
        }
    }

    private static void ValidateProviderParameterSpec(
        ProviderParameterSpec parameter)
    {
        if (parameter is null)
        {
            throw new CoreInteropException(
                "The provider parameter contract contains a null parameter.");
        }
        Require(parameter.Id, "provider parameter id");
        Require(parameter.LabelKey, "provider parameter label_key");
        if (parameter.ValueType is not (
            "boolean"
            or "integer"
            or "number"
            or "string"
            or "enum"
            or "string_list"
            or "json_schema"
            or "stop_sequence_list"
            or "tool_policy"))
        {
            throw new CoreInteropException(
                $"Unsupported provider parameter value_type '{parameter.ValueType}'.");
        }
        if (parameter.DefaultMode is not (
            "provider_default" or "explicit_required"))
        {
            throw new CoreInteropException(
                $"Unsupported provider parameter default_mode '{parameter.DefaultMode}'.");
        }
        if (parameter.Level is not (
            "basic" or "advanced" or "expert" or "hidden_internal"))
        {
            throw new CoreInteropException(
                $"Unsupported provider parameter level '{parameter.Level}'.");
        }
        if (parameter.ProviderMapping is null
            || parameter.ProviderMapping.Target is not (
                "request_body" or "request_header"))
        {
            throw new CoreInteropException(
                "A provider parameter has an invalid provider mapping.");
        }
        Require(
            parameter.ProviderMapping.FieldName,
            "provider parameter field_name");
        if (parameter.ProviderMapping.FieldName.Any(char.IsControl)
            || (parameter.ProviderMapping.Target == "request_header"
                && !parameter.ProviderMapping.FieldName.All(
                    IsHttpTokenCharacter)))
        {
            throw new CoreInteropException(
                "A provider parameter has an unsafe mapped field name.");
        }
        if ((parameter.Minimum is { } minimum && !double.IsFinite(minimum))
            || (parameter.Maximum is { } maximum && !double.IsFinite(maximum))
            || (parameter.Step is { } step
                && (!double.IsFinite(step) || step <= 0))
            || (parameter.Minimum is { } lower
                && parameter.Maximum is { } upper
                && lower > upper))
        {
            throw new CoreInteropException(
                "A provider parameter has invalid numeric constraints.");
        }
        if (parameter.AllowedValues is null
            || parameter.Conflicts is null)
        {
            throw new CoreInteropException(
                "A provider parameter is missing collection metadata.");
        }
        foreach (var choice in parameter.AllowedValues)
        {
            if (choice is null || choice.Value is null)
            {
                throw new CoreInteropException(
                    "A provider parameter contains an invalid allowed value.");
            }
            Require(choice.LabelKey, "provider parameter choice label_key");
            ValidateParameterLiteral(choice.Value);
            if (choice.Value.Type != parameter.ValueType)
            {
                throw new CoreInteropException(
                    $"Provider parameter '{parameter.Id}' contains an allowed value with a mismatched type.");
            }
        }
        if (parameter.Visibility is { } visibility)
        {
            Require(
                visibility.ParameterId,
                "provider parameter visibility parameter_id");
            if (visibility.Operator is not ("equals" or "not_equals")
                || visibility.Value is null)
            {
                throw new CoreInteropException(
                    "A provider parameter has an invalid visibility condition.");
            }
            ValidateParameterLiteral(visibility.Value);
        }
        foreach (var conflict in parameter.Conflicts)
        {
            if (conflict is null
                || conflict.Kind is not ("mutually_exclusive" or "requires"))
            {
                throw new CoreInteropException(
                    "A provider parameter has an invalid conflict.");
            }
            Require(
                conflict.ParameterId,
                "provider parameter conflict parameter_id");
            Require(
                conflict.MessageKey,
                "provider parameter conflict message_key");
        }
    }

    private static void ValidateProviderCurlInspection(
        ProviderCurlInspection inspection)
    {
        if (inspection.InspectionSchemaVersion != 1)
        {
            throw new CoreInteropException(
                "The provider cURL inspection has an unsupported schema version.");
        }
        ValidateProviderOrigin(
            inspection.ApiOrigin,
            "provider cURL inspection api_origin");
        Require(
            inspection.SanitizedSiteUrl,
            "provider cURL inspection sanitized_site_url");
        Require(
            inspection.Method,
            "provider cURL inspection method");
        Require(
            inspection.Path,
            "provider cURL inspection path");
        Require(
            inspection.RedactedCurl,
            "provider cURL inspection redacted_curl");
    }

    private static void ValidateProviderDiscoveryConnectionOptions(
        ProviderDiscoveryConnectionOptions options)
    {
        if (options.TimeoutSeconds is 0 or > 600)
        {
            throw new ArgumentOutOfRangeException(
                nameof(options),
                "Provider-discovery timeout must be between 1 and 600 seconds.");
        }
        ValidateConnectionValues(options.Values);
        ValidateProviderNetworkPolicy(
            options.LocalNetworkApproval?.Origin
                ?? "https://public.invalid",
            options.NetworkMode,
            options.LocalNetworkApproval,
            "provider-discovery connection options");
    }

    private static void ValidateProviderDiscoveryInput(
        ProviderDiscoveryInput input)
    {
        Require(input.ConnectionId, "provider-discovery connection_id");
        Require(input.DisplayName, "provider-discovery display_name");
        ValidateProviderDiscoveryConnectionOptions(
            input.ConnectionOptions);
        foreach (var url in new[] { input.SiteUrl, input.DocsUrl })
        {
            if (url is not null
                && (!Uri.TryCreate(
                        url,
                        UriKind.Absolute,
                        out var uri)
                    || (uri.Scheme != Uri.UriSchemeHttp
                        && uri.Scheme != Uri.UriSchemeHttps)))
            {
                throw new ArgumentException(
                    "Provider-discovery URLs must be absolute HTTP(S) URLs.");
            }
        }
    }

    private static void ValidateProviderDiscoverySource(
        ProviderDiscoverySource source,
        string? rawCurl)
    {
        var hasRawCurl = rawCurl is not null;
        var valid = source.Kind switch
        {
            "known_provider" =>
                !string.IsNullOrWhiteSpace(source.TemplateId)
                && !hasRawCurl,
            "site" =>
                source.TemplateId is null
                && !hasRawCurl,
            "curl" =>
                source.TemplateId is null
                && !string.IsNullOrWhiteSpace(rawCurl),
            _ => false,
        };
        if (!valid)
        {
            throw new ArgumentException(
                "The provider-discovery source and one-shot cURL input do not match.");
        }
    }

    private ProviderDiscoverySnapshot ParseAndValidateDiscoverySnapshot(
        string json,
        string? expectedSessionId = null,
        string? expectedPendingConnectionId = null,
        string? expectedCommitAttemptId = null,
        string label = "provider-discovery snapshot")
    {
        var snapshot = Parse<ProviderDiscoverySnapshot>(
            json,
            label);
        ValidateProviderDiscoverySnapshot(snapshot);
        if (expectedSessionId is not null)
        {
            RequireExactBinding(
                snapshot.SessionId,
                expectedSessionId,
                "provider-discovery session");
        }
        if (expectedPendingConnectionId is not null)
        {
            RequireExactBinding(
                snapshot.PendingConnectionId,
                expectedPendingConnectionId,
                "provider-discovery pending connection");
        }
        if (expectedCommitAttemptId is not null)
        {
            RequireExactBinding(
                snapshot.CommitAttemptId ?? string.Empty,
                expectedCommitAttemptId,
                "provider-discovery commit attempt");
        }
        return snapshot;
    }

    private static void ValidateProviderDiscoverySnapshot(
        ProviderDiscoverySnapshot snapshot)
    {
        if (snapshot.SnapshotSchemaVersion != 3)
        {
            throw new CoreInteropException(
                "The provider-discovery snapshot has an unsupported schema version.");
        }
        if (snapshot.NextEventSequence == 0
            || snapshot.CreatedAt == default
            || snapshot.UpdatedAt < snapshot.CreatedAt)
        {
            throw new CoreInteropException(
                "The provider-discovery snapshot has invalid durable lifecycle metadata.");
        }
        Require(snapshot.SessionId, "provider-discovery session_id");
        Require(
            snapshot.PendingConnectionId,
            "provider-discovery pending_connection_id");
        Require(
            snapshot.PendingDisplayName,
            "provider-discovery pending_display_name");
        ValidateProviderDiscoveryConnectionOptions(
            snapshot.ConnectionOptions);
        if (snapshot.CredentialSlotExpected)
        {
            if (!string.Equals(
                    snapshot.CredentialSlotId,
                    snapshot.PendingConnectionId,
                    StringComparison.Ordinal))
            {
                throw new CoreInteropException(
                    "The provider-discovery credential slot is not bound to the pending connection ID.");
            }
        }
        else if (snapshot.CredentialSlotId is not null)
        {
            throw new CoreInteropException(
                "A credential-free provider-discovery snapshot exposed a credential slot.");
        }

        ValidateProviderDiscoveryState(snapshot.State);
        if (snapshot.ManifestSha256 is { } manifestSha256)
        {
            ValidatePayloadSha256(
                manifestSha256,
                "provider-discovery manifest_sha256");
        }
        if (snapshot.CommitPlanSha256 is { } planSha256)
        {
            ValidatePayloadSha256(
                planSha256,
                "provider-discovery commit_plan_sha256");
        }
        if (snapshot.Failure is { } failure)
        {
            Require(
                failure.Code,
                "provider-discovery failure code");
            Require(
                failure.MessageKey,
                "provider-discovery failure message_key");
        }
        if (snapshot.ReviewProposal is { } proposal)
        {
            ValidatePayloadSha256(
                proposal.Review.Sha256,
                "provider-discovery review sha256");
            ValidatePayloadSha256(
                proposal.Review.GraphSha256,
                "provider-discovery graph sha256");
            ValidatePayloadSha256(
                proposal.CommitPlanSha256,
                "provider-discovery commit plan sha256");
            ValidatePayloadSha256(
                proposal.Approval.GrantSha256,
                "provider-discovery approval grant sha256");
            Require(
                proposal.CommitAttemptId,
                "provider-discovery commit_attempt_id");
            if (proposal.RequestPreview is { } preview)
            {
                ValidateProviderRequestPreview(preview);
            }
        }
        if (snapshot.ApprovalProposal is { } approvalProposal)
        {
            Require(
                approvalProposal.ApprovalId,
                "provider-discovery approval proposal id");
            ValidatePayloadSha256(
                approvalProposal.GrantSha256,
                "provider-discovery approval proposal grant_sha256");
            ValidateProviderDiscoveryApprovalGrant(
                approvalProposal.Grant);
        }
        foreach (var candidate in snapshot.Candidates)
        {
            Require(
                candidate.Id,
                "provider-discovery candidate id");
            Require(
                candidate.Summary.Kind,
                "provider-discovery candidate kind");
        }
        var stepIds = new HashSet<string>(StringComparer.Ordinal);
        foreach (var step in snapshot.Steps)
        {
            Require(step.Id, "provider-discovery step id");
            Require(
                step.TitleKey,
                "provider-discovery step title_key");
            if (!stepIds.Add(step.Id))
            {
                throw new CoreInteropException(
                    "The provider-discovery snapshot contains duplicate step IDs.");
            }
            _ = step.State switch
            {
                "completed" or "current" or "pending" => true,
                _ => throw new CoreInteropException(
                    $"Unsupported provider-discovery step state '{step.State}'."),
            };
        }
        ValidateProviderDiscoveryAssistantResumeBoundary(snapshot);
    }

    private static void ValidateProviderDiscoveryState(string state)
    {
        _ = state switch
        {
            "draft" or
            "resolving_known_provider" or
            "awaiting_template_selection" or
            "fetching_documents" or
            "extracting_evidence" or
            "awaiting_more_evidence" or
            "awaiting_assistant_consent" or
            "building_deterministic_manifest_draft" or
            "building_assistant_manifest_draft" or
            "validating_manifest" or
            "awaiting_credential_origin_approval" or
            "listing_models" or
            "awaiting_probe_consent" or
            "probing_capabilities" or
            "awaiting_review" or
            "committing" or
            "compensating" or
            "ready" or
            "failed" or
            "cancelled" or
            "interrupted" or
            "unknown_outcome" => true,
            _ => throw new CoreInteropException(
                $"Unsupported provider-discovery state '{state}'."),
        };
    }

    private static void ValidateProviderDiscoveryEvent(
        ProviderDiscoveryEvent discoveryEvent)
    {
        if (discoveryEvent.EventVersion !=
            SupportedProviderDiscoveryEventVersion)
        {
            throw new CoreInteropException(
                $"Unsupported provider-discovery event version {discoveryEvent.EventVersion}; expected {SupportedProviderDiscoveryEventVersion}.");
        }
        Require(
            discoveryEvent.EventId,
            "provider-discovery event_id");
        Require(
            discoveryEvent.SessionId,
            "provider-discovery event session_id");
        Require(
            discoveryEvent.ActionId,
            "provider-discovery event action_id");
        if (discoveryEvent.Sequence == 0
            || discoveryEvent.SessionRevision == 0)
        {
            throw new CoreInteropException(
                "A provider-discovery event has an invalid sequence or session revision.");
        }
        ValidateProviderDiscoveryState(
            discoveryEvent.State);
        if (discoveryEvent.Progress is { } progress)
        {
            _ = progress.Phase switch
            {
                "provider_candidates" or
                "documents" or
                "evidence" or
                "models" or
                "probes" => true,
                _ => throw new CoreInteropException(
                    $"Unsupported provider-discovery progress phase '{progress.Phase}'."),
            };
            if (progress.Total is { } total
                && progress.Completed > total)
            {
                throw new CoreInteropException(
                    "A provider-discovery event progress value exceeds its total.");
            }
        }
        if (discoveryEvent.Warning is { } warning)
        {
            _ = warning switch
            {
                "assistant_declined" or
                "probes_skipped" or
                "compensation_required" or
                "explicit_restart_required" or
                "unknown_external_outcome" => true,
                _ => throw new CoreInteropException(
                    $"Unsupported provider-discovery event warning '{warning}'."),
            };
        }
        if (discoveryEvent.Failure is { } failure)
        {
            Require(
                failure.Code,
                "provider-discovery event failure code");
            Require(
                failure.MessageKey,
                "provider-discovery event failure message_key");
        }
    }

    private static void ValidateProviderDiscoveryCompensationStep(
        ProviderDiscoveryCompensationStep step)
    {
        Require(step.Id, "provider-discovery compensation step id");
        Require(
            step.CommitAttemptId,
            "provider-discovery compensation commit_attempt_id");
        Require(
            step.ActionId,
            "provider-discovery compensation action_id");
        if (!string.Equals(
                step.Kind,
                step.Target.Kind,
                StringComparison.Ordinal))
        {
            throw new CoreInteropException(
                "A provider-discovery compensation kind does not match its typed target.");
        }
        _ = step.Kind switch
        {
            "remove_credential_slot" or
            "remove_connection_graph" or
            "restore_previous_selection" => true,
            _ => throw new CoreInteropException(
                $"Unsupported provider-discovery compensation kind '{step.Kind}'."),
        };
        _ = step.Status switch
        {
            "pending" or
            "in_progress" or
            "completed" or
            "failed" or
            "outcome_unknown" => true,
            _ => throw new CoreInteropException(
                $"Unsupported provider-discovery compensation status '{step.Status}'."),
        };
        if (step.CreatedAt == default
            || step.UpdatedAt < step.CreatedAt
            || (step.Status == "completed")
                != step.CompletedAt.HasValue
            || (step.CompletedAt is { } completedAt
                && completedAt < step.CreatedAt))
        {
            throw new CoreInteropException(
                "A provider-discovery compensation step has invalid lifecycle timestamps.");
        }
        if (step.Target.Kind == "remove_credential_slot")
        {
            Require(
                step.Target.ConnectionId ?? string.Empty,
                "provider-discovery compensation connection_id");
            if (!string.Equals(
                    step.Target.CredentialRef,
                    step.Target.ConnectionId,
                    StringComparison.Ordinal))
            {
                throw new CoreInteropException(
                    "A provider-discovery compensation credential_ref must exactly match its immutable connection ID.");
            }
            if (step.Target.PreviousSelection is not null)
            {
                throw new CoreInteropException(
                    "A provider-discovery credential compensation target contains selection metadata.");
            }
        }
        else if (step.Target.Kind == "remove_connection_graph")
        {
            Require(
                step.Target.ConnectionId ?? string.Empty,
                "provider-discovery compensation connection_id");
            if (step.Target.CredentialRef is not null
                || step.Target.PreviousSelection is not null)
            {
                throw new CoreInteropException(
                    "A provider-discovery graph compensation target contains unrelated metadata.");
            }
        }
        else if (step.Target.ConnectionId is not null
            || step.Target.CredentialRef is not null)
        {
            throw new CoreInteropException(
                "A provider-discovery selection compensation target contains connection metadata.");
        }
        else
        {
            var selection = step.Target.PreviousSelection
                ?? throw new CoreInteropException(
                    "A provider-discovery selection compensation target is incomplete.");
            switch (selection.Kind)
            {
                case "none"
                    when selection.ModelRouteId is null
                         && selection.GenerationPresetId is null:
                    break;
                case "route_and_preset":
                    Require(
                        selection.ModelRouteId ?? string.Empty,
                        "provider-discovery previous model_route_id");
                    Require(
                        selection.GenerationPresetId ?? string.Empty,
                        "provider-discovery previous generation_preset_id");
                    break;
                default:
                    throw new CoreInteropException(
                        "A provider-discovery previous selection is invalid.");
            }
        }
        if (step.LastFailure is { } failure)
        {
            Require(
                failure.Code,
                "provider-discovery compensation failure code");
            Require(
                failure.MessageKey,
                "provider-discovery compensation failure message_key");
        }
    }

    private static void ValidateProviderDiscoveryAssistantResumeBoundary(
        ProviderDiscoverySnapshot snapshot)
    {
        var boundary = snapshot.AssistantResumeBoundary;
        if (boundary is null)
        {
            return;
        }

        var expectedCheckpoint = boundary.Action switch
        {
            ProviderDiscoveryAssistantResumeAction.RunAssistant =>
                ProviderDiscoveryAssistantCheckpoint.Ready,
            ProviderDiscoveryAssistantResumeAction.WaitForAssistantOutcome =>
                ProviderDiscoveryAssistantCheckpoint.AwaitingAssistant,
            ProviderDiscoveryAssistantResumeAction.ResumeCoreHostAction =>
                ProviderDiscoveryAssistantCheckpoint.AwaitingToolResult,
            ProviderDiscoveryAssistantResumeAction.SupplyMoreEvidence =>
                ProviderDiscoveryAssistantCheckpoint.AwaitingMoreEvidence,
            ProviderDiscoveryAssistantResumeAction.ApproveRetry =>
                ProviderDiscoveryAssistantCheckpoint.AwaitingRetryConsent,
            ProviderDiscoveryAssistantResumeAction.ReviewDraft =>
                ProviderDiscoveryAssistantCheckpoint.DraftReady,
            ProviderDiscoveryAssistantResumeAction.ApproveConsent or
            ProviderDiscoveryAssistantResumeAction.RestartInterrupted or
            ProviderDiscoveryAssistantResumeAction.ResolveUnknownOutcome =>
                (ProviderDiscoveryAssistantCheckpoint?)null,
            _ => throw new CoreInteropException(
                "The provider-discovery assistant resume action is unsupported."),
        };
        if (boundary.Checkpoint != expectedCheckpoint)
        {
            throw new CoreInteropException(
                "The provider-discovery assistant resume checkpoint does not match its typed action.");
        }

        switch (boundary.Action)
        {
            case ProviderDiscoveryAssistantResumeAction.ApproveConsent
                when snapshot.State != "awaiting_assistant_consent":
            case ProviderDiscoveryAssistantResumeAction.RunAssistant
                when snapshot.State != "building_assistant_manifest_draft":
            case ProviderDiscoveryAssistantResumeAction.WaitForAssistantOutcome
                when snapshot.State != "building_assistant_manifest_draft":
            case ProviderDiscoveryAssistantResumeAction.ResumeCoreHostAction
                when snapshot.State != "building_assistant_manifest_draft":
            case ProviderDiscoveryAssistantResumeAction.ApproveRetry
                when snapshot.State != "building_assistant_manifest_draft":
            case ProviderDiscoveryAssistantResumeAction.ReviewDraft
                when snapshot.State != "building_assistant_manifest_draft":
            case ProviderDiscoveryAssistantResumeAction.SupplyMoreEvidence
                when snapshot.State != "awaiting_more_evidence":
            case ProviderDiscoveryAssistantResumeAction.RestartInterrupted
                when snapshot.State != "interrupted":
            case ProviderDiscoveryAssistantResumeAction.ResolveUnknownOutcome
                when snapshot.State != "unknown_outcome":
                throw new CoreInteropException(
                    "The provider-discovery assistant resume action does not match the durable discovery state.");
        }

        if (boundary.Action ==
            ProviderDiscoveryAssistantResumeAction.SupplyMoreEvidence)
        {
            if (boundary.Questions.Count == 0
                || boundary.DraftReview is not null)
            {
                throw new CoreInteropException(
                    "The provider-discovery assistant evidence-resume boundary is incomplete.");
            }
            foreach (var question in boundary.Questions)
            {
                ValidateProviderDiscoveryAssistantQuestion(question);
            }
            return;
        }

        if (boundary.Action ==
            ProviderDiscoveryAssistantResumeAction.ReviewDraft)
        {
            if (boundary.Questions.Count != 0
                || boundary.DraftReview is null)
            {
                throw new CoreInteropException(
                    "The provider-discovery assistant draft-resume boundary is incomplete.");
            }
            ValidateProviderDiscoveryAssistantDraftReview(
                boundary.DraftReview);
            return;
        }

        if (boundary.Questions.Count != 0
            || boundary.DraftReview is not null)
        {
            throw new CoreInteropException(
                "The provider-discovery assistant resume boundary contains data that is not valid for its action.");
        }
    }

    private static void ValidateProviderDiscoveryApprovalGrant(
        ProviderDiscoveryApprovalGrant grant)
    {
        switch (grant.Kind)
        {
            case "template_selection":
                Require(
                    grant.CandidateId ?? string.Empty,
                    "provider-discovery template candidate id");
                return;
            case "assistant_consent":
                Require(
                    grant.AssistantModelRouteId
                        ?? string.Empty,
                    "provider-discovery assistant model route id");
                if (grant.EvidenceIds is null
                    || grant.AllowedDocumentOrigins is null
                    || grant.MaxCalls is null or 0
                    || grant.MaxInputTokens is null or 0
                    || grant.MaxOutputTokens is null or 0
                    || grant.MaxToolCalls is null or 0
                    || grant.MaxRetries is null
                    || grant.MaxCostMicroUnits is null or 0)
                {
                    throw new CoreInteropException(
                        "The provider-discovery assistant grant is incomplete.");
                }
                foreach (var origin in
                         grant.AllowedDocumentOrigins)
                {
                    ValidateProviderOrigin(
                        origin,
                        "provider-discovery assistant allowed origin");
                }
                return;
            case "credential_origin":
                ValidateProviderOrigin(
                    grant.Origin ?? string.Empty,
                    "provider-discovery credential origin");
                ValidateAuthBinding(
                    grant.AuthBinding
                    ?? throw new CoreInteropException(
                        "The provider-discovery credential-origin grant is missing auth binding."));
                ValidatePayloadSha256(
                    grant.ManifestSha256 ?? string.Empty,
                    "provider-discovery credential-origin manifest_sha256");
                return;
            case "capability_probe":
                if (grant.ModelRouteIds is null
                    || grant.Budget is not { } budget
                    || budget.MaxRequests == 0
                    || budget.MaxTotalTokensPerRequest == 0
                    || budget.MaxOutputTokensPerRequest == 0
                    || budget.MaxDurationMillisPerRequest == 0
                    || budget.MaxCallsPerRequest == 0)
                {
                    throw new CoreInteropException(
                        "The provider-discovery capability-probe grant is incomplete.");
                }
                return;
            case "review":
                ValidatePayloadSha256(
                    grant.ReviewSha256 ?? string.Empty,
                    "provider-discovery review grant sha256");
                ValidatePayloadSha256(
                    grant.GraphSha256 ?? string.Empty,
                    "provider-discovery graph grant sha256");
                return;
            case "unknown_outcome_resolution":
                Require(
                    grant.Operation ?? string.Empty,
                    "provider-discovery unknown operation");
                if (grant.Resolution is null)
                {
                    throw new CoreInteropException(
                        "The provider-discovery unknown-outcome grant is missing its resolution.");
                }
                return;
            default:
                throw new CoreInteropException(
                    $"Unsupported provider-discovery approval grant '{grant.Kind}'.");
        }
    }

    private static void ValidateProviderDiscoveryAssistantHostAction(
        ProviderDiscoveryAssistantHostAction action,
        string expectedSessionId)
    {
        switch (action.Kind)
        {
            case "request_more_evidence":
                if (!string.Equals(
                        action.SessionId,
                        expectedSessionId,
                        StringComparison.Ordinal)
                    || action.Questions is null
                    || action.DraftReview is not null)
                {
                    throw new CoreInteropException(
                        "The provider-discovery assistant evidence request is not bound to the active session.");
                }
                foreach (var question in action.Questions)
                {
                    ValidateProviderDiscoveryAssistantQuestion(question);
                }
                return;
            case "review_draft":
                if (action.SessionId is not null
                    || action.Questions is not null
                    || action.DraftReview is null)
                {
                    throw new CoreInteropException(
                        "The provider-discovery assistant draft boundary is malformed.");
                }
                ValidateProviderDiscoveryAssistantDraftReview(
                    action.DraftReview);
                return;
            default:
                throw new CoreInteropException(
                    $"Unsupported provider-discovery assistant host action '{action.Kind}'.");
        }
    }

    private static void ValidateProviderDiscoveryAssistantQuestion(
        ProviderDiscoveryAssistantQuestion question)
    {
        Require(
            question.Id,
            "provider-discovery assistant question id");
        Require(
            question.Question,
            "provider-discovery assistant question");
        Require(
            question.RequiredEvidence,
            "provider-discovery assistant required_evidence");
        if (question.Field is { } field)
        {
            ValidateProviderDiscoveryAssistantDraftField(field);
        }
    }

    private static void ValidateProviderDiscoveryAssistantDraftReview(
        ProviderDiscoveryAssistantDraftReview review)
    {
        var draft = review.Draft;
        Require(
            draft.Summary,
            "provider-discovery assistant draft summary");
        if (draft.Manifest.SchemaVersion != 1)
        {
            throw new CoreInteropException(
                "The provider-discovery assistant manifest schema version is unsupported.");
        }
        ValidateAuthBinding(draft.Manifest.Auth);
        if (draft.Manifest.DefaultApiOrigin is { } defaultOrigin)
        {
            ValidateProviderOrigin(
                defaultOrigin,
                "provider-discovery assistant default_api_origin");
        }
        foreach (var source in draft.Manifest.Sources)
        {
            _ = source.Kind switch
            {
                "official_site" or
                "official_documentation" or
                "signed_catalog" or
                "user_supplied" => true,
                _ => throw new CoreInteropException(
                    $"Unsupported provider-discovery assistant source kind '{source.Kind}'."),
            };
            if (!Uri.TryCreate(
                    source.Url,
                    UriKind.Absolute,
                    out var sourceUrl)
                || (sourceUrl.Scheme != Uri.UriSchemeHttp
                    && sourceUrl.Scheme != Uri.UriSchemeHttps)
                || !string.IsNullOrEmpty(sourceUrl.UserInfo))
            {
                throw new CoreInteropException(
                    "A provider-discovery assistant source is not a safe absolute HTTP(S) URL.");
            }
            if (source.ContentSha256 is { } sourceSha256)
            {
                ValidatePayloadSha256(
                    sourceSha256,
                    "provider-discovery assistant source content_sha256");
            }
        }
        ValidateProviderDiscoveryAssistantEndpoint(
            draft.Manifest.Endpoints.Generate,
            "provider-discovery assistant generate endpoint");
        if (draft.Manifest.Endpoints.Models is { } models)
        {
            ValidateProviderDiscoveryAssistantEndpoint(
                models,
                "provider-discovery assistant models endpoint");
        }
        ValidateProviderDiscoveryAssistantDecoder(
            draft.Manifest.Decoders.Response);
        if (draft.Manifest.Decoders.Streaming is { } streaming)
        {
            ValidateProviderDiscoveryAssistantDecoder(streaming);
        }
        foreach (var parameter in draft.Manifest.Parameters)
        {
            ValidateProviderParameterSpec(parameter);
        }
        foreach (var mapping in draft.EvidenceMappings)
        {
            ValidateProviderDiscoveryAssistantDraftField(mapping.Field);
            Require(
                mapping.Explanation,
                "provider-discovery assistant evidence explanation");
            foreach (var evidenceId in mapping.EvidenceIds)
            {
                Require(
                    evidenceId,
                    "provider-discovery assistant evidence id");
            }
        }
        foreach (var conflict in draft.Conflicts)
        {
            ValidateProviderDiscoveryAssistantDraftField(conflict.Field);
            _ = conflict.Disposition.Status switch
            {
                "unresolved"
                    when conflict.Disposition.SelectedEvidenceId is null
                        && conflict.Disposition.Rationale is null => true,
                "resolved"
                    when !string.IsNullOrWhiteSpace(
                            conflict.Disposition.SelectedEvidenceId)
                        && !string.IsNullOrWhiteSpace(
                            conflict.Disposition.Rationale) => true,
                _ => throw new CoreInteropException(
                    "A provider-discovery assistant evidence conflict has an invalid disposition."),
            };
        }
        foreach (var question in draft.UnresolvedQuestions)
        {
            Require(
                question.Id,
                "provider-discovery assistant unresolved question id");
            Require(
                question.Question,
                "provider-discovery assistant unresolved question");
            Require(
                question.RequiredEvidence,
                "provider-discovery assistant unresolved required_evidence");
            if (question.Field is { } field)
            {
                ValidateProviderDiscoveryAssistantDraftField(field);
            }
        }
        foreach (var confidence in draft.Confidence)
        {
            ValidateProviderDiscoveryAssistantDraftField(
                confidence.Field);
            _ = confidence.Level switch
            {
                "unknown" or "low" or "medium" or "high" => true,
                _ => throw new CoreInteropException(
                    $"Unsupported provider-discovery assistant confidence '{confidence.Level}'."),
            };
            Require(
                confidence.Rationale,
                "provider-discovery assistant confidence rationale");
        }
        foreach (var field in review.UnresolvedConflicts)
        {
            ValidateProviderDiscoveryAssistantDraftField(field);
        }
        if (review.Requirements.Persistence !=
            "blocked_until_checks_pass")
        {
            throw new CoreInteropException(
                "The provider-discovery assistant draft unexpectedly allows persistence before review.");
        }
        var allowedChecks = new HashSet<string>(
            [
                "manifest_validation",
                "url_policy_validation",
                "credential_origin_approval",
                "user_review",
            ],
            StringComparer.Ordinal);
        if (review.Requirements.RequiredChecks.Count == 0
            || review.Requirements.RequiredChecks.Any(
                check => !allowedChecks.Contains(check)))
        {
            throw new CoreInteropException(
                "The provider-discovery assistant draft contains an unsupported review check.");
        }
    }

    private static void ValidateProviderDiscoveryAssistantDraftField(
        ProviderDiscoveryAssistantDraftField field)
    {
        var valid = field.Kind switch
        {
            "parameter" =>
                !string.IsNullOrWhiteSpace(field.ParameterId),
            "api_family" or
            "default_api_origin" or
            "auth" or
            "generate_endpoint" or
            "models_endpoint" or
            "response_decoder" or
            "streaming_decoder" =>
                field.ParameterId is null,
            _ => false,
        };
        if (!valid)
        {
            throw new CoreInteropException(
                "The provider-discovery assistant referenced an unsupported draft field.");
        }
    }

    private static void ValidateProviderDiscoveryAssistantEndpoint(
        ProviderDiscoveryAssistantEndpoint endpoint,
        string field)
    {
        if (endpoint.Method is not ("GET" or "POST")
            || string.IsNullOrWhiteSpace(endpoint.Path)
            || !endpoint.Path.StartsWith(
                "/",
                StringComparison.Ordinal))
        {
            throw new CoreInteropException(
                $"The {field} is malformed.");
        }
    }

    private static void ValidateProviderDiscoveryAssistantDecoder(
        string decoder)
    {
        _ = decoder switch
        {
            "open_ai_json_v1" or
            "open_ai_sse_v1" or
            "anthropic_json_v1" or
            "anthropic_sse_v1" or
            "gemini_json_v1" or
            "gemini_sse_v1" or
            "ollama_json_v1" or
            "ollama_jsonl_v1" => true,
            _ => throw new CoreInteropException(
                $"Unsupported provider-discovery assistant decoder '{decoder}'."),
        };
    }

    private static void ValidateProviderConnectionDraft(
        ProviderConnectionDraft draft)
    {
        Require(draft.Id, "provider connection id");
        Require(draft.TemplateId, "provider connection template_id");
        Require(draft.DisplayName, "provider connection display_name");
        ValidateProviderOrigin(draft.ApiOrigin, "provider connection api_origin");
        if (draft.TemplateVersion == 0)
        {
            throw new CoreInteropException(
                "A provider connection template_version must be positive.");
        }
        if (draft.TimeoutSeconds is 0 or > 600)
        {
            throw new CoreInteropException(
                "A provider connection timeout_seconds must be between 1 and 600.");
        }
        if (draft.ApprovedCredentialOrigin is { } approvedOrigin)
        {
            ValidateProviderOrigin(
                approvedOrigin,
                "provider connection approved_credential_origin");
        }
        ValidateProviderNetworkPolicy(
            draft.ApiOrigin,
            draft.NetworkMode,
            draft.LocalNetworkApproval,
            "provider connection");
        ValidateConnectionValues(draft.Values);
    }

    private static void ValidateProviderConnection(
        ProviderConnection connection)
    {
        Require(connection.Id, "provider connection id");
        Require(connection.TemplateId, "provider connection template_id");
        Require(connection.DisplayName, "provider connection display_name");
        ValidateProviderOrigin(
            connection.ApiOrigin,
            "provider connection api_origin");
        if (connection.TemplateVersion == 0)
        {
            throw new CoreInteropException(
                "A provider connection template_version must be positive.");
        }
        if (connection.TimeoutSeconds is 0 or > 600)
        {
            throw new CoreInteropException(
                "A provider connection timeout_seconds must be between 1 and 600.");
        }
        if (connection.CreatedAt == default || connection.UpdatedAt == default)
        {
            throw new CoreInteropException(
                "A provider connection is missing a lifecycle timestamp.");
        }
        ValidateProviderNetworkPolicy(
            connection.ApiOrigin,
            connection.NetworkMode,
            connection.LocalNetworkApproval,
            "provider connection");
        ValidateConnectionValues(connection.Values);
        ValidateAuthBinding(connection.AuthBinding);
        foreach (var origin in connection.ApprovedCredentialOrigins)
        {
            ValidateProviderOrigin(
                origin,
                "provider connection approved_credential_origins");
        }
        if (connection.CredentialSlotRequired)
        {
            if (!string.Equals(
                    connection.CredentialRef,
                    connection.Id,
                    StringComparison.Ordinal))
            {
                throw new CoreInteropException(
                    "A provider credential_ref must exactly match its immutable connection ID.");
            }
            if (connection.ApprovedCredentialOrigins.Count == 0
                || connection.AuthBinding.Kind == "none")
            {
                throw new CoreInteropException(
                    "A credential-bound provider connection is missing its scope.");
            }
        }
        else if (connection.CredentialRef is not null
            || connection.ApprovedCredentialOrigins.Count != 0
            || connection.AuthBinding.Kind != "none")
        {
            throw new CoreInteropException(
                "A credential-free provider connection contains credential scope metadata.");
        }
    }

    private static void ValidateProviderOrigin(string value, string field)
    {
        Require(value, field);
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttps
                && uri.Scheme != Uri.UriSchemeHttp)
            || string.IsNullOrWhiteSpace(uri.Host)
            || !string.IsNullOrEmpty(uri.UserInfo)
            || (uri.AbsolutePath != "/" && uri.AbsolutePath.Length != 0)
            || !string.IsNullOrEmpty(uri.Query)
            || !string.IsNullOrEmpty(uri.Fragment))
        {
            throw new CoreInteropException(
                $"The {field} must be an absolute HTTP(S) origin without user information.");
        }
    }

    private static void ValidateProviderNetworkPolicy(
        string apiOrigin,
        ProviderNetworkMode networkMode,
        ProviderLocalNetworkApproval? approval,
        string field)
    {
        if (networkMode != ProviderNetworkMode.ApprovedLocalNetwork)
        {
            if (approval is not null)
            {
                throw new CoreInteropException(
                    $"The {field} local_network_approval must be absent unless network_mode is approved_local_network.");
            }
            return;
        }

        if (approval is null)
        {
            throw new CoreInteropException(
                $"The {field} approved_local_network mode requires local_network_approval.");
        }
        ValidateProviderOrigin(
            approval.Origin,
            $"{field} local_network_approval origin");
        if (!string.Equals(
                apiOrigin,
                approval.Origin,
                StringComparison.Ordinal))
        {
            throw new CoreInteropException(
                $"The {field} local_network_approval origin must exactly match api_origin.");
        }
        if (approval.Addresses.Count is < 1 or > 16)
        {
            throw new CoreInteropException(
                $"The {field} local_network_approval must contain from 1 to 16 exact addresses.");
        }

        var addresses = new HashSet<IPAddress>();
        foreach (var value in approval.Addresses)
        {
            if (!IPAddress.TryParse(value, out var address)
                || !IsPrivateLanAddress(address))
            {
                throw new CoreInteropException(
                    $"The {field} local_network_approval contains an address outside RFC1918 IPv4 or ULA IPv6.");
            }
            if (!addresses.Add(address))
            {
                throw new CoreInteropException(
                    $"The {field} local_network_approval contains a duplicate address.");
            }
        }
    }

    private static bool IsPrivateLanAddress(IPAddress address)
    {
        if (address.AddressFamily ==
            System.Net.Sockets.AddressFamily.InterNetworkV6)
        {
            return address.IsIPv6UniqueLocal;
        }
        if (address.AddressFamily !=
            System.Net.Sockets.AddressFamily.InterNetwork)
        {
            return false;
        }

        var bytes = address.GetAddressBytes();
        return bytes[0] == 10
            || (bytes[0] == 172
                && bytes[1] is >= 16 and <= 31)
            || (bytes[0] == 192 && bytes[1] == 168);
    }

    private static void ValidateAuthBinding(ProviderAuthBinding binding)
    {
        ArgumentNullException.ThrowIfNull(binding);
        switch (binding.Kind)
        {
            case "none":
            case "bearer_header":
                if (binding.HeaderName is not null)
                {
                    throw new CoreInteropException(
                        "Only header_api_key auth may declare header_name.");
                }
                break;
            case "header_api_key":
                Require(binding.HeaderName ?? string.Empty, "auth binding header_name");
                break;
            default:
                throw new CoreInteropException(
                    $"Unsupported provider auth binding '{binding.Kind}'.");
        }
    }

    private static void ValidateConnectionValues(
        IReadOnlyList<ConnectionConfigEntry> values)
    {
        foreach (var entry in values)
        {
            Require(entry.Key, "provider connection value key");
            switch (entry.Value.Type)
            {
                case "text" when entry.Value.Value.ValueKind == JsonValueKind.String:
                case "integer" when entry.Value.Value.ValueKind == JsonValueKind.Number
                    && entry.Value.Value.TryGetInt64(out _):
                case "boolean" when entry.Value.Value.ValueKind
                    is JsonValueKind.True or JsonValueKind.False:
                    break;
                default:
                    throw new CoreInteropException(
                        $"Provider connection value '{entry.Key}' has an invalid typed value.");
            }
        }
    }

    private static void ValidateModelRoute(ModelRoute route)
    {
        Require(route.Id, "model route id");
        Require(route.ConnectionId, "model route connection_id");
        Require(route.ModelId, "model route model_id");
        if (route.FirstSeenAt == default)
        {
            throw new CoreInteropException(
                "A model route is missing first_seen_at.");
        }
        if (route.RawMetadataJson is { } rawMetadata)
        {
            try
            {
                using var document = JsonDocument.Parse(rawMetadata);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    throw new CoreInteropException(
                        "Model route raw_metadata_json must contain a JSON object.");
                }
            }
            catch (JsonException exception)
            {
                throw new CoreInteropException(
                    "Model route raw_metadata_json is invalid JSON.",
                    exception);
            }
        }
        foreach (var entry in route.RouteConfig.Values)
        {
            ValidateConnectionValues([entry]);
        }
    }

    private static void ValidateGenerationPreset(GenerationPreset preset)
    {
        Require(preset.Id, "generation preset id");
        Require(preset.ModelRouteId, "generation preset model_route_id");
        Require(preset.DisplayName, "generation preset display_name");
        if (preset.CreatedAt == default || preset.UpdatedAt == default)
        {
            throw new CoreInteropException(
                "A generation preset is missing a lifecycle timestamp.");
        }
        foreach (var parameter in preset.Values)
        {
            Require(parameter.ParameterId, "generation parameter id");
            if (parameter.State.State == "inherit_provider_default")
            {
                if (parameter.State.Value is not null)
                {
                    throw new CoreInteropException(
                        "An inherited generation parameter must not carry a value.");
                }
            }
            else if (parameter.State.State == "explicit")
            {
                if (parameter.State.Value is null)
                {
                    throw new CoreInteropException(
                        "An explicit generation parameter is missing its value.");
                }
                ValidateParameterLiteral(parameter.State.Value);
            }
            else
            {
                throw new CoreInteropException(
                    $"Unsupported generation parameter state '{parameter.State.State}'.");
            }
        }
        if (preset.PromptCache.Ttl.Kind == "custom_seconds"
            && preset.PromptCache.Ttl.Seconds is null)
        {
            throw new CoreInteropException(
                "A custom prompt-cache TTL is missing seconds.");
        }
    }

    private static void ValidateProviderRequestPreview(
        ProviderRequestPreview result)
    {
        if (result.RedactionVersion != 1)
        {
            throw new CoreInteropException(
                $"Unsupported provider request preview redaction version {result.RedactionVersion}.");
        }
        if (result.IncludesPrivateMessage
            || result.IncludesCredentialValue
            || result.IncludesOpaqueReasoningState)
        {
            throw new CoreInteropException(
                "The provider request preview failed its redaction guarantees.");
        }
        if (result.Preview is null)
        {
            throw new CoreInteropException(
                "The provider request preview is missing its request shape.");
        }

        var preview = result.Preview;
        if (preview.Method is not ("GET" or "POST"))
        {
            throw new CoreInteropException(
                $"Unsupported provider request preview method '{preview.Method}'.");
        }
        ValidateProviderOrigin(
            preview.Origin,
            "provider request preview origin");
        if (Encoding.UTF8.GetByteCount(preview.Origin) > 512)
        {
            throw new CoreInteropException(
                "The provider request preview origin exceeds its structural bound.");
        }

        Require(preview.Path, "provider request preview path");
        if (!preview.Path.StartsWith("/", StringComparison.Ordinal)
            || preview.Path.Contains("?", StringComparison.Ordinal)
            || preview.Path.Contains("#", StringComparison.Ordinal)
            || preview.Path.Any(char.IsControl)
            || Encoding.UTF8.GetByteCount(preview.Path) > 2_048)
        {
            throw new CoreInteropException(
                "The provider request preview contains an unsafe path.");
        }

        if (preview.HeaderNames is null
            || preview.HeaderNames.Count > 64)
        {
            throw new CoreInteropException(
                "The provider request preview contains an invalid header-name list.");
        }
        var headerNames = new HashSet<string>(StringComparer.Ordinal);
        foreach (var headerName in preview.HeaderNames)
        {
            if (string.IsNullOrWhiteSpace(headerName)
                || headerName != headerName.ToLowerInvariant()
                || Encoding.UTF8.GetByteCount(headerName) > 128
                || !headerName.All(IsHttpTokenCharacter)
                || !headerNames.Add(headerName))
            {
                throw new CoreInteropException(
                    "The provider request preview contains an unsafe header name.");
            }
        }

        if (preview.Body is not null)
        {
            var nodeCount = 0;
            ValidateProviderRequestBodyShape(
                preview.Body,
                depth: 0,
                ref nodeCount);
        }
    }

    private static void ValidateProviderRequestBodyShape(
        ProviderRequestBodyShape shape,
        int depth,
        ref int nodeCount)
    {
        if (shape is null || depth > 16 || ++nodeCount > 256)
        {
            throw new CoreInteropException(
                "The provider request preview body exceeds its structural bounds.");
        }

        switch (shape.Kind)
        {
            case "null":
            case "boolean":
            case "number":
            case "string":
            case "redacted":
            case "truncated":
                if (shape.Items is not null
                    || shape.Fields is not null
                    || shape.Truncated is not null)
                {
                    throw new CoreInteropException(
                        "A scalar provider request preview shape contains nested data.");
                }
                break;
            case "array":
                if (shape.Items is null
                    || shape.Items.Count > 8
                    || shape.Fields is not null
                    || shape.Truncated is null)
                {
                    throw new CoreInteropException(
                        "An array provider request preview shape is invalid.");
                }
                foreach (var item in shape.Items)
                {
                    ValidateProviderRequestBodyShape(
                        item,
                        depth + 1,
                        ref nodeCount);
                }
                break;
            case "object":
                if (shape.Fields is null
                    || shape.Fields.Count > 32
                    || shape.Items is not null
                    || shape.Truncated is null)
                {
                    throw new CoreInteropException(
                        "An object provider request preview shape is invalid.");
                }
                var fieldNames = new HashSet<string>(StringComparer.Ordinal);
                foreach (var field in shape.Fields)
                {
                    if (field is null
                        || string.IsNullOrWhiteSpace(field.Name)
                        || field.Name.Any(char.IsControl)
                        || Encoding.UTF8.GetByteCount(field.Name) > 128
                        || !fieldNames.Add(field.Name)
                        || field.Shape is null)
                    {
                        throw new CoreInteropException(
                            "A provider request preview body field is invalid.");
                    }
                    ValidateProviderRequestBodyShape(
                        field.Shape,
                        depth + 1,
                        ref nodeCount);
                }
                break;
            default:
                throw new CoreInteropException(
                    $"Unsupported provider request preview body kind '{shape.Kind}'.");
        }
    }

    private static bool IsHttpTokenCharacter(char value) =>
        char.IsAsciiLetterOrDigit(value)
        || "!#$%&'*+-.^_`|~".Contains(value, StringComparison.Ordinal);

    private static void ValidateParameterLiteral(
        ProviderParameterLiteral literal)
    {
        var valid = literal.Type switch
        {
            "boolean" => literal.Value.ValueKind
                is JsonValueKind.True or JsonValueKind.False,
            "integer" => literal.Value.ValueKind == JsonValueKind.Number
                && literal.Value.TryGetInt64(out _),
            "number" => literal.Value.ValueKind == JsonValueKind.Number,
            "string" or "enum" or "json_schema" =>
                literal.Value.ValueKind == JsonValueKind.String,
            "string_list" or "stop_sequence_list" =>
                literal.Value.ValueKind == JsonValueKind.Array,
            "tool_policy" => literal.Value.ValueKind == JsonValueKind.String,
            _ => false,
        };
        if (!valid)
        {
            throw new CoreInteropException(
                $"Generation parameter literal '{literal.Type}' is invalid.");
        }
    }

    private static void ValidateCapabilityObservation(
        CapabilityObservation observation)
    {
        Require(observation.Id, "capability observation id");
        Require(observation.ModelRouteId, "capability observation model_route_id");
        if (observation.ObservedAt == default)
        {
            throw new CoreInteropException(
                "A capability observation is missing observed_at.");
        }
        var valid = observation.Value.Type switch
        {
            "boolean" => observation.Value.Value.ValueKind
                is JsonValueKind.True or JsonValueKind.False,
            "integer" => observation.Value.Value.ValueKind == JsonValueKind.Number
                && observation.Value.Value.TryGetUInt64(out _),
            "enum_values" => observation.Value.Value.ValueKind == JsonValueKind.Array,
            "structured" => observation.Value.Value.ValueKind
                is JsonValueKind.Object or JsonValueKind.Array,
            _ => false,
        };
        if (!valid)
        {
            throw new CoreInteropException(
                $"Capability observation '{observation.Id}' has an invalid typed value.");
        }
    }

    private static void ValidateCapabilityTarget(
        CapabilityObservation observation,
        string modelRouteId,
        CapabilityKey key)
    {
        if (!string.Equals(
                observation.ModelRouteId,
                modelRouteId,
                StringComparison.Ordinal)
            || observation.Key != key)
        {
            throw new CoreInteropException(
                "An effective capability does not match the requested model route and key.");
        }
    }

    private static void ValidateUserCapabilityOverride(
        CapabilityObservation observation)
    {
        ValidateCapabilityObservation(observation);
        if (observation.Source != CapabilityObservationSource.UserOverride)
        {
            throw new ArgumentException(
                "A user capability override must use user_override provenance.",
                nameof(observation));
        }
        if (observation.Value.Type == "structured")
        {
            throw new ArgumentException(
                "A user capability override cannot contain structured provider metadata.",
                nameof(observation));
        }
        if (observation.Status is not (
            CapabilitySupportStatus.Verified
            or CapabilitySupportStatus.Unsupported
            or CapabilitySupportStatus.Unknown
            or CapabilitySupportStatus.Conditional))
        {
            throw new ArgumentException(
                "A user capability override has an unsupported status.",
                nameof(observation));
        }
    }

    private static void ValidateGenerationTarget(GenerationTarget target)
    {
        Require(target.ModelRouteId, "generation target model_route_id");
        Require(
            target.GenerationPresetId,
            "generation target generation_preset_id");
    }

    private void ValidateGenerationTargetCredentialBinding(
        string credentialConnectionId,
        GenerationTarget target)
    {
        ValidateModelRouteCredentialBinding(
            credentialConnectionId,
            target.ModelRouteId);
        var presets = ListGenerationPresets(
            target.ModelRouteId);
        if (presets.Count(preset => string.Equals(
                preset.Id,
                target.GenerationPresetId,
                StringComparison.Ordinal)) != 1)
        {
            throw new CoreInteropException(
                "The generation preset is not bound to the credential target.");
        }
    }

    private void ValidateModelRouteCredentialBinding(
        string credentialConnectionId,
        string modelRouteId)
    {
        var routes = ListModelRoutes(
            credentialConnectionId);
        if (routes.Count(route => string.Equals(
                route.Id,
                modelRouteId,
                StringComparison.Ordinal)) != 1)
        {
            throw new CoreInteropException(
                "The model route is not bound to the credential target.");
        }
    }

    private static void ValidateSelectedTarget(AppSettings settings)
    {
        var routeSelected =
            !string.IsNullOrWhiteSpace(settings.SelectedModelRouteId);
        var presetSelected =
            !string.IsNullOrWhiteSpace(settings.SelectedGenerationPresetId);
        if (routeSelected != presetSelected)
        {
            throw new CoreInteropException(
                "App settings must select or clear a model route and generation preset together.");
        }
    }

    private static void ValidateSelectedTargetResponse(
        AppSettings settings,
        GenerationTarget? expectedTarget)
    {
        if (expectedTarget is null)
        {
            if (settings.SelectedModelRouteId is not null
                || settings.SelectedGenerationPresetId is not null)
            {
                throw new CoreInteropException(
                    "The generation-target clear response did not clear the requested target.");
            }
            return;
        }

        RequireExactBinding(
            settings.SelectedModelRouteId
                ?? string.Empty,
            expectedTarget.ModelRouteId,
            "selected model route");
        RequireExactBinding(
            settings.SelectedGenerationPresetId
                ?? string.Empty,
            expectedTarget.GenerationPresetId,
            "selected generation preset");
    }

    private static void ValidateModelSyncJob(
        ModelSyncJob job,
        string? expectedJobId = null,
        string? expectedConnectionId = null)
    {
        Require(job.Id, "model-sync job id");
        Require(job.ConnectionId, "model-sync job connection_id");
        if (expectedJobId is not null)
        {
            RequireExactBinding(
                job.Id,
                expectedJobId,
                "model-sync job");
        }
        if (expectedConnectionId is not null)
        {
            RequireExactBinding(
                job.ConnectionId,
                expectedConnectionId,
                "model-sync job connection");
        }
        ValidateModelSyncState(job.State);
        if (job.Revision == 0)
        {
            throw new CoreInteropException(
                "A model-sync job revision must be positive.");
        }
        if (job.CreatedAt == default || job.UpdatedAt == default)
        {
            throw new CoreInteropException(
                "A model-sync job is missing a lifecycle timestamp.");
        }
        if (job.Review is { } review)
        {
            ValidatePayloadSha256(review.Sha256, "model-sync review sha256");
            ValidateModelSyncDiff(
                review.Diff,
                job.ConnectionId);
        }
        if (job.Failure is { } failure)
        {
            Require(failure.Code, "model-sync failure code");
            Require(failure.MessageKey, "model-sync failure message_key");
        }
    }

    private static void ValidateModelSyncDiff(
        ModelSyncDiff diff,
        string expectedConnectionId)
    {
        Require(diff.ConnectionId, "model-sync diff connection_id");
        RequireExactBinding(
            diff.ConnectionId,
            expectedConnectionId,
            "model-sync diff connection");
        if (diff.ObservedAt == default)
        {
            throw new CoreInteropException(
                "A model-sync diff is missing observed_at.");
        }
        ValidateProviderConnectionSnapshot(diff.ExpectedConnection);
        RequireExactBinding(
            diff.ExpectedConnection.Id,
            expectedConnectionId,
            "model-sync expected connection");
        var expectedRouteIds = new HashSet<string>(
            StringComparer.Ordinal);
        var listedRouteIds = new HashSet<string>(
            StringComparer.Ordinal);
        foreach (var route in diff.ExpectedModelRoutes)
        {
            ValidateModelSyncRouteSnapshot(route);
            RequireExactBinding(
                route.ConnectionId,
                expectedConnectionId,
                "model-sync expected route connection");
            if (!expectedRouteIds.Add(route.Id))
            {
                throw new CoreInteropException(
                    "A model-sync review contains duplicate expected route IDs.");
            }
        }
        foreach (var route in diff.ListedRoutes)
        {
            ValidateModelSyncRouteSnapshot(route);
            RequireExactBinding(
                route.ConnectionId,
                expectedConnectionId,
                "model-sync listed route connection");
            if (!listedRouteIds.Add(route.Id))
            {
                throw new CoreInteropException(
                    "A model-sync review contains duplicate listed route IDs.");
            }
        }
        var routeIds = new HashSet<string>(
            expectedRouteIds,
            StringComparer.Ordinal);
        routeIds.UnionWith(listedRouteIds);
        foreach (var preset in diff.InitialPresets)
        {
            ValidateGenerationPreset(preset);
            if (!routeIds.Contains(preset.ModelRouteId))
            {
                throw new CoreInteropException(
                    "A model-sync preset belongs to an unrelated model route.");
            }
        }
        foreach (var observation in diff.CapabilityObservations)
        {
            ValidateCapabilityObservation(observation);
            if (!routeIds.Contains(observation.ModelRouteId))
            {
                throw new CoreInteropException(
                    "A model-sync capability observation belongs to an unrelated model route.");
            }
        }
        ValidateModelSyncRouteReferences(
            diff.NewlySeenModelRouteIds,
            listedRouteIds,
            "newly seen");
        ValidateModelSyncRouteReferences(
            diff.MissingModelRouteIds,
            expectedRouteIds,
            "missing");
        ValidateModelSyncRouteReferences(
            diff.RoutesRequiringPresetConfiguration,
            routeIds,
            "preset-configuration");
        Require(diff.Provenance.Source, "model-sync provenance source");
        ValidateProviderOrigin(
            diff.Provenance.ApiOrigin,
            "model-sync provenance api_origin");
        Require(
            diff.Provenance.EndpointPath,
            "model-sync provenance endpoint_path");
    }

    private static void ValidateModelSyncRouteReferences(
        IReadOnlyList<string> routeReferences,
        IReadOnlySet<string> allowedRouteIds,
        string label)
    {
        var uniqueReferences = new HashSet<string>(
            StringComparer.Ordinal);
        foreach (var routeId in routeReferences)
        {
            Require(
                routeId,
                $"model-sync {label} route id");
            if (!allowedRouteIds.Contains(routeId)
                || !uniqueReferences.Add(routeId))
            {
                throw new CoreInteropException(
                    $"A model-sync {label} route reference is unrelated or duplicated.");
            }
        }
    }

    private static void ValidateProviderConnectionSnapshot(
        ProviderConnectionSnapshot connection)
    {
        Require(connection.Id, "model-sync connection id");
        Require(connection.TemplateId, "model-sync connection template_id");
        Require(connection.DisplayName, "model-sync connection display_name");
        ValidateProviderOrigin(
            connection.ApiOrigin,
            "model-sync connection api_origin");
        if (connection.TemplateVersion == 0
            || connection.TimeoutSeconds is 0 or > 600
            || connection.CreatedAt == default
            || connection.UpdatedAt == default)
        {
            throw new CoreInteropException(
                "A model-sync connection snapshot is incomplete.");
        }
        ValidateProviderNetworkPolicy(
            connection.ApiOrigin,
            connection.Config.NetworkMode,
            connection.Config.LocalNetworkApproval,
            "model-sync connection");
        ValidateConnectionValues(connection.Config.Values);
        if (connection.CredentialRef is { } credentialRef)
        {
            RequireExactBinding(
                credentialRef,
                connection.Id,
                "model-sync credential reference");
        }
        if (connection.CredentialScope is { } scope)
        {
            ValidateAuthBinding(scope.AuthBinding);
            Require(scope.RedirectPolicy, "model-sync credential redirect_policy");
            foreach (var origin in scope.AllowedOrigins)
            {
                ValidateProviderOrigin(
                    origin,
                    "model-sync credential allowed_origin");
            }
        }
    }

    private static void ValidateModelSyncRouteSnapshot(
        ModelSyncRouteSnapshot route)
    {
        Require(route.Id, "model-sync route id");
        Require(route.ConnectionId, "model-sync route connection_id");
        Require(route.ModelId, "model-sync route model_id");
        if (route.FirstSeenAt == default)
        {
            throw new CoreInteropException(
                "A model-sync route is missing first_seen_at.");
        }
        ValidateRawMetadata(route.RawMetadata, "model-sync route raw_metadata");
        ValidateConnectionValues(route.RouteConfig.Values);
    }

    private static void ValidateModelSyncEvent(ModelSyncEvent modelSyncEvent)
    {
        if (modelSyncEvent.Version != 1
            || modelSyncEvent.RedactionVersion != 1)
        {
            throw new CoreInteropException(
                "Unsupported model-sync event or redaction version.");
        }
        Require(modelSyncEvent.JobId, "model-sync event job_id");
        ValidateModelSyncState(modelSyncEvent.State);
        Require(
            modelSyncEvent.Progress.MessageKey,
            "model-sync event progress message_key");
        if (modelSyncEvent.JobRevision == 0
            || modelSyncEvent.Progress.TotalSteps == 0
            || modelSyncEvent.Progress.CompletedSteps
                > modelSyncEvent.Progress.TotalSteps
            || modelSyncEvent.EmittedAt == default)
        {
            throw new CoreInteropException(
                "A model-sync event contains invalid progress metadata.");
        }
        if (modelSyncEvent.ReviewSha256 is { } reviewSha256)
        {
            ValidatePayloadSha256(
                reviewSha256,
                "model-sync event review_sha256");
        }
        if (modelSyncEvent.Failure is { } failure)
        {
            Require(failure.Code, "model-sync event failure code");
            Require(
                failure.MessageKey,
                "model-sync event failure message_key");
        }
    }

    private static void ValidateModelSyncState(string state)
    {
        if (state is not (
            ModelSyncStates.Created
            or ModelSyncStates.Fetching
            or ModelSyncStates.Interrupted
            or ModelSyncStates.DiffReadyAwaitingReview
            or ModelSyncStates.Committing
            or ModelSyncStates.Completed
            or ModelSyncStates.Failed
            or ModelSyncStates.Cancelled))
        {
            throw new CoreInteropException(
                $"Unsupported model-sync state '{state}'.");
        }
    }

    private static void ValidateProviderCatalogStatus(
        ProviderCatalogStatus status)
    {
        if (status.StatusSchemaVersion != 1
            || status.ActiveRevision == 0)
        {
            throw new CoreInteropException(
                "Unsupported or invalid provider-catalog status.");
        }
        ValidatePayloadSha256(
            status.ActiveSnapshotSha256,
            "provider-catalog active_snapshot_sha256");
        ValidatePayloadSha256(
            status.BundledBaselineSha256,
            "provider-catalog bundled_baseline_sha256");
    }

    private static void ValidateProviderCatalogHistory(
        ProviderCatalogHistory history)
    {
        if (history.HistorySchemaVersion != 1
            || history.ActiveRevision == 0)
        {
            throw new CoreInteropException(
                "Unsupported or invalid provider-catalog history.");
        }
        foreach (var revision in history.Revisions)
        {
            if (revision.Revision == 0 || revision.CapturedAt == default)
            {
                throw new CoreInteropException(
                    "A provider-catalog revision summary is incomplete.");
            }
            ValidatePayloadSha256(
                revision.SnapshotSha256,
                "provider-catalog snapshot_sha256");
        }
        foreach (var activation in history.Activations)
        {
            Require(activation.ActionId, "provider-catalog activation action_id");
            if (activation.ToRevision == 0
                || activation.ActivatedAt == default)
            {
                throw new CoreInteropException(
                    "A provider-catalog activation summary is incomplete.");
            }
            ValidateProviderCatalogDiff(activation.Diff);
        }
    }

    private static void ValidateProviderCatalogDiff(
        ProviderCatalogDiff diff)
    {
        if (diff.DiffSchemaVersion != 1
            || diff.FromRevision == 0
            || diff.ToRevision == 0)
        {
            throw new CoreInteropException(
                "Unsupported or invalid provider-catalog diff.");
        }
        var templateIds = new HashSet<string>(StringComparer.Ordinal);
        ValidateCatalogManifestChanges(
            diff.AddedProviderTemplates,
            CatalogChangeKind.Added,
            templateIds);
        ValidateCatalogManifestChanges(
            diff.ChangedProviderTemplates,
            CatalogChangeKind.Updated,
            templateIds);
        ValidateCatalogManifestChanges(
            diff.RemovedProviderTemplates,
            CatalogChangeKind.Removed,
            templateIds);

        var modelIds = new HashSet<string>(StringComparer.Ordinal);
        ValidateCatalogModelChanges(
            diff.AddedModels,
            CatalogChangeKind.Added,
            modelIds);
        ValidateCatalogModelChanges(
            diff.ChangedModels,
            CatalogChangeKind.Updated,
            modelIds);
        ValidateCatalogModelChanges(
            diff.RemovedModels,
            CatalogChangeKind.Removed,
            modelIds);
    }

    private static void ValidateCatalogManifestChanges(
        IReadOnlyList<CatalogManifestDiff> changes,
        CatalogChangeKind kind,
        HashSet<string> seenIds)
    {
        foreach (var manifest in changes)
        {
            Require(
                manifest.ProviderTemplateId,
                "provider-catalog manifest provider_template_id");
            if (!seenIds.Add(manifest.ProviderTemplateId))
            {
                throw new CoreInteropException(
                    "A provider template appears in more than one catalog diff category.");
            }
            ValidateOptionalPayloadSha256(
                manifest.PreviousSha256,
                "provider-catalog previous manifest sha256");
            ValidateOptionalPayloadSha256(
                manifest.NextSha256,
                "provider-catalog next manifest sha256");
            ValidateCatalogChangeSides(
                kind,
                manifest.PreviousManifestVersion,
                manifest.NextManifestVersion,
                manifest.PreviousSha256,
                manifest.NextSha256,
                "provider template");
            ValidateDistinctValues(
                manifest.ChangedSections
                    .Select(section => section.ToString())
                    .ToArray(),
                "provider-catalog manifest changed sections");
        }
    }

    private static void ValidateCatalogModelChanges(
        IReadOnlyList<CatalogModelMetadataDiff> changes,
        CatalogChangeKind kind,
        HashSet<string> seenIds)
    {
        foreach (var model in changes)
        {
            Require(model.ModelEntryId, "provider-catalog model_entry_id");
            Require(
                model.ProviderTemplateId,
                "provider-catalog model provider_template_id");
            if (!seenIds.Add(model.ModelEntryId))
            {
                throw new CoreInteropException(
                    "A model entry appears in more than one catalog diff category.");
            }
            ValidateOptionalPayloadSha256(
                model.PreviousSha256,
                "provider-catalog previous model sha256");
            ValidateOptionalPayloadSha256(
                model.NextSha256,
                "provider-catalog next model sha256");
            ValidateCatalogChangeSides(
                kind,
                model.PreviousMetadataVersion,
                model.NextMetadataVersion,
                model.PreviousSha256,
                model.NextSha256,
                "model entry");
            ValidateDistinctValues(
                model.ChangedSections
                    .Select(section => section.ToString())
                    .ToArray(),
                "provider-catalog model changed sections");
        }
    }

    private static void ValidateCatalogChangeSides(
        CatalogChangeKind kind,
        uint? previousVersion,
        uint? nextVersion,
        string? previousSha256,
        string? nextSha256,
        string label)
    {
        var hasPrevious =
            previousVersion is > 0 && previousSha256 is not null;
        var hasNext =
            nextVersion is > 0 && nextSha256 is not null;
        var valid = kind switch
        {
            CatalogChangeKind.Added => !hasPrevious && hasNext,
            CatalogChangeKind.Updated => hasPrevious && hasNext,
            CatalogChangeKind.Removed => hasPrevious && !hasNext,
            _ => false,
        };
        if (!valid
            || (previousVersion is null) != (previousSha256 is null)
            || (nextVersion is null) != (nextSha256 is null))
        {
            throw new CoreInteropException(
                $"A provider-catalog {label} change has invalid before/after metadata.");
        }
    }

    private static void ValidateProviderCatalogRollbackPlan(
        ProviderCatalogRollbackPlan plan)
    {
        if (plan.PlanSchemaVersion != 1)
        {
            throw new CoreInteropException(
                "Unsupported provider-catalog rollback plan version.");
        }
        Require(plan.ActionId, "provider-catalog rollback action_id");
        ValidatePayloadSha256(
            plan.PlanSha256,
            "provider-catalog rollback plan_sha256");
        if (plan.ExpectedStateVersion == 0
            || plan.FromRevision == 0
            || plan.ToRevision == 0
            || plan.CreatedAt == default
            || plan.ExpiresAt == default
            || plan.ExpiresAt <= plan.CreatedAt)
        {
            throw new CoreInteropException(
                "A provider-catalog rollback plan is incomplete.");
        }
        ValidateProviderCatalogDiff(plan.Diff);
        using var document = ParseCatalogPlanJson(
            plan.PlanJson,
            "provider-catalog rollback plan_json");
        var root = document.RootElement;
        RequireCatalogPlanMatch(
            root,
            "action_id",
            plan.ActionId,
            "provider-catalog rollback action_id");
        RequireCatalogPlanMatch(
            root,
            "plan_sha256",
            plan.PlanSha256,
            "provider-catalog rollback plan_sha256");
        RequireCatalogPlanMatch(
            root,
            "expected_state_version",
            plan.ExpectedStateVersion,
            "provider-catalog rollback expected_state_version");
        var catalogPlan = RequireCatalogPlanObject(
            root,
            "catalog_plan",
            "provider-catalog rollback catalog_plan");
        RequireCatalogPlanMatch(
            catalogPlan,
            "from_revision",
            plan.FromRevision,
            "provider-catalog rollback from_revision");
        RequireCatalogPlanMatch(
            catalogPlan,
            "to_revision",
            plan.ToRevision,
            "provider-catalog rollback to_revision");
    }

    private static void ValidateProviderCatalogImportPlan(
        ProviderCatalogImportPlan plan,
        byte[] envelopeJson)
    {
        var review = plan.Review;
        if (review.PlanSchemaVersion != 1
            || review.EnvelopeByteCount == 0
            || review.EnvelopeByteCount
                != checked((ulong)envelopeJson.LongLength)
            || review.ExpectedActiveRevision == 0
            || review.SignedCatalogRevision == 0
            || review.CandidateRevision == 0
            || review.PreparedAt == default
            || review.ExpiresAt <= review.PreparedAt)
        {
            throw new CoreInteropException(
                "A provider-catalog import plan is incomplete or does not match the retained envelope.");
        }
        Require(review.ActionId, "provider-catalog import action_id");
        Require(review.SigningKeyId, "provider-catalog import signing_key_id");
        ValidatePayloadSha256(
            plan.PlanSha256,
            "provider-catalog import plan_sha256");
        ValidatePayloadSha256(
            review.ExpectedActiveSnapshotSha256,
            "provider-catalog import expected_active_snapshot_sha256");
        ValidatePayloadSha256(
            review.EnvelopeSha256,
            "provider-catalog import envelope_sha256");
        ValidatePayloadSha256(
            review.PayloadSha256,
            "provider-catalog import payload_sha256");
        ValidatePayloadSha256(
            review.CandidateSnapshotSha256,
            "provider-catalog import candidate_snapshot_sha256");
        var actualEnvelopeSha256 = Convert.ToHexString(
                SHA256.HashData(envelopeJson))
            .ToLowerInvariant();
        if (!CryptographicOperations.FixedTimeEquals(
                Encoding.ASCII.GetBytes(review.EnvelopeSha256),
                Encoding.ASCII.GetBytes(actualEnvelopeSha256)))
        {
            throw new CoreInteropException(
                "The retained signed-catalog envelope does not match the reviewed plan.");
        }
        ValidateProviderCatalogDiff(review.Diff);
        using var document = ParseCatalogPlanJson(
            plan.PlanJson,
            "provider-catalog import plan_json");
        var root = document.RootElement;
        RequireCatalogPlanMatch(
            root,
            "plan_sha256",
            plan.PlanSha256,
            "provider-catalog import plan_sha256");
        var retainedReview = RequireCatalogPlanObject(
            root,
            "review",
            "provider-catalog import review");
        RequireCatalogPlanMatch(
            retainedReview,
            "action_id",
            review.ActionId,
            "provider-catalog import action_id");
        RequireCatalogPlanMatch(
            retainedReview,
            "expected_state_version",
            review.ExpectedStateVersion,
            "provider-catalog import expected_state_version");
        RequireCatalogPlanMatch(
            retainedReview,
            "envelope_byte_count",
            review.EnvelopeByteCount,
            "provider-catalog import envelope_byte_count");
        RequireCatalogPlanMatch(
            retainedReview,
            "envelope_sha256",
            review.EnvelopeSha256,
            "provider-catalog import envelope_sha256");
        RequireCatalogPlanMatch(
            retainedReview,
            "candidate_revision",
            review.CandidateRevision,
            "provider-catalog import candidate_revision");
    }

    private static JsonDocument ParseCatalogPlanJson(
        string planJson,
        string field)
    {
        if (string.IsNullOrWhiteSpace(planJson)
            || planJson.Length > 2 * 1024 * 1024)
        {
            throw new CoreInteropException(
                $"The {field} is empty or exceeds 2 MiB.");
        }
        try
        {
            var document = JsonDocument.Parse(planJson);
            if (document.RootElement.ValueKind !=
                JsonValueKind.Object)
            {
                document.Dispose();
                throw new CoreInteropException(
                    $"The {field} must contain a JSON object.");
            }
            return document;
        }
        catch (JsonException exception)
        {
            throw new CoreInteropException(
                $"The {field} is invalid JSON.",
                exception);
        }
    }

    private static JsonElement RequireCatalogPlanObject(
        JsonElement parent,
        string property,
        string field)
    {
        if (!parent.TryGetProperty(property, out var value)
            || value.ValueKind != JsonValueKind.Object)
        {
            throw new CoreInteropException(
                $"The retained {field} is missing.");
        }
        return value;
    }

    private static void RequireCatalogPlanMatch(
        JsonElement parent,
        string property,
        string expected,
        string field)
    {
        if (!parent.TryGetProperty(property, out var value)
            || value.ValueKind != JsonValueKind.String
            || !string.Equals(
                value.GetString(),
                expected,
                StringComparison.Ordinal))
        {
            throw new CoreInteropException(
                $"The retained {field} does not match its typed review.");
        }
    }

    private static void RequireCatalogPlanMatch(
        JsonElement parent,
        string property,
        ulong expected,
        string field)
    {
        if (!parent.TryGetProperty(property, out var value)
            || !value.TryGetUInt64(out var actual)
            || actual != expected)
        {
            throw new CoreInteropException(
                $"The retained {field} does not match its typed review.");
        }
    }

    private static void ValidateReasoningControl(
        ReasoningControlModel control)
    {
        ValidateControlState(control.State, "reasoning control state");
        ValidateFieldState(control.EffortField, "reasoning effort field");
        ValidateFieldState(control.BudgetField, "reasoning budget field");
        ValidateFieldState(control.SummaryField, "reasoning summary field");
        ValidateDistinctValues(
            control.AllowedModes,
            "reasoning allowed modes");
        ValidateDistinctValues(
            control.AllowedEfforts,
            "reasoning allowed efforts");
        ValidateDistinctValues(
            control.AllowedSummaries,
            "reasoning allowed summaries");
        if (control.BudgetBounds is { } bounds
            && (bounds.Minimum == 0
                || bounds.Maximum < bounds.Minimum))
        {
            throw new CoreInteropException(
                "The reasoning budget bounds are invalid.");
        }
        ValidateParameterIssues(control.Issues);
    }

    private static void ValidatePromptCacheControl(
        PromptCacheControlModel control)
    {
        ValidateControlState(control.State, "prompt-cache control state");
        ValidateFieldState(control.TtlField, "prompt-cache TTL field");
        ValidateFieldState(
            control.ContextReferenceField,
            "prompt-cache context-reference field");
        ValidateDistinctValues(
            control.AllowedModes,
            "prompt-cache allowed modes");
        ValidateDistinctValues(
            control.AllowedTtls.Select(ttl => ttl.Kind).ToArray(),
            "prompt-cache allowed TTLs");
        if (control.SupportsCustomTtl
            != (control.CustomTtlBounds is not null))
        {
            throw new CoreInteropException(
                "The prompt-cache custom TTL support flag and bounds disagree.");
        }
        if (control.CustomTtlBounds is { } bounds
            && (bounds.MinimumSeconds == 0
                || bounds.MaximumSeconds < bounds.MinimumSeconds))
        {
            throw new CoreInteropException(
                "The prompt-cache TTL bounds are invalid.");
        }
        ValidateParameterIssues(control.Issues);
    }

    private static void ValidateControlState(
        string state,
        string field)
    {
        if (state is not ("hidden" or "ready" or "invalid"))
        {
            throw new CoreInteropException(
                $"The {field} is unsupported.");
        }
    }

    private static void ValidateFieldState(
        string state,
        string field)
    {
        if (state is not ("hidden" or "enabled" or "required"))
        {
            throw new CoreInteropException(
                $"The {field} is unsupported.");
        }
    }

    private static void ValidateDistinctValues(
        IReadOnlyList<string> values,
        string field)
    {
        if (values.Any(string.IsNullOrWhiteSpace)
            || values.Distinct(StringComparer.Ordinal).Count()
                != values.Count)
        {
            throw new CoreInteropException(
                $"The {field} contain empty or duplicate entries.");
        }
    }

    private static void ValidateParameterIssues(
        IReadOnlyList<ProviderParameterIssue> issues)
    {
        foreach (var issue in issues)
        {
            Require(issue.Code, "provider parameter issue code");
            Require(issue.Message, "provider parameter issue message");
        }
    }

    private static void ValidateSignedCatalogEnvelope(
        byte[] envelopeJson,
        string parameterName)
    {
        ArgumentNullException.ThrowIfNull(envelopeJson);
        if (envelopeJson.Length == 0
            || envelopeJson.Length > 2 * 1024 * 1024)
        {
            throw new ArgumentOutOfRangeException(
                parameterName,
                "A signed provider-catalog envelope must contain 1 byte to 2 MiB.");
        }
        try
        {
            using var document = JsonDocument.Parse(envelopeJson);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new ArgumentException(
                    "A signed provider-catalog envelope must be a JSON object.",
                    parameterName);
            }
        }
        catch (JsonException exception)
        {
            throw new ArgumentException(
                "A signed provider-catalog envelope must be valid JSON.",
                parameterName,
                exception);
        }
    }

    private static void ValidateRawMetadata(string? rawMetadata, string field)
    {
        if (rawMetadata is null)
        {
            return;
        }
        try
        {
            using var document = JsonDocument.Parse(rawMetadata);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new CoreInteropException(
                    $"The {field} must contain a JSON object.");
            }
        }
        catch (JsonException exception)
        {
            throw new CoreInteropException(
                $"The {field} is invalid JSON.",
                exception);
        }
    }

    private static void ValidateSha256(string value, string parameterName)
    {
        if (!IsSha256(value))
        {
            throw new ArgumentException(
                "A SHA-256 digest must contain exactly 64 hexadecimal characters.",
                parameterName);
        }
    }

    private static void ValidatePayloadSha256(string value, string field)
    {
        if (!IsSha256(value))
        {
            throw new CoreInteropException(
                $"The native core payload has an invalid {field}.");
        }
    }

    private static void ValidateOptionalPayloadSha256(
        string? value,
        string field)
    {
        if (value is not null)
        {
            ValidatePayloadSha256(value, field);
        }
    }

    private static bool IsSha256(string value) =>
        value.Length == 64 && value.All(Uri.IsHexDigit);

    private static ChatEvent MapEvent(ChatEventPayload payload)
    {
        if (payload.EventVersion != SupportedChatEventVersion)
        {
            throw new CoreInteropException(
                $"Unsupported chat event version {payload.EventVersion}; expected {SupportedChatEventVersion}.");
        }

        Require(payload.GenerationId, "chat event generation_id");
        Require(payload.ConversationId, "chat event conversation_id");
        var result = new ChatEvent
        {
            EventVersion = payload.EventVersion,
            GenerationId = payload.GenerationId,
            ConversationId = payload.ConversationId,
            BranchId = payload.BranchId,
            AssistantMessageId = payload.AssistantMessageId,
            Sequence = payload.Sequence,
            EmittedAt = payload.EmittedAt,
        };

        return payload.Kind.Type switch
        {
            "generation_started" => result with
            {
                Type = ChatEventType.GenerationStarted,
            },
            "reasoning_delta" => result with
            {
                Type = ChatEventType.ReasoningDelta,
                Text = ReadStringPayload(payload.Kind, "reasoning_delta"),
            },
            "text_delta" => result with
            {
                Type = ChatEventType.TextDelta,
                Text = ReadStringPayload(payload.Kind, "text_delta"),
            },
            "tool_call_started" => RequireEventVersion(
                result with
                {
                    Type = ChatEventType.ToolCallStarted,
                    ToolCallId = ReadRequiredString(
                        payload.Kind.Payload,
                        "id"),
                    ToolName = ReadRequiredString(
                        payload.Kind.Payload,
                        "name"),
                },
                minimumVersion: 4),
            "tool_call_arguments_delta" => RequireEventVersion(
                result with
                {
                    Type = ChatEventType.ToolCallArgumentsDelta,
                    ToolCallId = ReadRequiredString(
                        payload.Kind.Payload,
                        "id"),
                    ToolArgumentsDelta = ReadRequiredString(
                        payload.Kind.Payload,
                        "delta"),
                },
                minimumVersion: 4),
            "tool_call_completed" => RequireEventVersion(
                result with
                {
                    Type = ChatEventType.ToolCallCompleted,
                    ToolCallId = ReadRequiredString(
                        payload.Kind.Payload,
                        "id"),
                },
                minimumVersion: 4),
            "usage_updated" => result with
            {
                Type = ChatEventType.UsageUpdated,
                InputTokens = ReadOptionalUInt64(
                    payload.Kind.Payload,
                    "input_tokens"),
                CachedReadTokens = ReadOptionalUInt64(
                    payload.Kind.Payload,
                    "cached_read_tokens"),
                CachedWriteTokens = ReadOptionalUInt64(
                    payload.Kind.Payload,
                    "cached_write_tokens"),
                OutputTokens = ReadOptionalUInt64(
                    payload.Kind.Payload,
                    "output_tokens"),
                ReasoningTokens = ReadOptionalUInt64(
                    payload.Kind.Payload,
                    "reasoning_tokens"),
                ToolTokens = ReadOptionalUInt64(
                    payload.Kind.Payload,
                    "tool_tokens"),
                ProviderRawSummary = ReadOptionalString(
                    payload.Kind.Payload,
                    "provider_raw_summary"),
            },
            "message_committed" => result with
            {
                Type = ChatEventType.MessageCommitted,
                MessageId = ReadRequiredString(
                    payload.Kind.Payload,
                    "message_id"),
                MessageStatus = ReadRequiredString(
                    payload.Kind.Payload,
                    "status"),
            },
            "generation_cancelled" => result with
            {
                Type = ChatEventType.GenerationCancelled,
            },
            "generation_failed" => result with
            {
                Type = ChatEventType.GenerationFailed,
                ErrorCode = ReadRequiredString(payload.Kind.Payload, "code"),
                ErrorMessage = ReadRequiredString(
                    payload.Kind.Payload,
                    "message"),
            },
            "generation_finished" => result with
            {
                Type = ChatEventType.GenerationFinished,
            },
            _ => throw new CoreInteropException(
                $"Unsupported chat event type '{payload.Kind.Type}'."),
        };
    }

    private static ChatEvent RequireEventVersion(
        ChatEvent chatEvent,
        uint minimumVersion)
    {
        if (chatEvent.EventVersion < minimumVersion)
        {
            throw new CoreInteropException(
                $"{chatEvent.Type} requires chat event version {minimumVersion}.");
        }

        return chatEvent;
    }

    private static string ReadStringPayload(
        ChatEventKindPayload payload,
        string eventType)
    {
        if (payload.Payload.ValueKind != JsonValueKind.String)
        {
            throw new CoreInteropException(
                $"The {eventType} event payload must be a string.");
        }

        return payload.Payload.GetString() ?? string.Empty;
    }

    private static string ReadRequiredString(
        JsonElement payload,
        string property)
    {
        if (payload.ValueKind != JsonValueKind.Object
            || !payload.TryGetProperty(property, out var value)
            || value.ValueKind != JsonValueKind.String
            || string.IsNullOrWhiteSpace(value.GetString()))
        {
            throw new CoreInteropException(
                $"A chat event payload is missing {property}.");
        }

        return value.GetString()!;
    }

    private static ulong? ReadOptionalUInt64(
        JsonElement payload,
        string property)
    {
        if (payload.ValueKind != JsonValueKind.Object
            || !payload.TryGetProperty(property, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.Number
            || !value.TryGetUInt64(out var parsed))
        {
            throw new CoreInteropException(
                $"A chat usage payload has invalid {property}.");
        }

        return parsed;
    }

    private static string? ReadOptionalString(
        JsonElement payload,
        string property)
    {
        if (payload.ValueKind != JsonValueKind.Object
            || !payload.TryGetProperty(property, out var value)
            || value.ValueKind == JsonValueKind.Null)
        {
            return null;
        }

        if (value.ValueKind != JsonValueKind.String)
        {
            throw new CoreInteropException(
                $"A chat usage payload has invalid {property}.");
        }

        return value.GetString();
    }

    private static T Parse<T>(string json, string payloadName)
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            throw new CoreInteropException(
                $"The native core returned an empty {payloadName} payload.");
        }

        try
        {
            return JsonSerializer.Deserialize<T>(json, JsonOptions)
                ?? throw new CoreInteropException(
                    $"The native core returned a null {payloadName} payload.");
        }
        catch (JsonException exception)
        {
            throw new CoreInteropException(
                $"The native core returned invalid {payloadName} JSON.",
                exception);
        }
    }

    private static T? ParseOptional<T>(string json, string payloadName)
        where T : class
    {
        if (string.IsNullOrWhiteSpace(json))
        {
            throw new CoreInteropException(
                $"The native core returned an empty {payloadName} payload.");
        }

        try
        {
            return JsonSerializer.Deserialize<T>(json, JsonOptions);
        }
        catch (JsonException exception)
        {
            throw new CoreInteropException(
                $"The native core returned invalid {payloadName} JSON.",
                exception);
        }
    }

    private static byte[] SerializeVersioned<T>(T payload)
    {
        return JsonSerializer.SerializeToUtf8Bytes(
            new VersionedRequest<T>(1, payload),
            JsonOptions);
    }

    private static byte[] Utf8(string value) => Encoding.UTF8.GetBytes(value);

    private static void RequireArgument(string value, string parameterName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(value, parameterName);
    }

    private static void Require(string value, string field)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new CoreInteropException(
                $"The native core payload is missing {field}.");
        }
    }

    private static void RequireExactBinding(
        string actual,
        string expected,
        string label)
    {
        if (!string.Equals(
                actual,
                expected,
                StringComparison.Ordinal))
        {
            throw new CoreInteropException(
                $"The {label} response does not match the request.");
        }
    }

    private sealed record CoreConfiguration(
        [property: System.Text.Json.Serialization.JsonPropertyName("data_root")]
        string DataRoot);

    private sealed record VersionedRequest<T>(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "request_schema_version")]
        uint RequestSchemaVersion,
        [property: System.Text.Json.Serialization.JsonPropertyName("payload")]
        T Payload);

    private sealed record SendMessageWithTargetPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "conversation_id")]
        string ConversationId,
        [property: System.Text.Json.Serialization.JsonPropertyName("text")]
        string Text,
        [property: System.Text.Json.Serialization.JsonPropertyName("target")]
        GenerationTarget Target);

    private sealed record DeleteProviderConnectionPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "connection_id")]
        string ConnectionId);

    private sealed record DeleteModelRoutePayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "model_route_id")]
        string ModelRouteId);

    private sealed record EffectiveCapabilityPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "model_route_id")]
        string ModelRouteId,
        [property: System.Text.Json.Serialization.JsonPropertyName("key")]
        CapabilityKey Key);

    private sealed record DeleteCapabilityOverridePayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "model_route_id")]
        string ModelRouteId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "observation_id")]
        string ObservationId);

    private sealed record RefreshProviderModelsPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "connection_id")]
        string ConnectionId);

    private sealed record ProviderModelSyncJobPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName("job_id")]
        string JobId);

    private sealed record StartProviderModelSyncPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "connection_id")]
        string ConnectionId);

    private sealed record ListProviderModelSyncsPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "connection_id")]
        string ConnectionId,
        [property: System.Text.Json.Serialization.JsonPropertyName("limit")]
        uint Limit);

    private sealed record ApproveProviderModelSyncPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName("job_id")]
        string JobId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "review_sha256")]
        string ReviewSha256);

    private sealed record PollProviderModelSyncEventsPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName("job_id")]
        string JobId,
        [property: System.Text.Json.Serialization.JsonPropertyName("limit")]
        uint Limit);

    private sealed record AckProviderModelSyncEventPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName("job_id")]
        string JobId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "sequence")]
        ulong Sequence);

    private sealed record InspectProviderCurlPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "connection_options")]
        ProviderDiscoveryConnectionOptions ConnectionOptions);

    private sealed record BeginProviderDiscoveryPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName("input")]
        ProviderDiscoveryInput Input,
        [property: System.Text.Json.Serialization.JsonPropertyName("source")]
        ProviderDiscoverySource Source);

    private sealed record PrepareProviderDiscoveryActionPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "action_id")]
        string ActionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "expected_revision")]
        ulong ExpectedRevision,
        [property: System.Text.Json.Serialization.JsonPropertyName("action")]
        ProviderDiscoveryAction Action);

    private sealed record ContinueProviderDiscoveryPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "action_id")]
        string ActionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "expected_revision")]
        ulong ExpectedRevision,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "request_sha256")]
        string RequestSha256,
        [property: System.Text.Json.Serialization.JsonPropertyName("action")]
        ProviderDiscoveryAction Action);

    private sealed record ProviderDiscoverySessionPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId);

    private sealed record ListProviderDiscoveriesPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName("limit")]
        uint Limit);

    private sealed record ProviderDiscoveryEvidenceSource
    {
        internal ProviderDiscoveryEvidenceSource(
            string kind,
            string? url)
        {
            Kind = kind;
            Url = url;
        }

        [System.Text.Json.Serialization.JsonPropertyName("kind")]
        public string Kind { get; }

        [System.Text.Json.Serialization.JsonPropertyName("url")]
        [System.Text.Json.Serialization.JsonIgnore(
            Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)]
        public string? Url { get; }
    }

    private sealed record SupplyProviderDiscoveryEvidencePayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "expected_revision")]
        ulong ExpectedRevision,
        [property: System.Text.Json.Serialization.JsonPropertyName("source")]
        ProviderDiscoveryEvidenceSource Source);

    private sealed record CancelProviderDiscoveryPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "expected_revision")]
        ulong ExpectedRevision);

    private sealed record CommitProviderDiscoveryPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "credential_reference_confirmed")]
        bool CredentialReferenceConfirmed);

    private sealed record AckProviderDiscoveryEventPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "event_id")]
        string EventId);

    private sealed record ListProviderDiscoveryCompensationPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "commit_attempt_id")]
        string CommitAttemptId);

    private sealed record ProviderDiscoveryCompensationStepPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "step_id")]
        string StepId);

    private sealed record FailProviderDiscoveryCompensationStepPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "step_id")]
        string StepId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "failure_code")]
        string FailureCode,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "failure_message_key")]
        string FailureMessageKey,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "recoverable")]
        bool Recoverable);

    private sealed record RunProviderDiscoveryAssistantTurnPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "estimate")]
        ProviderDiscoveryAssistantCallEstimate Estimate);

    private sealed record RecordProviderDiscoveryAssistantFailurePayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "session_id")]
        string SessionId,
        [property: System.Text.Json.Serialization.JsonPropertyName("kind")]
        string Kind,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "retryable")]
        bool Retryable);

    private sealed record ProviderCatalogHistoryPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName("limit")]
        uint Limit,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "before_revision")]
        ulong? BeforeRevision,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "before_state_version")]
        ulong? BeforeStateVersion);

    private sealed record ProviderCatalogDiffPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "from_revision")]
        ulong FromRevision,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "to_revision")]
        ulong ToRevision);

    private sealed record PrepareProviderCatalogRollbackPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "target_revision")]
        ulong TargetRevision);

    private sealed record ActivateProviderCatalogRollbackPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "plan_json")]
        string PlanJson);

    private sealed record ActivateSignedProviderCatalogImportPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "plan_json")]
        string PlanJson);

    private sealed record DeleteGenerationPresetPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "generation_preset_id")]
        string GenerationPresetId);

    private sealed record GenerationPresetTargetPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "model_route_id")]
        string ModelRouteId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "generation_preset_id")]
        string GenerationPresetId);

    private sealed record SelectGenerationTargetPayload(
        [property: System.Text.Json.Serialization.JsonPropertyName("target")]
        GenerationTarget? Target);

    private sealed record ProviderConnectionWire(
        [property: System.Text.Json.Serialization.JsonPropertyName("id")]
        string Id,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "template_id")]
        string TemplateId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "template_version")]
        uint TemplateVersion,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "display_name")]
        string DisplayName,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "api_origin")]
        string ApiOrigin,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "api_base_path")]
        string? ApiBasePath,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "network_mode")]
        ProviderNetworkMode NetworkMode,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "local_network_approval")]
        ProviderLocalNetworkApproval? LocalNetworkApproval,
        [property: System.Text.Json.Serialization.JsonPropertyName("values")]
        IReadOnlyList<ConnectionConfigEntry> Values,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "credential_slot_ready")]
        bool CredentialSlotReady,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "auth_binding")]
        ProviderAuthBinding AuthBinding,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "approved_credential_origins")]
        IReadOnlyList<string> ApprovedCredentialOrigins,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "credential_redirect_policy")]
        string CredentialRedirectPolicy,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "timeout_seconds")]
        uint TimeoutSeconds,
        [property: System.Text.Json.Serialization.JsonPropertyName("status")]
        ProviderConnectionStatus Status,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "created_at")]
        DateTimeOffset CreatedAt,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "updated_at")]
        DateTimeOffset UpdatedAt)
    {
        internal static ProviderConnectionWire FromPublic(
            ProviderConnection connection,
            bool credentialSlotReady)
        {
            return new ProviderConnectionWire(
                connection.Id,
                connection.TemplateId,
                connection.TemplateVersion,
                connection.DisplayName,
                connection.ApiOrigin,
                connection.ApiBasePath,
                connection.NetworkMode,
                connection.LocalNetworkApproval,
                connection.Values,
                credentialSlotReady,
                credentialSlotReady
                    ? connection.AuthBinding
                    : new ProviderAuthBinding(),
                credentialSlotReady
                    ? connection.ApprovedCredentialOrigins
                    : [],
                credentialSlotReady
                    ? connection.CredentialRedirectPolicy
                    : "deny",
                connection.TimeoutSeconds,
                connection.Status,
                connection.CreatedAt,
                connection.UpdatedAt);
        }
    }

    private sealed record ModelRouteWire(
        [property: System.Text.Json.Serialization.JsonPropertyName("id")]
        string Id,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "connection_id")]
        string ConnectionId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "api_family")]
        ProviderApiFamily ApiFamily,
        [property: System.Text.Json.Serialization.JsonPropertyName("model_id")]
        string ModelId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "display_name")]
        string? DisplayName,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "route_config")]
        ModelRouteConfig RouteConfig,
        [property: System.Text.Json.Serialization.JsonPropertyName("status")]
        ModelAvailability Status,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "miss_count")]
        uint MissCount,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "raw_metadata")]
        string? RawMetadata,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "metadata_source")]
        ModelMetadataSource MetadataSource,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "metadata_observed_at")]
        DateTimeOffset? MetadataObservedAt,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "last_reconciled_sync_job_id")]
        string? LastReconciledSyncJobId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "metadata_sync_job_id")]
        string? MetadataSyncJobId,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "first_seen_at")]
        DateTimeOffset FirstSeenAt,
        [property: System.Text.Json.Serialization.JsonPropertyName(
            "last_seen_at")]
        DateTimeOffset? LastSeenAt)
    {
        internal static ModelRouteWire FromPublic(ModelRoute route) => new(
            route.Id,
            route.ConnectionId,
            route.ApiFamily,
            route.ModelId,
            route.DisplayName,
            route.RouteConfig,
            route.Availability,
            route.MissCount,
            route.RawMetadataJson,
            route.MetadataSource,
            route.MetadataObservedAt,
            route.LastReconciledSyncJobId,
            route.MetadataSyncJobId,
            route.FirstSeenAt,
            route.LastSeenAt);
    }
}
