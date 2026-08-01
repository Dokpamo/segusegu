using Lorepia.App.Platform;
using Lorepia.Native;
using System.Collections.ObjectModel;
using System.Net;

namespace Lorepia.App.ViewModels;

public sealed class SettingsViewModel : ObservableObject
{
    private static readonly CapabilityKey[] CapabilityKeys =
        Enum.GetValues<CapabilityKey>();

    private readonly CoreClient core;
    private readonly IProviderCredentialStore credentials;
    private readonly ProviderCredentialDraftGuard credentialDraft = new();
    private readonly ProviderSelectionGuard selectionGuard = new();
    private readonly SemaphoreSlim discoveryCompensationGate =
        new(1, 1);
    private readonly object discoveryStartGate = new();
    private readonly HashSet<(
        string SessionId,
        string AttemptId,
        string StepId)> claimedDiscoveryCompensations = [];
    private readonly HashSet<(string JobId, ulong Sequence)>
        displayedModelSyncEvents = [];
    private readonly HashSet<string>
        displayedDiscoveryEventIds =
            new(StringComparer.Ordinal);
    private readonly List<ProviderParameterEditor>
        allParameterEditors = [];
    private string abiVersion = "—";
    private string coreVersion = "—";
    private string database = "—";
    private string dataRoot = "—";
    private string staging = "—";
    private string recovery = "—";
    private string status = "Not checked";
    private string providerStatus =
        "Provider connections and model routes are stored locally.";
    private string connectionId = string.Empty;
    private string connectionDisplayName = string.Empty;
    private string apiOrigin = string.Empty;
    private string apiBasePath = string.Empty;
    private string localNetworkOrigin = string.Empty;
    private string localNetworkAddresses = string.Empty;
    private string timeoutSeconds = "60";
    private string siteUrl = string.Empty;
    private string additionalEvidenceUrl = string.Empty;
    private string discoveryActionSummary =
        "No durable provider discovery is active.";
    private string assistantModelRouteSelectionSummary =
        "No executable app-default route and preset are available for the setup assistant.";
    private string unknownOutcomeConnectionId = string.Empty;
    private string presetId = string.Empty;
    private string presetDisplayName = string.Empty;
    private string reasoningMode = "provider_default";
    private string reasoningEffort = string.Empty;
    private string reasoningBudgetTokens = string.Empty;
    private string reasoningSummary = "provider_default";
    private string promptCacheMode = "provider_default";
    private string promptCacheTtl = "provider_default";
    private string promptCacheCustomSeconds = string.Empty;
    private string promptCacheContextReference = string.Empty;
    private string requestPreview =
        "A redacted request preview has not been generated.";
    private string presetControlStatus =
        "Choose a model route to load Core-owned reasoning and cache controls.";
    private string catalogStatus = "Catalog status not loaded.";
    private ProviderSetupModeOption? selectedSetupMode;
    private ProviderNetworkModeOption? selectedNetworkMode;
    private ProviderDiscoverySnapshot? activeDiscovery;
    private ProviderDiscoveryAssistantHostAction? activeAssistantAction;
    private ProviderDiscoveryApprovalGrant? activeAssistantGrant;
    private ProviderDiscoveryAssistantResumeAction?
        activeAssistantResumeAction;
    private string? activeDiscoveryAssistantSessionId;
    private string? activeDiscoveryAssistantRouteId;
    private ProviderDiscoveryCandidateItem?
        selectedDiscoveryCandidate;
    private ProviderDiscoveryResolutionOption?
        selectedDiscoveryResolution;
    private AssistantModelRouteOption?
        selectedAssistantModelRoute;
    private ProviderTemplate? selectedTemplate;
    private ProviderConnection? selectedConnection;
    private ModelRoute? selectedModelRoute;
    private GenerationPreset? selectedGenerationPreset;
    private GenerationPreset? selectedDefaultPreset;
    private ProviderCatalogRevisionItem? selectedCatalogRevision;
    private ProviderCatalogImportPlan? pendingCatalogImportPlan;
    private byte[]? pendingCatalogEnvelopeBytes;
    private ProviderCatalogRollbackPlan? pendingCatalogRollbackPlan;
    private bool credentialOriginApproved;
    private bool localNetworkAccessApproved;
    private bool assistantConsentRequested;
    private bool probeConsentRequested;
    private bool assistantRetryAvailable;
    private bool preservePartialGenerations = true;
    private bool preserveOpaqueReasoningState;
    private bool reasoningControlsEnabled;
    private bool reasoningEffortEnabled;
    private bool reasoningBudgetEnabled;
    private bool reasoningSummaryEnabled;
    private bool promptCacheControlsEnabled;
    private bool promptCacheTtlEnabled;
    private bool promptCacheSupportsCustomTtl;
    private bool promptCacheContextReferenceEnabled;
    private bool isBusy;
    private bool isDiscoveryCancellationInProgress;
    private bool isModelSyncCancellationInProgress;
    private long routeRevision;
    private long previewRevision;
    private long presetControlRevision;
    private bool suppressPresetControlRefresh;
    private bool applyingParameterPolicy;
    private bool discoveryRecoveryPerformed;
    private string? activeModelSyncJobId;
    private string? activeModelSyncReviewSha256;
    private CancellationTokenSource? modelSyncMonitoring;
    private CancellationTokenSource? discoveryMonitoring;
    private CancellationTokenSource? discoveryStartCancellation;
    private Task? discoveryMonitoringTask;
    private long discoveryStartOperationEpoch;
    private long settingsLifecycleEpoch;
    private ulong activeCatalogRevision;
    private IReadOnlyList<ProviderParameterSpec> effectiveParameterSpecs = [];

    internal SettingsViewModel(
        CoreClient core,
        IProviderCredentialStore credentials)
    {
        this.core = core;
        this.credentials = credentials;
        SetupModes.Add(new ProviderSetupModeOption(
            ProviderSetupMode.KnownProvider,
            "Known provider",
            "Choose a built-in provider and enter only its required fields."));
        SetupModes.Add(new ProviderSetupModeOption(
            ProviderSetupMode.WebsiteDiscovery,
            "Find from website",
            "Use the official site or API-key page to discover the API."));
        SetupModes.Add(new ProviderSetupModeOption(
            ProviderSetupMode.CurlExample,
            "Analyze cURL example",
            "Parse an official request example and redact its credential."));
        SetupModes.Add(new ProviderSetupModeOption(
            ProviderSetupMode.LocalServer,
            "Local server",
            "Connect to an explicitly selected loopback provider."));
        NetworkModes.Add(new ProviderNetworkModeOption(
            ProviderNetworkMode.Public,
            "Public internet",
            "Allow only public HTTP(S) origins."));
        NetworkModes.Add(new ProviderNetworkModeOption(
            ProviderNetworkMode.LocalLoopback,
            "This device only",
            "Allow only loopback origins such as 127.0.0.1 or [::1]."));
        NetworkModes.Add(new ProviderNetworkModeOption(
            ProviderNetworkMode.ApprovedLocalNetwork,
            "Approved local network",
            "Pin one exact LAN origin to 1–16 explicitly approved private IP addresses."));
        DiscoveryResolutions.Add(
            new ProviderDiscoveryResolutionOption(
                "confirmed_no_effect",
                "Confirmed no effect",
                "Use only after verifying the uncertain operation changed nothing."));
        DiscoveryResolutions.Add(
            new ProviderDiscoveryResolutionOption(
                "confirmed_commit_completed",
                "Confirmed commit completed",
                "Use only after verifying the exact connection graph exists."));
        DiscoveryResolutions.Add(
            new ProviderDiscoveryResolutionOption(
                "confirmed_compensated",
                "Confirmed compensation completed",
                "Use only after verifying both the connection graph and credential slot were removed."));
        DiscoveryResolutions.Add(
            new ProviderDiscoveryResolutionOption(
                "manually_reconciled_as_failed",
                "Manually reconciled as failed",
                "Use after a manual audit has reconciled all uncertain effects."));
        selectedSetupMode = SetupModes[0];
        selectedNetworkMode = NetworkModes[0];
    }

    public ObservableCollection<ProviderSetupModeOption> SetupModes { get; } =
        [];

    public ObservableCollection<ProviderNetworkModeOption> NetworkModes
    {
        get;
    } = [];

    public ObservableCollection<ProviderDiscoveryResolutionOption>
    DiscoveryResolutions
    {
        get;
    } = [];

    public ObservableCollection<AssistantModelRouteOption>
    AssistantModelRoutes
    {
        get;
    } = [];

    public ObservableCollection<ProviderProgressItem>
    AssistantGrantReview
    {
        get;
    } = [];

    public ObservableCollection<ProviderDiscoveryCandidateItem>
    DiscoveryCandidates
    {
        get;
    } = [];

    public ObservableCollection<ProviderTemplate> ProviderTemplates { get; } =
        [];

    public ObservableCollection<ProviderConnection> ProviderConnections
    {
        get;
    } = [];

    public ObservableCollection<ConnectionFieldEditor> ConnectionFields
    {
        get;
    } = [];

    public ObservableCollection<ModelRoute> ModelRoutes { get; } = [];

    public ObservableCollection<GenerationPreset> GenerationPresets
    {
        get;
    } = [];

    public ObservableCollection<ProviderParameterEditor> ParameterEditors
    {
        get;
    } = [];

    public ObservableCollection<CapabilityDisplayItem> Capabilities { get; } =
        [];

    public ObservableCollection<ProviderProgressItem> DiscoveryProgress
    {
        get;
    } = [];

    public ObservableCollection<ModelSyncReviewItem> ModelSyncReview { get; } =
        [];

    public ObservableCollection<ProviderCatalogRevisionItem> CatalogRevisions
    {
        get;
    } = [];

    public ObservableCollection<ModelSyncReviewItem> CatalogReview { get; } =
        [];

    public ObservableCollection<string> ReasoningModes { get; } = [];

    public ObservableCollection<string> ReasoningEfforts { get; } = [];

    public ObservableCollection<string> ReasoningSummaries { get; } = [];

    public ObservableCollection<string> PromptCacheModes { get; } = [];

    public ObservableCollection<string> PromptCacheTtls { get; } = [];

    public string AbiVersion
    {
        get => abiVersion;
        private set => SetProperty(ref abiVersion, value);
    }

    public string CoreVersion
    {
        get => coreVersion;
        private set => SetProperty(ref coreVersion, value);
    }

    public string Database
    {
        get => database;
        private set => SetProperty(ref database, value);
    }

    public string DataRoot
    {
        get => dataRoot;
        private set => SetProperty(ref dataRoot, value);
    }

    public string Staging
    {
        get => staging;
        private set => SetProperty(ref staging, value);
    }

    public string Recovery
    {
        get => recovery;
        private set => SetProperty(ref recovery, value);
    }

    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public string ProviderStatus
    {
        get => providerStatus;
        private set => SetProperty(ref providerStatus, value);
    }

    public ProviderSetupModeOption? SelectedSetupMode
    {
        get => selectedSetupMode;
        set
        {
            if (IsBusy)
            {
                return;
            }

            if (SetProperty(ref selectedSetupMode, value))
            {
                OnPropertyChanged(nameof(SelectedSetupDescription));
                OnPropertyChanged(nameof(IsDirectConnectionMode));
                OnPropertyChanged(nameof(CanSaveConnection));
                OnPropertyChanged(
                    nameof(CanChooseProviderTemplate));
                OnPropertyChanged(nameof(IsDiscoveryMode));
                OnPropertyChanged(nameof(IsWebsiteDiscoveryMode));
                OnPropertyChanged(nameof(IsCurlDiscoveryMode));
                OnPropertyChanged(nameof(IsCurlInputEnabled));
                OnPropertyChanged(
                    nameof(IsConnectionNetworkEditable));
                OnPropertyChanged(
                    nameof(CanEditLocalNetworkApproval));
                NotifyAssistantRouteState();
                BeginNewConnection();
                if (value?.Mode == ProviderSetupMode.LocalServer)
                {
                    ApiOrigin = "http://127.0.0.1:11434";
                    SelectedNetworkMode = FindNetworkMode(
                        ProviderNetworkMode.LocalLoopback);
                }
            }
        }
    }

    public string SelectedSetupDescription =>
        SelectedSetupMode?.Description ?? string.Empty;

    public bool IsDirectConnectionMode =>
        SelectedSetupMode?.Mode is
            ProviderSetupMode.KnownProvider or
            ProviderSetupMode.LocalServer;

    public bool CanSaveConnection =>
        IsDirectConnectionMode && !IsBusy;

    public bool CanChangeProviderSelection => !IsBusy;

    public bool CanChooseProviderTemplate =>
        IsDirectConnectionMode && !IsBusy;

    public bool CanRemoveSelectedCredential =>
        SelectedConnection is not null && !IsBusy;

    public bool CanRefreshModels =>
        SelectedConnection is not null
        && activeModelSyncJobId is null
        && !IsBusy;

    public bool CanApproveModelSync =>
        activeModelSyncJobId is not null
        && activeModelSyncReviewSha256 is not null
        && !IsBusy;

    public bool CanCancelModelSync =>
        activeModelSyncJobId is not null
        && !isModelSyncCancellationInProgress;

    public bool IsWebsiteDiscoveryMode =>
        SelectedSetupMode?.Mode ==
        ProviderSetupMode.WebsiteDiscovery;

    public bool IsCurlDiscoveryMode =>
        SelectedSetupMode?.Mode ==
        ProviderSetupMode.CurlExample;

    public bool IsDiscoveryMode =>
        IsWebsiteDiscoveryMode || IsCurlDiscoveryMode;

    public ProviderNetworkModeOption? SelectedNetworkMode
    {
        get => selectedNetworkMode;
        set
        {
            if (SetProperty(ref selectedNetworkMode, value))
            {
                LocalNetworkAccessApproved = false;
                if (value?.Mode !=
                    ProviderNetworkMode.ApprovedLocalNetwork)
                {
                    LocalNetworkOrigin = string.Empty;
                    LocalNetworkAddresses = string.Empty;
                }
                OnPropertyChanged(
                    nameof(SelectedNetworkDescription));
                OnPropertyChanged(
                    nameof(IsApprovedLocalNetworkMode));
                OnPropertyChanged(
                    nameof(CanEditLocalNetworkApproval));
            }
        }
    }

    public string SelectedNetworkDescription =>
        SelectedNetworkMode?.Description ?? string.Empty;

    public bool IsApprovedLocalNetworkMode =>
        SelectedNetworkMode?.Mode ==
        ProviderNetworkMode.ApprovedLocalNetwork;

    public bool IsConnectionNetworkEditable =>
        SelectedConnection is null && IsDirectConnectionMode;

    public bool CanEditLocalNetworkApproval =>
        IsConnectionNetworkEditable
        && IsApprovedLocalNetworkMode;

    public ProviderTemplate? SelectedTemplate
    {
        get => selectedTemplate;
        set
        {
            if (IsBusy)
            {
                return;
            }

            SetSelectedTemplate(value);
        }
    }

    public ProviderConnection? SelectedConnection
    {
        get => selectedConnection;
        private set
        {
            if (SetProperty(ref selectedConnection, value))
            {
                if (!OpaqueReasoningContinuityAllowed
                    && preserveOpaqueReasoningState)
                {
                    preserveOpaqueReasoningState = false;
                    OnPropertyChanged(
                        nameof(PreserveOpaqueReasoningState));
                }
                OnPropertyChanged(
                    nameof(IsConnectionNetworkEditable));
                OnPropertyChanged(
                    nameof(CanEditLocalNetworkApproval));
                OnPropertyChanged(
                    nameof(CanPreserveOpaqueReasoningState));
                OnPropertyChanged(
                    nameof(CanRemoveSelectedCredential));
                NotifyModelSyncActionState();
            }
        }
    }

    public ModelRoute? SelectedModelRoute
    {
        get => selectedModelRoute;
        private set => SetProperty(ref selectedModelRoute, value);
    }

    public GenerationPreset? SelectedGenerationPreset
    {
        get => selectedGenerationPreset;
        private set => SetProperty(ref selectedGenerationPreset, value);
    }

    public GenerationPreset? SelectedDefaultPreset
    {
        get => selectedDefaultPreset;
        set => SetProperty(ref selectedDefaultPreset, value);
    }

    public AssistantModelRouteOption? SelectedAssistantModelRoute
    {
        get => selectedAssistantModelRoute;
        set
        {
            if (!CanEditAssistantModelRoute)
            {
                return;
            }

            var current = value is null
                ? null
                : AssistantModelRoutes.FirstOrDefault(
                    route => string.Equals(
                            route.ConnectionId,
                            value.ConnectionId,
                            StringComparison.Ordinal)
                        && string.Equals(
                            route.Id,
                            value.Id,
                            StringComparison.Ordinal));
            SetSelectedAssistantModelRoute(current);
        }
    }

    public string AssistantModelRouteSelectionSummary
    {
        get => assistantModelRouteSelectionSummary;
        private set => SetProperty(
            ref assistantModelRouteSelectionSummary,
            value);
    }

    public string ConnectionId
    {
        get => connectionId;
        set
        {
            if (SetProperty(ref connectionId, value)
                && credentialDraft.ConnectionIdChanged(value))
            {
                ProviderStatus =
                    "The connection ID changed after credential entry. Re-enter the credential before saving.";
            }
        }
    }

    public string ConnectionDisplayName
    {
        get => connectionDisplayName;
        set => SetProperty(ref connectionDisplayName, value);
    }

    public string ApiOrigin
    {
        get => apiOrigin;
        set
        {
            if (SetProperty(ref apiOrigin, value))
            {
                CredentialOriginApproved = false;
                LocalNetworkAccessApproved = false;
            }
        }
    }

    public string ApiBasePath
    {
        get => apiBasePath;
        set => SetProperty(ref apiBasePath, value);
    }

    public string LocalNetworkOrigin
    {
        get => localNetworkOrigin;
        set
        {
            if (SetProperty(ref localNetworkOrigin, value))
            {
                LocalNetworkAccessApproved = false;
            }
        }
    }

    public string LocalNetworkAddresses
    {
        get => localNetworkAddresses;
        set
        {
            if (SetProperty(ref localNetworkAddresses, value))
            {
                LocalNetworkAccessApproved = false;
            }
        }
    }

    public string TimeoutSeconds
    {
        get => timeoutSeconds;
        set => SetProperty(ref timeoutSeconds, value);
    }

    public string SiteUrl
    {
        get => siteUrl;
        set => SetProperty(ref siteUrl, value);
    }

    public string AdditionalEvidenceUrl
    {
        get => additionalEvidenceUrl;
        set => SetProperty(ref additionalEvidenceUrl, value);
    }

    public ProviderDiscoveryCandidateItem?
        SelectedDiscoveryCandidate
    {
        get => selectedDiscoveryCandidate;
        set => SetProperty(
            ref selectedDiscoveryCandidate,
            value);
    }

    public ProviderDiscoveryResolutionOption?
        SelectedDiscoveryResolution
    {
        get => selectedDiscoveryResolution;
        set
        {
            if (SetProperty(
                    ref selectedDiscoveryResolution,
                    value))
            {
                OnPropertyChanged(
                    nameof(DiscoveryActionSummary));
            }
        }
    }

    public string UnknownOutcomeConnectionId
    {
        get => unknownOutcomeConnectionId;
        set => SetProperty(
            ref unknownOutcomeConnectionId,
            value);
    }

    public string DiscoveryActionSummary
    {
        get => discoveryActionSummary;
        private set => SetProperty(
            ref discoveryActionSummary,
            value);
    }

    public bool HasActiveDiscovery =>
        activeDiscovery is not null
        && activeDiscovery.State is not
            ("ready" or "failed" or "cancelled");

    public bool CanEditAssistantModelRoute =>
        IsDiscoveryMode
        && !HasActiveDiscovery
        && !HasPendingDiscoveryStart
        && !IsBusy;

    public bool CanEnableAssistantRequest =>
        CanEditAssistantModelRoute
        && SelectedAssistantModelRoute is not null;

    public bool CanStartDiscovery =>
        !IsBusy
        && !HasActiveDiscovery
        && !HasPendingDiscoveryStart;

    public bool CanSaveAppSettings =>
        !IsBusy
        && !HasActiveDiscovery
        && !HasPendingDiscoveryStart;

    public bool CanCancelProviderOperation =>
        HasActiveDiscovery
        || HasPendingDiscoveryStart
        || activeModelSyncJobId is not null;

    public bool CanContinueDiscovery =>
        activeDiscovery?.ActionRequired is { } action
        && action.Kind != "approve_assistant"
        && (action.Kind != "supply_more_evidence"
            || CanRequestAssistantForActiveDiscovery)
        && !IsBusy;

    public bool CanApproveAssistantGrant =>
        !IsBusy
        && TryGetReviewableAssistantGrant(
            out _,
            out var grant)
        && string.Equals(
            SelectedAssistantModelRoute?.Id,
            grant.AssistantModelRouteId,
            StringComparison.Ordinal)
        && AssistantModelRoutes.Any(route =>
            string.Equals(
                route.Id,
                grant.AssistantModelRouteId,
                StringComparison.Ordinal));

    public bool CanDeclineAssistantGrant =>
        !IsBusy
        && TryGetReviewableAssistantGrant(
            out _,
            out _);

    public bool CanCommitDiscovery =>
        activeDiscovery?.State == "committing";

    public bool CanSupplyDiscoveryEvidence =>
        activeDiscovery?.State == "awaiting_more_evidence"
        && activeDiscovery.AssistantResumeBoundary?.Action is
            null or
            ProviderDiscoveryAssistantResumeAction.SupplyMoreEvidence;

    public bool CanAcceptAssistantDraft =>
        activeAssistantAction is
        {
            Kind: "review_draft",
            DraftReview.UnresolvedConflicts.Count: 0,
            DraftReview.Draft.UnresolvedQuestions.Count: 0,
        };

    public bool CanRequestAssistantRevision =>
        activeAssistantAction is
        {
            Kind: "review_draft",
            DraftReview: not null,
        };

    public bool CanRetryAssistant =>
        assistantRetryAvailable
        && activeDiscovery?.State ==
            "building_assistant_manifest_draft"
        && (activeAssistantResumeAction ==
                ProviderDiscoveryAssistantResumeAction.ResumeCoreHostAction
            || (activeAssistantGrant is not null
                && activeAssistantResumeAction is
                    ProviderDiscoveryAssistantResumeAction.RunAssistant or
                    ProviderDiscoveryAssistantResumeAction.ApproveRetry));

    public bool IsCurlInputEnabled =>
        IsCurlDiscoveryMode
        || CanSupplyDiscoveryEvidence;

    public bool AssistantConsentRequested
    {
        get => assistantConsentRequested;
        set
        {
            if (HasActiveDiscovery || HasPendingDiscoveryStart)
            {
                return;
            }
            if (value
                && SelectedAssistantModelRoute is null)
            {
                assistantConsentRequested = false;
                OnPropertyChanged(
                    nameof(AssistantConsentRequested));
                return;
            }

            if (SetProperty(
                    ref assistantConsentRequested,
                    value))
            {
                NotifyAssistantRouteState();
            }
        }
    }

    private bool CanRequestAssistantForActiveDiscovery =>
        assistantConsentRequested
        && activeDiscoveryAssistantRouteId is { } routeId
        && string.Equals(
            SelectedAssistantModelRoute?.Id,
            routeId,
            StringComparison.Ordinal)
        && AssistantModelRoutes.Any(route =>
            string.Equals(
                route.Id,
                routeId,
                StringComparison.Ordinal));

    private bool TryGetReviewableAssistantGrant(
        out ProviderDiscoverySnapshot? snapshot,
        out ProviderDiscoveryApprovalGrant grant)
    {
        snapshot = activeDiscovery;
        var proposal = snapshot?.ApprovalProposal;
        if (snapshot?.ActionRequired?.Kind !=
                "approve_assistant"
            || proposal?.Grant is not
            {
                Kind: "assistant_consent",
                AssistantModelRouteId.Length: > 0,
                EvidenceIds: not null,
                AllowedDocumentOrigins: not null,
                MaxCalls: > 0,
                MaxInputTokens: > 0,
                MaxOutputTokens: > 0,
                MaxToolCalls: > 0,
                MaxRetries: not null,
                MaxCostMicroUnits: > 0,
            } assistantGrant)
        {
            grant = new ProviderDiscoveryApprovalGrant();
            return false;
        }

        grant = assistantGrant;
        return true;
    }

    private bool TryValidateCurrentAssistantTarget(
        AssistantModelRouteOption target,
        out string? error)
    {
        try
        {
            var settings = core.GetSettings();
            if (!string.Equals(
                    settings.SelectedModelRouteId,
                    target.Id,
                    StringComparison.Ordinal)
                || !string.Equals(
                    settings.SelectedGenerationPresetId,
                    target.Preset.Id,
                    StringComparison.Ordinal))
            {
                error =
                    "The app-default model route or preset changed. Reload Settings before starting or approving assistant use.";
                return false;
            }

            var connectionMatches =
                core.ListProviderConnections()
                    .Where(connection => string.Equals(
                        connection.Id,
                        target.ConnectionId,
                        StringComparison.Ordinal))
                    .ToList();
            if (connectionMatches.Count != 1)
            {
                error =
                    "The app-default assistant connection no longer exists.";
                return false;
            }
            var connection = connectionMatches[0];
            var routeMatches =
                core.ListModelRoutes(connection.Id)
                    .Where(route =>
                        string.Equals(
                            route.Id,
                            target.Id,
                            StringComparison.Ordinal)
                        && string.Equals(
                            route.ConnectionId,
                            connection.Id,
                            StringComparison.Ordinal))
                    .ToList();
            if (routeMatches.Count != 1)
            {
                error =
                    "The app-default assistant route no longer has one exact connection binding.";
                return false;
            }
            if (routeMatches[0].Availability !=
                ModelAvailability.Available)
            {
                error =
                    "The app-default model route is not currently available.";
                return false;
            }

            var presetMatches =
                core.ListGenerationPresets(target.Id)
                    .Where(preset =>
                        string.Equals(
                            preset.Id,
                            target.Preset.Id,
                            StringComparison.Ordinal)
                        && string.Equals(
                            preset.ModelRouteId,
                            target.Id,
                            StringComparison.Ordinal))
                    .ToList();
            if (presetMatches.Count != 1)
            {
                error =
                    "The app-default generation preset no longer has one exact route binding.";
                return false;
            }
            core.ValidateGenerationPreset(
                target.Id,
                target.Preset.Id);
            if (connection.CredentialSlotRequired
                && credentials.Get(
                    connection.Id) is null)
            {
                error =
                    "The app-default assistant connection credential is unavailable.";
                return false;
            }
        }
        catch (Exception exception)
        {
            error = SafeError(
                "Could not validate the app-default assistant target.",
                exception);
            return false;
        }

        error = null;
        return true;
    }

    public bool CredentialOriginApproved
    {
        get => credentialOriginApproved;
        set => SetProperty(ref credentialOriginApproved, value);
    }

    public bool LocalNetworkAccessApproved
    {
        get => localNetworkAccessApproved;
        set => SetProperty(ref localNetworkAccessApproved, value);
    }

    public string PresetId
    {
        get => presetId;
        set
        {
            if (SetProperty(ref presetId, value))
            {
                MarkRequestPreviewStale();
            }
        }
    }

    public string PresetDisplayName
    {
        get => presetDisplayName;
        set
        {
            if (SetProperty(ref presetDisplayName, value))
            {
                MarkRequestPreviewStale();
            }
        }
    }

    public string ReasoningMode
    {
        get => reasoningMode;
        set
        {
            if (SetProperty(ref reasoningMode, value))
            {
                if (string.Equals(
                        reasoningMode,
                        "provider_default",
                        StringComparison.Ordinal))
                {
                    ClearProviderDefaultReasoningOverrides();
                }
                MarkRequestPreviewStale();
                SchedulePresetControlRefresh();
            }
        }
    }

    public string ReasoningEffort
    {
        get => reasoningEffort;
        set
        {
            if (SetProperty(ref reasoningEffort, value))
            {
                MarkRequestPreviewStale();
                SchedulePresetControlRefresh();
            }
        }
    }

    public string ReasoningBudgetTokens
    {
        get => reasoningBudgetTokens;
        set
        {
            if (SetProperty(ref reasoningBudgetTokens, value))
            {
                MarkRequestPreviewStale();
                SchedulePresetControlRefresh();
            }
        }
    }

    public string ReasoningSummary
    {
        get => reasoningSummary;
        set
        {
            if (SetProperty(ref reasoningSummary, value))
            {
                MarkRequestPreviewStale();
                SchedulePresetControlRefresh();
            }
        }
    }

    public bool PreserveOpaqueReasoningState
    {
        get => preserveOpaqueReasoningState;
        set
        {
            if (SetProperty(
                    ref preserveOpaqueReasoningState,
                    value && OpaqueReasoningContinuityAllowed))
            {
                MarkRequestPreviewStale();
                SchedulePresetControlRefresh();
            }
        }
    }

    public bool CanPreserveOpaqueReasoningState =>
        ReasoningControlsEnabled
        && OpaqueReasoningContinuityAllowed;

    public string PromptCacheMode
    {
        get => promptCacheMode;
        set
        {
            if (SetProperty(ref promptCacheMode, value))
            {
                MarkRequestPreviewStale();
                SchedulePresetControlRefresh();
            }
        }
    }

    public string PromptCacheTtl
    {
        get => promptCacheTtl;
        set
        {
            if (SetProperty(ref promptCacheTtl, value))
            {
                MarkRequestPreviewStale();
                OnPropertyChanged(
                    nameof(PromptCacheCustomTtlEnabled));
                SchedulePresetControlRefresh();
            }
        }
    }

    public string PromptCacheCustomSeconds
    {
        get => promptCacheCustomSeconds;
        set
        {
            if (SetProperty(
                    ref promptCacheCustomSeconds,
                    value))
            {
                MarkRequestPreviewStale();
                SchedulePresetControlRefresh();
            }
        }
    }

    public string PromptCacheContextReference
    {
        get => promptCacheContextReference;
        set
        {
            if (SetProperty(
                    ref promptCacheContextReference,
                    value))
            {
                MarkRequestPreviewStale();
                SchedulePresetControlRefresh();
            }
        }
    }

    public string RequestPreview
    {
        get => requestPreview;
        private set => SetProperty(ref requestPreview, value);
    }

    public string PresetControlStatus
    {
        get => presetControlStatus;
        private set => SetProperty(
            ref presetControlStatus,
            value);
    }

    public string CatalogStatus
    {
        get => catalogStatus;
        private set => SetProperty(ref catalogStatus, value);
    }

    public ProviderCatalogRevisionItem? SelectedCatalogRevision
    {
        get => selectedCatalogRevision;
        set
        {
            if (SetProperty(ref selectedCatalogRevision, value))
            {
                ClearPendingCatalogImport();
                pendingCatalogRollbackPlan = null;
                CatalogReview.Clear();
            }
        }
    }

    public bool PreservePartialGenerations
    {
        get => preservePartialGenerations;
        set => SetProperty(ref preservePartialGenerations, value);
    }

    public bool HasPendingCatalogImport =>
        pendingCatalogImportPlan is not null
        && pendingCatalogEnvelopeBytes is not null;

    public bool ReasoningControlsEnabled
    {
        get => reasoningControlsEnabled;
        private set
        {
            if (SetProperty(
                    ref reasoningControlsEnabled,
                    value))
            {
                OnPropertyChanged(
                    nameof(CanPreserveOpaqueReasoningState));
            }
        }
    }

    public bool PromptCacheControlsEnabled
    {
        get => promptCacheControlsEnabled;
        private set => SetProperty(
            ref promptCacheControlsEnabled,
            value);
    }

    public bool ReasoningEffortEnabled
    {
        get => reasoningEffortEnabled;
        private set => SetProperty(
            ref reasoningEffortEnabled,
            value);
    }

    public bool ReasoningBudgetEnabled
    {
        get => reasoningBudgetEnabled;
        private set => SetProperty(
            ref reasoningBudgetEnabled,
            value);
    }

    public bool ReasoningSummaryEnabled
    {
        get => reasoningSummaryEnabled;
        private set => SetProperty(
            ref reasoningSummaryEnabled,
            value);
    }

    public bool PromptCacheTtlEnabled
    {
        get => promptCacheTtlEnabled;
        private set
        {
            if (SetProperty(
                    ref promptCacheTtlEnabled,
                    value))
            {
                OnPropertyChanged(
                    nameof(PromptCacheCustomTtlEnabled));
            }
        }
    }

    public bool PromptCacheCustomTtlEnabled =>
        PromptCacheTtlEnabled
        && promptCacheSupportsCustomTtl
        && string.Equals(
            PromptCacheTtl,
            "custom_seconds",
            StringComparison.Ordinal);

    public bool PromptCacheContextReferenceEnabled
    {
        get => promptCacheContextReferenceEnabled;
        private set => SetProperty(
            ref promptCacheContextReferenceEnabled,
            value);
    }

    public bool IsBusy
    {
        get => isBusy
            || isDiscoveryCancellationInProgress
            || isModelSyncCancellationInProgress;
        private set
        {
            if (SetProperty(ref isBusy, value))
            {
                OnPropertyChanged(nameof(CanSaveConnection));
                OnPropertyChanged(
                    nameof(CanRemoveSelectedCredential));
                NotifyProviderSelectionActionState();
                NotifyModelSyncActionState();
                NotifyAssistantRouteState();
                NotifyAssistantGrantActionState();
            }
        }
    }

    private bool IsDiscoveryCancellationInProgress
    {
        get => isDiscoveryCancellationInProgress;
        set
        {
            if (isDiscoveryCancellationInProgress == value)
            {
                return;
            }

            isDiscoveryCancellationInProgress = value;
            NotifyCancellationBusyState();
        }
    }

    private bool IsModelSyncCancellationInProgress
    {
        get => isModelSyncCancellationInProgress;
        set
        {
            if (isModelSyncCancellationInProgress == value)
            {
                return;
            }

            isModelSyncCancellationInProgress = value;
            NotifyCancellationBusyState();
        }
    }

    private void NotifyCancellationBusyState()
    {
        OnPropertyChanged(nameof(IsBusy));
        OnPropertyChanged(nameof(CanSaveConnection));
        OnPropertyChanged(
            nameof(CanRemoveSelectedCredential));
        NotifyProviderSelectionActionState();
        NotifyModelSyncActionState();
    }

    private void NotifyProviderSelectionActionState()
    {
        OnPropertyChanged(
            nameof(CanChangeProviderSelection));
        OnPropertyChanged(
            nameof(CanChooseProviderTemplate));
    }

    private void NotifyModelSyncActionState()
    {
        OnPropertyChanged(nameof(CanRefreshModels));
        OnPropertyChanged(nameof(CanApproveModelSync));
        OnPropertyChanged(nameof(CanCancelModelSync));
        OnPropertyChanged(
            nameof(CanCancelProviderOperation));
    }

    private void NotifyAssistantRouteState()
    {
        OnPropertyChanged(
            nameof(CanEditAssistantModelRoute));
        OnPropertyChanged(
            nameof(CanEnableAssistantRequest));
        OnPropertyChanged(nameof(CanStartDiscovery));
        OnPropertyChanged(nameof(CanSaveAppSettings));
    }

    private void NotifyAssistantGrantActionState()
    {
        OnPropertyChanged(
            nameof(CanApproveAssistantGrant));
        OnPropertyChanged(
            nameof(CanDeclineAssistantGrant));
        OnPropertyChanged(nameof(CanContinueDiscovery));
    }

    private long CaptureSettingsLifecycleEpoch() =>
        Volatile.Read(ref settingsLifecycleEpoch);

    private bool IsSettingsLifecycleCurrent(
        long expectedEpoch) =>
        expectedEpoch ==
        Volatile.Read(ref settingsLifecycleEpoch);

    private void InvalidateSettingsLifecycle() =>
        Interlocked.Increment(ref settingsLifecycleEpoch);

    internal async Task RefreshAsync()
    {
        if (IsBusy)
        {
            return;
        }

        var lifecycleEpoch =
            CaptureSettingsLifecycleEpoch();
        IsBusy = true;
        Status = "Checking native core…";
        ProviderStatus = "Loading provider connections…";
        try
        {
            if (!discoveryRecoveryPerformed)
            {
                await Task.Run(() =>
                    core.RecoverProviderDiscoveries());
                if (!IsSettingsLifecycleCurrent(
                        lifecycleEpoch))
                {
                    return;
                }
                discoveryRecoveryPerformed = true;
            }
            var state = await Task.Run(() => (
                core.AbiVersion,
                Version: core.GetCoreVersion(),
                Health: core.GetHealthCheck(),
                Templates: core.ListProviderTemplates(),
                Connections: core.ListProviderConnections(),
                Settings: core.GetSettings(),
                CatalogStatus: core.GetProviderCatalogStatus(),
                CatalogHistory:
                    core.GetProviderCatalogHistory(limit: 50),
                Discoveries:
                    core.ListProviderDiscoveries(limit: 32)));
            if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                return;
            }

            AbiVersion = state.AbiVersion.ToString();
            CoreVersion = state.Version;
            Database = state.Health.DatabaseOpen
                ? $"Open · schema {state.Health.SchemaVersion}"
                : "Closed";
            DataRoot = state.Health.DataRootWritable
                ? "Writable"
                : "Not writable";
            Staging = state.Health.StagingWritable
                ? "Writable"
                : "Not writable";
            Recovery = state.Health.RecoveryPending
                ? "Pending"
                : "Clear";
            Status = $"Healthy · {state.Health.ActiveJobs} active job(s)";
            ReplaceTemplates(state.Templates);
            ReplaceConnections(state.Connections);
            PreservePartialGenerations =
                state.Settings.PreservePartialGenerations;
            ApplyCatalogStatus(
                state.CatalogStatus,
                state.CatalogHistory);
            var assistantRoutes = await Task.Run(() =>
                LoadAssistantModelRouteOptions(
                    state.Connections,
                    state.Settings.SelectedModelRouteId,
                    state.Settings
                        .SelectedGenerationPresetId));
            if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                return;
            }
            ReplaceAssistantModelRoutes(
                assistantRoutes);

            var selectedConnection = await FindConnectionForRouteAsync(
                state.Settings.SelectedModelRouteId);
            if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                return;
            }
            if (selectedConnection is not null)
            {
                await SelectConnectionCoreAsync(
                    selectedConnection,
                    lifecycleEpoch);
                if (!IsSettingsLifecycleCurrent(
                        lifecycleEpoch))
                {
                    return;
                }
                var route = ModelRoutes.FirstOrDefault(item =>
                    string.Equals(
                        item.Id,
                        state.Settings.SelectedModelRouteId,
                        StringComparison.Ordinal));
                if (route is not null)
                {
                    await SelectModelRouteAsync(
                        route,
                        lifecycleEpoch);
                    if (!IsSettingsLifecycleCurrent(
                            lifecycleEpoch))
                    {
                        return;
                    }
                    SelectedDefaultPreset =
                        GenerationPresets.FirstOrDefault(item =>
                            string.Equals(
                                item.Id,
                                state.Settings.SelectedGenerationPresetId,
                                StringComparison.Ordinal));
                }
            }

            var resumableDiscovery = state.Discoveries
                .Where(discovery =>
                    discovery.State is not
                        ("ready" or "failed" or "cancelled"))
                .OrderByDescending(discovery =>
                    discovery.UpdatedAt)
                .FirstOrDefault();
            if (resumableDiscovery is not null)
            {
                ApplyDiscoverySnapshot(resumableDiscovery);
                StartDiscoveryMonitoring(
                    resumableDiscovery.SessionId,
                    resumableDiscovery.PendingConnectionId,
                    lifecycleEpoch);
            }
            else if (activeModelSyncJobId is null)
            {
                if (SelectedConnection is null
                    && string.IsNullOrWhiteSpace(ConnectionId))
                {
                    BeginNewConnectionCore();
                }
                ProviderStatus = ProviderConnections.Count == 0
                    ? "No provider connection. Choose a template to add one."
                    : $"{ProviderConnections.Count} provider connection(s) stored locally.";
            }
        }
        catch (Exception exception)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                Status = SafeError(
                    "Could not load native core settings.",
                    exception);
                ProviderStatus =
                    "Could not load provider settings.";
            }
        }
        finally
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                IsBusy = false;
            }
        }
    }

    internal void BeginNewConnection()
    {
        if (IsBusy)
        {
            return;
        }

        BeginNewConnectionCore();
    }

    private void BeginNewConnectionCore()
    {
        StopModelSyncMonitoring();
        StopDiscoveryMonitoring(clearSnapshot: true);
        ClearAssistantBoundary();
        activeDiscoveryAssistantSessionId = null;
        activeDiscoveryAssistantRouteId = null;
        AssistantGrantReview.Clear();
        AssistantConsentRequested = false;
        credentialDraft.Invalidate();
        selectionGuard.MoveTo(null);
        SelectedConnection = null;
        SelectedModelRoute = null;
        SelectedGenerationPreset = null;
        ConnectionId = CreateConnectionId();
        ConnectionDisplayName =
            SelectedSetupMode?.Mode switch
            {
                ProviderSetupMode.WebsiteDiscovery =>
                    "Website provider",
                ProviderSetupMode.CurlExample =>
                    "cURL provider",
                ProviderSetupMode.LocalServer =>
                    "Local model server",
                _ => string.Empty,
            };
        ApiOrigin = string.Empty;
        ApiBasePath = string.Empty;
        LocalNetworkOrigin = string.Empty;
        LocalNetworkAddresses = string.Empty;
        LocalNetworkAccessApproved = false;
        SelectedNetworkMode =
            FindNetworkMode(ProviderNetworkMode.Public);
        TimeoutSeconds = "60";
        CredentialOriginApproved = false;
        ModelRoutes.Clear();
        GenerationPresets.Clear();
        effectiveParameterSpecs = [];
        ClearParameterEditors();
        Capabilities.Clear();
        ResetPresetControlPresentation();
        ModelSyncReview.Clear();
        RequestPreview =
            "Choose a model route and preset to request a Core-generated redacted preview.";

        if (IsDirectConnectionMode
            && SelectedTemplate is not null)
        {
            ApplyTemplate(SelectedTemplate);
        }
        else
        {
            ConnectionFields.Clear();
            ProviderStatus =
                "Review the display name. The connection ID and PasswordVault slot were generated internally.";
        }
    }

    internal void UpdateCredentialDraft(bool hasCredential)
    {
        credentialDraft.Update(hasCredential, ConnectionId);
    }

    internal void StopMonitoring()
    {
        InvalidateSettingsLifecycle();
        CancelPendingDiscoveryStart();
        StopModelSyncMonitoring();
        StopDiscoveryMonitoring(
            clearSnapshot: false);
        credentialDraft.Invalidate();
        ClearPendingCatalogImport();
        IsBusy = false;
    }

    internal async Task SelectConnectionAsync(
        ProviderConnection? connection)
    {
        if (IsBusy)
        {
            return;
        }

        await SelectConnectionCoreAsync(connection);
    }

    private Task SelectConnectionCoreAsync(
        ProviderConnection? connection) =>
        SelectConnectionCoreAsync(
            connection,
            CaptureSettingsLifecycleEpoch());

    private async Task SelectConnectionCoreAsync(
        ProviderConnection? connection,
        long lifecycleEpoch)
    {
        if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
        {
            return;
        }

        StopModelSyncMonitoring();
        credentialDraft.Invalidate();
        var token = selectionGuard.MoveTo(connection?.Id);
        SelectedConnection = connection;
        SelectedModelRoute = null;
        SelectedGenerationPreset = null;
        ModelRoutes.Clear();
        GenerationPresets.Clear();
        effectiveParameterSpecs = [];
        ClearParameterEditors();
        Capabilities.Clear();
        ResetPresetControlPresentation();
        ModelSyncReview.Clear();
        if (connection is null)
        {
            return;
        }

        ConnectionId = connection.Id;
        ConnectionDisplayName = connection.DisplayName;
        ApiOrigin = connection.ApiOrigin;
        ApiBasePath = connection.ApiBasePath ?? string.Empty;
        SelectedNetworkMode =
            FindNetworkMode(connection.NetworkMode);
        LocalNetworkOrigin =
            connection.LocalNetworkApproval?.Origin
            ?? string.Empty;
        LocalNetworkAddresses =
            connection.LocalNetworkApproval is { } approval
                ? string.Join(
                    Environment.NewLine,
                    approval.Addresses)
                : string.Empty;
        LocalNetworkAccessApproved =
            connection.LocalNetworkApproval is not null;
        TimeoutSeconds = connection.TimeoutSeconds.ToString();
        CredentialOriginApproved =
            connection.ApprovedCredentialOrigins.Any(origin =>
                string.Equals(
                    origin,
                    connection.ApiOrigin,
                    StringComparison.Ordinal));
        SetSelectedTemplate(ProviderTemplates.FirstOrDefault(template =>
            string.Equals(
                template.Id,
                connection.TemplateId,
                StringComparison.Ordinal)
            && template.ManifestVersion ==
                connection.TemplateVersion));
        LoadConnectionFields(SelectedTemplate, connection.Values);
        ProviderStatus = "Loading model routes…";
        try
        {
            var result = await Task.Run(() => (
                Routes: core.ListModelRoutes(connection.Id),
                Jobs: core.ListProviderModelSyncs(
                    connection.Id,
                    limit: 16)));
            if (!IsSettingsLifecycleCurrent(lifecycleEpoch)
                || !selectionGuard.IsCurrent(token))
            {
                return;
            }

            ReplaceRoutes(result.Routes);
            ProviderStatus = result.Routes.Count == 0
                ? "No model routes. Use “Refresh models” to query this connection."
                : $"{result.Routes.Count} model route(s) loaded. Credentials remain hidden.";
            var recoverableJob = result.Jobs.FirstOrDefault(job =>
                job.State is ModelSyncStates.Created
                    or ModelSyncStates.Fetching
                    or ModelSyncStates.Interrupted
                    or ModelSyncStates.DiffReadyAwaitingReview
                    or ModelSyncStates.Committing);
            if (recoverableJob is not null)
            {
                activeModelSyncJobId = recoverableJob.Id;
                ApplyModelSyncJob(recoverableJob);
                if (recoverableJob.State is
                    ModelSyncStates.Created or
                    ModelSyncStates.Fetching or
                    ModelSyncStates.Committing)
                {
                    modelSyncMonitoring =
                        new CancellationTokenSource();
                    _ = MonitorModelSyncAsync(
                        recoverableJob.Id,
                        token,
                        lifecycleEpoch,
                        modelSyncMonitoring.Token);
                }
            }
        }
        catch (Exception exception)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && selectionGuard.IsCurrent(token))
            {
                ProviderStatus = SafeError(
                    "Could not load model routes.",
                    exception);
            }
        }
    }

    internal async Task<bool> SaveConnectionAsync(string? credential)
    {
        if (IsBusy)
        {
            return false;
        }

        IsBusy = true;
        try
        {
            return await SaveConnectionCoreAsync(credential);
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task<bool> SaveConnectionCoreAsync(
        string? credential)
    {
        if (SelectedSetupMode?.Mode is
            ProviderSetupMode.WebsiteDiscovery or
            ProviderSetupMode.CurlExample)
        {
            ProviderStatus =
                "Use Start discovery for website or cURL setup so Core can retain the durable review state.";
            return false;
        }

        var template = SelectedTemplate;
        if (template is null)
        {
            ProviderStatus = "Choose a provider template.";
            return false;
        }

        if (!uint.TryParse(TimeoutSeconds, out var timeout)
            || timeout is 0 or > 600)
        {
            ProviderStatus =
                "Timeout must be a whole number from 1 to 600.";
            return false;
        }

        var id = ConnectionId.Trim();
        var displayName = ConnectionDisplayName.Trim();
        var origin = ApiOrigin.Trim();
        if (id.Length == 0
            || displayName.Length == 0
            || origin.Length == 0)
        {
            ProviderStatus =
                "Connection ID, display name, and API origin are required.";
            return false;
        }
        if (SelectedNetworkMode is not { } networkOption)
        {
            ProviderStatus =
                "Choose the connection network boundary.";
            return false;
        }
        if (!TryBuildLocalNetworkApproval(
                origin,
                networkOption.Mode,
                out var localNetworkApproval,
                out var networkError))
        {
            ProviderStatus = networkError
                ?? "The local-network approval is invalid.";
            return false;
        }
        if (SelectedConnection is { } selected
            && !string.Equals(
                selected.Id,
                id,
                StringComparison.Ordinal))
        {
            ProviderStatus =
                "An existing connection ID is immutable. Create a new connection instead.";
            return false;
        }
        if (SelectedConnection is { } existing
            && (!string.Equals(
                    existing.TemplateId,
                    template.Id,
                    StringComparison.Ordinal)
                || existing.TemplateVersion !=
                    template.ManifestVersion))
        {
            ProviderStatus =
                "An existing connection's provider template is immutable. Create a new connection for another template.";
            return false;
        }
        if (SelectedConnection is { } originBoundConnection
            && !string.Equals(
                originBoundConnection.ApiOrigin,
                origin,
                StringComparison.Ordinal))
        {
            ProviderStatus =
                "An existing connection's credential origin is immutable. Create a new connection for another origin.";
            return false;
        }
        if (SelectedConnection is { } networkBoundConnection
            && (networkBoundConnection.NetworkMode !=
                    networkOption.Mode
                || !LocalNetworkApprovalsEqual(
                    networkBoundConnection.LocalNetworkApproval,
                    localNetworkApproval)))
        {
            ProviderStatus =
                "An existing connection's network boundary and exact LAN approval are immutable. Create a new connection instead.";
            return false;
        }

        if (SelectedConnection is not null
            && !string.IsNullOrEmpty(credential))
        {
            credentialDraft.Invalidate();
            ProviderStatus =
                "Changing an existing connection's credential could cross provider accounts and reuse opaque state. Create a new connection ID, route, and preset instead; leave the field blank to retain the current credential.";
            return false;
        }

        if (template.RequiresCredential && !CredentialOriginApproved)
        {
            ProviderStatus =
                $"Approve the exact credential destination {origin} before saving.";
            return false;
        }

        if (!TryBuildConnectionValues(out var values, out var fieldError))
        {
            ProviderStatus = fieldError
                ?? "Provider connection fields are invalid.";
            return false;
        }

        var credentialWrite = credentialDraft.Capture(id, credential);
        if (!string.IsNullOrEmpty(credential)
            && credentialWrite is null)
        {
            ProviderStatus =
                "The credential could not be bound to the current connection ID. Re-enter it before saving.";
            return false;
        }
        if (credentialWrite is { } captured
            && !string.Equals(
                captured.ConnectionId,
                id,
                StringComparison.Ordinal))
        {
            ProviderStatus =
                "The credential target did not match the current connection ID.";
            return false;
        }

        var hasSavedCredential =
            !template.RequiresCredential || credentialWrite is not null;
        if (template.RequiresCredential && credentialWrite is null)
        {
            try
            {
                hasSavedCredential = credentials.Get(id) is not null;
            }
            catch
            {
                ProviderStatus =
                    "Windows PasswordVault could not be read. The connection was not changed.";
                return false;
            }
        }

        if (template.RequiresCredential
            && credentialWrite is null
            && !hasSavedCredential)
        {
            ProviderStatus = "This provider requires an API credential.";
            return false;
        }

        var token = selectionGuard.Capture();
        var existingConnection = SelectedConnection;
        ProviderConnection? saved = null;
        ProviderStatus = "Saving provider connection…";
        try
        {
            var replacement = credentialWrite?.Credential;
            await ProviderCredentialTransaction.PersistAsync(
                credentials,
                id,
                replacement,
                () => Task.Run(() =>
                {
                    if (existingConnection is null)
                    {
                        saved = core.CreateProviderConnection(
                            new ProviderConnectionDraft
                            {
                                Id = id,
                                TemplateId = template.Id,
                                TemplateVersion =
                                    template.ManifestVersion,
                                DisplayName = displayName,
                                ApiOrigin = origin,
                                ApiBasePath = NullIfBlank(ApiBasePath),
                                NetworkMode =
                                    networkOption.Mode,
                                LocalNetworkApproval =
                                    localNetworkApproval,
                                Values = values,
                                ApprovedCredentialOrigin =
                                    template.RequiresCredential
                                        ? origin
                                        : null,
                                TimeoutSeconds = timeout,
                            });
                    }
                    else
                    {
                        saved = core.UpsertProviderConnection(
                            existingConnection with
                            {
                                DisplayName = displayName,
                                ApiBasePath = NullIfBlank(ApiBasePath),
                                Values = values,
                                TimeoutSeconds = timeout,
                            },
                            credentialSlotReady:
                                template.RequiresCredential
                                && hasSavedCredential);
                    }

                    if (saved is null
                        || !string.Equals(
                            saved.Id,
                            id,
                            StringComparison.Ordinal))
                    {
                        throw new InvalidOperationException(
                            "Core returned a different provider connection ID.");
                    }
                }));
        }
        catch (ProviderCredentialCompensationException)
        {
            ProviderStatus =
                "Save failed and PasswordVault compensation also failed. The credential was not exposed; review the connection before retrying.";
            return false;
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not save provider connection.",
                exception);
            return false;
        }

        var savedConnection = saved
            ?? throw new InvalidOperationException(
                "Core did not return a provider connection.");
        try
        {
            var connections = await Task.Run(() =>
                core.ListProviderConnections());
            ReplaceConnections(connections);
            if (selectionGuard.IsCurrent(token))
            {
                await SelectConnectionCoreAsync(
                    ProviderConnections.First(item =>
                        string.Equals(
                            item.Id,
                            savedConnection.Id,
                            StringComparison.Ordinal)));
            }

            ProviderStatus =
                "Connection saved. The credential is stored only in Windows PasswordVault.";
            return true;
        }
        catch
        {
            UpsertConnectionLocally(savedConnection);
            if (selectionGuard.IsCurrent(token))
            {
                SelectedConnection = savedConnection;
            }
            ProviderStatus =
                "Connection and PasswordVault credential were saved, but the refreshed connection view could not be loaded. Reload settings to reconcile.";
            return true;
        }
    }

    internal async Task StartDiscoveryAsync(
        string? credential,
        string? curlExample,
        bool assistantConsent,
        bool probeConsent)
    {
        if (IsBusy || HasActiveDiscovery || HasPendingDiscoveryStart)
        {
            ProviderStatus =
                "Finish or cancel the current provider operation before starting discovery.";
            return;
        }

        var selection = selectionGuard.Capture();
        DiscoveryProgress.Clear();
        var mode = SelectedSetupMode?.Mode
            ?? ProviderSetupMode.KnownProvider;
        var id = ConnectionId.Trim();
        var displayName = ConnectionDisplayName.Trim();
        if (id.Length == 0 || displayName.Length == 0)
        {
            DiscoveryProgress.Add(new ProviderProgressItem(
                "!",
                "Discovery not started",
                "A generated connection ID and display name are required."));
            ProviderStatus =
                "Enter a connection display name before starting discovery.";
            return;
        }

        if (!uint.TryParse(
                TimeoutSeconds,
                out var timeout)
            || timeout is 0 or > 600)
        {
            ProviderStatus =
                "Timeout must be a whole number from 1 to 600.";
            return;
        }
        if (!TryBuildConnectionValues(
                out var values,
                out var valuesError))
        {
            ProviderStatus = valuesError
                ?? "Provider connection fields are invalid.";
            return;
        }
        if (SelectedNetworkMode is not { } networkMode)
        {
            ProviderStatus =
                "Choose the connection network boundary.";
            return;
        }
        var originForGrant = ApiOrigin.Trim();
        if (!TryBuildLocalNetworkApproval(
                originForGrant,
                networkMode.Mode,
                out var localNetworkApproval,
                out var networkError))
        {
            ProviderStatus = networkError
                ?? "The local-network approval is invalid.";
            return;
        }

        var siteUrl = NullIfBlank(SiteUrl);
        var rawCurl = string.IsNullOrWhiteSpace(curlExample)
            ? null
            : curlExample;
        ProviderDiscoverySource source;
        if (mode is ProviderSetupMode.KnownProvider
            or ProviderSetupMode.LocalServer)
        {
            if (SelectedTemplate is null)
            {
                ProviderStatus =
                    "Choose a provider template.";
                return;
            }
            source = new ProviderDiscoverySource
            {
                Kind = "known_provider",
                TemplateId = SelectedTemplate.Id,
            };
            rawCurl = null;
            siteUrl = null;
        }
        else if (mode == ProviderSetupMode.WebsiteDiscovery)
        {
            if (siteUrl is null)
            {
                ProviderStatus =
                    "Enter the official site or API-key page URL.";
                return;
            }
            source = new ProviderDiscoverySource
            {
                Kind = "site",
            };
            rawCurl = null;
        }
        else
        {
            if (rawCurl is null)
            {
                ProviderStatus =
                    "Paste an official cURL example.";
                return;
            }
            source = new ProviderDiscoverySource
            {
                Kind = "curl",
            };
        }

        var assistantTarget =
            (mode is ProviderSetupMode.WebsiteDiscovery
                or ProviderSetupMode.CurlExample)
            && assistantConsent
                ? SelectedAssistantModelRoute
                : null;
        if (assistantTarget is not null
            && !TryValidateCurrentAssistantTarget(
                assistantTarget,
                out var assistantTargetError))
        {
            SetSelectedAssistantModelRoute(null);
            DiscoveryProgress.Add(
                new ProviderProgressItem(
                    "!",
                    "Setup assistant unavailable",
                    assistantTargetError
                        ?? "The app-default assistant target is unavailable. Deterministic discovery will continue without it."));
            assistantTarget = null;
        }
        var assistantRouteId = assistantTarget?.Id;
        AssistantConsentRequested =
            assistantTarget is not null;
        probeConsentRequested = probeConsent;
        var options = new ProviderDiscoveryConnectionOptions
        {
            Values = values,
            ApiBasePath = NullIfBlank(ApiBasePath),
            TimeoutSeconds = timeout,
            NetworkMode = networkMode.Mode,
            LocalNetworkApproval = localNetworkApproval,
        };
        string? previousCredential;
        try
        {
            previousCredential = credentials.Get(id);
        }
        catch
        {
            ProviderStatus =
                "Windows PasswordVault could not be read. Discovery was not started.";
            return;
        }

        if (!TryBeginDiscoveryStart(
                out var operationEpoch,
                out var startCancellation))
        {
            ProviderStatus =
                "A provider discovery start is already in progress.";
            return;
        }

        var cancellationToken =
            startCancellation.Token;
        var credentialChanged = false;
        var beginInvoked = false;
        IsBusy = true;
        ProviderStatus =
            "Starting durable provider discovery…";
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (source.Kind == "curl")
            {
                var inspection = await Task.Run(() =>
                    core.InspectProviderCurl(
                        rawCurl!,
                        options,
                        extractedCredential =>
                        {
                            if (!string.IsNullOrEmpty(
                                    credential)
                                && !string.Equals(
                                    credential,
                                    extractedCredential,
                                    StringComparison.Ordinal))
                            {
                                throw new InvalidOperationException(
                                    "The credential field and cURL contain different credentials.");
                            }
                            if (previousCredential is not null
                                && !string.Equals(
                                    previousCredential,
                                    extractedCredential,
                                    StringComparison.Ordinal))
                            {
                                throw new InvalidOperationException(
                                    "The generated PasswordVault slot already contains another credential. Remove it explicitly before importing a different cURL credential.");
                            }
                            credentials.Save(
                                id,
                                extractedCredential);
                            credentialChanged = true;
                        }),
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                ApiOrigin = inspection.ApiOrigin;
                SiteUrl = inspection.SanitizedSiteUrl;
                rawCurl = inspection.RedactedCurl;
                DiscoveryProgress.Add(
                    new ProviderProgressItem(
                        "✓",
                        "cURL inspected and redacted",
                        inspection.CredentialPresent
                            ? $"{inspection.Method} {inspection.ApiOrigin}{inspection.Path} · credential value copied directly to the exact generated PasswordVault slot."
                            : $"{inspection.Method} {inspection.ApiOrigin}{inspection.Path} · no credential value was present."));
            }

            if (!credentialChanged
                && !string.IsNullOrEmpty(credential))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (previousCredential is not null
                    && !string.Equals(
                        previousCredential,
                        credential,
                        StringComparison.Ordinal))
                {
                    throw new InvalidOperationException(
                        "The generated PasswordVault slot already contains another credential. Remove it explicitly before saving a replacement.");
                }
                credentials.Save(id, credential);
                credentialChanged = true;
            }
            cancellationToken.ThrowIfCancellationRequested();
            var slotReady = credentials.Get(id) is not null;
            var input = new ProviderDiscoveryInput
            {
                ConnectionId = id,
                DisplayName = displayName,
                SiteUrl = siteUrl,
                CredentialSlotReady = slotReady,
                PreferredAssistantModelRouteId =
                    assistantRouteId,
                ConnectionOptions = options,
            };
            cancellationToken.ThrowIfCancellationRequested();
            beginInvoked = true;
            var snapshot = await Task.Run(() =>
                core.BeginProviderDiscovery(
                    input,
                    source,
                    rawCurl));
            if (cancellationToken.IsCancellationRequested
                || !IsCurrentDiscoveryStart(
                    operationEpoch,
                    startCancellation)
                || !selectionGuard.IsCurrent(selection)
                || !string.Equals(
                    ConnectionId.Trim(),
                    id,
                    StringComparison.Ordinal))
            {
                await CancelAbandonedDiscoveryStartAsync(
                    snapshot);
                return;
            }

            credentialDraft.Invalidate();
            activeDiscoveryAssistantSessionId =
                snapshot.SessionId;
            activeDiscoveryAssistantRouteId =
                assistantRouteId;
            ApplyDiscoverySnapshot(snapshot);
            StartDiscoveryMonitoring(
                snapshot.SessionId,
                snapshot.PendingConnectionId);
        }
        catch (Exception exception)
        {
            activeDiscoveryAssistantSessionId = null;
            activeDiscoveryAssistantRouteId = null;
            if (credentialChanged && !beginInvoked)
            {
                try
                {
                    if (previousCredential is null)
                    {
                        credentials.Delete(id);
                    }
                    else
                    {
                        credentials.Save(
                            id,
                            previousCredential);
                    }
                }
                catch
                {
                    ProviderStatus =
                        "Discovery did not start and PasswordVault restoration had an unknown outcome. Reconcile the generated connection slot before retrying.";
                    DiscoveryProgress.Add(
                        new ProviderProgressItem(
                            "!",
                            "Credential restoration unknown",
                            "No automatic retry will run after an uncertain PasswordVault side effect."));
                    return;
                }
            }
            if (beginInvoked)
            {
                ProviderStatus =
                    "Provider discovery may have started, but its exact outcome could not be confirmed. It will not be retried automatically; reopen Settings to recover the durable session.";
            }
            else if (exception is OperationCanceledException
                     && cancellationToken
                         .IsCancellationRequested)
            {
                ProviderStatus =
                    "Provider discovery start cancelled before Core accepted a session.";
            }
            else
            {
                ProviderStatus =
                    exception is InvalidOperationException
                        ? exception.Message
                        : SafeError(
                            "Could not start provider discovery.",
                            exception);
            }
            DiscoveryProgress.Add(new ProviderProgressItem(
                "!",
                "Discovery not started",
                beginInvoked
                    ? "The native outcome is unknown; no automatic retry will run."
                    : "No non-secret discovery session was accepted by Core."));
        }
        finally
        {
            CompleteDiscoveryStart(
                operationEpoch,
                startCancellation);
            IsBusy = false;
        }
    }

    internal async Task CancelDiscoveryAsync()
    {
        credentialDraft.Invalidate();
        if (CancelPendingDiscoveryStart())
        {
            ProviderStatus =
                "Cancelling provider discovery as soon as the in-flight Core start returns…";
            return;
        }

        var snapshot = activeDiscovery;
        if (snapshot is not null
            && snapshot.State is not
                ("ready" or "failed" or "cancelled"))
        {
            if (IsDiscoveryCancellationInProgress)
            {
                return;
            }

            IsDiscoveryCancellationInProgress = true;
            try
            {
                await StopDiscoveryMonitoringAsync(
                    clearSnapshot: false);
                snapshot = activeDiscovery;
                if (snapshot is null
                    || snapshot.State is
                        "ready" or "failed" or "cancelled")
                {
                    return;
                }

                var cancelled = await Task.Run(() =>
                    core.CancelProviderDiscovery(
                        snapshot.SessionId,
                        snapshot.Revision,
                        snapshot.PendingConnectionId));
                if (!IsCurrentDiscoverySessionBinding(
                        snapshot.SessionId,
                        snapshot.PendingConnectionId))
                {
                    return;
                }
                ApplyDiscoverySnapshot(cancelled);
                if (cancelled.State == "compensating")
                {
                    await HandleDiscoveryCompensationAsync(
                        cancelled);
                }
            }
            catch (Exception exception)
            {
                ProviderStatus = SafeError(
                    "Could not cancel provider discovery.",
                    exception);
            }
            finally
            {
                IsDiscoveryCancellationInProgress = false;
            }
            return;
        }

        if (activeModelSyncJobId is not null)
        {
            await CancelModelSyncAsync();
            return;
        }

        ProviderStatus =
            "There is no active discovery session to cancel.";
    }

    internal async Task ContinueDiscoveryAsync()
    {
        var snapshot = activeDiscovery;
        if (snapshot?.ActionRequired is null
            || IsBusy)
        {
            return;
        }
        if (!TryBuildDiscoveryAction(
                snapshot,
                out var action,
                out var actionError)
            || action is null)
        {
            ProviderStatus = actionError
                ?? "The required discovery action is incomplete.";
            return;
        }

        await ContinueDiscoveryWithActionAsync(
            snapshot,
            action,
            assistantGrant: null);
    }

    internal async Task ApproveAssistantGrantAsync()
    {
        if (!CanApproveAssistantGrant
            || !TryGetReviewableAssistantGrant(
                out var snapshot,
                out var grant)
            || snapshot is null)
        {
            ProviderStatus =
                "The exact assistant grant cannot be approved. Verify that its named route is still available.";
            return;
        }
        var target = SelectedAssistantModelRoute;
        string? targetError = null;
        if (target is null
            || !TryValidateCurrentAssistantTarget(
                target,
                out targetError))
        {
            SetSelectedAssistantModelRoute(null);
            ProviderStatus = targetError
                ?? "The app-default assistant target is unavailable.";
            return;
        }

        await ContinueDiscoveryWithActionAsync(
            snapshot,
            new ProviderDiscoveryAction
            {
                Kind = "approve_assistant",
                ApprovalId =
                    snapshot.ApprovalProposal!.ApprovalId,
                ApprovalGrantSha256 =
                    snapshot.ApprovalProposal.GrantSha256,
            },
            grant);
    }

    internal async Task DeclineAssistantGrantAsync()
    {
        if (!CanDeclineAssistantGrant
            || activeDiscovery is not { } snapshot)
        {
            return;
        }

        assistantConsentRequested = false;
        OnPropertyChanged(
            nameof(AssistantConsentRequested));
        await ContinueDiscoveryWithActionAsync(
            snapshot,
            new ProviderDiscoveryAction
            {
                Kind = "decline_assistant",
            },
            assistantGrant: null);
    }

    private async Task ContinueDiscoveryWithActionAsync(
        ProviderDiscoverySnapshot snapshot,
        ProviderDiscoveryAction action,
        ProviderDiscoveryApprovalGrant? assistantGrant)
    {
        string? credential = null;
        if (snapshot.CredentialSlotExpected
            && snapshot.CredentialSlotId is { } slotId)
        {
            try
            {
                credential = credentials.Get(slotId);
            }
            catch
            {
                ProviderStatus =
                    "Windows PasswordVault could not be read. The discovery action was not sent.";
                return;
            }
        }

        IsBusy = true;
        try
        {
            var continued = await Task.Run(() =>
            {
                var envelope =
                    core.PrepareProviderDiscoveryAction(
                        Guid.NewGuid().ToString("N"),
                        snapshot.Revision,
                        action);
                return core.ContinueProviderDiscovery(
                    snapshot.SessionId,
                    envelope,
                    credential,
                    snapshot.PendingConnectionId);
            });
            ApplyDiscoverySnapshot(continued);
            if (assistantGrant is not null)
            {
                activeAssistantGrant = assistantGrant;
                await RunDiscoveryAssistantTurnAsync(
                    continued,
                    assistantGrant);
            }
            if (continued.State == "compensating")
            {
                await HandleDiscoveryCompensationAsync(
                    continued);
            }
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not continue provider discovery.",
                exception);
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task AcceptAssistantDraftAsync()
    {
        var snapshot = activeDiscovery;
        if (!CanAcceptAssistantDraft
            || snapshot is null
            || IsBusy)
        {
            return;
        }

        IsBusy = true;
        try
        {
            var updated = await Task.Run(() =>
                core.AcceptProviderDiscoveryAssistantDraft(
                    snapshot.SessionId));
            ClearAssistantBoundary();
            ApplyDiscoverySnapshot(updated);
            StartDiscoveryMonitoring(
                updated.SessionId,
                updated.PendingConnectionId);
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not accept the setup-assistant draft.",
                exception);
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task RequestAssistantRevisionAsync()
    {
        var snapshot = activeDiscovery;
        if (!CanRequestAssistantRevision
            || snapshot is null
            || IsBusy)
        {
            return;
        }

        var priorGrant = activeAssistantGrant;
        IsBusy = true;
        try
        {
            var updated = await Task.Run(() =>
                core.RequestProviderDiscoveryAssistantRevision(
                    snapshot.SessionId));
            activeAssistantAction = null;
            activeAssistantResumeAction =
                ProviderDiscoveryAssistantResumeAction.ApproveRetry;
            assistantRetryAvailable = true;
            ApplyDiscoverySnapshot(updated);
            if (updated.AssistantResumeBoundary is null)
            {
                activeAssistantResumeAction =
                    ProviderDiscoveryAssistantResumeAction.ApproveRetry;
                activeAssistantGrant = priorGrant;
                assistantRetryAvailable =
                    activeAssistantGrant is not null;
            }
            DiscoveryActionSummary =
                "Draft revision is waiting for one explicit assistant retry. The prior draft remains non-persistent.";
            NotifyAssistantActionState();
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not request a setup-assistant revision.",
                exception);
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task RetryAssistantAsync()
    {
        var snapshot = activeDiscovery;
        var grant = activeAssistantGrant;
        var resumeAction = activeAssistantResumeAction;
        if (!CanRetryAssistant
            || snapshot is null
            || IsBusy)
        {
            return;
        }

        IsBusy = true;
        try
        {
            if (resumeAction ==
                ProviderDiscoveryAssistantResumeAction.ResumeCoreHostAction)
            {
                var resumed = await Task.Run(() =>
                    core.ResumeProviderDiscoveryAssistantCoreHostAction(
                        snapshot.SessionId));
                ApplyDiscoverySnapshot(resumed);
                DiscoveryActionSummary =
                    "The pending allowlisted Core host action was resumed without a model call. Resume the assistant separately if the next boundary requests it.";
                return;
            }
            if (grant is null)
            {
                ProviderStatus =
                    "The durable assistant consent grant is unavailable. No model call was made.";
                return;
            }
            var updated =
                resumeAction ==
                ProviderDiscoveryAssistantResumeAction.ApproveRetry
                    ? await Task.Run(() =>
                        core.ApproveProviderDiscoveryAssistantRetry(
                            snapshot.SessionId))
                    : snapshot;
            assistantRetryAvailable = false;
            ApplyDiscoverySnapshot(updated);
            await RunDiscoveryAssistantTurnAsync(
                updated,
                grant);
        }
        catch (Exception exception)
        {
            assistantRetryAvailable = true;
            ProviderStatus = SafeError(
                "Could not retry the setup assistant.",
                exception);
            NotifyAssistantActionState();
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task RunDiscoveryAssistantTurnAsync(
        ProviderDiscoverySnapshot snapshot,
        ProviderDiscoveryApprovalGrant grant)
    {
        if (grant.Kind != "assistant_consent"
            || grant.AssistantModelRouteId is not { } routeId
            || grant.MaxInputTokens is not { } maxInputTokens
            || grant.MaxOutputTokens is not { } maxOutputTokens
            || grant.MaxCostMicroUnits is not { } maxCostMicroUnits)
        {
            ProviderStatus =
                "The exact setup-assistant grant is incomplete. No model call was made.";
            return;
        }

        var target = SelectedAssistantModelRoute;
        string? targetError = null;
        if (target is null
            || !string.Equals(
                target.Id,
                routeId,
                StringComparison.Ordinal)
            || !TryValidateCurrentAssistantTarget(
                target,
                out targetError))
        {
            SetSelectedAssistantModelRoute(null);
            ProviderStatus = targetError
                ?? "The approved setup-assistant target is no longer the executable app default. No model call was made.";
            return;
        }

        string? assistantConnectionId;
        try
        {
            assistantConnectionId =
                await FindConnectionIdForRouteAsync(routeId);
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not resolve the approved setup-assistant route.",
                exception);
            return;
        }
        if (assistantConnectionId is null)
        {
            ProviderStatus =
                "The approved setup-assistant route no longer exists. No model call was made.";
            return;
        }

        string? assistantCredential;
        try
        {
            assistantCredential =
                credentials.Get(assistantConnectionId);
        }
        catch
        {
            ProviderStatus =
                "Windows PasswordVault could not read the approved assistant route credential. No model call was made.";
            return;
        }

        try
        {
            var action = await Task.Run(() =>
                core.RunProviderDiscoveryAssistantTurn(
                    snapshot.SessionId,
                    new ProviderDiscoveryAssistantCallEstimate
                    {
                        InputTokens = maxInputTokens,
                        MaximumOutputTokens =
                            maxOutputTokens,
                        MaximumCostMicroUnits =
                            maxCostMicroUnits,
                    },
                    routeId,
                    assistantConnectionId,
                    assistantCredential));
            var latest = await Task.Run(() =>
                core.GetProviderDiscovery(
                    snapshot.SessionId,
                    snapshot.PendingConnectionId));
            assistantRetryAvailable = false;
            ApplyDiscoverySnapshot(latest);
            if (latest.AssistantResumeBoundary is null)
            {
                ApplyAssistantHostAction(action);
            }
        }
        catch (Exception exception)
        {
            try
            {
                var latest = await Task.Run(() =>
                    core.GetProviderDiscovery(
                        snapshot.SessionId,
                        snapshot.PendingConnectionId));
                ApplyDiscoverySnapshot(latest);
                assistantRetryAvailable =
                    latest.State ==
                    "building_assistant_manifest_draft";
            }
            catch
            {
                assistantRetryAvailable = true;
            }
            ProviderStatus = SafeError(
                "The setup-assistant turn stopped. Review the durable state before an explicit retry.",
                exception);
            NotifyAssistantActionState();
        }
    }

    private async Task<string?> FindConnectionIdForRouteAsync(
        string modelRouteId)
    {
        var loaded = ModelRoutes.FirstOrDefault(route =>
            string.Equals(
                route.Id,
                modelRouteId,
                StringComparison.Ordinal));
        if (loaded is not null)
        {
            return loaded.ConnectionId;
        }
        var connectionIds = ProviderConnections
            .Select(connection => connection.Id)
            .ToArray();
        return await Task.Run(() =>
        {
            foreach (var connectionId in connectionIds)
            {
                if (core.ListModelRoutes(connectionId).Any(route =>
                        string.Equals(
                            route.Id,
                            modelRouteId,
                            StringComparison.Ordinal)))
                {
                    return connectionId;
                }
            }
            return null;
        });
    }

    private void ApplyAssistantHostAction(
        ProviderDiscoveryAssistantHostAction action)
    {
        activeAssistantAction = action;
        if (action.Kind == "request_more_evidence")
        {
            activeAssistantResumeAction =
                ProviderDiscoveryAssistantResumeAction.SupplyMoreEvidence;
            foreach (var question in action.Questions ?? [])
            {
                DiscoveryProgress.Add(
                    new ProviderProgressItem(
                        "?",
                        question.Question,
                        question.RequiredEvidence));
            }
            DiscoveryActionSummary =
                "The assistant needs more official evidence. Add exactly one official document URL or inspected redacted cURL; no source is fetched implicitly.";
        }
        else if (action.Kind == "review_draft"
                 && action.DraftReview is { } review)
        {
            activeAssistantResumeAction =
                ProviderDiscoveryAssistantResumeAction.ReviewDraft;
            DiscoveryProgress.Add(
                new ProviderProgressItem(
                    "!",
                    "Assistant draft awaiting review",
                    review.Draft.Summary));
            DiscoveryProgress.Add(
                new ProviderProgressItem(
                    "i",
                    "Proposed provider protocol",
                    $"{review.Draft.Manifest.ApiFamily} · {review.Draft.Manifest.DefaultApiOrigin ?? "no default origin"} · {review.Draft.Manifest.Endpoints.Generate.Method} {review.Draft.Manifest.Endpoints.Generate.Path}"));
            foreach (var check in
                     review.Requirements.RequiredChecks)
            {
                DiscoveryProgress.Add(
                    new ProviderProgressItem(
                        "○",
                        "Required check",
                        check));
            }
            foreach (var question in
                     review.Draft.UnresolvedQuestions)
            {
                DiscoveryProgress.Add(
                    new ProviderProgressItem(
                        "?",
                        question.Question,
                        question.RequiredEvidence));
            }
            DiscoveryActionSummary =
                review.UnresolvedConflicts.Count == 0
                && review.Draft.UnresolvedQuestions.Count == 0
                    ? "Review the typed assistant draft. Accept runs Core validation; request revision keeps the draft non-persistent."
                    : "The assistant draft still has unresolved conflicts or questions and cannot be accepted.";
        }
        NotifyAssistantActionState();
    }

    private void ClearAssistantBoundary()
    {
        activeAssistantAction = null;
        activeAssistantGrant = null;
        activeAssistantResumeAction = null;
        assistantRetryAvailable = false;
        NotifyAssistantActionState();
    }

    private void NotifyAssistantActionState()
    {
        OnPropertyChanged(
            nameof(CanAcceptAssistantDraft));
        OnPropertyChanged(
            nameof(CanRequestAssistantRevision));
        OnPropertyChanged(
            nameof(CanRetryAssistant));
    }

    internal async Task SupplyDiscoveryEvidenceAsync(
        string? rawCurl)
    {
        var snapshot = activeDiscovery;
        if (snapshot?.State != "awaiting_more_evidence"
            || IsBusy)
        {
            ProviderStatus =
                "The current discovery state is not awaiting more evidence.";
            return;
        }
        var documentUrl =
            NullIfBlank(AdditionalEvidenceUrl);
        var curl = string.IsNullOrWhiteSpace(rawCurl)
            ? null
            : rawCurl;
        if ((documentUrl is null) == (curl is null))
        {
            ProviderStatus =
                "Supply exactly one document URL or one cURL example.";
            return;
        }

        var inspectionOptions =
            snapshot.ConnectionOptions;

        string? previousCredential = null;
        var credentialChanged = false;
        if (curl is not null
            && snapshot.CredentialSlotExpected
            && snapshot.CredentialSlotId is { } expectedSlot)
        {
            try
            {
                previousCredential =
                    credentials.Get(expectedSlot);
            }
            catch
            {
                ProviderStatus =
                    "Windows PasswordVault could not read the exact pending credential slot. The cURL was not inspected.";
                return;
            }
        }

        IsBusy = true;
        try
        {
            ProviderDiscoverySnapshot updated;
            if (documentUrl is not null)
            {
                updated = await Task.Run(() =>
                    core.SupplyProviderDiscoveryDocument(
                        snapshot.SessionId,
                        snapshot.Revision,
                        documentUrl,
                        snapshot.PendingConnectionId));
            }
            else
            {
                var inspection = await Task.Run(() =>
                    core.InspectProviderCurl(
                        curl!,
                        inspectionOptions,
                        extractedCredential =>
                        {
                            if (!snapshot.CredentialSlotExpected
                                || snapshot.CredentialSlotId is not
                                { } slotId
                                || !string.Equals(
                                    slotId,
                                    snapshot.PendingConnectionId,
                                    StringComparison.Ordinal))
                            {
                                throw new InvalidOperationException(
                                    "This discovery is credential-free. The extracted cURL credential was discarded; restart with a credential-bound setup if it is required.");
                            }
                            if (previousCredential is not null
                                && !string.Equals(
                                    previousCredential,
                                    extractedCredential,
                                    StringComparison.Ordinal))
                            {
                                throw new InvalidOperationException(
                                    "The exact pending PasswordVault slot already contains another credential. Remove it explicitly before importing a replacement.");
                            }
                            if (previousCredential is null)
                            {
                                credentials.Save(
                                    slotId,
                                    extractedCredential);
                                credentialChanged = true;
                            }
                        }));
                updated = await Task.Run(() =>
                    core.SupplyProviderDiscoveryCurl(
                        snapshot.SessionId,
                        snapshot.Revision,
                        inspection.RedactedCurl,
                        snapshot.PendingConnectionId));
                DiscoveryProgress.Add(
                    new ProviderProgressItem(
                        "✓",
                        "Supplemental cURL inspected",
                        inspection.CredentialPresent
                            ? "Only the redacted parseable cURL was supplied to discovery; its credential was handed to the exact pending PasswordVault slot."
                            : "Only the redacted parseable cURL was supplied to discovery."));
            }
            AdditionalEvidenceUrl = string.Empty;
            ApplyDiscoverySnapshot(updated);
        }
        catch (Exception exception)
        {
            if (credentialChanged
                && snapshot.CredentialSlotId is { } slotId)
            {
                try
                {
                    credentials.Delete(slotId);
                }
                catch
                {
                    ProviderStatus =
                        "The supplemental cURL was not accepted and PasswordVault rollback has an unknown outcome. Reconcile the exact pending slot before retrying.";
                    return;
                }
            }
            ProviderStatus =
                exception is InvalidOperationException
                    ? exception.Message
                    : SafeError(
                        "Could not add provider-discovery evidence.",
                        exception);
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task CommitDiscoveryAsync()
    {
        var snapshot = activeDiscovery;
        if (snapshot?.State != "committing"
            || IsBusy)
        {
            ProviderStatus =
                "Approve the exact discovery review before commit.";
            return;
        }

        var credentialConfirmed =
            !snapshot.CredentialSlotExpected;
        if (snapshot.CredentialSlotExpected
            && snapshot.CredentialSlotId is { } slotId)
        {
            try
            {
                credentialConfirmed =
                    credentials.Get(slotId) is not null;
            }
            catch
            {
                ProviderStatus =
                    "Windows PasswordVault could not confirm the exact credential slot. Nothing was committed.";
                return;
            }
        }
        if (!credentialConfirmed)
        {
            ProviderStatus =
                "The exact PasswordVault slot is missing. Re-enter the credential before commit.";
            return;
        }

        IsBusy = true;
        ProviderConnection? committed = null;
        try
        {
            committed = await Task.Run(() =>
                core.CommitProviderDiscovery(
                    snapshot.SessionId,
                    snapshot.PendingConnectionId,
                    credentialConfirmed));
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not commit provider discovery.",
                exception);
            IsBusy = false;
            return;
        }

        try
        {
            var refreshed = await Task.Run(() => (
                Snapshot:
                    core.GetProviderDiscovery(
                        snapshot.SessionId,
                        snapshot.PendingConnectionId),
                Connections:
                    core.ListProviderConnections()));
            ReplaceConnections(refreshed.Connections);
            ApplyDiscoverySnapshot(refreshed.Snapshot);
            ProviderStatus =
                $"Provider discovery committed connection {committed.Id}.";
        }
        catch
        {
            UpsertConnectionLocally(committed);
            ProviderStatus =
                "Provider discovery committed, but the refreshed connection view could not be loaded. Reload settings to reconcile.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private bool TryBuildDiscoveryAction(
        ProviderDiscoverySnapshot snapshot,
        out ProviderDiscoveryAction? action,
        out string? error)
    {
        var required = snapshot.ActionRequired?.Kind;
        switch (required)
        {
            case "select_template":
                action = SelectedDiscoveryCandidate is { } selected
                    ? new ProviderDiscoveryAction
                    {
                        Kind = "select_template",
                        CandidateId = selected.Id,
                    }
                    : new ProviderDiscoveryAction
                    {
                        Kind = "continue_without_template",
                    };
                error = null;
                return true;
            case "supply_more_evidence":
                if (!CanRequestAssistantForActiveDiscovery)
                {
                    action = null;
                    error = activeDiscoveryAssistantRouteId is null
                        ? "This restored session cannot prove which assistant route was frozen. Add official evidence, or cancel and restart discovery to choose a route."
                        : "The frozen setup-assistant route is unavailable. Add official evidence, or cancel and restart discovery.";
                    return false;
                }
                action = new ProviderDiscoveryAction
                {
                    Kind = "request_assistant",
                };
                error = null;
                return true;
            case "approve_assistant":
                action = null;
                error =
                    "Use the exact assistant grant approval or decline button after reviewing its model identity, origins, evidence IDs, budget, and digest.";
                return false;
            case "approve_credential_origin":
                if (!CredentialOriginApproved)
                {
                    action = null;
                    error =
                        $"Approve the exact credential destination {ApiOrigin} before continuing.";
                    return false;
                }
                if (snapshot.ApprovalProposal is not { } origin)
                {
                    action = null;
                    error =
                        "The exact credential-origin proposal is unavailable.";
                    return false;
                }
                action = new ProviderDiscoveryAction
                {
                    Kind = "approve_credential_origin",
                    ApprovalId = origin.ApprovalId,
                };
                error = null;
                return true;
            case "approve_probes":
                if (!probeConsentRequested)
                {
                    action = new ProviderDiscoveryAction
                    {
                        Kind = "skip_probes",
                    };
                    error = null;
                    return true;
                }
                if (snapshot.ApprovalProposal is not { } probes)
                {
                    action = null;
                    error =
                        "The exact capability-probe proposal is unavailable.";
                    return false;
                }
                action = new ProviderDiscoveryAction
                {
                    Kind = "approve_probes",
                    ApprovalId = probes.ApprovalId,
                    ApprovalGrantSha256 =
                        probes.GrantSha256,
                };
                error = null;
                return true;
            case "review":
                if (snapshot.ReviewProposal is not { } review)
                {
                    action = null;
                    error =
                        "The exact provider graph review proposal is unavailable.";
                    return false;
                }
                action = new ProviderDiscoveryAction
                {
                    Kind = "approve_review",
                    ApprovalId =
                        review.Approval.ApprovalId,
                    CommitAttemptId =
                        review.CommitAttemptId,
                    CommitPlanSha256 =
                        review.CommitPlanSha256,
                    GraphSha256 =
                        review.Review.GraphSha256,
                };
                error = null;
                return true;
            case "restart_interrupted":
                action = new ProviderDiscoveryAction
                {
                    Kind = "restart_interrupted",
                };
                error = null;
                return true;
            case "reconcile_unknown_outcome":
                if (SelectedDiscoveryResolution is not
                    { } resolution)
                {
                    action = null;
                    error =
                        "Choose an audited unknown-outcome resolution. No operation will be replayed automatically.";
                    return false;
                }
                if (snapshot.ApprovalProposal is not { } proposal)
                {
                    action = null;
                    error =
                        "The exact unknown-outcome proposal is unavailable.";
                    return false;
                }
                var connectionId =
                    resolution.Resolution ==
                    "confirmed_commit_completed"
                        ? NullIfBlank(
                            UnknownOutcomeConnectionId)
                        : null;
                if (resolution.Resolution ==
                        "confirmed_commit_completed"
                    && connectionId is null)
                {
                    action = null;
                    error =
                        "Enter the exact connection ID verified by the reconciliation audit.";
                    return false;
                }
                action = new ProviderDiscoveryAction
                {
                    Kind = "resolve_unknown_outcome",
                    ApprovalId = proposal.ApprovalId,
                    Resolution =
                        new ProviderDiscoveryUnknownResolution
                        {
                            Resolution =
                                resolution.Resolution,
                            ConnectionId = connectionId,
                        },
                };
                error = null;
                return true;
            default:
                action = null;
                error =
                    "The current discovery state has no supported user action.";
                return false;
        }
    }

    private void ApplyDiscoverySnapshot(
        ProviderDiscoverySnapshot snapshot)
    {
        if (activeDiscovery is { } current
            && string.Equals(
                current.SessionId,
                snapshot.SessionId,
                StringComparison.Ordinal)
            && !string.Equals(
                current.PendingConnectionId,
                snapshot.PendingConnectionId,
                StringComparison.Ordinal))
        {
            throw new CoreInteropException(
                "The provider-discovery response changed its immutable pending connection.");
        }

        activeDiscovery = snapshot;
        RestoreAssistantBoundary(snapshot);
        RestoreAssistantRouteBinding(snapshot);
        if (!string.Equals(
                ConnectionId,
                snapshot.PendingConnectionId,
                StringComparison.Ordinal))
        {
            ConnectionId =
                snapshot.PendingConnectionId;
        }
        if (!string.Equals(
                ConnectionDisplayName,
                snapshot.PendingDisplayName,
                StringComparison.Ordinal))
        {
            ConnectionDisplayName =
                snapshot.PendingDisplayName;
        }
        ApplyDiscoveryConnectionOptions(
            snapshot.ConnectionOptions);

        DiscoveryCandidates.Clear();
        foreach (var candidate in snapshot.Candidates)
        {
            DiscoveryCandidates.Add(
                new ProviderDiscoveryCandidateItem(
                    candidate));
        }
        SelectedDiscoveryCandidate =
            DiscoveryCandidates.FirstOrDefault();

        DiscoveryProgress.Clear();
        ApplyAssistantGrantReview(snapshot);
        foreach (var step in snapshot.Steps)
        {
            DiscoveryProgress.Add(
                new ProviderProgressItem(
                    step.State switch
                    {
                        "completed" => "✓",
                        "current" => "●",
                        _ => "○",
                    },
                    step.TitleKey,
                    step.State));
        }
        foreach (var evidence in snapshot.Evidence)
        {
            DiscoveryProgress.Add(
                new ProviderProgressItem(
                    "i",
                    $"Evidence · {evidence.Kind}",
                    $"{evidence.Id} · SHA-256 {evidence.ContentSha256}"));
        }
        if (snapshot.ApprovalProposal is { } proposal)
        {
            DiscoveryProgress.Add(
                new ProviderProgressItem(
                    "!",
                    $"Approval · {proposal.Grant.Kind}",
                    $"ID {proposal.ApprovalId} · exact grant {proposal.GrantSha256}"));
            if (proposal.Grant.Budget is { } budget)
            {
                var aggregateTokens =
                    (System.Numerics.BigInteger)
                    budget.MaxTotalTokensPerRequest
                    * budget.MaxRequests;
                var aggregateOutputTokens =
                    (System.Numerics.BigInteger)
                    budget.MaxOutputTokensPerRequest
                    * budget.MaxRequests;
                var aggregateCost =
                    (System.Numerics.BigInteger)
                    budget.MaxCostMicroUsdPerRequest
                    * budget.MaxRequests;
                var aggregateDuration =
                    (System.Numerics.BigInteger)
                    budget.MaxDurationMillisPerRequest
                    * budget.MaxRequests;
                DiscoveryProgress.Add(
                    new ProviderProgressItem(
                        "!",
                        "Exact capability-probe budget",
                        $"{budget.MaxRequests} request(s) · {budget.MaxCallsPerRequest} call(s)/request · ≤{aggregateTokens} total tokens ({aggregateOutputTokens} output) · ≤{aggregateCost} micro-USD · ≤{aggregateDuration} ms"));
            }
            if (proposal.Grant.Kind ==
                    "credential_origin"
                && proposal.Grant.Origin is { } origin
                && !string.Equals(
                    ApiOrigin,
                    origin,
                    StringComparison.Ordinal))
            {
                ApiOrigin = origin;
            }
        }
        if (snapshot.ReviewProposal is { } review)
        {
            DiscoveryProgress.Add(
                new ProviderProgressItem(
                    "!",
                    "Exact provider graph review",
                    $"{review.Review.Changes.Count} change(s) · review {review.Review.Sha256} · graph {review.Review.GraphSha256} · plan {review.CommitPlanSha256}"));
            if (review.RequestPreview is { } preview)
            {
                RequestPreview =
                    FormatRequestPreview(preview);
            }
            foreach (var change in review.Review.Changes)
            {
                DiscoveryProgress.Add(
                    new ProviderProgressItem(
                        change.Kind == "add"
                            ? "+"
                            : "△",
                        $"{change.Kind} {change.TargetKind}",
                        $"{change.TargetId} · {change.SummaryKey} · evidence {string.Join(", ", change.EvidenceIds)}"));
            }
        }
        if (snapshot.Failure is { } failure)
        {
            DiscoveryProgress.Add(
                new ProviderProgressItem(
                    "!",
                    failure.Code,
                    $"{failure.MessageKey} · recoverable={failure.Recoverable.ToString().ToLowerInvariant()}"));
        }

        DiscoveryActionSummary =
            BuildDiscoveryActionSummary(snapshot);
        if (activeAssistantAction is { } assistantAction)
        {
            ApplyAssistantHostAction(assistantAction);
        }
        ProviderStatus =
            $"Discovery {snapshot.SessionId} · state {snapshot.State} · revision {snapshot.Revision}.";
        OnPropertyChanged(nameof(HasActiveDiscovery));
        NotifyAssistantRouteState();
        NotifyAssistantGrantActionState();
        OnPropertyChanged(
            nameof(CanCancelProviderOperation));
        OnPropertyChanged(nameof(CanContinueDiscovery));
        OnPropertyChanged(nameof(CanCommitDiscovery));
        OnPropertyChanged(
            nameof(CanSupplyDiscoveryEvidence));
        OnPropertyChanged(nameof(IsCurlInputEnabled));
        NotifyAssistantActionState();

        if (snapshot.State is
            "ready" or "failed" or "cancelled")
        {
            StopDiscoveryMonitoring(
                clearSnapshot: false);
        }
    }

    private static string BuildDiscoveryActionSummary(
        ProviderDiscoverySnapshot snapshot)
    {
        var assistantSummary =
            snapshot.AssistantResumeBoundary?.Action switch
            {
                ProviderDiscoveryAssistantResumeAction.RunAssistant =>
                    "The approved setup assistant is ready. Resume it explicitly; no billable call is replayed on startup.",
                ProviderDiscoveryAssistantResumeAction.WaitForAssistantOutcome =>
                    "An approved assistant call was in flight. Wait for startup recovery; LorePia will not replay it automatically.",
                ProviderDiscoveryAssistantResumeAction.ResumeCoreHostAction =>
                    "An internal assistant host step was interrupted. Startup recovery must resolve it before any new model call.",
                ProviderDiscoveryAssistantResumeAction.SupplyMoreEvidence =>
                    "The setup assistant is waiting for one fresh official document or inspected redacted cURL.",
                ProviderDiscoveryAssistantResumeAction.ApproveRetry =>
                    "A retryable assistant failure is waiting for one explicit retry approval.",
                ProviderDiscoveryAssistantResumeAction.ReviewDraft =>
                    "The durable typed assistant draft is waiting for review.",
                _ => null,
            };
        if (assistantSummary is not null)
        {
            return assistantSummary;
        }
        if (snapshot.State == "committing")
        {
            return
                $"Review approved. Commit plan {snapshot.CommitPlanSha256 ?? "missing"} is ready for one explicit commit.";
        }
        return snapshot.ActionRequired?.Kind switch
        {
            "select_template" =>
                "Select one evidence-backed provider candidate, or explicitly continue without a template.",
            "supply_more_evidence" =>
                "Supply one official document or redacted cURL, or request the bounded assistant.",
            "approve_assistant" =>
                "Review the exact assistant budget, origins, evidence IDs, and grant digest before continuing.",
            "approve_credential_origin" =>
                "Approve only the exact credential origin shown above; redirects remain credential-free.",
            "approve_probes" =>
                "Approve the exact bounded probe grant, or skip probes.",
            "review" =>
                "Review every graph change, provenance item, request shape, and digest before approval.",
            "restart_interrupted" =>
                $"The {snapshot.RecoveryOperation ?? "external"} operation was interrupted. Restart only by explicit action.",
            "reconcile_unknown_outcome" =>
                $"The outcome of {snapshot.UnknownOperation ?? "an external operation"} is unknown. Audit it and choose an explicit resolution; it will not be replayed.",
            _ when snapshot.State == "ready" =>
                $"Discovery committed connection {snapshot.CommittedConnectionId ?? snapshot.PendingConnectionId}.",
            _ =>
                $"Core is processing state {snapshot.State}.",
        };
    }

    private void RestoreAssistantRouteBinding(
        ProviderDiscoverySnapshot snapshot)
    {
        var exactGrant =
            snapshot.ApprovalProposal?.Grant is
            { Kind: "assistant_consent" } proposalGrant
                ? proposalGrant
                : snapshot.Approvals
                    .Where(approval =>
                        approval.Decision == "approved"
                        && approval.Grant.Kind ==
                            "assistant_consent")
                    .OrderByDescending(approval =>
                        approval.CreatedAt)
                    .Select(approval => approval.Grant)
                    .FirstOrDefault();
        var exactRouteId =
            exactGrant?.AssistantModelRouteId;
        if (!string.IsNullOrWhiteSpace(exactRouteId))
        {
            activeDiscoveryAssistantSessionId =
                snapshot.SessionId;
            activeDiscoveryAssistantRouteId =
                exactRouteId;
            var exactRoute =
                AssistantModelRoutes.FirstOrDefault(route =>
                    string.Equals(
                        route.Id,
                        exactRouteId,
                        StringComparison.Ordinal));
            SetSelectedAssistantModelRoute(exactRoute);
            if (exactRoute is null)
            {
                AssistantModelRouteSelectionSummary =
                    $"The durable assistant grant names route {exactRouteId}, but that route is unavailable. No assistant call can be approved.";
            }
            return;
        }

        var isSameInMemoryStart =
            string.Equals(
                activeDiscoveryAssistantSessionId,
                snapshot.SessionId,
                StringComparison.Ordinal)
            && activeDiscoveryAssistantRouteId is not null;
        if (isSameInMemoryStart)
        {
            var frozenRoute =
                AssistantModelRoutes.FirstOrDefault(route =>
                    string.Equals(
                        route.Id,
                        activeDiscoveryAssistantRouteId,
                        StringComparison.Ordinal));
            SetSelectedAssistantModelRoute(frozenRoute);
            if (frozenRoute is null)
            {
                AssistantModelRouteSelectionSummary =
                    $"The route frozen for this discovery ({activeDiscoveryAssistantRouteId}) is no longer available. Cancel and restart before using the assistant.";
            }
            return;
        }

        activeDiscoveryAssistantSessionId =
            snapshot.SessionId;
        activeDiscoveryAssistantRouteId = null;
        SetSelectedAssistantModelRoute(null);
        if (snapshot.State is not
            ("ready" or "failed" or "cancelled"))
        {
            AssistantModelRouteSelectionSummary =
                "This restored pre-grant session does not expose its frozen assistant route. Add deterministic evidence, or cancel and restart to choose a route safely.";
        }
    }

    private void ApplyAssistantGrantReview(
        ProviderDiscoverySnapshot snapshot)
    {
        AssistantGrantReview.Clear();
        if (snapshot.ApprovalProposal is not
            {
                Grant.Kind: "assistant_consent",
            } proposal)
        {
            return;
        }

        var grant = proposal.Grant;
        var route =
            AssistantModelRoutes.FirstOrDefault(option =>
                string.Equals(
                    option.Id,
                    grant.AssistantModelRouteId,
                    StringComparison.Ordinal));
        AssistantGrantReview.Add(
            new ProviderProgressItem(
                "!",
                "Assistant model identity",
                route is null
                    ? $"Unavailable route · {grant.AssistantModelRouteId}"
                    : $"{route.Label} · {route.Detail}"));
        foreach (var origin in
                 grant.AllowedDocumentOrigins ?? [])
        {
            AssistantGrantReview.Add(
                new ProviderProgressItem(
                    "→",
                    "Allowed document origin",
                    origin));
        }
        foreach (var evidenceId in
                 grant.EvidenceIds ?? [])
        {
            AssistantGrantReview.Add(
                new ProviderProgressItem(
                    "i",
                    "Evidence ID",
                    evidenceId));
        }
        AssistantGrantReview.Add(
            new ProviderProgressItem(
                "≤",
                "Bounded assistant budget",
                $"{grant.MaxCalls ?? 0} call(s) · input ≤{grant.MaxInputTokens ?? 0} tokens · output ≤{grant.MaxOutputTokens ?? 0} tokens · tools ≤{grant.MaxToolCalls ?? 0} · retries ≤{grant.MaxRetries ?? 0} · cost ≤{grant.MaxCostMicroUnits ?? 0} micro-units"));
        AssistantGrantReview.Add(
            new ProviderProgressItem(
                "#",
                "Exact assistant grant",
                $"approval {proposal.ApprovalId} · SHA-256 {proposal.GrantSha256}"));
    }

    private void RestoreAssistantBoundary(
        ProviderDiscoverySnapshot snapshot)
    {
        var boundary = snapshot.AssistantResumeBoundary;
        activeAssistantResumeAction = boundary?.Action;
        activeAssistantAction = boundary?.Action switch
        {
            ProviderDiscoveryAssistantResumeAction.SupplyMoreEvidence =>
                new ProviderDiscoveryAssistantHostAction
                {
                    Kind = "request_more_evidence",
                    SessionId = snapshot.SessionId,
                    Questions = boundary.Questions,
                },
            ProviderDiscoveryAssistantResumeAction.ReviewDraft
                when boundary.DraftReview is { } review =>
                new ProviderDiscoveryAssistantHostAction
                {
                    Kind = "review_draft",
                    DraftReview = review,
                },
            _ => null,
        };
        activeAssistantGrant = boundary is null
            ? null
            : snapshot.Approvals
                .Where(approval =>
                    approval.Decision == "approved"
                    && approval.Grant.Kind ==
                        "assistant_consent")
                .OrderByDescending(approval =>
                    approval.CreatedAt)
                .Select(approval => approval.Grant)
                .FirstOrDefault();
        assistantRetryAvailable =
            boundary?.Action ==
                ProviderDiscoveryAssistantResumeAction.ResumeCoreHostAction
            || (activeAssistantGrant is not null
                && boundary?.Action is
                    ProviderDiscoveryAssistantResumeAction.RunAssistant or
                    ProviderDiscoveryAssistantResumeAction.ApproveRetry);
    }

    private void ApplyDiscoveryConnectionOptions(
        ProviderDiscoveryConnectionOptions options)
    {
        ApiBasePath = options.ApiBasePath ?? string.Empty;
        TimeoutSeconds = options.TimeoutSeconds.ToString();
        SelectedNetworkMode =
            FindNetworkMode(options.NetworkMode);
        LocalNetworkOrigin =
            options.LocalNetworkApproval?.Origin
            ?? string.Empty;
        LocalNetworkAddresses =
            options.LocalNetworkApproval is { } approval
                ? string.Join(
                    Environment.NewLine,
                    approval.Addresses)
                : string.Empty;
        LocalNetworkAccessApproved =
            options.LocalNetworkApproval is not null;
    }

    private bool HasPendingDiscoveryStart
    {
        get
        {
            lock (discoveryStartGate)
            {
                return discoveryStartCancellation is not null;
            }
        }
    }

    private bool TryBeginDiscoveryStart(
        out long operationEpoch,
        out CancellationTokenSource cancellation)
    {
        cancellation = new CancellationTokenSource();
        lock (discoveryStartGate)
        {
            if (discoveryStartCancellation is not null)
            {
                operationEpoch = 0;
                cancellation.Dispose();
                return false;
            }

            discoveryStartOperationEpoch =
                checked(discoveryStartOperationEpoch + 1);
            operationEpoch = discoveryStartOperationEpoch;
            discoveryStartCancellation = cancellation;
        }
        OnPropertyChanged(
            nameof(CanCancelProviderOperation));
        NotifyAssistantRouteState();
        return true;
    }

    private bool IsCurrentDiscoveryStart(
        long operationEpoch,
        CancellationTokenSource cancellation)
    {
        lock (discoveryStartGate)
        {
            return operationEpoch ==
                    discoveryStartOperationEpoch
                && ReferenceEquals(
                    discoveryStartCancellation,
                    cancellation);
        }
    }

    private bool CancelPendingDiscoveryStart()
    {
        lock (discoveryStartGate)
        {
            if (discoveryStartCancellation is null)
            {
                return false;
            }

            discoveryStartOperationEpoch =
                checked(discoveryStartOperationEpoch + 1);
            discoveryStartCancellation.Cancel();
        }
        OnPropertyChanged(
            nameof(CanCancelProviderOperation));
        NotifyAssistantRouteState();
        return true;
    }

    private void CompleteDiscoveryStart(
        long operationEpoch,
        CancellationTokenSource cancellation)
    {
        _ = operationEpoch;
        var shouldDispose = false;
        lock (discoveryStartGate)
        {
            if (ReferenceEquals(
                    discoveryStartCancellation,
                    cancellation))
            {
                discoveryStartCancellation = null;
                shouldDispose = true;
            }
        }
        if (shouldDispose)
        {
            cancellation.Dispose();
            OnPropertyChanged(
                nameof(CanCancelProviderOperation));
            NotifyAssistantRouteState();
        }
    }

    private async Task CancelAbandonedDiscoveryStartAsync(
        ProviderDiscoverySnapshot snapshot)
    {
        try
        {
            var cancelled = snapshot;
            if (snapshot.State is not
                ("ready" or "failed" or "cancelled"))
            {
                cancelled = await Task.Run(() =>
                    core.CancelProviderDiscovery(
                        snapshot.SessionId,
                        snapshot.Revision,
                        snapshot.PendingConnectionId));
            }

            if (cancelled.State == "compensating")
            {
                await HandleDiscoveryCompensationAsync(
                    cancelled);
            }
            ProviderStatus = cancelled.State == "cancelled"
                ? "Provider discovery start cancelled."
                : "Provider discovery was abandoned before UI activation; its durable state remains recoverable and no monitor was started.";
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Provider discovery start was abandoned, but cancellation could not be confirmed. Reopen Settings to recover the durable session.",
                exception);
        }
    }

    private void StartDiscoveryMonitoring(
        string sessionId,
        string pendingConnectionId) =>
        StartDiscoveryMonitoring(
            sessionId,
            pendingConnectionId,
            CaptureSettingsLifecycleEpoch());

    private void StartDiscoveryMonitoring(
        string sessionId,
        string pendingConnectionId,
        long lifecycleEpoch)
    {
        if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
        {
            return;
        }

        StopDiscoveryMonitoring(clearSnapshot: false);
        discoveryMonitoring =
            new CancellationTokenSource();
        discoveryMonitoringTask = MonitorDiscoveryAsync(
            sessionId,
            pendingConnectionId,
            lifecycleEpoch,
            discoveryMonitoring.Token);
    }

    private async Task MonitorDiscoveryAsync(
        string sessionId,
        string pendingConnectionId,
        long lifecycleEpoch,
        CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested
                   && IsSettingsLifecycleCurrent(
                       lifecycleEpoch)
                   && string.Equals(
                       activeDiscovery?.SessionId,
                       sessionId,
                       StringComparison.Ordinal)
                   && string.Equals(
                       activeDiscovery?.PendingConnectionId,
                       pendingConnectionId,
                       StringComparison.Ordinal))
            {
                var state = await Task.Run(() => (
                    Events:
                        core.PollProviderDiscoveryEvents(
                            128),
                    Snapshot:
                        core.GetProviderDiscovery(
                            sessionId,
                            pendingConnectionId)),
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                if (!IsSettingsLifecycleCurrent(
                        lifecycleEpoch))
                {
                    return;
                }
                if (!string.Equals(
                        state.Snapshot.SessionId,
                        sessionId,
                        StringComparison.Ordinal)
                    || !string.Equals(
                        state.Snapshot.PendingConnectionId,
                        pendingConnectionId,
                        StringComparison.Ordinal))
                {
                    throw new CoreInteropException(
                        "The provider-discovery monitor received an unrelated session.");
                }
                if (!IsCurrentDiscoverySessionBinding(
                        sessionId,
                        pendingConnectionId))
                {
                    return;
                }

                foreach (var item in state.Events.Where(
                             item => string.Equals(
                                 item.Event.SessionId,
                                 sessionId,
                                 StringComparison.Ordinal)))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (!IsSettingsLifecycleCurrent(
                            lifecycleEpoch))
                    {
                        return;
                    }
                    if (displayedDiscoveryEventIds.Add(
                            item.Event.EventId))
                    {
                        DiscoveryProgress.Add(
                            new ProviderProgressItem(
                                item.Event.Failure is null
                                    ? "●"
                                    : "!",
                                item.Event.State,
                                item.Event.Progress is { } progress
                                    ? $"{progress.Phase} · {progress.Completed}/{progress.Total?.ToString() ?? "?"}"
                                    : item.Event.Warning
                                        ?? $"revision {item.Event.SessionRevision}"));
                    }
                    _ = await Task.Run(() =>
                        core.AckProviderDiscoveryEvent(
                            item.Event.EventId),
                        cancellationToken);
                    cancellationToken.ThrowIfCancellationRequested();
                }
                cancellationToken.ThrowIfCancellationRequested();
                if (!IsSettingsLifecycleCurrent(
                        lifecycleEpoch)
                    || !IsCurrentDiscoverySessionBinding(
                        sessionId,
                        pendingConnectionId))
                {
                    return;
                }

                ApplyDiscoverySnapshot(state.Snapshot);
                if (state.Snapshot.State ==
                    "compensating")
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    await HandleDiscoveryCompensationAsync(
                        state.Snapshot,
                        cancellationToken);
                    return;
                }
                if (state.Snapshot.State is
                    "ready" or "failed" or "cancelled"
                    or "interrupted" or "unknown_outcome")
                {
                    return;
                }
                await Task.Delay(
                    TimeSpan.FromMilliseconds(500),
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
            }
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && IsCurrentDiscoverySessionBinding(
                    sessionId,
                    pendingConnectionId))
            {
                ProviderStatus = SafeError(
                    "Provider-discovery monitoring stopped.",
                    exception);
            }
        }
    }

    private async Task HandleDiscoveryCompensationAsync(
        ProviderDiscoverySnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (snapshot.CommitAttemptId is not { } attemptId)
        {
            ProviderStatus =
                "Discovery compensation is missing its immutable commit attempt ID.";
            return;
        }

        await discoveryCompensationGate.WaitAsync(
            cancellationToken);
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            IReadOnlyList<ProviderDiscoveryCompensationStep> steps;
            try
            {
                steps = await Task.Run(() =>
                    core.ListProviderDiscoveryCompensationSteps(
                        attemptId),
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException)
                when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (Exception exception)
            {
                ProviderStatus = SafeError(
                    "Could not load the immutable discovery compensation recipe.",
                    exception);
                return;
            }

            var nativeStep = steps.FirstOrDefault(step =>
                step.Target.Kind == "remove_credential_slot"
                && step.Status == "pending"
                && step.AttemptCount == 0);
            if (nativeStep is null)
            {
                ProviderStatus =
                    "Discovery compensation requires explicit review; no unattempted PasswordVault step is ready.";
                return;
            }
            if (!string.Equals(
                    nativeStep.CommitAttemptId,
                    attemptId,
                    StringComparison.Ordinal))
            {
                ProviderStatus =
                    "The credential compensation step belongs to another commit attempt. No credential was removed.";
                return;
            }
            if (nativeStep.Target.ConnectionId is not
                { } connectionId)
            {
                ProviderStatus =
                    "The credential compensation target is incomplete.";
                return;
            }
            if (!string.Equals(
                    connectionId,
                    snapshot.PendingConnectionId,
                    StringComparison.Ordinal)
                || !snapshot.CredentialSlotExpected
                || !string.Equals(
                    snapshot.CredentialSlotId,
                    connectionId,
                    StringComparison.Ordinal)
                || !string.Equals(
                    nativeStep.Target.CredentialRef,
                    connectionId,
                    StringComparison.Ordinal))
            {
                ProviderStatus =
                    "The credential compensation target does not match the immutable pending PasswordVault slot. No credential was removed.";
                return;
            }

            cancellationToken.ThrowIfCancellationRequested();
            var claim = (
                snapshot.SessionId,
                attemptId,
                nativeStep.Id);
            if (!claimedDiscoveryCompensations.Add(claim))
            {
                return;
            }

            try
            {
                _ = await Task.Run(() =>
                    core.StartProviderDiscoveryCredentialCompensation(
                        snapshot.SessionId,
                        nativeStep.Id,
                        attemptId));
                credentials.Delete(connectionId);
            }
            catch
            {
                try
                {
                    var unknown = await Task.Run(() =>
                        core.MarkProviderDiscoveryCredentialCompensationUnknown(
                            snapshot.SessionId,
                            nativeStep.Id,
                            snapshot.PendingConnectionId,
                            attemptId));
                    if (IsCurrentDiscoverySessionBinding(
                            snapshot.SessionId,
                            snapshot.PendingConnectionId))
                    {
                        ApplyDiscoverySnapshot(unknown);
                    }
                }
                catch
                {
                }
                if (IsCurrentDiscoverySessionBinding(
                        snapshot.SessionId,
                        snapshot.PendingConnectionId))
                {
                    ProviderStatus =
                        "PasswordVault compensation has an unknown outcome. It will not be retried automatically; reconcile the exact connection slot.";
                }
                return;
            }

            try
            {
                var completed = await Task.Run(() =>
                    core.CompleteProviderDiscoveryCredentialCompensation(
                        snapshot.SessionId,
                        nativeStep.Id,
                        snapshot.PendingConnectionId,
                        attemptId));
                if (IsCurrentDiscoverySessionBinding(
                        snapshot.SessionId,
                        snapshot.PendingConnectionId))
                {
                    ApplyDiscoverySnapshot(completed);
                }
            }
            catch (Exception exception)
            {
                if (IsCurrentDiscoverySessionBinding(
                        snapshot.SessionId,
                        snapshot.PendingConnectionId))
                {
                    ProviderStatus = SafeError(
                        "The PasswordVault slot was removed, but Core could not record compensation completion. Reconcile before retrying.",
                        exception);
                }
            }
        }
        finally
        {
            discoveryCompensationGate.Release();
        }
    }

    private bool IsCurrentDiscoverySessionBinding(
        string sessionId,
        string pendingConnectionId) =>
        string.Equals(
            activeDiscovery?.SessionId,
            sessionId,
            StringComparison.Ordinal)
        && string.Equals(
            activeDiscovery?.PendingConnectionId,
            pendingConnectionId,
            StringComparison.Ordinal);

    private (
        CancellationTokenSource? Cancellation,
        Task? MonitoringTask) DetachDiscoveryMonitoring(
            bool clearSnapshot)
    {
        var cancellation = discoveryMonitoring;
        var monitoringTask = discoveryMonitoringTask;
        discoveryMonitoring = null;
        discoveryMonitoringTask = null;
        cancellation?.Cancel();
        if (clearSnapshot)
        {
            activeDiscovery = null;
        }

        return (cancellation, monitoringTask);
    }

    private async Task StopDiscoveryMonitoringAsync(
        bool clearSnapshot)
    {
        var (cancellation, monitoringTask) =
            DetachDiscoveryMonitoring(clearSnapshot);
        try
        {
            if (monitoringTask is not null)
            {
                await monitoringTask;
            }
        }
        catch (OperationCanceledException)
            when (cancellation?.IsCancellationRequested == true)
        {
        }
        finally
        {
            cancellation?.Dispose();
        }
    }

    private void StopDiscoveryMonitoring(
        bool clearSnapshot)
    {
        var (cancellation, _) =
            DetachDiscoveryMonitoring(clearSnapshot);
        cancellation?.Dispose();
    }

    internal async Task DeleteSelectedConnectionAsync()
    {
        var connection = SelectedConnection;
        if (connection is null || IsBusy)
        {
            return;
        }

        var token = selectionGuard.Capture();
        IsBusy = true;
        ProviderStatus = "Deleting provider connection…";
        try
        {
            await ProviderCredentialTransaction.DeleteAsync(
                credentials,
                connection.Id,
                () => Task.Run(() =>
                    core.DeleteProviderConnection(connection.Id)));
        }
        catch (ProviderCredentialCompensationException)
        {
            ProviderStatus =
                "Delete failed and PasswordVault compensation also failed. Review the connection and credential state before retrying.";
            IsBusy = false;
            return;
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not delete provider connection. Its previous PasswordVault entry was restored.",
                exception);
            IsBusy = false;
            return;
        }

        RemoveConnectionLocally(connection.Id);
        if (selectionGuard.IsCurrent(token))
        {
            BeginNewConnectionCore();
        }
        try
        {
            var connections = await Task.Run(() =>
                core.ListProviderConnections());
            ReplaceConnections(connections);
            ProviderStatus =
                "Provider connection and its PasswordVault credential were removed.";
        }
        catch
        {
            ProviderStatus =
                "Provider connection and its PasswordVault credential were removed, but the refreshed connection view could not be loaded. Reload settings to reconcile.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal void RemoveSelectedCredential()
    {
        var connection = SelectedConnection;
        if (connection is null || IsBusy)
        {
            return;
        }

        try
        {
            credentials.Delete(connection.Id);
            if (string.Equals(
                    SelectedAssistantModelRoute?.ConnectionId,
                    connection.Id,
                    StringComparison.Ordinal))
            {
                SetSelectedAssistantModelRoute(null);
                AssistantModelRouteSelectionSummary =
                    "The app-default assistant credential was removed. Restore it and reload Settings before requesting assistant use.";
            }
            ProviderStatus =
                "The PasswordVault credential was removed. The non-secret connection remains available for repair.";
        }
        catch
        {
            ProviderStatus =
                "Windows PasswordVault could not remove the credential. The connection was not changed.";
        }
    }

    internal async Task RefreshModelsAsync()
    {
        var connection = SelectedConnection;
        if (connection is null || IsBusy)
        {
            return;
        }

        if (activeModelSyncJobId is not null)
        {
            ProviderStatus =
                "Review, approve, cancel, or recover the current model synchronization before starting another.";
            return;
        }

        var lifecycleEpoch =
            CaptureSettingsLifecycleEpoch();
        var token = selectionGuard.Capture();
        StopModelSyncMonitoring();
        IsBusy = true;
        ProviderStatus =
            "Starting a durable model synchronization…";
        ModelSyncReview.Clear();
        displayedModelSyncEvents.Clear();
        try
        {
            string? credential = credentials.Get(connection.Id);
            ModelSyncStarted started;
            try
            {
                started = await Task.Run(() =>
                    core.StartProviderModelSync(
                        connection.Id,
                        credential));
            }
            finally
            {
                credential = null;
            }

            if (!IsSettingsLifecycleCurrent(lifecycleEpoch)
                || !selectionGuard.IsCurrent(token))
            {
                return;
            }

            activeModelSyncJobId = started.JobId;
            NotifyModelSyncActionState();
            modelSyncMonitoring = new CancellationTokenSource();
            await MonitorModelSyncAsync(
                started.JobId,
                token,
                lifecycleEpoch,
                modelSyncMonitoring.Token);
        }
        catch (Exception exception)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && selectionGuard.IsCurrent(token))
            {
                ProviderStatus = SafeError(
                    "Could not refresh models.",
                    exception);
            }
        }
        finally
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                IsBusy = false;
            }
        }
    }

    internal async Task ApproveModelSyncAsync()
    {
        var jobId = activeModelSyncJobId;
        var reviewSha256 = activeModelSyncReviewSha256;
        var lifecycleEpoch =
            CaptureSettingsLifecycleEpoch();
        var token = selectionGuard.Capture();
        if (jobId is null
            || reviewSha256 is null
            || token.ConnectionId is null
            || IsBusy)
        {
            ProviderStatus =
                "No exact model-sync review digest is awaiting approval.";
            return;
        }

        IsBusy = true;
        ProviderStatus =
            "Approving the exact reviewed model diff…";
        ModelSyncJob job;
        try
        {
            job = await Task.Run(() =>
                core.ApproveProviderModelSync(
                    jobId,
                    reviewSha256,
                    token.ConnectionId));
        }
        catch (Exception exception)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && selectionGuard.IsCurrent(token))
            {
                ProviderStatus = SafeError(
                    "Could not approve the model synchronization.",
                    exception);
                IsBusy = false;
            }
            return;
        }

        if (!IsSettingsLifecycleCurrent(lifecycleEpoch)
            || !selectionGuard.IsCurrent(token))
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                IsBusy = false;
            }
            return;
        }

        ApplyModelSyncJob(job);
        try
        {
            if (job.State == ModelSyncStates.Completed)
            {
                await ReloadSelectedConnectionRoutesAsync(
                    token,
                    lifecycleEpoch);
            }
            else if (job.State is
                ModelSyncStates.Committing or
                ModelSyncStates.Fetching or
                ModelSyncStates.Created)
            {
                StopModelSyncMonitoring();
                modelSyncMonitoring =
                    new CancellationTokenSource();
                await MonitorModelSyncAsync(
                    job.Id,
                    token,
                    lifecycleEpoch,
                    modelSyncMonitoring.Token);
            }
        }
        catch
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && selectionGuard.IsCurrent(token))
            {
                ProviderStatus = job.State ==
                    ModelSyncStates.Completed
                    ? "The approved model diff was committed, but the refreshed route view could not be loaded. Reload settings to reconcile."
                    : "The exact model-sync approval was accepted, but monitoring could not continue. Reopen this connection to recover the durable job.";
            }
        }
        finally
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                IsBusy = false;
            }
        }
    }

    internal async Task CancelModelSyncAsync()
    {
        var jobId = activeModelSyncJobId;
        if (jobId is null)
        {
            ProviderStatus =
                "No model synchronization is active.";
            return;
        }
        if (IsModelSyncCancellationInProgress)
        {
            return;
        }

        var token = selectionGuard.Capture();
        if (token.ConnectionId is null)
        {
            ProviderStatus =
                "The model synchronization is no longer bound to a selected connection.";
            return;
        }
        IsModelSyncCancellationInProgress = true;
        try
        {
            var job = await Task.Run(() =>
                core.CancelProviderModelSync(
                    jobId,
                    token.ConnectionId));
            StopModelSyncMonitoring();
            if (selectionGuard.IsCurrent(token))
            {
                ApplyModelSyncJob(job);
            }
        }
        catch (Exception exception)
        {
            if (selectionGuard.IsCurrent(token))
            {
                ProviderStatus = SafeError(
                    "Could not cancel the model synchronization.",
                    exception);
            }
        }
        finally
        {
            IsModelSyncCancellationInProgress = false;
        }
    }

    internal Task SelectModelRouteAsync(ModelRoute? route) =>
        SelectModelRouteAsync(
            route,
            CaptureSettingsLifecycleEpoch());

    private async Task SelectModelRouteAsync(
        ModelRoute? route,
        long lifecycleEpoch)
    {
        if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
        {
            return;
        }

        var defaultPresetId =
            SelectedDefaultPreset is { } currentDefault
            && route is not null
            && string.Equals(
                currentDefault.ModelRouteId,
                route.Id,
                StringComparison.Ordinal)
                ? currentDefault.Id
                : null;
        SelectedModelRoute = route;
        SelectedGenerationPreset = null;
        SelectedDefaultPreset = null;
        checked
        {
            previewRevision++;
        }
        GenerationPresets.Clear();
        effectiveParameterSpecs = [];
        ClearParameterEditors();
        Capabilities.Clear();
        ResetPresetControlPresentation();
        RequestPreview =
            "Choose a generation preset to request a Core-generated redacted preview.";
        var revision = checked(++routeRevision);
        if (route is null)
        {
            return;
        }

        ProviderStatus = "Loading presets and capability evidence…";
        try
        {
            var result = await Task.Run(() =>
            {
                var presets = core.ListGenerationPresets(route.Id);
                var parameterSpecs =
                    core.GetEffectiveParameterSpecs(route.Id);
                var capabilities = new List<EffectiveCapability>();
                foreach (var key in CapabilityKeys)
                {
                    var effective =
                        core.GetEffectiveCapability(route.Id, key);
                    if (effective is not null)
                    {
                        capabilities.Add(effective);
                    }
                }

                return (
                    Presets: presets,
                    ParameterSpecs: parameterSpecs,
                    Capabilities: capabilities);
            });
            if (!IsSettingsLifecycleCurrent(lifecycleEpoch)
                || revision != routeRevision
                || SelectedModelRoute?.Id != route.Id)
            {
                return;
            }

            ReplacePresets(result.Presets);
            effectiveParameterSpecs = result.ParameterSpecs;
            SelectedDefaultPreset =
                defaultPresetId is null
                    ? null
                    : GenerationPresets.FirstOrDefault(item =>
                        string.Equals(
                            item.Id,
                            defaultPresetId,
                            StringComparison.Ordinal));
            Capabilities.Clear();
            foreach (var capability in result.Capabilities)
            {
                Capabilities.Add(
                    CapabilityDisplayItem.From(capability));
            }
            if (GenerationPresets.Count > 0)
            {
                SelectGenerationPreset(
                    GenerationPresets.First(),
                    scheduleControls: false);
            }
            else
            {
                BeginNewPreset(scheduleControls: false);
            }
            await RefreshPresetControlsAsync(
                allowRenderedDefaultAdoption: true,
                lifecycleEpoch);
            if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
            {
                return;
            }

            ProviderStatus =
                $"{GenerationPresets.Count} preset(s), {Capabilities.Count} source-attributed capability value(s).";
        }
        catch (Exception exception)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && revision == routeRevision)
            {
                ProviderStatus = SafeError(
                    "Could not load model configuration.",
                    exception);
            }
        }
    }

    internal void SelectGenerationPreset(
        GenerationPreset? preset,
        bool scheduleControls = true)
    {
        checked
        {
            previewRevision++;
        }
        preset = preset is null
            ? null
            : ApplyOpaqueReasoningPolicy(preset);
        SelectedGenerationPreset = preset;
        if (preset is null)
        {
            BeginNewPreset(scheduleControls);
            return;
        }

        suppressPresetControlRefresh = true;
        try
        {
            PresetId = preset.Id;
            PresetDisplayName = preset.DisplayName;
            ReasoningMode = preset.Reasoning.Mode;
            ReasoningEffort =
                preset.Reasoning.Effort ?? string.Empty;
            ReasoningBudgetTokens =
                preset.Reasoning.BudgetTokens?.ToString()
                ?? string.Empty;
            ReasoningSummary = preset.Reasoning.Summary;
            if (string.Equals(
                    ReasoningMode,
                    "provider_default",
                    StringComparison.Ordinal))
            {
                ClearProviderDefaultReasoningOverrides();
            }
            PreserveOpaqueReasoningState =
                preset.Reasoning.PreserveOpaqueState;
            PromptCacheMode = preset.PromptCache.Mode;
            PromptCacheTtl = preset.PromptCache.Ttl.Kind;
            PromptCacheCustomSeconds =
                preset.PromptCache.Ttl.Seconds?.ToString()
                ?? string.Empty;
            PromptCacheContextReference =
                preset.PromptCache.ContextReference
                ?? string.Empty;
        }
        finally
        {
            suppressPresetControlRefresh = false;
        }
        LoadParameterEditors(preset.Values);
        RequestPreview =
            "Generate the Core-owned redacted request preview before sending.";
        if (scheduleControls)
        {
            SchedulePresetControlRefresh();
        }
    }

    internal void BeginNewPreset(bool scheduleControls = true)
    {
        checked
        {
            previewRevision++;
        }
        SelectedGenerationPreset = null;
        suppressPresetControlRefresh = true;
        try
        {
            PresetId = string.Empty;
            PresetDisplayName = string.Empty;
            ReasoningMode = "provider_default";
            ReasoningEffort = string.Empty;
            ReasoningBudgetTokens = string.Empty;
            ReasoningSummary = "provider_default";
            PreserveOpaqueReasoningState = false;
            PromptCacheMode = "provider_default";
            PromptCacheTtl = "provider_default";
            PromptCacheCustomSeconds = string.Empty;
            PromptCacheContextReference = string.Empty;
        }
        finally
        {
            suppressPresetControlRefresh = false;
        }
        LoadParameterEditors([]);
        RequestPreview =
            "Complete the preset fields to validate and preview this unsaved candidate.";
        if (scheduleControls)
        {
            SchedulePresetControlRefresh();
        }
    }

    internal async Task<bool> SavePresetAsync()
    {
        if (!await RefreshPresetControlsAsync())
        {
            ProviderStatus = PresetControlStatus;
            return false;
        }
        if (!TryBuildPresetCandidate(
                out var preset,
                out var candidateError)
            || preset is null)
        {
            ProviderStatus = candidateError
                ?? "The generation-preset candidate is invalid.";
            return false;
        }

        var routeId = preset.ModelRouteId;
        var routeRevisionAtStart = routeRevision;
        IsBusy = true;
        ProviderStatus =
            "Validating the generation-preset candidate before persistence…";
        GenerationPreset saved;
        try
        {
            saved = await Task.Run(() =>
            {
                core.ValidateGenerationPresetCandidate(preset);
                return core.UpsertGenerationPreset(preset);
            });
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not save generation preset.",
                exception);
            IsBusy = false;
            return false;
        }

        if (routeRevisionAtStart != routeRevision
            || !string.Equals(
                SelectedModelRoute?.Id,
                routeId,
                StringComparison.Ordinal))
        {
            ProviderStatus =
                "The preset was saved for the previous model route; the current route view was left unchanged.";
            IsBusy = false;
            return true;
        }

        UpsertPresetLocally(saved);
        try
        {
            var presets = await Task.Run(() =>
                core.ListGenerationPresets(routeId));
            ReplacePresets(presets);
            var selected = GenerationPresets.FirstOrDefault(item =>
                string.Equals(
                    item.Id,
                    saved.Id,
                    StringComparison.Ordinal))
                ?? saved;
            SelectGenerationPreset(selected);
            var previewLoaded =
                await LoadRequestPreviewAsync();
            ProviderStatus = previewLoaded
                ? "Generation preset saved, validated, and previewed with explicit provider-default states."
                : "Generation preset saved and validated, but its redacted preview is unavailable.";
            return true;
        }
        catch
        {
            SelectGenerationPreset(saved);
            ProviderStatus =
                "Generation preset was saved and validated, but the refreshed preset list could not be loaded. Reload settings to reconcile.";
            return true;
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task<bool> LoadRequestPreviewAsync()
    {
        if (!await RefreshPresetControlsAsync())
        {
            RequestPreview = PresetControlStatus;
            return false;
        }
        if (!TryBuildPresetCandidate(
                out var preset,
                out var candidateError)
            || preset is null)
        {
            RequestPreview = candidateError
                ?? "Complete the generation-preset candidate before generating a preview.";
            return false;
        }

        var revision = checked(++previewRevision);
        RequestPreview =
            "Generating a scalar-free, redacted request preview…";
        try
        {
            var preview = await Task.Run(() =>
            {
                core.ValidateGenerationPresetCandidate(preset);
                return core.PreviewProviderRequestCandidate(
                    preset);
            });
            if (revision != previewRevision
                || SelectedModelRoute?.Id != preset.ModelRouteId
                || !string.Equals(
                    PresetId.Trim(),
                    preset.Id,
                    StringComparison.Ordinal))
            {
                return false;
            }

            if (preview.IncludesPrivateMessage
                || preview.IncludesCredentialValue
                || preview.IncludesOpaqueReasoningState)
            {
                RequestPreview =
                    "Core refused this preview because a privacy leak flag was set.";
                return false;
            }

            RequestPreview = FormatRequestPreview(preview);
            return true;
        }
        catch (Exception exception)
        {
            if (revision == previewRevision)
            {
                RequestPreview = SafeError(
                    "Could not generate the redacted request preview.",
                    exception);
            }

            return false;
        }
    }

    internal async Task DeleteSelectedPresetAsync()
    {
        var preset = SelectedGenerationPreset;
        var route = SelectedModelRoute;
        if (preset is null || route is null || IsBusy)
        {
            return;
        }

        var routeRevisionAtStart = routeRevision;
        var routeId = route.Id;
        IsBusy = true;
        try
        {
            await Task.Run(() =>
                core.DeleteGenerationPreset(preset.Id));
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not delete generation preset.",
                exception);
            IsBusy = false;
            return;
        }

        if (routeRevisionAtStart != routeRevision
            || !string.Equals(
                SelectedModelRoute?.Id,
                routeId,
                StringComparison.Ordinal))
        {
            ProviderStatus =
                "The preset was deleted from the previous model route; the current route view was left unchanged.";
            IsBusy = false;
            return;
        }

        RemovePresetLocally(preset.Id);
        try
        {
            var presets = await Task.Run(() =>
                core.ListGenerationPresets(routeId));
            ReplacePresets(presets);
            SelectFirstPresetOrBeginNew();
            ProviderStatus = "Generation preset deleted.";
        }
        catch
        {
            SelectFirstPresetOrBeginNew();
            ProviderStatus =
                "Generation preset was deleted, but the refreshed preset list could not be loaded. Reload settings to reconcile.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task SaveAppSettingsAsync()
    {
        if (!CanSaveAppSettings)
        {
            ProviderStatus =
                "Finish or cancel the current provider discovery before changing the app-default model route and preset.";
            return;
        }

        var preset = SelectedDefaultPreset;
        var connections = ProviderConnections.ToList();
        IsBusy = true;
        ProviderStatus = "Saving chat target…";
        try
        {
            await Task.Run(() =>
            {
                var current = core.GetSettings();
                core.UpdateSettings(current with
                {
                    PreservePartialGenerations =
                        PreservePartialGenerations,
                    SelectedModelRouteId =
                        preset?.ModelRouteId,
                    SelectedGenerationPresetId =
                        preset?.Id,
                    SelectedProviderProfileId = null,
                });
            });
            var assistantRoutes = await Task.Run(() =>
                LoadAssistantModelRouteOptions(
                    connections,
                    preset?.ModelRouteId,
                    preset?.Id));
            ReplaceAssistantModelRoutes(
                assistantRoutes);
            ProviderStatus =
                "Default model route, preset, and chat behavior saved atomically.";
        }
        catch (Exception exception)
        {
            ProviderStatus = SafeError(
                "Could not save chat settings.",
                exception);
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task PrepareSignedCatalogImportAsync(
        byte[] envelopeBytes)
    {
        ArgumentNullException.ThrowIfNull(envelopeBytes);
        if (IsBusy)
        {
            return;
        }

        IsBusy = true;
        CatalogStatus =
            "Verifying the selected signed catalog and preparing an exact review…";
        CatalogReview.Clear();
        ClearPendingCatalogImport();
        pendingCatalogRollbackPlan = null;
        try
        {
            var plan = await Task.Run(() =>
                core.PrepareSignedProviderCatalogImport(
                    envelopeBytes));
            pendingCatalogEnvelopeBytes =
                envelopeBytes.ToArray();
            pendingCatalogImportPlan = plan;
            OnPropertyChanged(nameof(HasPendingCatalogImport));
            PopulateCatalogDiff(plan.Review.Diff);
            CatalogReview.Insert(0, new ModelSyncReviewItem(
                "#",
                "Exact import-plan digest",
                plan.PlanSha256));
            CatalogReview.Insert(1, new ModelSyncReviewItem(
                "✓",
                "Signature verified",
                $"{plan.Review.SigningKeyId} · signed revision {plan.Review.SignedCatalogRevision} · envelope {plan.Review.EnvelopeSha256}."));
            CatalogReview.Insert(2, new ModelSyncReviewItem(
                "⏱",
                "State-bound review",
                $"Active revision {plan.Review.ExpectedActiveRevision} → candidate {plan.Review.CandidateRevision}; expires {plan.Review.ExpiresAt.LocalDateTime:g}."));
            CatalogStatus =
                "Review the typed diff and exact digest, then explicitly activate this unchanged file before the plan expires.";
        }
        catch (Exception exception)
        {
            CatalogStatus = SafeError(
                "The signed catalog could not be prepared. The active revision was not changed.",
                exception);
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task ActivateSignedCatalogImportAsync()
    {
        var plan = pendingCatalogImportPlan;
        var envelopeBytes = pendingCatalogEnvelopeBytes;
        if (plan is null
            || envelopeBytes is null
            || IsBusy)
        {
            CatalogStatus =
                "Choose a signed catalog file and review its exact import plan first.";
            return;
        }

        IsBusy = true;
        ProviderCatalogImportResult result;
        try
        {
            result = await Task.Run(() =>
                core.ActivateSignedProviderCatalogImport(
                    plan,
                    envelopeBytes));
        }
        catch (Exception exception)
        {
            ClearPendingCatalogImport();
            CatalogStatus = SafeError(
                "The reviewed catalog import was not activated.",
                exception);
            IsBusy = false;
            return;
        }

        ClearPendingCatalogImport();
        PopulateCatalogDiff(result.Diff);
        CatalogReview.Insert(0, new ModelSyncReviewItem(
            "✓",
            "Reviewed catalog activated",
            $"Signed revision {result.SignedCatalogRevision}; local snapshot {result.ActivatedRevision}."));
        try
        {
            await RefreshCatalogStateAsync();
            var templates = await Task.Run(() =>
                core.ListProviderTemplates());
            ReplaceTemplates(templates);
            CatalogStatus =
                $"Reviewed signed revision {result.SignedCatalogRevision} was activated as local revision {result.ActivatedRevision}.";
        }
        catch
        {
            CatalogStatus =
                $"Signed revision {result.SignedCatalogRevision} was activated as local revision {result.ActivatedRevision}, but the refreshed catalog view could not be loaded. Reload settings to reconcile.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal void ReportCatalogReadFailure()
    {
        ClearPendingCatalogImport();
        CatalogStatus =
            "The selected catalog could not be read as bounded UTF-8 JSON. The active revision was not changed.";
    }

    private void ClearPendingCatalogImport()
    {
        var hadPending = HasPendingCatalogImport;
        if (pendingCatalogEnvelopeBytes is { } envelopeBytes)
        {
            Array.Clear(envelopeBytes);
        }
        pendingCatalogEnvelopeBytes = null;
        pendingCatalogImportPlan = null;
        if (hadPending)
        {
            OnPropertyChanged(nameof(HasPendingCatalogImport));
        }
    }

    internal async Task ReviewSelectedCatalogRevisionAsync()
    {
        var selected = SelectedCatalogRevision;
        if (selected is null || IsBusy)
        {
            return;
        }

        IsBusy = true;
        ClearPendingCatalogImport();
        CatalogReview.Clear();
        pendingCatalogRollbackPlan = null;
        try
        {
            var diff = await Task.Run(() =>
                core.DiffProviderCatalogRevisions(
                    activeCatalogRevision,
                    selected.Revision));
            if (SelectedCatalogRevision?.Revision
                != selected.Revision)
            {
                CatalogStatus =
                    "The catalog selection changed; the completed diff was discarded.";
                return;
            }

            PopulateCatalogDiff(diff);
            CatalogStatus =
                $"Reviewing active revision {activeCatalogRevision} against revision {selected.Revision}.";
        }
        catch (Exception exception)
        {
            CatalogStatus = SafeError(
                "Could not diff the selected catalog revision.",
                exception);
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task PrepareCatalogRollbackAsync()
    {
        var selected = SelectedCatalogRevision;
        if (selected is null || IsBusy)
        {
            return;
        }

        if (selected.Revision == activeCatalogRevision)
        {
            CatalogStatus =
                "The selected catalog revision is already active.";
            return;
        }

        IsBusy = true;
        ClearPendingCatalogImport();
        pendingCatalogRollbackPlan = null;
        CatalogReview.Clear();
        try
        {
            var plan = await Task.Run(() =>
                core.PrepareProviderCatalogRollback(
                    selected.Revision));
            if (SelectedCatalogRevision?.Revision
                != selected.Revision)
            {
                CatalogStatus =
                    "The catalog selection changed; the prepared rollback plan was discarded.";
                return;
            }

            pendingCatalogRollbackPlan = plan;
            PopulateCatalogDiff(plan.Diff);
            CatalogReview.Insert(0, new ModelSyncReviewItem(
                "#",
                "Rollback plan digest",
                plan.PlanSha256));
            CatalogReview.Insert(1, new ModelSyncReviewItem(
                "↩",
                "State-bound rollback",
                $"Revision {plan.FromRevision} → {plan.ToRevision}; expires {plan.ExpiresAt.LocalDateTime:g}."));
            CatalogStatus =
                "Review the exact state-bound rollback plan, then activate it before expiry.";
        }
        catch (Exception exception)
        {
            CatalogStatus = SafeError(
                "Could not prepare a catalog rollback.",
                exception);
        }
        finally
        {
            IsBusy = false;
        }
    }

    internal async Task ActivateCatalogRollbackAsync()
    {
        var plan = pendingCatalogRollbackPlan;
        if (plan is null || IsBusy)
        {
            CatalogStatus =
                "Prepare and review a catalog rollback first.";
            return;
        }

        if (SelectedCatalogRevision?.Revision
            != plan.ToRevision)
        {
            pendingCatalogRollbackPlan = null;
            CatalogStatus =
                "The catalog selection changed; prepare and review a new rollback plan.";
            return;
        }

        IsBusy = true;
        ProviderCatalogRollbackResult result;
        try
        {
            result = await Task.Run(() =>
                core.ActivateProviderCatalogRollback(plan));
        }
        catch (Exception exception)
        {
            pendingCatalogRollbackPlan = null;
            CatalogStatus = SafeError(
                "Catalog rollback was not activated.",
                exception);
            IsBusy = false;
            return;
        }

        pendingCatalogRollbackPlan = null;
        CatalogReview.Insert(0, new ModelSyncReviewItem(
            "✓",
            "Rollback activated",
            $"Revision {result.FromRevision} → {result.ActivatedRevision}."));
        try
        {
            await RefreshCatalogStateAsync();
            var templates = await Task.Run(() =>
                core.ListProviderTemplates());
            ReplaceTemplates(templates);
            CatalogStatus =
                $"Reviewed catalog rollback activated revision {result.ActivatedRevision}.";
        }
        catch
        {
            CatalogStatus =
                $"Reviewed catalog rollback activated revision {result.ActivatedRevision}, but the refreshed catalog view could not be loaded. Reload settings to reconcile.";
        }
        finally
        {
            IsBusy = false;
        }
    }

    private async Task<ProviderConnection?> FindConnectionForRouteAsync(
        string? modelRouteId)
    {
        if (string.IsNullOrWhiteSpace(modelRouteId))
        {
            return null;
        }

        foreach (var connection in ProviderConnections)
        {
            var routes = await Task.Run(() =>
                core.ListModelRoutes(connection.Id));
            if (routes.Any(route =>
                    string.Equals(
                        route.Id,
                        modelRouteId,
                        StringComparison.Ordinal)))
            {
                return connection;
            }
        }

        return null;
    }

    private void ApplyTemplate(ProviderTemplate template)
    {
        ApiOrigin = template.DefaultApiOrigin ?? ApiOrigin;
        SelectedNetworkMode =
            FindNetworkMode(template.DefaultNetworkMode);
        ConnectionDisplayName = template.DisplayName;
        LoadConnectionFields(template, []);
        ProviderStatus = template.RequiresCredential
            ? "Enter an API key and approve its exact destination."
            : "This provider template does not require a credential.";
    }

    private void ApplyCatalogStatus(
        ProviderCatalogStatus status,
        ProviderCatalogHistory history)
    {
        activeCatalogRevision = status.ActiveRevision;
        CatalogStatus =
            $"Active local catalog revision {status.ActiveRevision} · state {status.StateVersion} · {status.SignedUpdateCount} signed update(s) · anti-rollback guard {status.HighestAcceptedRevision}.";
        var selectedRevision = SelectedCatalogRevision?.Revision;
        CatalogRevisions.Clear();
        foreach (var revision in history.Revisions)
        {
            CatalogRevisions.Add(new ProviderCatalogRevisionItem(
                revision.Revision,
                revision.Active
                    ? $"Revision {revision.Revision} · active"
                    : $"Revision {revision.Revision}",
                $"Captured {revision.CapturedAt.LocalDateTime:g} · {revision.SnapshotSha256}",
                revision.Active));
        }

        var nextSelection =
            CatalogRevisions.FirstOrDefault(item =>
                item.Revision == selectedRevision)
            ?? CatalogRevisions.FirstOrDefault(item =>
                item.IsActive)
            ?? CatalogRevisions.FirstOrDefault();
        SetProperty(
            ref selectedCatalogRevision,
            nextSelection,
            nameof(SelectedCatalogRevision));
    }

    private async Task RefreshCatalogStateAsync()
    {
        var state = await Task.Run(() => (
            Status: core.GetProviderCatalogStatus(),
            History: core.GetProviderCatalogHistory(limit: 50)));
        ApplyCatalogStatus(state.Status, state.History);
    }

    private void PopulateCatalogDiff(ProviderCatalogDiff diff)
    {
        CatalogReview.Clear();
        CatalogReview.Add(new ModelSyncReviewItem(
            "↔",
            "Catalog revisions",
            $"{diff.FromRevision} → {diff.ToRevision}"));
        AddCatalogManifestDiffs(
            diff.AddedProviderTemplates,
            CatalogChangeKind.Added);
        AddCatalogManifestDiffs(
            diff.ChangedProviderTemplates,
            CatalogChangeKind.Updated);
        AddCatalogManifestDiffs(
            diff.RemovedProviderTemplates,
            CatalogChangeKind.Removed);
        AddCatalogModelDiffs(
            diff.AddedModels,
            CatalogChangeKind.Added);
        AddCatalogModelDiffs(
            diff.ChangedModels,
            CatalogChangeKind.Updated);
        AddCatalogModelDiffs(
            diff.RemovedModels,
            CatalogChangeKind.Removed);

        if (diff.AddedProviderTemplates.Count == 0
            && diff.ChangedProviderTemplates.Count == 0
            && diff.RemovedProviderTemplates.Count == 0
            && diff.AddedModels.Count == 0
            && diff.ChangedModels.Count == 0
            && diff.RemovedModels.Count == 0)
        {
            CatalogReview.Add(new ModelSyncReviewItem(
                "✓",
                "No catalog changes",
                "The two immutable revisions have the same provider and model entries."));
        }
    }

    private void AddCatalogManifestDiffs(
        IReadOnlyList<CatalogManifestDiff> changes,
        CatalogChangeKind kind)
    {
        foreach (var manifest in changes)
        {
            CatalogReview.Add(new ModelSyncReviewItem(
                MarkerForCatalogChange(kind),
                $"Provider template · {manifest.ProviderTemplateId}",
                manifest.ChangedSections.Count == 0
                    ? CapabilityDisplayItem.Humanize(
                        kind.ToString())
                    : string.Join(
                        ", ",
                        manifest.ChangedSections.Select(section =>
                            CapabilityDisplayItem.Humanize(
                                section.ToString())))));
        }
    }

    private void AddCatalogModelDiffs(
        IReadOnlyList<CatalogModelMetadataDiff> changes,
        CatalogChangeKind kind)
    {
        foreach (var model in changes)
        {
            CatalogReview.Add(new ModelSyncReviewItem(
                MarkerForCatalogChange(kind),
                $"Model metadata · {model.ModelEntryId}",
                model.ChangedSections.Count == 0
                    ? CapabilityDisplayItem.Humanize(
                        kind.ToString())
                    : string.Join(
                        ", ",
                        model.ChangedSections.Select(section =>
                            CapabilityDisplayItem.Humanize(
                                section.ToString())))));
        }
    }

    private static string MarkerForCatalogChange(
        CatalogChangeKind change)
    {
        return change switch
        {
            CatalogChangeKind.Added => "+",
            CatalogChangeKind.Updated => "~",
            CatalogChangeKind.Removed => "−",
            _ => "?",
        };
    }

    private void LoadConnectionFields(
        ProviderTemplate? template,
        IReadOnlyList<ConnectionConfigEntry> values)
    {
        ConnectionFields.Clear();
        if (template is null)
        {
            return;
        }

        foreach (var spec in template.ConnectionFields.Where(field =>
                     field.ValueType != ConnectionFieldType.Credential))
        {
            var editor = new ConnectionFieldEditor(spec);
            var existing = values.FirstOrDefault(value =>
                string.Equals(
                    value.Key,
                    spec.Key,
                    StringComparison.Ordinal));
            editor.Value = FormatConnectionValue(existing?.Value);
            ConnectionFields.Add(editor);
        }
    }

    private bool TryBuildConnectionValues(
        out IReadOnlyList<ConnectionConfigEntry> values,
        out string? error)
    {
        var result = new List<ConnectionConfigEntry>();
        foreach (var editor in ConnectionFields)
        {
            if (!editor.TryBuild(out var value, out error))
            {
                values = [];
                return false;
            }

            if (value is not null)
            {
                result.Add(value);
            }
        }

        values = result;
        error = null;
        return true;
    }

    private void LoadParameterEditors(
        IReadOnlyList<ProviderParameterValue> values)
    {
        ClearParameterEditors();
        IReadOnlyList<ProviderParameterSpec> specs;
        if (SelectedModelRoute is null)
        {
            specs = SelectedTemplate?.ParameterSpecs ?? [];
        }
        else
        {
            specs = effectiveParameterSpecs;
        }

        if (specs.Count == 0)
        {
            return;
        }

        foreach (var spec in specs.Where(spec =>
                     !string.Equals(
                         spec.Level,
                         "hidden_internal",
                         StringComparison.Ordinal)))
        {
            var editor = new ProviderParameterEditor(spec);
            var existing = values.FirstOrDefault(value =>
                string.Equals(
                    value.ParameterId,
                    spec.Id,
                    StringComparison.Ordinal));
            if (existing is not null)
            {
                editor.Load(existing);
            }

            editor.PropertyChanged += (_, args) =>
            {
                if (args.PropertyName is
                    nameof(ProviderParameterEditor.Input) or
                    nameof(ProviderParameterEditor.UseProviderDefault))
                {
                    MarkRequestPreviewStale();
                    RefreshParameterEditorPolicy();
                }
            };
            allParameterEditors.Add(editor);
        }
        RefreshParameterEditorPolicy();
    }

    private void ClearParameterEditors()
    {
        allParameterEditors.Clear();
        ParameterEditors.Clear();
    }

    private void RefreshParameterEditorPolicy()
    {
        if (applyingParameterPolicy)
        {
            return;
        }

        applyingParameterPolicy = true;
        try
        {
            HashSet<string> visibleIds = [];
            var attempts = Math.Max(
                1,
                allParameterEditors.Count * 2);
            for (var attempt = 0;
                 attempt < attempts;
                 attempt++)
            {
                var explicitValues =
                    BuildExplicitParameterValues();
                visibleIds = allParameterEditors
                    .Where(editor =>
                        ParameterIsVisible(
                            editor.Spec,
                            explicitValues))
                    .Select(editor => editor.Id)
                    .ToHashSet(StringComparer.Ordinal);
                var hiddenExplicit =
                    allParameterEditors.Where(editor =>
                        !visibleIds.Contains(editor.Id)
                        && !editor.UseProviderDefault)
                    .ToArray();
                if (hiddenExplicit.Length == 0)
                {
                    break;
                }
                foreach (var editor in hiddenExplicit)
                {
                    editor.ClearHiddenValue();
                }
            }

            var explicitIds = allParameterEditors
                .Where(editor => !editor.UseProviderDefault)
                .Select(editor => editor.Id)
                .ToHashSet(StringComparer.Ordinal);
            var mutualExclusions = allParameterEditors
                .SelectMany(owner =>
                    owner.Spec.Conflicts
                        .Where(conflict =>
                            string.Equals(
                                conflict.Kind,
                                "mutually_exclusive",
                                StringComparison.Ordinal))
                        .Select(conflict => (
                            LeftId: owner.Id,
                            RightId: conflict.ParameterId,
                            Message: conflict.MessageKey)))
                .ToArray();
            foreach (var editor in allParameterEditors)
            {
                if (!visibleIds.Contains(editor.Id))
                {
                    editor.SetPolicy(
                        enabled: false,
                        message: string.Empty,
                        error: null);
                    continue;
                }

                var messages = new List<string>();
                string? error = null;
                var enabled = true;
                var isExplicit =
                    explicitIds.Contains(editor.Id);
                if (string.Equals(
                        editor.Spec.DefaultMode,
                        "explicit_required",
                        StringComparison.Ordinal)
                    && !isExplicit)
                {
                    error =
                        $"{editor.Label}: an explicit value is required.";
                    messages.Add(error);
                }

                foreach (var conflict in mutualExclusions.Where(
                             conflict =>
                                 string.Equals(
                                     conflict.LeftId,
                                     editor.Id,
                                     StringComparison.Ordinal)
                                 || string.Equals(
                                     conflict.RightId,
                                     editor.Id,
                                     StringComparison.Ordinal)))
                {
                    var otherId = string.Equals(
                        conflict.LeftId,
                        editor.Id,
                        StringComparison.Ordinal)
                        ? conflict.RightId
                        : conflict.LeftId;
                    var otherIsExplicit =
                        explicitIds.Contains(
                            otherId);
                    if (otherIsExplicit)
                    {
                        var message =
                            string.IsNullOrWhiteSpace(
                                conflict.Message)
                                ? $"{editor.Label} cannot be used with {otherId}."
                                : conflict.Message;
                        if (isExplicit)
                        {
                            error ??= message;
                        }
                        else
                        {
                            enabled = false;
                        }
                        messages.Add(message);
                    }
                }

                foreach (var conflict in editor.Spec.Conflicts.Where(
                             conflict =>
                                 string.Equals(
                                     conflict.Kind,
                                     "requires",
                                     StringComparison.Ordinal)))
                {
                    if (isExplicit
                        && !explicitIds.Contains(
                            conflict.ParameterId))
                    {
                        var message =
                            string.IsNullOrWhiteSpace(
                                conflict.MessageKey)
                                ? $"{editor.Label} requires {conflict.ParameterId}."
                                : conflict.MessageKey;
                        error ??= message;
                        messages.Add(message);
                    }
                }

                editor.SetPolicy(
                    enabled,
                    string.Join(
                        Environment.NewLine,
                        messages.Distinct(
                            StringComparer.Ordinal)),
                    error);
            }

            ParameterEditors.Clear();
            foreach (var editor in allParameterEditors.Where(
                         editor =>
                             visibleIds.Contains(editor.Id)))
            {
                ParameterEditors.Add(editor);
            }
        }
        finally
        {
            applyingParameterPolicy = false;
        }
    }

    private Dictionary<string, ProviderParameterLiteral>
        BuildExplicitParameterValues()
    {
        var values = new Dictionary<
            string,
            ProviderParameterLiteral>(
            StringComparer.Ordinal);
        foreach (var editor in allParameterEditors)
        {
            if (editor.TryGetExplicitLiteral(
                    out var literal)
                && literal is not null)
            {
                values[editor.Id] = literal;
            }
        }
        return values;
    }

    private static bool ParameterIsVisible(
        ProviderParameterSpec spec,
        IReadOnlyDictionary<
            string,
            ProviderParameterLiteral> explicitValues)
    {
        var condition = spec.Visibility;
        if (condition is null)
        {
            return true;
        }
        if (!explicitValues.TryGetValue(
                condition.ParameterId,
                out var actual))
        {
            return false;
        }
        var equal =
            string.Equals(
                actual.Type,
                condition.Value.Type,
                StringComparison.Ordinal)
            && JsonValuesEqual(
                actual.Value,
                condition.Value.Value);
        return condition.Operator switch
        {
            "equals" => equal,
            "not_equals" => !equal,
            _ => false,
        };
    }

    private static bool JsonValuesEqual(
        System.Text.Json.JsonElement left,
        System.Text.Json.JsonElement right)
    {
        if (left.ValueKind != right.ValueKind)
        {
            return false;
        }
        return left.ValueKind switch
        {
            System.Text.Json.JsonValueKind.Object =>
                JsonObjectsEqual(left, right),
            System.Text.Json.JsonValueKind.Array =>
                left.EnumerateArray().SequenceEqual(
                    right.EnumerateArray(),
                    JsonElementEqualityComparer.Instance),
            System.Text.Json.JsonValueKind.String =>
                string.Equals(
                    left.GetString(),
                    right.GetString(),
                    StringComparison.Ordinal),
            System.Text.Json.JsonValueKind.Number =>
                string.Equals(
                    left.GetRawText(),
                    right.GetRawText(),
                    StringComparison.Ordinal),
            System.Text.Json.JsonValueKind.True or
                System.Text.Json.JsonValueKind.False =>
                left.GetBoolean() == right.GetBoolean(),
            System.Text.Json.JsonValueKind.Null or
                System.Text.Json.JsonValueKind.Undefined => true,
            _ => false,
        };
    }

    private static bool JsonObjectsEqual(
        System.Text.Json.JsonElement left,
        System.Text.Json.JsonElement right)
    {
        var leftProperties = left.EnumerateObject()
            .ToDictionary(
                property => property.Name,
                property => property.Value,
                StringComparer.Ordinal);
        var rightProperties = right.EnumerateObject()
            .ToDictionary(
                property => property.Name,
                property => property.Value,
                StringComparer.Ordinal);
        return leftProperties.Count == rightProperties.Count
            && leftProperties.All(property =>
                rightProperties.TryGetValue(
                    property.Key,
                    out var other)
                && JsonValuesEqual(
                    property.Value,
                    other));
    }

    private sealed class JsonElementEqualityComparer :
        IEqualityComparer<System.Text.Json.JsonElement>
    {
        internal static JsonElementEqualityComparer Instance { get; } =
            new();

        public bool Equals(
            System.Text.Json.JsonElement x,
            System.Text.Json.JsonElement y) =>
            JsonValuesEqual(x, y);

        public int GetHashCode(
            System.Text.Json.JsonElement obj) =>
            StringComparer.Ordinal.GetHashCode(
                obj.GetRawText());
    }

    private void MarkRequestPreviewStale()
    {
        checked
        {
            previewRevision++;
        }
        RequestPreview =
            "Preset fields changed. Refresh to validate and regenerate the scalar-free preview.";
    }

    private void SchedulePresetControlRefresh()
    {
        if (suppressPresetControlRefresh
            || SelectedModelRoute is null)
        {
            return;
        }

        _ = RefreshPresetControlsAsync();
    }

    internal Task<bool> RefreshPresetControlsAsync() =>
        RefreshPresetControlsAsync(
            allowRenderedDefaultAdoption: true,
            CaptureSettingsLifecycleEpoch());

    private async Task<bool> RefreshPresetControlsAsync(
        bool allowRenderedDefaultAdoption,
        long lifecycleEpoch)
    {
        if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
        {
            return false;
        }

        var revision = checked(++presetControlRevision);
        var currentRouteRevision = routeRevision;
        if (!TryBuildPresetControlCandidate(
                out var candidate,
                out var candidateError)
            || candidate is null)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && revision == presetControlRevision)
            {
                PresetControlStatus = candidateError
                    ?? "Complete the reasoning and prompt-cache fields.";
            }
            return false;
        }

        try
        {
            var controls = await Task.Run(() => (
                Reasoning:
                    core.RenderReasoningControlCandidate(candidate),
                PromptCache:
                    core.RenderPromptCacheControlCandidate(candidate)));
            if (!IsSettingsLifecycleCurrent(lifecycleEpoch)
                || revision != presetControlRevision
                || currentRouteRevision != routeRevision
                || !string.Equals(
                    SelectedModelRoute?.Id,
                    candidate.ModelRouteId,
                    StringComparison.Ordinal))
            {
                return false;
            }

            var adoptedRenderedDefault = ApplyPresetControls(
                controls.Reasoning,
                controls.PromptCache,
                allowRenderedDefaultAdoption);
            return !adoptedRenderedDefault
                || await RefreshPresetControlsAsync(
                    allowRenderedDefaultAdoption: false,
                    lifecycleEpoch);
        }
        catch (Exception exception)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && revision == presetControlRevision)
            {
                PresetControlStatus = SafeError(
                    "Could not load the model-specific reasoning and prompt-cache controls.",
                    exception);
            }
            return false;
        }
    }

    private bool ApplyPresetControls(
        ReasoningControlModel reasoning,
        PromptCacheControlModel promptCache,
        bool allowRenderedDefaultAdoption)
    {
        ReplaceValues(ReasoningModes, reasoning.AllowedModes);
        ReplaceValues(
            ReasoningEfforts,
            reasoning.AllowedEfforts);
        ReplaceValues(
            ReasoningSummaries,
            reasoning.AllowedSummaries);

        var renderedEffort = reasoning.Settings.Effort;
        var shouldAdoptRenderedEffort =
            allowRenderedDefaultAdoption
            && string.Equals(
                ReasoningMode,
                "enabled",
                StringComparison.Ordinal)
            && string.IsNullOrWhiteSpace(ReasoningEffort)
            && string.Equals(
                reasoning.Settings.Mode,
                "enabled",
                StringComparison.Ordinal)
            && !string.IsNullOrWhiteSpace(renderedEffort)
            && !string.Equals(
                reasoning.State,
                "hidden",
                StringComparison.Ordinal)
            && !string.Equals(
                reasoning.EffortField,
                "hidden",
                StringComparison.Ordinal)
            && reasoning.AllowedEfforts.Contains(
                renderedEffort,
                StringComparer.Ordinal);
        var wasSuppressingRefresh =
            suppressPresetControlRefresh;
        suppressPresetControlRefresh = true;
        try
        {
            PreserveOpaqueReasoningState =
                reasoning.Settings.PreserveOpaqueState;
            if (shouldAdoptRenderedEffort)
            {
                ReasoningEffort = renderedEffort!;
            }
        }
        finally
        {
            suppressPresetControlRefresh =
                wasSuppressingRefresh;
        }

        ReplaceValues(
            PromptCacheModes,
            promptCache.AllowedModes);
        var allowedTtls = promptCache.AllowedTtls
            .Select(ttl => ttl.Kind)
            .ToList();
        if (promptCache.SupportsCustomTtl
            && !allowedTtls.Contains(
                "custom_seconds",
                StringComparer.Ordinal))
        {
            allowedTtls.Add("custom_seconds");
        }
        ReplaceValues(PromptCacheTtls, allowedTtls);

        ReasoningControlsEnabled =
            !string.Equals(
                reasoning.State,
                "hidden",
                StringComparison.Ordinal);
        var usesProviderDefaultReasoning =
            string.Equals(
                ReasoningMode,
                "provider_default",
                StringComparison.Ordinal);
        ReasoningEffortEnabled =
            ReasoningControlsEnabled
            && !usesProviderDefaultReasoning
            && !string.Equals(
                reasoning.EffortField,
                "hidden",
                StringComparison.Ordinal);
        ReasoningBudgetEnabled =
            ReasoningControlsEnabled
            && !usesProviderDefaultReasoning
            && !string.Equals(
                reasoning.BudgetField,
                "hidden",
                StringComparison.Ordinal);
        ReasoningSummaryEnabled =
            ReasoningControlsEnabled
            && !usesProviderDefaultReasoning
            && !string.Equals(
                reasoning.SummaryField,
                "hidden",
                StringComparison.Ordinal);
        PromptCacheControlsEnabled =
            !string.Equals(
                promptCache.State,
                "hidden",
                StringComparison.Ordinal);
        PromptCacheTtlEnabled =
            PromptCacheControlsEnabled
            && !string.Equals(
                promptCache.TtlField,
                "hidden",
                StringComparison.Ordinal);
        promptCacheSupportsCustomTtl =
            promptCache.SupportsCustomTtl;
        OnPropertyChanged(
            nameof(PromptCacheCustomTtlEnabled));
        PromptCacheContextReferenceEnabled =
            PromptCacheControlsEnabled
            && !string.Equals(
                promptCache.ContextReferenceField,
                "hidden",
                StringComparison.Ordinal);

        var details = new List<string>();
        if (reasoning.BudgetBounds is { } reasoningBounds)
        {
            details.Add(
                $"Reasoning budget {reasoningBounds.Minimum}–{reasoningBounds.Maximum} tokens.");
        }
        if (promptCache.CustomTtlBounds is { } cacheBounds)
        {
            details.Add(
                $"Custom cache TTL {cacheBounds.MinimumSeconds}–{cacheBounds.MaximumSeconds} seconds.");
        }
        details.AddRange(
            reasoning.Issues.Select(issue => issue.Message));
        details.AddRange(
            promptCache.Issues.Select(issue => issue.Message));
        if (SelectedConnection?.CredentialSlotRequired == true)
        {
            details.Add(
                "Opaque reasoning continuity is disabled for credential-bearing connections.");
        }
        PresetControlStatus = details.Count == 0
            ? "Core loaded the exact controls supported by this model route."
            : string.Join(" ", details);
        return shouldAdoptRenderedEffort;
    }

    private void ResetPresetControlPresentation()
    {
        checked
        {
            presetControlRevision++;
        }
        ReasoningModes.Clear();
        ReasoningEfforts.Clear();
        ReasoningSummaries.Clear();
        PromptCacheModes.Clear();
        PromptCacheTtls.Clear();
        ReasoningControlsEnabled = false;
        ReasoningEffortEnabled = false;
        ReasoningBudgetEnabled = false;
        ReasoningSummaryEnabled = false;
        PromptCacheControlsEnabled = false;
        PromptCacheTtlEnabled = false;
        promptCacheSupportsCustomTtl = false;
        PromptCacheContextReferenceEnabled = false;
        PresetControlStatus =
            "Choose a model route to load Core-owned reasoning and cache controls.";
    }

    private static void ReplaceValues(
        ObservableCollection<string> target,
        IEnumerable<string> values)
    {
        var replacement = values.ToArray();
        if (target.SequenceEqual(
                replacement,
                StringComparer.Ordinal))
        {
            return;
        }
        target.Clear();
        foreach (var value in replacement)
        {
            target.Add(value);
        }
    }

    private bool TryBuildPresetControlCandidate(
        out GenerationPreset? preset,
        out string? error)
    {
        var route = SelectedModelRoute;
        if (route is null)
        {
            preset = null;
            error = "Choose a model route first.";
            return false;
        }
        if (!TryParsePresetSettings(
                out var reasoning,
                out var promptCache,
                out error))
        {
            preset = null;
            return false;
        }

        var now = DateTimeOffset.UtcNow;
        preset = new GenerationPreset
        {
            Id = string.IsNullOrWhiteSpace(PresetId)
                ? "unsaved-control-candidate"
                : PresetId.Trim(),
            ModelRouteId = route.Id,
            DisplayName =
                string.IsNullOrWhiteSpace(PresetDisplayName)
                    ? "Unsaved control candidate"
                    : PresetDisplayName.Trim(),
            Values = [],
            Reasoning = reasoning,
            PromptCache = promptCache,
            CreatedAt = now,
            UpdatedAt = now,
        };
        error = null;
        return true;
    }

    private bool TryParsePresetSettings(
        out GenerationReasoningSettings reasoning,
        out GenerationPromptCacheSettings promptCache,
        out string? error)
    {
        var usesProviderDefaultReasoning =
            string.Equals(
                ReasoningMode,
                "provider_default",
                StringComparison.Ordinal);
        uint? budgetTokens = null;
        if (!usesProviderDefaultReasoning
            && !string.IsNullOrWhiteSpace(ReasoningBudgetTokens))
        {
            if (!uint.TryParse(
                    ReasoningBudgetTokens,
                    out var parsedBudget)
                || parsedBudget == 0)
            {
                reasoning = new GenerationReasoningSettings();
                promptCache = new GenerationPromptCacheSettings();
                error =
                    "Reasoning budget must be a positive whole number.";
                return false;
            }

            budgetTokens = parsedBudget;
        }

        uint? customTtl = null;
        if (PromptCacheTtl == "custom_seconds")
        {
            if (!uint.TryParse(
                    PromptCacheCustomSeconds,
                    out var parsedTtl)
                || parsedTtl == 0)
            {
                reasoning = new GenerationReasoningSettings();
                promptCache = new GenerationPromptCacheSettings();
                error =
                    "Custom cache TTL must be a positive whole number of seconds.";
                return false;
            }

            customTtl = parsedTtl;
        }

        reasoning = new GenerationReasoningSettings
        {
            Mode = ReasoningMode,
            Effort = usesProviderDefaultReasoning
                ? null
                : NullIfBlank(ReasoningEffort),
            BudgetTokens = budgetTokens,
            Summary = usesProviderDefaultReasoning
                ? "provider_default"
                : ReasoningSummary,
            PreserveOpaqueState =
                OpaqueReasoningContinuityAllowed
                && PreserveOpaqueReasoningState,
        };
        promptCache = new GenerationPromptCacheSettings
        {
            Mode = PromptCacheMode,
            Ttl = new GenerationPromptCacheTtl
            {
                Kind = PromptCacheTtl,
                Seconds = customTtl,
            },
            ContextReference =
                NullIfBlank(PromptCacheContextReference),
        };
        error = null;
        return true;
    }

    private void ClearProviderDefaultReasoningOverrides()
    {
        SetProperty(
            ref reasoningEffort,
            string.Empty,
            nameof(ReasoningEffort));
        SetProperty(
            ref reasoningBudgetTokens,
            string.Empty,
            nameof(ReasoningBudgetTokens));
        SetProperty(
            ref reasoningSummary,
            "provider_default",
            nameof(ReasoningSummary));
    }

    private void ReplaceTemplates(
        IReadOnlyList<ProviderTemplate> templates)
    {
        var selectedId = SelectedTemplate?.Id;
        ProviderTemplates.Clear();
        foreach (var template in templates)
        {
            ProviderTemplates.Add(template);
        }

        SetSelectedTemplate(
            ProviderTemplates.FirstOrDefault(template =>
                string.Equals(
                    template.Id,
                    selectedId,
                    StringComparison.Ordinal))
            ?? ProviderTemplates.FirstOrDefault());
    }

    private void SetSelectedTemplate(
        ProviderTemplate? value)
    {
        if (SetProperty(ref selectedTemplate, value)
            && value is not null
            && SelectedConnection is null
            && IsDirectConnectionMode)
        {
            ApplyTemplate(value);
        }
    }

    private void ReplaceConnections(
        IReadOnlyList<ProviderConnection> connections)
    {
        ProviderConnections.Clear();
        foreach (var connection in connections)
        {
            ProviderConnections.Add(connection);
        }
    }

    private List<AssistantModelRouteOption>
        LoadAssistantModelRouteOptions(
            IReadOnlyList<ProviderConnection> connections,
            string? applicationDefaultRouteId,
            string? applicationDefaultPresetId)
    {
        if (string.IsNullOrWhiteSpace(
                applicationDefaultRouteId)
            || string.IsNullOrWhiteSpace(
                applicationDefaultPresetId))
        {
            return [];
        }

        var matches = new List<(
            ProviderConnection Connection,
            ModelRoute Route)>();
        foreach (var connection in connections)
        {
            foreach (var route in
                     core.ListModelRoutes(connection.Id))
            {
                if (string.Equals(
                        route.Id,
                        applicationDefaultRouteId,
                        StringComparison.Ordinal)
                    && string.Equals(
                        route.ConnectionId,
                        connection.Id,
                        StringComparison.Ordinal))
                {
                    matches.Add((connection, route));
                }
            }
        }

        if (matches.Count != 1)
        {
            return [];
        }

        var (selectedConnection, selectedRoute) =
            matches[0];
        if (selectedRoute.Availability !=
            ModelAvailability.Available)
        {
            return [];
        }

        var presetMatches =
            core.ListGenerationPresets(
                    selectedRoute.Id)
                .Where(preset => string.Equals(
                    preset.Id,
                    applicationDefaultPresetId,
                    StringComparison.Ordinal))
                .ToList();
        if (presetMatches.Count != 1)
        {
            return [];
        }

        try
        {
            core.ValidateGenerationPreset(
                selectedRoute.Id,
                presetMatches[0].Id);
            if (selectedConnection.CredentialSlotRequired
                && credentials.Get(
                    selectedConnection.Id) is null)
            {
                return [];
            }
        }
        catch
        {
            return [];
        }

        return
        [
            new AssistantModelRouteOption(
                selectedConnection.Id,
                selectedConnection.DisplayName,
                selectedRoute,
                presetMatches[0]),
        ];
    }

    private void ReplaceAssistantModelRoutes(
        IReadOnlyList<AssistantModelRouteOption> routes)
    {
        AssistantModelRoutes.Clear();
        foreach (var route in routes)
        {
            AssistantModelRoutes.Add(route);
        }

        SetSelectedAssistantModelRoute(
            AssistantModelRoutes.Count == 1
            ? AssistantModelRoutes[0]
            : null);
    }

    private void SetSelectedAssistantModelRoute(
        AssistantModelRouteOption? route)
    {
        SetProperty(
            ref selectedAssistantModelRoute,
            route,
            nameof(SelectedAssistantModelRoute));
        if (route is null && assistantConsentRequested)
        {
            assistantConsentRequested = false;
            OnPropertyChanged(
                nameof(AssistantConsentRequested));
        }
        AssistantModelRouteSelectionSummary =
            route switch
            {
                not null =>
                    $"Using the executable app-default route and preset: {route.Label} · {route.Preset.DisplayName}. Documents are sent only after reviewing and approving the exact grant.",
                _ =>
                    "No executable app-default route and preset are available. Select and save an available model route and preset, and ensure its required credential exists.",
            };
        NotifyAssistantRouteState();
        NotifyAssistantGrantActionState();
    }

    private void UpsertConnectionLocally(
        ProviderConnection connection)
    {
        for (var index = 0;
             index < ProviderConnections.Count;
             index++)
        {
            if (string.Equals(
                    ProviderConnections[index].Id,
                    connection.Id,
                    StringComparison.Ordinal))
            {
                ProviderConnections[index] = connection;
                return;
            }
        }
        ProviderConnections.Add(connection);
    }

    private void RemoveConnectionLocally(string connectionId)
    {
        for (var index = ProviderConnections.Count - 1;
             index >= 0;
             index--)
        {
            if (string.Equals(
                    ProviderConnections[index].Id,
                    connectionId,
                    StringComparison.Ordinal))
            {
                ProviderConnections.RemoveAt(index);
            }
        }
        for (var index = AssistantModelRoutes.Count - 1;
             index >= 0;
             index--)
        {
            if (string.Equals(
                    AssistantModelRoutes[index].ConnectionId,
                    connectionId,
                    StringComparison.Ordinal))
            {
                AssistantModelRoutes.RemoveAt(index);
            }
        }
        if (SelectedAssistantModelRoute is { } selected
            && string.Equals(
                selected.ConnectionId,
                connectionId,
                StringComparison.Ordinal))
        {
            SetSelectedAssistantModelRoute(
                AssistantModelRoutes.Count == 1
                    ? AssistantModelRoutes[0]
                    : null);
        }
    }

    private void UpsertPresetLocally(GenerationPreset preset)
    {
        preset = ApplyOpaqueReasoningPolicy(preset);
        for (var index = 0;
             index < GenerationPresets.Count;
             index++)
        {
            if (string.Equals(
                    GenerationPresets[index].Id,
                    preset.Id,
                    StringComparison.Ordinal))
            {
                GenerationPresets[index] = preset;
                return;
            }
        }
        GenerationPresets.Add(preset);
    }

    private void RemovePresetLocally(string presetId)
    {
        for (var index = GenerationPresets.Count - 1;
             index >= 0;
             index--)
        {
            if (string.Equals(
                    GenerationPresets[index].Id,
                    presetId,
                    StringComparison.Ordinal))
            {
                GenerationPresets.RemoveAt(index);
            }
        }
    }

    private void SelectFirstPresetOrBeginNew()
    {
        if (GenerationPresets.Count == 0)
        {
            BeginNewPreset();
        }
        else
        {
            SelectGenerationPreset(GenerationPresets[0]);
        }
    }

    private async Task MonitorModelSyncAsync(
        string jobId,
        ProviderSelectionToken selection,
        long lifecycleEpoch,
        CancellationToken cancellationToken)
    {
        var expectedConnectionId =
            selection.ConnectionId
            ?? throw new CoreInteropException(
                "A model-sync monitor requires an exact connection binding.");
        try
        {
            while (!cancellationToken.IsCancellationRequested
                   && IsSettingsLifecycleCurrent(
                       lifecycleEpoch)
                   && selectionGuard.IsCurrent(selection))
            {
                var snapshot = await Task.Run(() =>
                {
                    var events =
                        core.PollProviderModelSyncEvents(
                            jobId,
                            128);
                    var job = core.GetProviderModelSync(
                        jobId,
                        expectedConnectionId);
                    if (!string.Equals(
                            job.Id,
                            jobId,
                            StringComparison.Ordinal)
                        || !string.Equals(
                            job.ConnectionId,
                            expectedConnectionId,
                            StringComparison.Ordinal))
                    {
                        throw new CoreInteropException(
                            "The model-sync monitor received an unrelated job.");
                    }
                    return (Events: events, Job: job);
                }, cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
                if (!IsSettingsLifecycleCurrent(lifecycleEpoch)
                    || !selectionGuard.IsCurrent(selection))
                {
                    return;
                }

                foreach (var modelSyncEvent in snapshot.Events.Where(
                             item => string.Equals(
                                 item.JobId,
                                 jobId,
                                 StringComparison.Ordinal)))
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    if (!IsSettingsLifecycleCurrent(
                            lifecycleEpoch))
                    {
                        return;
                    }
                    if (displayedModelSyncEvents.Add((
                            modelSyncEvent.JobId,
                            modelSyncEvent.Sequence)))
                    {
                        ModelSyncReview.Add(new ModelSyncReviewItem(
                            modelSyncEvent.State ==
                                ModelSyncStates.DiffReadyAwaitingReview
                                ? "✓"
                                : "●",
                            modelSyncEvent.Progress.MessageKey,
                            $"{modelSyncEvent.Progress.CompletedSteps}/{modelSyncEvent.Progress.TotalSteps} · revision {modelSyncEvent.JobRevision}"));
                    }
                }

                cancellationToken.ThrowIfCancellationRequested();
                if (!IsSettingsLifecycleCurrent(lifecycleEpoch)
                    || !selectionGuard.IsCurrent(selection))
                {
                    return;
                }

                ApplyModelSyncJob(snapshot.Job);
                if (snapshot.Events.Count > 0)
                {
                    await Task.Run(() =>
                    {
                        foreach (var modelSyncEvent in snapshot.Events)
                        {
                            _ = core.AckProviderModelSyncEvent(
                                jobId,
                                modelSyncEvent.Sequence);
                        }
                    }, cancellationToken);
                    cancellationToken.ThrowIfCancellationRequested();
                }
                if (snapshot.Job.State ==
                    ModelSyncStates.DiffReadyAwaitingReview)
                {
                    return;
                }

                if (snapshot.Job.State is
                    ModelSyncStates.Completed or
                    ModelSyncStates.Cancelled or
                    ModelSyncStates.Failed or
                    ModelSyncStates.Interrupted)
                {
                    if (snapshot.Job.State ==
                        ModelSyncStates.Completed)
                    {
                        try
                        {
                            cancellationToken.ThrowIfCancellationRequested();
                            await ReloadSelectedConnectionRoutesAsync(
                                selection,
                                lifecycleEpoch);
                            cancellationToken.ThrowIfCancellationRequested();
                        }
                        catch (OperationCanceledException)
                            when (cancellationToken
                                .IsCancellationRequested)
                        {
                            throw;
                        }
                        catch
                        {
                            if (IsSettingsLifecycleCurrent(
                                    lifecycleEpoch)
                                && selectionGuard.IsCurrent(
                                    selection))
                            {
                                ProviderStatus =
                                    "The approved model diff was committed, but the refreshed route view could not be loaded. Reload settings to reconcile.";
                            }
                        }
                    }

                    return;
                }

                await Task.Delay(
                    TimeSpan.FromMilliseconds(250),
                    cancellationToken);
                cancellationToken.ThrowIfCancellationRequested();
            }
        }
        catch (OperationCanceledException)
            when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            if (IsSettingsLifecycleCurrent(lifecycleEpoch)
                && selectionGuard.IsCurrent(selection))
            {
                ProviderStatus = SafeError(
                    "Model synchronization monitoring stopped.",
                    exception);
            }
        }
    }

    private void ApplyModelSyncJob(ModelSyncJob job)
    {
        if (activeModelSyncJobId is { } currentJobId
            && !string.Equals(
                currentJobId,
                job.Id,
                StringComparison.Ordinal))
        {
            throw new CoreInteropException(
                "The model-sync response does not match the active job.");
        }
        if (SelectedConnection is { } connection
            && !string.Equals(
                connection.Id,
                job.ConnectionId,
                StringComparison.Ordinal))
        {
            throw new CoreInteropException(
                "The model-sync response belongs to another connection.");
        }

        activeModelSyncJobId = job.Id;
        activeModelSyncReviewSha256 = job.Review?.Sha256;
        if (job.Review is { } review)
        {
            PopulateModelSyncReview(review);
        }

        ProviderStatus = job.State switch
        {
            ModelSyncStates.Created =>
                "Model synchronization created. No provider request has been replayed.",
            ModelSyncStates.Fetching =>
                "Fetching models from the approved credential origin…",
            ModelSyncStates.Interrupted =>
                "Model synchronization was interrupted and will not restart automatically.",
            ModelSyncStates.DiffReadyAwaitingReview =>
                $"Review required before commit · digest {job.Review?.Sha256 ?? "missing"}.",
            ModelSyncStates.Committing =>
                "Committing the approved model diff atomically…",
            ModelSyncStates.Completed =>
                "The approved model diff was committed.",
            ModelSyncStates.Cancelled =>
                "Model synchronization cancelled.",
            ModelSyncStates.Failed =>
                $"Model synchronization failed · {job.Failure?.Code ?? "unknown"}.",
            _ => "Unknown model synchronization state.",
        };

        if (job.State is
            ModelSyncStates.Completed or
            ModelSyncStates.Cancelled or
            ModelSyncStates.Failed)
        {
            activeModelSyncJobId = null;
            activeModelSyncReviewSha256 = null;
        }
        NotifyModelSyncActionState();
    }

    private void PopulateModelSyncReview(ModelSyncReview review)
    {
        ModelSyncReview.Clear();
        var diff = review.Diff;
        ModelSyncReview.Add(new ModelSyncReviewItem(
            "#",
            "Exact review digest",
            review.Sha256));
        ModelSyncReview.Add(new ModelSyncReviewItem(
            "↗",
            "Credential destination",
            $"{diff.Provenance.ApiOrigin}{diff.Provenance.EndpointPath} · redirects remain credential-free."));
        ModelSyncReview.Add(new ModelSyncReviewItem(
            "i",
            "Listing source",
            $"{diff.Provenance.Source} · {diff.Provenance.ApiFamily}"));
        ModelSyncReview.Add(new ModelSyncReviewItem(
            "i",
            "Listing freshness",
            $"Observed {diff.ObservedAt.LocalDateTime:g} · {diff.Provenance.PagesFetched} page(s) · {diff.Provenance.ResponseBytes:N0} response byte(s)"));
        foreach (var id in diff.NewlySeenModelRouteIds)
        {
            ModelSyncReview.Add(new ModelSyncReviewItem(
                "+",
                "New model route",
                id));
        }

        foreach (var id in diff.MissingModelRouteIds)
        {
            ModelSyncReview.Add(new ModelSyncReviewItem(
                "!",
                "Temporarily missing",
                $"{id} is retained and its miss count advances only after approval."));
        }

        foreach (var id in
            diff.RoutesRequiringPresetConfiguration)
        {
            ModelSyncReview.Add(new ModelSyncReviewItem(
                "○",
                "Preset configuration required",
                id));
        }

        ModelSyncReview.Add(new ModelSyncReviewItem(
            "i",
            "Capability evidence",
            $"{diff.CapabilityObservations.Count} source-attributed observation(s) in this review."));
        if (diff.NewlySeenModelRouteIds.Count == 0
            && diff.MissingModelRouteIds.Count == 0
            && diff.RoutesRequiringPresetConfiguration.Count == 0)
        {
            ModelSyncReview.Add(new ModelSyncReviewItem(
                "✓",
                "No route changes",
                "The reviewed listing confirms the existing route graph."));
        }
    }

    private async Task ReloadSelectedConnectionRoutesAsync(
        ProviderSelectionToken selection,
        long lifecycleEpoch)
    {
        if (!IsSettingsLifecycleCurrent(lifecycleEpoch))
        {
            return;
        }

        var connection = SelectedConnection;
        if (connection is null)
        {
            return;
        }

        var routes = await Task.Run(() =>
            core.ListModelRoutes(connection.Id));
        if (IsSettingsLifecycleCurrent(lifecycleEpoch)
            && selectionGuard.IsCurrent(selection))
        {
            ReplaceRoutes(routes);
        }
    }

    private void StopModelSyncMonitoring()
    {
        modelSyncMonitoring?.Cancel();
        modelSyncMonitoring?.Dispose();
        modelSyncMonitoring = null;
        activeModelSyncJobId = null;
        activeModelSyncReviewSha256 = null;
        NotifyModelSyncActionState();
    }

    private void ReplaceRoutes(IReadOnlyList<ModelRoute> routes)
    {
        ModelRoutes.Clear();
        foreach (var route in routes)
        {
            ModelRoutes.Add(route);
        }
    }

    private void ReplacePresets(
        IReadOnlyList<GenerationPreset> presets)
    {
        GenerationPresets.Clear();
        foreach (var preset in presets)
        {
            GenerationPresets.Add(
                ApplyOpaqueReasoningPolicy(preset));
        }
    }

    private bool OpaqueReasoningContinuityAllowed =>
        SelectedConnection is
        {
            CredentialSlotRequired: false,
        };

    private GenerationPreset ApplyOpaqueReasoningPolicy(
        GenerationPreset preset)
    {
        if (OpaqueReasoningContinuityAllowed
            || !preset.Reasoning.PreserveOpaqueState)
        {
            return preset;
        }

        return preset with
        {
            Reasoning = preset.Reasoning with
            {
                PreserveOpaqueState = false,
            },
        };
    }

    private bool TryBuildPresetCandidate(
        out GenerationPreset? preset,
        out string? error)
    {
        var route = SelectedModelRoute;
        if (route is null)
        {
            preset = null;
            error = "Choose a model route first.";
            return false;
        }

        var id = PresetId.Trim();
        var displayName = PresetDisplayName.Trim();
        if (id.Length == 0 || displayName.Length == 0)
        {
            preset = null;
            error = "Preset ID and display name are required.";
            return false;
        }
        if (SelectedGenerationPreset is { } selected
            && !string.Equals(
                selected.Id,
                id,
                StringComparison.Ordinal))
        {
            preset = null;
            error =
                "An existing preset ID is immutable. Choose New preset to create another preset.";
            return false;
        }

        var values = new List<ProviderParameterValue>();
        foreach (var editor in ParameterEditors)
        {
            if (!editor.TryBuild(
                    out var value,
                    out var parameterError)
                || value is null)
            {
                preset = null;
                error = parameterError
                    ?? "A provider parameter is invalid.";
                return false;
            }

            values.Add(value);
        }

        if (!TryParsePresetSettings(
                out var reasoning,
                out var promptCache,
                out error))
        {
            preset = null;
            error ??=
                "Reasoning or prompt-cache settings are invalid.";
            return false;
        }

        var previous = GenerationPresets.FirstOrDefault(item =>
            string.Equals(item.Id, id, StringComparison.Ordinal));
        var now = DateTimeOffset.UtcNow;
        preset = new GenerationPreset
        {
            Id = id,
            ModelRouteId = route.Id,
            DisplayName = displayName,
            Values = values,
            Reasoning = reasoning,
            PromptCache = promptCache,
            CreatedAt = previous?.CreatedAt ?? now,
            UpdatedAt = now,
        };
        error = null;
        return true;
    }

    private static string FormatRequestPreview(
        ProviderRequestPreview preview)
    {
        var shape = preview.Preview;
        var lines = new List<string>
        {
            $"redaction_version: {preview.RedactionVersion}",
            $"method: {shape.Method}",
            $"origin: {shape.Origin}",
            $"path: {shape.Path}",
            "header_names:",
        };
        if (shape.HeaderNames.Count == 0)
        {
            lines.Add("  (none)");
        }
        else
        {
            foreach (var name in shape.HeaderNames)
            {
                lines.Add($"  - {name}");
            }
        }

        lines.Add("body_shape:");
        if (shape.Body is null)
        {
            lines.Add("  (none)");
        }
        else
        {
            AppendRequestBodyShape(
                lines,
                shape.Body,
                indent: 2,
                depth: 0);
        }

        lines.Add(
            "privacy_flags: private_message=false, credential_value=false, opaque_reasoning_state=false");
        return string.Join(Environment.NewLine, lines);
    }

    private static void AppendRequestBodyShape(
        ICollection<string> lines,
        ProviderRequestBodyShape shape,
        int indent,
        int depth)
    {
        var prefix = new string(' ', indent);
        lines.Add($"{prefix}kind: {shape.Kind}");
        if (shape.Truncated is { } truncated)
        {
            lines.Add(
                $"{prefix}truncated: {truncated.ToString().ToLowerInvariant()}");
        }

        if (depth >= 12)
        {
            lines.Add($"{prefix}(nested shape depth limited)");
            return;
        }

        if (shape.Fields is { Count: > 0 } fields)
        {
            lines.Add($"{prefix}fields:");
            foreach (var field in fields.Take(256))
            {
                lines.Add($"{prefix}  - name: {field.Name}");
                AppendRequestBodyShape(
                    lines,
                    field.Shape,
                    indent + 6,
                    depth + 1);
            }
            if (fields.Count > 256)
            {
                lines.Add($"{prefix}  (field list limited)");
            }
        }

        if (shape.Items is { Count: > 0 } items)
        {
            lines.Add($"{prefix}items:");
            foreach (var item in items.Take(256))
            {
                AppendRequestBodyShape(
                    lines,
                    item,
                    indent + 2,
                    depth + 1);
            }
            if (items.Count > 256)
            {
                lines.Add($"{prefix}  (item list limited)");
            }
        }
    }

    private static string FormatConnectionValue(
        ConnectionConfigValue? value)
    {
        if (value is null)
        {
            return string.Empty;
        }

        return value.Value.ValueKind switch
        {
            System.Text.Json.JsonValueKind.String =>
                value.Value.GetString() ?? string.Empty,
            _ => value.Value.GetRawText(),
        };
    }

    private ProviderNetworkModeOption FindNetworkMode(
        ProviderNetworkMode mode) =>
        NetworkModes.First(option => option.Mode == mode);

    private bool TryBuildDiscoveryConnectionOptions(
        out ProviderDiscoveryConnectionOptions? options,
        out string? error)
    {
        if (!uint.TryParse(
                TimeoutSeconds,
                out var timeout)
            || timeout is 0 or > 600)
        {
            options = null;
            error =
                "Timeout must be a whole number from 1 to 600.";
            return false;
        }
        if (!TryBuildConnectionValues(
                out var values,
                out error))
        {
            options = null;
            return false;
        }
        if (SelectedNetworkMode is not { } networkMode)
        {
            options = null;
            error =
                "Choose the connection network boundary.";
            return false;
        }
        if (!TryBuildLocalNetworkApproval(
                ApiOrigin.Trim(),
                networkMode.Mode,
                out var approval,
                out error))
        {
            options = null;
            return false;
        }
        options = new ProviderDiscoveryConnectionOptions
        {
            Values = values,
            ApiBasePath = NullIfBlank(ApiBasePath),
            TimeoutSeconds = timeout,
            NetworkMode = networkMode.Mode,
            LocalNetworkApproval = approval,
        };
        error = null;
        return true;
    }

    private bool TryBuildLocalNetworkApproval(
        string apiOrigin,
        ProviderNetworkMode networkMode,
        out ProviderLocalNetworkApproval? approval,
        out string? error)
    {
        if (networkMode !=
            ProviderNetworkMode.ApprovedLocalNetwork)
        {
            approval = null;
            error = null;
            return true;
        }
        if (!LocalNetworkAccessApproved)
        {
            approval = null;
            error =
                "Explicitly approve the exact LAN origin and address list before saving.";
            return false;
        }

        var approvedOrigin = LocalNetworkOrigin.Trim();
        if (!string.Equals(
                apiOrigin,
                approvedOrigin,
                StringComparison.Ordinal))
        {
            approval = null;
            error =
                "The approved LAN origin must exactly match the API origin.";
            return false;
        }

        var rawAddresses = LocalNetworkAddresses.Split(
            [',', ';', '\r', '\n', ' ', '\t'],
            StringSplitOptions.RemoveEmptyEntries
            | StringSplitOptions.TrimEntries);
        if (rawAddresses.Length is < 1 or > 16)
        {
            approval = null;
            error =
                "Enter from 1 to 16 exact RFC1918 IPv4 or ULA IPv6 addresses.";
            return false;
        }

        var addresses = new HashSet<IPAddress>();
        foreach (var rawAddress in rawAddresses)
        {
            if (!IPAddress.TryParse(
                    rawAddress,
                    out var address)
                || !IsPrivateLanAddress(address))
            {
                approval = null;
                error =
                    $"{rawAddress} is not an RFC1918 IPv4 or ULA IPv6 address.";
                return false;
            }
            if (!addresses.Add(address))
            {
                approval = null;
                error =
                    $"The exact address {address} is duplicated.";
                return false;
            }
        }

        approval = new ProviderLocalNetworkApproval
        {
            Origin = approvedOrigin,
            Addresses = addresses
                .Select(address => address.ToString())
                .Order(StringComparer.Ordinal)
                .ToArray(),
        };
        error = null;
        return true;
    }

    private static bool LocalNetworkApprovalsEqual(
        ProviderLocalNetworkApproval? left,
        ProviderLocalNetworkApproval? right)
    {
        if (left is null || right is null)
        {
            return left is null && right is null;
        }
        return string.Equals(
                left.Origin,
                right.Origin,
                StringComparison.Ordinal)
            && left.Addresses.ToHashSet(
                    StringComparer.Ordinal)
                .SetEquals(right.Addresses);
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

    private static string? NullIfBlank(string value)
    {
        var normalized = value.Trim();
        return normalized.Length == 0 ? null : normalized;
    }

    private static string CreateConnectionId() =>
        $"connection-{Guid.NewGuid():N}";

    private static string SafeError(
        string prefix,
        Exception exception)
    {
        return exception is CoreInteropException interop
            ? $"{prefix} {interop.Code ?? "core_error"}."
            : prefix;
    }

}
