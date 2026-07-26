import Combine

public enum ImportReviewState: Equatable, Sendable {
    case empty
    case selected(ImportCandidate)
    case acceptedForPreview(ImportCandidate)
}

@MainActor
public final class ImportReviewViewModel: ObservableObject {
    @Published public private(set) var state: ImportReviewState = .empty

    public let previewEnabled: Bool

    public init(previewEnabled: Bool) {
        self.previewEnabled = previewEnabled
    }

    public func select(_ candidate: ImportCandidate) {
        state = .selected(candidate)
    }

    public func clear() {
        state = .empty
    }

    public func acceptForPreview() {
        guard previewEnabled, case let .selected(candidate) = state else {
            return
        }
        state = .acceptedForPreview(candidate)
    }
}
