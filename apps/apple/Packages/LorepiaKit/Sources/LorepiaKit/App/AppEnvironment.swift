import Foundation

@MainActor
public final class AppEnvironment {
    public let runtimeMode: CoreRuntimeMode
    public let sharedState: SharedAppState
    public let coreStatusViewModel: CoreStatusViewModel
    public let libraryViewModel: LibraryViewModel
    public let conversationListViewModel: ConversationListViewModel
    public let chatViewModel: ChatViewModel
    public let importReviewViewModel: ImportReviewViewModel
    public let settingsViewModel: SettingsViewModel
    public let providerConfigurationStore: ProviderConfigurationStore
    private let coreClient: any CoreClient
    private var hasStarted = false

    public init(
        coreClient: any CoreClient,
        runtimeMode: CoreRuntimeMode,
        nativeStagingDirectory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LorePia-native-staging", isDirectory: true),
        credentialStore: any CredentialStore,
        characters: [LibraryCharacter] = []
    ) {
        self.coreClient = coreClient
        self.runtimeMode = runtimeMode
        let providerConfiguration = ProviderConfigurationStore()
        providerConfigurationStore = providerConfiguration
        sharedState = SharedAppState()
        coreStatusViewModel = CoreStatusViewModel(
            client: coreClient,
            runtimeMode: runtimeMode
        )
        let library = LibraryViewModel(
            client: coreClient,
            characters: characters
        )
        libraryViewModel = library
        conversationListViewModel = ConversationListViewModel(client: coreClient)
        chatViewModel = ChatViewModel(
            client: coreClient,
            credentialStore: credentialStore,
            runtimeMode: runtimeMode,
            providerConfigurationStore: providerConfiguration
        )
        importReviewViewModel = ImportReviewViewModel(
            client: coreClient,
            stager: ImportFileStager(directory: nativeStagingDirectory),
            libraryViewModel: library
        )
        settingsViewModel = SettingsViewModel(
            client: coreClient,
            credentialStore: credentialStore,
            runtimeMode: runtimeMode,
            providerConfigurationStore: providerConfiguration
        )
    }

    public static func makeDefault(dataRoot: URL) -> AppEnvironment {
        let selection = CoreClientFactory.make(dataRoot: dataRoot)
        let credentialStore = KeychainCredentialStore(
            service: "dev.lorepia.provider-credentials"
        )
        return AppEnvironment(
            coreClient: selection.client,
            runtimeMode: selection.mode,
            nativeStagingDirectory: dataRoot.appendingPathComponent(
                "native-staging",
                isDirectory: true
            ),
            credentialStore: credentialStore
        )
    }

    public func start() async {
        guard !hasStarted else {
            return
        }
        hasStarted = true
        await coreStatusViewModel.refresh()
        await libraryViewModel.refresh()
        await conversationListViewModel.refresh()
        await settingsViewModel.refresh()
        await settingsViewModel.providerSetupViewModel.refresh()
    }

    /// Performs a fail-closed validation for executable launch smoke tests.
    ///
    /// View models intentionally convert failures into UI state. A process
    /// smoke must call the client directly so a missing binding or unhealthy
    /// database produces a non-zero exit instead of a false green result.
    public func validateForLaunchSmoke() async throws {
        guard runtimeMode == .live else {
            throw CoreClientFailure.invalidResponse(
                "Launch smoke requires the live Rust core."
            )
        }

        let version = try await coreClient.version()
        let versions = try await coreClient.apiVersions()
        let health = try await coreClient.health()
        try CoreRuntimeContract.validate(versions)
        guard !version.isEmpty,
              version == versions.coreVersion,
              version == health.coreVersion,
              health.isHealthy
        else {
            throw CoreClientFailure.invalidResponse(
                "Core version or health validation failed."
            )
        }
    }

    public func selectCharacter(_ character: LibraryCharacter) async {
        sharedState.selectCharacter(character)
        await chatViewModel.setCharacter(character)
    }

    public func selectConversation(_ item: ConversationListItem) async {
        guard let character = item.character else {
            return
        }
        sharedState.selectCharacter(character)
        await chatViewModel.setConversation(
            item.conversation,
            character: character
        )
    }

    public func prepareImport(from url: URL) async {
        let candidate = ImportCandidate(sourceURL: url)
        sharedState.setPendingImport(candidate)
        await importReviewViewModel.inspect(sourceURL: url)
    }
}
