import SwiftUI

public struct SettingsView: View {
    @ObservedObject private var viewModel: SettingsViewModel
    @State private var showsProviderSelector = false

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
                Button {
                    showsProviderSelector = true
                } label: {
                    HStack {
                        Text("프로필")
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(selectedProviderDisplayName)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("프로필")
                .accessibilityIdentifier(
                    "settings-provider-profile-picker"
                )
                .accessibilityValue(selectedProviderDisplayName)
                .confirmationDialog(
                    "사용할 프로바이더",
                    isPresented: $showsProviderSelector
                ) {
                    Button("선택 안 함") {
                        Task {
                            await viewModel.selectProfile(id: nil)
                        }
                    }
                    ForEach(viewModel.profiles) { profile in
                        Button(profile.displayName) {
                            Task {
                                await viewModel.selectProfile(
                                    id: profile.id
                                )
                            }
                        }
                    }
                    Button("취소", role: .cancel) {}
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
                Text(viewModel.baseURLGuidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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

                Text(viewModel.credentialStatusDescription)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .privacySensitive()

                if viewModel.hasStoredCredential
                    || viewModel.requiresCredentialRecovery
                    || (
                        !viewModel.isCredentialStateKnown
                            && viewModel.isEditingStoredProfile
                    )
                {
                    Button(
                        credentialRecoveryButtonTitle,
                        role: .destructive
                    ) {
                        Task {
                            await viewModel.clearCredential()
                        }
                    }
                    .accessibilityIdentifier(
                        "settings-credential-recovery"
                    )
                }
                if !viewModel.isCredentialStateKnown,
                   viewModel.isEditingStoredProfile
                {
                    Button("API 키 상태 다시 확인") {
                        Task {
                            await viewModel.refreshCredentialStatus()
                        }
                    }
                }

                HStack {
                    newProfileButton
                    Spacer()
                    deleteProfileButton
                    saveProfileButton
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
                        .accessibilityIdentifier(
                            "settings-status-message"
                        )
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
        .disabled(viewModel.isLoading)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
    }

    private var credentialRecoveryButtonTitle: String {
        if viewModel.hasStoredCredential {
            return "저장된 자격증명 삭제"
        }
        if viewModel.requiresCredentialRecovery {
            return "API 키 없이 복구"
        }
        return "읽을 수 없는 API 키 삭제"
    }

    private var newProfileButton: some View {
        Button("새 프로필") {
            viewModel.beginNewProfile()
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("settings-new-provider-profile")
    }

    private var deleteProfileButton: some View {
        Button("프로필 삭제", role: .destructive) {
            Task {
                await viewModel.deleteEditingProfile()
            }
        }
        .disabled(!viewModel.isEditingStoredProfile)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("settings-delete-provider-profile")
    }

    private var saveProfileButton: some View {
        Button("저장") {
            Task {
                await viewModel.saveProfile()
            }
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("settings-save-provider-profile")
    }

    private var selectedProviderDisplayName: String {
        guard
            let selectedProfileID = viewModel.selectedProfileID,
            let selectedProfile = viewModel.profiles.first(where: {
                $0.id == selectedProfileID
            })
        else {
            return "선택 안 함"
        }
        return selectedProfile.displayName
    }
}
