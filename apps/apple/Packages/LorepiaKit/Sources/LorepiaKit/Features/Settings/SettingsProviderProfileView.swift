import SwiftUI
import UniformTypeIdentifiers

public struct SettingsProviderProfileView: View {
    @ObservedObject private var viewModel: ProviderSetupViewModel
    @State private var presentedSetup: ProviderSetupPresentation?

    public init(viewModel: SettingsViewModel) {
        _viewModel = ObservedObject(
            wrappedValue: viewModel.providerSetupViewModel
        )
    }

    public var body: some View {
        List {
            connectionSection
            catalogSection
            safetySection
            messageSection
        }
        .navigationTitle("AI 연결")
        .settingsDetailTitleDisplayMode()
        .refreshable {
            await viewModel.refresh()
        }
        .task {
            if viewModel.loadState == .idle {
                await viewModel.refresh()
            }
        }
        .overlay {
            if viewModel.loadState == .loading,
               viewModel.connections.isEmpty
            {
                ProgressView("프로바이더 연결 불러오는 중")
                    .accessibilityIdentifier(
                        "provider-connections-loading"
                    )
            }
        }
        .sheet(item: $presentedSetup) { presentation in
            ProviderDiscoveryWizard(
                viewModel: viewModel,
                method: presentation.method
            )
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            if viewModel.connections.isEmpty,
               viewModel.loadState == .loaded
            {
                ContentUnavailableView(
                    "연결된 AI 서비스 없음",
                    systemImage: "bolt.horizontal.circle",
                    description: Text(
                        "API 키나 서비스 주소로 연결 방법과 모델을 찾을 수 있습니다."
                    )
                )
                .accessibilityIdentifier("provider-connections-empty")
            } else {
                ForEach(viewModel.connections) { connection in
                    NavigationLink {
                        ProviderConnectionDetailView(
                            viewModel: viewModel,
                            connection: connection
                        )
                    } label: {
                        ProviderConnectionLabel(connection: connection)
                    }
                    .accessibilityIdentifier(
                        "provider-connection-\(connection.id)"
                    )
                }
            }
        } header: {
            Text("연결")
        } footer: {
            Text(
                "하나의 연결에서 여러 모델 경로와 생성 프리셋을 관리합니다."
            )
        }

        Section("새 AI 연결") {
            ForEach(ProviderDiscoveryMethod.allCases) { method in
                Button {
                    presentedSetup = ProviderSetupPresentation(
                        method: method
                    )
                } label: {
                    Label(method.title, systemImage: method.symbolName)
                }
                .accessibilityIdentifier(
                    "provider-add-\(method.rawValue)"
                )
            }
        }
    }

    @ViewBuilder
    private var catalogSection: some View {
        Section("프로바이더 카탈로그") {
            NavigationLink {
                ProviderCatalogView(viewModel: viewModel)
            } label: {
                LabeledContent(
                    "서명 카탈로그",
                    value: catalogValue
                )
            }
            .accessibilityIdentifier("provider-catalog-row")
        }
    }

    private var safetySection: some View {
        Section("개인정보와 보안") {
            Label(
                "API 키는 이 기기의 Keychain에만 저장됩니다.",
                systemImage: "key.fill"
            )
            Label(
                "새 서버나 문서 분석 AI로 보내기 전에 대상을 확인합니다.",
                systemImage: "checkmark.shield.fill"
            )
            Label(
                "요청 미리보기는 인증값, 비공개 메시지와 추론 상태를 가립니다.",
                systemImage: "eye.slash.fill"
            )
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var messageSection: some View {
        if let errorMessage = viewModel.errorMessage {
            Section {
                Label(
                    errorMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier("provider-error-message")
            }
        }
        if let statusMessage = viewModel.statusMessage {
            Section {
                Label(
                    statusMessage,
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("provider-status-message")
            }
        }
    }

    private var catalogValue: String {
        guard let catalog = viewModel.catalogStatus else {
            return "확인 필요"
        }
        if let revision = catalog.currentRevision {
            return "r\(revision) · \(catalog.currentSource)"
        }
        return catalog.currentSource
    }
}

private struct ProviderSetupPresentation: Identifiable {
    let id = UUID()
    let method: ProviderDiscoveryMethod
}

private struct ProviderConnectionLabel: View {
    let connection: ProviderConnectionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(connection.displayName)
                    .font(.body.weight(.medium))
                Spacer()
                ProviderStatusBadge(status: connection.status)
            }
            Text(connection.apiOrigin)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .privacySensitive()
            Text(
                connection.hasCredential
                    ? "API 키 저장됨 · \(connection.templateID)"
                    : "API 키 없음 · \(connection.templateID)"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
    }
}

private struct ProviderStatusBadge: View {
    let status: String

    var body: some View {
        Text(displayName)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var displayName: String {
        switch status {
        case "connected": "연결됨"
        case "auth_failed": "인증 필요"
        case "unavailable": "사용 불가"
        default: "검사 필요"
        }
    }

    private var color: Color {
        switch status {
        case "connected": .green
        case "auth_failed": .orange
        case "unavailable": .red
        default: .secondary
        }
    }
}

private struct ProviderDiscoveryWizard: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ProviderSetupViewModel
    let method: ProviderDiscoveryMethod
    @State private var didPrepare = false

    var body: some View {
        NavigationStack {
            Form {
                if let discovery = viewModel.discovery {
                    progressSection(discovery)
                    actionSection(discovery)
                    reviewSection(discovery)
                } else {
                    inputSections
                }
                messageSection
            }
            .navigationTitle("새 AI 연결")
            .settingsDetailTitleDisplayMode()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(discoveryDismissActionTitle) {
                        if viewModel.hasActiveDiscovery {
                            Task {
                                await viewModel.cancelDiscovery()
                            }
                        } else if
                            viewModel.hasPendingDiscoveryCredentialCleanup
                        {
                            Task {
                                await viewModel
                                    .cleanupDiscoveryCredential()
                            }
                        } else {
                            dismiss()
                        }
                    }
                    .disabled(viewModel.isBusy)
                    .accessibilityIdentifier("provider-discovery-cancel")
                }
            }
            .disabled(viewModel.isBusy)
            .overlay {
                if viewModel.isBusy {
                    ProgressView()
                }
            }
            .interactiveDismissDisabled(
                viewModel.hasActiveDiscovery
                    || viewModel
                        .hasPendingDiscoveryCredentialCleanup
            )
            .onAppear {
                guard !didPrepare else {
                    return
                }
                didPrepare = true
                viewModel.prepareDiscovery(method: method)
            }
        }
    }

    private var discoveryDismissActionTitle: String {
        if viewModel.hasActiveDiscovery {
            return "탐색 취소"
        }
        if viewModel.hasPendingDiscoveryCredentialCleanup {
            return "Keychain 정리"
        }
        return "닫기"
    }

    @ViewBuilder
    private var inputSections: some View {
        Section {
            TextField(
                "연결 이름",
                text: $viewModel.discoveryDisplayName
            )
            .accessibilityIdentifier("provider-discovery-name")

            if method == .knownProvider {
                Picker(
                    "프로바이더",
                    selection: Binding(
                        get: {
                            viewModel.selectedTemplateID
                                ?? viewModel.templates.first?.id
                                ?? ""
                        },
                        set: {
                            viewModel.selectDiscoveryTemplate(id: $0)
                        }
                    )
                ) {
                    ForEach(viewModel.templates) { template in
                        Text(template.displayName).tag(template.id)
                    }
                }
                .accessibilityIdentifier(
                    "provider-discovery-template"
                )
            }
        } header: {
            Text(method.title)
        }

        switch method {
        case .knownProvider:
            knownProviderInput
        case .website:
            websiteInput
        case .curl:
            curlInput
        case .localServer:
            localInput
        }

        assistantRouteInput

        Section {
            Button("연결 및 모델 찾기") {
                Task {
                    await viewModel.startDiscovery()
                }
            }
            .frame(maxWidth: .infinity)
            .disabled(!viewModel.canStartDiscovery)
            .accessibilityIdentifier("provider-discovery-start")
        } footer: {
            Text(
                "API 키는 선택한 API 서버에만 전송되며 문서 분석용 AI에는 전달되지 않습니다."
            )
        }
    }

    private var assistantRouteInput: some View {
        Section {
            if viewModel.assistantModelRoutes.isEmpty {
                Label(
                    "사용할 수 있는 문서 분석 모델이 없습니다.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier(
                    "provider-discovery-assistant-route-empty"
                )
            } else {
                Picker(
                    "설정 도우미 모델",
                    selection: Binding<String?>(
                        get: {
                            viewModel
                                .selectedAssistantModelRouteID
                        },
                        set: {
                            viewModel.selectAssistantModelRoute(
                                id: $0
                            )
                        }
                    )
                ) {
                    Text("선택 안 함")
                        .tag(Optional<String>.none)
                    ForEach(viewModel.assistantModelRoutes) {
                        route in
                        Text(
                            viewModel.assistantRouteTitle(route)
                        )
                        .tag(Optional(route.id))
                    }
                }
                .accessibilityIdentifier(
                    "provider-discovery-assistant-route"
                )

                if let route =
                    viewModel.selectedAssistantModelRoute
                {
                    LabeledContent(
                        "정확한 route ID",
                        value: route.id
                    )
                    .font(.caption)
                    .privacySensitive()
                }
            }

            if let message =
                viewModel.assistantRouteSelectionMessage
            {
                Label(
                    message,
                    systemImage: "info.circle"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(
                    "provider-discovery-assistant-route-message"
                )
            }
        } header: {
            Text("API 문서 분석 AI")
        } footer: {
            Text(
                method == .website
                    ? "사이트 자동 찾기는 먼저 결정론적으로 진행합니다. 현재 앱 기본 모델이 있으면 막힌 단계에서 문서 분석 도우미로 선택할 수 있으며 API 키는 전달하지 않습니다."
                    : "결정론적 탐색이 막힌 경우에만 이 모델을 선택적으로 사용할 수 있습니다. API 키는 전달하지 않습니다."
            )
        }
    }

    @ViewBuilder
    private var knownProviderInput: some View {
        Section {
            if let template =
                viewModel.selectedDiscoveryTemplate
            {
                ForEach(
                    template.connectionFields.filter {
                        $0.type != .credential
                    }
                ) { field in
                    connectionFieldInput(field)
                }
                if template.requiresCredential
                    || template.connectionFields.contains(where: {
                        $0.type == .credential
                    })
                {
                    SecureField(
                        template.connectionFields.first(where: {
                            $0.type == .credential
                        })?.label ?? "API 키",
                        text: $viewModel.credentialDraft
                    )
                    .textContentType(.password)
                    .privacySensitive()
                    .accessibilityIdentifier(
                        "provider-discovery-credential"
                    )
                } else {
                    Label(
                        "이 프로바이더는 API 키가 필요하지 않습니다.",
                        systemImage: "checkmark.circle"
                    )
                }
                if template.defaultNetworkMode == .localLoopback {
                    Label(
                        "이 템플릿은 loopback 서버에만 연결합니다.",
                        systemImage: "desktopcomputer"
                    )
                    .font(.footnote)
                }
            }
        } footer: {
            Text(
                "표시된 템플릿 필드는 Rust가 검증합니다. 인증값은 일반 설정 값에 포함하지 않고 Keychain 슬롯으로만 전달합니다."
            )
        }
    }

    @ViewBuilder
    private func connectionFieldInput(
        _ field: ProviderConnectionField
    ) -> some View {
        switch field.type {
        case .text:
            TextField(
                field.label,
                text: Binding(
                    get: {
                        viewModel.connectionFieldTextValues[
                            field.key
                        ] ?? ""
                    },
                    set: {
                        viewModel.connectionFieldTextValues[
                            field.key
                        ] = $0
                    }
                )
            )
#if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#endif
            .accessibilityIdentifier(
                "provider-connection-field-\(field.key)"
            )
        case .integer:
            TextField(
                field.label,
                text: Binding(
                    get: {
                        viewModel.connectionFieldTextValues[
                            field.key
                        ] ?? ""
                    },
                    set: {
                        viewModel.connectionFieldTextValues[
                            field.key
                        ] = $0
                    }
                )
            )
#if os(iOS)
            .keyboardType(.numberPad)
#endif
            .accessibilityIdentifier(
                "provider-connection-field-\(field.key)"
            )
        case .boolean:
            Toggle(
                field.label,
                isOn: Binding(
                    get: {
                        viewModel.connectionFieldBooleanValues[
                            field.key
                        ] ?? false
                    },
                    set: {
                        viewModel.connectionFieldBooleanValues[
                            field.key
                        ] = $0
                    }
                )
            )
            .accessibilityIdentifier(
                "provider-connection-field-\(field.key)"
            )
        case .credential:
            EmptyView()
        }
        if let description = field.description {
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var websiteInput: some View {
        Section {
            TextField(
                "https://console.example.ai/api-keys",
                text: $viewModel.discoveryURL
            )
            .textContentType(.URL)
#if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
#endif
            .accessibilityIdentifier("provider-discovery-site-url")

            SecureField(
                "API 키",
                text: $viewModel.credentialDraft
            )
            .textContentType(.password)
            .privacySensitive()
            .accessibilityIdentifier("provider-discovery-credential")
        } header: {
            Text("API 키를 발급받은 사이트")
        } footer: {
            Text(
                "홈페이지, 콘솔, API 키 페이지 또는 공식 문서 주소를 입력할 수 있습니다."
            )
        }
    }

    private var curlInput: some View {
        Section {
            Picker(
                "네트워크 범위",
                selection: $viewModel.discoveryNetworkMode
            ) {
                Text("공개 인터넷")
                    .tag(ProviderNetworkMode.publicInternet)
                Text("이 기기의 loopback")
                    .tag(ProviderNetworkMode.localLoopback)
                Text("승인한 LAN 서버")
                    .tag(ProviderNetworkMode.approvedLocalNetwork)
            }
            TextEditor(text: $viewModel.curlExample)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 150)
                .privacySensitive()
                .accessibilityIdentifier("provider-discovery-curl")
            if viewModel.discoveryNetworkMode
                == .approvedLocalNetwork
            {
                TextField(
                    "cURL의 정확한 origin",
                    text: $viewModel.approvedLANOrigin
                )
                .textContentType(.URL)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
                .accessibilityIdentifier(
                    "provider-discovery-curl-lan-origin"
                )
                TextField(
                    "승인할 IP (쉼표 또는 줄바꿈, 최대 16개)",
                    text: $viewModel.approvedLANAddresses,
                    axis: .vertical
                )
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
                .lineLimit(2 ... 5)
                .accessibilityIdentifier(
                    "provider-discovery-curl-lan-addresses"
                )
                Label(
                    "Rust가 cURL에서 추출한 origin과 정확히 일치할 때만 분석합니다.",
                    systemImage: "lock.shield"
                )
                .font(.footnote)
            }
        } header: {
            Text("API 문서의 cURL 예제")
        } footer: {
            Text(
                "원문은 저장하거나 기록하지 않습니다. 인증값은 파싱 직후 일회성으로 Keychain에 이관됩니다. LAN cURL은 로컬 서버 방식에서 정확한 origin과 IP를 승인하세요."
            )
        }
    }

    private var localInput: some View {
        Section {
            Picker(
                "로컬 네트워크 범위",
                selection: $viewModel.discoveryNetworkMode
            ) {
                Text("이 기기의 loopback")
                    .tag(ProviderNetworkMode.localLoopback)
                Text("승인한 LAN 서버")
                    .tag(ProviderNetworkMode.approvedLocalNetwork)
            }
            TextField(
                "http://127.0.0.1:11434",
                text: $viewModel.discoveryURL
            )
            .textContentType(.URL)
#if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
#endif
            .accessibilityIdentifier("provider-discovery-local-url")

            if viewModel.discoveryNetworkMode
                == .approvedLocalNetwork
            {
                TextField(
                    "정확한 origin (예: http://models.lan:11434)",
                    text: $viewModel.approvedLANOrigin
                )
                .textContentType(.URL)
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
                .accessibilityIdentifier(
                    "provider-discovery-lan-origin"
                )
                TextField(
                    "승인할 IP (쉼표 또는 줄바꿈, 최대 16개)",
                    text: $viewModel.approvedLANAddresses,
                    axis: .vertical
                )
#if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
#endif
                .lineLimit(2 ... 5)
                .accessibilityIdentifier(
                    "provider-discovery-lan-addresses"
                )
                Label(
                    "이 origin과 입력한 RFC1918/ULA IP만 허용됩니다.",
                    systemImage: "lock.shield"
                )
                .font(.footnote)
            }
        } footer: {
            Text(
                "loopback과 승인된 LAN은 서로 다른 권한입니다. LAN은 정확한 origin과 실제 연결될 IP를 모두 고정합니다."
            )
        }
    }

    private func progressSection(
        _ discovery: ProviderDiscoverySnapshot
    ) -> some View {
        Section("탐색 진행") {
            ForEach(discovery.steps) { step in
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: step.state.symbolName)
                        .foregroundStyle(step.state.color)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title)
                        if let source = step.source {
                            Text(source)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(step.state.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(
                    "provider-discovery-step-\(step.id)"
                )
            }
        }
    }

    @ViewBuilder
    private func actionSection(
        _ discovery: ProviderDiscoverySnapshot
    ) -> some View {
        if let assistantAction = viewModel.assistantHostAction {
            switch assistantAction {
            case let .requestMoreEvidence(sessionID, questions)
                where sessionID == discovery.id:
                supplementalEvidenceSection(
                    questions: questions
                )
            case let .reviewDraft(review):
                assistantDraftReviewSection(review)
            default:
                EmptyView()
            }
        }

        if let boundary = discovery.assistantResumeBoundary {
            assistantResumeSection(boundary)
        }

        switch discovery.actionRequired {
        case let .assistantConsent(consent):
            let identity = viewModel.assistantRouteIdentity(
                routeID: consent.assistantModelRouteID
            )
            Section("API 문서 분석") {
                Text(
                    "자동 설정을 위해 아래 문서 일부를 ‘\(identity.map { "\($0.provider) · \($0.model)" } ?? "확인할 수 없는 모델")’에 보냅니다."
                )
                LabeledContent(
                    "프로바이더 연결",
                    value: identity?.provider ?? "연결을 찾을 수 없음"
                )
                LabeledContent(
                    "모델",
                    value: identity?.model ?? "모델을 찾을 수 없음"
                )
                LabeledContent(
                    "정확한 route ID",
                    value: consent.assistantModelRouteID
                )
                .font(.callout.monospaced())
                Text("허용된 문서 origin")
                    .font(.caption.weight(.semibold))
                ForEach(consent.documentOrigins, id: \.self) { origin in
                    Text(origin)
                        .font(.callout.monospaced())
                }
                Label(
                    "Core가 승인 제안에 포함한 redacted 문서 증거만 전송하며 API 키와 인증 헤더 값은 포함하지 않습니다.",
                    systemImage: "eye.slash"
                )
                LabeledContent(
                    "최대 호출",
                    value: "\(consent.maximumCalls)회"
                )
                LabeledContent(
                    "최대 입력",
                    value: "\(consent.maximumInputTokens) 토큰"
                )
                LabeledContent(
                    "최대 출력",
                    value: "\(consent.maximumOutputTokens) 토큰"
                )
                LabeledContent(
                    "최대 도구 호출",
                    value: "\(consent.maximumToolCalls)회"
                )
                LabeledContent(
                    "최대 재시도",
                    value: "\(consent.maximumRetries)회"
                )
                LabeledContent(
                    "최대 비용 한도",
                    value: "\(consent.maximumCostMicroUnits) micro-units"
                )
                HStack {
                    Button("건너뛰기") {
                        continueWith(.declineAssistant)
                    }
                    Spacer()
                    Button("분석 허용") {
                        continueWith(
                            .approveAssistant(
                                approvalID: consent.approvalID,
                                grantSHA256: consent.grantSHA256
                            )
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !viewModel
                            .canApproveDiscoveryAssistant(consent)
                    )
                    .accessibilityIdentifier(
                        "provider-approve-assistant"
                    )
                }
                if !viewModel
                    .canApproveDiscoveryAssistant(consent),
                    let message =
                        viewModel.assistantRouteSelectionMessage
                {
                    Label(
                        message,
                        systemImage: "lock.shield"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(
                        "provider-approve-assistant-disabled-reason"
                    )
                }
            }

        case let .credentialOrigin(approval):
            Section("API 키 전송 확인") {
                Text(
                    "LorePia가 다음 서버에 API 키를 전송하려고 합니다."
                )
                Text(approval.origin)
                    .font(.headline.monospaced())
                    .textSelection(.enabled)
                    .accessibilityIdentifier(
                        "provider-credential-origin"
                )
                LabeledContent("인증 방식", value: approval.authDescription)
                LabeledContent(
                    "Manifest",
                    value: String(
                        approval.manifestSHA256.prefix(16)
                    ) + "…"
                )
                Text(
                    "다른 서버로 redirect되면 키를 전달하지 않습니다."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                HStack {
                    Button("취소", role: .destructive) {
                        Task {
                            await viewModel.cancelDiscovery()
                        }
                    }
                    Spacer()
                    Button("이 서버에만 허용") {
                        continueWith(
                            .approveCredentialOrigin(
                                approvalID: approval.approvalID
                            )
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "provider-approve-credential-origin"
                    )
                }
            }

        case let .capabilityProbe(probe):
            Section("선택적 기능 검사") {
                Text(
                    "선택한 모델에 최대 \(probe.budget.maximumRequests)번의 작은 요청을 보내 실제 지원 기능을 확인합니다."
                )
                ForEach(probe.routeIDs, id: \.self) { routeID in
                    Label(routeID, systemImage: "cube")
                }
                Label(
                    "프로바이더 사용료가 소액 발생할 수 있습니다.",
                    systemImage: "creditcard"
                )
                .foregroundStyle(.orange)
                LabeledContent(
                    "요청당 토큰",
                    value:
                        "\(probe.budget.maximumTotalTokensPerRequest) 이하"
                )
                LabeledContent(
                    "요청당 출력",
                    value:
                        "\(probe.budget.maximumOutputTokensPerRequest) 토큰 이하"
                )
                LabeledContent(
                    "요청당 비용",
                    value:
                        "\(probe.budget.maximumCostMicroUSDPerRequest) micro-USD 이하"
                )
                LabeledContent(
                    "요청당 시간",
                    value:
                        "\(probe.budget.maximumDurationMillisecondsPerRequest) ms 이하"
                )
                LabeledContent(
                    "요청당 호출",
                    value:
                        "\(probe.budget.maximumCallsPerRequest)회 이하"
                )
                HStack {
                    Button("검사 건너뛰기") {
                        continueWith(.skipProbes)
                    }
                    Spacer()
                    Button("기능 검사 허용") {
                        continueWith(
                            .approveProbes(
                                approvalID: probe.approvalID,
                                grantSHA256: probe.grantSHA256
                            )
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(
                        "provider-approve-probes"
                    )
                }
            }

        case .review:
            EmptyView()

        case .restartInterrupted:
            Section {
                Label(
                    "중단된 네트워크 작업은 자동 재실행하지 않습니다.",
                    systemImage: "pause.circle"
                )
                Button("명시적으로 다시 시작") {
                    continueWith(.restartInterrupted)
                }
            }

        case .reconcileUnknownOutcome:
            Section {
                Label(
                    "외부 작업 결과를 확인할 수 없습니다. 자동으로 반복하지 않습니다.",
                    systemImage: "questionmark.diamond"
                )
                if let proposal =
                    discovery.unknownOutcomeProposal
                {
                    Button("검토한 결과로 조정") {
                        continueWith(
                            .resolveUnknownOutcome(
                                approvalID: proposal.approvalID,
                                resolution: proposal.resolution
                            )
                        )
                    }
                } else {
                    Button("취소", role: .destructive) {
                        Task {
                            await viewModel.cancelDiscovery()
                        }
                    }
                }
            }

        case .selectTemplate:
            Section {
                if discovery.candidates.isEmpty {
                    Text("선택할 수 있는 프로바이더 템플릿이 없습니다.")
                }
                ForEach(discovery.candidates) { candidate in
                    Button {
                        continueWith(
                            .selectTemplate(
                                candidateID: candidate.id
                            )
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title)
                            if let subtitle = candidate.subtitle {
                                Text(subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Button("템플릿 없이 계속") {
                    continueWith(.continueWithoutTemplate)
                }
            } header: {
                Text("프로바이더 후보 선택")
            }

        case .supplyMoreEvidence:
            if viewModel.assistantHostAction == nil {
                supplementalEvidenceSection(questions: [])
            }

        case nil:
            if discovery.state == .ready {
                Section {
                    Label(
                        "연결과 모델을 저장했습니다.",
                        systemImage: "checkmark.circle.fill"
                    )
                    .foregroundStyle(.green)
                    Button("완료") {
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(
                        "provider-discovery-finished"
                    )
                }
            } else if discovery.state == .compensating {
                compensationSection
            }
        }
    }

    @ViewBuilder
    private func assistantResumeSection(
        _ boundary: ProviderDiscoveryAssistantResumeBoundary
    ) -> some View {
        switch boundary.action {
        case .runAssistant:
            Section("API 문서 분석") {
                Label(
                    "승인한 한도 안에서 다음 설정 도우미 모델 호출을 실행할 준비가 됐습니다.",
                    systemImage: "sparkles"
                )
                Button("문서 분석 계속") {
                    Task {
                        await viewModel.runDiscoveryAssistant()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    "provider-run-assistant"
                )
            }

        case .waitForAssistantOutcome:
            Section("API 문서 분석") {
                Label(
                    "이전에 시작한 모델 호출 결과를 기다리고 있습니다. 결과가 불명확한 동안 자동으로 다시 호출하지 않습니다.",
                    systemImage: "pause.circle"
                )
                .accessibilityIdentifier(
                    "provider-assistant-awaiting-outcome"
                )
            }

        case .resumeCoreHostAction:
            Section("API 문서 분석") {
                Label(
                    "Core에 저장된 allowlisted 읽기 전용 도구 작업부터 재개합니다.",
                    systemImage: "arrow.clockwise.circle"
                )
                Button("Core 도구 작업 재개") {
                    Task {
                        await viewModel
                            .resumeDiscoveryAssistantCoreHostAction()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    "provider-resume-assistant-core-action"
                )
            }

        case .approveRetry:
            Section("설정 도우미 재시도") {
                Label(
                    "수정 요청은 추가 모델 호출을 사용합니다. 기존에 승인한 호출·토큰·비용 한도 안에서 한 번 더 진행할지 확인하세요.",
                    systemImage: "creditcard"
                )
                .foregroundStyle(.orange)
                Button("한도 확인 후 재시도 승인") {
                    Task {
                        await viewModel
                            .approveDiscoveryAssistantRetry()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    "provider-approve-assistant-retry"
                )
            }

        case .approveConsent,
             .supplyMoreEvidence,
             .reviewDraft,
             .restartInterrupted,
             .resolveUnknownOutcome:
            EmptyView()
        }
    }

    private func supplementalEvidenceSection(
        questions: [ProviderDiscoveryAssistantQuestion]
    ) -> some View {
        Section {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: 4) {
                    Text(question.question)
                    Text(question.requiredEvidence)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let field = question.field {
                        Text(field.displayName)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            TextField(
                "https://docs.example.ai/api",
                text: $viewModel.supplementalDocumentURL
            )
            .textContentType(.URL)
#if os(iOS)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
#endif
            .accessibilityIdentifier(
                "provider-supplemental-document-url"
            )
            Button("공식 문서 증거 추가") {
                Task {
                    await viewModel.supplyFreshDocumentEvidence()
                }
            }
            .disabled(
                viewModel.supplementalDocumentURL
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty
            )

            TextEditor(
                text: $viewModel.supplementalCurlExample
            )
            .font(.system(.caption, design: .monospaced))
            .frame(minHeight: 120)
            .privacySensitive()
            .accessibilityIdentifier(
                "provider-supplemental-curl"
            )
            Toggle(
                "cURL 키가 다르면 기존 Keychain API 키 교체",
                isOn:
                    $viewModel
                        .approvesSupplementalCredentialOverwrite
            )
            .accessibilityIdentifier(
                "provider-supplemental-curl-overwrite"
            )
            Button("cURL 증거 안전하게 추가") {
                Task {
                    await viewModel.supplyFreshCurlEvidence()
                }
            }
            .disabled(
                viewModel.supplementalCurlExample
                    .trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                    .isEmpty
            )

            Button("설정 도우미로 문서 분석") {
                Task {
                    await viewModel.requestDiscoveryAssistant()
                }
            }
            .disabled(!viewModel.canRequestDiscoveryAssistant)
            .accessibilityIdentifier(
                "provider-request-discovery-assistant"
            )

            if !viewModel.canRequestDiscoveryAssistant,
               let message =
                   viewModel.assistantRouteSelectionMessage
            {
                Label(
                    message,
                    systemImage: "lock.shield"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
                .accessibilityIdentifier(
                    "provider-request-assistant-disabled-reason"
                )
            }
        } header: {
            Text("추가 증거")
        } footer: {
            Text(
                "cURL 원문은 먼저 한 번 검사합니다. 인증값은 정확한 pending Keychain 슬롯으로만 이관하고, Core에는 재파싱 가능한 redacted cURL만 보냅니다."
            )
        }
    }

    private func assistantDraftReviewSection(
        _ review: ProviderDiscoveryAssistantDraftReview
    ) -> some View {
        Section {
            Text(review.draft.summary)
            LabeledContent(
                "API 형식",
                value: review.draft.manifest.apiFamily.rawValue
            )
            LabeledContent(
                "생성 endpoint",
                value:
                    "\(review.draft.manifest.generateEndpoint.method.rawValue) \(review.draft.manifest.generateEndpoint.path)"
            )
            if !review.unresolvedConflicts.isEmpty {
                Label(
                    "해결되지 않은 충돌 \(review.unresolvedConflicts.count)개",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
            }
            if !review.draft.unresolvedQuestions.isEmpty {
                Label(
                    "추가 확인 \(review.draft.unresolvedQuestions.count)개",
                    systemImage: "questionmark.circle"
                )
                .foregroundStyle(.orange)
            }
            ForEach(
                Array(review.draft.confidence.enumerated()),
                id: \.offset
            ) { _, confidence in
                LabeledContent(
                    confidence.field.displayName,
                    value: confidence.level.rawValue
                )
            }
            HStack {
                Button("수정 요청") {
                    Task {
                        await viewModel
                            .requestDiscoveryAssistantRevision()
                    }
                }
                Spacer()
                Button("초안 채택") {
                    Task {
                        await viewModel
                            .acceptDiscoveryAssistantDraft()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !review.unresolvedConflicts.isEmpty
                        || !review.draft.unresolvedQuestions.isEmpty
                )
                .accessibilityIdentifier(
                    "provider-accept-assistant-draft"
                )
            }
        } header: {
            Text("설정 도우미 초안 검토")
        } footer: {
            Text(
                "이 초안은 아직 저장되지 않았습니다. Core의 manifest, URL, 자격증명 origin 검증을 모두 통과해야 연결 후보가 됩니다."
            )
        }
    }

    private var compensationSection: some View {
        Section {
            Label(
                "부분 저장 결과를 역순으로 정리하고 있습니다.",
                systemImage: "arrow.uturn.backward.circle"
            )
            ForEach(viewModel.compensationSteps) { step in
                LabeledContent(
                    step.kind.displayName,
                    value: step.status.displayName
                )
            }
            Button("안전한 정리 재개") {
                Task {
                    await viewModel.resumeDiscoveryCompensation()
                }
            }
            .accessibilityIdentifier(
                "provider-resume-compensation"
            )
        } header: {
            Text("저장 실패 정리")
        } footer: {
            Text(
                "앱은 Core가 지정한 정확한 Keychain 슬롯만 지웁니다. 연결 graph와 기본 모델 복원은 Rust Core가 처리합니다."
            )
        }
    }

    @ViewBuilder
    private func reviewSection(
        _ discovery: ProviderDiscoverySnapshot
    ) -> some View {
        if let review = discovery.review,
           discovery.state == .awaitingReview
        {
            Section("연결 준비 완료") {
                ForEach(review.changes) { change in
                    HStack(alignment: .top) {
                        Text(change.kind.symbol)
                            .font(.headline.monospaced())
                            .foregroundStyle(change.kind.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.title)
                            if let detail = change.detail {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if review.warningCount > 0 {
                    Label(
                        "경고 \(review.warningCount)개 · 미확인 \(review.unresolvedQuestionCount)개",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }

            if let preview = review.requestPreview {
                ProviderRequestPreviewSection(preview: preview)
            }

            Section {
                Button("연결 저장") {
                    Task {
                        await viewModel.commitDiscovery()
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("provider-discovery-commit")
            } footer: {
                Text(
                    "표시된 검토 내용의 해시가 달라지면 적용이 거부됩니다."
                )
            }
        }
    }

    @ViewBuilder
    private var messageSection: some View {
        if let error = viewModel.errorMessage {
            Section {
                Label(
                    error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .accessibilityIdentifier(
                    "provider-discovery-error-message"
                )
            }
        }
        if let status = viewModel.statusMessage {
            Section {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func continueWith(_ action: ProviderDiscoveryAction) {
        Task {
            await viewModel.continueDiscovery(action)
        }
    }
}

private struct ProviderConnectionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: ProviderSetupViewModel
    let connection: ProviderConnectionRecord
    @State private var confirmsDeletion = false

    var body: some View {
        List {
            Section("연결") {
                LabeledContent("이름", value: connection.displayName)
                LabeledContent("API 서버", value: connection.apiOrigin)
                LabeledContent(
                    "인증 정보 전송 대상",
                    value: connection.approvedCredentialOrigins
                        .joined(separator: ", ")
                )
                LabeledContent(
                    "API 키",
                    value: connection.hasCredential ? "Keychain 저장됨" : "없음"
                )
                LabeledContent("네트워크 모드", value: connection.networkMode)
                if let approval = connection.localNetworkApproval {
                    LabeledContent(
                        "승인된 LAN origin",
                        value: approval.origin
                    )
                    LabeledContent(
                        "승인된 LAN IP",
                        value: approval.addresses.joined(
                            separator: ", "
                        )
                    )
                }
                LabeledContent(
                    "제한 시간",
                    value: "\(connection.timeoutSeconds)초"
                )
            }

            modelSyncSection

            Section("모델 경로") {
                if viewModel.modelRoutes.isEmpty {
                    Text("저장된 모델 경로가 없습니다.")
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.modelRoutes) { route in
                    NavigationLink {
                        ProviderModelRouteDetailView(
                            viewModel: viewModel,
                            route: route
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(route.title)
                            HStack {
                                Text(route.modelID)
                                Spacer()
                                Text(route.availability.displayName)
                            }
                            .font(.caption)
                            .foregroundStyle(
                                route.availability == .available
                                    ? Color.secondary
                                    : Color.orange
                            )
                        }
                    }
                    .accessibilityIdentifier(
                        "provider-model-route-\(route.id)"
                    )
                }
            }

            Section {
                Button(
                    "연결 삭제",
                    role: .destructive
                ) {
                    confirmsDeletion = true
                }
                .accessibilityIdentifier("provider-delete-connection")
            } footer: {
                Text(
                    "삭제 전 Keychain API 키를 지우고, Core 삭제가 실패하면 키를 복구합니다."
                )
            }
        }
        .navigationTitle(connection.displayName)
        .settingsDetailTitleDisplayMode()
        .task(id: connection.id) {
            await viewModel.selectConnection(id: connection.id)
        }
        .confirmationDialog(
            "‘\(connection.displayName)’ 연결을 삭제할까요?",
            isPresented: $confirmsDeletion
        ) {
            Button("연결 삭제", role: .destructive) {
                Task {
                    await viewModel.deleteSelectedConnection()
                    if !viewModel.connections.contains(where: {
                        $0.id == connection.id
                    }) {
                        dismiss()
                    }
                }
            }
            .accessibilityIdentifier(
                "provider-confirm-delete-connection"
            )
            Button("취소", role: .cancel) {}
        } message: {
            Text("기존 대화 기록은 유지되지만 이 연결로 새 응답을 만들 수 없습니다.")
        }
    }

    @ViewBuilder
    private var modelSyncSection: some View {
        Section("모델 및 기능 새로고침") {
            Button {
                Task {
                    await viewModel.startModelSync()
                }
            } label: {
                Label(
                    "모델 및 기능 새로고침",
                    systemImage: "arrow.clockwise"
                )
            }
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier("provider-model-sync-start")

            if let job = viewModel.modelSyncJob,
               job.connectionID == connection.id
            {
                ProgressView(
                    value: Double(job.completedSteps),
                    total: Double(max(job.totalSteps, 1))
                ) {
                    Text(job.state.displayName)
                }
                if let messageKey =
                    viewModel.modelSyncEventMessageKey
                {
                    Text(messageKey)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                if !job.state.isTerminal {
                    Button {
                        Task {
                            await viewModel
                                .refreshModelSyncEvents()
                        }
                    } label: {
                        Label(
                            "진행 이벤트 확인",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(viewModel.isBusy)
                    .accessibilityIdentifier(
                        "provider-model-sync-poll-events"
                    )
                }
                if let diff = job.diff {
                    ProviderModelSyncDiffView(diff: diff)
                }
                if job.state == .awaitingReview {
                    HStack {
                        Button("취소", role: .cancel) {
                            Task {
                                await viewModel.cancelModelSync()
                            }
                        }
                        Spacer()
                        Button("검토한 변경 적용") {
                            Task {
                                await viewModel.approveModelSync()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(
                            "provider-model-sync-approve"
                        )
                    }
                }
            }
        }
    }
}

private struct ProviderModelSyncDiffView: View {
    let diff: ProviderModelSyncDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(diff.newRoutes) { route in
                Label(
                    "새 모델: \(route.title)",
                    systemImage: "plus.circle"
                )
                .foregroundStyle(.green)
            }
            if !diff.changedRouteIDs.isEmpty {
                Label(
                    "변경된 모델 \(diff.changedRouteIDs.count)개",
                    systemImage: "arrow.triangle.2.circlepath"
                )
            }
            if !diff.missingRouteIDs.isEmpty {
                Label(
                    "이번 조회에서 보이지 않음 \(diff.missingRouteIDs.count)개",
                    systemImage: "exclamationmark.circle"
                )
                .foregroundStyle(.orange)
                Text(
                    "누락된 모델과 기존 프리셋·대화 참조는 삭제하지 않습니다."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            if diff.capabilityChangeCount > 0 {
                Label(
                    "기능 근거 변경 \(diff.capabilityChangeCount)개",
                    systemImage: "checkmark.seal"
                )
            }
        }
        .font(.callout)
    }
}

private struct ProviderModelRouteDetailView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    let route: ProviderModelRoute
    @State private var showsAdvancedParameters = false
    @State private var confirmsPresetDeletion = false

    var body: some View {
        Form {
            Section("모델 경로") {
                LabeledContent("모델", value: route.modelID)
                LabeledContent("API family", value: route.apiFamily)
                if let deploymentID = route.deploymentID {
                    LabeledContent("Deployment", value: deploymentID)
                }
                if let region = route.region {
                    LabeledContent("Region", value: region)
                }
                LabeledContent(
                    "상태",
                    value: route.availability.displayName
                )
                if let source = route.metadataSource {
                    LabeledContent(
                        "모델 목록 출처",
                        value: source.displayName
                    )
                    .accessibilityIdentifier(
                        "provider-model-route-source-\(route.id)"
                    )
                }
                if let observedAt = route.metadataObservedAt {
                    LabeledContent(
                        "출처 확인 시각",
                        value: observedAt
                    )
                }
                if route.missCount > 0 {
                    LabeledContent(
                        "연속 누락",
                        value: "\(route.missCount)회"
                    )
                }
            }

            capabilitySection
            presetSection
            parameterSection
            reasoningAndCacheSection

            if let preview = viewModel.currentRequestPreview {
                ProviderRequestPreviewSection(preview: preview)
            }

            if let error = viewModel.errorMessage {
                Section {
                    Label(
                        error,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle(route.title)
        .settingsDetailTitleDisplayMode()
        .task(id: route.id) {
            await viewModel.selectModelRoute(id: route.id)
        }
        .onChange(of: presetControlRefreshToken) { _, _ in
            Task {
                await viewModel.refreshPresetControls()
            }
        }
        .confirmationDialog(
            "선택한 프리셋을 삭제할까요?",
            isPresented: $confirmsPresetDeletion
        ) {
            Button("프리셋 삭제", role: .destructive) {
                Task {
                    await viewModel.deleteSelectedPreset()
                }
            }
            Button("취소", role: .cancel) {}
        }
    }

    private var presetControlRefreshToken: String {
        [
            viewModel.presetName,
            viewModel.reasoningMode,
            viewModel.reasoningEffort,
            viewModel.reasoningBudgetTokens,
            viewModel.reasoningSummary,
            viewModel.preservesOpaqueReasoningState ? "1" : "0",
            viewModel.promptCacheMode,
            viewModel.promptCacheTTL,
            viewModel.promptCacheCustomTTLSeconds,
            viewModel.promptCacheContextReference,
        ].joined(separator: "\u{001F}")
    }

    private var capabilitySection: some View {
        Section("기능과 근거") {
            if viewModel.capabilities.isEmpty {
                Text("확인된 기능 근거가 없습니다.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.capabilities) { capability in
                DisclosureGroup {
                    LabeledContent(
                        "출처",
                        value: capability.selected.source.displayName
                    )
                    LabeledContent(
                        "신뢰도",
                        value: capability.selected.confidence
                    )
                    LabeledContent(
                        "마지막 확인",
                        value: capability.selected.observedAt
                    )
                    if let expiresAt = capability.selected.expiresAt {
                        LabeledContent("만료", value: expiresAt)
                    }
                    if let evidence =
                        capability.selected.evidenceReference
                    {
                        Text(evidence)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .privacySensitive()
                    }
                    if capability.hasConflict {
                        Label(
                            "서로 다른 근거가 충돌합니다.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.orange)
                    }
                } label: {
                    HStack {
                        Text(capability.selected.key.displayCapabilityName)
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(capability.selected.value.displayValue)
                            Text(
                                capability.isStale
                                    ? "오래된 근거"
                                    : capability.selected.source.displayName
                            )
                            .font(.caption2)
                            .foregroundStyle(
                                capability.isStale
                                    ? Color.orange
                                    : Color.secondary
                            )
                        }
                    }
                }
                .accessibilityIdentifier(
                    "provider-capability-\(capability.id)"
                )
            }
        }
    }

    private var presetSection: some View {
        Section("생성 프리셋") {
            if !viewModel.presets.isEmpty {
                Picker(
                    "프리셋",
                    selection: Binding(
                        get: { viewModel.selectedPresetID ?? "" },
                        set: { id in
                            Task {
                                await viewModel.selectPreset(id: id)
                            }
                        }
                    )
                ) {
                    ForEach(viewModel.presets) { preset in
                        Text(preset.displayName).tag(preset.id)
                    }
                }
                .accessibilityIdentifier("provider-preset-picker")
            }
            TextField("프리셋 이름", text: $viewModel.presetName)
                .accessibilityIdentifier("provider-preset-name")
            Text(viewModel.selectedPresetParameterSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("새 프리셋") {
                    viewModel.beginNewPreset()
                }
                Spacer()
                if viewModel.selectedPreset != nil {
                    if viewModel.selectedPresetCanBeDeleted {
                        Button("삭제", role: .destructive) {
                            confirmsPresetDeletion = true
                        }
                    } else {
                        Text(
                            "마이그레이션된 기본 프리셋은 연결과 함께 관리됩니다."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("저장") {
                    Task {
                        await viewModel.savePreset()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("provider-preset-save")
            }
            Button {
                Task {
                    await viewModel.previewEditedPreset()
                }
            } label: {
                Label(
                    "현재 편집 값 검증 및 요청 미리보기",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .disabled(viewModel.isBusy)
            .accessibilityIdentifier(
                "provider-preset-preview-candidate"
            )
            if viewModel.requestPreview != nil,
               viewModel.currentRequestPreview == nil
            {
                Text(
                    "편집 값이 바뀌어 이전 미리보기를 숨겼습니다. 현재 값으로 다시 검증하세요."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if viewModel.selectedPreset != nil {
                Button {
                    Task {
                        await viewModel.useSelectedPresetAsAppDefault()
                    }
                } label: {
                    Label(
                        viewModel.selectedPresetIsAppDefault
                            ? "앱 기본 모델로 사용 중"
                            : "앱 기본 모델로 사용",
                        systemImage: viewModel.selectedPresetIsAppDefault
                            ? "checkmark.circle.fill"
                            : "circle"
                    )
                }
                .disabled(
                    viewModel.isBusy
                        || viewModel.selectedPresetIsAppDefault
                )
                .accessibilityIdentifier(
                    "provider-preset-use-as-default"
                )
            }
        }
    }

    @ViewBuilder
    private var parameterSection: some View {
        let basic = viewModel.visibleParameterSpecs.filter {
            $0.level == .basic
        }
        let advanced = viewModel.visibleParameterSpecs.filter {
            $0.level == .advanced || $0.level == .expert
        }
        if !basic.isEmpty {
            Section("모델 옵션") {
                ForEach(basic) { spec in
                    ProviderParameterEditor(
                        viewModel: viewModel,
                        spec: spec
                    )
                }
            }
        }
        if !advanced.isEmpty {
            Section {
                DisclosureGroup(
                    "고급 옵션",
                    isExpanded: $showsAdvancedParameters
                ) {
                    ForEach(advanced) { spec in
                        ProviderParameterEditor(
                            viewModel: viewModel,
                            spec: spec
                        )
                    }
                }
            } footer: {
                Text(
                    "건드리지 않은 값은 요청에서 생략해 프로바이더 기본값을 보존합니다."
                )
            }
        }
        if !viewModel.parameterConflictMessages.isEmpty {
            Section("옵션 조합 확인") {
                ForEach(
                    viewModel.parameterConflictMessages,
                    id: \.self
                ) { message in
                    Label(
                        message,
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private var reasoningAndCacheSection: some View {
        let reasoning = viewModel.currentReasoningControl
        let cache = viewModel.currentPromptCacheControl
        let reasoningVisible = reasoning.map {
            $0.state != .hidden
        } ?? false
        let cacheVisible = cache.map {
            $0.state != .hidden
        } ?? false

        if reasoningVisible || cacheVisible {
            Section("추론과 프로바이더 프롬프트 캐시") {
                if let reasoning, reasoning.state != .hidden {
                    Picker(
                        "추론",
                        selection: Binding(
                            get: {
                                viewModel.reasoningMode
                            },
                            set: {
                                viewModel.setReasoningMode($0)
                            }
                        )
                    ) {
                        ForEach(
                            reasoning.allowedModes,
                            id: \.self
                        ) { mode in
                            Text(reasoningModeLabel(mode)).tag(mode)
                        }
                    }
                    .accessibilityIdentifier(
                        "provider-reasoning-mode"
                    )

                    if reasoning.effortField.isVisible {
                        Picker(
                            "추론 강도",
                            selection: $viewModel.reasoningEffort
                        ) {
                            if reasoning.effortField != .required {
                                Text("설정 안 함").tag("")
                            }
                            ForEach(
                                reasoning.allowedEfforts,
                                id: \.self
                            ) { effort in
                                Text(reasoningEffortLabel(effort))
                                    .tag(effort)
                            }
                        }
                        .accessibilityIdentifier(
                            "provider-reasoning-effort"
                        )
                    }

                    if reasoning.budgetField.isVisible {
                        TextField(
                            reasoningBudgetLabel(reasoning),
                            text: $viewModel.reasoningBudgetTokens
                        )
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                        .accessibilityIdentifier(
                            "provider-reasoning-budget"
                        )
                    }

                    if reasoning.summaryField.isVisible {
                        Picker(
                            "추론 요약",
                            selection: $viewModel.reasoningSummary
                        ) {
                            ForEach(
                                reasoning.allowedSummaries,
                                id: \.self
                            ) { summary in
                                Text(reasoningSummaryLabel(summary))
                                    .tag(summary)
                            }
                        }
                        .accessibilityIdentifier(
                            "provider-reasoning-summary"
                        )
                    }

                    if viewModel.canEditOpaqueReasoningContinuity {
                        Toggle(
                            "같은 모델의 비공개 추론 상태 이어쓰기",
                            isOn:
                                $viewModel
                                .preservesOpaqueReasoningState
                        )
                        .accessibilityIdentifier(
                            "provider-opaque-reasoning-continuity-toggle"
                        )
                    } else {
                        Text(
                            "이 연결에서는 비공개 추론 상태 이어쓰기를 사용할 수 없습니다."
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(
                            "provider-opaque-reasoning-continuity-unavailable"
                        )
                    }

                    ForEach(reasoning.issues) { issue in
                        providerControlIssue(issue)
                    }
                }

                if let cache, cache.state != .hidden {
                    Picker(
                        "프롬프트 캐시",
                        selection: $viewModel.promptCacheMode
                    ) {
                        ForEach(
                            cache.allowedModes,
                            id: \.self
                        ) { mode in
                            Text(promptCacheModeLabel(mode)).tag(mode)
                        }
                    }
                    .accessibilityIdentifier(
                        "provider-prompt-cache-mode"
                    )

                    if cache.ttlField.isVisible {
                        if viewModel.promptCacheTTL
                            != "custom_seconds"
                        {
                            Picker(
                                "캐시 유지 시간",
                                selection: $viewModel.promptCacheTTL
                            ) {
                                ForEach(
                                    cache.allowedTTLs,
                                    id: \.self
                                ) { ttl in
                                    Text(promptCacheTTLLabel(ttl))
                                        .tag(ttl)
                                }
                            }
                            .accessibilityIdentifier(
                                "provider-prompt-cache-ttl"
                            )
                        }

                        if cache.supportsCustomTTL {
                            Toggle(
                                "초 단위 유지 시간 직접 입력",
                                isOn: customTTLBinding(cache)
                            )
                            .accessibilityIdentifier(
                                "provider-prompt-cache-custom-ttl-enabled"
                            )
                        }

                        if cache.supportsCustomTTL,
                           viewModel.promptCacheTTL == "custom_seconds"
                        {
                            TextField(
                                promptCacheCustomTTLLabel(cache),
                                text:
                                    $viewModel
                                    .promptCacheCustomTTLSeconds
                            )
#if os(iOS)
                            .keyboardType(.numberPad)
#endif
                            .accessibilityIdentifier(
                                "provider-prompt-cache-custom-ttl"
                            )
                        }
                    }

                    if cache.contextReferenceField.isVisible {
                        TextField(
                            cache.contextReferenceField == .required
                                ? "컨텍스트 캐시 참조 (필수)"
                                : "컨텍스트 캐시 참조",
                            text:
                                $viewModel
                                .promptCacheContextReference
                        )
#if os(iOS)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
#endif
                        .accessibilityIdentifier(
                            "provider-prompt-cache-context"
                        )
                    }

                    ForEach(cache.issues) { issue in
                        providerControlIssue(issue)
                    }
                }

                Text(
                    "표시 가능한 모드와 범위는 Rust Core가 현재 모델 경로와 프리셋에서 계산합니다. 비공개 추론 상태는 미리보기, 로그와 오류 메시지에 표시되지 않습니다."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        } else if reasoning == nil || cache == nil {
            Section("추론과 프로바이더 프롬프트 캐시") {
                Button {
                    Task {
                        await viewModel.refreshPresetControls(
                            reportingFailure: true
                        )
                    }
                } label: {
                    Label(
                        "모델별 제어 다시 불러오기",
                        systemImage: "arrow.clockwise"
                    )
                }
                .disabled(viewModel.isBusy)
                Text(
                    "지원 여부를 추측하지 않고 Rust Core의 렌더링 결과가 있을 때만 제어를 표시합니다."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func providerControlIssue(
        _ issue: ProviderParameterIssue
    ) -> some View {
        Label(
            issue.message,
            systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange)
        .accessibilityIdentifier(
            "provider-control-issue-\(issue.code)"
        )
    }

    private func reasoningModeLabel(_ value: String) -> String {
        switch value {
        case "provider_default": "프로바이더 기본값"
        case "disabled": "끄기"
        case "automatic": "자동"
        case "enabled": "켜기"
        default: value
        }
    }

    private func reasoningEffortLabel(_ value: String) -> String {
        switch value {
        case "minimal": "최소"
        case "low": "낮음"
        case "medium": "중간"
        case "high": "높음"
        case "extra_high": "매우 높음"
        case "maximum": "최대"
        default: value
        }
    }

    private func reasoningSummaryLabel(_ value: String) -> String {
        switch value {
        case "provider_default": "프로바이더 기본값"
        case "disabled": "사용 안 함"
        case "automatic": "자동"
        case "concise": "간결하게"
        case "detailed": "자세하게"
        default: value
        }
    }

    private func promptCacheModeLabel(_ value: String) -> String {
        switch value {
        case "provider_default": "프로바이더 기본값"
        case "automatic": "자동"
        case "explicit_breakpoints": "명시적 중단점"
        case "explicit_context": "명시적 컨텍스트"
        case "disabled_if_supported": "지원되면 사용 안 함"
        default: value
        }
    }

    private func promptCacheTTLLabel(_ value: String) -> String {
        switch value {
        case "provider_default": "프로바이더 기본값"
        case "short": "짧게"
        case "long": "길게"
        case "custom_seconds": "직접 입력"
        default: value
        }
    }

    private func reasoningBudgetLabel(
        _ control: ProviderReasoningControl
    ) -> String {
        guard let minimum = control.minimumBudgetTokens,
              let maximum = control.maximumBudgetTokens
        else {
            return control.budgetField == .required
                ? "추론 토큰 예산 (필수)"
                : "추론 토큰 예산"
        }
        return "추론 토큰 예산 (\(minimum)–\(maximum))"
    }

    private func promptCacheCustomTTLLabel(
        _ control: ProviderPromptCacheControl
    ) -> String {
        guard let minimum = control.minimumCustomTTLSeconds,
              let maximum = control.maximumCustomTTLSeconds
        else {
            return "캐시 유지 시간 (초)"
        }
        return "캐시 유지 시간 (\(minimum)–\(maximum)초)"
    }

    private func customTTLBinding(
        _ control: ProviderPromptCacheControl
    ) -> Binding<Bool> {
        Binding(
            get: {
                viewModel.promptCacheTTL == "custom_seconds"
            },
            set: { usesCustom in
                if usesCustom {
                    viewModel.promptCacheTTL = "custom_seconds"
                } else {
                    viewModel.promptCacheTTL =
                        control.allowedTTLs.first
                        ?? "provider_default"
                    viewModel.promptCacheCustomTTLSeconds = ""
                }
            }
        )
    }
}

private struct ProviderParameterEditor: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    let spec: ProviderParameterSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "프로바이더 기본값 사용",
                isOn: Binding(
                    get: { usesProviderDefault },
                    set: {
                        viewModel.setParameterUsesProviderDefault(
                            id: spec.id,
                            usesDefault: $0
                        )
                    }
                )
            )
            .accessibilityIdentifier(
                "provider-parameter-default-\(spec.id)"
            )
            if !usesProviderDefault {
                explicitControl
            }
            if let description = spec.description {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var explicitControl: some View {
        switch spec.type {
        case .boolean:
            Toggle(
                spec.label,
                isOn: Binding(
                    get: {
                        if case let .explicit(.boolean(value)) =
                            viewModel.parameterValues[spec.id]
                        {
                            return value
                        }
                        return false
                    },
                    set: {
                        viewModel.setParameterLiteral(
                            id: spec.id,
                            literal: .boolean($0)
                        )
                    }
                )
            )
        case .enumeration, .toolPolicy:
            Picker(
                spec.label,
                selection: stringBinding
            ) {
                ForEach(spec.choices) { choice in
                    Text(choice.label)
                        .tag(choice.value.displayValue)
                }
            }
        case .integer:
            TextField(spec.label, text: integerBinding)
#if os(iOS)
                .keyboardType(.numbersAndPunctuation)
#endif
        case .number:
            TextField(spec.label, text: numberBinding)
#if os(iOS)
                .keyboardType(.decimalPad)
#endif
        case .string, .jsonSchema:
            TextField(spec.label, text: stringBinding, axis: .vertical)
        case .stringList, .stopSequenceList:
            TextField(
                "\(spec.label) (쉼표로 구분)",
                text: listBinding
            )
        }
    }

    private var usesProviderDefault: Bool {
        if case .providerDefault = viewModel.parameterValues[spec.id] {
            return true
        }
        return false
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                guard case let .explicit(value) =
                    viewModel.parameterValues[spec.id]
                else {
                    return ""
                }
                return value.displayValue
            },
            set: { value in
                let literal: ProviderParameterLiteral =
                    spec.type == .toolPolicy
                    ? .toolPolicy(value)
                    : (
                        spec.type == .enumeration
                            ? .enumeration(value)
                            : (
                                spec.type == .jsonSchema
                                    ? .jsonSchema(value)
                                    : .string(value)
                            )
                    )
                viewModel.setParameterLiteral(
                    id: spec.id,
                    literal: literal
                )
            }
        )
    }

    private var integerBinding: Binding<String> {
        Binding(
            get: {
                if case let .explicit(.integer(value)) =
                    viewModel.parameterValues[spec.id]
                {
                    return String(value)
                }
                return ""
            },
            set: { value in
                guard let parsed = Int64(value) else {
                    return
                }
                viewModel.setParameterLiteral(
                    id: spec.id,
                    literal: .integer(parsed)
                )
            }
        )
    }

    private var numberBinding: Binding<String> {
        Binding(
            get: {
                if case let .explicit(.number(value)) =
                    viewModel.parameterValues[spec.id]
                {
                    return String(value)
                }
                return ""
            },
            set: { value in
                guard let parsed = Double(value) else {
                    return
                }
                viewModel.setParameterLiteral(
                    id: spec.id,
                    literal: .number(parsed)
                )
            }
        )
    }

    private var listBinding: Binding<String> {
        Binding(
            get: {
                guard case let .explicit(literal) =
                    viewModel.parameterValues[spec.id]
                else {
                    return ""
                }
                switch literal {
                case let .stringList(values),
                     let .stopSequenceList(values):
                    return values.joined(separator: ", ")
                default:
                    return ""
                }
            },
            set: { value in
                let values = value.split(separator: ",").map {
                    $0.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                }.filter { !$0.isEmpty }
                viewModel.setParameterLiteral(
                    id: spec.id,
                    literal: spec.type == .stopSequenceList
                        ? .stopSequenceList(values)
                        : .stringList(values)
                )
            }
        )
    }
}

private struct ProviderRequestPreviewSection: View {
    let preview: ProviderRequestPreview

    var body: some View {
        Section("안전한 요청 미리보기") {
            LabeledContent(
                "Redaction schema",
                value: "v\(preview.redactionVersion)"
            )
            LabeledContent("Method", value: preview.method)
            LabeledContent("Origin", value: preview.origin)
            LabeledContent("Path", value: preview.path)
            if !preview.headerNames.isEmpty {
                LabeledContent(
                    "Header 이름",
                    value: preview.headerNames.joined(separator: ", ")
                )
            }
            if !preview.queryParameterNames.isEmpty {
                LabeledContent(
                    "Query 이름",
                    value: preview.queryParameterNames.joined(separator: ", ")
                )
            }
            if preview.isScalarFree {
                if let bodyShapeJSON = preview.bodyShapeJSON {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("값이 제거된 Body 구조")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(bodyShapeJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
                ForEach(preview.redactions, id: \.self) { redaction in
                    Label(
                        "\(redaction) 제외",
                        systemImage: "eye.slash"
                    )
                    .foregroundStyle(.secondary)
                }
            } else {
                Label(
                    "민감한 scalar 값이 포함된 미리보기는 표시하지 않습니다.",
                    systemImage: "exclamationmark.shield.fill"
                )
                .foregroundStyle(.red)
            }
            if preview.bodyTruncated {
                Label(
                    "구조 크기 제한으로 Body 일부를 생략했습니다.",
                    systemImage: "ellipsis.circle"
                )
                .foregroundStyle(.orange)
            }
        }
        .privacySensitive()
        .accessibilityIdentifier("provider-request-preview")
    }
}

private struct ProviderCatalogView: View {
    @ObservedObject var viewModel: ProviderSetupViewModel
    @State private var showsCatalogImporter = false
    @State private var confirmsCatalogActivation = false
    @State private var confirmsCatalogRollback = false

    var body: some View {
        List {
            Section {
                Button {
                    showsCatalogImporter = true
                } label: {
                    Label(
                        "서명 카탈로그 파일 선택",
                        systemImage: "doc.badge.plus"
                    )
                }
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier(
                    "provider-catalog-import-select"
                )
            } footer: {
                Text(
                    "파일 선택은 서명과 변경 검토만 준비합니다. 아래에서 명시적으로 승인하기 전에는 활성 revision이 바뀌지 않습니다."
                )
            }

            if let plan = viewModel.pendingCatalogImport {
                catalogImportReview(plan)
            }
            if let plan = viewModel.pendingCatalogRollback {
                catalogRollbackReview(plan)
            }

            if let catalog = viewModel.catalogStatus {
                Section("현재 카탈로그") {
                    LabeledContent(
                        "Schema",
                        value: "v\(catalog.schemaVersion)"
                    )
                    LabeledContent(
                        "Revision",
                        value: catalog.currentRevision.map(String.init)
                            ?? "없음"
                    )
                    LabeledContent("Source", value: catalog.currentSource)
                    if let signer = catalog.verifiedSigner {
                        LabeledContent("검증된 서명자", value: signer)
                    }
                    if let updatedAt = catalog.updatedAt {
                        LabeledContent("활성화", value: updatedAt)
                    }
                }

                Section("활성화 기록") {
                    ForEach(catalog.history) { activation in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("r\(activation.revision)")
                                    .font(.headline)
                                if activation.isCurrent {
                                    Text("현재")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                                Spacer()
                                Text(activation.source)
                                    .foregroundStyle(.secondary)
                            }
                            Text(activation.summary)
                            if let signer = activation.signer {
                                Text(
                                    "\(signer) · \(activation.activatedAt)"
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            } else {
                                Text(activation.activatedAt)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !activation.isCurrent {
                                Button("이 버전으로 롤백") {
                                    Task {
                                        await viewModel
                                            .prepareCatalogRollback(
                                                to:
                                                    activation
                                                        .revision
                                            )
                                    }
                                }
                                .accessibilityIdentifier(
                                    "provider-catalog-rollback-\(activation.id)"
                                )
                            }
                        }
                        .padding(.vertical, 3)
                    }
                }
            } else {
                ContentUnavailableView(
                    "카탈로그 상태를 확인할 수 없음",
                    systemImage: "checkmark.seal"
                )
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Label(
                        errorMessage,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                }
            } else if let statusMessage = viewModel.statusMessage {
                Section {
                    Label(
                        statusMessage,
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("서명 카탈로그")
        .settingsDetailTitleDisplayMode()
        .fileImporter(
            isPresented: $showsCatalogImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result,
                  let selectedURL = urls.first
            else {
                return
            }
            Task {
                await viewModel.prepareSignedCatalogImport(
                    from: selectedURL
                )
            }
        }
        .confirmationDialog(
            "검토한 서명 카탈로그를 활성화할까요?",
            isPresented: $confirmsCatalogActivation,
            presenting: viewModel.pendingCatalogImport
        ) { plan in
            Button(
                "r\(plan.review.candidateRevision) 활성화"
            ) {
                Task {
                    await viewModel.activatePreparedCatalogImport()
                }
            }
            Button("취소", role: .cancel) {}
        } message: { plan in
            Text(
                "서명자 \(plan.review.signingKeyID), r\(plan.review.expectedActiveRevision) → r\(plan.review.candidateRevision) 변경만 적용합니다. 검토 후 상태나 파일이 바뀌면 Core가 거부합니다."
            )
        }
        .confirmationDialog(
            "검토한 카탈로그 롤백을 활성화할까요?",
            isPresented: $confirmsCatalogRollback,
            presenting: viewModel.pendingCatalogRollback
        ) { plan in
            Button("r\(plan.toRevision)로 롤백", role: .destructive) {
                Task {
                    await viewModel
                        .activatePreparedCatalogRollback()
                }
            }
            Button("취소", role: .cancel) {}
        } message: { plan in
            Text(
                "검토한 r\(plan.fromRevision) → r\(plan.toRevision) 변경만 적용합니다. 준비 후 상태가 바뀌면 Core가 CAS 검증으로 거부합니다."
            )
        }
    }

    private func catalogRollbackReview(
        _ plan: ProviderCatalogRollbackPlan
    ) -> some View {
        Section("롤백 활성화 전 변경 검토") {
            LabeledContent(
                "Revision",
                value: "r\(plan.fromRevision) → r\(plan.toRevision)"
            )
            LabeledContent(
                "상태 기준",
                value: String(plan.expectedStateVersion)
            )
            LabeledContent(
                "Plan",
                value:
                    String(plan.planSHA256.prefix(16)) + "…"
            )
            LabeledContent("검토 만료", value: plan.expiresAt)
            Label(
                "활성 revision은 아직 r\(plan.fromRevision)입니다.",
                systemImage: "pause.circle"
            )
            .foregroundStyle(.secondary)
            LabeledContent(
                "프로바이더 템플릿 변경",
                value: String(plan.diff.manifestChanges.count)
            )
            LabeledContent(
                "모델 메타데이터 변경",
                value: String(plan.diff.modelChanges.count)
            )
            ForEach(plan.diff.manifestChanges) { change in
                Label(
                    "\(change.providerTemplateID) · \(catalogChangeLabel(change.change))",
                    systemImage: "building.2"
                )
            }
            ForEach(plan.diff.modelChanges) { change in
                Label(
                    "\(change.modelEntryID) · \(catalogChangeLabel(change.change))",
                    systemImage: "cube"
                )
            }
            HStack {
                Button("검토 취소", role: .cancel) {
                    viewModel.cancelPreparedCatalogRollback()
                }
                .disabled(viewModel.isBusy)
                Spacer()
                Button("검토한 롤백 활성화") {
                    confirmsCatalogRollback = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier(
                    "provider-catalog-rollback-activate"
                )
            }
        }
    }

    private func catalogImportReview(
        _ plan: ProviderCatalogImportPlan
    ) -> some View {
        let review = plan.review
        return Section("활성화 전 변경 검토") {
            if let filename =
                viewModel.pendingCatalogImportFilename
            {
                LabeledContent("파일", value: filename)
                    .privacySensitive()
            }
            LabeledContent("검증된 서명 키", value: review.signingKeyID)
            LabeledContent(
                "Revision",
                value:
                    "r\(review.expectedActiveRevision) → r\(review.candidateRevision)"
            )
            LabeledContent(
                "파일 크기",
                value: ByteCountFormatter.string(
                    fromByteCount: Int64(
                        clamping: review.envelopeByteCount
                    ),
                    countStyle: .file
                )
            )
            LabeledContent("검토 만료", value: review.expiresAt)
            Label(
                "현재 활성 revision은 아직 r\(review.expectedActiveRevision)입니다.",
                systemImage: "pause.circle"
            )
            .foregroundStyle(.secondary)

            if review.diff.manifestChanges.isEmpty,
               review.diff.modelChanges.isEmpty
            {
                Text("템플릿 또는 모델 메타데이터 변경이 없습니다.")
                    .foregroundStyle(.secondary)
            }

            ForEach(review.diff.manifestChanges) { change in
                DisclosureGroup {
                    LabeledContent(
                        "변경",
                        value: catalogChangeLabel(change.change)
                    )
                    if let previous =
                        change.previousManifestVersion
                    {
                        LabeledContent(
                            "이전 manifest",
                            value: "v\(previous)"
                        )
                    }
                    if let next = change.nextManifestVersion {
                        LabeledContent(
                            "다음 manifest",
                            value: "v\(next)"
                        )
                    }
                    if !change.changedSections.isEmpty {
                        Text(
                            change.changedSections
                                .joined(separator: ", ")
                        )
                        .font(.caption.monospaced())
                    }
                } label: {
                    Label(
                        "\(change.providerTemplateID) · \(catalogChangeLabel(change.change))",
                        systemImage: "building.2"
                    )
                }
            }

            ForEach(review.diff.modelChanges) { change in
                DisclosureGroup {
                    LabeledContent(
                        "프로바이더",
                        value: change.providerTemplateID
                    )
                    LabeledContent(
                        "변경",
                        value: catalogChangeLabel(change.change)
                    )
                    if let previous =
                        change.previousMetadataVersion
                    {
                        LabeledContent(
                            "이전 metadata",
                            value: "v\(previous)"
                        )
                    }
                    if let next = change.nextMetadataVersion {
                        LabeledContent(
                            "다음 metadata",
                            value: "v\(next)"
                        )
                    }
                    if !change.changedSections.isEmpty {
                        Text(
                            change.changedSections
                                .joined(separator: ", ")
                        )
                        .font(.caption.monospaced())
                    }
                } label: {
                    Label(
                        "\(change.modelEntryID) · \(catalogChangeLabel(change.change))",
                        systemImage: "cube"
                    )
                }
            }

            HStack {
                Button("검토 취소", role: .cancel) {
                    viewModel.cancelPreparedCatalogImport()
                }
                .disabled(viewModel.isBusy)
                Spacer()
                Button("검토한 변경 활성화") {
                    confirmsCatalogActivation = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isBusy)
                .accessibilityIdentifier(
                    "provider-catalog-import-activate"
                )
            }
        }
    }

    private func catalogChangeLabel(
        _ change: ProviderCatalogChangeKind
    ) -> String {
        switch change {
        case .added: "추가"
        case .updated: "변경"
        case .removed: "제거"
        }
    }
}

private extension ProviderDiscoveryMethod {
    var symbolName: String {
        switch self {
        case .knownProvider: "building.2"
        case .website: "globe"
        case .curl: "terminal"
        case .localServer: "desktopcomputer"
        }
    }
}

private extension ProviderDiscoveryStepState {
    var symbolName: String {
        switch self {
        case .pending: "circle"
        case .active: "circle.dotted"
        case .complete: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .failed: "xmark.circle.fill"
        }
    }

    var displayName: String {
        switch self {
        case .pending: "대기"
        case .active: "진행 중"
        case .complete: "완료"
        case .skipped: "건너뜀"
        case .failed: "실패"
        }
    }

    var color: Color {
        switch self {
        case .pending, .skipped: .secondary
        case .active: .accentColor
        case .complete: .green
        case .failed: .red
        }
    }
}

private extension ProviderReviewChangeKind {
    var symbol: String {
        switch self {
        case .add: "+"
        case .update: "~"
        case .deprecate: "!"
        case .preserveMissing: "!"
        }
    }

    var color: Color {
        switch self {
        case .add: .green
        case .update: .blue
        case .deprecate, .preserveMissing: .orange
        }
    }
}

private extension ProviderModelSyncState {
    var displayName: String {
        switch self {
        case .created: "준비"
        case .fetching: "모델 확인 중"
        case .interrupted: "중단됨"
        case .awaitingReview: "변경 검토 필요"
        case .completed: "적용 완료"
        case .failed: "실패"
        case .cancelled: "취소됨"
        }
    }
}

private extension ProviderDiscoveryCompensationKind {
    var displayName: String {
        switch self {
        case .removeCredentialSlot: "Keychain API 키 제거"
        case .removeConnectionGraph: "연결 graph 제거"
        case .restorePreviousSelection: "이전 기본 모델 복원"
        }
    }
}

private extension ProviderDiscoveryCompensationStatus {
    var displayName: String {
        switch self {
        case .pending: "대기"
        case .inProgress: "진행 중"
        case .completed: "완료"
        case .failed: "실패"
        case .outcomeUnknown: "결과 확인 필요"
        }
    }
}

private extension String {
    var displayCapabilityName: String {
        switch self {
        case "streaming": "스트리밍"
        case "reasoning": "추론"
        case "structured_output": "JSON Schema"
        case "prompt_cache": "프롬프트 캐시"
        case "tool_calls": "툴 호출"
        case "parallel_tool_calls": "병렬 툴 호출"
        case "context_window": "컨텍스트 길이"
        default: self
        }
    }

    var displayName: String {
        switch self {
        case "provider_api": "실제 provider API"
        case "signed_catalog": "서명 카탈로그"
        case "capability_probe": "실제 검사"
        case "official_documentation": "공식 문서"
        case "user_override": "사용자 지정"
        default: self
        }
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
