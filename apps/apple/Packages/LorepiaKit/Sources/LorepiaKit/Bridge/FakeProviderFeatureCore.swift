import Foundation

actor FakeProviderFeatureCore {
    private struct DiscoveryRecord {
        var snapshot: ProviderDiscoverySnapshot
        let displayName: String
        let connectionID: String
        let templateID: String
        let apiOrigin: String
        let hasCredential: Bool
        let networkMode: ProviderNetworkMode
        let localNetworkApproval: ProviderLocalNetworkApproval?
        let assistantModelRouteID: String?
    }

    private let timestamp = "2026-07-31T00:00:00Z"
    private let forcesOpaqueReasoningStateOff: Bool
    private let reasoningMetadataFixture:
        FakeReasoningMetadataFixture
    private var templates: [ProviderTemplateDescriptor]
    private var connections: [ProviderConnectionRecord]
    private var routesByConnection: [String: [ProviderModelRoute]]
    private var presetsByRoute: [String: [ProviderGenerationPreset]]
    private var capabilitiesByRoute: [
        String: [ProviderEffectiveCapability]
    ]
    private var discoveries: [String: DiscoveryRecord] = [:]
    private var discoveryOrder: [String] = []
    private var discoveryOutbox: [ProviderDiscoveryOutboxEvent] = []
    private var compensationStepsByAttempt: [
        String: [ProviderDiscoveryCompensationStep]
    ] = [:]
    private var curlCredentialHandoffs: [String: Data] = [:]
    private var modelSyncJobs: [String: ProviderModelSyncJob] = [:]
    private var modelSyncJobOrder: [String] = []
    private var modelSyncEvents: [
        String: [ProviderModelSyncEvent]
    ] = [:]
    private var pendingCatalogImports: [String: Data] = [:]
    private var pendingCatalogRollbacks:
        [String: ProviderCatalogRollbackPlan] = [:]
    private var previewedPresetCandidates:
        [ProviderGenerationPreset] = []
    private var catalog: ProviderCatalogStatus

    init(
        legacyProfiles: [ProviderProfile],
        forcesOpaqueReasoningStateOff: Bool = false,
        reasoningMetadataFixture:
            FakeReasoningMetadataFixture = .generic
    ) {
        self.forcesOpaqueReasoningStateOff =
            forcesOpaqueReasoningStateOff
        self.reasoningMetadataFixture = reasoningMetadataFixture
        let parameterSpecs = [
            ProviderParameterSpec(
                id: "temperature",
                label: "창의성",
                description: "비워 두면 프로바이더 기본값을 사용합니다.",
                type: .number,
                minimum: 0,
                maximum: 2,
                step: 0.1
            ),
            ProviderParameterSpec(
                id: "max_output_tokens",
                label: "최대 출력 토큰",
                type: .integer,
                minimum: 1,
                maximum: 32_768,
                step: 1
            ),
            ProviderParameterSpec(
                id: "reasoning_effort",
                label: "추론 강도",
                type: .enumeration,
                choices: [
                    ProviderParameterChoice(
                        value: .enumeration("low"),
                        label: "낮음"
                    ),
                    ProviderParameterChoice(
                        value: .enumeration("medium"),
                        label: "중간"
                    ),
                    ProviderParameterChoice(
                        value: .enumeration("high"),
                        label: "높음"
                    ),
                ],
                level: .advanced
            ),
        ]
        templates = [
            ProviderTemplateDescriptor(
                id: "openai-v1",
                displayName: "OpenAI",
                manifestVersion: 1,
                source: "bundled",
                apiFamily: "openai_chat_completions",
                defaultAPIOrigin: "https://api.openai.com",
                requiresCredential: true,
                supportsModelListing: true,
                parameters: parameterSpecs
            ),
            ProviderTemplateDescriptor(
                id: "anthropic-v1",
                displayName: "Anthropic",
                manifestVersion: 1,
                source: "bundled",
                apiFamily: "anthropic_messages",
                defaultAPIOrigin: "https://api.anthropic.com",
                requiresCredential: true,
                supportsModelListing: true,
                parameters: parameterSpecs
            ),
            ProviderTemplateDescriptor(
                id: "gemini-v1",
                displayName: "Gemini",
                manifestVersion: 1,
                source: "bundled",
                apiFamily: "gemini_generate_content",
                defaultAPIOrigin: "https://generativelanguage.googleapis.com",
                requiresCredential: true,
                supportsModelListing: true,
                parameters: parameterSpecs
            ),
            ProviderTemplateDescriptor(
                id: "openrouter-v1",
                displayName: "OpenRouter",
                manifestVersion: 1,
                source: "bundled",
                apiFamily: "openai_chat_completions",
                defaultAPIOrigin: "https://openrouter.ai",
                requiresCredential: true,
                supportsModelListing: true,
                parameters: parameterSpecs
            ),
            ProviderTemplateDescriptor(
                id: "ollama-v1",
                displayName: "Ollama",
                manifestVersion: 1,
                source: "bundled",
                apiFamily: "ollama_chat",
                defaultNetworkMode: .localLoopback,
                defaultAPIOrigin: "http://127.0.0.1:11434",
                requiresCredential: false,
                supportsModelListing: true,
                parameters: parameterSpecs
            ),
            ProviderTemplateDescriptor(
                id: "synthetic-manifest-fields-v1",
                displayName: "Synthetic Manifest Fields",
                manifestVersion: 1,
                source: "synthetic-test",
                apiFamily: "openai_chat_completions",
                defaultAPIOrigin: "https://manifest.invalid",
                requiresCredential: true,
                supportsModelListing: true,
                connectionFields: [
                    ProviderConnectionField(
                        key: "project_id",
                        label: "프로젝트 ID",
                        description:
                            "Core manifest가 요구하는 프로젝트 식별자",
                        type: .text,
                        isRequired: true
                    ),
                    ProviderConnectionField(
                        key: "api_version",
                        label: "API 버전",
                        type: .integer,
                        isRequired: true
                    ),
                    ProviderConnectionField(
                        key: "use_vertex",
                        label: "Vertex 경로 사용",
                        type: .boolean,
                        isRequired: true
                    ),
                    ProviderConnectionField(
                        key: "api_key",
                        label: "API 키",
                        type: .credential,
                        isRequired: true
                    ),
                ],
                parameters: parameterSpecs
            ),
        ]

        connections = []
        routesByConnection = [:]
        presetsByRoute = [:]
        capabilitiesByRoute = [:]
        for profile in legacyProfiles {
            let components = URLComponents(string: profile.baseURL)
            var origin = "\(components?.scheme ?? "https")://"
                + (components?.host ?? "example.invalid")
            if let port = components?.port {
                origin += ":\(port)"
            }
            let basePath = components?.path.isEmpty == false
                ? components?.path
                : nil
            let connection = ProviderConnectionRecord(
                id: profile.id,
                templateID: "openai-v1",
                templateVersion: 1,
                displayName: profile.displayName,
                apiOrigin: origin,
                apiBasePath: basePath,
                hasCredential: false,
                approvedCredentialOrigins: [origin],
                timeoutSeconds: profile.timeoutSeconds,
                status: "connected",
                createdAt: timestamp,
                updatedAt: timestamp
            )
            connections.append(connection)
            // Rust's legacy migration deliberately preserves the profile ID
            // for the connection, route, and default preset.
            let route = ProviderModelRoute(
                id: profile.id,
                connectionID: connection.id,
                apiFamily: "openai_chat_completions",
                modelID: profile.model,
                displayName: profile.model,
                endpointPath: "\(basePath ?? "")/chat/completions",
                availability: .available,
                firstSeenAt: timestamp,
                lastSeenAt: timestamp,
                metadataSource: "legacy_migration",
                metadataObservedAt: timestamp
            )
            routesByConnection[connection.id] = [route]
            let preset = ProviderGenerationPreset(
                id: profile.id,
                modelRouteID: route.id,
                displayName: "기본",
                createdAt: timestamp,
                updatedAt: timestamp
            )
            presetsByRoute[route.id] = [preset]
            let streaming = ProviderCapabilityObservation(
                id: "\(profile.id)-streaming",
                modelRouteID: route.id,
                key: "streaming",
                value: .boolean(true),
                status: "verified",
                source: "provider_api",
                confidence: "high",
                observedAt: timestamp,
                expiresAt: nil,
                evidenceReference: "synthetic://provider-api"
            )
            let reasoning = ProviderCapabilityObservation(
                id: "\(profile.id)-reasoning",
                modelRouteID: route.id,
                key: "reasoning",
                value: .enumeration(["low", "medium", "high"]),
                status: "conditional",
                source: "official_documentation",
                confidence: "medium",
                observedAt: timestamp,
                expiresAt: nil,
                evidenceReference: "https://example.invalid/docs"
            )
            capabilitiesByRoute[route.id] = [
                ProviderEffectiveCapability(
                    selected: streaming,
                    alternatives: [],
                    evaluatedAt: timestamp,
                    isStale: false,
                    hasConflict: false
                ),
                ProviderEffectiveCapability(
                    selected: reasoning,
                    alternatives: [],
                    evaluatedAt: timestamp,
                    isStale: false,
                    hasConflict: false
                ),
            ]
        }
        let activation = ProviderCatalogActivation(
            id: "bundled-1",
            revision: 1,
            source: "bundled",
            signer: "LorePia release key",
            activatedAt: timestamp,
            isCurrent: true,
            summary: "내장 프로바이더 카탈로그"
        )
        catalog = ProviderCatalogStatus(
            schemaVersion: 1,
            currentRevision: 1,
            currentSource: "bundled",
            verifiedSigner: activation.signer,
            updatedAt: timestamp,
            history: [activation]
        )
    }

    func listTemplates() -> [ProviderTemplateDescriptor] {
        templates
    }

    func listConnections() -> [ProviderConnectionRecord] {
        connections.sorted {
            $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
    }

    func deleteConnection(id: String) throws -> Set<String> {
        guard connections.contains(where: { $0.id == id }) else {
            throw CoreClientFailure.invalidResponse(
                "삭제할 프로바이더 연결을 찾지 못했습니다."
            )
        }
        connections.removeAll { $0.id == id }
        let routeIDs = Set((routesByConnection.removeValue(forKey: id) ?? []).map(\.id))
        for routeID in routeIDs {
            presetsByRoute.removeValue(forKey: routeID)
            capabilitiesByRoute.removeValue(forKey: routeID)
        }
        return routeIDs
    }

    func listRoutes(connectionID: String) -> [ProviderModelRoute] {
        routesByConnection[connectionID] ?? []
    }

    func listPresets(routeID: String) -> [ProviderGenerationPreset] {
        presetsByRoute[routeID] ?? []
    }

    func resolveTarget(
        _ target: ProviderGenerationTarget
    ) throws -> ProviderGenerationOption {
        guard let route = routesByConnection.values
            .joined()
            .first(where: { $0.id == target.modelRouteID }),
              let connection = connections.first(where: {
                  $0.id == route.connectionID
              }),
              let preset = presetsByRoute[route.id]?.first(where: {
                  $0.id == target.generationPresetID
              })
        else {
            throw CoreClientFailure.invalidResponse(
                "선택한 모델 경로와 프리셋을 찾지 못했습니다."
            )
        }
        return ProviderGenerationOption(
            connection: connection,
            route: route,
            preset: preset
        )
    }

    func upsertPreset(
        _ preset: ProviderGenerationPreset
    ) throws -> ProviderGenerationPreset {
        try validatePresetCandidate(preset)
        var presets = presetsByRoute[preset.modelRouteID] ?? []
        presets.removeAll { $0.id == preset.id }
        presets.append(preset)
        presetsByRoute[preset.modelRouteID] = presets
        return preset
    }

    func validatePreset(
        routeID: String,
        presetID: String
    ) throws {
        guard let preset = presetsByRoute[routeID]?.first(where: {
            $0.id == presetID
        }) else {
            throw CoreClientFailure.invalidResponse(
                "검증할 생성 프리셋을 찾지 못했습니다."
            )
        }
        try validatePresetCandidate(preset)
    }

    func validatePresetCandidate(
        _ preset: ProviderGenerationPreset
    ) throws {
        let control = try reasoningControl(for: preset)
        guard control.issues.isEmpty else {
            throw CoreClientFailure.invalidResponse(
                control.issues[0].message
            )
        }
    }

    private func validatePresetStructure(
        _ preset: ProviderGenerationPreset
    ) throws {
        guard routesByConnection.values.joined().contains(where: {
            $0.id == preset.modelRouteID
        }) else {
            throw CoreClientFailure.invalidResponse(
                "프리셋의 모델 경로를 찾지 못했습니다."
            )
        }
        guard !preset.id.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty,
        !preset.displayName.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
        else {
            throw CoreClientFailure.invalidResponse(
                "프리셋 ID와 이름은 비어 있을 수 없습니다."
            )
        }

        let specs = listParameterSpecs(routeID: preset.modelRouteID)
        let specsByID = Dictionary(uniqueKeysWithValues: specs.map {
            ($0.id, $0)
        })
        guard Set(preset.values.map(\.parameterID)).count
            == preset.values.count
        else {
            throw CoreClientFailure.invalidResponse(
                "같은 생성 파라미터를 두 번 설정할 수 없습니다."
            )
        }

        for parameter in preset.values {
            guard let spec = specsByID[parameter.parameterID] else {
                throw CoreClientFailure.invalidResponse(
                    "지원하지 않는 생성 파라미터입니다: \(parameter.parameterID)"
                )
            }
            switch parameter.state {
            case .providerDefault:
                guard spec.defaultMode != .explicitRequired else {
                    throw CoreClientFailure.invalidResponse(
                        "\(spec.label)은(는) 값을 직접 선택해야 합니다."
                    )
                }
            case let .explicit(literal):
                try validate(literal: literal, against: spec)
            }
        }
    }

    func reasoningControl(
        for preset: ProviderGenerationPreset
    ) throws -> ProviderReasoningControl {
        try validatePresetStructure(preset)
        let allowedModes: [String]
        let allowedEfforts: [String]
        let allowedSummaries: [String]
        let canonicalEffort: String?
        let effortField: ProviderUIFieldState
        let budgetField: ProviderUIFieldState
        let summaryField: ProviderUIFieldState
        let reasoningEnabled =
            preset.reasoningMode != "disabled"
                && preset.reasoningMode != "provider_default"

        switch reasoningMetadataFixture {
        case .generic:
            allowedModes = [
                "provider_default",
                "disabled",
                "automatic",
                "enabled",
            ]
            allowedEfforts = ["minimal", "low", "medium", "high"]
            allowedSummaries = [
                "provider_default",
                "disabled",
                "automatic",
                "concise",
                "detailed",
            ]
            canonicalEffort = preset.reasoningEffort
            effortField = reasoningEnabled ? .enabled : .hidden
            budgetField =
                preset.reasoningMode == "enabled"
                    ? .enabled
                    : .hidden
            summaryField = reasoningEnabled ? .enabled : .hidden
        case let .openRouterExact(defaultEffort):
            allowedModes = ["provider_default", "enabled"]
            allowedEfforts = ["low", "medium", "high"]
            allowedSummaries = ["provider_default"]
            canonicalEffort =
                preset.reasoningMode == "enabled"
                    ? preset.reasoningEffort ?? defaultEffort
                    : preset.reasoningEffort
            effortField =
                preset.reasoningMode == "enabled"
                    ? defaultEffort == nil ? .required : .enabled
                    : .hidden
            budgetField = .hidden
            summaryField = .hidden
        case .openRouterNotExposed, .openRouterExactEmpty:
            allowedModes = ["provider_default", "enabled"]
            allowedEfforts = []
            allowedSummaries = ["provider_default"]
            canonicalEffort = preset.reasoningEffort
            effortField = .hidden
            budgetField = .hidden
            summaryField = .hidden
        case .openRouterExactNoneOnly:
            allowedModes = ["provider_default", "disabled"]
            allowedEfforts = []
            allowedSummaries = ["provider_default"]
            canonicalEffort = preset.reasoningEffort
            effortField = .hidden
            budgetField = .hidden
            summaryField = .hidden
        }

        var issues: [ProviderParameterIssue] = []
        if !allowedModes.contains(preset.reasoningMode) {
            issues.append(
                ProviderParameterIssue(
                    code: "unsupported_reasoning",
                    parameterID: "reasoning",
                    relatedParameterID: nil,
                    message: "선택한 모델에서 지원하지 않는 추론 모드입니다."
                )
            )
        }
        if preset.reasoningMode == "provider_default",
           preset.reasoningEffort != nil
                || preset.reasoningBudgetTokens != nil
                || preset.reasoningSummary != "provider_default"
        {
            issues.append(
                ProviderParameterIssue(
                    code: "unsupported_reasoning",
                    parameterID: "reasoning",
                    relatedParameterID: nil,
                    message:
                        "프로바이더 기본값에는 추론 강도, 예산 또는 요약을 함께 설정할 수 없습니다."
                )
            )
        }
        if let effort = preset.reasoningEffort,
           !allowedEfforts.contains(effort)
        {
            issues.append(
                ProviderParameterIssue(
                    code: "unsupported_reasoning",
                    parameterID: "reasoning_effort",
                    relatedParameterID: nil,
                    message: "선택한 모델에서 지원하지 않는 추론 강도입니다."
                )
            )
        }
        if case .openRouterExact(defaultEffort: nil) =
            reasoningMetadataFixture,
           preset.reasoningMode == "enabled",
           preset.reasoningEffort == nil
        {
            issues.append(
                ProviderParameterIssue(
                    code: "missing_required_parameter",
                    parameterID: "reasoning_effort",
                    relatedParameterID: nil,
                    message: "이 모델은 추론 강도를 직접 선택해야 합니다."
                )
            )
        }
        if !allowedSummaries.contains(preset.reasoningSummary) {
            issues.append(
                ProviderParameterIssue(
                    code: "unsupported_reasoning",
                    parameterID: "reasoning_summary",
                    relatedParameterID: nil,
                    message: "선택한 모델에서 지원하지 않는 추론 요약 방식입니다."
                )
            )
        }
        if reasoningMetadataFixture.isOpenRouter,
           preset.reasoningBudgetTokens != nil
        {
            issues.append(
                ProviderParameterIssue(
                    code: "unsupported_reasoning",
                    parameterID: "reasoning_budget",
                    relatedParameterID: nil,
                    message: "이 모델은 경계가 확인된 추론 예산을 제공하지 않습니다."
                )
            )
        }
        return ProviderReasoningControl(
            state: issues.isEmpty ? .ready : .invalid,
            mode: preset.reasoningMode,
            effort: canonicalEffort,
            budgetTokens: preset.reasoningBudgetTokens,
            summary: preset.reasoningSummary,
            preservesOpaqueState:
                forcesOpaqueReasoningStateOff
                    ? false
                    : preset.preservesOpaqueReasoningState,
            allowedModes: allowedModes,
            allowedEfforts: allowedEfforts,
            allowedSummaries: allowedSummaries,
            minimumBudgetTokens:
                reasoningMetadataFixture == .generic ? 1 : nil,
            maximumBudgetTokens:
                reasoningMetadataFixture == .generic ? 32_768 : nil,
            effortField: effortField,
            budgetField: budgetField,
            summaryField: summaryField,
            issues: issues
        )
    }

    func promptCacheControl(
        for preset: ProviderGenerationPreset
    ) throws -> ProviderPromptCacheControl {
        try validatePresetStructure(preset)
        let allowedModes = [
            "provider_default",
            "automatic",
            "explicit_breakpoints",
            "explicit_context",
            "disabled_if_supported",
        ]
        let ttlIsVisible =
            preset.promptCacheMode == "automatic"
                || preset.promptCacheMode == "explicit_breakpoints"
                || preset.promptCacheMode == "explicit_context"
        let allowedTTLs = ttlIsVisible
            ? [
                "provider_default",
                "short",
                "long",
            ]
            : ["provider_default"]
        let supportsCustomTTL = ttlIsVisible
        var issues: [ProviderParameterIssue] = []
        if !allowedModes.contains(preset.promptCacheMode) {
            issues.append(
                ProviderParameterIssue(
                    code: "unsupported_prompt_cache",
                    parameterID: "prompt_cache",
                    relatedParameterID: nil,
                    message: "선택한 모델에서 지원하지 않는 프롬프트 캐시 모드입니다."
                )
            )
        }
        if !allowedTTLs.contains(preset.promptCacheTTL),
           !(supportsCustomTTL
               && preset.promptCacheTTL == "custom_seconds")
        {
            issues.append(
                ProviderParameterIssue(
                    code: "unsupported_prompt_cache",
                    parameterID: "prompt_cache_ttl",
                    relatedParameterID: nil,
                    message: "선택한 캐시 모드에서 지원하지 않는 TTL입니다."
                )
            )
        }
        let requiresContext =
            preset.promptCacheMode == "explicit_context"
        if requiresContext,
           preset.promptCacheContextReference?
               .trimmingCharacters(in: .whitespacesAndNewlines)
               .isEmpty != false
        {
            issues.append(
                ProviderParameterIssue(
                    code: "invalid_prompt_cache_reference",
                    parameterID: "prompt_cache_context_reference",
                    relatedParameterID: nil,
                    message: "명시적 컨텍스트 캐시에는 참조 이름이 필요합니다."
                )
            )
        }
        return ProviderPromptCacheControl(
            state: issues.isEmpty ? .ready : .invalid,
            mode: preset.promptCacheMode,
            ttl: preset.promptCacheTTL,
            customTTLSeconds: preset.promptCacheCustomTTLSeconds,
            contextReference: preset.promptCacheContextReference,
            allowedModes: allowedModes,
            allowedTTLs: allowedTTLs,
            supportsCustomTTL: supportsCustomTTL,
            minimumCustomTTLSeconds: 1,
            maximumCustomTTLSeconds: 86_400,
            ttlField: ttlIsVisible ? .enabled : .hidden,
            contextReferenceField: requiresContext
                ? .required
                : .hidden,
            issues: issues
        )
    }

    func deletePreset(id: String) throws -> String? {
        var deletedRouteID: String?
        for routeID in Array(presetsByRoute.keys) {
            if presetsByRoute[routeID]?.contains(where: {
                $0.id == id
            }) == true {
                if routeID == id {
                    throw CoreClientFailure.invalidResponse(
                        "마이그레이션된 기본 프리셋은 연결과 별도로 삭제할 수 없습니다."
                    )
                }
                deletedRouteID = routeID
            }
            presetsByRoute[routeID]?.removeAll { $0.id == id }
        }
        return deletedRouteID
    }

    func listCapabilities(
        routeID: String
    ) -> [ProviderEffectiveCapability] {
        capabilitiesByRoute[routeID] ?? []
    }

    func listParameterSpecs(
        routeID: String
    ) -> [ProviderParameterSpec] {
        guard routesByConnection.values
            .joined()
            .contains(where: { $0.id == routeID })
        else {
            return []
        }
        return templates.first { $0.id == "openai-v1" }?.parameters ?? []
    }

    func inspectCurl(
        _ rawCurl: String,
        networkPolicy: ProviderNetworkPolicy
    ) throws
        -> ProviderCurlInspection
    {
        guard !rawCurl.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw CoreClientFailure.invalidResponse(
                "검사할 cURL 예제가 비어 있습니다."
            )
        }
        let origin: String
        switch networkPolicy.mode {
        case .publicInternet:
            guard networkPolicy.localNetworkApproval == nil else {
                throw CoreClientFailure.invalidResponse(
                    "공개 cURL에는 LAN 승인을 보낼 수 없습니다."
                )
            }
            origin = "https://api.example.invalid"
        case .localLoopback:
            guard networkPolicy.localNetworkApproval == nil else {
                throw CoreClientFailure.invalidResponse(
                    "loopback cURL에는 LAN 승인을 보낼 수 없습니다."
                )
            }
            origin = "http://127.0.0.1:11434"
        case .approvedLocalNetwork:
            guard let approval =
                networkPolicy.localNetworkApproval,
                (1 ... 16).contains(approval.addresses.count)
            else {
                throw CoreClientFailure.invalidResponse(
                    "LAN cURL에는 정확한 origin과 IP 승인이 필요합니다."
                )
            }
            origin = approval.origin
        }
        let handoffID: String?
        if let marker = rawCurl.range(of: "Bearer ") {
            let suffix = rawCurl[marker.upperBound...]
            let token = suffix.prefix {
                !$0.isWhitespace && $0 != "'" && $0 != "\""
            }
            if token.isEmpty || token.contains("{{") {
                handoffID = nil
            } else {
                let id = "preview-handoff-\(UUID().uuidString.lowercased())"
                curlCredentialHandoffs[id] = Data(token.utf8)
                handoffID = id
            }
        } else {
            handoffID = nil
        }
        return ProviderCurlInspection(
            schemaVersion: 1,
            sanitizedSiteURL: origin,
            apiOrigin: origin,
            method: "GET",
            path: "/v1/models",
            headerNames: ["Authorization"],
            authBindingHint: "bearer_header",
            apiFamilyHint: "openai_chat_completions",
            modelHint: nil,
            streamHint: nil,
            redactedCurl:
                "curl \(origin)/v1/models -H 'Authorization: Bearer {{credential}}'",
            credentialHandoffID: handoffID
        )
    }

    func takeCurlCredential(handoffID: String) -> Data? {
        curlCredentialHandoffs.removeValue(forKey: handoffID)
    }

    func beginDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?
    ) throws -> ProviderDiscoverySnapshot {
        let sessionID = "preview-discovery-\(UUID().uuidString.lowercased())"
        let template: ProviderTemplateDescriptor
        switch source {
        case let .knownProvider(templateID):
            guard let selected = templates.first(where: {
                $0.id == templateID
            }) else {
                throw CoreClientFailure.invalidResponse(
                    "선택한 프로바이더 템플릿을 찾지 못했습니다."
                )
            }
            template = selected
        case .site, .curl:
            template = templates[0]
        }
        if case .curl = source {
            guard rawCurl?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty == false else {
                throw CoreClientFailure.invalidResponse(
                    "cURL 탐색에는 request-scoped 원문이 필요합니다."
                )
            }
        } else if rawCurl != nil {
            throw CoreClientFailure.invalidResponse(
                "cURL 원문은 cURL 탐색에만 사용할 수 있습니다."
            )
        }
        let curlApprovedOrigin: String?
        if case .curl = source {
            curlApprovedOrigin =
                input.connectionOptions.localNetworkApproval?.origin
        } else {
            curlApprovedOrigin = nil
        }
        let origin = sanitizedOrigin(
            input.siteURL
                ?? curlApprovedOrigin
                ?? (
                    input.connectionOptions.networkMode
                        == .localLoopback
                        ? "http://127.0.0.1:11434"
                        : template.defaultAPIOrigin
                            ?? "https://example.invalid"
                )
        )
        switch input.connectionOptions.networkMode {
        case .publicInternet, .localLoopback:
            guard input.connectionOptions.localNetworkApproval == nil else {
                throw CoreClientFailure.invalidResponse(
                    "이 네트워크 모드에는 LAN 승인을 보낼 수 없습니다."
                )
            }
        case .approvedLocalNetwork:
            guard let approval =
                input.connectionOptions.localNetworkApproval,
                approval.origin == origin,
                (1 ... 16).contains(approval.addresses.count)
            else {
                throw CoreClientFailure.invalidResponse(
                    "승인된 LAN origin과 IP 범위가 올바르지 않습니다."
                )
            }
        }
        let initialAction: ProviderDiscoveryActionRequired
        let initialState: ProviderDiscoveryState
        if case .site = source,
           input.connectionOptions.networkMode == .publicInternet
        {
            if let assistantModelRouteID =
                input.preferredAssistantModelRouteID
            {
                guard routesByConnection.values.joined().contains(
                    where: {
                        $0.id == assistantModelRouteID
                    }
                ) else {
                    throw CoreClientFailure.configurationRequired(
                        "provider setup assistant route was not selected"
                    )
                }
                initialAction = .assistantConsent(
                    ProviderDiscoveryAssistantConsent(
                        approvalID: "assistant-\(sessionID)",
                        grantSHA256:
                            String(repeating: "a", count: 64),
                        assistantModelRouteID:
                            assistantModelRouteID,
                        documentOrigins: [origin],
                        maximumCalls: 2,
                        maximumInputTokens: 8_192,
                        maximumOutputTokens: 2_048,
                        maximumToolCalls: 4,
                        maximumRetries: 1,
                        maximumCostMicroUnits: 50_000
                    )
                )
                initialState = .awaitingAssistantConsent
            } else {
                initialAction = .supplyMoreEvidence
                initialState = .awaitingMoreEvidence
            }
        } else {
            initialAction = .credentialOrigin(
                credentialApproval(origin: origin)
            )
            initialState = .awaitingCredentialOriginApproval
        }
        let snapshot = ProviderDiscoverySnapshot(
            id: sessionID,
            pendingConnectionID: input.connectionID,
            pendingDisplayName: input.displayName,
            connectionOptions: input.connectionOptions,
            credentialSlotID: input.credentialSlotReady
                ? input.connectionID
                : nil,
            credentialSlotExpected: input.credentialSlotReady,
            revision: 1,
            nextEventSequence: 2,
            state: initialState,
            steps: initialSteps(
                active: initialState == .awaitingAssistantConsent
                    || initialState == .awaitingMoreEvidence
                    ? "documents"
                    : "origin"
            ),
            actionRequired: initialAction,
            candidates: [
                ProviderDiscoveryCandidate(
                    id: "template:\(template.id)",
                    kind: "provider_template",
                    title: template.displayName,
                    subtitle: template.apiFamily
                ),
            ],
            assistantResumeBoundary:
                initialState == .awaitingAssistantConsent
                    ? ProviderDiscoveryAssistantResumeBoundary(
                        checkpoint: nil,
                        action: .approveConsent
                    )
                    : nil,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        discoveries[sessionID] = DiscoveryRecord(
            snapshot: snapshot,
            displayName: input.displayName,
            connectionID: input.connectionID,
            templateID: template.id,
            apiOrigin: origin,
            hasCredential: input.credentialSlotReady,
            networkMode: input.connectionOptions.networkMode,
            localNetworkApproval:
                input.connectionOptions.localNetworkApproval,
            assistantModelRouteID:
                input.preferredAssistantModelRouteID
        )
        discoveryOrder.append(sessionID)
        appendDiscoveryEvent(for: snapshot)
        return snapshot
    }

    func prepareDiscoveryAction(
        actionID: String,
        expectedRevision: UInt64,
        action: ProviderDiscoveryAction
    ) throws -> ProviderDiscoveryActionEnvelope {
        guard !actionID.isEmpty else {
            throw CoreClientFailure.invalidResponse(
                "탐색 action ID가 비어 있습니다."
            )
        }
        return ProviderDiscoveryActionEnvelope(
            actionID: actionID,
            expectedRevision: expectedRevision,
            requestSHA256: String(repeating: "e", count: 64),
            action: action
        )
    }

    func continueDiscovery(
        id: String,
        envelope: ProviderDiscoveryActionEnvelope,
        hasTargetCredential: Bool
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.revision == envelope.expectedRevision,
              !envelope.actionID.isEmpty,
              !envelope.requestSHA256.isEmpty
        else {
            throw CoreClientFailure.invalidResponse(
                "탐색 상태가 변경되었습니다. 다시 불러와 주세요."
            )
        }
        let action = envelope.action
        if record.hasCredential,
           action.requiresTargetCredential,
           !hasTargetCredential
        {
            throw CoreClientFailure.invalidResponse(
                "승인된 provider 요청에 사용할 request-scoped 자격증명이 없습니다."
            )
        }
        let expectedRevision = envelope.expectedRevision
        let nextRevision = expectedRevision + 1
        let next: ProviderDiscoverySnapshot
        switch action {
        case let .approveAssistant(approvalID, grantSHA256):
            guard case let .assistantConsent(consent) =
                record.snapshot.actionRequired,
                consent.approvalID == approvalID,
                consent.grantSHA256 == grantSHA256
            else {
                throw CoreClientFailure.invalidResponse(
                    "문서 분석 승인 제안이 변경되었습니다."
                )
            }
            next = ProviderDiscoverySnapshot(
                id: id,
                pendingConnectionID: record.connectionID,
                pendingDisplayName: record.displayName,
                connectionOptions:
                    record.snapshot.connectionOptions,
                credentialSlotID: record.hasCredential
                    ? record.connectionID
                    : nil,
                credentialSlotExpected: record.hasCredential,
                revision: nextRevision,
                state: .buildingAssistantManifestDraft,
                steps: initialSteps(active: "documents"),
                actionRequired: nil,
                candidates: record.snapshot.candidates,
                assistantApprovalBinding:
                    ProviderDiscoveryAssistantApprovalBinding(
                        assistantModelRouteID:
                            consent.assistantModelRouteID,
                        maximumCalls: consent.maximumCalls,
                        maximumInputTokens:
                            consent.maximumInputTokens,
                        maximumOutputTokens:
                            consent.maximumOutputTokens,
                        maximumToolCalls:
                            consent.maximumToolCalls,
                        maximumRetries:
                            consent.maximumRetries,
                        maximumCostMicroUnits:
                            consent.maximumCostMicroUnits
                    ),
                assistantResumeBoundary:
                    ProviderDiscoveryAssistantResumeBoundary(
                        checkpoint: .ready,
                        action: .runAssistant
                    ),
                createdAt: record.snapshot.createdAt,
                updatedAt: timestamp
            )
        case .declineAssistant:
            next = snapshot(
                from: record,
                revision: nextRevision,
                state: .awaitingMoreEvidence,
                actionRequired: .supplyMoreEvidence,
                steps: initialSteps(active: "documents"),
                warnings: ["assistant_declined"]
            )
        case .requestAssistant:
            guard record.snapshot.state == .awaitingMoreEvidence,
                  record.snapshot.actionRequired == .supplyMoreEvidence,
                  let assistantModelRouteID =
                      record.assistantModelRouteID,
                  routesByConnection.values.joined().contains(where: {
                      $0.id == assistantModelRouteID
                  })
            else {
                throw CoreClientFailure.configurationRequired(
                    "provider setup assistant route was not selected"
                )
            }
            next = snapshot(
                from: record,
                revision: nextRevision,
                state: .awaitingAssistantConsent,
                actionRequired: .assistantConsent(
                    ProviderDiscoveryAssistantConsent(
                        approvalID: "assistant-\(id)-\(nextRevision)",
                        grantSHA256:
                            String(repeating: "a", count: 64),
                        assistantModelRouteID:
                            assistantModelRouteID,
                        documentOrigins: [record.apiOrigin],
                        maximumCalls: 2,
                        maximumInputTokens: 8_192,
                        maximumOutputTokens: 2_048,
                        maximumToolCalls: 4,
                        maximumRetries: 1,
                        maximumCostMicroUnits: 50_000
                    )
                ),
                steps: initialSteps(active: "documents")
            )
        case let .approveCredentialOrigin(approvalID):
            guard case let .credentialOrigin(approval) =
                record.snapshot.actionRequired,
                approval.approvalID == approvalID
            else {
                throw CoreClientFailure.invalidResponse(
                    "자격증명 origin 승인 제안이 변경되었습니다."
                )
            }
            let routeID = "\(id)-route"
            next = ProviderDiscoverySnapshot(
                id: id,
                pendingConnectionID: record.connectionID,
                pendingDisplayName: record.displayName,
                credentialSlotID: record.hasCredential
                    ? record.connectionID
                    : nil,
                credentialSlotExpected: record.hasCredential,
                revision: nextRevision,
                state: .awaitingProbeConsent,
                steps: initialSteps(active: "probes"),
                actionRequired: .capabilityProbe(
                    ProviderDiscoveryProbeConsent(
                        approvalID: "probe-\(id)",
                        grantSHA256:
                            String(repeating: "b", count: 64),
                        routeIDs: [routeID],
                        budget: ProviderDiscoveryProbeBudget(
                            maximumRequests: 2,
                            maximumTotalTokensPerRequest: 512,
                            maximumOutputTokensPerRequest: 128,
                            maximumCostMicroUSDPerRequest: 2_500,
                            maximumDurationMillisecondsPerRequest:
                                15_000,
                            maximumCallsPerRequest: 1
                        )
                    )
                ),
                candidates: record.snapshot.candidates + [
                    ProviderDiscoveryCandidate(
                        id: routeID,
                        kind: "model_route",
                        title: "example-chat",
                        subtitle: "실제 models API"
                    ),
                ],
                warnings: record.snapshot.warnings,
                createdAt: record.snapshot.createdAt,
                updatedAt: timestamp
            )
        case let .approveProbes(approvalID, grantSHA256):
            guard case let .capabilityProbe(probe) =
                record.snapshot.actionRequired,
                probe.approvalID == approvalID,
                probe.grantSHA256 == grantSHA256
            else {
                throw CoreClientFailure.invalidResponse(
                    "기능 검사 승인 제안이 변경되었습니다."
                )
            }
            next = reviewDiscovery(
                record,
                revision: nextRevision,
                probesApproved: true
            )
        case .skipProbes:
            next = reviewDiscovery(
                record,
                revision: nextRevision,
                probesApproved: false
            )
        case let .approveReview(
            approvalID,
            commitAttemptID,
            commitPlanSHA256,
            graphSHA256
        ):
            guard let proposal = record.snapshot.reviewProposal,
                  proposal.approvalID == approvalID,
                  proposal.commitAttemptID == commitAttemptID,
                  proposal.commitPlanSHA256 == commitPlanSHA256,
                  proposal.review.graphSHA256 == graphSHA256
            else {
                throw CoreClientFailure.invalidResponse(
                    "검토 내용이 변경되었습니다. 다시 확인해 주세요."
                )
            }
            next = snapshot(
                from: record,
                revision: nextRevision,
                state: .committing,
                actionRequired: nil,
                steps: completedSteps(),
                review: proposal.review,
                reviewProposal: proposal
            )
        case .resumeCompensation, .restartInterrupted,
             .resolveUnknownOutcome:
            next = reviewDiscovery(
                record,
                revision: nextRevision,
                probesApproved: false
            )
        case .selectTemplate, .continueWithoutTemplate,
             .supplyMoreEvidence:
            next = snapshot(
                from: record,
                revision: nextRevision,
                state: .awaitingCredentialOriginApproval,
                actionRequired: .credentialOrigin(
                    credentialApproval(origin: record.apiOrigin)
                ),
                steps: initialSteps(active: "origin")
            )
        case .cancel:
            next = cancelledDiscovery(
                record.snapshot,
                revision: nextRevision
            )
        }
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return next
    }

    func supplyDocumentEvidence(
        id: String,
        expectedRevision: UInt64,
        documentURL: String
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.revision == expectedRevision,
              let url = URL(string: documentURL),
              ["http", "https"].contains(url.scheme?.lowercased())
        else {
            throw CoreClientFailure.invalidResponse(
                "추가 문서 증거 요청이 현재 탐색과 일치하지 않습니다."
            )
        }
        let evidence = ProviderDiscoveryEvidence(
            id: "document-\(UUID().uuidString.lowercased())",
            kind: "html_document",
            contentSHA256: String(repeating: "d", count: 64),
            fetchedAt: timestamp
        )
        let next = discoverySnapshot(
            record: record,
            revision: expectedRevision + 1,
            state: .buildingAssistantManifestDraft,
            evidence: record.snapshot.evidence + [evidence],
            assistantResumeBoundary:
                ProviderDiscoveryAssistantResumeBoundary(
                    checkpoint: .ready,
                    action: .runAssistant
                )
        )
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return next
    }

    func supplyCurlEvidence(
        id: String,
        expectedRevision: UInt64,
        redactedCurl: String
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.revision == expectedRevision,
              redactedCurl.contains("{{credential}}"),
              !redactedCurl.localizedCaseInsensitiveContains(
                  "synthetic-"
              )
        else {
            throw CoreClientFailure.invalidResponse(
                "추가 cURL은 먼저 검사한 redacted 결과여야 합니다."
            )
        }
        let evidence = ProviderDiscoveryEvidence(
            id: "curl-\(UUID().uuidString.lowercased())",
            kind: "plain_text_document",
            contentSHA256: String(repeating: "e", count: 64),
            fetchedAt: timestamp
        )
        let next = discoverySnapshot(
            record: record,
            revision: expectedRevision + 1,
            state: .buildingAssistantManifestDraft,
            evidence: record.snapshot.evidence + [evidence],
            assistantResumeBoundary:
                ProviderDiscoveryAssistantResumeBoundary(
                    checkpoint: .ready,
                    action: .runAssistant
                )
        )
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return next
    }

    func runAssistantTurn(
        id: String,
        estimate: ProviderDiscoveryAssistantCallEstimate
    ) throws -> ProviderDiscoveryAssistantHostAction {
        guard var record = discoveries[id],
              record.snapshot.state
                == .buildingAssistantManifestDraft,
              estimate.inputTokens > 0,
              estimate.maximumOutputTokens > 0
        else {
            throw CoreClientFailure.invalidResponse(
                "설정 도우미를 실행할 수 있는 탐색 상태가 아닙니다."
            )
        }
        let manifest = ProviderDiscoveryAssistantManifest(
            schemaVersion: 1,
            apiFamily: .openAIChatCompletions,
            sources: [
                ProviderDiscoveryAssistantManifestSource(
                    kind: .officialDocumentation,
                    url: "\(record.apiOrigin)/docs",
                    contentSHA256:
                        String(repeating: "d", count: 64)
                ),
            ],
            defaultAPIOrigin: record.apiOrigin,
            authDescription: "Authorization: Bearer",
            modelsEndpoint:
                ProviderDiscoveryAssistantEndpoint(
                    method: .get,
                    path: "/v1/models"
                ),
            generateEndpoint:
                ProviderDiscoveryAssistantEndpoint(
                    method: .post,
                    path: "/v1/chat/completions"
                ),
            responseDecoder: .openAIJSONV1,
            streamingDecoder: .openAISSEV1,
            parameters:
                templates.first(where: {
                    $0.id == "openai-v1"
                })?.parameters ?? []
        )
        let review = ProviderDiscoveryAssistantDraftReview(
                draft: ProviderDiscoveryAssistantManifestDraft(
                    manifest: manifest,
                    evidenceMappings: [],
                    conflicts: [],
                    unresolvedQuestions: [],
                    confidence: [
                        ProviderDiscoveryAssistantFieldConfidence(
                            field: .apiFamily,
                            level: .high,
                            rationale: "synthetic official evidence"
                        ),
                    ],
                    summary:
                        "공식 문서 증거로 OpenAI 호환 endpoint를 확인했습니다."
                ),
                unresolvedConflicts: [],
                requiredChecks: [
                    .manifestValidation,
                    .urlPolicyValidation,
                    .credentialOriginApproval,
                    .userReview,
                ],
                persistence: .blockedUntilChecksPass
            )
        let action = ProviderDiscoveryAssistantHostAction.reviewDraft(review)
        let next = snapshot(
            from: record,
            revision: record.snapshot.revision + 1,
            state: .buildingAssistantManifestDraft,
            actionRequired: nil,
            steps: initialSteps(active: "documents"),
            assistantResumeBoundary:
                ProviderDiscoveryAssistantResumeBoundary(
                    checkpoint: .draftReady,
                    action: .reviewDraft,
                    draftReview: review
                )
        )
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return action
    }

    func acceptAssistantDraft(
        id: String
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.state
                == .buildingAssistantManifestDraft
        else {
            throw CoreClientFailure.invalidResponse(
                "채택할 설정 도우미 초안이 없습니다."
            )
        }
        let next = snapshot(
            from: record,
            revision: record.snapshot.revision + 1,
            state: .awaitingCredentialOriginApproval,
            actionRequired: .credentialOrigin(
                credentialApproval(origin: record.apiOrigin)
            ),
            steps: initialSteps(active: "origin")
        )
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return next
    }

    func requestAssistantRevision(
        id: String
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.state
                == .buildingAssistantManifestDraft
        else {
            throw CoreClientFailure.invalidResponse(
                "수정할 설정 도우미 초안이 없습니다."
            )
        }
        let next = snapshot(
            from: record,
            revision: record.snapshot.revision + 1,
            state: .buildingAssistantManifestDraft,
            actionRequired: nil,
            steps: initialSteps(active: "documents"),
            assistantResumeBoundary:
                ProviderDiscoveryAssistantResumeBoundary(
                    checkpoint: .awaitingRetryConsent,
                    action: .approveRetry
                )
        )
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return next
    }

    func approveAssistantRetry(
        id: String
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.state
                == .buildingAssistantManifestDraft,
              record.snapshot.assistantResumeBoundary?.action
                == .approveRetry
        else {
            throw CoreClientFailure.invalidResponse(
                "승인할 설정 도우미 재시도 경계가 없습니다."
            )
        }
        let next = snapshot(
            from: record,
            revision: record.snapshot.revision + 1,
            state: .buildingAssistantManifestDraft,
            actionRequired: nil,
            steps: initialSteps(active: "documents"),
            assistantResumeBoundary:
                ProviderDiscoveryAssistantResumeBoundary(
                    checkpoint: .ready,
                    action: .runAssistant
                )
        )
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return next
    }

    func resumeAssistantCoreHostAction(
        id: String
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.state
                == .buildingAssistantManifestDraft,
              record.snapshot.assistantResumeBoundary?.action
                == .resumeCoreHostAction
        else {
            throw CoreClientFailure.invalidResponse(
                "재개할 Core 설정 도우미 도구 작업이 없습니다."
            )
        }
        let next = snapshot(
            from: record,
            revision: record.snapshot.revision + 1,
            state: .buildingAssistantManifestDraft,
            actionRequired: nil,
            steps: initialSteps(active: "documents"),
            assistantResumeBoundary:
                ProviderDiscoveryAssistantResumeBoundary(
                    checkpoint: .ready,
                    action: .runAssistant
                )
        )
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return next
    }

    func recordAssistantFailure(
        id: String,
        retryable: Bool
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id] else {
            throw CoreClientFailure.invalidResponse(
                "설정 도우미 탐색을 찾지 못했습니다."
            )
        }
        let next = snapshot(
            from: record,
            revision: record.snapshot.revision + 1,
            state: retryable ? .interrupted : .failed,
            actionRequired: retryable
                ? .restartInterrupted("build_assistant_manifest_draft")
                : nil,
            steps: initialSteps(active: "documents")
        )
        record.snapshot = next
        discoveries[id] = record
        appendDiscoveryEvent(for: next)
        return next
    }

    func getDiscovery(id: String) throws -> ProviderDiscoverySnapshot {
        guard let snapshot = discoveries[id]?.snapshot else {
            throw CoreClientFailure.invalidResponse(
                "프로바이더 탐색을 찾지 못했습니다."
            )
        }
        return snapshot
    }

    func listDiscoveries(limit: UInt32)
        -> [ProviderDiscoverySnapshot]
    {
        discoveryOrder.reversed().compactMap {
            discoveries[$0]?.snapshot
        }
        .prefix(Int(limit))
        .map { $0 }
    }

    func cancelDiscovery(
        id: String,
        expectedRevision: UInt64
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.revision == expectedRevision
        else {
            throw CoreClientFailure.invalidResponse(
                "탐색 상태가 변경되었습니다. 다시 불러와 주세요."
            )
        }
        let snapshot = cancelledDiscovery(
            record.snapshot,
            revision: expectedRevision + 1
        )
        record.snapshot = snapshot
        discoveries[id] = record
        appendDiscoveryEvent(for: snapshot)
        return snapshot
    }

    func commitDiscovery(
        id: String,
        credentialSlotConfirmed: Bool
    ) throws -> ProviderConnectionRecord {
        guard var record = discoveries[id],
              record.snapshot.state == .committing,
              let reviewProposal =
                  record.snapshot.reviewProposal
        else {
            throw CoreClientFailure.invalidResponse(
                "승인된 탐색 검토가 없어 연결을 저장할 수 없습니다."
            )
        }
        guard credentialSlotConfirmed == record.hasCredential else {
            let step = ProviderDiscoveryCompensationStep(
                id: "credential-\(reviewProposal.commitAttemptID)",
                commitAttemptID:
                    reviewProposal.commitAttemptID,
                ordinal: 0,
                actionID: "fake-remove-credential",
                kind: .removeCredentialSlot,
                target: .removeCredentialSlot(
                    connectionID: record.connectionID,
                    credentialReference: record.connectionID
                ),
                status: .pending,
                attemptCount: 0,
                lastFailure: nil,
                createdAt: timestamp,
                updatedAt: timestamp,
                completedAt: nil
            )
            compensationStepsByAttempt[
                reviewProposal.commitAttemptID
            ] = [step]
            let compensating = snapshot(
                from: record,
                revision: record.snapshot.revision + 1,
                state: .compensating,
                actionRequired: nil,
                steps: completedSteps(),
                review: record.snapshot.review,
                reviewProposal: reviewProposal
            )
            record.snapshot = compensating
            discoveries[id] = record
            appendDiscoveryEvent(for: compensating)
            throw CoreClientFailure.invalidResponse(
                "Keychain 슬롯 확인이 실패해 보상을 시작했습니다."
            )
        }
        let connectionID = record.connectionID
        let connection = ProviderConnectionRecord(
            id: connectionID,
            templateID: record.templateID,
            templateVersion: 1,
            displayName: record.displayName,
            apiOrigin: record.apiOrigin,
            apiBasePath: "/v1",
            networkMode: record.networkMode.rawValue,
            localNetworkApproval: record.localNetworkApproval,
            hasCredential: record.hasCredential,
            approvedCredentialOrigins: [record.apiOrigin],
            timeoutSeconds: 60,
            status: "connected",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        let route = ProviderModelRoute(
            id: "\(connectionID)-example-chat",
            connectionID: connectionID,
            apiFamily: "openai_chat_completions",
            modelID: "example-chat",
            displayName: "Example Chat",
            endpointPath: "/v1/chat/completions",
            availability: .available,
            firstSeenAt: timestamp,
            lastSeenAt: timestamp,
            metadataSource: "provider_api",
            metadataObservedAt: timestamp
        )
        routesByConnection[connectionID] = [route]
        presetsByRoute[route.id] = [
            ProviderGenerationPreset(
                id: "\(route.id)-default",
                modelRouteID: route.id,
                displayName: "기본",
                createdAt: timestamp,
                updatedAt: timestamp
            ),
        ]
        capabilitiesByRoute[route.id] =
            capabilitiesByRoute.values.first ?? []
        let completed = snapshot(
            from: record,
            revision: record.snapshot.revision + 1,
            state: .ready,
            actionRequired: nil,
            steps: completedSteps(),
            committedConnectionID: connectionID,
            review: record.snapshot.review,
            reviewProposal: record.snapshot.reviewProposal
        )
        record.snapshot = completed
        discoveries[id] = record
        appendDiscoveryEvent(for: completed)
        return connection
    }

    func listCompensationSteps(
        commitAttemptID: String
    ) -> [ProviderDiscoveryCompensationStep] {
        compensationStepsByAttempt[commitAttemptID] ?? []
    }

    func continueCompensation(
        id: String
    ) throws -> ProviderDiscoverySnapshot {
        guard var record = discoveries[id],
              record.snapshot.state == .compensating,
              let attemptID = record.snapshot.commitAttemptID
        else {
            throw CoreClientFailure.invalidResponse(
                "재개할 탐색 보상이 없습니다."
            )
        }
        let steps = compensationStepsByAttempt[attemptID] ?? []
        guard steps.allSatisfy({
            $0.status == .completed
        }) else {
            return record.snapshot
        }
        let failed = snapshot(
            from: record,
            revision: record.snapshot.revision + 1,
            state: .failed,
            actionRequired: nil,
            steps: record.snapshot.steps,
            review: record.snapshot.review,
            reviewProposal: record.snapshot.reviewProposal
        )
        record.snapshot = failed
        discoveries[id] = record
        appendDiscoveryEvent(for: failed)
        return failed
    }

    func startCredentialCompensation(
        id: String,
        stepID: String
    ) throws -> ProviderDiscoveryCompensationStep {
        guard let record = discoveries[id],
              let attemptID = record.snapshot.commitAttemptID,
              var steps = compensationStepsByAttempt[attemptID],
              let index = steps.firstIndex(where: {
                  $0.id == stepID
                      && $0.kind == .removeCredentialSlot
                      && ($0.status == .pending
                          || $0.status == .failed)
              })
        else {
            throw CoreClientFailure.invalidResponse(
                "시작할 Keychain 보상 단계가 없습니다."
            )
        }
        let current = steps[index]
        let started = ProviderDiscoveryCompensationStep(
            id: current.id,
            commitAttemptID: current.commitAttemptID,
            ordinal: current.ordinal,
            actionID: current.actionID,
            kind: current.kind,
            target: current.target,
            status: .inProgress,
            attemptCount: current.attemptCount + 1,
            lastFailure: current.lastFailure,
            createdAt: current.createdAt,
            updatedAt: timestamp,
            completedAt: nil
        )
        steps[index] = started
        compensationStepsByAttempt[attemptID] = steps
        return started
    }

    func finishCredentialCompensation(
        id: String,
        stepID: String,
        status: ProviderDiscoveryCompensationStatus,
        failure: ProviderDiscoveryFailure? = nil
    ) throws -> ProviderDiscoverySnapshot {
        guard let record = discoveries[id],
              let attemptID = record.snapshot.commitAttemptID,
              var steps = compensationStepsByAttempt[attemptID],
              let index = steps.firstIndex(where: {
                  $0.id == stepID
                      && $0.kind == .removeCredentialSlot
              })
        else {
            throw CoreClientFailure.invalidResponse(
                "완료할 Keychain 보상 단계가 없습니다."
            )
        }
        let current = steps[index]
        steps[index] = ProviderDiscoveryCompensationStep(
            id: current.id,
            commitAttemptID: current.commitAttemptID,
            ordinal: current.ordinal,
            actionID: current.actionID,
            kind: current.kind,
            target: current.target,
            status: status,
            attemptCount: current.attemptCount,
            lastFailure: failure,
            createdAt: current.createdAt,
            updatedAt: timestamp,
            completedAt:
                status == .completed ? timestamp : nil
        )
        compensationStepsByAttempt[attemptID] = steps
        return try continueCompensation(id: id)
    }

    func resumeCompensation(
        id: String
    ) throws -> ProviderDiscoverySnapshot {
        guard let record = discoveries[id],
              let attemptID = record.snapshot.commitAttemptID,
              var steps = compensationStepsByAttempt[attemptID]
        else {
            throw CoreClientFailure.invalidResponse(
                "재개할 탐색 보상이 없습니다."
            )
        }
        steps = steps.map { step in
            guard step.status == .failed else {
                return step
            }
            return ProviderDiscoveryCompensationStep(
                id: step.id,
                commitAttemptID: step.commitAttemptID,
                ordinal: step.ordinal,
                actionID: step.actionID,
                kind: step.kind,
                target: step.target,
                status: .pending,
                attemptCount: step.attemptCount,
                lastFailure: step.lastFailure,
                createdAt: step.createdAt,
                updatedAt: timestamp,
                completedAt: nil
            )
        }
        compensationStepsByAttempt[attemptID] = steps
        return record.snapshot
    }

    func recoverDiscoveries() -> [ProviderDiscoveryRecoveryResult] {
        []
    }

    func pollDiscoveryEvents(limit: UInt32)
        -> [ProviderDiscoveryOutboxEvent]
    {
        Array(discoveryOutbox.prefix(Int(limit)))
    }

    func ackDiscoveryEvent(id: String) -> Bool {
        guard let index = discoveryOutbox.firstIndex(where: {
            $0.event.id == id
        }) else {
            return false
        }
        discoveryOutbox.remove(at: index)
        return true
    }

    func startModelSync(connectionID: String) throws -> ProviderModelSyncJob {
        guard let existingRoute = routesByConnection[connectionID]?.first else {
            throw CoreClientFailure.invalidResponse(
                "동기화할 프로바이더 연결을 찾지 못했습니다."
            )
        }
        let jobID = "preview-sync-\(UUID().uuidString.lowercased())"
        let addedRoute = ProviderModelRoute(
            id: "\(connectionID)-example-pro-2",
            connectionID: connectionID,
            apiFamily: existingRoute.apiFamily,
            modelID: "example-pro-2",
            displayName: "Example Pro 2",
            endpointPath: existingRoute.endpointPath,
            availability: .available,
            firstSeenAt: timestamp,
            lastSeenAt: timestamp,
            metadataSource: "provider_api",
            metadataObservedAt: timestamp
        )
        let job = ProviderModelSyncJob(
            id: jobID,
            connectionID: connectionID,
            state: .awaitingReview,
            revision: 1,
            completedSteps: 3,
            totalSteps: 4,
            reviewSHA256: String(repeating: "b", count: 64),
            diff: ProviderModelSyncDiff(
                newRoutes: [addedRoute],
                changedRouteIDs: [existingRoute.id],
                missingRouteIDs: [],
                capabilityChangeCount: 1
            ),
            failureMessageKey: nil,
            updatedAt: timestamp
        )
        modelSyncJobs[jobID] = job
        modelSyncJobOrder.append(jobID)
        appendModelSyncEvent(for: job)
        return job
    }

    func modelSync(id: String) throws -> ProviderModelSyncJob {
        guard let job = modelSyncJobs[id] else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 작업을 찾지 못했습니다."
            )
        }
        return job
    }

    func listModelSyncs(
        connectionID: String,
        limit: UInt32
    ) -> [ProviderModelSyncJob] {
        modelSyncJobOrder.reversed().compactMap { id in
            guard let job = modelSyncJobs[id],
                  job.connectionID == connectionID
            else {
                return nil
            }
            return job
        }
        .prefix(Int(limit))
        .map { $0 }
    }

    func pollModelSyncEvents(
        id: String,
        limit: UInt32
    ) throws -> [ProviderModelSyncEvent] {
        guard modelSyncJobs[id] != nil else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 작업을 찾지 못했습니다."
            )
        }
        return Array(
            (modelSyncEvents[id] ?? []).prefix(Int(limit))
        )
    }

    func ackModelSyncEvent(
        id: String,
        sequence: UInt64
    ) throws -> Bool {
        guard modelSyncJobs[id] != nil else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 작업을 찾지 못했습니다."
            )
        }
        guard let index = modelSyncEvents[id]?.firstIndex(where: {
            $0.jobID == id && $0.sequence == sequence
        }) else {
            return false
        }
        modelSyncEvents[id]?.remove(at: index)
        return true
    }

    func approveModelSync(
        id: String,
        expectedRevision: UInt64,
        sha256: String
    ) throws -> ProviderModelSyncJob {
        guard let job = modelSyncJobs[id],
              job.revision == expectedRevision,
              job.reviewSHA256 == sha256
        else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 검토가 변경되었습니다."
            )
        }
        if let additions = job.diff?.newRoutes {
            var routes = routesByConnection[job.connectionID] ?? []
            for route in additions where !routes.contains(where: {
                $0.id == route.id
            }) {
                routes.append(route)
            }
            routesByConnection[job.connectionID] = routes
        }
        let completed = ProviderModelSyncJob(
            id: job.id,
            connectionID: job.connectionID,
            state: .completed,
            revision: job.revision + 1,
            completedSteps: job.totalSteps,
            totalSteps: job.totalSteps,
            reviewSHA256: job.reviewSHA256,
            diff: job.diff,
            failureMessageKey: nil,
            updatedAt: timestamp
        )
        modelSyncJobs[id] = completed
        appendModelSyncEvent(for: completed)
        return completed
    }

    func cancelModelSync(
        id: String,
        expectedRevision: UInt64
    ) throws -> ProviderModelSyncJob {
        guard let job = modelSyncJobs[id],
              job.revision == expectedRevision
        else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 상태가 변경되었습니다."
            )
        }
        let cancelled = ProviderModelSyncJob(
            id: job.id,
            connectionID: job.connectionID,
            state: .cancelled,
            revision: job.revision + 1,
            completedSteps: job.completedSteps,
            totalSteps: job.totalSteps,
            reviewSHA256: job.reviewSHA256,
            diff: job.diff,
            failureMessageKey: nil,
            updatedAt: timestamp
        )
        modelSyncJobs[id] = cancelled
        appendModelSyncEvent(for: cancelled)
        return cancelled
    }

    private func appendModelSyncEvent(
        for job: ProviderModelSyncJob
    ) {
        let sequence =
            (modelSyncEvents[job.id]?.last?.sequence ?? 0) + 1
        let event = ProviderModelSyncEvent(
            version: 1,
            jobID: job.id,
            sequence: sequence,
            jobRevision: job.revision,
            redactionVersion: 1,
            state: job.state,
            completedSteps: job.completedSteps,
            totalSteps: job.totalSteps,
            messageKey: "provider.model_sync.\(job.state.rawValue)",
            reviewSHA256: job.reviewSHA256,
            failureMessageKey: job.failureMessageKey,
            emittedAt: job.updatedAt
        )
        modelSyncEvents[job.id, default: []].append(event)
    }

    func catalogStatus() -> ProviderCatalogStatus {
        catalog
    }

    func prepareCatalogImport(
        envelopeJSON: Data
    ) throws -> ProviderCatalogImportPlan {
        guard !envelopeJSON.isEmpty else {
            throw CoreClientFailure.invalidResponse(
                "서명 카탈로그 파일이 비어 있습니다."
            )
        }
        let actionID =
            "preview-catalog-\(UUID().uuidString.lowercased())"
        let fromRevision = catalog.currentRevision ?? 0
        let candidateRevision = fromRevision + 1
        let diff = ProviderCatalogDiff(
            schemaVersion: 1,
            fromRevision: fromRevision,
            toRevision: candidateRevision,
            manifestChanges: [
                ProviderCatalogManifestChange(
                    providerTemplateID: "openai-v1",
                    change: .updated,
                    previousManifestVersion: 1,
                    nextManifestVersion: 2,
                    changedSections: ["parameters"]
                ),
            ],
            modelChanges: [
                ProviderCatalogModelChange(
                    modelEntryID: "preview-model-2",
                    providerTemplateID: "openai-v1",
                    change: .added,
                    previousMetadataVersion: nil,
                    nextMetadataVersion: 1,
                    changedSections: []
                ),
            ]
        )
        let review = ProviderCatalogImportReview(
            planSchemaVersion: 1,
            actionID: actionID,
            expectedStateVersion: fromRevision,
            expectedActiveRevision: fromRevision,
            expectedActiveSnapshotSHA256:
                String(repeating: "0", count: 64),
            expectedHighestAcceptedRevision: fromRevision,
            envelopeByteCount: UInt64(envelopeJSON.count),
            envelopeSHA256: String(repeating: "a", count: 64),
            signingKeyID: "lorepia-preview-catalog-key",
            payloadSHA256: String(repeating: "b", count: 64),
            signedCatalogRevision: candidateRevision,
            candidateRevision: candidateRevision,
            candidateSnapshotSHA256:
                String(repeating: "c", count: 64),
            preparedAt: timestamp,
            expiresAt: "2026-07-31T01:00:00Z",
            diff: diff
        )
        pendingCatalogImports[actionID] = envelopeJSON
        return ProviderCatalogImportPlan(
            review: review,
            planSHA256: String(repeating: "d", count: 64),
            opaquePlanJSON: "{}"
        )
    }

    func activateCatalogImport(
        plan: ProviderCatalogImportPlan,
        envelopeJSON: Data
    ) throws -> ProviderCatalogImportResult {
        guard pendingCatalogImports[plan.review.actionID]
            == envelopeJSON,
            UInt64(envelopeJSON.count)
                == plan.review.envelopeByteCount,
            catalog.currentRevision
                == plan.review.expectedActiveRevision
        else {
            throw CoreClientFailure.invalidResponse(
                "검토한 파일 또는 현재 카탈로그 상태가 변경되었습니다."
            )
        }
        pendingCatalogImports.removeValue(
            forKey: plan.review.actionID
        )
        let activation = ProviderCatalogActivation(
            id: plan.review.actionID,
            revision: plan.review.candidateRevision,
            source: "signed_catalog",
            signer: plan.review.signingKeyID,
            activatedAt: timestamp,
            isCurrent: true,
            summary:
                "서명 카탈로그 r\(plan.review.candidateRevision)"
        )
        catalog = ProviderCatalogStatus(
            schemaVersion: catalog.schemaVersion,
            currentRevision: plan.review.candidateRevision,
            currentSource: "signed_catalog",
            verifiedSigner: plan.review.signingKeyID,
            updatedAt: timestamp,
            history: [activation] + catalog.history.map { item in
                ProviderCatalogActivation(
                    id: item.id,
                    revision: item.revision,
                    source: item.source,
                    signer: item.signer,
                    activatedAt: item.activatedAt,
                    isCurrent: false,
                    summary: item.summary
                )
            }
        )
        return ProviderCatalogImportResult(
            signedCatalogRevision:
                plan.review.signedCatalogRevision,
            activatedRevision: plan.review.candidateRevision,
            diff: plan.review.diff,
            status: catalog
        )
    }

    func prepareCatalogRollback(
        targetRevision: UInt64
    ) throws -> ProviderCatalogRollbackPlan {
        guard let fromRevision = catalog.currentRevision,
              fromRevision != targetRevision,
              catalog.history.contains(where: {
                  $0.revision == targetRevision
              })
        else {
            throw CoreClientFailure.invalidResponse(
                "되돌릴 카탈로그 기록을 찾지 못했습니다."
            )
        }
        let actionID =
            "preview-catalog-rollback-\(UUID().uuidString.lowercased())"
        let plan = ProviderCatalogRollbackPlan(
            planSchemaVersion: 1,
            actionID: actionID,
            expectedStateVersion:
                UInt64(catalog.history.count),
            planSHA256: String(repeating: "e", count: 64),
            fromRevision: fromRevision,
            toRevision: targetRevision,
            createdAt: timestamp,
            expiresAt: "2026-08-02T00:00:00Z",
            diff: ProviderCatalogDiff(
                schemaVersion: 1,
                fromRevision: fromRevision,
                toRevision: targetRevision,
                manifestChanges: [],
                modelChanges: []
            ),
            opaquePlanJSON:
                "{\"action_id\":\"\(actionID)\"}"
        )
        pendingCatalogRollbacks[actionID] = plan
        return plan
    }

    func activateCatalogRollback(
        plan: ProviderCatalogRollbackPlan
    ) throws -> ProviderCatalogRollbackResult {
        guard pendingCatalogRollbacks[plan.actionID] == plan,
              catalog.currentRevision == plan.fromRevision,
              UInt64(catalog.history.count)
                == plan.expectedStateVersion,
              catalog.history.contains(where: {
                  $0.revision == plan.toRevision
              })
        else {
            throw CoreClientFailure.invalidResponse(
                "검토한 롤백 계획 또는 현재 카탈로그 상태가 변경되었습니다."
            )
        }
        pendingCatalogRollbacks.removeValue(
            forKey: plan.actionID
        )
        let target = catalog.history.first {
            $0.revision == plan.toRevision
        }
        catalog = ProviderCatalogStatus(
            schemaVersion: catalog.schemaVersion,
            currentRevision: plan.toRevision,
            currentSource: "rollback",
            verifiedSigner: target?.signer,
            updatedAt: timestamp,
            history: catalog.history.map { item in
                ProviderCatalogActivation(
                    id: item.id,
                    revision: item.revision,
                    source: item.source,
                    signer: item.signer,
                    activatedAt: item.activatedAt,
                    isCurrent:
                        item.revision == plan.toRevision,
                    summary: item.summary
                )
            }
        )
        return ProviderCatalogRollbackResult(
            fromRevision: plan.fromRevision,
            activatedRevision: plan.toRevision,
            status: catalog
        )
    }

    func requestPreview(
        routeID: String,
        presetID: String
    ) throws -> ProviderRequestPreview {
        guard let preset = presetsByRoute[routeID]?.first(where: {
            $0.id == presetID
        }) else {
            throw CoreClientFailure.invalidResponse(
                "요청 미리보기에 사용할 프리셋을 찾지 못했습니다."
            )
        }
        try validatePresetCandidate(preset)
        return try requestPreview(candidate: preset)
    }

    func requestPreview(
        candidate: ProviderGenerationPreset
    ) throws -> ProviderRequestPreview {
        try validatePresetCandidate(candidate)
        previewedPresetCandidates.append(candidate)
        return ProviderRequestPreview(
            redactionVersion: 1,
            method: "POST",
            origin: "https://example.invalid",
            path: "/v1/chat/completions",
            headerNames: ["Authorization", "Content-Type"],
            bodyShapeJSON:
                #"{"kind":"object","fields":[{"name":"messages","shape":{"kind":"redacted"}},{"name":"model","shape":{"kind":"string"}},{"name":"stream","shape":{"kind":"boolean"}}],"truncated":false}"#,
            bodyTruncated: false,
            includesPrivateMessage: false,
            includesCredentialValue: false,
            includesOpaqueReasoningState: false
        )
    }

    func previewCandidatesForTesting()
        -> [ProviderGenerationPreset]
    {
        previewedPresetCandidates
    }

    private func validate(
        literal: ProviderParameterLiteral,
        against spec: ProviderParameterSpec
    ) throws {
        let numericValue: Double?
        switch (spec.type, literal) {
        case (.boolean, .boolean),
             (.string, .string),
             (.stringList, .stringList),
             (.jsonSchema, .jsonSchema),
             (.stopSequenceList, .stopSequenceList),
             (.toolPolicy, .toolPolicy):
            numericValue = nil
        case let (.integer, .integer(value)):
            numericValue = Double(value)
        case let (.number, .number(value)):
            numericValue = value
        case let (.enumeration, .enumeration(value)):
            guard spec.choices.isEmpty || spec.choices.contains(where: {
                $0.value == .enumeration(value)
            }) else {
                throw CoreClientFailure.invalidResponse(
                    "\(spec.label)의 선택 값이 지원되지 않습니다."
                )
            }
            numericValue = nil
        default:
            throw CoreClientFailure.invalidResponse(
                "\(spec.label)의 값 형식이 올바르지 않습니다."
            )
        }

        if let numericValue,
           let minimum = spec.minimum,
           numericValue < minimum
        {
            throw CoreClientFailure.invalidResponse(
                "\(spec.label)은(는) \(minimum) 이상이어야 합니다."
            )
        }
        if let numericValue,
           let maximum = spec.maximum,
           numericValue > maximum
        {
            throw CoreClientFailure.invalidResponse(
                "\(spec.label)은(는) \(maximum) 이하여야 합니다."
            )
        }
    }

    private func sanitizedOrigin(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return "https://example.invalid"
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = ""
        return components.url?.absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            ?? "https://example.invalid"
    }

    private func credentialApproval(
        origin: String
    ) -> ProviderCredentialOriginApproval {
        ProviderCredentialOriginApproval(
            approvalID:
                "origin-\(origin.replacingOccurrences(of: "/", with: "_"))",
            origin: origin,
            authDescription: "Authorization 헤더",
            manifestSHA256: String(repeating: "a", count: 64)
        )
    }

    private func initialSteps(active: String) -> [ProviderDiscoveryStep] {
        let definitions = [
            ("site", "사이트 확인"),
            ("documents", "공식 문서 발견"),
            ("origin", "API 서버 후보 확인"),
            ("auth", "인증 방식 확인"),
            ("models", "사용 가능한 모델 확인"),
            ("probes", "기능 검사"),
        ]
        guard let activeIndex = definitions.firstIndex(where: {
            $0.0 == active
        }) else {
            return completedSteps()
        }
        return definitions.enumerated().map { index, item in
            ProviderDiscoveryStep(
                id: item.0,
                title: item.1,
                source: index < activeIndex ? "결정론적 탐색" : nil,
                state: index < activeIndex
                    ? .complete
                    : (index == activeIndex ? .active : .pending)
            )
        }
    }

    private func completedSteps() -> [ProviderDiscoveryStep] {
        [
            ProviderDiscoveryStep(
                id: "site",
                title: "사이트 확인",
                source: "결정론적 탐색",
                state: .complete
            ),
            ProviderDiscoveryStep(
                id: "documents",
                title: "공식 문서 발견",
                source: "결정론적 탐색",
                state: .complete
            ),
            ProviderDiscoveryStep(
                id: "origin",
                title: "API 서버 후보 확인",
                source: "결정론적 탐색",
                state: .complete
            ),
            ProviderDiscoveryStep(
                id: "auth",
                title: "인증 방식 확인",
                source: "결정론적 탐색",
                state: .complete
            ),
            ProviderDiscoveryStep(
                id: "models",
                title: "사용 가능한 모델 확인",
                source: "실제 models API",
                state: .complete
            ),
            ProviderDiscoveryStep(
                id: "probes",
                title: "기능 검사",
                source: "사용자 승인",
                state: .complete
            ),
        ]
    }

    private func reviewDiscovery(
        _ record: DiscoveryRecord,
        revision: UInt64,
        probesApproved: Bool
    ) -> ProviderDiscoverySnapshot {
        let review = ProviderDiscoveryReview(
            sha256: String(repeating: "c", count: 64),
            graphSHA256: String(repeating: "g", count: 64),
            changes: [
                ProviderReviewChange(
                    id: "connection",
                    kind: .add,
                    targetKind: "provider_connection",
                    title: "연결: \(record.displayName)",
                    detail: record.apiOrigin
                ),
                ProviderReviewChange(
                    id: "model",
                    kind: .add,
                    targetKind: "model_route",
                    title: "새 모델: example-chat",
                    detail: "실제 models API에서 확인"
                ),
            ],
            unresolvedQuestionCount: probesApproved ? 0 : 1,
            warningCount: probesApproved ? 0 : 1,
            requestPreview: ProviderRequestPreview(
                redactionVersion: 1,
                method: "GET",
                origin: record.apiOrigin,
                path: "/v1/models",
                headerNames: ["Authorization"],
                bodyShapeJSON: nil,
                bodyTruncated: false,
                includesPrivateMessage: false,
                includesCredentialValue: false,
                includesOpaqueReasoningState: false
            )
        )
        let proposal = ProviderDiscoveryReviewProposal(
            approvalID: "review-\(record.snapshot.id)",
            grantSHA256: String(repeating: "d", count: 64),
            commitAttemptID: "attempt-\(record.snapshot.id)",
            commitPlanSHA256: String(repeating: "p", count: 64),
            review: review
        )
        return snapshot(
            from: record,
            revision: revision,
            state: .awaitingReview,
            actionRequired: .review,
            steps: completedSteps(),
            review: review,
            reviewProposal: proposal,
            warnings: probesApproved
                ? record.snapshot.warnings
                : record.snapshot.warnings
                    + ["비용이 드는 기능 검사를 건너뛰었습니다."]
        )
    }

    private func cancelledDiscovery(
        _ snapshot: ProviderDiscoverySnapshot,
        revision: UInt64
    ) -> ProviderDiscoverySnapshot {
        ProviderDiscoverySnapshot(
            schemaVersion: snapshot.schemaVersion,
            id: snapshot.id,
            pendingConnectionID: snapshot.pendingConnectionID,
            pendingDisplayName: snapshot.pendingDisplayName,
            connectionOptions: snapshot.connectionOptions,
            credentialSlotID: snapshot.credentialSlotID,
            credentialSlotExpected: snapshot.credentialSlotExpected,
            revision: revision,
            nextEventSequence: snapshot.nextEventSequence + 1,
            state: .cancelled,
            steps: snapshot.steps,
            actionRequired: nil,
            manifestSHA256: snapshot.manifestSHA256,
            commitPlanSHA256: snapshot.commitPlanSHA256,
            commitAttemptID: snapshot.commitAttemptID,
            candidates: snapshot.candidates,
            evidence: snapshot.evidence,
            review: snapshot.review,
            reviewProposal: snapshot.reviewProposal,
            assistantApprovalBinding:
                snapshot.assistantApprovalBinding,
            assistantResumeBoundary: nil,
            warnings: snapshot.warnings,
            createdAt: snapshot.createdAt,
            updatedAt: timestamp
        )
    }

    private func snapshot(
        from record: DiscoveryRecord,
        revision: UInt64,
        state: ProviderDiscoveryState,
        actionRequired: ProviderDiscoveryActionRequired?,
        steps: [ProviderDiscoveryStep],
        committedConnectionID: String? = nil,
        review: ProviderDiscoveryReview? = nil,
        reviewProposal: ProviderDiscoveryReviewProposal? = nil,
        assistantResumeBoundary:
            ProviderDiscoveryAssistantResumeBoundary? = nil,
        warnings: [String]? = nil
    ) -> ProviderDiscoverySnapshot {
        ProviderDiscoverySnapshot(
            schemaVersion: record.snapshot.schemaVersion,
            id: record.snapshot.id,
            pendingConnectionID: record.connectionID,
            pendingDisplayName: record.displayName,
            connectionOptions:
                record.snapshot.connectionOptions,
            credentialSlotID: record.hasCredential
                ? record.connectionID
                : nil,
            credentialSlotExpected: record.hasCredential,
            revision: revision,
            nextEventSequence:
                record.snapshot.nextEventSequence + 1,
            state: state,
            steps: steps,
            actionRequired: actionRequired,
            manifestSHA256:
                record.snapshot.manifestSHA256
                    ?? String(repeating: "m", count: 64),
            commitPlanSHA256:
                reviewProposal?.commitPlanSHA256
                    ?? record.snapshot.commitPlanSHA256,
            commitAttemptID:
                reviewProposal?.commitAttemptID
                    ?? record.snapshot.commitAttemptID,
            committedConnectionID: committedConnectionID,
            candidates: record.snapshot.candidates,
            evidence: record.snapshot.evidence,
            review: review ?? record.snapshot.review,
            reviewProposal:
                reviewProposal ?? record.snapshot.reviewProposal,
            assistantApprovalBinding:
                record.snapshot.assistantApprovalBinding,
            assistantResumeBoundary: assistantResumeBoundary,
            warnings: warnings ?? record.snapshot.warnings,
            createdAt: record.snapshot.createdAt,
            updatedAt: timestamp
        )
    }

    private func discoverySnapshot(
        record: DiscoveryRecord,
        revision: UInt64,
        state: ProviderDiscoveryState,
        evidence: [ProviderDiscoveryEvidence],
        assistantResumeBoundary:
            ProviderDiscoveryAssistantResumeBoundary?
    ) -> ProviderDiscoverySnapshot {
        let current = record.snapshot
        return ProviderDiscoverySnapshot(
            schemaVersion: current.schemaVersion,
            id: current.id,
            pendingConnectionID: current.pendingConnectionID,
            pendingDisplayName: current.pendingDisplayName,
            connectionOptions: current.connectionOptions,
            credentialSlotID: current.credentialSlotID,
            credentialSlotExpected: current.credentialSlotExpected,
            revision: revision,
            nextEventSequence: current.nextEventSequence + 1,
            state: state,
            steps: initialSteps(active: "documents"),
            actionRequired: nil,
            activeOperationID: current.activeOperationID,
            recoveryOperation: current.recoveryOperation,
            unknownOperation: current.unknownOperation,
            manifestSHA256: current.manifestSHA256,
            commitPlanSHA256: current.commitPlanSHA256,
            commitAttemptID: current.commitAttemptID,
            committedConnectionID: current.committedConnectionID,
            cancellationPending: current.cancellationPending,
            candidates: current.candidates,
            evidence: evidence,
            review: current.review,
            reviewProposal: current.reviewProposal,
            assistantApprovalBinding:
                current.assistantApprovalBinding,
            assistantResumeBoundary: assistantResumeBoundary,
            unknownOutcomeProposal:
                current.unknownOutcomeProposal,
            warnings: current.warnings,
            failureMessageKey: current.failureMessageKey,
            createdAt: current.createdAt,
            updatedAt: timestamp
        )
    }

    private func appendDiscoveryEvent(
        for snapshot: ProviderDiscoverySnapshot
    ) {
        let sequence =
            discoveryOutbox
                .filter { $0.event.sessionID == snapshot.id }
                .map(\.event.sequence)
                .max() ?? 0
        let event = ProviderDiscoveryEvent(
            version:
                CoreRuntimeContract
                    .providerDiscoveryEventVersion,
            id: "preview-discovery-event-\(UUID().uuidString.lowercased())",
            sessionID: snapshot.id,
            sequence: sequence + 1,
            sessionRevision: snapshot.revision,
            state: snapshot.state,
            progress: nil,
            actionID: "preview-discovery-action",
            warning: snapshot.warnings.last,
            failureMessageKey: snapshot.failureMessageKey
        )
        discoveryOutbox.append(
            ProviderDiscoveryOutboxEvent(
                event: event,
                deliveryAttempts: 0,
                availableAt: timestamp,
                createdAt: timestamp
            )
        )
    }
}

private extension ProviderDiscoveryAction {
    var requiresTargetCredential: Bool {
        switch self {
        case .approveCredentialOrigin, .approveProbes:
            true
        default:
            false
        }
    }
}

public extension FakeCoreClient {
    func providerPreviewCandidatesForTesting() async
        -> [ProviderGenerationPreset]
    {
        await providerFeatures.previewCandidatesForTesting()
    }

    func listProviderTemplates() async throws
        -> [ProviderTemplateDescriptor]
    {
        await providerFeatures.listTemplates()
    }

    func listProviderConnections() async throws
        -> [ProviderConnectionRecord]
    {
        await providerFeatures.listConnections()
    }

    func deleteProviderConnection(id: String) async throws {
        let routeIDs = try await providerFeatures.deleteConnection(id: id)
        clearProviderGenerationSelection(
            deletingConnectionID: id,
            modelRouteIDs: routeIDs
        )
    }

    func listProviderModelRoutes(
        connectionID: String
    ) async throws -> [ProviderModelRoute] {
        await providerFeatures.listRoutes(connectionID: connectionID)
    }

    func listProviderGenerationPresets(
        modelRouteID: String
    ) async throws -> [ProviderGenerationPreset] {
        await providerFeatures.listPresets(routeID: modelRouteID)
    }

    func upsertProviderGenerationPreset(
        _ preset: ProviderGenerationPreset
    ) async throws -> ProviderGenerationPreset {
        try await providerFeatures.upsertPreset(preset)
    }

    func validateProviderGenerationPreset(
        modelRouteID: String,
        generationPresetID: String
    ) async throws {
        try await providerFeatures.validatePreset(
            routeID: modelRouteID,
            presetID: generationPresetID
        )
    }

    func validateProviderGenerationPresetCandidate(
        _ preset: ProviderGenerationPreset
    ) async throws {
        try await providerFeatures.validatePresetCandidate(preset)
    }

    func renderProviderReasoningControl(
        for preset: ProviderGenerationPreset
    ) async throws -> ProviderReasoningControl {
        try await providerFeatures.reasoningControl(for: preset)
    }

    func renderProviderPromptCacheControl(
        for preset: ProviderGenerationPreset
    ) async throws -> ProviderPromptCacheControl {
        try await providerFeatures.promptCacheControl(for: preset)
    }

    func deleteProviderGenerationPreset(id: String) async throws {
        let routeID = try await providerFeatures.deletePreset(id: id)
        clearProviderGenerationSelection(
            deletingPresetID: id,
            modelRouteID: routeID
        )
    }

    func listProviderCapabilities(
        modelRouteID: String
    ) async throws -> [ProviderEffectiveCapability] {
        await providerFeatures.listCapabilities(routeID: modelRouteID)
    }

    func listProviderParameterSpecs(
        modelRouteID: String
    ) async throws -> [ProviderParameterSpec] {
        await providerFeatures.listParameterSpecs(routeID: modelRouteID)
    }

    func inspectProviderCurl(
        _ rawCurl: String,
        networkPolicy: ProviderNetworkPolicy
    ) async throws -> ProviderCurlInspection {
        try await providerFeatures.inspectCurl(
            rawCurl,
            networkPolicy: networkPolicy
        )
    }

    func takeProviderCurlCredential(
        handoffID: String
    ) async throws -> Data? {
        await providerFeatures.takeCurlCredential(
            handoffID: handoffID
        )
    }

    func beginProviderDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.beginDiscovery(
            input: input,
            source: source,
            rawCurl: rawCurl
        )
    }

    func prepareProviderDiscoveryAction(
        actionID: String,
        expectedRevision: UInt64,
        action: ProviderDiscoveryAction
    ) async throws -> ProviderDiscoveryActionEnvelope {
        try await providerFeatures.prepareDiscoveryAction(
            actionID: actionID,
            expectedRevision: expectedRevision,
            action: action
        )
    }

    func continueProviderDiscovery(
        sessionID: String,
        envelope: ProviderDiscoveryActionEnvelope,
        targetCredential: String?
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.continueDiscovery(
            id: sessionID,
            envelope: envelope,
            hasTargetCredential: targetCredential != nil
        )
    }

    func supplyProviderDiscoveryDocumentEvidence(
        sessionID: String,
        expectedRevision: UInt64,
        documentURL: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.supplyDocumentEvidence(
            id: sessionID,
            expectedRevision: expectedRevision,
            documentURL: documentURL
        )
    }

    func supplyProviderDiscoveryCurlEvidence(
        sessionID: String,
        expectedRevision: UInt64,
        redactedCurl: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.supplyCurlEvidence(
            id: sessionID,
            expectedRevision: expectedRevision,
            redactedCurl: redactedCurl
        )
    }

    func runProviderDiscoveryAssistantTurn(
        sessionID: String,
        estimate: ProviderDiscoveryAssistantCallEstimate,
        assistantCredential _: String?
    ) async throws -> ProviderDiscoveryAssistantHostAction {
        try await providerFeatures.runAssistantTurn(
            id: sessionID,
            estimate: estimate
        )
    }

    func resumeProviderDiscoveryAssistantCoreHostAction(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.resumeAssistantCoreHostAction(
            id: sessionID
        )
    }

    func approveProviderDiscoveryAssistantRetry(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.approveAssistantRetry(
            id: sessionID
        )
    }

    func requestProviderDiscoveryAssistantRevision(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.requestAssistantRevision(
            id: sessionID
        )
    }

    func acceptProviderDiscoveryAssistantDraft(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.acceptAssistantDraft(
            id: sessionID
        )
    }

    func recordProviderDiscoveryAssistantFailure(
        sessionID: String,
        kind _: String,
        retryable: Bool
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.recordAssistantFailure(
            id: sessionID,
            retryable: retryable
        )
    }

    func getProviderDiscovery(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.getDiscovery(id: sessionID)
    }

    func listProviderDiscoveries(
        limit: UInt32
    ) async throws -> [ProviderDiscoverySnapshot] {
        await providerFeatures.listDiscoveries(limit: limit)
    }

    func cancelProviderDiscovery(
        sessionID: String,
        expectedRevision: UInt64
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.cancelDiscovery(
            id: sessionID,
            expectedRevision: expectedRevision
        )
    }

    func commitProviderDiscovery(
        sessionID: String,
        credentialSlotConfirmed: Bool
    ) async throws -> ProviderConnectionRecord {
        try await providerFeatures.commitDiscovery(
            id: sessionID,
            credentialSlotConfirmed: credentialSlotConfirmed
        )
    }

    func listProviderDiscoveryCompensationSteps(
        commitAttemptID: String
    ) async throws -> [ProviderDiscoveryCompensationStep] {
        await providerFeatures.listCompensationSteps(
            commitAttemptID: commitAttemptID
        )
    }

    func continueProviderDiscoveryCompensation(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.continueCompensation(
            id: sessionID
        )
    }

    func startProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoveryCompensationStep {
        try await providerFeatures.startCredentialCompensation(
            id: sessionID,
            stepID: stepID
        )
    }

    func completeProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.finishCredentialCompensation(
            id: sessionID,
            stepID: stepID,
            status: .completed
        )
    }

    func failProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String,
        failure: ProviderDiscoveryFailure
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.finishCredentialCompensation(
            id: sessionID,
            stepID: stepID,
            status: .failed,
            failure: failure
        )
    }

    func markProviderDiscoveryCredentialCompensationUnknown(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.finishCredentialCompensation(
            id: sessionID,
            stepID: stepID,
            status: .outcomeUnknown
        )
    }

    func resumeProviderDiscoveryCompensation(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try await providerFeatures.resumeCompensation(
            id: sessionID
        )
    }

    func recoverProviderDiscoveries() async throws
        -> [ProviderDiscoveryRecoveryResult]
    {
        await providerFeatures.recoverDiscoveries()
    }

    func pollProviderDiscoveryEvents(
        limit: UInt32
    ) async throws -> [ProviderDiscoveryOutboxEvent] {
        await providerFeatures.pollDiscoveryEvents(limit: limit)
    }

    func ackProviderDiscoveryEvent(
        eventID: String
    ) async throws -> Bool {
        await providerFeatures.ackDiscoveryEvent(id: eventID)
    }

    func startProviderModelSync(
        connectionID: String,
        credential _: String?
    ) async throws -> ProviderModelSyncJob {
        try await providerFeatures.startModelSync(
            connectionID: connectionID
        )
    }

    func getProviderModelSync(
        jobID: String
    ) async throws -> ProviderModelSyncJob {
        try await providerFeatures.modelSync(id: jobID)
    }

    func listProviderModelSyncs(
        connectionID: String,
        limit: UInt32
    ) async throws -> [ProviderModelSyncJob] {
        await providerFeatures.listModelSyncs(
            connectionID: connectionID,
            limit: limit
        )
    }

    func pollProviderModelSyncEvents(
        jobID: String,
        limit: UInt32
    ) async throws -> [ProviderModelSyncEvent] {
        try await providerFeatures.pollModelSyncEvents(
            id: jobID,
            limit: limit
        )
    }

    func ackProviderModelSyncEvent(
        jobID: String,
        sequence: UInt64
    ) async throws -> Bool {
        try await providerFeatures.ackModelSyncEvent(
            id: jobID,
            sequence: sequence
        )
    }

    func approveProviderModelSync(
        jobID: String,
        expectedRevision: UInt64,
        reviewSHA256: String
    ) async throws -> ProviderModelSyncJob {
        try await providerFeatures.approveModelSync(
            id: jobID,
            expectedRevision: expectedRevision,
            sha256: reviewSHA256
        )
    }

    func cancelProviderModelSync(
        jobID: String,
        expectedRevision: UInt64
    ) async throws -> ProviderModelSyncJob {
        try await providerFeatures.cancelModelSync(
            id: jobID,
            expectedRevision: expectedRevision
        )
    }

    func getProviderCatalogStatus() async throws
        -> ProviderCatalogStatus
    {
        await providerFeatures.catalogStatus()
    }

    func prepareSignedProviderCatalogImport(
        envelopeJSON: Data
    ) async throws -> ProviderCatalogImportPlan {
        try await providerFeatures.prepareCatalogImport(
            envelopeJSON: envelopeJSON
        )
    }

    func activateSignedProviderCatalogImport(
        plan: ProviderCatalogImportPlan,
        envelopeJSON: Data
    ) async throws -> ProviderCatalogImportResult {
        try await providerFeatures.activateCatalogImport(
            plan: plan,
            envelopeJSON: envelopeJSON
        )
    }

    func prepareProviderCatalogRollback(
        targetRevision: UInt64
    ) async throws -> ProviderCatalogRollbackPlan {
        try await providerFeatures.prepareCatalogRollback(
            targetRevision: targetRevision
        )
    }

    func activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlan
    ) async throws -> ProviderCatalogRollbackResult {
        try await providerFeatures.activateCatalogRollback(
            plan: plan
        )
    }

    func previewProviderRequest(
        modelRouteID: String,
        generationPresetID: String
    ) async throws -> ProviderRequestPreview {
        try await providerFeatures.requestPreview(
            routeID: modelRouteID,
            presetID: generationPresetID
        )
    }

    func previewProviderRequestCandidate(
        _ preset: ProviderGenerationPreset
    ) async throws -> ProviderRequestPreview {
        try await providerFeatures.requestPreview(candidate: preset)
    }
}
