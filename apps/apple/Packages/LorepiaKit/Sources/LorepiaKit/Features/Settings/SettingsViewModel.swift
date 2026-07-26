import Combine

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var showTechnicalDetails = true
    @Published public var confirmBeforeSending = true

    public let runtimeMode: CoreRuntimeMode

    public init(runtimeMode: CoreRuntimeMode) {
        self.runtimeMode = runtimeMode
    }
}
