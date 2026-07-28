import Foundation
import LorepiaKit
import SwiftUI

@main
@MainActor
struct LorepiaIOSApp: App {
    private let environment: AppEnvironment

    init() {
#if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--lorepia-chat-bubble-showcase") {
            environment = AppEnvironment(
                coreClient: FakeCoreClient(
                    initialConversationMessages:
                        ChatBubbleShowcase.messages,
                    initialConversationFixtures:
                        ChatBubbleShowcase.conversationFixtures
                ),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: LibraryCharacter.previewCharacters
            )
            return
        }
        if arguments.contains("--lorepia-ui-test") {
            environment = AppEnvironment(
                coreClient: FakeCoreClient(characters: []),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: []
            )
            return
        }
        if arguments.contains(
            "--lorepia-native-navigation-ui-test"
        ) {
            environment = AppEnvironment(
                coreClient: FakeCoreClient(),
                runtimeMode: .preview,
                credentialStore: InMemoryCredentialStore(),
                characters: LibraryCharacter.previewCharacters
            )
            return
        }
#endif
        environment = AppEnvironment.makeDefault(
            dataRoot: IOSAppDirectories.dataRoot()
        )
    }

    var body: some Scene {
        WindowGroup {
            IOSRootView(environment: environment)
        }
    }
}

#if DEBUG
private enum ChatBubbleShowcase {
    static let conversationFixtures: [FakeConversationFixture] = {
        let now = Date()
        return [
            fixture(
                id: "showcase-morning-walk",
                characterID: "preview-librarian",
                title: "새벽 산책",
                mode: .chat,
                createdDaysAgo: 8,
                updatedSecondsAgo: 2 * 60,
                now: now,
                messages: messages
            ),
            fixture(
                id: "showcase-last-scene",
                characterID: "preview-cartographer",
                title: "마지막 장면부터 다시 시작해 보는 이야기",
                mode: .story,
                createdDaysAgo: 4,
                updatedSecondsAgo: 18 * 60,
                now: now,
                messages: [
                    ChatMessage(
                        role: .user,
                        text: "성문이 닫히기 직전 장면부터 다시 시작하자."
                    ),
                    ChatMessage(
                        role: .assistant,
                        text: "문이 닫히기 직전, 그녀가 뒤를 돌아 아주 작은 목소리로 이름을 불렀다."
                    ),
                ]
            ),
            fixture(
                id: "showcase-library-secret",
                characterID: "preview-librarian",
                title: "잠긴 서가의 비밀",
                mode: .chat,
                createdDaysAgo: 3,
                updatedSecondsAgo: 52 * 60,
                now: now,
                messages: [
                    ChatMessage(
                        role: .user,
                        text: "아까 말한 오래된 열쇠를 찾았어."
                    ),
                    ChatMessage(
                        role: .assistant,
                        text: "좋아. 가장 안쪽 서가의 푸른 자물쇠부터 확인해 보자."
                    ),
                ]
            ),
            fixture(
                id: "showcase-second-voyage",
                characterID: "preview-cartographer",
                title: "별빛 지도사 · 두 번째 항해",
                mode: .chat,
                createdDaysAgo: 6,
                updatedSecondsAgo: 3 * 60 * 60,
                now: now,
                messages: [
                    ChatMessage(
                        role: .user,
                        text: "오늘은 어느 별을 따라가면 돼?"
                    ),
                    ChatMessage(
                        role: .assistant,
                        text: "북동쪽 하늘의 가장 밝은 별부터 연결해 봐."
                    ),
                ]
            ),
            fixture(
                id: "showcase-rainy-promise",
                characterID: "preview-librarian",
                title: "비 오는 날의 약속",
                mode: .story,
                createdDaysAgo: 12,
                updatedSecondsAgo: 26 * 60 * 60,
                now: now,
                messages: [
                    ChatMessage(
                        role: .assistant,
                        text: "창밖으로 빗소리가 조금씩 가까워졌다."
                    ),
                    ChatMessage(
                        role: .user,
                        text: "그 우산, 아직 가지고 있어?"
                    ),
                ]
            ),
            fixture(
                id: "showcase-short-room",
                characterID: "preview-librarian",
                title: "짧은 방",
                mode: .chat,
                createdDaysAgo: 5,
                updatedSecondsAgo: 3 * 24 * 60 * 60,
                now: now,
                messages: [
                    ChatMessage(role: .user, text: "계속할까?"),
                    ChatMessage(role: .assistant, text: "좋아."),
                ]
            ),
            fixture(
                id: "showcase-glass-desert",
                characterID: "preview-cartographer",
                title: "유리 사막의 밤",
                mode: .story,
                createdDaysAgo: 18,
                updatedSecondsAgo: 8 * 24 * 60 * 60,
                now: now,
                messages: [
                    ChatMessage(
                        role: .user,
                        text: "모래 아래에서 빛나는 건 뭘까?"
                    ),
                    ChatMessage(
                        role: .assistant,
                        text: "달빛을 오래 품은 유리 조각들이 파도처럼 깨어나고 있어."
                    ),
                ]
            ),
            fixture(
                id: "showcase-long-title",
                characterID: "preview-cartographer",
                title: "아주 길고 구체적인 대화 제목이 한 줄에서 어떻게 보이는지 확인하는 방",
                mode: .chat,
                createdDaysAgo: 32,
                updatedSecondsAgo: 20 * 24 * 60 * 60,
                now: now,
                messages: [
                    ChatMessage(
                        role: .user,
                        text: "긴 제목과 미리보기가 좁은 화면에서도 자연스럽게 정리되는지 확인해 줘."
                    ),
                    ChatMessage(
                        role: .assistant,
                        text: "날짜와 제목이 겹치지 않도록 한 줄 말줄임 상태를 함께 살펴볼게."
                    ),
                ]
            ),
        ]
    }()

    static let messages = [
        ChatMessage(
            id: "chat-bubble-assistant-1",
            role: .assistant,
            text: "상대방 한 줄 말풍선"
        ),
        ChatMessage(
            id: "chat-bubble-user-1",
            role: .user,
            text: "내 한 줄 말풍선"
        ),
        ChatMessage(
            id: "chat-bubble-assistant-5",
            role: .assistant,
            text: """
            상대방 다섯 줄
            두 번째 줄
            세 번째 줄
            네 번째 줄
            다섯 번째 줄
            """
        ),
        ChatMessage(
            id: "chat-bubble-user-5",
            role: .user,
            text: """
            내 다섯 줄
            두 번째 줄
            세 번째 줄
            네 번째 줄
            다섯 번째 줄
            """
        ),
        ChatMessage(
            id: "chat-bubble-assistant-10",
            role: .assistant,
            text: """
            상대방 열 줄
            두 번째 줄
            세 번째 줄
            네 번째 줄
            다섯 번째 줄
            여섯 번째 줄
            일곱 번째 줄
            여덟 번째 줄
            아홉 번째 줄
            열 번째 줄
            """
        ),
        ChatMessage(
            id: "chat-bubble-user-10",
            role: .user,
            text: """
            내 열 줄
            두 번째 줄
            세 번째 줄
            네 번째 줄
            다섯 번째 줄
            여섯 번째 줄
            일곱 번째 줄
            여덟 번째 줄
            아홉 번째 줄
            열 번째 줄
            """
        ),
    ]

    private static func fixture(
        id: String,
        characterID: String,
        title: String,
        mode: ConversationMode,
        createdDaysAgo: TimeInterval,
        updatedSecondsAgo: TimeInterval,
        now: Date,
        messages: [ChatMessage]
    ) -> FakeConversationFixture {
        let updatedDate = now.addingTimeInterval(-updatedSecondsAgo)
        let createdDate = now.addingTimeInterval(
            -createdDaysAgo * 24 * 60 * 60
        )
        let datedMessages = messages.enumerated().map { index, message in
            ChatMessage(
                id: "\(id)-template-\(index + 1)",
                role: message.role,
                text: message.text,
                status: message.status,
                generationID: message.generationID,
                createdAt: timestamp(
                    updatedDate.addingTimeInterval(
                        -TimeInterval(messages.count - index - 1) * 60
                    )
                )
            )
        }
        return FakeConversationFixture(
            conversation: CoreConversation(
                id: id,
                characterID: characterID,
                title: title,
                createdAt: timestamp(createdDate),
                updatedAt: timestamp(updatedDate)
            ),
            mode: mode,
            messages: datedMessages
        )
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        )
    }
}
#endif
