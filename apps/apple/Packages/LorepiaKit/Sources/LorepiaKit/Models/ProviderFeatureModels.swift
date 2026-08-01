import Foundation

public enum ProviderConnectionFieldType: String, Sendable {
    case text
    case integer
    case boolean
    case credential
}

public struct ProviderConnectionField: Identifiable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let description: String?
    public let type: ProviderConnectionFieldType
    public let isRequired: Bool

    public var id: String { key }

    public init(
        key: String,
        label: String,
        description: String? = nil,
        type: ProviderConnectionFieldType,
        isRequired: Bool
    ) {
        self.key = key
        self.label = label
        self.description = description
        self.type = type
        self.isRequired = isRequired
    }
}

public enum ProviderConfigurationValue: Equatable, Sendable {
    case text(String)
    case integer(Int64)
    case boolean(Bool)
}

public struct ProviderConfigurationEntry: Identifiable, Equatable, Sendable {
    public let key: String
    public var value: ProviderConfigurationValue

    public var id: String { key }

    public init(key: String, value: ProviderConfigurationValue) {
        self.key = key
        self.value = value
    }
}

public enum ProviderParameterType: String, Sendable {
    case boolean
    case integer
    case number
    case string
    case enumeration
    case stringList
    case jsonSchema
    case stopSequenceList
    case toolPolicy
}

public enum ProviderParameterLiteral: Equatable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case enumeration(String)
    case stringList([String])
    case jsonSchema(String)
    case stopSequenceList([String])
    case toolPolicy(String)

    public var displayValue: String {
        switch self {
        case let .boolean(value):
            value ? "켜짐" : "꺼짐"
        case let .integer(value):
            String(value)
        case let .number(value):
            String(value)
        case let .string(value), let .enumeration(value),
             let .jsonSchema(value), let .toolPolicy(value):
            value
        case let .stringList(values), let .stopSequenceList(values):
            values.joined(separator: ", ")
        }
    }
}

public enum ProviderParameterValueState: Equatable, Sendable {
    case providerDefault
    case explicit(ProviderParameterLiteral)
}

public struct ProviderParameterValue: Identifiable, Equatable, Sendable {
    public let parameterID: String
    public var state: ProviderParameterValueState

    public var id: String { parameterID }

    public init(
        parameterID: String,
        state: ProviderParameterValueState
    ) {
        self.parameterID = parameterID
        self.state = state
    }
}

public struct ProviderParameterChoice: Identifiable, Equatable, Sendable {
    public let value: ProviderParameterLiteral
    public let label: String

    public var id: String { "\(label):\(value.displayValue)" }

    public init(value: ProviderParameterLiteral, label: String) {
        self.value = value
        self.label = label
    }
}

public enum ProviderParameterDefaultMode: String, Sendable {
    case providerDefault
    case explicitRequired
}

public enum ProviderParameterLevel: String, Sendable {
    case basic
    case advanced
    case expert
    case hidden
}

public enum ProviderParameterConditionOperator: String, Sendable {
    case equals
    case notEquals
}

public struct ProviderParameterCondition: Equatable, Sendable {
    public let parameterID: String
    public let conditionOperator: ProviderParameterConditionOperator
    public let value: ProviderParameterLiteral

    public init(
        parameterID: String,
        conditionOperator: ProviderParameterConditionOperator,
        value: ProviderParameterLiteral
    ) {
        self.parameterID = parameterID
        self.conditionOperator = conditionOperator
        self.value = value
    }
}

public enum ProviderParameterConflictKind: String, Sendable {
    case mutuallyExclusive
    case requires
}

public struct ProviderParameterConflict: Equatable, Sendable {
    public let parameterID: String
    public let kind: ProviderParameterConflictKind
    public let message: String

    public init(
        parameterID: String,
        kind: ProviderParameterConflictKind,
        message: String
    ) {
        self.parameterID = parameterID
        self.kind = kind
        self.message = message
    }
}

public enum ProviderParameterTarget: String, Sendable {
    case requestBody
    case requestHeader
}

public enum ProviderNetworkMode: String, Equatable, Sendable {
    case publicInternet = "public"
    case localLoopback = "local_loopback"
    case approvedLocalNetwork = "approved_local_network"
}

public struct ProviderLocalNetworkApproval: Equatable, Sendable {
    public let origin: String
    public let addresses: [String]

    public init(origin: String, addresses: [String]) {
        self.origin = origin
        self.addresses = addresses
    }
}

public struct ProviderNetworkPolicy: Equatable, Sendable {
    public let mode: ProviderNetworkMode
    public let localNetworkApproval: ProviderLocalNetworkApproval?

    public init(
        mode: ProviderNetworkMode,
        localNetworkApproval: ProviderLocalNetworkApproval? = nil
    ) {
        self.mode = mode
        self.localNetworkApproval = localNetworkApproval
    }
}

public struct ProviderParameterMapping: Equatable, Sendable {
    public let target: ProviderParameterTarget
    public let fieldName: String

    public init(
        target: ProviderParameterTarget,
        fieldName: String
    ) {
        self.target = target
        self.fieldName = fieldName
    }
}

public struct ProviderParameterSpec: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let description: String?
    public let type: ProviderParameterType
    public let choices: [ProviderParameterChoice]
    public let minimum: Double?
    public let maximum: Double?
    public let step: Double?
    public let defaultMode: ProviderParameterDefaultMode
    public let visibility: ProviderParameterCondition?
    public let conflicts: [ProviderParameterConflict]
    public let providerMapping: ProviderParameterMapping?
    public let level: ProviderParameterLevel

    public init(
        id: String,
        label: String,
        description: String? = nil,
        type: ProviderParameterType,
        choices: [ProviderParameterChoice] = [],
        minimum: Double? = nil,
        maximum: Double? = nil,
        step: Double? = nil,
        defaultMode: ProviderParameterDefaultMode = .providerDefault,
        visibility: ProviderParameterCondition? = nil,
        conflicts: [ProviderParameterConflict] = [],
        providerMapping: ProviderParameterMapping? = nil,
        level: ProviderParameterLevel = .basic
    ) {
        self.id = id
        self.label = label
        self.description = description
        self.type = type
        self.choices = choices
        self.minimum = minimum
        self.maximum = maximum
        self.step = step
        self.defaultMode = defaultMode
        self.visibility = visibility
        self.conflicts = conflicts
        self.providerMapping = providerMapping
        self.level = level
    }
}

public struct ProviderTemplateDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let manifestVersion: UInt32
    public let source: String
    public let apiFamily: String
    public let defaultNetworkMode: ProviderNetworkMode
    public let defaultAPIOrigin: String?
    public let requiresCredential: Bool
    public let supportsModelListing: Bool
    public let connectionFields: [ProviderConnectionField]
    public let parameters: [ProviderParameterSpec]

    public init(
        id: String,
        displayName: String,
        manifestVersion: UInt32,
        source: String,
        apiFamily: String,
        defaultNetworkMode: ProviderNetworkMode = .publicInternet,
        defaultAPIOrigin: String?,
        requiresCredential: Bool,
        supportsModelListing: Bool,
        connectionFields: [ProviderConnectionField] = [],
        parameters: [ProviderParameterSpec] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.manifestVersion = manifestVersion
        self.source = source
        self.apiFamily = apiFamily
        self.defaultNetworkMode = defaultNetworkMode
        self.defaultAPIOrigin = defaultAPIOrigin
        self.requiresCredential = requiresCredential
        self.supportsModelListing = supportsModelListing
        self.connectionFields = connectionFields
        self.parameters = parameters
    }
}

public struct ProviderConnectionRecord: Identifiable, Equatable, Sendable {
    public let id: String
    public let templateID: String
    public let templateVersion: UInt32
    public var displayName: String
    public let apiOrigin: String
    public var apiBasePath: String?
    public let networkMode: String
    public let localNetworkApproval: ProviderLocalNetworkApproval?
    public var values: [ProviderConfigurationEntry]
    public let hasCredential: Bool
    public let approvedCredentialOrigins: [String]
    public var timeoutSeconds: UInt32
    public let status: String
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        templateID: String,
        templateVersion: UInt32,
        displayName: String,
        apiOrigin: String,
        apiBasePath: String? = nil,
        networkMode: String = "public",
        localNetworkApproval: ProviderLocalNetworkApproval? = nil,
        values: [ProviderConfigurationEntry] = [],
        hasCredential: Bool,
        approvedCredentialOrigins: [String],
        timeoutSeconds: UInt32,
        status: String,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.templateID = templateID
        self.templateVersion = templateVersion
        self.displayName = displayName
        self.apiOrigin = apiOrigin
        self.apiBasePath = apiBasePath
        self.networkMode = networkMode
        self.localNetworkApproval = localNetworkApproval
        self.values = values
        self.hasCredential = hasCredential
        self.approvedCredentialOrigins = approvedCredentialOrigins
        self.timeoutSeconds = timeoutSeconds
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ProviderModelAvailability: String, Sendable {
    case available
    case missingTemporarily = "missing_temporarily"
    case documentedOnly = "documented_only"
    case accessDenied = "access_denied"
    case deprecated
    case retired
    case unknown

    public var displayName: String {
        switch self {
        case .available: "사용 가능"
        case .missingTemporarily: "이번 조회에서 보이지 않음"
        case .documentedOnly: "문서에서만 확인"
        case .accessDenied: "접근 권한 없음"
        case .deprecated: "지원 종료 예정"
        case .retired: "사용 종료"
        case .unknown: "확인되지 않음"
        }
    }
}

public struct ProviderModelRoute: Identifiable, Equatable, Sendable {
    public let id: String
    public let connectionID: String
    public let apiFamily: String
    public let modelID: String
    public let displayName: String?
    public let deploymentID: String?
    public let region: String?
    public let endpointPath: String?
    public let availability: ProviderModelAvailability
    public let firstSeenAt: String
    public let lastSeenAt: String?
    public let missCount: UInt32
    public let metadataSource: String?
    public let metadataObservedAt: String?

    public init(
        id: String,
        connectionID: String,
        apiFamily: String,
        modelID: String,
        displayName: String?,
        deploymentID: String? = nil,
        region: String? = nil,
        endpointPath: String? = nil,
        availability: ProviderModelAvailability,
        firstSeenAt: String,
        lastSeenAt: String?,
        missCount: UInt32 = 0,
        metadataSource: String? = nil,
        metadataObservedAt: String? = nil
    ) {
        self.id = id
        self.connectionID = connectionID
        self.apiFamily = apiFamily
        self.modelID = modelID
        self.displayName = displayName
        self.deploymentID = deploymentID
        self.region = region
        self.endpointPath = endpointPath
        self.availability = availability
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.missCount = missCount
        self.metadataSource = metadataSource
        self.metadataObservedAt = metadataObservedAt
    }

    public var title: String {
        guard let candidate = displayName?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !candidate.isEmpty
        else {
            return modelID
        }
        return candidate
    }
}

public struct ProviderGenerationPreset: Identifiable, Equatable, Sendable {
    public let id: String
    public let modelRouteID: String
    public var displayName: String
    public var values: [ProviderParameterValue]
    public var reasoningMode: String
    public var reasoningEffort: String?
    public var reasoningBudgetTokens: UInt32?
    public var reasoningSummary: String
    public var preservesOpaqueReasoningState: Bool
    public var promptCacheMode: String
    public var promptCacheTTL: String
    public var promptCacheCustomTTLSeconds: UInt32?
    public var promptCacheContextReference: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        id: String,
        modelRouteID: String,
        displayName: String,
        values: [ProviderParameterValue] = [],
        reasoningMode: String = "provider_default",
        reasoningEffort: String? = nil,
        reasoningBudgetTokens: UInt32? = nil,
        reasoningSummary: String = "provider_default",
        preservesOpaqueReasoningState: Bool = false,
        promptCacheMode: String = "provider_default",
        promptCacheTTL: String = "provider_default",
        promptCacheCustomTTLSeconds: UInt32? = nil,
        promptCacheContextReference: String? = nil,
        createdAt: String,
        updatedAt: String
    ) {
        self.id = id
        self.modelRouteID = modelRouteID
        self.displayName = displayName
        self.values = values
        self.reasoningMode = reasoningMode
        self.reasoningEffort = reasoningEffort
        self.reasoningBudgetTokens = reasoningBudgetTokens
        self.reasoningSummary = reasoningSummary
        self.preservesOpaqueReasoningState = preservesOpaqueReasoningState
        self.promptCacheMode = promptCacheMode
        self.promptCacheTTL = promptCacheTTL
        self.promptCacheCustomTTLSeconds = promptCacheCustomTTLSeconds
        self.promptCacheContextReference = promptCacheContextReference
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ProviderUIControlState: String, Equatable, Sendable {
    case hidden
    case ready
    case invalid
}

public enum ProviderUIFieldState: String, Equatable, Sendable {
    case hidden
    case enabled
    case required

    public var isVisible: Bool {
        self != .hidden
    }
}

public struct ProviderParameterIssue: Identifiable, Equatable, Sendable {
    public let code: String
    public let parameterID: String?
    public let relatedParameterID: String?
    public let message: String

    public var id: String {
        [
            code,
            parameterID ?? "",
            relatedParameterID ?? "",
            message,
        ].joined(separator: "\u{001F}")
    }

    public init(
        code: String,
        parameterID: String?,
        relatedParameterID: String?,
        message: String
    ) {
        self.code = code
        self.parameterID = parameterID
        self.relatedParameterID = relatedParameterID
        self.message = message
    }
}

/// A render-ready control computed by Rust for one preset candidate.
///
/// The native UI renders these allowed values and field states verbatim. It
/// does not infer provider capabilities from model names or API families.
public struct ProviderReasoningControl: Equatable, Sendable {
    public let state: ProviderUIControlState
    public let mode: String
    public let effort: String?
    public let budgetTokens: UInt32?
    public let summary: String
    public let preservesOpaqueState: Bool
    public let allowedModes: [String]
    public let allowedEfforts: [String]
    public let allowedSummaries: [String]
    public let minimumBudgetTokens: UInt32?
    public let maximumBudgetTokens: UInt32?
    public let effortField: ProviderUIFieldState
    public let budgetField: ProviderUIFieldState
    public let summaryField: ProviderUIFieldState
    public let issues: [ProviderParameterIssue]

    public init(
        state: ProviderUIControlState,
        mode: String,
        effort: String?,
        budgetTokens: UInt32?,
        summary: String,
        preservesOpaqueState: Bool,
        allowedModes: [String],
        allowedEfforts: [String],
        allowedSummaries: [String],
        minimumBudgetTokens: UInt32?,
        maximumBudgetTokens: UInt32?,
        effortField: ProviderUIFieldState,
        budgetField: ProviderUIFieldState,
        summaryField: ProviderUIFieldState,
        issues: [ProviderParameterIssue]
    ) {
        self.state = state
        self.mode = mode
        self.effort = effort
        self.budgetTokens = budgetTokens
        self.summary = summary
        self.preservesOpaqueState = preservesOpaqueState
        self.allowedModes = allowedModes
        self.allowedEfforts = allowedEfforts
        self.allowedSummaries = allowedSummaries
        self.minimumBudgetTokens = minimumBudgetTokens
        self.maximumBudgetTokens = maximumBudgetTokens
        self.effortField = effortField
        self.budgetField = budgetField
        self.summaryField = summaryField
        self.issues = issues
    }
}

/// A render-ready provider prompt-cache control computed by Rust.
///
/// This is deliberately distinct from local response caches and model
/// residency caches.
public struct ProviderPromptCacheControl: Equatable, Sendable {
    public let state: ProviderUIControlState
    public let mode: String
    public let ttl: String
    public let customTTLSeconds: UInt32?
    public let contextReference: String?
    public let allowedModes: [String]
    public let allowedTTLs: [String]
    public let supportsCustomTTL: Bool
    public let minimumCustomTTLSeconds: UInt32?
    public let maximumCustomTTLSeconds: UInt32?
    public let ttlField: ProviderUIFieldState
    public let contextReferenceField: ProviderUIFieldState
    public let issues: [ProviderParameterIssue]

    public init(
        state: ProviderUIControlState,
        mode: String,
        ttl: String,
        customTTLSeconds: UInt32?,
        contextReference: String?,
        allowedModes: [String],
        allowedTTLs: [String],
        supportsCustomTTL: Bool,
        minimumCustomTTLSeconds: UInt32?,
        maximumCustomTTLSeconds: UInt32?,
        ttlField: ProviderUIFieldState,
        contextReferenceField: ProviderUIFieldState,
        issues: [ProviderParameterIssue]
    ) {
        self.state = state
        self.mode = mode
        self.ttl = ttl
        self.customTTLSeconds = customTTLSeconds
        self.contextReference = contextReference
        self.allowedModes = allowedModes
        self.allowedTTLs = allowedTTLs
        self.supportsCustomTTL = supportsCustomTTL
        self.minimumCustomTTLSeconds = minimumCustomTTLSeconds
        self.maximumCustomTTLSeconds = maximumCustomTTLSeconds
        self.ttlField = ttlField
        self.contextReferenceField = contextReferenceField
        self.issues = issues
    }
}

public struct ProviderGenerationTarget:
    Identifiable,
    Equatable,
    Hashable,
    Sendable
{
    public let modelRouteID: String
    public let generationPresetID: String

    public var id: String {
        "\(modelRouteID)\u{001F}\(generationPresetID)"
    }

    public init(
        modelRouteID: String,
        generationPresetID: String
    ) {
        self.modelRouteID = modelRouteID
        self.generationPresetID = generationPresetID
    }
}

public struct ProviderGenerationOption:
    Identifiable,
    Equatable,
    Sendable
{
    public let target: ProviderGenerationTarget
    public let connection: ProviderConnectionRecord
    public let route: ProviderModelRoute
    public let preset: ProviderGenerationPreset

    public var id: String { target.id }

    public init(
        connection: ProviderConnectionRecord,
        route: ProviderModelRoute,
        preset: ProviderGenerationPreset
    ) {
        precondition(route.connectionID == connection.id)
        precondition(preset.modelRouteID == route.id)
        target = ProviderGenerationTarget(
            modelRouteID: route.id,
            generationPresetID: preset.id
        )
        self.connection = connection
        self.route = route
        self.preset = preset
    }

    public var title: String {
        "\(route.title) · \(preset.displayName)"
    }

    public var subtitle: String {
        connection.displayName
    }

    public var accessibilityID: String {
        [connection.id, route.id, preset.id]
            .map(Self.accessibilityComponent)
            .joined(separator: "--")
    }

    private static func accessibilityComponent(
        _ value: String
    ) -> String {
        value.unicodeScalars.map { scalar in
            let code = scalar.value
            if (48 ... 57).contains(code)
                || (65 ... 90).contains(code)
                || (97 ... 122).contains(code)
                || code == 45
                || code == 95
            {
                return String(scalar)
            }
            return "_\(String(code, radix: 16, uppercase: true))"
        }.joined()
    }
}

public enum ProviderCapabilityValue: Equatable, Sendable {
    case boolean(Bool)
    case integer(UInt64)
    case enumeration([String])
    case structuredSummary(String)
    case unknown

    public var displayValue: String {
        switch self {
        case let .boolean(value): value ? "지원" : "미지원"
        case let .integer(value): String(value)
        case let .enumeration(values): values.joined(separator: ", ")
        case let .structuredSummary(value): value
        case .unknown: "확인되지 않음"
        }
    }
}

public struct ProviderCapabilityObservation:
    Identifiable,
    Equatable,
    Sendable
{
    public let id: String
    public let modelRouteID: String
    public let key: String
    public let value: ProviderCapabilityValue
    public let status: String
    public let source: String
    public let confidence: String
    public let observedAt: String
    public let expiresAt: String?
    public let evidenceReference: String?

    public init(
        id: String,
        modelRouteID: String,
        key: String,
        value: ProviderCapabilityValue,
        status: String,
        source: String,
        confidence: String,
        observedAt: String,
        expiresAt: String?,
        evidenceReference: String?
    ) {
        self.id = id
        self.modelRouteID = modelRouteID
        self.key = key
        self.value = value
        self.status = status
        self.source = source
        self.confidence = confidence
        self.observedAt = observedAt
        self.expiresAt = expiresAt
        self.evidenceReference = evidenceReference
    }
}

public struct ProviderEffectiveCapability:
    Identifiable,
    Equatable,
    Sendable
{
    public let selected: ProviderCapabilityObservation
    public let alternatives: [ProviderCapabilityObservation]
    public let evaluatedAt: String
    public let isStale: Bool
    public let hasConflict: Bool

    public var id: String { selected.key }

    public init(
        selected: ProviderCapabilityObservation,
        alternatives: [ProviderCapabilityObservation],
        evaluatedAt: String,
        isStale: Bool,
        hasConflict: Bool
    ) {
        self.selected = selected
        self.alternatives = alternatives
        self.evaluatedAt = evaluatedAt
        self.isStale = isStale
        self.hasConflict = hasConflict
    }
}

public enum ProviderDiscoveryMethod: String, CaseIterable, Identifiable, Sendable {
    case knownProvider
    case website
    case curl
    case localServer

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .knownProvider: "알려진 프로바이더"
        case .website: "사이트에서 자동 찾기"
        case .curl: "cURL 붙여넣기"
        case .localServer: "로컬 서버"
        }
    }
}

public struct ProviderCurlInspection:
    Equatable,
    Sendable,
    CustomDebugStringConvertible
{
    public let schemaVersion: UInt32
    public let sanitizedSiteURL: String
    public let apiOrigin: String
    public let method: String
    public let path: String
    public let headerNames: [String]
    public let authBindingHint: String?
    public let apiFamilyHint: String?
    public let modelHint: String?
    public let streamHint: Bool?
    public let redactedCurl: String
    let credentialHandoffID: String?

    public init(
        schemaVersion: UInt32,
        sanitizedSiteURL: String,
        apiOrigin: String,
        method: String,
        path: String,
        headerNames: [String],
        authBindingHint: String?,
        apiFamilyHint: String?,
        modelHint: String?,
        streamHint: Bool?,
        redactedCurl: String,
        credentialHandoffID: String?
    ) {
        self.schemaVersion = schemaVersion
        self.sanitizedSiteURL = sanitizedSiteURL
        self.apiOrigin = apiOrigin
        self.method = method
        self.path = path
        self.headerNames = headerNames
        self.authBindingHint = authBindingHint
        self.apiFamilyHint = apiFamilyHint
        self.modelHint = modelHint
        self.streamHint = streamHint
        self.redactedCurl = redactedCurl
        self.credentialHandoffID = credentialHandoffID
    }

    public var debugDescription: String {
        "ProviderCurlInspection(schemaVersion: \(schemaVersion), "
            + "apiOrigin: \(String(reflecting: apiOrigin)), "
            + "method: \(String(reflecting: method)), "
            + "path: \(String(reflecting: path)), "
            + "headerNames: \(headerNames), "
            + "hasCredentialHandoff: \(credentialHandoffID != nil))"
    }
}

public struct ProviderDiscoveryConnectionOptions: Equatable, Sendable {
    public let values: [ProviderConfigurationEntry]
    public let apiBasePath: String?
    public let timeoutSeconds: UInt32
    public let networkMode: ProviderNetworkMode
    public let localNetworkApproval: ProviderLocalNetworkApproval?

    public init(
        values: [ProviderConfigurationEntry] = [],
        apiBasePath: String? = nil,
        timeoutSeconds: UInt32 = 60,
        networkMode: ProviderNetworkMode,
        localNetworkApproval: ProviderLocalNetworkApproval? = nil
    ) {
        self.values = values
        self.apiBasePath = apiBasePath
        self.timeoutSeconds = timeoutSeconds
        self.networkMode = networkMode
        self.localNetworkApproval = localNetworkApproval
    }
}

public enum ProviderDiscoverySource: Equatable, Sendable {
    case knownProvider(templateID: String)
    case site
    case curl
}

public struct ProviderDiscoveryInput:
    Equatable,
    Sendable,
    CustomDebugStringConvertible
{
    public let connectionID: String
    public let displayName: String
    public let siteURL: String?
    public let docsURL: String?
    public let credentialSlotReady: Bool
    public let preferredAssistantModelRouteID: String?
    public let connectionOptions: ProviderDiscoveryConnectionOptions
    public let suppliedEvidenceIDs: [String]

    public init(
        connectionID: String,
        displayName: String,
        siteURL: String? = nil,
        docsURL: String? = nil,
        credentialSlotReady: Bool,
        preferredAssistantModelRouteID: String? = nil,
        connectionOptions: ProviderDiscoveryConnectionOptions,
        suppliedEvidenceIDs: [String] = []
    ) {
        self.connectionID = connectionID
        self.displayName = displayName
        self.siteURL = siteURL
        self.docsURL = docsURL
        self.credentialSlotReady = credentialSlotReady
        self.preferredAssistantModelRouteID =
            preferredAssistantModelRouteID
        self.connectionOptions = connectionOptions
        self.suppliedEvidenceIDs = suppliedEvidenceIDs
    }

    public var debugDescription: String {
        "ProviderDiscoveryInput(connectionID: "
            + "\(String(reflecting: connectionID)), "
            + "displayName: \(String(reflecting: displayName)), "
            + "hasSiteURL: \(siteURL != nil), "
            + "hasDocsURL: \(docsURL != nil), "
            + "credentialSlotReady: \(credentialSlotReady), "
            + "networkMode: "
            + "\(connectionOptions.networkMode.rawValue))"
    }
}

public enum ProviderDiscoveryState: String, Sendable {
    case draft
    case resolvingKnownProvider = "resolving_known_provider"
    case awaitingTemplateSelection = "awaiting_template_selection"
    case fetchingDocuments = "fetching_documents"
    case extractingEvidence = "extracting_evidence"
    case awaitingMoreEvidence = "awaiting_more_evidence"
    case awaitingAssistantConsent = "awaiting_assistant_consent"
    case buildingDeterministicManifestDraft =
        "building_deterministic_manifest_draft"
    case buildingAssistantManifestDraft =
        "building_assistant_manifest_draft"
    case validatingManifest = "validating_manifest"
    case awaitingCredentialOriginApproval =
        "awaiting_credential_origin_approval"
    case listingModels = "listing_models"
    case awaitingProbeConsent = "awaiting_probe_consent"
    case probingCapabilities = "probing_capabilities"
    case awaitingReview = "awaiting_review"
    case committing
    case compensating
    case ready
    case cancelled
    case failed
    case interrupted
    case unknownOutcome = "unknown_outcome"

    public var isTerminal: Bool {
        switch self {
        case .ready, .cancelled, .failed: true
        default: false
        }
    }
}

public enum ProviderDiscoveryStepState: String, Sendable {
    case pending
    case active
    case complete
    case skipped
    case failed
}

public struct ProviderDiscoveryStep: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let source: String?
    public let state: ProviderDiscoveryStepState

    public init(
        id: String,
        title: String,
        source: String? = nil,
        state: ProviderDiscoveryStepState
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.state = state
    }
}

public struct ProviderDiscoveryCandidate: Identifiable, Equatable, Sendable {
    public let id: String
    public let proposedRevision: UInt64
    public let kind: String
    public let title: String
    public let subtitle: String?
    public let evidenceReferences: [String]
    public let createdAt: String

    public init(
        id: String,
        proposedRevision: UInt64 = 0,
        kind: String,
        title: String,
        subtitle: String? = nil,
        evidenceReferences: [String] = [],
        createdAt: String = ""
    ) {
        self.id = id
        self.proposedRevision = proposedRevision
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.evidenceReferences = evidenceReferences
        self.createdAt = createdAt
    }
}

public struct ProviderDiscoveryAssistantConsent: Equatable, Sendable {
    public let approvalID: String
    public let grantSHA256: String
    public let assistantModelRouteID: String
    public let documentOrigins: [String]
    public let maximumCalls: UInt32
    public let maximumInputTokens: UInt32
    public let maximumOutputTokens: UInt32
    public let maximumToolCalls: UInt32
    public let maximumRetries: UInt32
    public let maximumCostMicroUnits: UInt64

    public init(
        approvalID: String,
        grantSHA256: String,
        assistantModelRouteID: String,
        documentOrigins: [String],
        maximumCalls: UInt32,
        maximumInputTokens: UInt32,
        maximumOutputTokens: UInt32,
        maximumToolCalls: UInt32,
        maximumRetries: UInt32,
        maximumCostMicroUnits: UInt64
    ) {
        self.approvalID = approvalID
        self.grantSHA256 = grantSHA256
        self.assistantModelRouteID = assistantModelRouteID
        self.documentOrigins = documentOrigins
        self.maximumCalls = maximumCalls
        self.maximumInputTokens = maximumInputTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumToolCalls = maximumToolCalls
        self.maximumRetries = maximumRetries
        self.maximumCostMicroUnits = maximumCostMicroUnits
    }
}

public struct ProviderDiscoveryAssistantCallEstimate:
    Equatable,
    Sendable
{
    public let inputTokens: UInt64
    public let maximumOutputTokens: UInt64
    public let maximumCostMicroUnits: UInt64

    public init(
        inputTokens: UInt64,
        maximumOutputTokens: UInt64,
        maximumCostMicroUnits: UInt64
    ) {
        self.inputTokens = inputTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumCostMicroUnits = maximumCostMicroUnits
    }
}

/// The non-secret portion of the assistant consent grant that Core has
/// durably approved for this discovery session.
public struct ProviderDiscoveryAssistantApprovalBinding:
    Equatable,
    Sendable
{
    public let assistantModelRouteID: String
    public let maximumCalls: UInt32
    public let maximumInputTokens: UInt32
    public let maximumOutputTokens: UInt32
    public let maximumToolCalls: UInt32
    public let maximumRetries: UInt32
    public let maximumCostMicroUnits: UInt64

    public init(
        assistantModelRouteID: String,
        maximumCalls: UInt32,
        maximumInputTokens: UInt32,
        maximumOutputTokens: UInt32,
        maximumToolCalls: UInt32,
        maximumRetries: UInt32,
        maximumCostMicroUnits: UInt64
    ) {
        self.assistantModelRouteID = assistantModelRouteID
        self.maximumCalls = maximumCalls
        self.maximumInputTokens = maximumInputTokens
        self.maximumOutputTokens = maximumOutputTokens
        self.maximumToolCalls = maximumToolCalls
        self.maximumRetries = maximumRetries
        self.maximumCostMicroUnits = maximumCostMicroUnits
    }
}

public enum ProviderDiscoveryAssistantDraftField:
    Equatable,
    Sendable
{
    case apiFamily
    case defaultAPIOrigin
    case auth
    case generateEndpoint
    case modelsEndpoint
    case responseDecoder
    case streamingDecoder
    case parameter(id: String)

    public var displayName: String {
        switch self {
        case .apiFamily: "API 형식"
        case .defaultAPIOrigin: "기본 API origin"
        case .auth: "인증 방식"
        case .generateEndpoint: "생성 endpoint"
        case .modelsEndpoint: "모델 목록 endpoint"
        case .responseDecoder: "응답 decoder"
        case .streamingDecoder: "스트리밍 decoder"
        case let .parameter(id): "파라미터 \(id)"
        }
    }
}

public struct ProviderDiscoveryAssistantQuestion:
    Identifiable,
    Equatable,
    Sendable
{
    public let id: String
    public let field: ProviderDiscoveryAssistantDraftField?
    public let question: String
    public let requiredEvidence: String

    public init(
        id: String,
        field: ProviderDiscoveryAssistantDraftField?,
        question: String,
        requiredEvidence: String
    ) {
        self.id = id
        self.field = field
        self.question = question
        self.requiredEvidence = requiredEvidence
    }
}

public struct ProviderDiscoveryAssistantEvidenceMapping:
    Equatable,
    Sendable
{
    public let field: ProviderDiscoveryAssistantDraftField
    public let evidenceIDs: [String]
    public let explanation: String

    public init(
        field: ProviderDiscoveryAssistantDraftField,
        evidenceIDs: [String],
        explanation: String
    ) {
        self.field = field
        self.evidenceIDs = evidenceIDs
        self.explanation = explanation
    }
}

public enum ProviderDiscoveryAssistantConfidenceLevel:
    String,
    Equatable,
    Sendable
{
    case unknown
    case low
    case medium
    case high
}

public struct ProviderDiscoveryAssistantFieldConfidence:
    Equatable,
    Sendable
{
    public let field: ProviderDiscoveryAssistantDraftField
    public let level: ProviderDiscoveryAssistantConfidenceLevel
    public let rationale: String

    public init(
        field: ProviderDiscoveryAssistantDraftField,
        level: ProviderDiscoveryAssistantConfidenceLevel,
        rationale: String
    ) {
        self.field = field
        self.level = level
        self.rationale = rationale
    }
}

public enum ProviderDiscoveryAssistantConflictDisposition:
    Equatable,
    Sendable
{
    case unresolved
    case resolved(selectedEvidenceID: String, rationale: String)
}

public struct ProviderDiscoveryAssistantEvidenceConflict:
    Equatable,
    Sendable
{
    public let field: ProviderDiscoveryAssistantDraftField
    public let evidenceIDs: [String]
    public let disposition:
        ProviderDiscoveryAssistantConflictDisposition

    public init(
        field: ProviderDiscoveryAssistantDraftField,
        evidenceIDs: [String],
        disposition: ProviderDiscoveryAssistantConflictDisposition
    ) {
        self.field = field
        self.evidenceIDs = evidenceIDs
        self.disposition = disposition
    }
}

public enum ProviderDiscoveryAssistantAPIFamily:
    String,
    Equatable,
    Sendable
{
    case openAIResponses = "openai_responses"
    case openAIChatCompletions = "openai_chat_completions"
    case anthropicMessages = "anthropic_messages"
    case geminiGenerateContent = "gemini_generate_content"
    case ollamaNative = "ollama_native"
}

public enum ProviderDiscoveryAssistantManifestSourceKind:
    String,
    Equatable,
    Sendable
{
    case officialSite = "official_site"
    case officialDocumentation = "official_documentation"
    case signedCatalog = "signed_catalog"
    case userSupplied = "user_supplied"
}

public enum ProviderDiscoveryAssistantHTTPMethod:
    String,
    Equatable,
    Sendable
{
    case get = "GET"
    case post = "POST"
}

public enum ProviderDiscoveryAssistantDecoder:
    String,
    Equatable,
    Sendable
{
    case openAIJSONV1 = "openai_json_v1"
    case openAISSEV1 = "openai_sse_v1"
    case anthropicJSONV1 = "anthropic_json_v1"
    case anthropicSSEV1 = "anthropic_sse_v1"
    case geminiJSONV1 = "gemini_json_v1"
    case geminiSSEV1 = "gemini_sse_v1"
    case ollamaJSONV1 = "ollama_json_v1"
    case ollamaJSONLV1 = "ollama_jsonl_v1"
}

public struct ProviderDiscoveryAssistantManifestSource:
    Equatable,
    Sendable
{
    public let kind: ProviderDiscoveryAssistantManifestSourceKind
    public let url: String
    public let contentSHA256: String?

    public init(
        kind: ProviderDiscoveryAssistantManifestSourceKind,
        url: String,
        contentSHA256: String?
    ) {
        self.kind = kind
        self.url = url
        self.contentSHA256 = contentSHA256
    }
}

public struct ProviderDiscoveryAssistantEndpoint:
    Equatable,
    Sendable
{
    public let method: ProviderDiscoveryAssistantHTTPMethod
    public let path: String

    public init(
        method: ProviderDiscoveryAssistantHTTPMethod,
        path: String
    ) {
        self.method = method
        self.path = path
    }
}

public struct ProviderDiscoveryAssistantManifest:
    Equatable,
    Sendable
{
    public let schemaVersion: UInt32
    public let apiFamily: ProviderDiscoveryAssistantAPIFamily
    public let sources: [ProviderDiscoveryAssistantManifestSource]
    public let defaultAPIOrigin: String?
    public let authDescription: String
    public let modelsEndpoint: ProviderDiscoveryAssistantEndpoint?
    public let generateEndpoint: ProviderDiscoveryAssistantEndpoint
    public let responseDecoder: ProviderDiscoveryAssistantDecoder
    public let streamingDecoder: ProviderDiscoveryAssistantDecoder?
    public let parameters: [ProviderParameterSpec]

    public init(
        schemaVersion: UInt32,
        apiFamily: ProviderDiscoveryAssistantAPIFamily,
        sources: [ProviderDiscoveryAssistantManifestSource],
        defaultAPIOrigin: String?,
        authDescription: String,
        modelsEndpoint: ProviderDiscoveryAssistantEndpoint?,
        generateEndpoint: ProviderDiscoveryAssistantEndpoint,
        responseDecoder: ProviderDiscoveryAssistantDecoder,
        streamingDecoder: ProviderDiscoveryAssistantDecoder?,
        parameters: [ProviderParameterSpec]
    ) {
        self.schemaVersion = schemaVersion
        self.apiFamily = apiFamily
        self.sources = sources
        self.defaultAPIOrigin = defaultAPIOrigin
        self.authDescription = authDescription
        self.modelsEndpoint = modelsEndpoint
        self.generateEndpoint = generateEndpoint
        self.responseDecoder = responseDecoder
        self.streamingDecoder = streamingDecoder
        self.parameters = parameters
    }
}

public struct ProviderDiscoveryAssistantManifestDraft:
    Equatable,
    Sendable
{
    public let manifest: ProviderDiscoveryAssistantManifest
    public let evidenceMappings:
        [ProviderDiscoveryAssistantEvidenceMapping]
    public let conflicts: [ProviderDiscoveryAssistantEvidenceConflict]
    public let unresolvedQuestions: [ProviderDiscoveryAssistantQuestion]
    public let confidence:
        [ProviderDiscoveryAssistantFieldConfidence]
    public let summary: String

    public init(
        manifest: ProviderDiscoveryAssistantManifest,
        evidenceMappings:
            [ProviderDiscoveryAssistantEvidenceMapping],
        conflicts: [ProviderDiscoveryAssistantEvidenceConflict],
        unresolvedQuestions: [ProviderDiscoveryAssistantQuestion],
        confidence: [ProviderDiscoveryAssistantFieldConfidence],
        summary: String
    ) {
        self.manifest = manifest
        self.evidenceMappings = evidenceMappings
        self.conflicts = conflicts
        self.unresolvedQuestions = unresolvedQuestions
        self.confidence = confidence
        self.summary = summary
    }
}

public enum ProviderDiscoveryAssistantDraftReviewCheck:
    String,
    Equatable,
    Sendable
{
    case manifestValidation = "manifest_validation"
    case urlPolicyValidation = "url_policy_validation"
    case credentialOriginApproval = "credential_origin_approval"
    case userReview = "user_review"
}

public enum ProviderDiscoveryAssistantDraftPersistence:
    String,
    Equatable,
    Sendable
{
    case blockedUntilChecksPass = "blocked_until_checks_pass"
}

public struct ProviderDiscoveryAssistantDraftReview:
    Equatable,
    Sendable
{
    public let draft: ProviderDiscoveryAssistantManifestDraft
    public let unresolvedConflicts:
        [ProviderDiscoveryAssistantDraftField]
    public let requiredChecks:
        [ProviderDiscoveryAssistantDraftReviewCheck]
    public let persistence:
        ProviderDiscoveryAssistantDraftPersistence

    public init(
        draft: ProviderDiscoveryAssistantManifestDraft,
        unresolvedConflicts:
            [ProviderDiscoveryAssistantDraftField],
        requiredChecks:
            [ProviderDiscoveryAssistantDraftReviewCheck],
        persistence: ProviderDiscoveryAssistantDraftPersistence
    ) {
        self.draft = draft
        self.unresolvedConflicts = unresolvedConflicts
        self.requiredChecks = requiredChecks
        self.persistence = persistence
    }
}

public enum ProviderDiscoveryAssistantHostAction:
    Equatable,
    Sendable
{
    case requestMoreEvidence(
        sessionID: String,
        questions: [ProviderDiscoveryAssistantQuestion]
    )
    case reviewDraft(ProviderDiscoveryAssistantDraftReview)
}

public enum ProviderDiscoveryAssistantCheckpoint:
    String,
    Equatable,
    Sendable
{
    case ready
    case awaitingAssistant = "awaiting_assistant"
    case awaitingToolResult = "awaiting_tool_result"
    case awaitingMoreEvidence = "awaiting_more_evidence"
    case awaitingRetryConsent = "awaiting_retry_consent"
    case draftReady = "draft_ready"
}

public enum ProviderDiscoveryAssistantResumeAction:
    String,
    Equatable,
    Sendable
{
    case approveConsent = "approve_consent"
    case runAssistant = "run_assistant"
    case waitForAssistantOutcome = "wait_for_assistant_outcome"
    case resumeCoreHostAction = "resume_core_host_action"
    case supplyMoreEvidence = "supply_more_evidence"
    case approveRetry = "approve_retry"
    case reviewDraft = "review_draft"
    case restartInterrupted = "restart_interrupted"
    case resolveUnknownOutcome = "resolve_unknown_outcome"
}

public struct ProviderDiscoveryAssistantResumeBoundary:
    Equatable,
    Sendable
{
    public let checkpoint: ProviderDiscoveryAssistantCheckpoint?
    public let action: ProviderDiscoveryAssistantResumeAction
    public let questions: [ProviderDiscoveryAssistantQuestion]
    public let draftReview: ProviderDiscoveryAssistantDraftReview?

    public init(
        checkpoint: ProviderDiscoveryAssistantCheckpoint?,
        action: ProviderDiscoveryAssistantResumeAction,
        questions: [ProviderDiscoveryAssistantQuestion] = [],
        draftReview: ProviderDiscoveryAssistantDraftReview? = nil
    ) {
        self.checkpoint = checkpoint
        self.action = action
        self.questions = questions
        self.draftReview = draftReview
    }
}

public struct ProviderCredentialOriginApproval: Equatable, Sendable {
    public let approvalID: String
    public let origin: String
    public let authDescription: String
    public let manifestSHA256: String

    public init(
        approvalID: String,
        origin: String,
        authDescription: String,
        manifestSHA256: String
    ) {
        self.approvalID = approvalID
        self.origin = origin
        self.authDescription = authDescription
        self.manifestSHA256 = manifestSHA256
    }
}

public struct ProviderDiscoveryProbeConsent: Equatable, Sendable {
    public let approvalID: String
    public let grantSHA256: String
    public let routeIDs: [String]
    public let budget: ProviderDiscoveryProbeBudget

    public init(
        approvalID: String,
        grantSHA256: String,
        routeIDs: [String],
        budget: ProviderDiscoveryProbeBudget
    ) {
        self.approvalID = approvalID
        self.grantSHA256 = grantSHA256
        self.routeIDs = routeIDs
        self.budget = budget
    }
}

/// The exact per-request limits bound into a capability-probe approval grant.
///
/// Native surfaces these values verbatim. It does not derive a looser budget
/// from the number of routes.
public struct ProviderDiscoveryProbeBudget: Equatable, Sendable {
    public let maximumRequests: UInt32
    public let maximumTotalTokensPerRequest: UInt64
    public let maximumOutputTokensPerRequest: UInt64
    public let maximumCostMicroUSDPerRequest: UInt64
    public let maximumDurationMillisecondsPerRequest: UInt64
    public let maximumCallsPerRequest: UInt32

    public init(
        maximumRequests: UInt32,
        maximumTotalTokensPerRequest: UInt64,
        maximumOutputTokensPerRequest: UInt64,
        maximumCostMicroUSDPerRequest: UInt64,
        maximumDurationMillisecondsPerRequest: UInt64,
        maximumCallsPerRequest: UInt32
    ) {
        self.maximumRequests = maximumRequests
        self.maximumTotalTokensPerRequest =
            maximumTotalTokensPerRequest
        self.maximumOutputTokensPerRequest =
            maximumOutputTokensPerRequest
        self.maximumCostMicroUSDPerRequest =
            maximumCostMicroUSDPerRequest
        self.maximumDurationMillisecondsPerRequest =
            maximumDurationMillisecondsPerRequest
        self.maximumCallsPerRequest = maximumCallsPerRequest
    }
}

public struct ProviderDiscoveryEvidence: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: String
    public let contentSHA256: String
    public let fetchedAt: String

    public init(
        id: String,
        kind: String,
        contentSHA256: String,
        fetchedAt: String
    ) {
        self.id = id
        self.kind = kind
        self.contentSHA256 = contentSHA256
        self.fetchedAt = fetchedAt
    }
}

public enum ProviderReviewChangeKind: String, Sendable {
    case add
    case update
    case deprecate
    case preserveMissing
}

public struct ProviderReviewChange: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: ProviderReviewChangeKind
    public let targetKind: String
    public let title: String
    public let detail: String?
    public let evidenceReferences: [String]

    public init(
        id: String,
        kind: ProviderReviewChangeKind,
        targetKind: String,
        title: String,
        detail: String? = nil,
        evidenceReferences: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.targetKind = targetKind
        self.title = title
        self.detail = detail
        self.evidenceReferences = evidenceReferences
    }
}

public struct ProviderDiscoveryReview: Equatable, Sendable {
    public let sha256: String
    public let graphSHA256: String
    public let changes: [ProviderReviewChange]
    public let unresolvedQuestionCount: UInt32
    public let warningCount: UInt32
    public let requestPreview: ProviderRequestPreview?

    public init(
        sha256: String,
        graphSHA256: String,
        changes: [ProviderReviewChange],
        unresolvedQuestionCount: UInt32,
        warningCount: UInt32,
        requestPreview: ProviderRequestPreview? = nil
    ) {
        self.sha256 = sha256
        self.graphSHA256 = graphSHA256
        self.changes = changes
        self.unresolvedQuestionCount = unresolvedQuestionCount
        self.warningCount = warningCount
        self.requestPreview = requestPreview
    }
}

public enum ProviderDiscoveryActionRequired: Equatable, Sendable {
    case selectTemplate
    case supplyMoreEvidence
    case assistantConsent(ProviderDiscoveryAssistantConsent)
    case credentialOrigin(ProviderCredentialOriginApproval)
    case capabilityProbe(ProviderDiscoveryProbeConsent)
    case review
    case restartInterrupted(String)
    case reconcileUnknownOutcome(String)
}

public struct ProviderDiscoveryReviewProposal: Equatable, Sendable {
    public let approvalID: String
    public let grantSHA256: String
    public let commitAttemptID: String
    public let commitPlanSHA256: String
    public let review: ProviderDiscoveryReview

    public init(
        approvalID: String,
        grantSHA256: String,
        commitAttemptID: String,
        commitPlanSHA256: String,
        review: ProviderDiscoveryReview
    ) {
        self.approvalID = approvalID
        self.grantSHA256 = grantSHA256
        self.commitAttemptID = commitAttemptID
        self.commitPlanSHA256 = commitPlanSHA256
        self.review = review
    }
}

public struct ProviderDiscoveryUnknownOutcomeProposal:
    Equatable,
    Sendable
{
    public let approvalID: String
    public let operation: String
    public let resolution: ProviderDiscoveryUnknownOutcomeResolution

    public init(
        approvalID: String,
        operation: String,
        resolution: ProviderDiscoveryUnknownOutcomeResolution
    ) {
        self.approvalID = approvalID
        self.operation = operation
        self.resolution = resolution
    }
}

public struct ProviderDiscoverySnapshot: Identifiable, Equatable, Sendable {
    public let schemaVersion: UInt32
    public let id: String
    public let pendingConnectionID: String
    public let pendingDisplayName: String
    public let connectionOptions:
        ProviderDiscoveryConnectionOptions
    public let credentialSlotID: String?
    public let credentialSlotExpected: Bool
    public let revision: UInt64
    public let nextEventSequence: UInt64
    public let state: ProviderDiscoveryState
    public let steps: [ProviderDiscoveryStep]
    public let actionRequired: ProviderDiscoveryActionRequired?
    public let activeOperationID: String?
    public let recoveryOperation: String?
    public let unknownOperation: String?
    public let manifestSHA256: String?
    public let commitPlanSHA256: String?
    public let commitAttemptID: String?
    public let committedConnectionID: String?
    public let cancellationPending: Bool
    public let candidates: [ProviderDiscoveryCandidate]
    public let evidence: [ProviderDiscoveryEvidence]
    public let review: ProviderDiscoveryReview?
    public let reviewProposal: ProviderDiscoveryReviewProposal?
    public let assistantApprovalBinding:
        ProviderDiscoveryAssistantApprovalBinding?
    public let assistantResumeBoundary:
        ProviderDiscoveryAssistantResumeBoundary?
    public let unknownOutcomeProposal:
        ProviderDiscoveryUnknownOutcomeProposal?
    public let warnings: [String]
    public let failureMessageKey: String?
    public let createdAt: String
    public let updatedAt: String

    public init(
        schemaVersion: UInt32 =
            CoreRuntimeContract
                .providerDiscoverySnapshotSchemaVersion,
        id: String,
        pendingConnectionID: String,
        pendingDisplayName: String,
        connectionOptions: ProviderDiscoveryConnectionOptions =
            ProviderDiscoveryConnectionOptions(
                networkMode: .publicInternet
            ),
        credentialSlotID: String? = nil,
        credentialSlotExpected: Bool = false,
        revision: UInt64,
        nextEventSequence: UInt64 = 0,
        state: ProviderDiscoveryState,
        steps: [ProviderDiscoveryStep],
        actionRequired: ProviderDiscoveryActionRequired?,
        activeOperationID: String? = nil,
        recoveryOperation: String? = nil,
        unknownOperation: String? = nil,
        manifestSHA256: String? = nil,
        commitPlanSHA256: String? = nil,
        commitAttemptID: String? = nil,
        committedConnectionID: String? = nil,
        cancellationPending: Bool = false,
        candidates: [ProviderDiscoveryCandidate] = [],
        evidence: [ProviderDiscoveryEvidence] = [],
        review: ProviderDiscoveryReview? = nil,
        reviewProposal: ProviderDiscoveryReviewProposal? = nil,
        assistantApprovalBinding:
            ProviderDiscoveryAssistantApprovalBinding? = nil,
        assistantResumeBoundary:
            ProviderDiscoveryAssistantResumeBoundary? = nil,
        unknownOutcomeProposal:
            ProviderDiscoveryUnknownOutcomeProposal? = nil,
        warnings: [String] = [],
        failureMessageKey: String? = nil,
        createdAt: String = "",
        updatedAt: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.pendingConnectionID = pendingConnectionID
        self.pendingDisplayName = pendingDisplayName
        self.connectionOptions = connectionOptions
        self.credentialSlotID = credentialSlotID
        self.credentialSlotExpected = credentialSlotExpected
        self.revision = revision
        self.nextEventSequence = nextEventSequence
        self.state = state
        self.steps = steps
        self.actionRequired = actionRequired
        self.activeOperationID = activeOperationID
        self.recoveryOperation = recoveryOperation
        self.unknownOperation = unknownOperation
        self.manifestSHA256 = manifestSHA256
        self.commitPlanSHA256 = commitPlanSHA256
        self.commitAttemptID = commitAttemptID
        self.committedConnectionID = committedConnectionID
        self.cancellationPending = cancellationPending
        self.candidates = candidates
        self.evidence = evidence
        self.review = review
        self.reviewProposal = reviewProposal
        self.assistantApprovalBinding = assistantApprovalBinding
        self.assistantResumeBoundary = assistantResumeBoundary
        self.unknownOutcomeProposal = unknownOutcomeProposal
        self.warnings = warnings
        self.failureMessageKey = failureMessageKey
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum ProviderDiscoveryUnknownOutcomeResolution: Equatable, Sendable {
    case confirmedNoEffect
    case confirmedCommitCompleted(connectionID: String)
    case confirmedCompensated
    case manuallyReconciledAsFailed
}

public enum ProviderDiscoveryAction: Equatable, Sendable {
    case selectTemplate(candidateID: String)
    case continueWithoutTemplate
    case supplyMoreEvidence(evidenceIDs: [String])
    case requestAssistant
    case approveAssistant(approvalID: String, grantSHA256: String)
    case declineAssistant
    case approveCredentialOrigin(approvalID: String)
    case approveProbes(approvalID: String, grantSHA256: String)
    case skipProbes
    case approveReview(
        approvalID: String,
        commitAttemptID: String,
        commitPlanSHA256: String,
        graphSHA256: String
    )
    case resumeCompensation
    case restartInterrupted
    case resolveUnknownOutcome(
        approvalID: String,
        resolution: ProviderDiscoveryUnknownOutcomeResolution
    )
    case cancel
}

public struct ProviderDiscoveryActionEnvelope: Equatable, Sendable {
    public let actionID: String
    public let expectedRevision: UInt64
    public let requestSHA256: String
    public let action: ProviderDiscoveryAction

    public init(
        actionID: String,
        expectedRevision: UInt64,
        requestSHA256: String,
        action: ProviderDiscoveryAction
    ) {
        self.actionID = actionID
        self.expectedRevision = expectedRevision
        self.requestSHA256 = requestSHA256
        self.action = action
    }
}

public struct ProviderDiscoveryProgress: Equatable, Sendable {
    public let phase: String
    public let completed: UInt32
    public let total: UInt32?

    public init(phase: String, completed: UInt32, total: UInt32?) {
        self.phase = phase
        self.completed = completed
        self.total = total
    }
}

public struct ProviderDiscoveryEvent: Identifiable, Equatable, Sendable {
    public let version: UInt32
    public let id: String
    public let sessionID: String
    public let sequence: UInt64
    public let sessionRevision: UInt64
    public let state: ProviderDiscoveryState
    public let progress: ProviderDiscoveryProgress?
    public let actionID: String
    public let warning: String?
    public let failureMessageKey: String?

    public init(
        version: UInt32,
        id: String,
        sessionID: String,
        sequence: UInt64,
        sessionRevision: UInt64,
        state: ProviderDiscoveryState,
        progress: ProviderDiscoveryProgress?,
        actionID: String,
        warning: String?,
        failureMessageKey: String?
    ) {
        self.version = version
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.sessionRevision = sessionRevision
        self.state = state
        self.progress = progress
        self.actionID = actionID
        self.warning = warning
        self.failureMessageKey = failureMessageKey
    }
}

public struct ProviderDiscoveryOutboxEvent: Equatable, Sendable {
    public let event: ProviderDiscoveryEvent
    public let deliveryAttempts: UInt32
    public let availableAt: String
    public let createdAt: String

    public init(
        event: ProviderDiscoveryEvent,
        deliveryAttempts: UInt32,
        availableAt: String,
        createdAt: String
    ) {
        self.event = event
        self.deliveryAttempts = deliveryAttempts
        self.availableAt = availableAt
        self.createdAt = createdAt
    }
}

public struct ProviderDiscoveryRecoveryResult: Equatable, Sendable {
    public let operationID: String
    public let sessionID: String
    public let state: ProviderDiscoveryState
    public let event: ProviderDiscoveryEvent

    public init(
        operationID: String,
        sessionID: String,
        state: ProviderDiscoveryState,
        event: ProviderDiscoveryEvent
    ) {
        self.operationID = operationID
        self.sessionID = sessionID
        self.state = state
        self.event = event
    }
}

public struct ProviderDiscoveryFailure: Equatable, Sendable {
    public let code: String
    public let messageKey: String
    public let isRecoverable: Bool

    public init(
        code: String,
        messageKey: String,
        isRecoverable: Bool
    ) {
        self.code = code
        self.messageKey = messageKey
        self.isRecoverable = isRecoverable
    }
}

public enum ProviderDiscoveryCompensationKind:
    String,
    Equatable,
    Sendable
{
    case removeCredentialSlot = "remove_credential_slot"
    case removeConnectionGraph = "remove_connection_graph"
    case restorePreviousSelection = "restore_previous_selection"
}

public enum ProviderDiscoveryCompensationStatus:
    String,
    Equatable,
    Sendable
{
    case pending
    case inProgress = "in_progress"
    case completed
    case failed
    case outcomeUnknown = "outcome_unknown"
}

public enum ProviderDiscoveryPreviousSelection: Equatable, Sendable {
    case none
    case routeAndPreset(
        modelRouteID: String,
        generationPresetID: String
    )
}

/// A closed compensation target. Only `removeCredentialSlot` is executed by
/// native code; Core owns the connection graph and settings selection steps.
public enum ProviderDiscoveryCompensationTarget: Equatable, Sendable {
    case removeCredentialSlot(
        connectionID: String,
        credentialReference: String
    )
    case removeConnectionGraph(connectionID: String)
    case restorePreviousSelection(ProviderDiscoveryPreviousSelection)
}

public struct ProviderDiscoveryCompensationStep:
    Identifiable,
    Equatable,
    Sendable
{
    public let id: String
    public let commitAttemptID: String
    public let ordinal: UInt32
    public let actionID: String
    public let kind: ProviderDiscoveryCompensationKind
    public let target: ProviderDiscoveryCompensationTarget
    public let status: ProviderDiscoveryCompensationStatus
    public let attemptCount: UInt32
    public let lastFailure: ProviderDiscoveryFailure?
    public let createdAt: String
    public let updatedAt: String
    public let completedAt: String?

    public init(
        id: String,
        commitAttemptID: String,
        ordinal: UInt32,
        actionID: String,
        kind: ProviderDiscoveryCompensationKind,
        target: ProviderDiscoveryCompensationTarget,
        status: ProviderDiscoveryCompensationStatus,
        attemptCount: UInt32,
        lastFailure: ProviderDiscoveryFailure?,
        createdAt: String,
        updatedAt: String,
        completedAt: String?
    ) {
        self.id = id
        self.commitAttemptID = commitAttemptID
        self.ordinal = ordinal
        self.actionID = actionID
        self.kind = kind
        self.target = target
        self.status = status
        self.attemptCount = attemptCount
        self.lastFailure = lastFailure
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
    }
}

public struct ProviderModelSyncDiff: Equatable, Sendable {
    public let newRoutes: [ProviderModelRoute]
    public let changedRouteIDs: [String]
    public let missingRouteIDs: [String]
    public let capabilityChangeCount: UInt32

    public init(
        newRoutes: [ProviderModelRoute],
        changedRouteIDs: [String],
        missingRouteIDs: [String],
        capabilityChangeCount: UInt32
    ) {
        self.newRoutes = newRoutes
        self.changedRouteIDs = changedRouteIDs
        self.missingRouteIDs = missingRouteIDs
        self.capabilityChangeCount = capabilityChangeCount
    }
}

public enum ProviderModelSyncState: String, Sendable {
    case created
    case fetching
    case interrupted
    case awaitingReview
    case completed
    case failed
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        default: false
        }
    }
}

public struct ProviderModelSyncJob: Identifiable, Equatable, Sendable {
    public let id: String
    public let connectionID: String
    public let state: ProviderModelSyncState
    public let revision: UInt64
    public let completedSteps: UInt32
    public let totalSteps: UInt32
    public let reviewSHA256: String?
    public let diff: ProviderModelSyncDiff?
    public let failureMessageKey: String?
    public let updatedAt: String

    public init(
        id: String,
        connectionID: String,
        state: ProviderModelSyncState,
        revision: UInt64,
        completedSteps: UInt32,
        totalSteps: UInt32,
        reviewSHA256: String?,
        diff: ProviderModelSyncDiff?,
        failureMessageKey: String?,
        updatedAt: String
    ) {
        self.id = id
        self.connectionID = connectionID
        self.state = state
        self.revision = revision
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.reviewSHA256 = reviewSHA256
        self.diff = diff
        self.failureMessageKey = failureMessageKey
        self.updatedAt = updatedAt
    }
}

public struct ProviderModelSyncEvent:
    Identifiable,
    Equatable,
    Sendable
{
    public let version: UInt32
    public let jobID: String
    public let sequence: UInt64
    public let jobRevision: UInt64
    public let redactionVersion: UInt32
    public let state: ProviderModelSyncState
    public let completedSteps: UInt32
    public let totalSteps: UInt32
    public let messageKey: String
    public let reviewSHA256: String?
    public let failureMessageKey: String?
    public let emittedAt: String

    public var id: String {
        "\(jobID)\u{001F}\(sequence)"
    }

    public init(
        version: UInt32,
        jobID: String,
        sequence: UInt64,
        jobRevision: UInt64,
        redactionVersion: UInt32,
        state: ProviderModelSyncState,
        completedSteps: UInt32,
        totalSteps: UInt32,
        messageKey: String,
        reviewSHA256: String?,
        failureMessageKey: String?,
        emittedAt: String
    ) {
        self.version = version
        self.jobID = jobID
        self.sequence = sequence
        self.jobRevision = jobRevision
        self.redactionVersion = redactionVersion
        self.state = state
        self.completedSteps = completedSteps
        self.totalSteps = totalSteps
        self.messageKey = messageKey
        self.reviewSHA256 = reviewSHA256
        self.failureMessageKey = failureMessageKey
        self.emittedAt = emittedAt
    }
}

public struct ProviderCatalogActivation: Identifiable, Equatable, Sendable {
    public let id: String
    public let revision: UInt64
    public let source: String
    public let signer: String?
    public let activatedAt: String
    public let isCurrent: Bool
    public let summary: String

    public init(
        id: String,
        revision: UInt64,
        source: String,
        signer: String? = nil,
        activatedAt: String,
        isCurrent: Bool,
        summary: String
    ) {
        self.id = id
        self.revision = revision
        self.source = source
        self.signer = signer
        self.activatedAt = activatedAt
        self.isCurrent = isCurrent
        self.summary = summary
    }
}

public struct ProviderCatalogStatus: Equatable, Sendable {
    public let schemaVersion: UInt32
    public let currentRevision: UInt64?
    public let currentSource: String
    public let verifiedSigner: String?
    public let updatedAt: String?
    public let history: [ProviderCatalogActivation]

    public init(
        schemaVersion: UInt32,
        currentRevision: UInt64?,
        currentSource: String,
        verifiedSigner: String?,
        updatedAt: String?,
        history: [ProviderCatalogActivation]
    ) {
        self.schemaVersion = schemaVersion
        self.currentRevision = currentRevision
        self.currentSource = currentSource
        self.verifiedSigner = verifiedSigner
        self.updatedAt = updatedAt
        self.history = history
    }
}

public enum ProviderCatalogChangeKind:
    String,
    Equatable,
    Sendable
{
    case added
    case updated
    case removed
}

public struct ProviderCatalogManifestChange:
    Identifiable,
    Equatable,
    Sendable
{
    public let providerTemplateID: String
    public let change: ProviderCatalogChangeKind
    public let previousManifestVersion: UInt32?
    public let nextManifestVersion: UInt32?
    public let previousSHA256: String?
    public let nextSHA256: String?
    public let changedSections: [String]

    public var id: String {
        "\(providerTemplateID)\u{001F}\(change.rawValue)"
    }

    public init(
        providerTemplateID: String,
        change: ProviderCatalogChangeKind,
        previousManifestVersion: UInt32?,
        nextManifestVersion: UInt32?,
        previousSHA256: String? = nil,
        nextSHA256: String? = nil,
        changedSections: [String]
    ) {
        self.providerTemplateID = providerTemplateID
        self.change = change
        self.previousManifestVersion = previousManifestVersion
        self.nextManifestVersion = nextManifestVersion
        self.previousSHA256 = previousSHA256
        self.nextSHA256 = nextSHA256
        self.changedSections = changedSections
    }
}

public struct ProviderCatalogModelChange:
    Identifiable,
    Equatable,
    Sendable
{
    public let modelEntryID: String
    public let providerTemplateID: String
    public let change: ProviderCatalogChangeKind
    public let previousMetadataVersion: UInt32?
    public let nextMetadataVersion: UInt32?
    public let previousSHA256: String?
    public let nextSHA256: String?
    public let changedSections: [String]

    public var id: String {
        [
            providerTemplateID,
            modelEntryID,
            change.rawValue,
        ].joined(separator: "\u{001F}")
    }

    public init(
        modelEntryID: String,
        providerTemplateID: String,
        change: ProviderCatalogChangeKind,
        previousMetadataVersion: UInt32?,
        nextMetadataVersion: UInt32?,
        previousSHA256: String? = nil,
        nextSHA256: String? = nil,
        changedSections: [String]
    ) {
        self.modelEntryID = modelEntryID
        self.providerTemplateID = providerTemplateID
        self.change = change
        self.previousMetadataVersion = previousMetadataVersion
        self.nextMetadataVersion = nextMetadataVersion
        self.previousSHA256 = previousSHA256
        self.nextSHA256 = nextSHA256
        self.changedSections = changedSections
    }
}

public struct ProviderCatalogDiff: Equatable, Sendable {
    public let schemaVersion: UInt32
    public let fromRevision: UInt64
    public let toRevision: UInt64
    public let manifestChanges: [ProviderCatalogManifestChange]
    public let modelChanges: [ProviderCatalogModelChange]

    public init(
        schemaVersion: UInt32,
        fromRevision: UInt64,
        toRevision: UInt64,
        manifestChanges: [ProviderCatalogManifestChange],
        modelChanges: [ProviderCatalogModelChange]
    ) {
        self.schemaVersion = schemaVersion
        self.fromRevision = fromRevision
        self.toRevision = toRevision
        self.manifestChanges = manifestChanges
        self.modelChanges = modelChanges
    }
}

public struct ProviderCatalogImportReview: Equatable, Sendable {
    public let planSchemaVersion: UInt32
    public let actionID: String
    public let expectedStateVersion: UInt64
    public let expectedActiveRevision: UInt64
    public let expectedActiveSnapshotSHA256: String
    public let expectedHighestAcceptedRevision: UInt64
    public let envelopeByteCount: UInt64
    public let envelopeSHA256: String
    public let signingKeyID: String
    public let payloadSHA256: String
    public let signedCatalogRevision: UInt64
    public let candidateRevision: UInt64
    public let candidateSnapshotSHA256: String
    public let preparedAt: String
    public let expiresAt: String
    public let diff: ProviderCatalogDiff

    public init(
        planSchemaVersion: UInt32,
        actionID: String,
        expectedStateVersion: UInt64,
        expectedActiveRevision: UInt64,
        expectedActiveSnapshotSHA256: String,
        expectedHighestAcceptedRevision: UInt64,
        envelopeByteCount: UInt64,
        envelopeSHA256: String,
        signingKeyID: String,
        payloadSHA256: String,
        signedCatalogRevision: UInt64,
        candidateRevision: UInt64,
        candidateSnapshotSHA256: String,
        preparedAt: String,
        expiresAt: String,
        diff: ProviderCatalogDiff
    ) {
        self.planSchemaVersion = planSchemaVersion
        self.actionID = actionID
        self.expectedStateVersion = expectedStateVersion
        self.expectedActiveRevision = expectedActiveRevision
        self.expectedActiveSnapshotSHA256 =
            expectedActiveSnapshotSHA256
        self.expectedHighestAcceptedRevision =
            expectedHighestAcceptedRevision
        self.envelopeByteCount = envelopeByteCount
        self.envelopeSHA256 = envelopeSHA256
        self.signingKeyID = signingKeyID
        self.payloadSHA256 = payloadSHA256
        self.signedCatalogRevision = signedCatalogRevision
        self.candidateRevision = candidateRevision
        self.candidateSnapshotSHA256 = candidateSnapshotSHA256
        self.preparedAt = preparedAt
        self.expiresAt = expiresAt
        self.diff = diff
    }
}

public struct ProviderCatalogImportPlan: Equatable, Sendable {
    public let review: ProviderCatalogImportReview
    public let planSHA256: String
    let opaquePlanJSON: String

    init(
        review: ProviderCatalogImportReview,
        planSHA256: String,
        opaquePlanJSON: String
    ) {
        self.review = review
        self.planSHA256 = planSHA256
        self.opaquePlanJSON = opaquePlanJSON
    }
}

public struct ProviderCatalogImportResult: Equatable, Sendable {
    public let signedCatalogRevision: UInt64
    public let activatedRevision: UInt64
    public let diff: ProviderCatalogDiff
    public let status: ProviderCatalogStatus

    public init(
        signedCatalogRevision: UInt64,
        activatedRevision: UInt64,
        diff: ProviderCatalogDiff,
        status: ProviderCatalogStatus
    ) {
        self.signedCatalogRevision = signedCatalogRevision
        self.activatedRevision = activatedRevision
        self.diff = diff
        self.status = status
    }
}

/// An opaque, state-bound rollback plan. Native may render the typed metadata
/// and diff, but must return the exact plan payload to Core for activation.
public struct ProviderCatalogRollbackPlan: Equatable, Sendable {
    public let planSchemaVersion: UInt32
    public let actionID: String
    public let expectedStateVersion: UInt64
    public let planSHA256: String
    public let fromRevision: UInt64
    public let toRevision: UInt64
    public let createdAt: String
    public let expiresAt: String
    public let diff: ProviderCatalogDiff
    let opaquePlanJSON: String

    init(
        planSchemaVersion: UInt32,
        actionID: String,
        expectedStateVersion: UInt64,
        planSHA256: String,
        fromRevision: UInt64,
        toRevision: UInt64,
        createdAt: String,
        expiresAt: String,
        diff: ProviderCatalogDiff,
        opaquePlanJSON: String
    ) {
        self.planSchemaVersion = planSchemaVersion
        self.actionID = actionID
        self.expectedStateVersion = expectedStateVersion
        self.planSHA256 = planSHA256
        self.fromRevision = fromRevision
        self.toRevision = toRevision
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.diff = diff
        self.opaquePlanJSON = opaquePlanJSON
    }
}

public struct ProviderCatalogRollbackResult: Equatable, Sendable {
    public let fromRevision: UInt64
    public let activatedRevision: UInt64
    public let status: ProviderCatalogStatus

    public init(
        fromRevision: UInt64,
        activatedRevision: UInt64,
        status: ProviderCatalogStatus
    ) {
        self.fromRevision = fromRevision
        self.activatedRevision = activatedRevision
        self.status = status
    }
}

public struct ProviderRequestPreview: Equatable, Sendable {
    public let redactionVersion: UInt32
    public let method: String
    public let origin: String
    public let path: String
    public let headerNames: [String]
    public let queryParameterNames: [String]
    public let bodyShapeJSON: String?
    public let bodyTruncated: Bool
    public let includesPrivateMessage: Bool
    public let includesCredentialValue: Bool
    public let includesOpaqueReasoningState: Bool

    public init(
        redactionVersion: UInt32,
        method: String,
        origin: String,
        path: String,
        headerNames: [String],
        queryParameterNames: [String] = [],
        bodyShapeJSON: String?,
        bodyTruncated: Bool,
        includesPrivateMessage: Bool,
        includesCredentialValue: Bool,
        includesOpaqueReasoningState: Bool
    ) {
        self.redactionVersion = redactionVersion
        self.method = method
        self.origin = origin
        self.path = path
        self.headerNames = headerNames
        self.queryParameterNames = queryParameterNames
        self.bodyShapeJSON = bodyShapeJSON
        self.bodyTruncated = bodyTruncated
        self.includesPrivateMessage = includesPrivateMessage
        self.includesCredentialValue = includesCredentialValue
        self.includesOpaqueReasoningState =
            includesOpaqueReasoningState
    }

    public var endpoint: String {
        let normalizedOrigin = origin.hasSuffix("/")
            ? String(origin.dropLast())
            : origin
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return normalizedOrigin + normalizedPath
    }

    public var isScalarFree: Bool {
        !includesPrivateMessage
            && !includesCredentialValue
            && !includesOpaqueReasoningState
    }

    public var redactions: [String] {
        var values: [String] = []
        if !includesCredentialValue {
            values.append("인증 정보 값")
        }
        if !includesPrivateMessage {
            values.append("메시지 값")
        }
        if !includesOpaqueReasoningState {
            values.append("비공개 추론 상태 값")
        }
        return values
    }
}
