import SwiftUI

public struct LibraryView: View {
    @ObservedObject private var viewModel: LibraryViewModel
    private let onImport: () -> Void
    private let onOpenChat: (LibraryCharacter) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 220), spacing: LorepiaSpacing.standard),
    ]

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
        VStack(spacing: 0) {
            HStack(spacing: LorepiaSpacing.compact) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("서재 검색", text: $viewModel.query)
                    .textFieldStyle(.plain)
                if !viewModel.query.isEmpty {
                    Button {
                        viewModel.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("검색어 지우기")
                }
            }
            .lorepiaCard()
            .padding([.horizontal, .top], LorepiaSpacing.standard)

            if viewModel.filteredCharacters.isEmpty {
                ContentUnavailableView {
                    Label("서재가 비어 있습니다", systemImage: "books.vertical")
                } description: {
                    Text("캐릭터 패키지를 선택하면 Rust 코어가 안전하게 검사합니다.")
                } actions: {
                    Button("콘텐츠 가져오기", action: onImport)
                        .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: LorepiaSpacing.standard) {
                        ForEach(viewModel.filteredCharacters) { character in
                            Button {
                                onOpenChat(character)
                            } label: {
                                CharacterCard(character: character)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("채팅 화면을 엽니다")
                        }
                    }
                    .padding(LorepiaSpacing.standard)
                }
            }
        }
    }
}

private struct CharacterCard: View {
    let character: LibraryCharacter

    var body: some View {
        HStack(alignment: .top, spacing: LorepiaSpacing.standard) {
            Image(systemName: character.symbolName)
                .font(.title)
                .frame(width: 44, height: 44)
                .background(.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 6) {
                Text(character.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(character.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .lorepiaCard()
    }
}
