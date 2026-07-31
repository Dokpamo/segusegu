#if DEBUG
import Foundation
import LorepiaKit

enum DevelopmentMessagePattern {
    case empty
    case compactPair(user: String, assistant: String)
    case dialogue(pairs: [(String, String)])
    case longReply(user: String, assistant: String)
    case multiline(user: String, assistant: String)
    case repeatedKeyword(
        keyword: String,
        user: String,
        assistant: String
    )
    case noticeAndDialogue(
        notice: String,
        user: String,
        assistant: String
    )
    case failed(user: String, partial: String)
    case cancelled(user: String, partial: String)
    case storyScene(prompt: String, paragraphs: [String])
    case multiDayTimeline(
        firstUser: String,
        firstAssistant: String,
        secondUser: String,
        secondAssistant: String
    )
    case noticeOnly(String)
    case systemMix(
        system: String,
        user: String,
        assistant: String,
        notice: String
    )
}

enum DevelopmentMessageCatalog {
    static let initialConversationMessages = [
        ChatMessage(
            id: "fixture-new-conversation-system",
            role: .system,
            text: "개발용 합성 대화입니다. 실제 사용자 데이터는 포함되지 않습니다."
        ),
        ChatMessage(
            id: "fixture-new-conversation-assistant",
            role: .assistant,
            text: "준비됐어. 어떤 장면부터 시작할까?"
        ),
    ]

    static func messages(
        for pattern: DevelopmentMessagePattern,
        conversationID: String,
        updatedAt: Date
    ) -> [ChatMessage] {
        let seeds = seeds(for: pattern)
        return seeds.enumerated().map { index, seed in
            ChatMessage(
                id: "\(conversationID)-template-\(index + 1)",
                role: seed.role,
                text: seed.text,
                status: seed.status,
                generationID: seed.hasGeneration
                    ? "\(conversationID)-generation-marker-\(index + 1)"
                    : nil,
                createdAt: DevelopmentFixtureClock.timestamp(
                    updatedAt.addingTimeInterval(
                        -seed.secondsBeforeUpdate
                    )
                )
            )
        }
    }

    private static func seeds(
        for pattern: DevelopmentMessagePattern
    ) -> [DevelopmentMessageSeed] {
        switch pattern {
        case .empty:
            return []

        case let .compactPair(user, assistant):
            return [
                seed(.user, user, 90),
                seed(.assistant, assistant, 0),
            ]

        case let .dialogue(pairs):
            return dialogueSeeds(pairs)

        case let .longReply(user, assistant):
            return [
                seed(.user, user, 150),
                seed(.assistant, assistant, 0),
            ]

        case let .multiline(user, assistant):
            return [
                seed(.user, user, 180),
                seed(.assistant, assistant, 0),
            ]

        case let .repeatedKeyword(keyword, user, assistant):
            return [
                seed(
                    .user,
                    "\(keyword)에 대해 다시 확인할게. \(user)",
                    8 * DevelopmentFixtureClock.minute
                ),
                seed(
                    .assistant,
                    "\(keyword) 기록을 찾았어. \(assistant)",
                    6 * DevelopmentFixtureClock.minute
                ),
                seed(
                    .user,
                    "\(keyword)이 같은 뜻으로 한 번 더 등장한 거야?",
                    2 * DevelopmentFixtureClock.minute
                ),
                seed(
                    .assistant,
                    "맞아. 검색 결과에 \(keyword)이 여러 번 보여야 해.",
                    0
                ),
            ]

        case let .noticeAndDialogue(notice, user, assistant):
            return [
                seed(.notice, notice, 4 * DevelopmentFixtureClock.minute,
                     status: .notice),
                seed(.user, user, 2 * DevelopmentFixtureClock.minute),
                seed(.assistant, assistant, 0),
            ]

        case let .failed(user, partial):
            return [
                seed(.user, user, 75),
                seed(
                    .assistant,
                    partial,
                    0,
                    status: .failed,
                    hasGeneration: true
                ),
            ]

        case let .cancelled(user, partial):
            return [
                seed(.user, user, 75),
                seed(
                    .assistant,
                    partial,
                    0,
                    status: .cancelled,
                    hasGeneration: true
                ),
            ]

        case let .storyScene(prompt, paragraphs):
            let assistantText = paragraphs.joined(separator: "\n\n")
            return [
                seed(.user, prompt, 3 * DevelopmentFixtureClock.minute),
                seed(.assistant, assistantText, 0),
            ]

        case let .multiDayTimeline(
            firstUser,
            firstAssistant,
            secondUser,
            secondAssistant
        ):
            return [
                seed(
                    .user,
                    firstUser,
                    2 * DevelopmentFixtureClock.day
                ),
                seed(
                    .assistant,
                    firstAssistant,
                    2 * DevelopmentFixtureClock.day
                        - 2 * DevelopmentFixtureClock.minute
                ),
                seed(
                    .user,
                    secondUser,
                    3 * DevelopmentFixtureClock.hour
                ),
                seed(.assistant, secondAssistant, 0),
            ]

        case let .noticeOnly(text):
            return [
                seed(
                    .notice,
                    text,
                    0,
                    status: .notice
                ),
            ]

        case let .systemMix(system, user, assistant, notice):
            return [
                seed(
                    .system,
                    system,
                    6 * DevelopmentFixtureClock.minute
                ),
                seed(
                    .user,
                    user,
                    4 * DevelopmentFixtureClock.minute
                ),
                seed(
                    .assistant,
                    assistant,
                    2 * DevelopmentFixtureClock.minute
                ),
                seed(
                    .notice,
                    notice,
                    0,
                    status: .notice
                ),
            ]
        }
    }

    private static func dialogueSeeds(
        _ pairs: [(String, String)]
    ) -> [DevelopmentMessageSeed] {
        let messageCount = pairs.count * 2
        return pairs.enumerated().flatMap { pairIndex, pair in
            let firstIndex = pairIndex * 2
            return [
                seed(
                    .user,
                    pair.0,
                    TimeInterval(messageCount - firstIndex - 1)
                        * DevelopmentFixtureClock.minute
                ),
                seed(
                    .assistant,
                    pair.1,
                    TimeInterval(messageCount - firstIndex - 2)
                        * DevelopmentFixtureClock.minute
                ),
            ]
        }
    }

    private static func seed(
        _ role: ChatMessage.Role,
        _ text: String,
        _ secondsBeforeUpdate: TimeInterval,
        status: ChatMessage.Status = .complete,
        hasGeneration: Bool = false
    ) -> DevelopmentMessageSeed {
        DevelopmentMessageSeed(
            role: role,
            text: text,
            status: status,
            hasGeneration: hasGeneration,
            secondsBeforeUpdate: secondsBeforeUpdate
        )
    }
}

private struct DevelopmentMessageSeed {
    let role: ChatMessage.Role
    let text: String
    let status: ChatMessage.Status
    let hasGeneration: Bool
    let secondsBeforeUpdate: TimeInterval
}
#endif
