import SwiftUI

/// Where the core's own state lives.
///
/// Runtime mode and the status panel are diagnostics: useful when something is
/// wrong, noise on the main settings page when nothing is. They sit one page
/// down, and a broken core announces itself on the page above regardless.
public struct SettingsDiagnosticsView: View {
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
                LorepiaSettingsCard {
                    LorepiaSettingsRow(
                        glyph: .waveform,
                        title: "실행 모드",
                        subtitle: runtimeSubtitle
                    )

                }

                // The panel owns its title and card treatment.
                CoreStatusPanel(viewModel: coreStatus)

                Text("이 값들은 문제를 찾을 때만 필요합니다.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, LorepiaSpacing.tight)
            }
            .padding(.horizontal, LorepiaSettingsMetrics.cardInset)
            .padding(.vertical, LorepiaSpacing.snug)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background(LorepiaColor.paper.ignoresSafeArea())
        .navigationTitle("진단")
        .settingsDetailTitleDisplayMode()
    }

    private var runtimeSubtitle: String {
        if case let .unavailable(message) = viewModel.runtimeMode {
            return message
        }
        return viewModel.runtimeMode.displayName
    }
}
