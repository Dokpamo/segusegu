import SwiftUI

/// Destinations that can be opened from settings or from another app surface.
public enum SettingsDestination: Hashable, Sendable {
    case providerProfile
    case diagnostics
}

public struct SettingsView: View {
    @ObservedObject private var viewModel: SettingsViewModel
    @ObservedObject private var coreStatus: CoreStatusViewModel

    public init(
        viewModel: SettingsViewModel,
        coreStatus: CoreStatusViewModel
    ) {
        self.viewModel = viewModel
        self.coreStatus = coreStatus
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: LorepiaSettingsMetrics.cardSpacing) {
                guestIdentityHeader
                connectionCard
                generalCard
                statusCard
            }
            .padding(.horizontal, LorepiaSettingsMetrics.cardInset)
            .padding(.bottom, LorepiaSpacing.roomy)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(LorepiaColor.paper.ignoresSafeArea())
        .disabled(viewModel.isLoading)
        .overlay {
            if viewModel.isLoading {
                ProgressView()
            }
        }
        .navigationDestination(for: SettingsDestination.self) { destination in
            settingsDestination(destination)
        }
    }

    /// The local identity header from the settings reference.
    ///
    /// Its account behavior is intentionally absent: LorePia remains
    /// local-first, while the visual hierarchy still starts with the current
    /// guest identity.
    private var guestIdentityHeader: some View {
        VStack(spacing: LorepiaSpacing.snug) {
            LorepiaAvatar(
                symbolName: "person.fill",
                size: 104
            )
            .overlay(alignment: .bottomTrailing) {
                LorepiaGlyphView(.plus, size: 17)
                    .foregroundStyle(LorepiaColor.paper)
                    .frame(width: 32, height: 32)
                    .background(Color.primary, in: Circle())
                    .overlay {
                        Circle().strokeBorder(
                            LorepiaColor.paper,
                            lineWidth: 2.5
                        )
                    }
                    .accessibilityHidden(true)
            }

            Text("게스트")
                .font(.title3.weight(.semibold))
        }
        .padding(.top, LorepiaSpacing.compact)
        .padding(.bottom, LorepiaSpacing.tight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("게스트")
        .accessibilityIdentifier("settings-guest-identity")
    }

    private var connectionCard: some View {
        LorepiaSettingsCard {
            NavigationLink(value: SettingsDestination.providerProfile) {
                providerProfileRow
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-provider-profile-row")

            // The core only earns a line here when it is broken. Otherwise
            // its state is a diagnostic, one page down.
            if case let .unavailable(message) = viewModel.runtimeMode {
                LorepiaSettingsRow(
                    glyph: .waveform,
                    title: "코어를 사용할 수 없습니다",
                    subtitle: message
                )
            }
        }
    }

    private var generalCard: some View {
        LorepiaSettingsCard {
            Toggle(
                isOn: Binding(
                    get: { viewModel.preservePartialGenerations },
                    set: { value in
                        Task {
                            await viewModel.setPreservePartialGenerations(value)
                        }
                    }
                )
            ) {
                LorepiaSettingsRow(
                    glyph: .retry,
                    title: "취소·실패한 부분 응답 보존",
                    subtitle: "중단된 응답도 대화에 남겨 둡니다"
                )
            }

            NavigationLink(value: SettingsDestination.diagnostics) {
                diagnosticsRow
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("settings-diagnostics-row")
        }
    }

    private var providerProfileRow: some View {
        LorepiaSettingsRow(
            glyph: .shield,
            title: connectionTitle,
            subtitle: connectionSubtitle
        ) {
            disclosure
        }
        .contentShape(Rectangle())
    }

    private var diagnosticsRow: some View {
        LorepiaSettingsRow(
            glyph: .waveform,
            title: "진단",
            subtitle: "실행 모드와 코어 상태"
        ) {
            disclosure
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func settingsDestination(
        _ destination: SettingsDestination
    ) -> some View {
        switch destination {
        case .providerProfile:
            SettingsProviderProfileView(viewModel: viewModel)
        case .diagnostics:
            SettingsDiagnosticsView(
                viewModel: viewModel,
                coreStatus: coreStatus
            )
        }
    }

    @ViewBuilder
    private var statusCard: some View {
        if let errorMessage = viewModel.errorMessage {
            LorepiaSettingsCard {
                Label(
                    errorMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }

    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    private var connectionTitle: String {
        selectedProviderProfile?.displayName ?? "프로바이더 연결"
    }

    /// The model and whether a key is stored: what the reader needs to know
    /// without opening the page.
    private var connectionSubtitle: String {
        guard let selectedProviderProfile else {
            return "아직 연결된 프로바이더가 없습니다"
        }
        let model = selectedProviderProfile.model.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let hasCredential =
            viewModel.selectedProfileCredentialPresence
        else {
            return model
        }
        let key = hasCredential ? "API 키 저장됨" : "API 키 없음"
        return model.isEmpty ? key : "\(model) · \(key)"
    }

    private var selectedProviderProfile: ProviderProfile? {
        guard
            let selectedProfileID = viewModel.selectedProfileID,
            let selectedProfile = viewModel.profiles.first(where: {
                $0.id == selectedProfileID
            })
        else {
            return nil
        }
        return selectedProfile
    }
}
