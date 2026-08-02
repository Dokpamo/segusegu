import Foundation

#if LOREPIA_UNIFFI_GENERATED
public actor UniFfiCoreClient: CoreClient {
    private let core: LorepiaCore

    public init(dataRoot: URL) throws {
        let config = FfiCoreConfig(
            dataRoot: dataRoot.path(percentEncoded: false)
        )
        core = try LorepiaCore.open(config: config)
    }

    public func version() async throws -> String {
        coreVersion()
    }

    public func apiVersions() async throws -> CoreVersionInfo {
        let info = versionInfo()
        return CoreVersionInfo(
            coreVersion: info.coreVersion,
            coreAPIVersion: info.coreApiVersion,
            bindingAPIVersion: info.bindingApiVersion,
            chatEventVersion: info.chatEventVersion
        )
    }

    public func health() async throws -> HealthStatus {
        let report = try core.healthCheck()
        return HealthStatus(
            coreVersion: report.coreVersion,
            databaseOpen: report.databaseOpen,
            schemaVersion: report.schemaVersion,
            dataRootWritable: report.dataRootWritable,
            stagingWritable: report.stagingWritable,
            recoveryPending: report.recoveryPending,
            activeJobs: report.activeJobs
        )
    }

    public func listCharacters() async throws -> [CoreCharacter] {
        try core.listCharacters().map(Self.mapCharacter)
    }

    public func getCharacter(id: String) async throws -> CoreCharacter {
        try Self.mapCharacter(core.getCharacter(characterId: id))
    }

    public func inspectImport(stagedURL: URL) async throws -> ImportInspection {
        let inspection = try core.inspectImport(
            stagedPath: stagedURL.path(percentEncoded: false)
        )
        return ImportInspection(
            id: inspection.id,
            contentKind: inspection.contentKind,
            displayName: inspection.displayName,
            description: inspection.description,
            sourceSHA256: inspection.sourceSha256,
            sourceSize: inspection.sourceSize,
            estimatedStoredSize: inspection.estimatedStoredSize,
            assetCount: inspection.assetCount,
            warnings: inspection.warnings.map {
                ImportWarning(code: $0.code, message: $0.message)
            },
            blockedReasons: inspection.blockedReasons,
            isAllowed: inspection.isAllowed,
            representativeImage: inspection.representativeImage.map {
                ImportImagePreview(
                    logicalAssetID: $0.logicalAssetId,
                    mediaType: $0.mediaType,
                    sizeBytes: $0.sizeBytes
                )
            },
            unsupportedOptionalFields: inspection.unsupportedOptionalFields
        )
    }

    public func discardImport(inspectionID: String) async throws {
        try core.discardImport(inspectionId: inspectionID)
    }

    public func commitImport(inspectionID: String) async throws -> CoreCharacter {
        try Self.mapCharacter(core.commitImport(inspectionId: inspectionID))
    }

    public func listConversations() async throws -> [CoreConversation] {
        try core.listConversations().map(Self.mapConversation)
    }

    public func openConversation(characterID: String) async throws -> CoreConversation {
        try Self.mapConversation(core.openConversation(characterId: characterID))
    }

    public func createConversation(
        characterID: String,
        title: String,
        mode: ConversationMode
    ) async throws -> CoreConversation {
        try Self.mapConversation(
            core.createConversation(
                characterId: characterID,
                title: title,
                mode: mode.rawValue
            )
        )
    }

    public func listConversations(
        characterID: String
    ) async throws -> [CoreConversation] {
        try core.listConversationsForCharacter(
            characterId: characterID
        ).map(Self.mapConversation)
    }

    public func getConversation(id: String) async throws -> CoreConversation {
        try Self.mapConversation(
            core.getConversation(conversationId: id)
        )
    }

    public func getConversationState(
        conversationID: String
    ) async throws -> CoreConversationState {
        try Self.mapConversationState(
            core.getConversationState(conversationId: conversationID)
        )
    }

    public func listConversationBranches(
        conversationID: String
    ) async throws -> [CoreConversationBranch] {
        try core.listConversationBranches(
            conversationId: conversationID
        ).map(Self.mapConversationBranch)
    }

    public func createConversationBranch(
        conversationID: String,
        fromMessageID: String?,
        title: String?
    ) async throws -> CoreConversationBranch {
        try Self.mapConversationBranch(
            core.createConversationBranch(
                conversationId: conversationID,
                fromMessageId: fromMessageID,
                title: title
            )
        )
    }

    public func selectConversationBranch(
        conversationID: String,
        branchID: String
    ) async throws -> CoreConversationState {
        try Self.mapConversationState(
            core.selectConversationBranch(
                conversationId: conversationID,
                branchId: branchID
            )
        )
    }

    public func setConversationMode(
        conversationID: String,
        mode: ConversationMode
    ) async throws -> CoreConversationState {
        try Self.mapConversationState(
            core.setConversationMode(
                conversationId: conversationID,
                mode: mode.rawValue
            )
        )
    }

    public func listMessages(conversationID: String) async throws -> [ChatMessage] {
        try core.listMessages(
            conversationId: conversationID
        ).map(Self.mapMessage)
    }

    public func listBranchMessages(
        branchID: String
    ) async throws -> [ChatMessage] {
        try core.listBranchMessages(
            branchId: branchID
        ).map(Self.mapMessage)
    }

    public func sendMessage(
        conversationID: String,
        text: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> String {
        try core.sendMessage(
            conversationId: conversationID,
            text: text,
            providerProfileId: providerProfileID,
            credential: credential
        )
    }

    public func sendMessageWithTarget(
        conversationID: String,
        text: String,
        target: ProviderGenerationTarget,
        credential: String?
    ) async throws -> String {
        try core.sendMessageWithTarget(
            conversationId: conversationID,
            text: text,
            target: Self.mapGenerationTarget(target),
            credential: credential
        )
    }

    public func sendMessageToBranch(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        mode: ConversationMode,
        text: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> String {
        try core.sendMessageToBranch(
            conversationId: conversationID,
            branchId: branchID,
            expectedHead: expectedHeadMessageID,
            mode: mode.rawValue,
            text: text,
            providerProfileId: providerProfileID,
            credential: credential
        )
    }

    public func sendMessageToBranchWithTarget(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        mode: ConversationMode,
        text: String,
        target: ProviderGenerationTarget,
        credential: String?
    ) async throws -> String {
        try core.sendMessageToBranchWithTarget(
            conversationId: conversationID,
            branchId: branchID,
            expectedHead: expectedHeadMessageID,
            mode: mode.rawValue,
            text: text,
            target: Self.mapGenerationTarget(target),
            credential: credential
        )
    }

    public func editUserMessage(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        replacementText: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> CoreMessageActionGeneration {
        let result = try core.editUserMessage(
            conversationId: conversationID,
            branchId: branchID,
            expectedHead: expectedHeadMessageID,
            messageId: messageID,
            replacementText: replacementText,
            providerProfileId: providerProfileID,
            credential: credential
        )
        return CoreMessageActionGeneration(
            branch: Self.mapConversationBranch(result.branch),
            generationID: result.generationId
        )
    }

    public func editUserMessageWithTarget(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        replacementText: String,
        target: ProviderGenerationTarget,
        credential: String?
    ) async throws -> CoreMessageActionGeneration {
        let result = try core.editUserMessageWithTarget(
            conversationId: conversationID,
            branchId: branchID,
            expectedHead: expectedHeadMessageID,
            messageId: messageID,
            replacementText: replacementText,
            target: Self.mapGenerationTarget(target),
            credential: credential
        )
        return CoreMessageActionGeneration(
            branch: Self.mapConversationBranch(result.branch),
            generationID: result.generationId
        )
    }

    public func regenerateAssistantMessage(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        providerProfileID: String,
        credential: String?
    ) async throws -> CoreMessageActionGeneration {
        let result = try core.regenerateAssistantMessage(
            conversationId: conversationID,
            branchId: branchID,
            expectedHead: expectedHeadMessageID,
            messageId: messageID,
            providerProfileId: providerProfileID,
            credential: credential
        )
        return CoreMessageActionGeneration(
            branch: Self.mapConversationBranch(result.branch),
            generationID: result.generationId
        )
    }

    public func regenerateAssistantMessageWithTarget(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String,
        target: ProviderGenerationTarget,
        credential: String?
    ) async throws -> CoreMessageActionGeneration {
        let result = try core.regenerateAssistantMessageWithTarget(
            conversationId: conversationID,
            branchId: branchID,
            expectedHead: expectedHeadMessageID,
            messageId: messageID,
            target: Self.mapGenerationTarget(target),
            credential: credential
        )
        return CoreMessageActionGeneration(
            branch: Self.mapConversationBranch(result.branch),
            generationID: result.generationId
        )
    }

    public func removeMessageFromBranch(
        conversationID: String,
        branchID: String,
        expectedHeadMessageID: String?,
        messageID: String
    ) async throws -> CoreConversationBranch {
        try Self.mapConversationBranch(
            core.removeMessageFromBranch(
                conversationId: conversationID,
                branchId: branchID,
                expectedHead: expectedHeadMessageID,
                messageId: messageID
            )
        )
    }

    public func cancelGeneration(generationID: String) async throws {
        try core.cancelGeneration(generationId: generationID)
    }

    public func pollEvents(maxEvents: UInt32) async throws -> ChatEventBatch {
        let batch = try core.pollEvents(maxEvents: maxEvents)
        return ChatEventBatch(
            events: batch.events.map { event in
                ChatEvent(
                    eventVersion: event.eventVersion,
                    generationID: event.generationId,
                    conversationID: event.conversationId,
                    branchID: event.branchId,
                    assistantMessageID: event.assistantMessageId,
                    sequence: event.sequence,
                    emittedAt: event.emittedAt,
                    kind: event.kind,
                    text: event.text,
                    messageID: event.messageId,
                    messageStatus: event.messageStatus,
                    errorCode: event.errorCode,
                    errorMessage: event.errorMessage,
                    usageInputTokens: event.usageInputTokens,
                    usageOutputTokens: event.usageOutputTokens
                )
            },
            droppedEventCount: batch.droppedEventCount
        )
    }

    public func listProviderProfiles() async throws -> [ProviderProfile] {
        try core.listProviderProfiles().map(Self.mapProviderProfile)
    }

    public func upsertProviderProfile(
        _ profile: ProviderProfile
    ) async throws -> ProviderProfile {
        let saved = try core.upsertProviderProfile(
            profile: FfiProviderProfile(
                id: profile.id,
                displayName: profile.displayName,
                baseUrl: profile.baseURL,
                model: profile.model,
                timeoutSeconds: profile.timeoutSeconds
            )
        )
        return Self.mapProviderProfile(saved)
    }

    public func deleteProviderProfile(id: String) async throws {
        try core.deleteProviderProfile(profileId: id)
    }

    public func listProviderTemplates() async throws
        -> [ProviderTemplateDescriptor]
    {
        try core.listProviderTemplates().map(Self.mapProviderTemplate)
    }

    public func listProviderConnections() async throws
        -> [ProviderConnectionRecord]
    {
        try core.listProviderConnections().map(
            Self.mapProviderConnection
        )
    }

    public func deleteProviderConnection(id: String) async throws {
        try core.deleteProviderConnection(connectionId: id)
    }

    public func listProviderModelRoutes(
        connectionID: String
    ) async throws -> [ProviderModelRoute] {
        try core.listModelRoutes(connectionId: connectionID).map(
            Self.mapModelRoute
        )
    }

    public func listProviderGenerationPresets(
        modelRouteID: String
    ) async throws -> [ProviderGenerationPreset] {
        try core.listGenerationPresets(
            modelRouteId: modelRouteID
        ).map(Self.mapGenerationPreset)
    }

    public func upsertProviderGenerationPreset(
        _ preset: ProviderGenerationPreset
    ) async throws -> ProviderGenerationPreset {
        try Self.mapGenerationPreset(
            core.upsertGenerationPreset(
                preset: Self.mapGenerationPreset(preset)
            )
        )
    }

    public func validateProviderGenerationPreset(
        modelRouteID: String,
        generationPresetID: String
    ) async throws {
        try core.validateGenerationPreset(
            modelRouteId: modelRouteID,
            generationPresetId: generationPresetID
        )
    }

    public func validateProviderGenerationPresetCandidate(
        _ preset: ProviderGenerationPreset
    ) async throws {
        try core.validateGenerationPresetCandidate(
            preset: Self.mapGenerationPreset(preset)
        )
    }

    public func renderProviderReasoningControl(
        for preset: ProviderGenerationPreset
    ) async throws -> ProviderReasoningControl {
        try Self.mapReasoningControl(
            core.renderReasoningControlForPreset(
                preset: Self.mapGenerationPreset(preset)
            )
        )
    }

    public func renderProviderPromptCacheControl(
        for preset: ProviderGenerationPreset
    ) async throws -> ProviderPromptCacheControl {
        try Self.mapPromptCacheControl(
            core.renderPromptCacheControlForPreset(
                preset: Self.mapGenerationPreset(preset)
            )
        )
    }

    public func deleteProviderGenerationPreset(
        id: String
    ) async throws {
        try core.deleteGenerationPreset(generationPresetId: id)
    }

    public func listProviderCapabilities(
        modelRouteID: String
    ) async throws -> [ProviderEffectiveCapability] {
        let observations = try core.listCapabilityObservations(
            modelRouteId: modelRouteID
        )
        let keys = Set(observations.map(\.key)).sorted()
        return try keys.compactMap { key in
            try core.effectiveCapability(
                modelRouteId: modelRouteID,
                key: key
            ).map(Self.mapEffectiveCapability)
        }
    }

    public func listProviderParameterSpecs(
        modelRouteID: String
    ) async throws -> [ProviderParameterSpec] {
        try core.effectiveParameterSpecs(
            modelRouteId: modelRouteID
        ).map(Self.mapParameterSpec)
    }

    public func inspectProviderCurl(
        _ rawCurl: String,
        networkPolicy: ProviderNetworkPolicy
    ) async throws -> ProviderCurlInspection {
        let inspection = try core.inspectProviderCurl(
            rawCurl: rawCurl,
            networkPolicy: FfiProviderNetworkPolicy(
                networkMode: Self.mapProviderNetworkMode(
                    networkPolicy.mode
                ),
                localNetworkApproval: Self.mapLocalNetworkApproval(
                    networkPolicy.localNetworkApproval
                )
            )
        )
        return ProviderCurlInspection(
            schemaVersion: inspection.inspectionSchemaVersion,
            sanitizedSiteURL: inspection.sanitizedSiteUrl,
            apiOrigin: inspection.apiOrigin,
            method: inspection.method,
            path: inspection.path,
            headerNames: inspection.headerNames,
            authBindingHint: inspection.authBindingHint.map(
                Self.authBindingDescription
            ),
            apiFamilyHint: inspection.apiFamilyHint,
            modelHint: inspection.modelHint,
            streamHint: inspection.streamHint,
            redactedCurl: inspection.redactedCurl,
            credentialHandoffID:
                inspection.credentialHandoffId
        )
    }

    public func takeProviderCurlCredential(
        handoffID: String
    ) async throws -> Data? {
        try core.takeProviderCurlCredential(
            credentialHandoffId: handoffID
        )
    }

    public func beginProviderDiscovery(
        input: ProviderDiscoveryInput,
        source: ProviderDiscoverySource,
        rawCurl: String?
    ) async throws -> ProviderDiscoverySnapshot {
        let snapshot = try core.beginProviderDiscovery(
            input: FfiProviderDiscoveryInput(
                connectionId: input.connectionID,
                displayName: input.displayName,
                siteUrl: input.siteURL,
                docsUrl: input.docsURL,
                credentialSlotReady: input.credentialSlotReady,
                preferredAssistantModelRouteId:
                    input.preferredAssistantModelRouteID,
                connectionOptions:
                    Self.mapDiscoveryConnectionOptions(
                        input.connectionOptions
                    ),
                suppliedEvidenceIds: input.suppliedEvidenceIDs
            ),
            source: Self.mapDiscoverySource(source),
            rawCurl: rawCurl
        )
        return try Self.mapProviderDiscoverySnapshot(snapshot)
    }

    public func prepareProviderDiscoveryAction(
        actionID: String,
        expectedRevision: UInt64,
        action: ProviderDiscoveryAction
    ) async throws -> ProviderDiscoveryActionEnvelope {
        try Self.mapDiscoveryActionEnvelope(
            core.prepareProviderDiscoveryAction(
                actionId: actionID,
                expectedRevision: expectedRevision,
                action: Self.mapDiscoveryAction(action)
            )
        )
    }

    public func continueProviderDiscovery(
        sessionID: String,
        envelope: ProviderDiscoveryActionEnvelope,
        targetCredential: String?
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.continueProviderDiscovery(
                sessionId: sessionID,
                envelope: Self.mapDiscoveryActionEnvelope(envelope),
                targetCredential: targetCredential
            )
        )
    }

    public func supplyProviderDiscoveryDocumentEvidence(
        sessionID: String,
        expectedRevision: UInt64,
        documentURL: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.supplyProviderDiscoveryDocumentEvidence(
                sessionId: sessionID,
                expectedRevision: expectedRevision,
                documentUrl: documentURL
            )
        )
    }

    public func supplyProviderDiscoveryCurlEvidence(
        sessionID: String,
        expectedRevision: UInt64,
        redactedCurl: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.supplyProviderDiscoveryCurlEvidence(
                sessionId: sessionID,
                expectedRevision: expectedRevision,
                rawCurl: redactedCurl
            )
        )
    }

    public func runProviderDiscoveryAssistantTurn(
        sessionID: String,
        estimate: ProviderDiscoveryAssistantCallEstimate,
        assistantCredential: String?
    ) async throws -> ProviderDiscoveryAssistantHostAction {
        try Self.mapDiscoveryAssistantHostAction(
            core.runProviderDiscoveryAssistantTurn(
                sessionId: sessionID,
                estimate: FfiDiscoveryAssistantCallEstimate(
                    inputTokens: estimate.inputTokens,
                    maximumOutputTokens:
                        estimate.maximumOutputTokens,
                    maximumCostMicroUnits:
                        estimate.maximumCostMicroUnits
                ),
                assistantCredential: assistantCredential
            )
        )
    }

    public func resumeProviderDiscoveryAssistantCoreHostAction(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core
                .resumeProviderDiscoveryAssistantCoreHostAction(
                    sessionId: sessionID
                )
        )
    }

    public func approveProviderDiscoveryAssistantRetry(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.approveProviderDiscoveryAssistantRetry(
                sessionId: sessionID
            )
        )
    }

    public func requestProviderDiscoveryAssistantRevision(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.requestProviderDiscoveryAssistantRevision(
                sessionId: sessionID
            )
        )
    }

    public func acceptProviderDiscoveryAssistantDraft(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.acceptProviderDiscoveryAssistantDraft(
                sessionId: sessionID
            )
        )
    }

    public func recordProviderDiscoveryAssistantFailure(
        sessionID: String,
        kind: String,
        retryable: Bool
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.recordProviderDiscoveryAssistantFailure(
                sessionId: sessionID,
                kind: kind,
                retryable: retryable
            )
        )
    }

    public func getProviderDiscovery(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.getProviderDiscovery(sessionId: sessionID)
        )
    }

    public func listProviderDiscoveries(
        limit: UInt32
    ) async throws -> [ProviderDiscoverySnapshot] {
        try core.listProviderDiscoveries(limit: limit).map(
            Self.mapProviderDiscoverySnapshot
        )
    }

    public func cancelProviderDiscovery(
        sessionID: String,
        expectedRevision: UInt64
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.cancelProviderDiscovery(
                sessionId: sessionID,
                expectedRevision: expectedRevision
            )
        )
    }

    public func commitProviderDiscovery(
        sessionID: String,
        credentialSlotConfirmed: Bool
    ) async throws -> ProviderConnectionRecord {
        Self.mapProviderConnection(
            try core.commitProviderDiscovery(
                sessionId: sessionID,
                credentialReferenceConfirmed:
                    credentialSlotConfirmed
            )
        )
    }

    public func listProviderDiscoveryCompensationSteps(
        commitAttemptID: String
    ) async throws -> [ProviderDiscoveryCompensationStep] {
        try core.listProviderDiscoveryCompensationSteps(
            commitAttemptId: commitAttemptID
        ).map(Self.mapDiscoveryCompensationStep)
    }

    public func continueProviderDiscoveryCompensation(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.continueProviderDiscoveryCompensation(
                sessionId: sessionID
            )
        )
    }

    public func startProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoveryCompensationStep {
        try Self.mapDiscoveryCompensationStep(
            core.startProviderDiscoveryCredentialCompensation(
                sessionId: sessionID,
                stepId: stepID
            )
        )
    }

    public func completeProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.completeProviderDiscoveryCredentialCompensation(
                sessionId: sessionID,
                stepId: stepID
            )
        )
    }

    public func failProviderDiscoveryCredentialCompensation(
        sessionID: String,
        stepID: String,
        failure: ProviderDiscoveryFailure
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.failProviderDiscoveryCredentialCompensation(
                sessionId: sessionID,
                stepId: stepID,
                failure: Self.mapDiscoveryFailure(failure)
            )
        )
    }

    public func markProviderDiscoveryCredentialCompensationUnknown(
        sessionID: String,
        stepID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.markProviderDiscoveryCredentialCompensationUnknown(
                sessionId: sessionID,
                stepId: stepID
            )
        )
    }

    public func resumeProviderDiscoveryCompensation(
        sessionID: String
    ) async throws -> ProviderDiscoverySnapshot {
        try Self.mapProviderDiscoverySnapshot(
            core.resumeProviderDiscoveryCompensation(
                sessionId: sessionID
            )
        )
    }

    public func recoverProviderDiscoveries() async throws
        -> [ProviderDiscoveryRecoveryResult]
    {
        try core.recoverProviderDiscoveries().map(
            Self.mapDiscoveryRecoveryResult
        )
    }

    public func pollProviderDiscoveryEvents(
        limit: UInt32
    ) async throws -> [ProviderDiscoveryOutboxEvent] {
        try core.pollProviderDiscoveryEvents(limit: limit).map(
            Self.mapDiscoveryOutboxEvent
        )
    }

    public func ackProviderDiscoveryEvent(
        eventID: String
    ) async throws -> Bool {
        try core.ackProviderDiscoveryEvent(eventId: eventID)
    }

    public func startProviderModelSync(
        connectionID: String,
        credential: String?
    ) async throws -> ProviderModelSyncJob {
        let jobID = try core.startProviderModelSync(
            connectionId: connectionID,
            credential: credential
        )
        return try Self.mapModelSyncJob(
            core.getProviderModelSync(jobId: jobID)
        )
    }

    public func getProviderModelSync(
        jobID: String
    ) async throws -> ProviderModelSyncJob {
        try Self.mapModelSyncJob(
            core.getProviderModelSync(jobId: jobID)
        )
    }

    public func listProviderModelSyncs(
        connectionID: String,
        limit: UInt32
    ) async throws -> [ProviderModelSyncJob] {
        try core.listProviderModelSyncs(
            connectionId: connectionID,
            limit: limit
        ).map(Self.mapModelSyncJob)
    }

    public func pollProviderModelSyncEvents(
        jobID: String,
        limit: UInt32
    ) async throws -> [ProviderModelSyncEvent] {
        try core.pollProviderModelSyncJobEvents(
            jobId: jobID,
            limit: limit
        ).map(Self.mapModelSyncEvent)
    }

    public func ackProviderModelSyncEvent(
        jobID: String,
        sequence: UInt64
    ) async throws -> Bool {
        try core.ackProviderModelSyncEvent(
            jobId: jobID,
            sequence: sequence
        )
    }

    public func approveProviderModelSync(
        jobID: String,
        expectedRevision: UInt64,
        reviewSHA256: String
    ) async throws -> ProviderModelSyncJob {
        let current = try core.getProviderModelSync(jobId: jobID)
        guard current.revision == expectedRevision else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 상태가 바뀌었습니다. 변경 내용을 다시 검토하세요."
            )
        }
        return try Self.mapModelSyncJob(
            core.approveProviderModelSync(
                jobId: jobID,
                reviewSha256: reviewSHA256
            )
        )
    }

    public func cancelProviderModelSync(
        jobID: String,
        expectedRevision: UInt64
    ) async throws -> ProviderModelSyncJob {
        let current = try core.getProviderModelSync(jobId: jobID)
        guard current.revision == expectedRevision else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 상태가 바뀌었습니다. 최신 상태를 확인하세요."
            )
        }
        return try Self.mapModelSyncJob(
            core.cancelProviderModelSync(jobId: jobID)
        )
    }

    public func getProviderCatalogStatus() async throws
        -> ProviderCatalogStatus
    {
        let status = try core.providerCatalogStatus()
        let history = try core.providerCatalogHistory(
            limit: 100,
            beforeRevision: nil,
            beforeStateVersion: nil
        )
        return Self.mapProviderCatalogStatus(
            status,
            history: history
        )
    }

    public func prepareSignedProviderCatalogImport(
        envelopeJSON: Data
    ) async throws -> ProviderCatalogImportPlan {
        try Self.mapCatalogImportPlan(
            core.prepareSignedProviderCatalogImport(
                envelopeJson: envelopeJSON
            )
        )
    }

    public func activateSignedProviderCatalogImport(
        plan: ProviderCatalogImportPlan,
        envelopeJSON: Data
    ) async throws -> ProviderCatalogImportResult {
        let activated =
            try core.activateSignedProviderCatalogImport(
                plan: Self.mapCatalogImportPlan(plan),
                envelopeJson: envelopeJSON
            )
        let status = try await getProviderCatalogStatus()
        return ProviderCatalogImportResult(
            signedCatalogRevision:
                activated.signedCatalogRevision,
            activatedRevision: activated.activatedRevision,
            diff: Self.mapCatalogDiff(activated.diff),
            status: status
        )
    }

    public func prepareProviderCatalogRollback(
        targetRevision: UInt64
    ) async throws -> ProviderCatalogRollbackPlan {
        Self.mapCatalogRollbackPlan(
            try core.prepareProviderCatalogRollback(
                targetRevision: targetRevision
            )
        )
    }

    public func activateProviderCatalogRollback(
        plan: ProviderCatalogRollbackPlan
    ) async throws -> ProviderCatalogRollbackResult {
        let result = try core.activateProviderCatalogRollback(
            plan: Self.mapCatalogRollbackPlan(plan)
        )
        let status = try await getProviderCatalogStatus()
        return ProviderCatalogRollbackResult(
            fromRevision: result.fromRevision,
            activatedRevision: result.activatedRevision,
            status: status
        )
    }

    public func previewProviderRequest(
        modelRouteID: String,
        generationPresetID: String
    ) async throws -> ProviderRequestPreview {
        try Self.mapRequestPreview(
            core.previewProviderRequest(
                modelRouteId: modelRouteID,
                generationPresetId: generationPresetID
            )
        )
    }

    public func previewProviderRequestCandidate(
        _ preset: ProviderGenerationPreset
    ) async throws -> ProviderRequestPreview {
        try Self.mapRequestPreview(
            core.previewProviderRequestCandidate(
                preset: Self.mapGenerationPreset(preset)
            )
        )
    }

    public func getSettings() async throws -> CoreAppSettings {
        try Self.mapSettings(core.getSettings())
    }

    public func updateSettings(
        _ settings: CoreAppSettings
    ) async throws -> CoreAppSettings {
        let updated = try core.updateSettings(
            settings: FfiAppSettings(
                preservePartialGenerations: settings.preservePartialGenerations,
                selectedProviderProfileId: settings.selectedProviderProfileID,
                selectedModelRouteId: settings.selectedModelRouteID,
                selectedGenerationPresetId:
                    settings.selectedGenerationPresetID
            )
        )
        return Self.mapSettings(updated)
    }

    public func setPreservePartialGenerations(
        _ value: Bool
    ) async throws -> CoreAppSettings {
        let current = try core.getSettings()
        let updated = try core.updateSettings(
            settings: FfiAppSettings(
                preservePartialGenerations: value,
                selectedProviderProfileId:
                    current.selectedProviderProfileId,
                selectedModelRouteId: current.selectedModelRouteId,
                selectedGenerationPresetId:
                    current.selectedGenerationPresetId
            )
        )
        return Self.mapSettings(updated)
    }

    public func selectProviderProfile(
        id: String?
    ) async throws -> CoreAppSettings {
        let current = try core.getSettings()
        let updated = try core.updateSettings(
            settings: FfiAppSettings(
                preservePartialGenerations:
                    current.preservePartialGenerations,
                selectedProviderProfileId: id,
                selectedModelRouteId: nil,
                selectedGenerationPresetId: nil
            )
        )
        return Self.mapSettings(updated)
    }

    public func selectProviderGenerationTarget(
        _ target: ProviderGenerationTarget?
    ) async throws -> CoreAppSettings {
        try Self.mapSettings(
            core.selectGenerationTarget(
                target: target.map(Self.mapGenerationTarget)
            )
        )
    }

    public func databaseStats() async throws -> DatabaseStats {
        let stats = try core.databaseStats()
        return DatabaseStats(
            characters: stats.characters,
            conversations: stats.conversations,
            messages: stats.messages,
            pendingImports: stats.pendingImports
        )
    }

    private static func mapCharacter(_ character: FfiCharacter) -> CoreCharacter {
        CoreCharacter(
            id: character.id,
            name: character.name,
            description: character.description,
            sourceHash: character.sourceHash,
            avatarAssetHash: character.avatarAssetHash,
            createdAt: character.createdAt
        )
    }

    private static func mapConversation(
        _ conversation: FfiConversation
    ) -> CoreConversation {
        CoreConversation(
            id: conversation.id,
            characterID: conversation.characterId,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt
        )
    }

    private static func mapConversationBranch(
        _ branch: FfiConversationBranch
    ) -> CoreConversationBranch {
        CoreConversationBranch(
            id: branch.id,
            conversationID: branch.conversationId,
            title: branch.title,
            forkMessageID: branch.forkMessageId,
            headMessageID: branch.headMessageId,
            createdAt: branch.createdAt,
            updatedAt: branch.updatedAt
        )
    }

    private static func mapConversationState(
        _ state: FfiConversationState
    ) throws -> CoreConversationState {
        guard let mode = ConversationMode(rawValue: state.selectedMode) else {
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 대화 모드입니다: \(state.selectedMode)"
            )
        }
        return CoreConversationState(
            conversationID: state.conversationId,
            activeBranchID: state.activeBranchId,
            selectedMode: mode,
            updatedAt: state.updatedAt
        )
    }

    private static func mapMessage(_ message: FfiMessage) -> ChatMessage {
        ChatMessage(
            id: message.id,
            conversationID: message.conversationId,
            parentID: message.parentId,
            role: ChatMessage.Role(rawValue: message.role) ?? .notice,
            text: message.content,
            status: ChatMessage.Status(rawValue: message.status) ?? .notice,
            generationID: message.generationId,
            createdAt: message.createdAt
        )
    }

    private static func mapProviderProfile(
        _ profile: FfiProviderProfile
    ) -> ProviderProfile {
        ProviderProfile(
            id: profile.id,
            displayName: profile.displayName,
            baseURL: profile.baseUrl,
            model: profile.model,
            timeoutSeconds: profile.timeoutSeconds
        )
    }

    private static func mapProviderTemplate(
        _ template: FfiProviderTemplate
    ) throws -> ProviderTemplateDescriptor {
        return ProviderTemplateDescriptor(
            id: template.id,
            displayName: template.displayName,
            manifestVersion: template.manifestVersion,
            source: template.source,
            apiFamily: template.apiFamily,
            defaultNetworkMode: mapProviderNetworkMode(
                template.defaultNetworkMode
            ),
            defaultAPIOrigin: template.defaultApiOrigin,
            requiresCredential: template.requiresCredential,
            supportsModelListing: template.supportsModelListing,
            connectionFields: template.connectionFields.map {
                ProviderConnectionField(
                    key: $0.key,
                    label: $0.labelKey,
                    description: $0.descriptionKey,
                    type: mapConnectionFieldType($0.valueType),
                    isRequired: $0.required
                )
            },
            parameters: template.parameters.map(mapParameterSpec)
        )
    }

    private static func mapConnectionFieldType(
        _ type: FfiConnectionFieldType
    ) -> ProviderConnectionFieldType {
        switch type {
        case .text:
            .text
        case .integer:
            .integer
        case .boolean:
            .boolean
        case .credential:
            .credential
        }
    }

    private static func mapParameterSpec(
        _ spec: FfiParameterSpec
    ) -> ProviderParameterSpec {
        ProviderParameterSpec(
            id: spec.id,
            label: spec.labelKey,
            description: spec.descriptionKey,
            type: mapParameterType(spec.valueType),
            choices: spec.allowedValues.map {
                ProviderParameterChoice(
                    value: mapParameterLiteral($0.value),
                    label: $0.labelKey
                )
            },
            minimum: spec.minimum,
            maximum: spec.maximum,
            step: spec.step,
            defaultMode: mapParameterDefaultMode(
                spec.defaultMode
            ),
            visibility: spec.visibility.map {
                ProviderParameterCondition(
                    parameterID: $0.parameterId,
                    conditionOperator: mapParameterConditionOperator(
                        $0.operator
                    ),
                    value: mapParameterLiteral($0.value)
                )
            },
            conflicts: spec.conflicts.map {
                ProviderParameterConflict(
                    parameterID: $0.parameterId,
                    kind: mapParameterConflictKind($0.kind),
                    message: $0.messageKey
                )
            },
            providerMapping: ProviderParameterMapping(
                target: mapParameterTarget(
                    spec.providerMapping.target
                ),
                fieldName: spec.providerMapping.fieldName
            ),
            level: mapParameterLevel(spec.level)
        )
    }

    private static func mapParameterType(
        _ type: FfiParameterType
    ) -> ProviderParameterType {
        switch type {
        case .boolean:
            .boolean
        case .integer:
            .integer
        case .number:
            .number
        case .string:
            .string
        case .enum:
            .enumeration
        case .stringList:
            .stringList
        case .jsonSchema:
            .jsonSchema
        case .stopSequenceList:
            .stopSequenceList
        case .toolPolicy:
            .toolPolicy
        }
    }

    private static func mapParameterDefaultMode(
        _ mode: FfiParameterDefaultMode
    ) -> ProviderParameterDefaultMode {
        switch mode {
        case .providerDefault:
            .providerDefault
        case .explicitRequired:
            .explicitRequired
        }
    }

    private static func mapParameterConditionOperator(
        _ value: FfiParameterConditionOperator
    ) -> ProviderParameterConditionOperator {
        switch value {
        case .equals:
            .equals
        case .notEquals:
            .notEquals
        }
    }

    private static func mapParameterConflictKind(
        _ value: FfiParameterConflictKind
    ) -> ProviderParameterConflictKind {
        switch value {
        case .mutuallyExclusive:
            .mutuallyExclusive
        case .requires:
            .requires
        }
    }

    private static func mapParameterTarget(
        _ value: FfiProviderParameterTarget
    ) -> ProviderParameterTarget {
        switch value {
        case .requestBody:
            .requestBody
        case .requestHeader:
            .requestHeader
        }
    }

    private static func mapParameterLevel(
        _ level: FfiUiParameterLevel
    ) -> ProviderParameterLevel {
        switch level {
        case .basic:
            .basic
        case .advanced:
            .advanced
        case .expert:
            .expert
        case .hiddenInternal:
            .hidden
        }
    }

    private static func mapParameterLiteral(
        _ literal: FfiParameterLiteral
    ) -> ProviderParameterLiteral {
        switch literal {
        case let .boolean(value):
            .boolean(value)
        case let .integer(value):
            .integer(value)
        case let .number(value):
            .number(value)
        case let .string(value):
            .string(value)
        case let .enum(value):
            .enumeration(value)
        case let .stringList(values):
            .stringList(values)
        case let .jsonSchema(value):
            .jsonSchema(value)
        case let .stopSequenceList(values):
            .stopSequenceList(values)
        case let .toolPolicy(value):
            .toolPolicy(mapToolPolicy(value))
        }
    }

    private static func mapToolPolicy(
        _ policy: FfiToolPolicy
    ) -> String {
        switch policy {
        case .none:
            "none"
        case .auto:
            "auto"
        case .required:
            "required"
        }
    }

    private static func mapProviderConnection(
        _ connection: FfiProviderConnection
    ) -> ProviderConnectionRecord {
        ProviderConnectionRecord(
            id: connection.id,
            templateID: connection.templateId,
            templateVersion: connection.templateVersion,
            displayName: connection.displayName,
            apiOrigin: connection.apiOrigin,
            apiBasePath: connection.apiBasePath,
            networkMode: mapProviderNetworkMode(
                connection.networkMode
            ).rawValue,
            localNetworkApproval:
                connection.localNetworkApproval.map {
                    ProviderLocalNetworkApproval(
                        origin: $0.origin,
                        addresses: $0.addresses
                    )
                },
            values: connection.values.map(mapConnectionConfigEntry),
            hasCredential: connection.credentialSlotReady,
            approvedCredentialOrigins:
                connection.approvedCredentialOrigins,
            timeoutSeconds: connection.timeoutSeconds,
            status: connection.status,
            createdAt: connection.createdAt,
            updatedAt: connection.updatedAt
        )
    }

    private static func mapProviderNetworkMode(
        _ mode: FfiProviderNetworkMode
    ) -> ProviderNetworkMode {
        switch mode {
        case .public:
            .publicInternet
        case .localLoopback:
            .localLoopback
        case .approvedLocalNetwork:
            .approvedLocalNetwork
        }
    }

    private static func mapProviderNetworkMode(
        _ mode: ProviderNetworkMode
    ) -> FfiProviderNetworkMode {
        switch mode {
        case .publicInternet:
            .public
        case .localLoopback:
            .localLoopback
        case .approvedLocalNetwork:
            .approvedLocalNetwork
        }
    }

    private static func mapLocalNetworkApproval(
        _ approval: ProviderLocalNetworkApproval?
    ) -> FfiProviderLocalNetworkApproval? {
        approval.map {
            FfiProviderLocalNetworkApproval(
                origin: $0.origin,
                addresses: $0.addresses
            )
        }
    }

    private static func mapDiscoveryConnectionOptions(
        _ options: ProviderDiscoveryConnectionOptions
    ) -> FfiProviderDiscoveryConnectionOptions {
        FfiProviderDiscoveryConnectionOptions(
            values: options.values.map(mapConnectionConfigEntry),
            apiBasePath: options.apiBasePath,
            timeoutSeconds: options.timeoutSeconds,
            networkMode: mapProviderNetworkMode(
                options.networkMode
            ),
            localNetworkApproval: mapLocalNetworkApproval(
                options.localNetworkApproval
            )
        )
    }

    private static func mapDiscoveryConnectionOptions(
        _ options: FfiProviderDiscoveryConnectionOptions
    ) -> ProviderDiscoveryConnectionOptions {
        ProviderDiscoveryConnectionOptions(
            values: options.values.map(mapConnectionConfigEntry),
            apiBasePath: options.apiBasePath,
            timeoutSeconds: options.timeoutSeconds,
            networkMode: mapProviderNetworkMode(
                options.networkMode
            ),
            localNetworkApproval:
                options.localNetworkApproval.map {
                    ProviderLocalNetworkApproval(
                        origin: $0.origin,
                        addresses: $0.addresses
                    )
                }
        )
    }

    private static func mapConnectionConfigEntry(
        _ entry: ProviderConfigurationEntry
    ) -> FfiConnectionConfigEntry {
        FfiConnectionConfigEntry(
            key: entry.key,
            value: mapConnectionConfigValue(entry.value)
        )
    }

    private static func mapConnectionConfigValue(
        _ value: ProviderConfigurationValue
    ) -> FfiConnectionConfigValue {
        switch value {
        case let .text(value):
            .text(value: value)
        case let .integer(value):
            .integer(value: value)
        case let .boolean(value):
            .boolean(value: value)
        }
    }

    private static func mapDiscoverySource(
        _ source: ProviderDiscoverySource
    ) -> FfiProviderDiscoverySource {
        switch source {
        case let .knownProvider(templateID):
            .knownProvider(templateId: templateID)
        case .site:
            .site
        case .curl:
            .curl
        }
    }

    private static func mapDiscoveryAction(
        _ action: ProviderDiscoveryAction
    ) -> FfiProviderDiscoveryAction {
        switch action {
        case let .selectTemplate(candidateID):
            .selectTemplate(candidateId: candidateID)
        case .continueWithoutTemplate:
            .continueWithoutTemplate
        case let .supplyMoreEvidence(evidenceIDs):
            .supplyMoreEvidence(evidenceIds: evidenceIDs)
        case .requestAssistant:
            .requestAssistant
        case let .approveAssistant(approvalID, grantSHA256):
            .approveAssistant(
                approvalId: approvalID,
                approvalGrantSha256: grantSHA256
            )
        case .declineAssistant:
            .declineAssistant
        case let .approveCredentialOrigin(approvalID):
            .approveCredentialOrigin(approvalId: approvalID)
        case let .approveProbes(approvalID, grantSHA256):
            .approveProbes(
                approvalId: approvalID,
                approvalGrantSha256: grantSHA256
            )
        case .skipProbes:
            .skipProbes
        case let .approveReview(
            approvalID,
            commitAttemptID,
            commitPlanSHA256,
            graphSHA256
        ):
            .approveReview(
                approvalId: approvalID,
                commitAttemptId: commitAttemptID,
                commitPlanSha256: commitPlanSHA256,
                graphSha256: graphSHA256
            )
        case .resumeCompensation:
            .resumeCompensation
        case .restartInterrupted:
            .restartInterrupted
        case let .resolveUnknownOutcome(approvalID, resolution):
            .resolveUnknownOutcome(
                approvalId: approvalID,
                resolution: mapDiscoveryUnknownOutcomeResolution(
                    resolution
                )
            )
        case .cancel:
            .cancel
        }
    }

    private static func mapDiscoveryAction(
        _ action: FfiProviderDiscoveryAction
    ) -> ProviderDiscoveryAction {
        switch action {
        case let .selectTemplate(candidateID):
            .selectTemplate(candidateID: candidateID)
        case .continueWithoutTemplate:
            .continueWithoutTemplate
        case let .supplyMoreEvidence(evidenceIDs):
            .supplyMoreEvidence(evidenceIDs: evidenceIDs)
        case .requestAssistant:
            .requestAssistant
        case let .approveAssistant(approvalID, grantSHA256):
            .approveAssistant(
                approvalID: approvalID,
                grantSHA256: grantSHA256
            )
        case .declineAssistant:
            .declineAssistant
        case let .approveCredentialOrigin(approvalID):
            .approveCredentialOrigin(approvalID: approvalID)
        case let .approveProbes(approvalID, grantSHA256):
            .approveProbes(
                approvalID: approvalID,
                grantSHA256: grantSHA256
            )
        case .skipProbes:
            .skipProbes
        case let .approveReview(
            approvalID,
            commitAttemptID,
            commitPlanSHA256,
            graphSHA256
        ):
            .approveReview(
                approvalID: approvalID,
                commitAttemptID: commitAttemptID,
                commitPlanSHA256: commitPlanSHA256,
                graphSHA256: graphSHA256
            )
        case .resumeCompensation:
            .resumeCompensation
        case .restartInterrupted:
            .restartInterrupted
        case let .resolveUnknownOutcome(approvalID, resolution):
            .resolveUnknownOutcome(
                approvalID: approvalID,
                resolution: mapDiscoveryUnknownOutcomeResolution(
                    resolution
                )
            )
        case .cancel:
            .cancel
        }
    }

    private static func mapDiscoveryUnknownOutcomeResolution(
        _ resolution: ProviderDiscoveryUnknownOutcomeResolution
    ) -> FfiDiscoveryUnknownOutcomeResolution {
        switch resolution {
        case .confirmedNoEffect:
            .confirmedNoEffect
        case let .confirmedCommitCompleted(connectionID):
            .confirmedCommitCompleted(
                connectionId: connectionID
            )
        case .confirmedCompensated:
            .confirmedCompensated
        case .manuallyReconciledAsFailed:
            .manuallyReconciledAsFailed
        }
    }

    private static func mapDiscoveryUnknownOutcomeResolution(
        _ resolution: FfiDiscoveryUnknownOutcomeResolution
    ) -> ProviderDiscoveryUnknownOutcomeResolution {
        switch resolution {
        case .confirmedNoEffect:
            .confirmedNoEffect
        case let .confirmedCommitCompleted(connectionID):
            .confirmedCommitCompleted(
                connectionID: connectionID
            )
        case .confirmedCompensated:
            .confirmedCompensated
        case .manuallyReconciledAsFailed:
            .manuallyReconciledAsFailed
        }
    }

    private static func mapDiscoveryActionEnvelope(
        _ envelope: ProviderDiscoveryActionEnvelope
    ) -> FfiProviderDiscoveryActionEnvelope {
        FfiProviderDiscoveryActionEnvelope(
            actionId: envelope.actionID,
            expectedRevision: envelope.expectedRevision,
            requestSha256: envelope.requestSHA256,
            action: mapDiscoveryAction(envelope.action)
        )
    }

    private static func mapDiscoveryActionEnvelope(
        _ envelope: FfiProviderDiscoveryActionEnvelope
    ) throws -> ProviderDiscoveryActionEnvelope {
        ProviderDiscoveryActionEnvelope(
            actionID: envelope.actionId,
            expectedRevision: envelope.expectedRevision,
            requestSHA256: envelope.requestSha256,
            action: mapDiscoveryAction(envelope.action)
        )
    }

    private static func mapProviderDiscoverySnapshot(
        _ snapshot: FfiProviderDiscoverySnapshot
    ) throws -> ProviderDiscoverySnapshot {
        try CoreRuntimeContract
            .validateProviderDiscoverySnapshotVersion(
                snapshot.snapshotSchemaVersion
            )
        let state = try mapDiscoveryState(snapshot.state)
        let reviewProposal = try snapshot.reviewProposal.map(
            mapDiscoveryReviewProposal
        )
        let review = if let reviewProposal {
            reviewProposal.review
        } else {
            try snapshot.review.map {
                try mapDiscoveryReview($0, requestPreview: nil)
            }
        }
        let actionRequired = try snapshot.actionRequired.map {
            try mapDiscoveryActionRequired(
                $0,
                proposal: snapshot.approvalProposal
            )
        }
        let unknownProposal = try snapshot.approvalProposal.flatMap {
            try mapUnknownOutcomeProposal($0)
        }
        return ProviderDiscoverySnapshot(
            schemaVersion: snapshot.snapshotSchemaVersion,
            id: snapshot.sessionId,
            pendingConnectionID: snapshot.pendingConnectionId,
            pendingDisplayName: snapshot.pendingDisplayName,
            connectionOptions: mapDiscoveryConnectionOptions(
                snapshot.connectionOptions
            ),
            credentialSlotID: snapshot.credentialSlotId,
            credentialSlotExpected:
                snapshot.credentialSlotExpected,
            revision: snapshot.revision,
            nextEventSequence: snapshot.nextEventSequence,
            state: state,
            steps: try snapshot.steps.map(mapDiscoveryStep),
            actionRequired: actionRequired,
            activeOperationID: snapshot.activeOperationId,
            recoveryOperation: snapshot.recoveryOperation.map(
                mapDiscoveryOperation
            ),
            unknownOperation: snapshot.unknownOperation.map(
                mapDiscoveryOperation
            ),
            manifestSHA256: snapshot.manifestSha256,
            commitPlanSHA256: snapshot.commitPlanSha256,
            commitAttemptID: snapshot.commitAttemptId,
            committedConnectionID:
                snapshot.committedConnectionId,
            cancellationPending: snapshot.cancellationPending,
            candidates: snapshot.candidates.map(
                mapDiscoveryCandidate
            ),
            evidence: snapshot.evidence.map(
                mapDiscoveryEvidence
            ),
            review: review,
            reviewProposal: reviewProposal,
            assistantApprovalBinding:
                mapDiscoveryAssistantApprovalBinding(
                    snapshot.approvals
                ),
            assistantResumeBoundary:
                snapshot.assistantResumeBoundary.map(
                    mapDiscoveryAssistantResumeBoundary
                ),
            unknownOutcomeProposal: unknownProposal,
            warnings: [],
            failureMessageKey: snapshot.failure?.messageKey,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt
        )
    }

    private static func mapDiscoveryAssistantApprovalBinding(
        _ approvals: [FfiDiscoveryApproval]
    ) -> ProviderDiscoveryAssistantApprovalBinding? {
        let approved = approvals
            .filter { $0.decision == .approved }
            .sorted { $0.sessionRevision < $1.sessionRevision }
        for approval in approved.reversed() {
            guard case let .assistantConsent(
                assistantModelRouteID,
                _,
                _,
                maximumCalls,
                maximumInputTokens,
                maximumOutputTokens,
                maximumToolCalls,
                maximumRetries,
                maximumCostMicroUnits
            ) = approval.grant
            else {
                continue
            }
            return ProviderDiscoveryAssistantApprovalBinding(
                assistantModelRouteID: assistantModelRouteID,
                maximumCalls: maximumCalls,
                maximumInputTokens: maximumInputTokens,
                maximumOutputTokens: maximumOutputTokens,
                maximumToolCalls: maximumToolCalls,
                maximumRetries: maximumRetries,
                maximumCostMicroUnits: maximumCostMicroUnits
            )
        }
        return nil
    }

    private static func mapDiscoveryAssistantHostAction(
        _ action: FfiDiscoveryAssistantHostAction
    ) throws -> ProviderDiscoveryAssistantHostAction {
        switch action {
        case let .requestMoreEvidence(sessionID, questions):
            .requestMoreEvidence(
                sessionID: sessionID,
                questions: questions.map(
                    mapDiscoveryAssistantQuestion
                )
            )
        case let .reviewDraft(review):
            .reviewDraft(
                mapDiscoveryAssistantDraftReview(review)
            )
        }
    }

    private static func mapDiscoveryAssistantResumeBoundary(
        _ boundary: FfiDiscoveryAssistantResumeBoundary
    ) -> ProviderDiscoveryAssistantResumeBoundary {
        ProviderDiscoveryAssistantResumeBoundary(
            checkpoint: boundary.checkpoint.map(
                mapDiscoveryAssistantCheckpoint
            ),
            action: mapDiscoveryAssistantResumeAction(
                boundary.action
            ),
            questions: boundary.questions.map(
                mapDiscoveryAssistantQuestion
            ),
            draftReview: boundary.draftReview.map(
                mapDiscoveryAssistantDraftReview
            )
        )
    }

    private static func mapDiscoveryAssistantCheckpoint(
        _ checkpoint: FfiDiscoveryAssistantCheckpoint
    ) -> ProviderDiscoveryAssistantCheckpoint {
        switch checkpoint {
        case .ready: .ready
        case .awaitingAssistant: .awaitingAssistant
        case .awaitingToolResult: .awaitingToolResult
        case .awaitingMoreEvidence: .awaitingMoreEvidence
        case .awaitingRetryConsent: .awaitingRetryConsent
        case .draftReady: .draftReady
        }
    }

    private static func mapDiscoveryAssistantResumeAction(
        _ action: FfiDiscoveryAssistantResumeAction
    ) -> ProviderDiscoveryAssistantResumeAction {
        switch action {
        case .approveConsent: .approveConsent
        case .runAssistant: .runAssistant
        case .waitForAssistantOutcome: .waitForAssistantOutcome
        case .resumeCoreHostAction: .resumeCoreHostAction
        case .supplyMoreEvidence: .supplyMoreEvidence
        case .approveRetry: .approveRetry
        case .reviewDraft: .reviewDraft
        case .restartInterrupted: .restartInterrupted
        case .resolveUnknownOutcome: .resolveUnknownOutcome
        }
    }

    private static func mapDiscoveryAssistantQuestion(
        _ question: FfiDiscoveryAssistantQuestion
    ) -> ProviderDiscoveryAssistantQuestion {
        ProviderDiscoveryAssistantQuestion(
            id: question.id,
            field: question.field.map(
                mapDiscoveryAssistantDraftField
            ),
            question: question.question,
            requiredEvidence: question.requiredEvidence
        )
    }

    private static func mapDiscoveryAssistantDraftField(
        _ field: FfiDiscoveryAssistantDraftField
    ) -> ProviderDiscoveryAssistantDraftField {
        switch field {
        case .apiFamily: .apiFamily
        case .defaultApiOrigin: .defaultAPIOrigin
        case .auth: .auth
        case .generateEndpoint: .generateEndpoint
        case .modelsEndpoint: .modelsEndpoint
        case .responseDecoder: .responseDecoder
        case .streamingDecoder: .streamingDecoder
        case let .parameter(parameterID):
            .parameter(id: parameterID)
        }
    }

    private static func mapDiscoveryAssistantDraftReview(
        _ review: FfiDiscoveryAssistantDraftReview
    ) -> ProviderDiscoveryAssistantDraftReview {
        ProviderDiscoveryAssistantDraftReview(
            draft: mapDiscoveryAssistantManifestDraft(
                review.draft
            ),
            unresolvedConflicts: review.unresolvedConflicts.map(
                mapDiscoveryAssistantDraftField
            ),
            requiredChecks: review.requiredChecks.map(
                mapDiscoveryAssistantDraftReviewCheck
            ),
            persistence:
                mapDiscoveryAssistantDraftPersistence(
                    review.persistence
                )
        )
    }

    private static func mapDiscoveryAssistantDraftReviewCheck(
        _ check: FfiDiscoveryAssistantDraftReviewCheck
    ) -> ProviderDiscoveryAssistantDraftReviewCheck {
        switch check {
        case .manifestValidation: .manifestValidation
        case .urlPolicyValidation: .urlPolicyValidation
        case .credentialOriginApproval: .credentialOriginApproval
        case .userReview: .userReview
        }
    }

    private static func mapDiscoveryAssistantDraftPersistence(
        _ persistence: FfiDiscoveryAssistantDraftPersistence
    ) -> ProviderDiscoveryAssistantDraftPersistence {
        switch persistence {
        case .blockedUntilChecksPass: .blockedUntilChecksPass
        }
    }

    private static func mapDiscoveryAssistantManifestDraft(
        _ draft: FfiDiscoveryAssistantManifestDraft
    ) -> ProviderDiscoveryAssistantManifestDraft {
        ProviderDiscoveryAssistantManifestDraft(
            manifest: mapDiscoveryAssistantManifest(
                draft.manifest
            ),
            evidenceMappings: draft.evidenceMappings.map {
                ProviderDiscoveryAssistantEvidenceMapping(
                    field: mapDiscoveryAssistantDraftField(
                        $0.field
                    ),
                    evidenceIDs: $0.evidenceIds,
                    explanation: $0.explanation
                )
            },
            conflicts: draft.conflicts.map {
                ProviderDiscoveryAssistantEvidenceConflict(
                    field: mapDiscoveryAssistantDraftField(
                        $0.field
                    ),
                    evidenceIDs: $0.evidenceIds,
                    disposition:
                        mapDiscoveryAssistantConflictDisposition(
                            $0.disposition
                        )
                )
            },
            unresolvedQuestions: draft.unresolvedQuestions.map(
                mapDiscoveryAssistantQuestion
            ),
            confidence: draft.confidence.map {
                ProviderDiscoveryAssistantFieldConfidence(
                    field: mapDiscoveryAssistantDraftField(
                        $0.field
                    ),
                    level:
                        mapDiscoveryAssistantConfidenceLevel(
                            $0.level
                        ),
                    rationale: $0.rationale
                )
            },
            summary: draft.summary
        )
    }

    private static func mapDiscoveryAssistantConflictDisposition(
        _ disposition: FfiDiscoveryAssistantConflictDisposition
    ) -> ProviderDiscoveryAssistantConflictDisposition {
        switch disposition {
        case .unresolved:
            .unresolved
        case let .resolved(selectedEvidenceID, rationale):
            .resolved(
                selectedEvidenceID: selectedEvidenceID,
                rationale: rationale
            )
        }
    }

    private static func mapDiscoveryAssistantConfidenceLevel(
        _ level: FfiDiscoveryAssistantConfidenceLevel
    ) -> ProviderDiscoveryAssistantConfidenceLevel {
        switch level {
        case .unknown: .unknown
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
    }

    private static func mapDiscoveryAssistantManifest(
        _ manifest: FfiDiscoveryAssistantManifest
    ) -> ProviderDiscoveryAssistantManifest {
        ProviderDiscoveryAssistantManifest(
            schemaVersion: manifest.schemaVersion,
            apiFamily: mapDiscoveryAssistantAPIFamily(
                manifest.apiFamily
            ),
            sources: manifest.sources.map {
                ProviderDiscoveryAssistantManifestSource(
                    kind:
                        mapDiscoveryAssistantManifestSourceKind(
                            $0.kind
                        ),
                    url: $0.url,
                    contentSHA256: $0.contentSha256
                )
            },
            defaultAPIOrigin: manifest.defaultApiOrigin,
            authDescription: authBindingDescription(
                manifest.auth
            ),
            modelsEndpoint: manifest.modelsEndpoint.map(
                mapDiscoveryAssistantEndpoint
            ),
            generateEndpoint: mapDiscoveryAssistantEndpoint(
                manifest.generateEndpoint
            ),
            responseDecoder: mapDiscoveryAssistantDecoder(
                manifest.responseDecoder
            ),
            streamingDecoder: manifest.streamingDecoder.map(
                mapDiscoveryAssistantDecoder
            ),
            parameters: manifest.parameters.map(
                mapParameterSpec
            )
        )
    }

    private static func mapDiscoveryAssistantAPIFamily(
        _ family: FfiDiscoveryAssistantApiFamily
    ) -> ProviderDiscoveryAssistantAPIFamily {
        switch family {
        case .openAiResponses: .openAIResponses
        case .openAiChatCompletions: .openAIChatCompletions
        case .anthropicMessages: .anthropicMessages
        case .geminiGenerateContent: .geminiGenerateContent
        case .ollamaNative: .ollamaNative
        }
    }

    private static func mapDiscoveryAssistantManifestSourceKind(
        _ kind: FfiDiscoveryAssistantManifestSourceKind
    ) -> ProviderDiscoveryAssistantManifestSourceKind {
        switch kind {
        case .officialSite: .officialSite
        case .officialDocumentation: .officialDocumentation
        case .signedCatalog: .signedCatalog
        case .userSupplied: .userSupplied
        }
    }

    private static func mapDiscoveryAssistantEndpoint(
        _ endpoint: FfiDiscoveryAssistantEndpoint
    ) -> ProviderDiscoveryAssistantEndpoint {
        let method: ProviderDiscoveryAssistantHTTPMethod
        switch endpoint.method {
        case .get:
            method = .get
        case .post:
            method = .post
        }
        return ProviderDiscoveryAssistantEndpoint(
            method: method,
            path: endpoint.path
        )
    }

    private static func mapDiscoveryAssistantDecoder(
        _ decoder: FfiDiscoveryAssistantDecoder
    ) -> ProviderDiscoveryAssistantDecoder {
        switch decoder {
        case .openAiJsonV1: .openAIJSONV1
        case .openAiSseV1: .openAISSEV1
        case .anthropicJsonV1: .anthropicJSONV1
        case .anthropicSseV1: .anthropicSSEV1
        case .geminiJsonV1: .geminiJSONV1
        case .geminiSseV1: .geminiSSEV1
        case .ollamaJsonV1: .ollamaJSONV1
        case .ollamaJsonlV1: .ollamaJSONLV1
        }
    }

    private static func mapDiscoveryState(
        _ value: FfiDiscoveryState
    ) throws -> ProviderDiscoveryState {
        switch value {
        case .draft: .draft
        case .resolvingKnownProvider: .resolvingKnownProvider
        case .awaitingTemplateSelection: .awaitingTemplateSelection
        case .fetchingDocuments: .fetchingDocuments
        case .extractingEvidence: .extractingEvidence
        case .awaitingMoreEvidence: .awaitingMoreEvidence
        case .awaitingAssistantConsent: .awaitingAssistantConsent
        case .buildingDeterministicManifestDraft:
            .buildingDeterministicManifestDraft
        case .buildingAssistantManifestDraft:
            .buildingAssistantManifestDraft
        case .validatingManifest: .validatingManifest
        case .awaitingCredentialOriginApproval:
            .awaitingCredentialOriginApproval
        case .listingModels: .listingModels
        case .awaitingProbeConsent: .awaitingProbeConsent
        case .probingCapabilities: .probingCapabilities
        case .awaitingReview: .awaitingReview
        case .committing: .committing
        case .compensating: .compensating
        case .ready: .ready
        case .failed: .failed
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        case .unknownOutcome: .unknownOutcome
        }
    }

    private static func mapDiscoveryStep(
        _ step: FfiDiscoveryStep
    ) throws -> ProviderDiscoveryStep {
        let state: ProviderDiscoveryStepState = switch step.state {
        case .completed: .complete
        case .current: .active
        case .pending: .pending
        }
        return ProviderDiscoveryStep(
            id: step.id,
            title: step.titleKey,
            source: nil,
            state: state
        )
    }

    private static func mapDiscoveryActionRequired(
        _ required: FfiDiscoveryActionRequired,
        proposal: FfiDiscoveryApprovalProposal?
    ) throws -> ProviderDiscoveryActionRequired {
        switch required {
        case .selectTemplate:
            .selectTemplate
        case .supplyMoreEvidence:
            .supplyMoreEvidence
        case .approveAssistant:
            .assistantConsent(
                try mapAssistantConsentProposal(proposal)
            )
        case .approveCredentialOrigin:
            .credentialOrigin(
                try mapCredentialOriginProposal(proposal)
            )
        case .approveProbes:
            .capabilityProbe(
                try mapProbeProposal(proposal)
            )
        case .review:
            .review
        case let .restartInterrupted(operation):
            .restartInterrupted(
                mapDiscoveryOperation(operation)
            )
        case let .reconcileUnknownOutcome(operation):
            .reconcileUnknownOutcome(
                mapDiscoveryOperation(operation)
            )
        }
    }

    private static func mapDiscoveryOperation(
        _ operation: FfiDiscoveryOperationKind
    ) -> String {
        switch operation {
        case .resolveKnownProvider: "resolve_known_provider"
        case .fetchDocuments: "fetch_documents"
        case .extractEvidence: "extract_evidence"
        case .buildDeterministicManifestDraft:
            "build_deterministic_manifest_draft"
        case .buildAssistantManifestDraft:
            "build_assistant_manifest_draft"
        case .validateManifest: "validate_manifest"
        case .listModels: "list_models"
        case .probeCapabilities: "probe_capabilities"
        case .atomicCommit: "atomic_commit"
        case .compensation: "compensation"
        }
    }

    private static func mapAssistantConsentProposal(
        _ proposal: FfiDiscoveryApprovalProposal?
    ) throws -> ProviderDiscoveryAssistantConsent {
        guard let proposal,
              case let .assistantConsent(
                  assistantModelRouteID,
                  _,
                  allowedDocumentOrigins,
                  maxCalls,
                  maxInputTokens,
                  maxOutputTokens,
                  maxToolCalls,
                  maxRetries,
                  maxCostMicroUnits
              ) = proposal.grant
        else {
            throw CoreClientFailure.invalidResponse(
                "문서 분석 승인 제안이 snapshot에 없습니다."
            )
        }
        return ProviderDiscoveryAssistantConsent(
            approvalID: proposal.approvalId,
            grantSHA256: proposal.grantSha256,
            assistantModelRouteID: assistantModelRouteID,
            documentOrigins: allowedDocumentOrigins,
            maximumCalls: maxCalls,
            maximumInputTokens: maxInputTokens,
            maximumOutputTokens: maxOutputTokens,
            maximumToolCalls: maxToolCalls,
            maximumRetries: maxRetries,
            maximumCostMicroUnits: maxCostMicroUnits
        )
    }

    private static func mapCredentialOriginProposal(
        _ proposal: FfiDiscoveryApprovalProposal?
    ) throws -> ProviderCredentialOriginApproval {
        guard let proposal,
              case let .credentialOrigin(
                  origin,
                  authBinding,
                  manifestSHA256
              ) = proposal.grant
        else {
            throw CoreClientFailure.invalidResponse(
                "자격증명 origin 승인 제안이 snapshot에 없습니다."
            )
        }
        return ProviderCredentialOriginApproval(
            approvalID: proposal.approvalId,
            origin: origin,
            authDescription:
                authBindingDescription(authBinding),
            manifestSHA256: manifestSHA256
        )
    }

    private static func mapProbeProposal(
        _ proposal: FfiDiscoveryApprovalProposal?
    ) throws -> ProviderDiscoveryProbeConsent {
        guard let proposal,
              case let .capabilityProbe(
                  modelRouteIDs,
                  budget
              ) = proposal.grant
        else {
            throw CoreClientFailure.invalidResponse(
                "기능 검사 승인 제안이 snapshot에 없습니다."
            )
        }
        return ProviderDiscoveryProbeConsent(
            approvalID: proposal.approvalId,
            grantSHA256: proposal.grantSha256,
            routeIDs: modelRouteIDs,
            budget: ProviderDiscoveryProbeBudget(
                maximumRequests: budget.maxRequests,
                maximumTotalTokensPerRequest:
                    budget.maxTotalTokensPerRequest,
                maximumOutputTokensPerRequest:
                    budget.maxOutputTokensPerRequest,
                maximumCostMicroUSDPerRequest:
                    budget.maxCostMicroUsdPerRequest,
                maximumDurationMillisecondsPerRequest:
                    budget.maxDurationMillisPerRequest,
                maximumCallsPerRequest:
                    budget.maxCallsPerRequest
            )
        )
    }

    private static func mapUnknownOutcomeProposal(
        _ proposal: FfiDiscoveryApprovalProposal
    ) throws -> ProviderDiscoveryUnknownOutcomeProposal? {
        guard case let .unknownOutcomeResolution(
            operation,
            resolution
        ) = proposal.grant else {
            return nil
        }
        return ProviderDiscoveryUnknownOutcomeProposal(
            approvalID: proposal.approvalId,
            operation: mapDiscoveryOperation(operation),
            resolution: mapDiscoveryUnknownOutcomeResolution(
                resolution
            )
        )
    }

    private static func authBindingDescription(
        _ binding: FfiAuthBinding
    ) -> String {
        switch binding {
        case .none:
            "인증 없음"
        case .bearerHeader:
            "Authorization: Bearer"
        case let .headerApiKey(headerName):
            "\(headerName) 헤더"
        }
    }

    private static func mapDiscoveryCandidate(
        _ candidate: FfiDiscoveryCandidate
    ) -> ProviderDiscoveryCandidate {
        let kind: String
        let title: String
        let subtitle: String?
        switch candidate.summary {
        case let .providerTemplate(
            templateID,
            templateVersion
        ):
            kind = "provider_template"
            title = templateID
            subtitle = "manifest v\(templateVersion)"
        case let .apiOrigin(origin):
            kind = "api_origin"
            title = origin
            subtitle = nil
        case let .officialDocument(contentSHA256):
            kind = "official_document"
            title = "공식 문서"
            subtitle = String(contentSHA256.prefix(16)) + "…"
        case let .modelRoute(modelID):
            kind = "model_route"
            title = modelID
            subtitle = nil
        case let .manifestDraft(
            schemaVersion,
            manifestSHA256
        ):
            kind = "manifest_draft"
            title = "Manifest draft v\(schemaVersion)"
            subtitle = String(manifestSHA256.prefix(16)) + "…"
        }
        return ProviderDiscoveryCandidate(
            id: candidate.id,
            proposedRevision: candidate.proposedRevision,
            kind: kind,
            title: title,
            subtitle: subtitle,
            evidenceReferences: candidate.evidenceIds,
            createdAt: candidate.createdAt
        )
    }

    private static func mapDiscoveryEvidence(
        _ evidence: FfiDiscoveryEvidence
    ) -> ProviderDiscoveryEvidence {
        ProviderDiscoveryEvidence(
            id: evidence.id,
            kind: mapDiscoveryEvidenceKind(evidence.kind),
            contentSHA256: evidence.contentSha256,
            fetchedAt: evidence.fetchedAt
        )
    }

    private static func mapDiscoveryEvidenceKind(
        _ kind: FfiDiscoveryEvidenceKind
    ) -> String {
        switch kind {
        case .htmlDocument: "html_document"
        case .jsonDocument: "json_document"
        case .yamlDocument: "yaml_document"
        case .xmlDocument: "xml_document"
        case .plainTextDocument: "plain_text_document"
        case .jsonSchema: "json_schema"
        case .openApi: "open_api"
        }
    }

    private static func mapDiscoveryReviewProposal(
        _ proposal: FfiDiscoveryReviewProposal
    ) throws -> ProviderDiscoveryReviewProposal {
        let review = try mapDiscoveryReview(
            proposal.review,
            requestPreview: proposal.requestPreview
        )
        return ProviderDiscoveryReviewProposal(
            approvalID: proposal.approval.approvalId,
            grantSHA256: proposal.approval.grantSha256,
            commitAttemptID: proposal.commitAttemptId,
            commitPlanSHA256: proposal.commitPlanSha256,
            review: review
        )
    }

    private static func mapDiscoveryReview(
        _ review: FfiDiscoveryReview,
        requestPreview: FfiRequestPreview?
    ) throws -> ProviderDiscoveryReview {
        ProviderDiscoveryReview(
            sha256: review.sha256,
            graphSHA256: review.graphSha256,
            changes: review.changes.enumerated().map {
                index, change in
                let kind = mapDiscoveryReviewChangeKind(
                    change.kind
                )
                let targetKind = mapDiscoveryReviewTargetKind(
                    change.targetKind
                )
                return ProviderReviewChange(
                    id: "\(targetKind):\(change.targetId):\(index)",
                    kind: kind,
                    targetKind: targetKind,
                    title: change.summaryKey,
                    detail: change.targetId,
                    evidenceReferences: change.evidenceIds
                )
            },
            unresolvedQuestionCount:
                review.unresolvedQuestionCount,
            warningCount: review.warningCount,
            requestPreview: try requestPreview.map(
                mapRequestPreview
            )
        )
    }

    private static func mapDiscoveryReviewChangeKind(
        _ kind: FfiDiscoveryReviewChangeKind
    ) -> ProviderReviewChangeKind {
        switch kind {
        case .add: .add
        case .update: .update
        case .deprecate: .deprecate
        case .preserveMissing: .preserveMissing
        }
    }

    private static func mapDiscoveryReviewTargetKind(
        _ kind: FfiDiscoveryReviewTargetKind
    ) -> String {
        switch kind {
        case .providerTemplate: "provider_template"
        case .providerConnection: "provider_connection"
        case .modelRoute: "model_route"
        }
    }

    private static func mapDiscoveryEvent(
        _ event: FfiDiscoveryEvent
    ) throws -> ProviderDiscoveryEvent {
        try CoreRuntimeContract
            .validateProviderDiscoveryEventVersion(
                event.eventVersion
            )
        return ProviderDiscoveryEvent(
            version: event.eventVersion,
            id: event.eventId,
            sessionID: event.sessionId,
            sequence: event.sequence,
            sessionRevision: event.sessionRevision,
            state: try mapDiscoveryState(event.state),
            progress: event.progress.map {
                ProviderDiscoveryProgress(
                    phase: mapDiscoveryProgressPhase($0.phase),
                    completed: $0.completed,
                    total: $0.total
                )
            },
            actionID: event.actionId,
            warning: event.warning.map(mapDiscoveryWarning),
            failureMessageKey: event.failure?.messageKey
        )
    }

    private static func mapDiscoveryProgressPhase(
        _ phase: FfiDiscoveryProgressPhase
    ) -> String {
        switch phase {
        case .providerCandidates: "provider_candidates"
        case .documents: "documents"
        case .evidence: "evidence"
        case .models: "models"
        case .probes: "probes"
        }
    }

    private static func mapDiscoveryWarning(
        _ warning: FfiDiscoveryWarning
    ) -> String {
        switch warning {
        case .assistantDeclined: "assistant_declined"
        case .probesSkipped: "probes_skipped"
        case .compensationRequired: "compensation_required"
        case .explicitRestartRequired: "explicit_restart_required"
        case .unknownExternalOutcome: "unknown_external_outcome"
        }
    }

    private static func mapDiscoveryOutboxEvent(
        _ outbox: FfiDiscoveryOutboxEvent
    ) throws -> ProviderDiscoveryOutboxEvent {
        ProviderDiscoveryOutboxEvent(
            event: try mapDiscoveryEvent(outbox.event),
            deliveryAttempts: outbox.deliveryAttempts,
            availableAt: outbox.availableAt,
            createdAt: outbox.createdAt
        )
    }

    private static func mapDiscoveryRecoveryResult(
        _ result: FfiDiscoveryRecoveryResult
    ) throws -> ProviderDiscoveryRecoveryResult {
        ProviderDiscoveryRecoveryResult(
            operationID: result.operationId,
            sessionID: result.sessionId,
            state: try mapDiscoveryState(result.state),
            event: try mapDiscoveryEvent(result.event)
        )
    }

    private static func mapDiscoveryCompensationStep(
        _ step: FfiDiscoveryCompensationStep
    ) throws -> ProviderDiscoveryCompensationStep {
        ProviderDiscoveryCompensationStep(
            id: step.id,
            commitAttemptID: step.commitAttemptId,
            ordinal: step.ordinal,
            actionID: step.actionId,
            kind: mapDiscoveryCompensationKind(step.kind),
            target: mapDiscoveryCompensationTarget(step.target),
            status: mapDiscoveryCompensationStatus(step.status),
            attemptCount: step.attemptCount,
            lastFailure: step.lastFailure.map(
                mapDiscoveryFailure
            ),
            createdAt: step.createdAt,
            updatedAt: step.updatedAt,
            completedAt: step.completedAt
        )
    }

    private static func mapDiscoveryCompensationKind(
        _ kind: FfiDiscoveryCompensationKind
    ) -> ProviderDiscoveryCompensationKind {
        switch kind {
        case .removeCredentialSlot: .removeCredentialSlot
        case .removeConnectionGraph: .removeConnectionGraph
        case .restorePreviousSelection: .restorePreviousSelection
        }
    }

    private static func mapDiscoveryCompensationStatus(
        _ status: FfiDiscoveryCompensationStatus
    ) -> ProviderDiscoveryCompensationStatus {
        switch status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .completed: .completed
        case .failed: .failed
        case .outcomeUnknown: .outcomeUnknown
        }
    }

    private static func mapDiscoveryCompensationTarget(
        _ target: FfiDiscoveryCompensationTarget
    ) -> ProviderDiscoveryCompensationTarget {
        switch target {
        case let .removeCredentialSlot(
            connectionID,
            credentialReference
        ):
            .removeCredentialSlot(
                connectionID: connectionID,
                credentialReference: credentialReference
            )
        case let .removeConnectionGraph(connectionID):
            .removeConnectionGraph(connectionID: connectionID)
        case let .restorePreviousSelection(previousSelection):
            .restorePreviousSelection(
                mapDiscoveryPreviousSelection(
                    previousSelection
                )
            )
        }
    }

    private static func mapDiscoveryPreviousSelection(
        _ selection: FfiDiscoveryPreviousSelection
    ) -> ProviderDiscoveryPreviousSelection {
        switch selection {
        case .none:
            .none
        case let .routeAndPreset(
            modelRouteID,
            generationPresetID
        ):
            .routeAndPreset(
                modelRouteID: modelRouteID,
                generationPresetID: generationPresetID
            )
        }
    }

    private static func mapDiscoveryFailure(
        _ failure: FfiDiscoveryFailure
    ) -> ProviderDiscoveryFailure {
        ProviderDiscoveryFailure(
            code: failure.code,
            messageKey: failure.messageKey,
            isRecoverable: failure.recoverable
        )
    }

    private static func mapDiscoveryFailure(
        _ failure: ProviderDiscoveryFailure
    ) -> FfiDiscoveryFailure {
        FfiDiscoveryFailure(
            code: failure.code,
            messageKey: failure.messageKey,
            recoverable: failure.isRecoverable
        )
    }

    private static func mapConnectionConfigEntry(
        _ entry: FfiConnectionConfigEntry
    ) -> ProviderConfigurationEntry {
        ProviderConfigurationEntry(
            key: entry.key,
            value: mapConnectionConfigValue(entry.value)
        )
    }

    private static func mapConnectionConfigValue(
        _ value: FfiConnectionConfigValue
    ) -> ProviderConfigurationValue {
        switch value {
        case let .text(value):
            .text(value)
        case let .integer(value):
            .integer(value)
        case let .boolean(value):
            .boolean(value)
        }
    }

    private static func mapModelRoute(
        _ route: FfiModelRoute
    ) -> ProviderModelRoute {
        ProviderModelRoute(
            id: route.id,
            connectionID: route.connectionId,
            apiFamily: route.apiFamily,
            modelID: route.modelId,
            displayName: route.displayName,
            deploymentID: route.routeConfig.deploymentId,
            region: route.routeConfig.region,
            endpointPath: route.routeConfig.endpointPath,
            availability:
                ProviderModelAvailability(rawValue: route.availability)
                    ?? .unknown,
            firstSeenAt: route.firstSeenAt,
            lastSeenAt: route.lastSeenAt,
            missCount: route.missCount,
            metadataSource: route.metadataSource,
            metadataObservedAt: route.metadataObservedAt
        )
    }

    private static func mapGenerationPreset(
        _ preset: FfiGenerationPreset
    ) throws -> ProviderGenerationPreset {
        guard preset.parameterValueCount
            == UInt32(clamping: preset.values.count)
        else {
            throw CoreClientFailure.invalidResponse(
                "생성 프리셋 파라미터 개수가 일치하지 않습니다."
            )
        }
        return ProviderGenerationPreset(
            id: preset.id,
            modelRouteID: preset.modelRouteId,
            displayName: preset.displayName,
            values: preset.values.map {
                ProviderParameterValue(
                    parameterID: $0.parameterId,
                    state: mapParameterValueState($0.state)
                )
            },
            reasoningMode: preset.reasoningMode,
            reasoningEffort: preset.reasoningEffort,
            reasoningBudgetTokens: preset.reasoningBudgetTokens,
            reasoningSummary: preset.reasoningSummary,
            preservesOpaqueReasoningState:
                preset.preserveOpaqueReasoningState,
            promptCacheMode: preset.promptCacheMode,
            promptCacheTTL: preset.promptCacheTtl,
            promptCacheCustomTTLSeconds:
                preset.promptCacheCustomTtlSeconds,
            promptCacheContextReference:
                preset.promptCacheContextReference,
            createdAt: preset.createdAt,
            updatedAt: preset.updatedAt
        )
    }

    private static func mapParameterValueState(
        _ state: FfiParameterValueState
    ) -> ProviderParameterValueState {
        switch state {
        case .inheritProviderDefault:
            .providerDefault
        case let .explicit(value):
            .explicit(mapParameterLiteral(value))
        }
    }

    private static func mapGenerationPreset(
        _ preset: ProviderGenerationPreset
    ) throws -> FfiGenerationPreset {
        guard let valueCount = UInt32(exactly: preset.values.count) else {
            throw CoreClientFailure.invalidResponse(
                "생성 프리셋 파라미터가 너무 많습니다."
            )
        }
        return FfiGenerationPreset(
            id: preset.id,
            modelRouteId: preset.modelRouteID,
            displayName: preset.displayName,
            parameterValueCount: valueCount,
            values: try preset.values.map {
                FfiParameterValue(
                    parameterId: $0.parameterID,
                    state: try mapParameterValueState($0.state)
                )
            },
            reasoningMode: preset.reasoningMode,
            reasoningEffort: preset.reasoningEffort,
            reasoningBudgetTokens: preset.reasoningBudgetTokens,
            reasoningSummary: preset.reasoningSummary,
            preserveOpaqueReasoningState:
                preset.preservesOpaqueReasoningState,
            promptCacheMode: preset.promptCacheMode,
            promptCacheTtl: preset.promptCacheTTL,
            promptCacheCustomTtlSeconds:
                preset.promptCacheCustomTTLSeconds,
            promptCacheContextReference:
                preset.promptCacheContextReference,
            createdAt: preset.createdAt,
            updatedAt: preset.updatedAt
        )
    }

    private static func mapParameterValueState(
        _ state: ProviderParameterValueState
    ) throws -> FfiParameterValueState {
        switch state {
        case .providerDefault:
            .inheritProviderDefault
        case let .explicit(value):
            .explicit(value: try mapParameterLiteral(value))
        }
    }

    private static func mapParameterLiteral(
        _ literal: ProviderParameterLiteral
    ) throws -> FfiParameterLiteral {
        switch literal {
        case let .boolean(value):
            .boolean(value: value)
        case let .integer(value):
            .integer(value: value)
        case let .number(value):
            .number(value: value)
        case let .string(value):
            .string(value: value)
        case let .enumeration(value):
            .enum(value: value)
        case let .stringList(values):
            .stringList(values: values)
        case let .jsonSchema(value):
            .jsonSchema(value: value)
        case let .stopSequenceList(values):
            .stopSequenceList(values: values)
        case let .toolPolicy(value):
            .toolPolicy(value: try mapToolPolicy(value))
        }
    }

    private static func mapToolPolicy(
        _ value: String
    ) throws -> FfiToolPolicy {
        switch value {
        case "none":
            .none
        case "auto":
            .auto
        case "required":
            .required
        default:
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 도구 사용 정책입니다."
            )
        }
    }

    private static func mapEffectiveCapability(
        _ capability: FfiEffectiveCapability
    ) -> ProviderEffectiveCapability {
        ProviderEffectiveCapability(
            selected: mapCapabilityObservation(capability.selected),
            alternatives: capability.alternatives.map(
                mapCapabilityObservation
            ),
            evaluatedAt: capability.evaluatedAt,
            isStale: capability.selectedIsStale,
            hasConflict: capability.hasConflict
        )
    }

    private static func mapCapabilityObservation(
        _ observation: FfiCapabilityObservation
    ) -> ProviderCapabilityObservation {
        ProviderCapabilityObservation(
            id: observation.id,
            modelRouteID: observation.modelRouteId,
            key: observation.key,
            value: mapCapabilityValue(observation.value),
            status: observation.status,
            source: observation.source,
            confidence: observation.confidence,
            observedAt: observation.observedAt,
            expiresAt: observation.expiresAt,
            evidenceReference: observation.evidenceRef
        )
    }

    private static func mapCapabilityValue(
        _ value: FfiCapabilityValue
    ) -> ProviderCapabilityValue {
        switch value.kind {
        case "boolean":
            value.booleanValue.map(ProviderCapabilityValue.boolean)
                ?? .unknown
        case "integer":
            value.integerValue.map(ProviderCapabilityValue.integer)
                ?? .unknown
        case "enum", "enumeration":
            .enumeration(value.enumValues)
        case "structured":
            value.structuredJson.map {
                .structuredSummary($0)
            } ?? .unknown
        default:
            .unknown
        }
    }

    private static func mapModelSyncJob(
        _ job: FfiModelSyncJob
    ) throws -> ProviderModelSyncJob {
        let state = try mapModelSyncState(job.state)
        let completedSteps: UInt32
        switch job.state {
        case "created":
            completedSteps = 0
        case "fetching":
            completedSteps = 1
        case "interrupted":
            completedSteps = 1
        case "awaiting_review":
            completedSteps = 3
        case "completed":
            completedSteps = 4
        case "failed":
            completedSteps = 0
        case "cancelled":
            completedSteps = 0
        default:
            completedSteps = 0
        }

        return ProviderModelSyncJob(
            id: job.id,
            connectionID: job.connectionId,
            state: state,
            revision: job.revision,
            completedSteps: completedSteps,
            totalSteps: 4,
            reviewSHA256: job.review?.sha256,
            diff: try job.review.map(mapModelSyncDiff),
            failureMessageKey: job.failure?.messageKey,
            updatedAt: job.updatedAt
        )
    }

    private static func mapModelSyncEvent(
        _ event: FfiModelSyncEvent
    ) throws -> ProviderModelSyncEvent {
        try CoreRuntimeContract
            .validateProviderModelSyncEventVersions(
                version: event.version,
                redactionVersion: event.redactionVersion
            )
        guard event.totalSteps > 0,
              event.completedSteps <= event.totalSteps
        else {
            throw CoreClientFailure.invalidResponse(
                "모델 동기화 이벤트 형식이 올바르지 않습니다."
            )
        }
        return ProviderModelSyncEvent(
            version: event.version,
            jobID: event.jobId,
            sequence: event.sequence,
            jobRevision: event.jobRevision,
            redactionVersion: event.redactionVersion,
            state: try mapModelSyncState(event.state),
            completedSteps: event.completedSteps,
            totalSteps: event.totalSteps,
            messageKey: event.messageKey,
            reviewSHA256: event.reviewSha256,
            failureMessageKey: event.failure?.messageKey,
            emittedAt: event.emittedAt
        )
    }

    private static func mapModelSyncState(
        _ state: String
    ) throws -> ProviderModelSyncState {
        switch state {
        case "created": .created
        case "fetching": .fetching
        case "interrupted": .interrupted
        case "awaiting_review": .awaitingReview
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        default:
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 모델 동기화 상태입니다."
            )
        }
    }

    private static func mapModelSyncDiff(
        _ review: FfiModelSyncReview
    ) throws -> ProviderModelSyncDiff {
        let newIDs = Set(review.newlySeenModelRouteIds)
        let expectedByID = Dictionary(
            uniqueKeysWithValues: review.expectedModelRoutes.map {
                ($0.id, $0)
            }
        )
        let changedRouteIDs: [String] = review.listedRoutes.compactMap {
            route -> String? in
            guard !newIDs.contains(route.id),
                  let expected = expectedByID[route.id],
                  expected != route
            else {
                return nil
            }
            return route.id
        }
        let newRoutes = review.listedRoutes
            .filter { newIDs.contains($0.id) }
            .map(mapModelRoute)
        return ProviderModelSyncDiff(
            newRoutes: newRoutes,
            changedRouteIDs: changedRouteIDs,
            missingRouteIDs: review.missingModelRouteIds,
            capabilityChangeCount: UInt32(
                clamping: review.capabilityObservations.count
            )
        )
    }

    private static func mapProviderCatalogStatus(
        _ status: FfiProviderCatalogStatus,
        history: FfiProviderCatalogHistory
    ) -> ProviderCatalogStatus {
        let activeAction = history.activations.first {
            $0.stateVersion == status.stateVersion
                && $0.toRevision == status.activeRevision
        }
        let activationRevisionSet = Set(
            history.activations.map(\.toRevision)
        )
        var items = history.activations.map { activation in
            ProviderCatalogActivation(
                id: activation.actionId,
                revision: activation.toRevision,
                source: activation.kind,
                activatedAt: activation.activatedAt,
                isCurrent:
                    activation.actionId == activeAction?.actionId,
                summary: activation.fromRevision.map {
                    "r\($0) → r\(activation.toRevision)"
                } ?? "r\(activation.toRevision) 활성화"
            )
        }
        items.append(
            contentsOf: history.revisions
                .filter {
                    !activationRevisionSet.contains($0.revision)
                }
                .map { revision in
                    ProviderCatalogActivation(
                        id: "revision:\(revision.revision)",
                        revision: revision.revision,
                        source: revision.signedRevisions.isEmpty
                            ? "bundled"
                            : "signed_catalog",
                        activatedAt: revision.capturedAt,
                        isCurrent:
                            revision.revision == status.activeRevision,
                        summary: revision.signedRevisions.isEmpty
                            ? "내장 프로바이더 카탈로그"
                            : "서명된 카탈로그 스냅샷"
                    )
                }
        )
        items.sort {
            if $0.activatedAt == $1.activatedAt {
                return $0.revision > $1.revision
            }
            return $0.activatedAt > $1.activatedAt
        }
        let currentItem = items.first(where: \.isCurrent)
        return ProviderCatalogStatus(
            schemaVersion: status.statusSchemaVersion,
            currentRevision: status.activeRevision,
            currentSource:
                status.activeSignedRevisions.contains(
                    status.activeRevision
                )
                ? "signed_catalog"
                : "bundled",
            verifiedSigner: nil,
            updatedAt: currentItem?.activatedAt
                ?? status.latestIssuedAt,
            history: items
        )
    }

    private static func mapCatalogDiff(
        _ diff: FfiProviderCatalogDiff
    ) -> ProviderCatalogDiff {
        ProviderCatalogDiff(
            schemaVersion: diff.diffSchemaVersion,
            fromRevision: diff.fromRevision,
            toRevision: diff.toRevision,
            manifestChanges:
                mapCatalogManifestChanges(
                    diff.addedProviderTemplates,
                    change: .added
                )
                + mapCatalogManifestChanges(
                    diff.changedProviderTemplates,
                    change: .updated
                )
                + mapCatalogManifestChanges(
                    diff.removedProviderTemplates,
                    change: .removed
                ),
            modelChanges:
                mapCatalogModelChanges(
                    diff.addedModels,
                    change: .added
                )
                + mapCatalogModelChanges(
                    diff.changedModels,
                    change: .updated
                )
                + mapCatalogModelChanges(
                    diff.removedModels,
                    change: .removed
                )
        )
    }

    private static func mapCatalogManifestChanges(
        _ entries: [FfiProviderCatalogTemplateDiffEntry],
        change: ProviderCatalogChangeKind
    ) -> [ProviderCatalogManifestChange] {
        entries.map {
            ProviderCatalogManifestChange(
                providerTemplateID: $0.providerTemplateId,
                change: change,
                previousManifestVersion:
                    $0.previousManifestVersion,
                nextManifestVersion: $0.nextManifestVersion,
                previousSHA256: $0.previousSha256,
                nextSHA256: $0.nextSha256,
                changedSections: $0.changedSections.map(
                    mapCatalogTemplateSection
                )
            )
        }
    }

    private static func mapCatalogModelChanges(
        _ entries: [FfiProviderCatalogModelDiffEntry],
        change: ProviderCatalogChangeKind
    ) -> [ProviderCatalogModelChange] {
        entries.map {
            ProviderCatalogModelChange(
                modelEntryID: $0.modelEntryId,
                providerTemplateID: $0.providerTemplateId,
                change: change,
                previousMetadataVersion:
                    $0.previousMetadataVersion,
                nextMetadataVersion: $0.nextMetadataVersion,
                previousSHA256: $0.previousSha256,
                nextSHA256: $0.nextSha256,
                changedSections: $0.changedSections.map(
                    mapCatalogModelSection
                )
            )
        }
    }

    private static func mapCatalogTemplateSection(
        _ section: FfiProviderCatalogTemplateChangedSection
    ) -> String {
        switch section {
        case .displayName: "display_name"
        case .manifestVersion: "manifest_version"
        case .connectionFields: "connection_fields"
        case .apiFamily: "api_family"
        case .sources: "sources"
        case .origin: "origin"
        case .authentication: "authentication"
        case .endpoints: "endpoints"
        case .decoders: "decoders"
        case .parameters: "parameters"
        case .freshness: "freshness"
        }
    }

    private static func mapCatalogModelSection(
        _ section: FfiProviderCatalogModelChangedSection
    ) -> String {
        switch section {
        case .match: "match"
        case .apiFamily: "api_family"
        case .metadataVersion: "metadata_version"
        case .capabilities: "capabilities"
        case .parameters: "parameters"
        case .lifecycle: "lifecycle"
        case .sources: "sources"
        case .freshness: "freshness"
        }
    }

    private static func mapCatalogImportPlan(
        _ plan: FfiProviderCatalogImportPlan
    ) throws -> ProviderCatalogImportPlan {
        let review = plan.review
        return ProviderCatalogImportPlan(
            review: ProviderCatalogImportReview(
                planSchemaVersion: review.planSchemaVersion,
                actionID: review.actionId,
                expectedStateVersion:
                    review.expectedStateVersion,
                expectedActiveRevision:
                    review.expectedActiveRevision,
                expectedActiveSnapshotSHA256:
                    review.expectedActiveSnapshotSha256,
                expectedHighestAcceptedRevision:
                    review.expectedHighestAcceptedRevision,
                envelopeByteCount: review.envelopeByteCount,
                envelopeSHA256: review.envelopeSha256,
                signingKeyID: review.signingKeyId,
                payloadSHA256: review.payloadSha256,
                signedCatalogRevision:
                    review.signedCatalogRevision,
                candidateRevision: review.candidateRevision,
                candidateSnapshotSHA256:
                    review.candidateSnapshotSha256,
                preparedAt: review.preparedAt,
                expiresAt: review.expiresAt,
                diff: mapCatalogDiff(review.diff)
            ),
            planSHA256: plan.planSha256,
            opaquePlanJSON: plan.planJson
        )
    }

    private static func mapCatalogImportPlan(
        _ plan: ProviderCatalogImportPlan
    ) throws -> FfiProviderCatalogImportPlan {
        let review = plan.review
        return FfiProviderCatalogImportPlan(
            review: FfiProviderCatalogImportReview(
                planSchemaVersion: review.planSchemaVersion,
                actionId: review.actionID,
                expectedStateVersion:
                    review.expectedStateVersion,
                expectedActiveRevision:
                    review.expectedActiveRevision,
                expectedActiveSnapshotSha256:
                    review.expectedActiveSnapshotSHA256,
                expectedHighestAcceptedRevision:
                    review.expectedHighestAcceptedRevision,
                envelopeByteCount: review.envelopeByteCount,
                envelopeSha256: review.envelopeSHA256,
                signingKeyId: review.signingKeyID,
                payloadSha256: review.payloadSHA256,
                signedCatalogRevision:
                    review.signedCatalogRevision,
                candidateRevision: review.candidateRevision,
                candidateSnapshotSha256:
                    review.candidateSnapshotSHA256,
                preparedAt: review.preparedAt,
                expiresAt: review.expiresAt,
                diff: try mapCatalogDiff(review.diff)
            ),
            planSha256: plan.planSHA256,
            planJson: plan.opaquePlanJSON
        )
    }

    private static func mapCatalogRollbackPlan(
        _ plan: FfiProviderCatalogRollbackPlan
    ) -> ProviderCatalogRollbackPlan {
        ProviderCatalogRollbackPlan(
            planSchemaVersion: plan.planSchemaVersion,
            actionID: plan.actionId,
            expectedStateVersion: plan.expectedStateVersion,
            planSHA256: plan.planSha256,
            fromRevision: plan.fromRevision,
            toRevision: plan.toRevision,
            createdAt: plan.createdAt,
            expiresAt: plan.expiresAt,
            diff: mapCatalogDiff(plan.diff),
            opaquePlanJSON: plan.planJson
        )
    }

    private static func mapCatalogRollbackPlan(
        _ plan: ProviderCatalogRollbackPlan
    ) throws -> FfiProviderCatalogRollbackPlan {
        FfiProviderCatalogRollbackPlan(
            planSchemaVersion: plan.planSchemaVersion,
            actionId: plan.actionID,
            expectedStateVersion: plan.expectedStateVersion,
            planSha256: plan.planSHA256,
            fromRevision: plan.fromRevision,
            toRevision: plan.toRevision,
            createdAt: plan.createdAt,
            expiresAt: plan.expiresAt,
            diff: try mapCatalogDiff(plan.diff),
            planJson: plan.opaquePlanJSON
        )
    }

    private static func mapCatalogDiff(
        _ diff: ProviderCatalogDiff
    ) throws -> FfiProviderCatalogDiff {
        FfiProviderCatalogDiff(
            diffSchemaVersion: diff.schemaVersion,
            fromRevision: diff.fromRevision,
            toRevision: diff.toRevision,
            addedProviderTemplates:
                try mapCatalogManifestChanges(
                    diff.manifestChanges.filter {
                        $0.change == .added
                    }
                ),
            changedProviderTemplates:
                try mapCatalogManifestChanges(
                    diff.manifestChanges.filter {
                        $0.change == .updated
                    }
                ),
            removedProviderTemplates:
                try mapCatalogManifestChanges(
                    diff.manifestChanges.filter {
                        $0.change == .removed
                    }
                ),
            addedModels: try mapCatalogModelChanges(
                diff.modelChanges.filter {
                    $0.change == .added
                }
            ),
            changedModels: try mapCatalogModelChanges(
                diff.modelChanges.filter {
                    $0.change == .updated
                }
            ),
            removedModels: try mapCatalogModelChanges(
                diff.modelChanges.filter {
                    $0.change == .removed
                }
            )
        )
    }

    private static func mapCatalogManifestChanges(
        _ entries: [ProviderCatalogManifestChange]
    ) throws -> [FfiProviderCatalogTemplateDiffEntry] {
        try entries.map {
            FfiProviderCatalogTemplateDiffEntry(
                providerTemplateId: $0.providerTemplateID,
                previousManifestVersion:
                    $0.previousManifestVersion,
                nextManifestVersion: $0.nextManifestVersion,
                previousSha256: $0.previousSHA256,
                nextSha256: $0.nextSHA256,
                changedSections: try $0.changedSections.map(
                    unmapCatalogTemplateSection
                )
            )
        }
    }

    private static func mapCatalogModelChanges(
        _ entries: [ProviderCatalogModelChange]
    ) throws -> [FfiProviderCatalogModelDiffEntry] {
        try entries.map {
            FfiProviderCatalogModelDiffEntry(
                modelEntryId: $0.modelEntryID,
                providerTemplateId: $0.providerTemplateID,
                previousMetadataVersion:
                    $0.previousMetadataVersion,
                nextMetadataVersion: $0.nextMetadataVersion,
                previousSha256: $0.previousSHA256,
                nextSha256: $0.nextSHA256,
                changedSections: try $0.changedSections.map(
                    unmapCatalogModelSection
                )
            )
        }
    }

    private static func unmapCatalogTemplateSection(
        _ section: String
    ) throws -> FfiProviderCatalogTemplateChangedSection {
        switch section {
        case "display_name": .displayName
        case "manifest_version": .manifestVersion
        case "connection_fields": .connectionFields
        case "api_family": .apiFamily
        case "sources": .sources
        case "origin": .origin
        case "authentication": .authentication
        case "endpoints": .endpoints
        case "decoders": .decoders
        case "parameters": .parameters
        case "freshness": .freshness
        default:
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 카탈로그 템플릿 변경 영역입니다."
            )
        }
    }

    private static func unmapCatalogModelSection(
        _ section: String
    ) throws -> FfiProviderCatalogModelChangedSection {
        switch section {
        case "match": .match
        case "api_family": .apiFamily
        case "metadata_version": .metadataVersion
        case "capabilities": .capabilities
        case "parameters": .parameters
        case "lifecycle": .lifecycle
        case "sources": .sources
        case "freshness": .freshness
        default:
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 카탈로그 모델 변경 영역입니다."
            )
        }
    }

    private static func mapRequestPreview(
        _ preview: FfiRequestPreview
    ) throws -> ProviderRequestPreview {
        guard preview.redactionVersion > 0,
              !preview.includesPrivateMessage,
              !preview.includesCredentialValue,
              !preview.includesOpaqueReasoningState
        else {
            throw CoreClientFailure.invalidResponse(
                "민감한 값이 포함될 수 있는 요청 미리보기는 표시하지 않습니다."
            )
        }
        return ProviderRequestPreview(
            redactionVersion: preview.redactionVersion,
            method: preview.method,
            origin: preview.origin,
            path: preview.path,
            headerNames: preview.headerNames,
            queryParameterNames: preview.queryParameterNames,
            bodyShapeJSON: try preview.bodyShape.map(
                requestBodyShapeJSON
            ),
            bodyTruncated: preview.bodyTruncated,
            includesPrivateMessage: preview.includesPrivateMessage,
            includesCredentialValue: preview.includesCredentialValue,
            includesOpaqueReasoningState:
                preview.includesOpaqueReasoningState
        )
    }

    private static func requestBodyShapeJSON(
        _ shape: FfiRequestBodyShape
    ) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: requestBodyShapeObject(shape),
            options: [.sortedKeys]
        )
        guard let value = String(data: data, encoding: .utf8) else {
            throw CoreClientFailure.invalidResponse(
                "요청 body 구조를 안전하게 표시할 수 없습니다."
            )
        }
        return value
    }

    private static func requestBodyShapeObject(
        _ shape: FfiRequestBodyShape
    ) -> Any {
        switch shape {
        case .null:
            ["kind": "null"]
        case .boolean:
            ["kind": "boolean"]
        case .number:
            ["kind": "number"]
        case .string:
            ["kind": "string"]
        case let .array(items, truncated):
            [
                "kind": "array",
                "items": items.map(requestBodyShapeObject),
                "truncated": truncated,
            ] as [String: Any]
        case let .object(fields, truncated):
            [
                "kind": "object",
                "fields": fields.map {
                    [
                        "name": $0.name,
                        "shape": requestBodyShapeObject($0.shape),
                    ] as [String: Any]
                },
                "truncated": truncated,
            ] as [String: Any]
        case .redacted:
            ["kind": "redacted"]
        case .truncated:
            ["kind": "truncated"]
        }
    }

    private static func mapReasoningControl(
        _ control: FfiReasoningControl
    ) throws -> ProviderReasoningControl {
        ProviderReasoningControl(
            state: try mapUIControlState(control.state),
            mode: control.mode,
            effort: control.effort,
            budgetTokens: control.budgetTokens,
            summary: control.summary,
            preservesOpaqueState: control.preserveOpaqueState,
            allowedModes: control.allowedModes,
            allowedEfforts: control.allowedEfforts,
            allowedSummaries: control.allowedSummaries,
            minimumBudgetTokens: control.minimumBudgetTokens,
            maximumBudgetTokens: control.maximumBudgetTokens,
            effortField: try mapUIFieldState(control.effortField),
            budgetField: try mapUIFieldState(control.budgetField),
            summaryField: try mapUIFieldState(control.summaryField),
            issues: control.issues.map(mapParameterIssue)
        )
    }

    private static func mapPromptCacheControl(
        _ control: FfiPromptCacheControl
    ) throws -> ProviderPromptCacheControl {
        ProviderPromptCacheControl(
            state: try mapUIControlState(control.state),
            mode: control.mode,
            ttl: control.ttl,
            customTTLSeconds: control.customTtlSeconds,
            contextReference: control.contextReference,
            allowedModes: control.allowedModes,
            allowedTTLs: control.allowedTtls,
            supportsCustomTTL: control.supportsCustomTtl,
            minimumCustomTTLSeconds:
                control.minimumCustomTtlSeconds,
            maximumCustomTTLSeconds:
                control.maximumCustomTtlSeconds,
            ttlField: try mapUIFieldState(control.ttlField),
            contextReferenceField: try mapUIFieldState(
                control.contextReferenceField
            ),
            issues: control.issues.map(mapParameterIssue)
        )
    }

    private static func mapUIControlState(
        _ rawValue: String
    ) throws -> ProviderUIControlState {
        guard let state = ProviderUIControlState(rawValue: rawValue) else {
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 프로바이더 제어 상태입니다."
            )
        }
        return state
    }

    private static func mapUIFieldState(
        _ rawValue: String
    ) throws -> ProviderUIFieldState {
        guard let state = ProviderUIFieldState(rawValue: rawValue) else {
            throw CoreClientFailure.invalidResponse(
                "지원하지 않는 프로바이더 필드 상태입니다."
            )
        }
        return state
    }

    private static func mapParameterIssue(
        _ issue: FfiParameterIssue
    ) -> ProviderParameterIssue {
        ProviderParameterIssue(
            code: issue.code,
            parameterID: issue.parameterId,
            relatedParameterID: issue.relatedParameterId,
            message: issue.message
        )
    }

    private static func mapGenerationTarget(
        _ target: ProviderGenerationTarget
    ) -> FfiGenerationTarget {
        FfiGenerationTarget(
            modelRouteId: target.modelRouteID,
            generationPresetId: target.generationPresetID
        )
    }

    private static func mapSettings(
        _ settings: FfiAppSettings
    ) -> CoreAppSettings {
        CoreAppSettings(
            preservePartialGenerations:
                settings.preservePartialGenerations,
            selectedProviderProfileID:
                settings.selectedProviderProfileId,
            selectedModelRouteID: settings.selectedModelRouteId,
            selectedGenerationPresetID:
                settings.selectedGenerationPresetId
        )
    }
}
#else
public typealias UniFfiCoreClient = UnavailableCoreClient
#endif

public enum CoreClientFactory {
    public static func make(dataRoot: URL) -> CoreClientSelection {
        #if LOREPIA_UNIFFI_GENERATED
        do {
            return CoreClientSelection(
                client: try UniFfiCoreClient(dataRoot: dataRoot),
                mode: .live
            )
        } catch {
            let message = String(describing: error)
            return CoreClientSelection(
                client: UnavailableCoreClient(message: message),
                mode: .unavailable(message)
            )
        }
        #else
        let message = CoreClientFailure.bindingsUnavailable.localizedDescription
        return CoreClientSelection(
            client: UnavailableCoreClient(message: message),
            mode: .unavailable(message)
        )
        #endif
    }
}
