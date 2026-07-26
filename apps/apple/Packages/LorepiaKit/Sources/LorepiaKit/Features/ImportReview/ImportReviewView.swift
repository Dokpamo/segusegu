import SwiftUI

public struct ImportReviewView: View {
    @ObservedObject private var viewModel: ImportReviewViewModel
    private let onPickFile: () -> Void

    public init(
        viewModel: ImportReviewViewModel,
        onPickFile: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onPickFile = onPickFile
    }

    public var body: some View {
        Group {
            switch viewModel.state {
            case .empty:
                ContentUnavailableView {
                    Label("검토할 파일이 없습니다", systemImage: "doc.badge.plus")
                } description: {
                    Text("플랫폼 문서 선택기에서 캐릭터 패키지를 선택하세요.")
                } actions: {
                    Button("파일 선택", action: onPickFile)
                        .buttonStyle(.borderedProminent)
                }
            case let .selected(candidate):
                review(candidate)
            case let .acceptedForPreview(candidate):
                ContentUnavailableView {
                    Label("프리뷰 검토 완료", systemImage: "checkmark.circle")
                } description: {
                    Text("\(candidate.displayName)은 저장되거나 파싱되지 않았습니다.")
                } actions: {
                    Button("다른 파일 선택", action: onPickFile)
                }
            }
        }
        .padding(LorepiaSpacing.standard)
    }

    private func review(_ candidate: ImportCandidate) -> some View {
        VStack(alignment: .leading, spacing: LorepiaSpacing.roomy) {
            VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                Label("선택한 콘텐츠", systemImage: "doc")
                    .font(.headline)
                Text(candidate.displayName)
                    .font(.title3)
                    .textSelection(.enabled)
                Text(
                    viewModel.previewEnabled
                        ? "프리뷰 모드에서는 파일을 읽지 않고 선택 흐름만 검증합니다."
                        : "Rust 콘텐츠 검사 API가 결과를 제공하면 이 화면에 안전성 검사를 표시합니다."
                )
                .foregroundStyle(.secondary)
            }
            .lorepiaCard()

            HStack {
                Button("선택 해제", action: viewModel.clear)
                Spacer()
                Button("프리뷰 검토 완료", action: viewModel.acceptForPreview)
                    .buttonStyle(.borderedProminent)
                    .disabled(!viewModel.previewEnabled)
            }

            Spacer()
        }
        .frame(maxWidth: 680)
    }
}
