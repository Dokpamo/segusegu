#if DEBUG
import Foundation
import LorepiaKit

enum DevelopmentConversationCatalog {
    static func comprehensiveFixtures(
        anchor: Date
    ) -> [FakeConversationFixture] {
        comprehensiveSpecs
            .filter { $0.id != DevelopmentBranchCatalog.conversationID }
            .map { fixture(from: $0, anchor: anchor) }
    }

    static func loadFixtures(
        anchor: Date,
        roomCount: Int = 60
    ) -> [FakeConversationFixture] {
        let characters = DevelopmentCharacterCatalog.characters
        return (0 ..< roomCount).map { index in
            let displayIndex = index + 1
            let character = characters[index % characters.count]
            let keyword = String(format: "LOAD-%03d", displayIndex)
            let pattern = DevelopmentMessagePattern.dialogue(
                pairs: (1 ... 5).map { exchange in
                    (
                        "\(keyword) 부하 대화 \(exchange)번째 질문이야.",
                        "\(keyword) 부하 대화 \(exchange)번째 합성 응답이야."
                    )
                }
            )
            let spec = DevelopmentConversationSpec(
                id: "fixture-load-room-\(displayIndex)",
                characterID: character.id,
                title: "\(keyword) · 긴 목록과 스크롤 성능 확인",
                mode: displayIndex.isMultiple(of: 3) ? .story : .chat,
                createdDaysAgo: Double(30 + index % 20),
                updatedSecondsAgo: TimeInterval(displayIndex * 90),
                pattern: pattern
            )
            return fixture(from: spec, anchor: anchor)
        }
    }

    private static let comprehensiveSpecs: [DevelopmentConversationSpec] = [
        DevelopmentConversationSpec(
            id: "fixture-room-narin-postcard",
            characterID: "fixture-postmaster-narin",
            title: "도착하지 않은 엽서",
            mode: .chat,
            createdDaysAgo: 8,
            updatedSecondsAgo: 2 * DevelopmentFixtureClock.minute,
            pattern: .compactPair(
                user: "파란 우표가 붙은 엽서가 아직 도착하지 않았어.",
                assistant: "마지막 소인이 찍힌 새벽 우체국부터 차근차근 확인해 볼게."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-narin-untitled",
            characterID: "fixture-postmaster-narin",
            title: "",
            mode: .chat,
            createdDaysAgo: 1,
            updatedSecondsAgo: 18 * DevelopmentFixtureClock.minute,
            pattern: .empty
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-narin-address-failed",
            characterID: "fixture-postmaster-narin",
            title: "주소의 마지막 한 줄을 찾는 밤",
            mode: .story,
            createdDaysAgo: 10,
            updatedSecondsAgo: 2 * DevelopmentFixtureClock.day,
            pattern: .failed(
                user: "번진 주소의 마지막 줄을 읽어 줄래?",
                partial: "달빛 아래에서 보이는 글자는 ‘북쪽 계단을 지나…"
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-moa-first-leaf",
            characterID: "fixture-greenhouse-moa",
            title: "첫 잎 관찰일지",
            mode: .chat,
            createdDaysAgo: 3,
            updatedSecondsAgo: 7 * DevelopmentFixtureClock.minute,
            pattern: .dialogue(
                pairs: [
                    ("새 잎 끝이 조금 투명해.", "빛을 받은 시간부터 기록해 보자."),
                    ("어제보다 3밀리미터 자랐어.", "성장 속도도 함께 표에 적어 둘게."),
                    ("물은 지금 줘도 될까?", "흙 표면이 마른 뒤 한 번만 천천히 줘."),
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-moa-blue17",
            characterID: "fixture-greenhouse-moa",
            title: "씨앗 상자 07 / BLUE-17",
            mode: .story,
            createdDaysAgo: 16,
            updatedSecondsAgo: 4 * DevelopmentFixtureClock.hour,
            pattern: .storyScene(
                prompt: "BLUE-17 상자를 여는 장면부터 이어 줘.",
                paragraphs: [
                    "모아가 낡은 걸쇠를 올리자 푸른 먼지가 얇은 안개처럼 퍼졌다.",
                    "상자 안에는 씨앗 대신 날짜가 다른 작은 관찰표가 일곱 장 놓여 있었다.",
                    "가장 아래쪽 종이에는 오늘 밤 자정에만 피는 잎의 위치가 그려져 있었다.",
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-moa-winter-table",
            characterID: "fixture-greenhouse-moa",
            title: "겨울 온실의 온도표",
            mode: .chat,
            createdDaysAgo: 90,
            updatedSecondsAgo: 31 * DevelopmentFixtureClock.day,
            pattern: .systemMix(
                system: "온실 기록 모드 · 단위는 섭씨입니다.",
                user: "새벽 두 시 온도가 유난히 낮아.",
                assistant: "환기창이 열린 시간을 겹쳐 보면 원인을 찾을 수 있어.",
                notice: "합성 기록: 실제 센서 데이터가 아닙니다."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-haram-three-winds",
            characterID: "fixture-windmap-haram",
            title: "갈림길의 세 바람",
            mode: .chat,
            createdDaysAgo: 5,
            updatedSecondsAgo: 52 * DevelopmentFixtureClock.minute,
            pattern: .dialogue(
                pairs: [
                    ("세 갈래 길 모두 바람이 불어.", "나뭇잎이 가장 낮게 도는 길을 봐."),
                    ("왼쪽 길만 따뜻해.", "그 길은 마을 쪽에서 돌아오는 바람이야."),
                    ("그럼 가운데 길로 갈까?", "응, 지도에 없는 계곡은 가운데에 있어."),
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-haram-lantern-alley",
            characterID: "fixture-windmap-haram",
            title: "등불이 흔들리는 골목",
            mode: .story,
            createdDaysAgo: 11,
            updatedSecondsAgo: 26 * DevelopmentFixtureClock.hour,
            pattern: .repeatedKeyword(
                keyword: "등불",
                user: "바람이 없는데도 흔들리고 있어.",
                assistant: "골목 아래의 숨은 통로에서 공기가 올라오는 것 같아."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-haram-fold-map",
            characterID: "fixture-windmap-haram",
            title: "지도 접기",
            mode: .chat,
            createdDaysAgo: 25,
            updatedSecondsAgo: 9 * DevelopmentFixtureClock.day,
            pattern: .cancelled(
                user: "지도를 여섯 조각으로 접는 순서를 알려 줘.",
                partial: "먼저 북쪽 모서리를 중심선에 맞추고, 다음은"
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-eden-spare-screw",
            characterID: "fixture-workshop-eden",
            title: "나사 하나가 남았어",
            mode: .chat,
            createdDaysAgo: 2,
            updatedSecondsAgo: 30,
            pattern: .compactPair(
                user: "조립은 끝났는데 나사가 하나 남았어.",
                assistant: "덮개 안쪽 세 번째 고정 구멍을 먼저 확인해 봐."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-eden-gear-check",
            characterID: "fixture-workshop-eden",
            title: "톱니 정렬 점검",
            mode: .chat,
            createdDaysAgo: 4,
            updatedSecondsAgo: 6 * DevelopmentFixtureClock.hour,
            pattern: .noticeAndDialogue(
                notice: "정비 안전 모드가 켜졌습니다.",
                user: "큰 톱니가 한 칸씩 밀리는 것 같아.",
                assistant: "전원을 끄고 기준 표시 두 개가 만나는지 확인하자."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-eden-long-maintenance",
            characterID: "fixture-workshop-eden",
            title: "오래 멈춰 있던 자동인형의 왼쪽 팔 관절과 세 번째 태엽을 함께 점검하는 기록",
            mode: .story,
            createdDaysAgo: 260,
            updatedSecondsAgo: 180 * DevelopmentFixtureClock.day,
            pattern: .multiline(
                user: "점검 순서를 열 줄로 정리해 줘.",
                assistant: """
                1. 외부 덮개 상태 확인
                2. 주 태엽 장력 해제
                3. 왼쪽 팔 고정
                4. 관절 축 마모 확인
                5. 세 번째 태엽 분리
                6. 톱니 사이 이물질 제거
                7. 윤활유 한 방울 도포
                8. 태엽을 낮은 장력으로 결합
                9. 팔을 천천히 왕복 시험
                10. 덮개를 닫고 소음 기록
                """
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-daon-late-bowl",
            characterID: "fixture-kitchen-daon",
            title: "늦은 밤 한 그릇",
            mode: .chat,
            createdDaysAgo: 3,
            updatedSecondsAgo: 12 * DevelopmentFixtureClock.minute,
            pattern: .compactPair(
                user: "배는 고픈데 무거운 건 싫어.",
                assistant: "달걀과 파를 넣은 맑은 국수 한 그릇은 어때?"
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-daon-potato-bread",
            characterID: "fixture-kitchen-daon",
            title: "감자 두 개와 식은 빵으로 만드는 저녁",
            mode: .story,
            createdDaysAgo: 9,
            updatedSecondsAgo: 25 * DevelopmentFixtureClock.hour,
            pattern: .storyScene(
                prompt: "남은 재료만으로 저녁을 만드는 장면을 써 줘.",
                paragraphs: [
                    "다온은 감자를 얇게 썰어 팬 가장자리에 둥글게 놓았다.",
                    "식은 빵은 우유 한 숟갈과 함께 부드럽게 풀어 가운데를 채웠다.",
                    "소금과 후추를 뿌리자 작은 부엌에 고소한 냄새가 천천히 번졌다.",
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-daon-tea",
            characterID: "fixture-kitchen-daon",
            title: "차",
            mode: .chat,
            createdDaysAgo: 500,
            updatedSecondsAgo: 370 * DevelopmentFixtureClock.day,
            pattern: .compactPair(
                user: "따뜻한 차.",
                assistant: "좋아."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-rumi-north-star",
            characterID: "fixture-paperstar-rumi",
            title: "접힌 별의 북쪽",
            mode: .story,
            createdDaysAgo: 13,
            updatedSecondsAgo: 3 * DevelopmentFixtureClock.hour,
            pattern: .storyScene(
                prompt: "종이별 지도의 북쪽 끝으로 가자.",
                paragraphs: [
                    "루미가 마지막 접힌 선을 펼치자 작은 은빛 길이 나타났다.",
                    "길 끝에서는 종이로 만든 눈이 소리 없이 내리고 있었다.",
                    "둘은 발자국 대신 연필로 이동 경로를 지도 위에 그렸다.",
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-rumi-paper-planet",
            characterID: "fixture-paperstar-rumi",
            title: "★ 종이 행성 3호",
            mode: .chat,
            createdDaysAgo: 10,
            updatedSecondsAgo: 3 * DevelopmentFixtureClock.day,
            pattern: .dialogue(
                pairs: [
                    ("3호 행성은 왜 삼각형이야?", "세 번 접은 종이에서 태어났거든."),
                    ("중력도 세 방향이야?", "응, 모서리마다 아래쪽이 달라."),
                    ("착륙 지점은 어디가 좋아?", "가운데의 둥근 스티커가 가장 안전해."),
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-rumi-whitespace",
            characterID: "fixture-paperstar-rumi",
            title: "   ",
            mode: .chat,
            createdDaysAgo: 7,
            updatedSecondsAgo: 6 * DevelopmentFixtureClock.day,
            pattern: .empty
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-yeonwoo-tin-roof",
            characterID: "fixture-rain-lab-yeonwoo",
            title: "양철 지붕의 파도",
            mode: .chat,
            createdDaysAgo: 5,
            updatedSecondsAgo: 15 * DevelopmentFixtureClock.minute,
            pattern: .repeatedKeyword(
                keyword: "파도",
                user: "빗방울이 지붕에서 밀려오는 소리야.",
                assistant: "간격을 재면 비의 세기가 바뀌는 순간도 알 수 있어."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-yeonwoo-window-0403",
            characterID: "fixture-rain-lab-yeonwoo",
            title: "새벽 4시 03분, 유리창",
            mode: .story,
            createdDaysAgo: 14,
            updatedSecondsAgo: 5 * DevelopmentFixtureClock.day,
            pattern: .storyScene(
                prompt: "녹음이 시작되는 순간부터 묘사해 줘.",
                paragraphs: [
                    "시계가 4시 03분을 가리키자 첫 빗방울이 유리창 중앙에 닿았다.",
                    "연우는 숨을 죽이고 파형이 고르게 올라오는 것을 바라보았다.",
                    "멀리서 기차가 지나가자 빗소리는 잠시 낮은 화음으로 바뀌었다.",
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-yeonwoo-broken-recording",
            characterID: "fixture-rain-lab-yeonwoo",
            title: "끊긴 녹음",
            mode: .chat,
            createdDaysAgo: 30,
            updatedSecondsAgo: 14 * DevelopmentFixtureClock.day,
            pattern: .failed(
                user: "끊긴 뒤의 파형을 복원할 수 있을까?",
                partial: "남아 있는 12초를 기준으로 반복 구간을 찾으면"
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-sodam-five-minutes",
            characterID: "fixture-theater-sodam",
            title: "막이 오르기 5분 전",
            mode: .chat,
            createdDaysAgo: 2,
            updatedSecondsAgo: 20 * DevelopmentFixtureClock.minute,
            pattern: .dialogue(
                pairs: [
                    ("배우 한 명이 아직 안 왔어.", "대역 동선을 먼저 열어 둘게."),
                    ("조명 3번도 깜빡여.", "예비 회로로 바꾸고 밝기를 낮추자."),
                    ("관객 입장 시작할까?", "응, 로비 종을 한 번 울려 줘."),
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-sodam-punctuation",
            characterID: "fixture-theater-sodam",
            title: "쉼표, 물음표? 그리고 …",
            mode: .story,
            createdDaysAgo: 19,
            updatedSecondsAgo: 8 * DevelopmentFixtureClock.day,
            pattern: .multiline(
                user: "대사 사이의 침묵도 그대로 써 줘.",
                assistant: """
                “왔어?”

                대답 대신, 무대 뒤에서 의자가 한 번 끌리는 소리가 났다.

                “정말… 너야?”

                이번에는 아주 작은 숨소리가 객석 끝까지 닿았다.
                """
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-sodam-empty-rehearsal",
            characterID: "fixture-theater-sodam",
            title: "관객이 없는 리허설",
            mode: .story,
            createdDaysAgo: 70,
            updatedSecondsAgo: 32 * DevelopmentFixtureClock.day,
            pattern: .noticeOnly(
                "리허설 기록만 남아 있고 아직 대사는 없습니다."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-yoonseul-current-12b",
            characterID: "fixture-coral-library-yoonseul",
            title: "해류 기록 12-B",
            mode: .chat,
            createdDaysAgo: 4,
            updatedSecondsAgo: 6 * DevelopmentFixtureClock.minute,
            pattern: .compactPair(
                user: "12-B 기록이 어제와 반대로 흐르고 있어.",
                assistant: "달의 위치와 수온 기록을 함께 비교해 볼게."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-yoonseul-blue17",
            characterID: "fixture-coral-library-yoonseul",
            title: "BLUE-17 보관함",
            mode: .chat,
            createdDaysAgo: 15,
            updatedSecondsAgo: 23 * DevelopmentFixtureClock.hour,
            pattern: .repeatedKeyword(
                keyword: "BLUE-17",
                user: "온실 기록과 같은 표식이야.",
                assistant: "두 보관함이 같은 탐사대에서 왔는지 대조해 볼게."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-yoonseul-long-archive",
            characterID: "fixture-coral-library-yoonseul",
            title: "산호가 세 번 자란 뒤에만 열리는 가장 깊은 해저 기록 보관실의 분류표",
            mode: .story,
            createdDaysAgo: 140,
            updatedSecondsAgo: 65 * DevelopmentFixtureClock.day,
            pattern: .longReply(
                user: "보관실의 분류 규칙을 자세히 설명해 줘.",
                assistant: "첫 번째 선반은 해류가 가져온 날짜순 기록, 두 번째는 발신지를 알 수 없는 병 속 편지, 세 번째는 산호 성장 고리에 새겨진 장기 관측 자료야. 빛이 닿지 않는 아래 칸에는 소리로만 읽을 수 있는 조개 기록을 두고, 같은 표식이 반복되면 서로 다른 선반에서도 연결 태그를 붙여."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-gaon-cotton-cloud",
            characterID: "fixture-cloud-gaon",
            title: "솜사탕 구름",
            mode: .chat,
            createdDaysAgo: 2,
            updatedSecondsAgo: 40 * DevelopmentFixtureClock.minute,
            pattern: .compactPair(
                user: "저 구름은 정말 솜사탕처럼 보여.",
                assistant: "가장자리의 얇은 빛까지 분홍색이라 더 그렇게 보여."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-gaon-empty-sky",
            characterID: "fixture-cloud-gaon",
            title: "비어 있는 하늘",
            mode: .story,
            createdDaysAgo: 6,
            updatedSecondsAgo: 4 * DevelopmentFixtureClock.day,
            pattern: .empty
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-gaon-eastward",
            characterID: "fixture-cloud-gaon",
            title: "오늘의 구름은 천천히 동쪽으로",
            mode: .chat,
            createdDaysAgo: 200,
            updatedSecondsAgo: 120 * DevelopmentFixtureClock.day,
            pattern: .multiline(
                user: "관측표를 열두 줄로 남겨 줘.",
                assistant: """
                06:00 얇은 층운
                07:00 북서풍 약함
                08:00 가장자리 밝아짐
                09:00 구름량 4
                10:00 이동 방향 동쪽
                11:00 작은 적운 발생
                12:00 그림자 짧아짐
                13:00 수분감 증가
                14:00 구름량 6
                15:00 이동 속도 느림
                16:00 서쪽 하늘 맑음
                17:00 관측 종료
                """
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-seon-double-noon",
            characterID: "fixture-clockforest-seon",
            title: "정오가 두 번 오는 길",
            mode: .story,
            createdDaysAgo: 12,
            updatedSecondsAgo: 9 * DevelopmentFixtureClock.minute,
            pattern: .multiDayTimeline(
                firstUser: "첫 번째 정오에 붉은 표지판을 봤어.",
                firstAssistant: "그 표지판은 시간을 되돌리는 길의 입구야.",
                secondUser: "오늘 두 번째 정오에는 파란 표지판이 나타났어.",
                secondAssistant: "이제 숲을 나갈 수 있어. 파란 화살표만 따라와."
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-seon-midnight-sign",
            characterID: "fixture-clockforest-seon",
            title: "00:00에서 멈춘 표지판",
            mode: .chat,
            createdDaysAgo: 9,
            updatedSecondsAgo: 25 * DevelopmentFixtureClock.hour,
            pattern: .systemMix(
                system: "시계숲 안전 규칙 3번을 적용합니다.",
                user: "표지판 시계가 자정에서 움직이지 않아.",
                assistant: "그 길에서는 실제 시계보다 발자국 수를 믿어야 해.",
                notice: "시간 왜곡 구간 · 합성 안내"
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-seon-no-rewind",
            characterID: "fixture-clockforest-seon",
            title: "되감기 금지",
            mode: .chat,
            createdDaysAgo: 45,
            updatedSecondsAgo: 21 * DevelopmentFixtureClock.day,
            pattern: .cancelled(
                user: "방금 선택을 되돌리고 다른 길로 갈래.",
                partial: "되감기 표식이 켜져 있어서 지금은"
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-mir-radio-917",
            characterID: "fixture-harbor-radio-mir",
            title: "오늘 밤 91.7",
            mode: .chat,
            createdDaysAgo: 3,
            updatedSecondsAgo: 20,
            pattern: .dialogue(
                pairs: [
                    ("91.7에 약한 신호가 잡혀.", "잡음을 줄이고 호출 부호를 들어 볼게."),
                    ("두 글자처럼 들려.", "첫 글자는 M, 두 번째는 R에 가까워."),
                    ("응답을 보내도 될까?", "짧게 세 번, 항구 식별 신호부터 보내자."),
                ]
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-mir-last-broadcast",
            characterID: "fixture-harbor-radio-mir",
            title: "폭풍 전 마지막 송출",
            mode: .story,
            createdDaysAgo: 12,
            updatedSecondsAgo: 3 * DevelopmentFixtureClock.day,
            pattern: .failed(
                user: "송출이 끊기기 전 마지막 문장을 복원해 줘.",
                partial: "모든 배는 동쪽 방파제를 피하고, 흰 등대를"
            )
        ),
        DevelopmentConversationSpec(
            id: "fixture-room-mir-lantern",
            characterID: "fixture-harbor-radio-mir",
            title: "LANTERN / 항구 신호",
            mode: .chat,
            createdDaysAgo: 80,
            updatedSecondsAgo: 45 * DevelopmentFixtureClock.day,
            pattern: .dialogue(
                pairs: [
                    (
                        "주파수 표에 LANTERN이라는 이름이 있어.",
                        "오래된 항구 식별 코드야. 기록을 열어 볼게."
                    ),
                    (
                        "LANTERN 신호가 세 번 들어왔어.",
                        "세 번이면 귀항 신호야. 북쪽 부표부터 확인해."
                    ),
                ]
            )
        ),
    ]

    private static func fixture(
        from spec: DevelopmentConversationSpec,
        anchor: Date
    ) -> FakeConversationFixture {
        let updatedAt = anchor.addingTimeInterval(
            -spec.updatedSecondsAgo
        )
        let createdAt = anchor.addingTimeInterval(
            -spec.createdDaysAgo * DevelopmentFixtureClock.day
        )
        return FakeConversationFixture(
            conversation: CoreConversation(
                id: spec.id,
                characterID: spec.characterID,
                title: spec.title,
                createdAt: DevelopmentFixtureClock.timestamp(createdAt),
                updatedAt: DevelopmentFixtureClock.timestamp(updatedAt)
            ),
            mode: spec.mode,
            messages: DevelopmentMessageCatalog.messages(
                for: spec.pattern,
                conversationID: spec.id,
                updatedAt: updatedAt
            )
        )
    }
}

private struct DevelopmentConversationSpec {
    let id: String
    let characterID: String
    let title: String
    let mode: ConversationMode
    let createdDaysAgo: Double
    let updatedSecondsAgo: TimeInterval
    let pattern: DevelopmentMessagePattern
}
#endif
