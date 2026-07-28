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

            Section("사용할 프로바이더") {
                Picker(
                    "프로필",
                    selection: Binding(
                        get: { viewModel.selectedProfileID },
                        set: { id in
                            Task {
                                await viewModel.selectProfile(id: id)
                            }
                        }
                    )
                ) {
                    Text("선택 안 함").tag(String?.none)
                    ForEach(viewModel.profiles) { profile in
                        Text(profile.displayName).tag(Optional(profile.id))
                    }
                }

                Toggle(
                    "취소·실패한 부분 응답 보존",
                    isOn: Binding(
                        get: { viewModel.preservePartialGenerations },
                        set: { value in
                            Task {
                                await viewModel.setPreservePartialGenerations(value)
                            }
                        }
                    )
                )
            }

            Section("프로필 편집") {
                TextField("표시 이름", text: $viewModel.profileName)
                TextField("Base URL", text: $viewModel.baseURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    #endif
                TextField("모델", text: $viewModel.model)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    #endif
                TextField("제한 시간(초)", text: $viewModel.timeoutSeconds)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                SecureField(
                    viewModel.hasStoredCredential
                        ? "새 API 키를 입력하면 교체됩니다"
                        : "API 키 (선택 사항)",
                    text: $viewModel.credentialDraft
                )
                .textContentType(.password)
                .privacySensitive()

                if viewModel.hasStoredCredential {
                    Label("Keychain에 자격증명이 저장되어 있습니다.", systemImage: "key.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("저장된 자격증명 삭제", role: .destructive) {
                        Task {
                            await viewModel.clearCredential()
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack {
                        newProfileButton
                        Spacer()
                        deleteProfileButton
                        saveProfileButton
                    }

                    VStack(spacing: LorepiaSpacing.compact) {
                        newProfileButton
                            .frame(maxWidth: .infinity)
                        deleteProfileButton
                            .frame(maxWidth: .infinity)
                        saveProfileButton
                            .frame(maxWidth: .infinity)
                    }
                }
            }

            Section("화면") {
                Toggle(
                    "기술 상태 패널 표시",
                    isOn: $viewModel.showTechnicalDetails
                )
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            if let statusMessage = viewModel.statusMessage {
                Section {
                    LorepiaGlyphLabel(statusMessage, glyph: .check)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Text(
                    "API 키는 Keychain에만 저장되며 Rust 데이터베이스나 앱 로그에 기록되지 않습니다."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
    }

    private var newProfileButton: some View {
        Button("새 프로필") {
            viewModel.beginNewProfile()
        }
    }

    private var deleteProfileButton: some View {
        Button("프로필 삭제", role: .destructive) {
            Task {
                await viewModel.deleteEditingProfile()
            }
        }
    }

    private var saveProfileButton: some View {
        Button("저장") {
            Task {
                await viewModel.saveProfile()
            }
        }
        .buttonStyle(.borderedProminent)
    }
}
