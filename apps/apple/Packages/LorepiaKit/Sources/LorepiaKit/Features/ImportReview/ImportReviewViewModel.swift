import Combine
import Foundation

public enum ImportReviewState: Equatable, Sendable {
    case empty
    case loading(fileName: String)
    case review(ImportInspection)
    case committing(ImportInspection)
    case completed(CoreCharacter)
    case commitFailed(inspection: ImportInspection, message: String)
    case failed(fileName: String, message: String)
}

@MainActor
public final class ImportReviewViewModel: ObservableObject {
    @Published public private(set) var state: ImportReviewState = .empty

    private let client: any CoreClient
    private let stager: ImportFileStager
    private let libraryViewModel: LibraryViewModel
    private var operationEpoch: UInt64 = 0

    public init(
        client: any CoreClient,
        stager: ImportFileStager,
        libraryViewModel: LibraryViewModel
    ) {
        self.client = client
        self.stager = stager
        self.libraryViewModel = libraryViewModel
    }

    public func inspect(sourceURL: URL) async {
        if case .committing = state {
            return
        }
        operationEpoch &+= 1
        let epoch = operationEpoch
        await discardCurrentInspection()
        guard operationEpoch == epoch else {
            return
        }
        state = .loading(fileName: sourceURL.lastPathComponent)

        var stagedURL: URL?
        do {
            let staged = try await stager.stage(sourceURL)
            stagedURL = staged
            guard operationEpoch == epoch else {
                await stager.remove(staged)
                return
            }
            let inspection = try await client.inspectImport(stagedURL: staged)
            await stager.remove(staged)
            stagedURL = nil
            guard operationEpoch == epoch else {
                try? await client.discardImport(inspectionID: inspection.id)
                return
            }
            state = .review(inspection)
        } catch {
            if let stagedURL {
                await stager.remove(stagedURL)
            }
            guard operationEpoch == epoch else {
                return
            }
            state = .failed(
                fileName: sourceURL.lastPathComponent,
                message: error.localizedDescription
            )
        }
    }

    public var isBusy: Bool {
        switch state {
        case .loading, .committing:
            true
        default:
            false
        }
    }

    public func commit() async {
        let inspection: ImportInspection? = switch state {
        case let .review(inspection):
            inspection
        case let .commitFailed(inspection, _):
            inspection
        default:
            nil
        }
        guard let inspection, inspection.isAllowed else {
            return
        }
        let epoch = operationEpoch
        state = .committing(inspection)
        do {
            let character = try await client.commitImport(inspectionID: inspection.id)
            await libraryViewModel.refresh()
            guard operationEpoch == epoch else {
                return
            }
            state = .completed(character)
        } catch {
            guard operationEpoch == epoch else {
                return
            }
            state = .commitFailed(
                inspection: inspection,
                message: error.localizedDescription
            )
        }
    }

    public func discardPending() async {
        if case .committing = state {
            return
        }
        operationEpoch &+= 1
        await discardCurrentInspection()
        state = .empty
    }

    private func discardCurrentInspection() async {
        let inspection: ImportInspection? = switch state {
        case let .review(inspection):
            inspection
        case let .commitFailed(inspection, _):
            inspection
        default:
            nil
        }
        guard let inspection else {
            return
        }
        try? await client.discardImport(inspectionID: inspection.id)
    }
}
