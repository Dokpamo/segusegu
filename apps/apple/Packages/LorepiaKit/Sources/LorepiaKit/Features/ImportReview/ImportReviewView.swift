import SwiftUI

public struct ImportReviewView: View {
    @ObservedObject private var viewModel: ImportReviewViewModel
    private let onPickFile: () -> Void
    private let onFinished: () -> Void

    public init(
        viewModel: ImportReviewViewModel,
        onPickFile: @escaping () -> Void,
        onFinished: @escaping () -> Void = {}
    ) {
        self.viewModel = viewModel
        self.onPickFile = onPickFile
        self.onFinished = onFinished
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
            case let .loading(fileName):
                progress(title: "안전하게 복사하고 검사하는 중", detail: fileName)
            case let .review(inspection):
                review(inspection, commitError: nil)
            case let .committing(inspection):
                progress(title: "서재에 저장하는 중", detail: inspection.displayName)
            case let .completed(character):
                ContentUnavailableView {
                    Label("가져오기 완료", systemImage: "checkmark.circle.fill")
                } description: {
                    Text("\(character.name)을(를) 서재에 저장했습니다.")
                } actions: {
                    Button("서재로 이동", action: onFinished)
                        .buttonStyle(.borderedProminent)
                }
            case let .commitFailed(inspection, message):
                review(inspection, commitError: message)
            case let .failed(fileName, message):
                ContentUnavailableView {
                    Label("가져오지 못했습니다", systemImage: "exclamationmark.triangle")
                } description: {
                    VStack(spacing: LorepiaSpacing.compact) {
                        Text(fileName)
                        Text(message)
                    }
                } actions: {
                    Button("다른 파일 선택", action: onPickFile)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(LorepiaSpacing.standard)
        .onDisappear {
            Task {
                await viewModel.discardPending()
            }
        }
    }

    private func review(
        _ inspection: ImportInspection,
        commitError: String?
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LorepiaSpacing.roomy) {
                if let commitError {
                    VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                        Label("저장하지 못했습니다", systemImage: "arrow.clockwise.circle")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text(commitError)
                            .font(.callout)
                        Text("검사 결과는 유지되었습니다. 다시 저장하거나 안전하게 버릴 수 있습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .lorepiaCard()
                    .accessibilityElement(children: .combine)
                }

                VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                    Label("Rust 코어 검사 결과", systemImage: "checkmark.shield")
                        .font(.headline)
                    Text(inspection.displayName)
                        .font(.title3)
                        .textSelection(.enabled)
                    if !inspection.description.isEmpty {
                        Text(inspection.description)
                            .foregroundStyle(.secondary)
                    }
                    Divider()
                    inspectionRow("형식", inspection.contentKind)
                    inspectionRow(
                        "원본 크기",
                        ByteCountFormatter.string(
                            fromByteCount: Int64(inspection.sourceSize),
                            countStyle: .file
                        )
                    )
                    inspectionRow(
                        "예상 저장 크기",
                        ByteCountFormatter.string(
                            fromByteCount: Int64(inspection.estimatedStoredSize),
                            countStyle: .file
                        )
                    )
                    inspectionRow("에셋", "\(inspection.assetCount)개")
                    inspectionRow(
                        "대표 이미지",
                        inspection.representativeImage.map {
                            "\($0.logicalAssetID) · \($0.mediaType) · " +
                                ByteCountFormatter.string(
                                    fromByteCount: Int64(
                                        min($0.sizeBytes, UInt64(Int64.max))
                                    ),
                                    countStyle: .file
                                )
                        } ?? "없음"
                    )
                    inspectionRow("SHA-256", inspection.sourceSHA256)
                }
                .lorepiaCard()

                if !inspection.unsupportedOptionalFields.isEmpty {
                    VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                        Label("지원하지 않는 선택 필드", systemImage: "questionmark.folder")
                            .font(.headline)
                        ForEach(inspection.unsupportedOptionalFields, id: \.self) {
                            Text($0)
                                .font(.callout)
                        }
                    }
                    .lorepiaCard()
                    .accessibilityElement(children: .combine)
                }

                if !inspection.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                        Label("주의 사항", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        ForEach(inspection.warnings) { warning in
                            Text("[\(warning.code)] \(warning.message)")
                                .font(.callout)
                        }
                    }
                    .lorepiaCard()
                    .accessibilityElement(children: .combine)
                }

                if !inspection.blockedReasons.isEmpty {
                    VStack(alignment: .leading, spacing: LorepiaSpacing.compact) {
                        Label("가져오기 차단", systemImage: "xmark.octagon.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        ForEach(inspection.blockedReasons, id: \.self) {
                            Text($0)
                        }
                    }
                    .lorepiaCard()
                    .accessibilityElement(children: .combine)
                }

                HStack {
                    Button(
                        commitError == nil ? "취소" : "검사 결과 버리기",
                        role: commitError == nil ? nil : .destructive
                    ) {
                        Task {
                            await viewModel.discardPending()
                        }
                    }
                    Spacer()
                    Button(commitError == nil ? "서재에 저장" : "다시 저장") {
                        Task {
                            await viewModel.commit()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!inspection.isAllowed)
                    .accessibilityHint(
                        inspection.isAllowed
                            ? "검사한 콘텐츠를 앱 서재에 저장합니다"
                            : "검사 결과에 차단 사유가 있어 저장할 수 없습니다"
                    )
                }
            }
            .frame(maxWidth: 680)
        }
    }

    private func progress(title: String, detail: String) -> some View {
        VStack(spacing: LorepiaSpacing.standard) {
            ProgressView()
            Text(title)
                .font(.headline)
            Text(detail)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func inspectionRow(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}
