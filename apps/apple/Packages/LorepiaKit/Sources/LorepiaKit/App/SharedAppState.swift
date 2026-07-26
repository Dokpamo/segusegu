import Combine

@MainActor
public final class SharedAppState: ObservableObject {
    @Published public private(set) var selectedCharacter: LibraryCharacter?
    @Published public private(set) var pendingImport: ImportCandidate?

    public init() {}

    public func selectCharacter(_ character: LibraryCharacter?) {
        selectedCharacter = character
    }

    public func setPendingImport(_ candidate: ImportCandidate?) {
        pendingImport = candidate
    }
}
