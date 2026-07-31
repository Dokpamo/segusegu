import Foundation
@preconcurrency import Security

enum CredentialStorePolicy {
    static let maximumCredentialUTF8Bytes = 16 * 1_024
}

enum KeychainQueryBuilder {
    static func dataProtectionQuery(
        service: String,
        profileID: String
    ) -> [String: Any] {
        var query = baseQuery(service: service, profileID: profileID)
        // The production app's code-signing identity supplies its default
        // access group. Unsigned command-line hosts fail closed with
        // errSecMissingEntitlement instead of falling back to a weaker store.
        query[kSecUseDataProtectionKeychain as String] = true
        return query
    }

    static func legacyQuery(
        service: String,
        profileID: String
    ) -> [String: Any] {
        var query = baseQuery(service: service, profileID: profileID)
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = false
        #endif
        return query
    }

    static func updateAttributes(data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
    }

    static func addAttributes(
        query: [String: Any],
        data: Data
    ) -> [String: Any] {
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return item
    }

    private static func baseQuery(
        service: String,
        profileID: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
    }
}

struct KeychainCopyResult: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol KeychainSecurityClient: Sendable {
    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult
    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus
    func add(_ attributes: [String: Any]) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemKeychainSecurityClient: KeychainSecurityClient {
    func copyMatching(_ query: [String: Any]) -> KeychainCopyResult {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )
        return KeychainCopyResult(
            status: status,
            data: result as? Data
        )
    }

    func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

private func normalizedCredential(_ credential: String?) -> String? {
    guard let normalized = credential?.trimmingCharacters(
        in: .whitespacesAndNewlines
    ), !normalized.isEmpty else {
        return nil
    }
    return normalized
}

private func validatedCredential(
    _ credential: String?
) throws -> String? {
    guard let normalized = normalizedCredential(credential) else {
        return nil
    }
    guard
        normalized.utf8.count
            <= CredentialStorePolicy.maximumCredentialUTF8Bytes
    else {
        throw CredentialStoreError.credentialTooLarge
    }
    return normalized
}

public protocol CredentialStore: Sendable {
    func credential(for profileID: String) async throws -> String?
    func setCredential(_ credential: String?, for profileID: String) async throws
    func deleteCredential(for profileID: String) async throws
}

public enum CredentialStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidEncoding
    case credentialTooLarge
    case verificationFailed
    case keychainStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "자격증명을 안전하게 인코딩할 수 없습니다."
        case .credentialTooLarge:
            "API 키가 허용된 크기를 초과했습니다."
        case .verificationFailed:
            "Keychain 저장 결과를 안전하게 확인할 수 없습니다."
        case let .keychainStatus(status):
            "Keychain 작업에 실패했습니다. (OSStatus \(status))"
        }
    }
}

public actor KeychainCredentialStore: CredentialStore {
    private let service: String
    private let securityClient: any KeychainSecurityClient

    public init(service: String) {
        self.service = service
        securityClient = SystemKeychainSecurityClient()
    }

    init(
        service: String,
        securityClient: any KeychainSecurityClient
    ) {
        self.service = service
        self.securityClient = securityClient
    }

    public func credential(for profileID: String) async throws -> String? {
        if let data = try credentialData(
            query: dataProtectionQuery(profileID: profileID)
        ) {
            let credential = try decodeCredential(data)
            try hardenDataProtectionCredentialIfNeeded(
                originalData: data,
                normalizedData: Data(credential.utf8),
                profileID: profileID
            )
            #if os(macOS)
            try deleteItem(query: legacyQuery(profileID: profileID))
            #endif
            return credential
        }

        #if os(macOS)
        guard let legacyData = try credentialData(
            query: legacyQuery(profileID: profileID)
        ) else {
            return nil
        }
        let credential = try decodeCredential(legacyData)
        try migrateLegacyCredential(
            Data(credential.utf8),
            profileID: profileID
        )
        return credential
        #else
        return nil
        #endif
    }

    public func setCredential(
        _ credential: String?,
        for profileID: String
    ) async throws {
        guard let normalized = try validatedCredential(credential) else {
            try await deleteCredential(for: profileID)
            return
        }
        guard let data = normalized.data(using: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }

        let query = dataProtectionQuery(profileID: profileID)
        let previousData = try credentialData(query: query)
        try upsertCredentialData(data, query: query)
        do {
            try verifyDataProtectionItem(
                expectedData: data,
                profileID: profileID
            )
            #if os(macOS)
            try deleteItem(query: legacyQuery(profileID: profileID))
            #endif
        } catch {
            try? restoreCredentialData(previousData, query: query)
            throw error
        }
    }

    public func deleteCredential(for profileID: String) async throws {
        let query = dataProtectionQuery(profileID: profileID)
        let previousData = try credentialData(query: query)
        try deleteItem(query: query)
        #if os(macOS)
        do {
            try deleteItem(query: legacyQuery(profileID: profileID))
        } catch {
            try? restoreCredentialData(previousData, query: query)
            throw error
        }
        #endif
    }

    private func dataProtectionQuery(
        profileID: String
    ) -> [String: Any] {
        KeychainQueryBuilder.dataProtectionQuery(
            service: service,
            profileID: profileID
        )
    }

    private func legacyQuery(profileID: String) -> [String: Any] {
        KeychainQueryBuilder.legacyQuery(
            service: service,
            profileID: profileID
        )
    }

    private func credentialData(
        query: [String: Any]
    ) throws -> Data? {
        var dataQuery = query
        dataQuery[kSecReturnData as String] = true
        dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        let result = securityClient.copyMatching(dataQuery)
        let status = result.status
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainStatus(status)
        }
        guard let data = result.data else {
            throw CredentialStoreError.invalidEncoding
        }
        return data
    }

    private func decodeCredential(_ data: Data) throws -> String {
        guard let credential = String(data: data, encoding: .utf8),
              let normalized = try validatedCredential(credential)
        else {
            throw CredentialStoreError.invalidEncoding
        }
        return normalized
    }

    private func upsertCredentialData(
        _ data: Data,
        query: [String: Any]
    ) throws {
        let updates = KeychainQueryBuilder.updateAttributes(data: data)
        let updateStatus = securityClient.update(
            query,
            attributes: updates
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychainStatus(updateStatus)
        }

        let item = KeychainQueryBuilder.addAttributes(
            query: query,
            data: data
        )
        let addStatus = securityClient.add(item)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychainStatus(addStatus)
        }
    }

    private func verifyDataProtectionItem(
        expectedData: Data,
        profileID: String
    ) throws {
        var query = dataProtectionQuery(profileID: profileID)
        query[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard try credentialData(query: query) == expectedData else {
            throw CredentialStoreError.verificationFailed
        }
    }

    private func hardenDataProtectionCredentialIfNeeded(
        originalData: Data,
        normalizedData: Data,
        profileID: String
    ) throws {
        var hardenedQuery = dataProtectionQuery(profileID: profileID)
        hardenedQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        if try credentialData(query: hardenedQuery) == normalizedData {
            return
        }

        let query = dataProtectionQuery(profileID: profileID)
        do {
            try upsertCredentialData(normalizedData, query: query)
            try verifyDataProtectionItem(
                expectedData: normalizedData,
                profileID: profileID
            )
        } catch {
            try? upsertCredentialData(originalData, query: query)
            throw error
        }
    }

    private func restoreCredentialData(
        _ data: Data?,
        query: [String: Any]
    ) throws {
        if let data {
            try upsertCredentialData(data, query: query)
        } else {
            try deleteItem(query: query)
        }
    }

    private func deleteItem(query: [String: Any]) throws {
        let status = securityClient.delete(query)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainStatus(status)
        }
    }

    #if os(macOS)
    private func migrateLegacyCredential(
        _ data: Data,
        profileID: String
    ) throws {
        let protectedQuery = dataProtectionQuery(profileID: profileID)
        try upsertCredentialData(data, query: protectedQuery)
        do {
            try verifyDataProtectionItem(
                expectedData: data,
                profileID: profileID
            )
            try deleteItem(query: legacyQuery(profileID: profileID))
        } catch {
            try? deleteItem(query: protectedQuery)
            throw error
        }
    }
    #endif
}

public actor InMemoryCredentialStore: CredentialStore {
    private var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values.compactMapValues(normalizedCredential)
    }

    public func credential(for profileID: String) async throws -> String? {
        try validatedCredential(values[profileID])
    }

    public func setCredential(
        _ credential: String?,
        for profileID: String
    ) async throws {
        if let normalized = try validatedCredential(credential) {
            values[profileID] = normalized
        } else {
            values.removeValue(forKey: profileID)
        }
    }

    public func deleteCredential(for profileID: String) async throws {
        values.removeValue(forKey: profileID)
    }
}
