import Foundation
@preconcurrency import Security

public protocol CredentialStore: Sendable {
    func credential(for profileID: String) async throws -> String?
    func setCredential(_ credential: String?, for profileID: String) async throws
    func deleteCredential(for profileID: String) async throws
}

public enum CredentialStoreError: Error, LocalizedError, Equatable, Sendable {
    case invalidEncoding
    case keychainStatus(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            "자격증명을 안전하게 인코딩할 수 없습니다."
        case let .keychainStatus(status):
            "Keychain 작업에 실패했습니다. (OSStatus \(status))"
        }
    }
}

public actor KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    public func credential(for profileID: String) async throws -> String? {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainStatus(status)
        }
        guard
            let data = result as? Data,
            let credential = String(data: data, encoding: .utf8)
        else {
            throw CredentialStoreError.invalidEncoding
        }
        return credential
    }

    public func setCredential(
        _ credential: String?,
        for profileID: String
    ) async throws {
        let normalized = credential?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized, !normalized.isEmpty else {
            try await deleteCredential(for: profileID)
            return
        }
        guard let data = normalized.data(using: .utf8) else {
            throw CredentialStoreError.invalidEncoding
        }

        let query = baseQuery(profileID: profileID)
        let updates: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            updates as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialStoreError.keychainStatus(updateStatus)
        }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CredentialStoreError.keychainStatus(addStatus)
        }
    }

    public func deleteCredential(for profileID: String) async throws {
        let status = SecItemDelete(baseQuery(profileID: profileID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainStatus(status)
        }
    }

    private func baseQuery(profileID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID,
        ]
    }
}

public actor InMemoryCredentialStore: CredentialStore {
    private var values: [String: String]

    public init(values: [String: String] = [:]) {
        self.values = values
    }

    public func credential(for profileID: String) async throws -> String? {
        values[profileID]
    }

    public func setCredential(
        _ credential: String?,
        for profileID: String
    ) async throws {
        if let credential, !credential.isEmpty {
            values[profileID] = credential
        } else {
            values.removeValue(forKey: profileID)
        }
    }

    public func deleteCredential(for profileID: String) async throws {
        values.removeValue(forKey: profileID)
    }
}
