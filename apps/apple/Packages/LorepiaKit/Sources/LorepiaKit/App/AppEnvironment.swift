import Foundation

@MainActor
public final class AppEnvironment {
    public let runtimeMode: CoreRuntimeMode
    public let sharedState: SharedAppState
    public let coreStatusViewModel: CoreStatusViewModel
    public let libraryViewModel: LibraryViewModel
    public let chatViewModel: ChatViewModel
    public let importReviewViewModel: ImportReviewViewModel
    public let settingsViewModel: SettingsViewModel

    public init(
        coreClient: any CoreClient,
        runtimeMode: CoreRuntimeMode,
        characters: [LibraryCharacter] = []
    ) {
        self.runtimeMode = runtimeMode
        sharedState = SharedAppState()
        coreStatusViewModel = CoreStatusViewModel(
            client: coreClient,
            runtimeMode: runtimeMode
        )
        libraryViewModel = LibraryViewModel(characters: characters)
        chatViewModel = ChatViewModel(previewEnabled: runtimeMode == .preview)
        importReviewViewModel = ImportReviewViewModel(
            previewEnabled: runtimeMode == .preview
        )
        settingsViewModel = SettingsViewModel(runtimeMode: runtimeMode)
    }

    public static func makeDefault(dataRoot: URL) -> AppEnvironment {
        let selection = CoreClientFactory.make(dataRoot: dataRoot)
        let characters = selection.mode == .preview
            ? LibraryCharacter.previewCharacters
            : []
        return AppEnvironment(
            coreClient: selection.client,
            runtimeMode: selection.mode,
            characters: characters
        )
    }

    public func selectCharacter(_ character: LibraryCharacter) {
        sharedState.selectCharacter(character)
        chatViewModel.setCharacter(character)
    }

    public func prepareImport(from url: URL) {
        let candidate = ImportCandidate(sourceURL: url)
        sharedState.setPendingImport(candidate)
        importReviewViewModel.select(candidate)
    }
}
