import Combine
import Foundation

@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var query = ""
    @Published public private(set) var characters: [LibraryCharacter]
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?

    private let client: (any CoreClient)?

    public init(
        client: (any CoreClient)? = nil,
        characters: [LibraryCharacter] = []
    ) {
        self.client = client
        self.characters = characters
    }

    public var filteredCharacters: [LibraryCharacter] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return characters
        }

        return characters.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.summary.localizedCaseInsensitiveContains(trimmed)
        }
    }

    public func replaceCharacters(_ characters: [LibraryCharacter]) {
        self.characters = characters
    }

    public func refresh() async {
        guard let client else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            characters = try await client.listCharacters().map(\.libraryCharacter)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
