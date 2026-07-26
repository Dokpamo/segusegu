import SwiftUI

public struct LibraryView: View {
    @ObservedObject private var viewModel: LibraryViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let onImport: () -> Void
    private let onOpenChat: (LibraryCharacter) -> Void

    public init(
        viewModel: LibraryViewModel,
        onImport: @escaping () -> Void,
        onOpenChat: @escaping (LibraryCharacter) -> Void
    ) {
        self.viewModel = viewModel
        self.onImport = onImport
        self.onOpenChat = onOpenChat
    }

    public var body: some View {
        ZStack {
            switch contentState {
            case .loading:
                ProgressView("서재를 불러오는 중")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error:
                errorView
            case .empty:
                emptyView
            case .noResults:
                noResultsView
            case .results:
                characterList
            }
        }
        .id(contentState)
        .transition(.opacity)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: contentState
        )
        .searchable(
            text: $viewModel.query,
            placement: .automatic,
            prompt: Text("서재 검색")
        )
        .overlay {
            if viewModel.isLoading, !viewModel.characters.isEmpty {
                ProgressView("서재를 불러오는 중")
                    .padding()
                    .background(
                        .regularMaterial,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                    )
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: viewModel.isLoading
        )
    }

    private var contentState: LibraryContentState {
        if viewModel.isLoading, viewModel.characters.isEmpty {
            return .loading
        }
        if viewModel.errorMessage != nil, viewModel.characters.isEmpty {
            return .error
        }
        if viewModel.characters.isEmpty {
            return .empty
        }
        if viewModel.filteredCharacters.isEmpty {
            return .noResults
        }
        return .results
    }

    private var characterList: some View {
        List(viewModel.filteredCharacters) { character in
            Button {
                onOpenChat(character)
            } label: {
                LibraryCharacterRow(character: character)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityHint("채팅 화면을 엽니다")
        }
        .listStyle(.plain)
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("서재가 비어 있습니다", systemImage: "books.vertical")
        } description: {
            Text("캐릭터 패키지를 선택하면 Rust 코어가 안전하게 검사합니다.")
        } actions: {
            ViewThatFits(in: .horizontal) {
                HStack {
                    refreshButton
                    importButton
                }
                VStack {
                    refreshButton
                    importButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        ContentUnavailableView {
            Label(
                "서재를 불러오지 못했습니다",
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(viewModel.errorMessage ?? "알 수 없는 오류가 발생했습니다.")
        } actions: {
            ViewThatFits(in: .horizontal) {
                HStack {
                    refreshButton
                    importButton
                }
                VStack {
                    refreshButton
                    importButton
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        ContentUnavailableView.search(text: viewModel.query)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var refreshButton: some View {
        Button("다시 불러오기") {
            Task {
                await viewModel.refresh()
            }
        }
    }

    private var importButton: some View {
        Button("콘텐츠 가져오기", action: onImport)
            .buttonStyle(.borderedProminent)
    }
}

private enum LibraryContentState: Hashable {
    case loading
    case error
    case empty
    case noResults
    case results
}

private struct LibraryCharacterRow: View {
    let character: LibraryCharacter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var avatarSize = 44

    var body: some View {
        HStack(alignment: .top, spacing: LorepiaSpacing.standard) {
            Image(systemName: character.symbolName)
                .font(.title2)
                .frame(
                    width: max(44, min(avatarSize, 64)),
                    height: max(44, min(avatarSize, 64))
                )
                .background(.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(character.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(character.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, LorepiaSpacing.compact / 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
