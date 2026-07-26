import Combine
import Foundation

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var showTechnicalDetails = true
    @Published public private(set) var profiles: [ProviderProfile] = []
    @Published public private(set) var selectedProfileID: String?
    @Published public var preservePartialGenerations = false
    @Published public var profileName = ""
    @Published public var baseURL = ""
    @Published public var model = ""
    @Published public var timeoutSeconds = "60"
    @Published public var credentialDraft = ""
    @Published public private(set) var hasStoredCredential = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var statusMessage: String?

    public let runtimeMode: CoreRuntimeMode

    private let client: any CoreClient
    private let credentialStore: any CredentialStore
    private var editingProfileID = UUID().uuidString

    public init(
        client: any CoreClient,
        credentialStore: any CredentialStore,
        runtimeMode: CoreRuntimeMode
    ) {
        self.client = client
        self.credentialStore = credentialStore
        self.runtimeMode = runtimeMode
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let loadedProfiles = client.listProviderProfiles()
            async let loadedSettings = client.getSettings()
            profiles = try await loadedProfiles
            let settings = try await loadedSettings
            selectedProfileID = settings.selectedProviderProfileID
            preservePartialGenerations = settings.preservePartialGenerations
            if let selectedProfileID,
               let profile = profiles.first(where: { $0.id == selectedProfileID })
            {
                try await loadEditor(profile)
            } else if let profile = profiles.first {
                try await loadEditor(profile)
            } else {
                beginNewProfile()
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func selectProfile(id: String?) async {
        let previousID = selectedProfileID
        selectedProfileID = id
        do {
            _ = try await client.updateSettings(
                CoreAppSettings(
                    preservePartialGenerations: preservePartialGenerations,
                    selectedProviderProfileID: id
                )
            )
            if let id, let profile = profiles.first(where: { $0.id == id }) {
                try await loadEditor(profile)
            }
            errorMessage = nil
            statusMessage = "사용할 프로바이더를 변경했습니다."
        } catch {
            selectedProfileID = previousID
            errorMessage = error.localizedDescription
        }
    }

    public func setPreservePartialGenerations(_ value: Bool) async {
        let previousValue = preservePartialGenerations
        preservePartialGenerations = value
        do {
            _ = try await client.updateSettings(
                CoreAppSettings(
                    preservePartialGenerations: value,
                    selectedProviderProfileID: selectedProfileID
                )
            )
            errorMessage = nil
        } catch {
            preservePartialGenerations = previousValue
            errorMessage = error.localizedDescription
        }
    }

    public func beginNewProfile() {
        editingProfileID = UUID().uuidString
        profileName = ""
        baseURL = "https://api.openai.com/v1"
        model = ""
        timeoutSeconds = "60"
        credentialDraft = ""
        hasStoredCredential = false
        statusMessage = nil
    }

    public func editProfile(id: String) async {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            return
        }
        do {
            try await loadEditor(profile)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func saveProfile() async {
        let normalizedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalizedName.isEmpty,
            !normalizedURL.isEmpty,
            !normalizedModel.isEmpty,
            let timeout = UInt32(timeoutSeconds),
            (1 ... 600).contains(timeout)
        else {
            errorMessage = "이름, URL, 모델과 1~600초 제한 시간을 확인하세요."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let profile = try await client.upsertProviderProfile(
                ProviderProfile(
                    id: editingProfileID,
                    displayName: normalizedName,
                    baseURL: normalizedURL,
                    model: normalizedModel,
                    timeoutSeconds: timeout
                )
            )
            if !credentialDraft.isEmpty {
                try await credentialStore.setCredential(
                    credentialDraft,
                    for: profile.id
                )
                credentialDraft = ""
                hasStoredCredential = true
            }
            profiles = try await client.listProviderProfiles()
            await selectProfile(id: profile.id)
            statusMessage = "프로바이더 프로필을 저장했습니다."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteEditingProfile() async {
        guard profiles.contains(where: { $0.id == editingProfileID }) else {
            return
        }
        do {
            try await client.deleteProviderProfile(id: editingProfileID)
            let deletedID = editingProfileID
            var credentialError: Error?
            do {
                try await credentialStore.deleteCredential(for: deletedID)
            } catch {
                credentialError = error
            }
            profiles = try await client.listProviderProfiles()
            let nextID = profiles.first?.id
            await selectProfile(id: nextID)
            if nextID == nil {
                beginNewProfile()
            }
            if let credentialError {
                statusMessage = "프로바이더 프로필은 삭제했습니다."
                errorMessage = credentialError.localizedDescription
            } else if errorMessage == nil {
                statusMessage = "프로바이더 프로필과 Keychain 자격증명을 삭제했습니다."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func clearCredential() async {
        do {
            try await credentialStore.deleteCredential(for: editingProfileID)
            credentialDraft = ""
            hasStoredCredential = false
            statusMessage = "Keychain 자격증명을 삭제했습니다."
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadEditor(_ profile: ProviderProfile) async throws {
        editingProfileID = profile.id
        profileName = profile.displayName
        baseURL = profile.baseURL
        model = profile.model
        timeoutSeconds = String(profile.timeoutSeconds)
        credentialDraft = ""
        hasStoredCredential =
            try await credentialStore.credential(for: profile.id) != nil
    }
}
