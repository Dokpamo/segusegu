import Combine
import Foundation

@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published public var query = ""
    @Published public private(set) var characters: [LibraryCharacter]

    public init(characters: [LibraryCharacter] = []) {
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
}
