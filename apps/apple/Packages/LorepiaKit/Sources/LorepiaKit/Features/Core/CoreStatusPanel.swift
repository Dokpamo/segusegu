import SwiftUI

public struct CoreStatusPanel: View {
    @ObservedObject private var viewModel: CoreStatusViewModel

    public init(viewModel: CoreStatusViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LorepiaSpacing.standard) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("코어 상태")
                        .font(.headline)
                    Text(viewModel.runtimeMode.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        await viewModel.refresh()
                    }
                } label: {
                    LorepiaGlyphView(.regenerate, size: 18)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("코어 상태 새로 고침")
            }

            statusContent
        }
        .lorepiaCard()
        .task {
            if viewModel.state == .idle {
                await viewModel.refresh()
            }
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.state {
        case .idle, .loading:
            HStack(spacing: LorepiaSpacing.compact) {
                ProgressView()
                Text("코어를 확인하는 중입니다.")
                    .foregroundStyle(.secondary)
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
        case let .ready(version, health):
            VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                if health.isHealthy {
                    LorepiaGlyphLabel("정상", glyph: .check)
                        .foregroundStyle(.green)
                } else {
                    Label(
                        "확인 필요",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .foregroundStyle(.orange)
                }

                Divider()

                CoreStatusRow(label: "버전", value: version)
                CoreStatusRow(
                    label: "데이터베이스",
                    value: health.databaseOpen ? "열림" : "닫힘"
                )
                CoreStatusRow(
                    label: "스키마",
                    value: String(health.schemaVersion)
                )
                CoreStatusRow(
                    label: "데이터 경로",
                    value: health.dataRootWritable ? "쓰기 가능" : "읽기 전용"
                )
                CoreStatusRow(
                    label: "Staging",
                    value: health.stagingWritable ? "쓰기 가능" : "읽기 전용"
                )
                CoreStatusRow(
                    label: "복구",
                    value: health.recoveryPending ? "대기 중" : "없음"
                )
                CoreStatusRow(
                    label: "활성 작업",
                    value: String(health.activeJobs)
                )
            }
        }
    }
}

private struct CoreStatusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: LorepiaSpacing.compact)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}
