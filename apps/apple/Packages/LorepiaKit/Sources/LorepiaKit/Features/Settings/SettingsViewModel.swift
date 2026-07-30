import Combine
import Foundation

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public private(set) var profiles: [ProviderProfile] = []
    @Published public private(set) var selectedProfileID: String?
    @Published public var preservePartialGenerations = false
    @Published public var profileName = ""
    @Published public var baseURL = ""
    @Published public var model = ""
    @Published public var timeoutSeconds = "60"
    @Published public var credentialDraft = ""
    @Published public private(set) var hasStoredCredential = false
    @Published public private(set) var isCredentialStateKnown = true
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?

    public let runtimeMode: CoreRuntimeMode

    public var isEditingStoredProfile: Bool {
        profiles.contains { $0.id == editingProfileID }
    }

    /// Credential state is editor-scoped. Expose it for the selected profile
    /// only when the editor currently represents that same persisted profile.
    public var selectedProfileCredentialPresence: Bool? {
        guard editingProfileID == selectedProfileID,
              isCredentialStateKnown
        else {
            return nil
        }
        return hasStoredCredential
    }

    public var requiresCredentialRecovery: Bool {
        providerConfigurationStore.isQuarantined(
            profileID: editingProfileID
        )
    }

    public var credentialStatusDescription: String {
        if requiresCredentialRecovery {
            return normalizedCredentialDraft == nil
                ? "이 프로필의 API 키 안전 상태를 복구해야 합니다. 키를 다시 입력하거나 저장된 키 삭제를 완료하세요."
                : "저장하면 입력한 API 키로 이 프로필의 안전 상태 복구를 시도합니다."
        }
        guard isCredentialStateKnown else {
            return normalizedCredentialDraft == nil
                ? "Keychain API 키 저장 상태를 확인하지 못했습니다."
                : "현재 Keychain 상태를 확인할 수 없습니다. 저장하면 입력한 API 키로 설정을 시도합니다."
        }
        if normalizedCredentialDraft != nil {
            return hasStoredCredential
                ? "저장하면 기존 Keychain API 키를 새 키로 교체합니다."
                : "저장하면 API 키를 이 기기의 Keychain에 추가합니다."
        }
        if hasStoredCredential {
            return "API 키가 Keychain에 저장되어 있습니다. 입력 칸을 비워 두면 현재 키를 유지합니다."
        }
        return "저장된 API 키가 없습니다. 키가 필요 없는 로컬 프로바이더는 비워 둘 수 있습니다."
    }

    public var baseURLGuidance: String {
        "OpenAI 호환 API의 기본 주소를 입력하세요. 일반적으로 /v1로 끝납니다."
    }

    private let client: any CoreClient
    private let credentialStore: any CredentialStore
    private let providerConfigurationStore: ProviderConfigurationStore
    private var providerConfigurationCancellable: AnyCancellable?
    private var pendingProviderConfigurationRevision: UInt64?
    private var selfPublishedProviderConfigurationRevisions: Set<UInt64> = []
    private var editingProfileID = UUID().uuidString

    public init(
        client: any CoreClient,
        credentialStore: any CredentialStore,
        runtimeMode: CoreRuntimeMode,
        providerConfigurationStore: ProviderConfigurationStore? = nil
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.runtimeMode = runtimeMode
        self.providerConfigurationStore =
            providerConfigurationStore ?? ProviderConfigurationStore()
        providerConfigurationCancellable =
            self.providerConfigurationStore.$revision
                .dropFirst()
                .sink { [weak self] revision in
                    Task { @MainActor [weak self] in
                        await self?.enqueueProviderConfiguration(
                            revision: revision
                        )
                    }
                }
    }

    public func refresh() async {
        guard beginOperation() else {
            return
        }
        defer { endOperation() }

        do {
            async let loadedProfiles = client.listProviderProfiles()
            async let loadedSettings = client.getSettings()
            let (newProfiles, settings) = try await (
                loadedProfiles,
                loadedSettings
            )
            profiles = sortedProfiles(newProfiles)
            selectedProfileID = profiles.contains {
                $0.id == settings.selectedProviderProfileID
            } ? settings.selectedProviderProfileID : nil
            preservePartialGenerations = settings.preservePartialGenerations
            publishProviderConfiguration()

            if let selectedProfileID,
               let profile = profiles.first(where: {
                   $0.id == selectedProfileID
               })
            {
                await loadEditorAndCredentialState(profile)
            } else if let profile = profiles.first {
                await loadEditorAndCredentialState(profile)
            } else {
                resetEditorForNewProfile()
            }
            if isCredentialStateKnown {
                errorMessage = nil
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = coreOperationError(
                "프로바이더 설정을 불러오지"
            )
        }
    }

    public func selectProfile(id: String?) async {
        if let id,
           providerConfigurationStore.isBlocked(profileID: id)
        {
            await editProfile(id: id)
            statusMessage =
                "이 프로필은 기본 프로바이더로 선택하지 않고 복구용 편집 화면만 열었습니다."
            errorMessage =
                "이 프로필의 API 키 상태를 먼저 복구하거나 프로필을 다시 저장하세요."
            return
        }
        guard beginOperation() else {
            return
        }
        credentialDraft = ""
        defer { endOperation() }

        do {
            let updated = try await client.selectProviderProfile(id: id)
            preservePartialGenerations = updated.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == updated.selectedProviderProfileID
            } ? updated.selectedProviderProfileID : nil
            publishProviderConfiguration()

            if let selectedProfileID,
               let profile = profiles.first(where: {
                   $0.id == selectedProfileID
               })
            {
                await loadEditorAndCredentialState(profile)
            }
            if isCredentialStateKnown {
                errorMessage = nil
                statusMessage = "사용할 프로바이더를 변경했습니다."
            } else {
                statusMessage =
                    "사용할 프로바이더는 변경했지만 API 키 상태는 확인하지 못했습니다."
            }
        } catch is CancellationError {
            return
        } catch {
            errorMessage = coreOperationError(
                "사용할 프로바이더를 변경하지"
            )
        }
    }

    public func setPreservePartialGenerations(_ value: Bool) async {
        guard beginOperation() else {
            return
        }
        defer { endOperation() }

        do {
            let updated = try await client.setPreservePartialGenerations(
                value
            )
            preservePartialGenerations = updated.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == updated.selectedProviderProfileID
            } ? updated.selectedProviderProfileID : nil
            publishProviderConfiguration()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = coreOperationError(
                "부분 응답 설정을 저장하지"
            )
        }
    }

    public func beginNewProfile() {
        guard !isLoading else {
            return
        }
        resetEditorForNewProfile()
        errorMessage = nil
        statusMessage = nil
    }

    public func editProfile(id: String) async {
        guard
            let profile = profiles.first(where: { $0.id == id }),
            beginOperation()
        else {
            return
        }
        credentialDraft = ""
        defer { endOperation() }

        await loadEditorAndCredentialState(profile)
        if isCredentialStateKnown {
            errorMessage = nil
        }
    }

    public func saveProfile() async {
        let normalizedName = profileName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedURL = baseURL.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedModel = model.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let normalizedTimeout = timeoutSeconds.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !normalizedName.isEmpty,
            !normalizedURL.isEmpty,
            !normalizedModel.isEmpty,
            let timeout = UInt32(normalizedTimeout),
            (1 ... 600).contains(timeout)
        else {
            statusMessage = nil
            errorMessage = "이름, URL, 모델과 1~600초 제한 시간을 확인하세요."
            return
        }
        let targetID = editingProfileID
        let previousProfile = profiles.first { $0.id == targetID }
        let credentialToStore = normalizedCredentialDraft
        let changesCredentialEndpoint =
            previousProfile?.baseURL != normalizedURL
            && credentialToStore != nil
        if let credentialToStore,
           credentialToStore.utf8.count
               > CredentialStorePolicy.maximumCredentialUTF8Bytes
        {
            statusMessage = nil
            errorMessage =
                "API 키가 너무 깁니다. 더 짧은 키인지 확인하세요."
            return
        }
        if providerConfigurationStore.isQuarantined(
            profileID: targetID
        ), credentialToStore == nil {
            statusMessage = nil
            errorMessage =
                "이 프로필을 복구하려면 API 키를 다시 입력하거나 저장된 키 삭제를 완료하세요."
            return
        }
        if let previousProfile,
           previousProfile.baseURL != normalizedURL,
           credentialToStore == nil,
           hasStoredCredential || !isCredentialStateKnown
        {
            statusMessage = nil
            errorMessage =
                "Base URL을 변경하려면 새 API 키를 함께 입력하거나 저장된 키를 먼저 삭제하세요."
            return
        }
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        providerConfigurationStore.beginMutation(profileID: targetID)
        defer {
            providerConfigurationStore.endMutation(profileID: targetID)
        }

        let credentialBeforeSave: String?
        let credentialSnapshotIsKnown: Bool
        if credentialToStore != nil {
            do {
                credentialBeforeSave =
                    try await credentialStore.credential(for: targetID)
                credentialSnapshotIsKnown = true
            } catch {
                isCredentialStateKnown = false
                credentialBeforeSave = nil
                credentialSnapshotIsKnown = false
            }
        } else {
            credentialBeforeSave = nil
            credentialSnapshotIsKnown = true
        }
        let credentialWasClearedBeforeProfileSave =
            changesCredentialEndpoint || !credentialSnapshotIsKnown

        let originalSettings: CoreAppSettings
        do {
            originalSettings = try await client.getSettings()
            preservePartialGenerations =
                originalSettings.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == originalSettings.selectedProviderProfileID
            } ? originalSettings.selectedProviderProfileID : nil
            publishProviderConfiguration()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = coreOperationError(
                "현재 프로바이더 설정을 확인하지"
            )
            return
        }

        let temporarilyDeselected =
            originalSettings.selectedProviderProfileID == targetID
        if temporarilyDeselected {
            do {
                let updated = try await client.updateSettings(
                    CoreAppSettings(
                        preservePartialGenerations:
                            originalSettings.preservePartialGenerations,
                        selectedProviderProfileID: nil
                    )
                )
                preservePartialGenerations =
                    updated.preservePartialGenerations
                selectedProfileID = nil
                publishProviderConfiguration()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = coreOperationError(
                    "프로바이더 변경 준비를 완료하지"
                )
                return
            }
        }

        if credentialWasClearedBeforeProfileSave {
            let removedPreviousCredential =
                await deleteCredentialAndVerifyAbsence(
                    profileID: targetID
                )
            guard removedPreviousCredential else {
                _ = await restoreSelection(
                    originalSettings,
                    ifTemporarilyDeselected: temporarilyDeselected
                )
                isCredentialStateKnown = false
                errorMessage = credentialOperationError("삭제")
                statusMessage = changesCredentialEndpoint
                    ? "Base URL 변경을 안전하게 준비하지 못했습니다. 기존 프로필은 변경하지 않았습니다."
                    : "API 키 교체를 안전하게 준비하지 못했습니다. 기존 프로필은 변경하지 않았습니다."
                return
            }
        }

        let profile: ProviderProfile
        do {
            profile = try await client.upsertProviderProfile(
                ProviderProfile(
                    id: targetID,
                    displayName: normalizedName,
                    baseURL: normalizedURL,
                    model: normalizedModel,
                    timeoutSeconds: timeout
                )
            )
        } catch is CancellationError {
            _ = await restoreCredentialAndSelectionAfterPreclear(
                credentialBeforeSave,
                profileID: targetID,
                originalSettings: originalSettings,
                temporarilyDeselected: temporarilyDeselected,
                credentialWasCleared:
                    credentialWasClearedBeforeProfileSave,
                previousCredentialSnapshotIsKnown:
                    credentialSnapshotIsKnown
            )
            return
        } catch {
            let selectionRestored =
                await restoreCredentialAndSelectionAfterPreclear(
                    credentialBeforeSave,
                    profileID: targetID,
                    originalSettings: originalSettings,
                    temporarilyDeselected: temporarilyDeselected,
                    credentialWasCleared:
                        credentialWasClearedBeforeProfileSave,
                    previousCredentialSnapshotIsKnown:
                        credentialSnapshotIsKnown
                )
            errorMessage = coreOperationError(
                "프로바이더 프로필을 저장하지"
            )
            if temporarilyDeselected, !selectionRestored {
                statusMessage =
                    "안전을 위해 기본 프로바이더 선택을 해제했습니다. 목록에서 다시 선택하세요."
            }
            return
        }

        editingProfileID = profile.id
        profileName = profile.displayName
        baseURL = profile.baseURL
        model = profile.model
        timeoutSeconds = String(profile.timeoutSeconds)
        mergeSavedProfile(profile)

        if let credentialToStore {
            do {
                try await credentialStore.setCredential(
                    credentialToStore,
                    for: profile.id
                )
                credentialDraft = ""
                hasStoredCredential = true
                isCredentialStateKnown = true
            } catch {
                let recovery = await recoverAfterCredentialSaveFailure(
                    credentialWasClearedBeforeProfileSave:
                        credentialWasClearedBeforeProfileSave,
                    previousProfile: previousProfile,
                    savedProfile: profile,
                    previousCredential:
                        credentialBeforeSave,
                    previousCredentialSnapshotIsKnown:
                        credentialSnapshotIsKnown,
                    profileID: profile.id
                )
                let profileRolledBack = recovery.profileRolledBack
                let credentialRolledBack =
                    recovery.credentialRolledBack
                let recoverySucceeded =
                    profileRolledBack && credentialRolledBack
                if profileRolledBack {
                    if let previousProfile {
                        mergeSavedProfile(previousProfile)
                    } else {
                        profiles.removeAll { $0.id == profile.id }
                    }
                }
                let selectionRestored = recoverySucceeded
                    ? await restoreSelection(
                        originalSettings,
                        ifTemporarilyDeselected: temporarilyDeselected
                    )
                    : false
                if !recoverySucceeded {
                    await reconcileAfterProfileRecoveryFailure(
                        targetProfileID: profile.id,
                        fallbackSelection:
                            originalSettings.selectedProviderProfileID
                    )
                }
                await reconcileCredentialState(for: profile.id)
                if !recoverySucceeded {
                    isCredentialStateKnown = false
                }
                publishProviderConfiguration()
                if recoverySucceeded {
                    statusMessage = temporarilyDeselected
                        && !selectionRestored
                        ? "API 키 저장 실패로 프로필 변경을 되돌렸습니다. 기본 프로바이더는 다시 선택하세요."
                        : "API 키 저장 실패로 프로필 변경을 적용하지 않았습니다. 입력한 키를 확인하고 다시 저장하세요."
                } else {
                    providerConfigurationStore.quarantine(
                        profileID: profile.id
                    )
                    statusMessage =
                        "프로필과 API 키 상태를 자동 복구하지 못했습니다. 편집한 프로필은 사용하지 말고 API 키를 다시 입력해 저장하세요."
                }
                errorMessage = credentialOperationError("저장")
                return
            }
        } else {
            credentialDraft = ""
        }
        providerConfigurationStore.clearQuarantine(profileID: profile.id)

        do {
            let updated = try await client.updateSettings(
                CoreAppSettings(
                    preservePartialGenerations:
                        originalSettings.preservePartialGenerations,
                    selectedProviderProfileID: profile.id
                )
            )
            preservePartialGenerations = updated.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == updated.selectedProviderProfileID
            } ? updated.selectedProviderProfileID : nil
            publishProviderConfiguration()

            guard selectedProfileID == profile.id else {
                statusMessage =
                    "프로필은 저장했지만 기본 프로바이더로 선택되지 않았습니다. 프로필 목록에서 다시 선택하세요."
                errorMessage = "프로바이더 선택 결과를 확인할 수 없습니다."
                return
            }
            errorMessage = nil
            statusMessage = credentialToStore == nil
                ? "프로바이더 프로필을 저장하고 선택했습니다."
                : "프로바이더 프로필과 API 키를 저장하고 선택했습니다."
        } catch is CancellationError {
            await reconcileSelectionAfterSaveFailure(
                fallback: temporarilyDeselected
                    ? nil
                    : originalSettings.selectedProviderProfileID
            )
            statusMessage =
                "프로필은 저장했지만 기본 프로바이더 선택은 완료되지 않았습니다."
        } catch {
            await reconcileSelectionAfterSaveFailure(
                fallback: temporarilyDeselected
                    ? nil
                    : originalSettings.selectedProviderProfileID
            )
            statusMessage =
                "프로필은 저장했지만 기본 프로바이더로 선택하지 못했습니다. 프로필 목록에서 다시 선택하세요."
            errorMessage = coreOperationError(
                "기본 프로바이더 선택을 완료하지"
            )
        }
    }

    public func deleteEditingProfile() async {
        guard
            let profile = profiles.first(where: {
                $0.id == editingProfileID
            }),
            beginOperation()
        else {
            return
        }
        defer { endOperation() }
        let wasQuarantinedBeforeDeletion =
            providerConfigurationStore.isQuarantined(
                profileID: profile.id
            )
        providerConfigurationStore.beginMutation(profileID: profile.id)
        defer {
            providerConfigurationStore.endMutation(profileID: profile.id)
        }

        let storedCredential: String?
        let credentialSnapshotIsKnown: Bool
        do {
            storedCredential = try await credentialStore.credential(
                for: profile.id
            )
            credentialSnapshotIsKnown = true
        } catch {
            isCredentialStateKnown = false
            storedCredential = nil
            credentialSnapshotIsKnown = false
        }

        let originalSettings: CoreAppSettings
        do {
            originalSettings = try await client.getSettings()
            preservePartialGenerations =
                originalSettings.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == originalSettings.selectedProviderProfileID
            } ? originalSettings.selectedProviderProfileID : nil
            publishProviderConfiguration()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = coreOperationError(
                "현재 프로바이더 설정을 확인하지"
            )
            return
        }

        let temporarilyDeselected =
            originalSettings.selectedProviderProfileID == profile.id
        if temporarilyDeselected {
            do {
                let updated = try await client.updateSettings(
                    CoreAppSettings(
                        preservePartialGenerations:
                            originalSettings.preservePartialGenerations,
                        selectedProviderProfileID: nil
                    )
                )
                guard updated.selectedProviderProfileID == nil else {
                    errorMessage = coreOperationError(
                        "프로바이더 삭제 준비를 완료하지"
                    )
                    return
                }
                preservePartialGenerations =
                    updated.preservePartialGenerations
                selectedProfileID = profiles.contains {
                    $0.id == updated.selectedProviderProfileID
                } ? updated.selectedProviderProfileID : nil
                publishProviderConfiguration()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = coreOperationError(
                    "프로바이더 삭제 준비를 완료하지"
                )
                return
            }
        }

        do {
            try await credentialStore.deleteCredential(for: profile.id)
            guard
                try await credentialStore.credential(for: profile.id)
                    == nil
            else {
                throw CredentialStoreError.verificationFailed
            }
            hasStoredCredential = false
            isCredentialStateKnown = true
        } catch {
            if !credentialSnapshotIsKnown,
               await deleteCredentialAndVerifyAbsence(
                   profileID: profile.id
               )
            {
                // The unreadable item was removed on retry. Profile deletion
                // can continue without ever restoring unknown credential data.
            } else {
                let credentialIsUnchanged: Bool
                if credentialSnapshotIsKnown {
                    credentialIsUnchanged =
                        await verifyCredentialSnapshot(
                            storedCredential,
                            profileID: profile.id
                        )
                } else {
                    credentialIsUnchanged = false
                }
                if credentialIsUnchanged {
                    if temporarilyDeselected,
                       !wasQuarantinedBeforeDeletion
                    {
                        _ = await restoreSelection(
                            originalSettings,
                            ifTemporarilyDeselected: true
                        )
                    }
                } else {
                    providerConfigurationStore.quarantine(
                        profileID: profile.id
                    )
                    _ = await reconcileAfterProfileRecoveryFailure(
                        targetProfileID: profile.id,
                        fallbackSelection:
                            originalSettings.selectedProviderProfileID
                    )
                }
                errorMessage = credentialOperationError("삭제")
                return
            }
        }

        do {
            try await client.deleteProviderProfile(id: profile.id)
        } catch is CancellationError {
            if credentialSnapshotIsKnown {
                await restoreCredentialAfterFailedProfileDeletion(
                    storedCredential,
                    profileID: profile.id,
                    profileDeletionWasCancelled: true,
                    wasQuarantinedBeforeDeletion:
                        wasQuarantinedBeforeDeletion,
                    originalSettings: originalSettings,
                    temporarilyDeselected: temporarilyDeselected
                )
            } else {
                await handleProfileDeletionFailureWithoutCredentialSnapshot(
                    profileID: profile.id,
                    profileDeletionWasCancelled: true
                )
            }
            return
        } catch {
            if credentialSnapshotIsKnown {
                await restoreCredentialAfterFailedProfileDeletion(
                    storedCredential,
                    profileID: profile.id,
                    profileDeletionWasCancelled: false,
                    wasQuarantinedBeforeDeletion:
                        wasQuarantinedBeforeDeletion,
                    originalSettings: originalSettings,
                    temporarilyDeselected: temporarilyDeselected
                )
            } else {
                await handleProfileDeletionFailureWithoutCredentialSnapshot(
                    profileID: profile.id,
                    profileDeletionWasCancelled: false
                )
            }
            return
        }

        profiles.removeAll { $0.id == profile.id }
        providerConfigurationStore.clearQuarantine(profileID: profile.id)
        if selectedProfileID == profile.id {
            selectedProfileID = nil
        }
        credentialDraft = ""
        publishProviderConfiguration()

        var refreshFailed = false
        do {
            profiles = sortedProfiles(try await client.listProviderProfiles())
        } catch {
            refreshFailed = true
        }
        do {
            let settings = try await client.getSettings()
            preservePartialGenerations = settings.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == settings.selectedProviderProfileID
            } ? settings.selectedProviderProfileID : nil
        } catch {
            refreshFailed = true
        }
        publishProviderConfiguration()

        if let selectedProfileID,
           let nextProfile = profiles.first(where: {
               $0.id == selectedProfileID
           })
        {
            await loadEditorAndCredentialState(nextProfile)
        } else if let nextProfile = profiles.first {
            await loadEditorAndCredentialState(nextProfile)
        } else {
            resetEditorForNewProfile()
        }

        statusMessage =
            "프로바이더 프로필과 Keychain API 키를 삭제했습니다."
        if !isCredentialStateKnown {
            errorMessage = credentialOperationError("확인")
        } else if refreshFailed {
            errorMessage =
                "삭제는 완료했지만 프로바이더 설정을 새로고침하지 못했습니다."
        } else {
            errorMessage = nil
        }
    }

    public func clearCredential() async {
        guard beginOperation() else {
            return
        }
        defer { endOperation() }
        let targetID = editingProfileID
        let wasQuarantinedBeforeClear =
            providerConfigurationStore.isQuarantined(
                profileID: targetID
            )
        providerConfigurationStore.beginMutation(
            profileID: targetID
        )
        defer {
            providerConfigurationStore.endMutation(
                profileID: targetID
            )
        }

        let credentialBeforeClear: String?
        let credentialSnapshotIsKnown: Bool
        do {
            credentialBeforeClear =
                try await credentialStore.credential(for: targetID)
            credentialSnapshotIsKnown = true
        } catch {
            isCredentialStateKnown = false
            credentialBeforeClear = nil
            credentialSnapshotIsKnown = false
        }

        let originalSettings: CoreAppSettings
        do {
            originalSettings = try await client.getSettings()
            preservePartialGenerations =
                originalSettings.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == originalSettings.selectedProviderProfileID
            } ? originalSettings.selectedProviderProfileID : nil
            publishProviderConfiguration()
        } catch is CancellationError {
            return
        } catch {
            errorMessage = coreOperationError(
                "현재 프로바이더 설정을 확인하지"
            )
            return
        }

        let temporarilyDeselected =
            originalSettings.selectedProviderProfileID == targetID
        if temporarilyDeselected {
            do {
                let updated = try await client.updateSettings(
                    CoreAppSettings(
                        preservePartialGenerations:
                            originalSettings.preservePartialGenerations,
                        selectedProviderProfileID: nil
                    )
                )
                guard updated.selectedProviderProfileID == nil else {
                    errorMessage = coreOperationError(
                        "API 키 삭제 준비를 완료하지"
                    )
                    return
                }
                preservePartialGenerations =
                    updated.preservePartialGenerations
                selectedProfileID = nil
                publishProviderConfiguration()
            } catch is CancellationError {
                return
            } catch {
                errorMessage = coreOperationError(
                    "API 키 삭제 준비를 완료하지"
                )
                return
            }
        }

        do {
            try await credentialStore.deleteCredential(for: targetID)
            guard
                try await credentialStore.credential(for: targetID) == nil
            else {
                throw CredentialStoreError.verificationFailed
            }
            await completeCredentialClear(
                profileID: targetID,
                wasQuarantinedBeforeClear: wasQuarantinedBeforeClear,
                originalSettings: originalSettings,
                temporarilyDeselected: temporarilyDeselected
            )
        } catch {
            let credentialIsUnchanged: Bool
            if credentialSnapshotIsKnown {
                credentialIsUnchanged = await verifyCredentialSnapshot(
                    credentialBeforeClear,
                    profileID: targetID
                )
            } else {
                credentialIsUnchanged = false
            }
            if isCredentialStateKnown, !hasStoredCredential {
                await completeCredentialClear(
                    profileID: targetID,
                    wasQuarantinedBeforeClear:
                        wasQuarantinedBeforeClear,
                    originalSettings: originalSettings,
                    temporarilyDeselected: temporarilyDeselected
                )
                return
            }

            if credentialIsUnchanged,
               !wasQuarantinedBeforeClear
            {
                if temporarilyDeselected {
                    _ = await restoreSelection(
                        originalSettings,
                        ifTemporarilyDeselected: true
                    )
                }
            } else {
                providerConfigurationStore.quarantine(
                    profileID: targetID
                )
                _ = await reconcileAfterProfileRecoveryFailure(
                    targetProfileID: targetID,
                    fallbackSelection: temporarilyDeselected
                        ? nil
                        : originalSettings.selectedProviderProfileID
                )
            }
            errorMessage = credentialOperationError("삭제")
        }
    }

    private func completeCredentialClear(
        profileID: String,
        wasQuarantinedBeforeClear: Bool,
        originalSettings: CoreAppSettings,
        temporarilyDeselected: Bool
    ) async {
        credentialDraft = ""
        hasStoredCredential = false
        isCredentialStateKnown = true
        providerConfigurationStore.clearQuarantine(
            profileID: profileID
        )

        let selectionRestored = temporarilyDeselected
            ? await restoreSelection(
                originalSettings,
                ifTemporarilyDeselected: true
            )
            : true
        if temporarilyDeselected, !selectionRestored {
            statusMessage =
                "API 키 삭제는 완료했습니다. 기본 프로바이더는 다시 선택하세요."
        } else {
            statusMessage = wasQuarantinedBeforeClear
                ? "API 키 없이 사용할 수 있도록 프로필을 복구했습니다."
                : "Keychain API 키를 삭제했습니다."
        }
        errorMessage = nil
    }

    public func refreshCredentialStatus() async {
        guard isEditingStoredProfile, beginOperation() else {
            return
        }
        defer { endOperation() }

        await reconcileCredentialState(for: editingProfileID)
        if isCredentialStateKnown {
            errorMessage = nil
            statusMessage = "Keychain API 키 상태를 확인했습니다."
        }
    }

    private var normalizedCredentialDraft: String? {
        let normalized = credentialDraft.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return normalized.isEmpty ? nil : normalized
    }

    private func beginOperation() -> Bool {
        guard !isLoading else {
            return false
        }
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        return true
    }

    private func endOperation() {
        isLoading = false
        guard pendingProviderConfigurationRevision != nil else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.applyPendingProviderConfiguration()
        }
    }

    private func resetEditorForNewProfile() {
        editingProfileID = UUID().uuidString
        profileName = ""
        baseURL = "https://api.openai.com/v1"
        model = ""
        timeoutSeconds = "60"
        credentialDraft = ""
        hasStoredCredential = false
        isCredentialStateKnown = true
    }

    private func loadEditorAndCredentialState(
        _ profile: ProviderProfile
    ) async {
        editingProfileID = profile.id
        profileName = profile.displayName
        baseURL = profile.baseURL
        model = profile.model
        timeoutSeconds = String(profile.timeoutSeconds)
        credentialDraft = ""
        await reconcileCredentialState(for: profile.id)
    }

    private func reconcileCredentialState(for profileID: String) async {
        isCredentialStateKnown = false
        do {
            hasStoredCredential =
                try await credentialStore.credential(for: profileID) != nil
            isCredentialStateKnown = true
        } catch {
            hasStoredCredential = false
            errorMessage = credentialOperationError("확인")
        }
    }

    private func restoreCredentialAfterFailedProfileDeletion(
        _ credential: String?,
        profileID: String,
        profileDeletionWasCancelled: Bool,
        wasQuarantinedBeforeDeletion: Bool,
        originalSettings: CoreAppSettings,
        temporarilyDeselected: Bool
    ) async {
        let credentialRestored = await restoreCredentialSnapshot(
            credential,
            profileID: profileID
        )
        if credentialRestored {
            if !wasQuarantinedBeforeDeletion {
                providerConfigurationStore.clearQuarantine(
                    profileID: profileID
                )
            }
            let selectionRestored: Bool
            if temporarilyDeselected,
               !wasQuarantinedBeforeDeletion
            {
                selectionRestored = await restoreSelection(
                    originalSettings,
                    ifTemporarilyDeselected: true
                )
            } else if temporarilyDeselected {
                _ = await reconcileAfterProfileRecoveryFailure(
                    targetProfileID: profileID,
                    fallbackSelection: nil
                )
                selectionRestored = false
            } else {
                selectionRestored = true
            }
            errorMessage = profileDeletionWasCancelled
                ? "프로필 삭제가 취소되었습니다."
                : coreOperationError("프로바이더 프로필을 삭제하지")
            if wasQuarantinedBeforeDeletion {
                statusMessage =
                    "프로필은 남아 있습니다. API 키 안전 상태를 복구한 뒤 다시 선택하세요."
            } else if temporarilyDeselected, !selectionRestored {
                statusMessage =
                    "프로필과 API 키는 원래 상태로 복원했지만 기본 프로바이더는 다시 선택하세요."
            } else {
                statusMessage =
                    "프로필을 삭제하지 못해 Keychain API 키를 원래 상태로 복원했습니다."
            }
        } else {
            credentialDraft = ""
            providerConfigurationStore.quarantine(profileID: profileID)
            let selectionIsSafe =
                await reconcileAfterProfileRecoveryFailure(
                    targetProfileID: profileID,
                    fallbackSelection: temporarilyDeselected
                        ? nil
                        : originalSettings.selectedProviderProfileID
                )
            statusMessage = selectionIsSafe
                ? "프로필은 남아 있으며 기본 선택을 해제했습니다. API 키를 다시 입력한 뒤 저장하세요."
                : "프로필은 남아 있습니다. 채팅을 보내지 말고 API 키를 다시 입력한 뒤 저장하세요."
            errorMessage =
                "프로필 삭제와 Keychain API 키 자동 복원을 완료하지 못했습니다."
        }
    }

    private func handleProfileDeletionFailureWithoutCredentialSnapshot(
        profileID: String,
        profileDeletionWasCancelled: Bool
    ) async {
        credentialDraft = ""
        hasStoredCredential = false
        isCredentialStateKnown = true
        providerConfigurationStore.quarantine(profileID: profileID)
        _ = await reconcileAfterProfileRecoveryFailure(
            targetProfileID: profileID,
            fallbackSelection: nil
        )
        statusMessage =
            "읽을 수 없던 API 키는 삭제했지만 프로필은 남아 있습니다. API 키를 다시 입력해 저장하거나 프로필 삭제를 다시 시도하세요."
        errorMessage = profileDeletionWasCancelled
            ? "프로필 삭제가 취소되었습니다."
            : coreOperationError("프로바이더 프로필을 삭제하지")
    }

    private func restoreCredentialSnapshot(
        _ credential: String?,
        profileID: String
    ) async -> Bool {
        if let credential {
            try? await credentialStore.setCredential(
                credential,
                for: profileID
            )
        }
        return await verifyCredentialSnapshot(
            credential,
            profileID: profileID
        )
    }

    private func verifyCredentialSnapshot(
        _ credential: String?,
        profileID: String
    ) async -> Bool {
        do {
            let currentCredential =
                try await credentialStore.credential(for: profileID)
            hasStoredCredential = currentCredential != nil
            isCredentialStateKnown = true
            return currentCredential == credential
        } catch {
            hasStoredCredential = false
            isCredentialStateKnown = false
            return false
        }
    }

    private func rollbackProfileSave(
        previousProfile: ProviderProfile?,
        savedProfile: ProviderProfile
    ) async -> Bool {
        do {
            if let previousProfile {
                _ = try await client.upsertProviderProfile(previousProfile)
            } else {
                try await client.deleteProviderProfile(id: savedProfile.id)
            }
            return true
        } catch {
            return false
        }
    }

    private func restoreCredentialAndSelectionAfterPreclear(
        _ previousCredential: String?,
        profileID: String,
        originalSettings: CoreAppSettings,
        temporarilyDeselected: Bool,
        credentialWasCleared: Bool,
        previousCredentialSnapshotIsKnown: Bool
    ) async -> Bool {
        if credentialWasCleared {
            guard previousCredentialSnapshotIsKnown else {
                providerConfigurationStore.quarantine(
                    profileID: profileID
                )
                return false
            }
            let credentialRestored = await restoreCredentialSnapshot(
                previousCredential,
                profileID: profileID
            )
            guard credentialRestored else {
                providerConfigurationStore.quarantine(
                    profileID: profileID
                )
                return false
            }
        }
        return await restoreSelection(
            originalSettings,
            ifTemporarilyDeselected: temporarilyDeselected
        )
    }

    private func recoverAfterCredentialSaveFailure(
        credentialWasClearedBeforeProfileSave: Bool,
        previousProfile: ProviderProfile?,
        savedProfile: ProviderProfile,
        previousCredential: String?,
        previousCredentialSnapshotIsKnown: Bool,
        profileID: String
    ) async -> (
        profileRolledBack: Bool,
        credentialRolledBack: Bool
    ) {
        if credentialWasClearedBeforeProfileSave {
            guard await deleteCredentialAndVerifyAbsence(
                profileID: profileID
            ) else {
                // The saved profile still points to the endpoint for which the
                // new credential was intended. Do not restore the old profile
                // while Keychain state is unknown.
                return (false, false)
            }
        }

        let profileRolledBack = await rollbackProfileSave(
            previousProfile: previousProfile,
            savedProfile: savedProfile
        )
        guard profileRolledBack else {
            return (false, false)
        }
        guard previousCredentialSnapshotIsKnown else {
            return (true, false)
        }
        let credentialRolledBack = await rollbackCredentialSave(
            previousCredential,
            profileID: profileID
        )
        return (profileRolledBack, credentialRolledBack)
    }

    private func deleteCredentialAndVerifyAbsence(
        profileID: String
    ) async -> Bool {
        do {
            try await credentialStore.deleteCredential(for: profileID)
            guard
                try await credentialStore.credential(for: profileID) == nil
            else {
                return false
            }
            hasStoredCredential = false
            isCredentialStateKnown = true
            return true
        } catch {
            isCredentialStateKnown = false
            return false
        }
    }

    private func rollbackCredentialSave(
        _ previousCredential: String?,
        profileID: String
    ) async -> Bool {
        do {
            if let previousCredential {
                try await credentialStore.setCredential(
                    previousCredential,
                    for: profileID
                )
            } else {
                try await credentialStore.deleteCredential(for: profileID)
            }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func reconcileAfterProfileRecoveryFailure(
        targetProfileID: String,
        fallbackSelection: String?
    ) async -> Bool {
        if let loadedProfiles = try? await client.listProviderProfiles() {
            profiles = sortedProfiles(loadedProfiles)
        }

        var coreSelectionIsSafe = false
        do {
            let settings = try await client.getSettings()
            preservePartialGenerations = settings.preservePartialGenerations
            if settings.selectedProviderProfileID == targetProfileID {
                let updated = try await client.updateSettings(
                    CoreAppSettings(
                        preservePartialGenerations:
                            settings.preservePartialGenerations,
                        selectedProviderProfileID: nil
                    )
                )
                selectedProfileID = updated.selectedProviderProfileID
                coreSelectionIsSafe =
                    updated.selectedProviderProfileID != targetProfileID
            } else {
                selectedProfileID = settings.selectedProviderProfileID
                coreSelectionIsSafe = true
            }
        } catch {
            selectedProfileID = fallbackSelection == targetProfileID
                ? nil
                : fallbackSelection
        }
        selectedProfileID = profiles.contains {
            $0.id == selectedProfileID
        } ? selectedProfileID : nil
        publishProviderConfiguration()
        return coreSelectionIsSafe
    }

    private func restoreSelection(
        _ settings: CoreAppSettings,
        ifTemporarilyDeselected: Bool
    ) async -> Bool {
        guard ifTemporarilyDeselected else {
            selectedProfileID = profiles.contains {
                $0.id == settings.selectedProviderProfileID
            } ? settings.selectedProviderProfileID : nil
            publishProviderConfiguration()
            return true
        }

        do {
            let restored = try await client.updateSettings(settings)
            preservePartialGenerations =
                restored.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == restored.selectedProviderProfileID
            } ? restored.selectedProviderProfileID : nil
            publishProviderConfiguration()
            return selectedProfileID == settings.selectedProviderProfileID
        } catch {
            selectedProfileID = nil
            publishProviderConfiguration()
            return false
        }
    }

    private func reconcileSelectionAfterSaveFailure(
        fallback: String?
    ) async {
        do {
            let settings = try await client.getSettings()
            preservePartialGenerations = settings.preservePartialGenerations
            selectedProfileID = profiles.contains {
                $0.id == settings.selectedProviderProfileID
            } ? settings.selectedProviderProfileID : nil
        } catch {
            selectedProfileID = profiles.contains {
                $0.id == fallback
            } ? fallback : nil
        }
        publishProviderConfiguration()
    }

    private func mergeSavedProfile(_ profile: ProviderProfile) {
        profiles.removeAll { $0.id == profile.id }
        profiles.append(profile)
        profiles = sortedProfiles(profiles)
    }

    private func sortedProfiles(
        _ profiles: [ProviderProfile]
    ) -> [ProviderProfile] {
        profiles.sorted {
            if $0.displayName == $1.displayName {
                if $0.model == $1.model {
                    return $0.id.localizedStandardCompare($1.id)
                        == .orderedAscending
                }
                return $0.model.localizedStandardCompare($1.model)
                    == .orderedAscending
            }
            return $0.displayName.localizedStandardCompare($1.displayName)
                == .orderedAscending
        }
    }

    private func enqueueProviderConfiguration(revision: UInt64) async {
        if selfPublishedProviderConfigurationRevisions.remove(revision)
            != nil
        {
            return
        }
        if let pendingProviderConfigurationRevision {
            self.pendingProviderConfigurationRevision = max(
                pendingProviderConfigurationRevision,
                revision
            )
        } else {
            pendingProviderConfigurationRevision = revision
        }
        await applyPendingProviderConfiguration()
    }

    private func applyPendingProviderConfiguration() async {
        guard
            !isLoading,
            pendingProviderConfigurationRevision != nil
        else {
            return
        }
        pendingProviderConfigurationRevision = nil
        await adoptProviderConfiguration(
            revision: providerConfigurationStore.revision
        )
    }

    private func adoptProviderConfiguration(revision: UInt64) async {
        guard
            providerConfigurationStore.revision == revision,
            !isLoading
        else {
            return
        }

        let nextProfiles = providerConfigurationStore.profiles
        let nextSelectedProfileID =
            providerConfigurationStore.selectedProfileID
        let previousEditorProfile = profiles.first {
            $0.id == editingProfileID
        }
        let nextEditorProfile =
            nextSelectedProfileID.flatMap { selectedID in
                nextProfiles.first { $0.id == selectedID }
            }
            ?? nextProfiles.first { $0.id == editingProfileID }
        let editorHasLocalChanges = editorHasUnsavedChanges
        let editingStoredProfileWasDeleted =
            previousEditorProfile != nil
            && !nextProfiles.contains { $0.id == editingProfileID }
        let shouldReloadEditor =
            selectedProfileID != nextSelectedProfileID
            || previousEditorProfile != nextEditorProfile

        profiles = nextProfiles
        selectedProfileID = nextSelectedProfileID
        if shouldReloadEditor,
           editorHasLocalChanges,
           !editingStoredProfileWasDeleted
        {
            statusMessage =
                "다른 화면의 프로바이더 변경을 반영했지만 저장하지 않은 프로필 편집 내용은 유지했습니다."
            return
        }
        guard shouldReloadEditor, beginOperation() else {
            return
        }
        credentialDraft = ""
        defer { endOperation() }

        if let nextEditorProfile {
            await loadEditorAndCredentialState(nextEditorProfile)
        } else if let firstProfile = nextProfiles.first {
            await loadEditorAndCredentialState(firstProfile)
        } else {
            resetEditorForNewProfile()
        }

        if isCredentialStateKnown {
            errorMessage = nil
            statusMessage =
                "다른 화면에서 변경한 프로바이더 설정을 반영했습니다."
        }
    }

    private var editorHasUnsavedChanges: Bool {
        if !credentialDraft.isEmpty {
            return true
        }
        guard let profile = profiles.first(where: {
            $0.id == editingProfileID
        }) else {
            return !profileName.isEmpty
                || baseURL != "https://api.openai.com/v1"
                || !model.isEmpty
                || timeoutSeconds != "60"
        }
        return profileName != profile.displayName
            || baseURL != profile.baseURL
            || model != profile.model
            || timeoutSeconds != String(profile.timeoutSeconds)
    }

    private func publishProviderConfiguration() {
        let previousRevision = providerConfigurationStore.revision
        providerConfigurationStore.replace(
            profiles: profiles,
            selectedProfileID: selectedProfileID
        )
        if providerConfigurationStore.revision != previousRevision {
            selfPublishedProviderConfigurationRevisions.insert(
                providerConfigurationStore.revision
            )
        }
        profiles = providerConfigurationStore.profiles
        selectedProfileID = providerConfigurationStore.selectedProfileID
    }

    private func credentialOperationError(_ action: String) -> String {
        "Keychain에서 API 키 \(action) 작업을 완료하지 못했습니다."
    }

    private func coreOperationError(_ action: String) -> String {
        "\(action) 못했습니다. 잠시 후 다시 시도하세요."
    }
}
