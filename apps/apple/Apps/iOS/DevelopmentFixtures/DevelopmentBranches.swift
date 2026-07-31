#if DEBUG
import Foundation
import LorepiaKit

enum DevelopmentBranchCatalog {
    static let conversationID = "fixture-room-moa-blue17"

    static func moaBlue17Graph(
        anchor: Date
    ) -> FakeConversationGraphFixture {
        let updatedAt = anchor.addingTimeInterval(
            -4 * DevelopmentFixtureClock.hour
        )
        let createdAt = anchor.addingTimeInterval(
            -16 * DevelopmentFixtureClock.day
        )
        let conversationTimestamp =
            DevelopmentFixtureClock.timestamp(updatedAt)
        let conversation = CoreConversation(
            id: conversationID,
            characterID: "fixture-greenhouse-moa",
            title: "씨앗 상자 07 / BLUE-17",
            createdAt: DevelopmentFixtureClock.timestamp(createdAt),
            updatedAt: conversationTimestamp
        )

        let sharedMessages = [
            message(
                id: "fixture-moa-blue17-user-1",
                parentID: nil,
                role: .user,
                text: "BLUE-17 상자를 찾았어. 표면에 잎 모양 표시가 있어.",
                date: updatedAt.addingTimeInterval(
                    -15 * DevelopmentFixtureClock.minute
                )
            ),
            message(
                id: "fixture-moa-blue17-assistant-1",
                parentID: "fixture-moa-blue17-user-1",
                role: .assistant,
                text: "빛과 온도를 따로 기록한 상자야. 어떤 단서부터 볼까?",
                date: updatedAt.addingTimeInterval(
                    -13 * DevelopmentFixtureClock.minute
                )
            ),
            message(
                id: "fixture-moa-blue17-user-2",
                parentID: "fixture-moa-blue17-assistant-1",
                role: .user,
                text: "두 가능성을 각각 확인해 보자.",
                date: updatedAt.addingTimeInterval(
                    -8 * DevelopmentFixtureClock.minute
                )
            ),
        ]

        let lightMessages = sharedMessages + [
            message(
                id: "fixture-moa-blue17-light-assistant",
                parentID: "fixture-moa-blue17-user-2",
                role: .assistant,
                text: "빛 기록을 먼저 보면 자정 직전 파장이 한 번 크게 바뀌어.",
                date: updatedAt.addingTimeInterval(
                    -3 * DevelopmentFixtureClock.minute
                )
            ),
            message(
                id: "fixture-moa-blue17-light-user",
                parentID: "fixture-moa-blue17-light-assistant",
                role: .user,
                text: "빛 우선 경로를 활성 분기로 둘게.",
                date: updatedAt
            ),
        ]

        let temperatureMessages = sharedMessages + [
            message(
                id: "fixture-moa-blue17-temperature-assistant",
                parentID: "fixture-moa-blue17-user-2",
                role: .assistant,
                text: "온도 기록에서는 새벽 2시에 정확히 3도가 내려간 흔적이 보여.",
                date: updatedAt.addingTimeInterval(
                    -4 * DevelopmentFixtureClock.minute
                )
            ),
            message(
                id: "fixture-moa-blue17-temperature-user",
                parentID: "fixture-moa-blue17-temperature-assistant",
                role: .user,
                text: "온도 우선 경로도 나중에 다시 비교하자.",
                date: updatedAt
            ),
        ]

        let lightBranch = CoreConversationBranch(
            id: "fixture-moa-blue17-branch-light",
            conversationID: conversationID,
            title: "빛 기록 우선",
            forkMessageID: nil,
            headMessageID: lightMessages.last?.id,
            createdAt: conversation.createdAt,
            updatedAt: conversationTimestamp
        )
        let temperatureBranch = CoreConversationBranch(
            id: "fixture-moa-blue17-branch-temperature",
            conversationID: conversationID,
            title: "온도 기록 우선",
            forkMessageID: "fixture-moa-blue17-user-2",
            headMessageID: temperatureMessages.last?.id,
            createdAt: conversation.createdAt,
            updatedAt: conversationTimestamp
        )

        return FakeConversationGraphFixture(
            conversation: conversation,
            state: CoreConversationState(
                conversationID: conversationID,
                activeBranchID: lightBranch.id,
                selectedMode: .story,
                updatedAt: conversationTimestamp
            ),
            branches: [
                FakeConversationBranchFixture(
                    branch: lightBranch,
                    messages: lightMessages
                ),
                FakeConversationBranchFixture(
                    branch: temperatureBranch,
                    messages: temperatureMessages
                ),
            ]
        )
    }

    private static func message(
        id: String,
        parentID: String?,
        role: ChatMessage.Role,
        text: String,
        date: Date
    ) -> ChatMessage {
        ChatMessage(
            id: id,
            conversationID: conversationID,
            parentID: parentID,
            role: role,
            text: text,
            status: .complete,
            createdAt: DevelopmentFixtureClock.timestamp(date)
        )
    }
}
#endif
