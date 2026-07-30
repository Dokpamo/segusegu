import Foundation
import LorepiaKit

#if DEBUG
/// A transcript long enough to scroll and spread over several days, for the
/// day separators, the floating day marker, and the date picker.
enum ChatHistoryShowcase {
    static let conversationFixtures: [FakeConversationFixture] = {
        let now = Date()
        return [
            FakeConversationFixture(
                conversation: CoreConversation(
                    id: "history-long-run",
                    characterID: "preview-cartographer",
                    title: "여러 날에 걸친 항해",
                    createdAt: timestamp(
                        now.addingTimeInterval(-6 * 24 * 60 * 60)
                    ),
                    updatedAt: timestamp(now.addingTimeInterval(-90 * 60))
                ),
                mode: .chat,
                messages: messages
            ),
        ]
    }()

    /// Six exchanges a day across four days, far enough apart that every day
    /// earns its own separator.
    static let messages: [ChatMessage] = {
        let now = Date()
        let lines = [
            ("오늘은 어느 별을 따라가면 돼?", "북동쪽 하늘의 가장 밝은 별부터 연결해 봐."),
            ("그다음은?", "세 번째 별에서 왼쪽으로 꺾으면 옛 항로가 나와."),
            ("항로 끝에는 뭐가 있어?", "부서진 등대와, 아직 불이 남아 있는 창문 하나."),
        ]
        var messages: [ChatMessage] = []
        for dayOffset in stride(from: 5, through: 2, by: -1) {
            for (index, line) in lines.enumerated() {
                let base = now.addingTimeInterval(
                    -Double(dayOffset) * 24 * 60 * 60
                        + Double(index) * 40 * 60
                )
                messages.append(
                    ChatMessage(
                        id: "history-\(dayOffset)-\(index)-user",
                        role: .user,
                        text: line.0,
                        createdAt: timestamp(base)
                    )
                )
                messages.append(
                    ChatMessage(
                        id: "history-\(dayOffset)-\(index)-assistant",
                        role: .assistant,
                        text: line.1,
                        createdAt: timestamp(
                            base.addingTimeInterval(70)
                        )
                    )
                )
            }
        }
        return messages
    }()

    private static func timestamp(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
    }
}
#endif
