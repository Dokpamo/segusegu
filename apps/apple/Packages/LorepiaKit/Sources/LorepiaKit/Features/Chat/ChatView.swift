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
                    header(character)
                    Divider()
                    messageList
                    Divider()
                    composer
                }
            } else {
                ContentUnavailableView {
                    Label("대화를 선택하세요", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("서재에서 캐릭터를 선택하면 저장된 대화를 이어갈 수 있습니다.")
                }
            }
        }
        .onAppear {
            Task {
                await viewModel.resumeEventPolling()
            }
        }
        .onDisappear {
            viewModel.pauseEventPolling()
        }
    }

    private func header(_ character: LibraryCharacter) -> some View {
        HStack(spacing: LorepiaSpacing.compact) {
            Image(systemName: character.symbolName)
                .font(.title2)
            VStack(alignment: .leading) {
                Text(character.name)
                    .font(.headline)
                Text(viewModel.runtimeMode.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if viewModel.isGenerating {
                Button("생성 취소", role: .destructive) {
                    Task {
                        await viewModel.cancelGeneration()
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityHint("현재 모델 응답 생성을 중단합니다")
            }
        }
        .padding(LorepiaSpacing.standard)
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: LorepiaSpacing.compact) {
                    if viewModel.isLoading {
                        ProgressView("대화를 복원하는 중")
                            .padding()
                    }
                    if let errorMessage = viewModel.errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lorepiaCard()
                    }
                    ForEach(viewModel.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                    if let usageDescription = viewModel.usageDescription {
                        Text(usageDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                .padding(LorepiaSpacing.standard)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewModel.messages.count) {
                if let id = viewModel.messages.last?.id {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: LorepiaSpacing.compact) {
            TextField(
                viewModel.conversation == nil
                    ? "대화를 준비하는 중입니다"
                    : "메시지",
                text: $viewModel.draft,
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1 ... 5)
            .disabled(viewModel.conversation == nil || viewModel.isGenerating)
            .onSubmit {
                Task {
                    await viewModel.submitMessage()
                }
            }

            Button {
                Task {
                    await viewModel.submitMessage()
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSubmit)
            .accessibilityLabel("메시지 보내기")
        }
        .padding(LorepiaSpacing.standard)
    }
}

private struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user {
                Spacer(minLength: 44)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.text.isEmpty ? "…" : message.text)
                    .font(.body)
                if message.status != .complete {
                    Text(statusText)
                        .font(.caption2)
                        .opacity(0.75)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .foregroundStyle(foregroundStyle)
            .background(backgroundStyle, in: RoundedRectangle(cornerRadius: 17))

            if message.role != .user {
                Spacer(minLength: 44)
            }
        }
        .accessibilityElement(children: .combine)
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
        case .system, .notice:
            Color.orange.opacity(0.14)
        }
    }

    private var statusText: String {
        switch message.status {
        case .pending:
            "생성 중"
        case .cancelled:
            "취소됨"
        case .failed:
            "실패"
        case .complete:
            "완료"
        case .notice:
            "안내"
        }
    }

    private var accessibilityText: String {
        let speaker = switch message.role {
        case .user:
            "나"
        case .assistant:
            "캐릭터"
        case .system:
            "시스템"
        case .notice:
            "안내"
        }
        return "\(speaker): \(message.text), \(statusText)"
    }
}
