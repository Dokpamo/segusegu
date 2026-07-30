import SwiftUI

/// The provider profile, on its own page.
///
/// The root of settings lists what is connected; the editing of it — URLs,
/// model, key — belongs one level down, where a long form has room.
public struct SettingsProviderProfileView: View {
    @ObservedObject private var viewModel: SettingsViewModel
    @State private var showsProviderSelector = false

    public init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: LorepiaSettingsMetrics.cardSpacing) {
                selectionCard
                fieldsCard
                footnote
            }
            .padding(.horizontal, LorepiaSettingsMetrics.cardInset)
            .padding(.vertical, LorepiaSpacing.snug)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(LorepiaColor.paper.ignoresSafeArea())
        .navigationTitle("프로필 편집")
        .settingsDetailTitleDisplayMode()
        .disabled(viewModel.isLoading)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
    }

    private var selectionCard: some View {
        LorepiaSettingsCard {
            Button {
                showsProviderSelector = true
            } label: {
                LorepiaSettingsRow(
                    glyph: .shield,
                    title: "사용할 프로바이더",
                    subtitle: selectedProviderDisplayName
                ) {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("프로필")
            .accessibilityIdentifier("settings-provider-profile-picker")
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
                            await viewModel.selectProfile(id: profile.id)
                        }
                    }
                }
                Button("취소", role: .cancel) {}
            }
        }
    }

    private var fieldsCard: some View {
        LorepiaSettingsCard("프로필 편집") {
            LorepiaSettingsField("표시 이름", text: $viewModel.profileName)
            LorepiaSettingsField("Base URL", text: $viewModel.baseURL)
                .textContentType(.URL)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
#endif
            Text(viewModel.baseURLGuidance)
                .font(.footnote)
                .foregroundStyle(.secondary)
            LorepiaSettingsField("모델", text: $viewModel.model)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
            LorepiaSettingsField(
                "제한 시간(초)",
                text: $viewModel.timeoutSeconds
            )
#if os(iOS)
            .keyboardType(.numberPad)
#endif
            LorepiaSettingsField(
                viewModel.hasStoredCredential
                    ? "새 API 키를 입력하면 교체됩니다"
                    : "API 키 (선택 사항)",
                text: $viewModel.credentialDraft,
                isSecure: true
            )
            .textContentType(.password)
            .privacySensitive()

            Text(viewModel.credentialStatusDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .privacySensitive()

            if showsCredentialRecovery {
                Button(credentialRecoveryButtonTitle, role: .destructive) {
                    Task {
                        await viewModel.clearCredential()
                    }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("settings-credential-recovery")
            }
            if !viewModel.isCredentialStateKnown,
               viewModel.isEditingStoredProfile
            {
                Button("API 키 상태 다시 확인") {
                    Task {
                        await viewModel.refreshCredentialStatus()
                    }
                }
                .frame(minHeight: 44)
            }

            if let errorMessage = viewModel.errorMessage {
                Label(
                    errorMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
            if let statusMessage = viewModel.statusMessage {
                LorepiaGlyphLabel(statusMessage, glyph: .check)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings-status-message")
            }

            HStack {
                Button("새 프로필") {
                    viewModel.beginNewProfile()
                }
                .frame(minHeight: 44)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings-new-provider-profile")

                Spacer()

                Button("프로필 삭제", role: .destructive) {
                    Task {
                        await viewModel.deleteEditingProfile()
                    }
                }
                .frame(minHeight: 44)
                .disabled(!viewModel.isEditingStoredProfile)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("settings-delete-provider-profile")

                Button("저장") {
                    Task {
                        await viewModel.saveProfile()
                    }
                }
                .frame(minHeight: 44)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("settings-save-provider-profile")
            }
        }
    }

    private var footnote: some View {
        Text(
            "API 키는 Keychain에만 저장되며 Rust 데이터베이스나 앱 로그에 기록되지 않습니다."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, LorepiaSpacing.tight)
    }

    private var showsCredentialRecovery: Bool {
        viewModel.hasStoredCredential
            || viewModel.requiresCredentialRecovery
            || (
                !viewModel.isCredentialStateKnown
                    && viewModel.isEditingStoredProfile
            )
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

extension View {
    @ViewBuilder
    func settingsDetailTitleDisplayMode() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }
}
