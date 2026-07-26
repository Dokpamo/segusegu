import SwiftUI

public struct ChatView: View {
    @ObservedObject private var viewModel: ChatViewModel

    public init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Group {
            if let character = viewModel.character {
                VStack(spacing: 0) {
                    HStack(spacing: LorepiaSpacing.compact) {
                        Image(systemName: character.symbolName)
                            .font(.title2)
                        VStack(alignment: .leading) {
                            Text(character.name)
                                .font(.headline)
                            Text(
                                viewModel.previewEnabled
                                    ? "프리뷰 대화"
                                    : "Rust 코어 대화"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(LorepiaSpacing.standard)

                    Divider()

                    ScrollView {
                        LazyVStack(spacing: LorepiaSpacing.compact) {
                            ForEach(viewModel.messages) { message in
                                ChatBubble(message: message)
                            }
                        }
                        .padding(LorepiaSpacing.standard)
                        .frame(maxWidth: .infinity)
                    }

                    Divider()

                    HStack(alignment: .bottom, spacing: LorepiaSpacing.compact) {
                        TextField(
                            viewModel.previewEnabled
                                ? "프리뷰 메시지"
                                : "채팅 바인딩 연결 후 사용할 수 있습니다",
                            text: $viewModel.draft,
                            axis: .vertical
                        )
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1 ... 5)
                        .disabled(!viewModel.previewEnabled)
                        .onSubmit(viewModel.submitPreviewMessage)

                        Button(action: viewModel.submitPreviewMessage) {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .disabled(!viewModel.canSubmit)
                        .accessibilityLabel("메시지 보내기")
                    }
                    .padding(LorepiaSpacing.standard)
                }
            } else {
                ContentUnavailableView {
                    Label("대화를 선택하세요", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("서재에서 캐릭터를 선택하면 이곳에서 대화 화면을 확인할 수 있습니다.")
                }
            }
        }
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 44)
            }

            Text(message.text)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .foregroundStyle(foregroundStyle)
                .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 17))

            if message.role != .user {
                Spacer(minLength: 44)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var foregroundStyle: Color {
        message.role == .user ? .white : .primary
    }

    private var backgroundStyle: Color {
        switch message.role {
        case .user:
            .accentColor
        case .assistant:
            Color.secondary.opacity(0.14)
        case .notice:
            Color.orange.opacity(0.14)
        }
    }

    private var accessibilityText: String {
        switch message.role {
        case .user:
            "나: \(message.text)"
        case .assistant:
            "캐릭터: \(message.text)"
        case .notice:
            "안내: \(message.text)"
        }
    }
}
