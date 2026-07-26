import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var viewModel: SettingsViewModel

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        Form {
            Section("코어") {
                LabeledContent("실행 모드", value: viewModel.runtimeMode.displayName)
                if case let .unavailable(message) = viewModel.runtimeMode {
                    LabeledContent("오류") {
                        Text(message)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }

            Section("화면") {
                Toggle(
                    "기술 상태 패널 표시",
                    isOn: $viewModel.showTechnicalDetails
                )
                Toggle(
                    "메시지 전송 전 확인",
                    isOn: $viewModel.confirmBeforeSending
                )
            }

            Section {
                Text(
                    "자격증명, 파일 선택, 앱 생명주기는 각 플랫폼이 담당하며 콘텐츠 파싱과 저장은 Rust 코어만 수행합니다."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
