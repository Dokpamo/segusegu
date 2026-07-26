import Combine

@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var character: LibraryCharacter?
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public var draft = ""

    public let previewEnabled: Bool

    public init(previewEnabled: Bool) {
        self.previewEnabled = previewEnabled
    }

    public var canSubmit: Bool {
        previewEnabled
            && character != nil
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func setCharacter(_ character: LibraryCharacter) {
        guard self.character?.id != character.id else {
            return
        }
        self.character = character
        messages = previewEnabled
            ? [
                ChatMessage(
                    role: .notice,
                    text: "프리뷰 코어 모드입니다. 실제 모델 호출이나 대화 저장은 수행하지 않습니다."
                ),
            ]
            : []
        draft = ""
    }

    public func submitPreviewMessage() {
        guard canSubmit else {
            return
        }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        messages.append(ChatMessage(role: .user, text: text))
        messages.append(
            ChatMessage(
                role: .assistant,
                text: "이 응답은 UI 검증용 합성 메시지입니다."
            )
        )
        draft = ""
    }
}
