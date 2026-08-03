import Foundation
@preconcurrency import Security

enum NativeCredentialStatus: String {
    case missing
    case available
    case unreadable
}

enum KeychainCredentialStoreError: Error {
    case invalidData
    case operationFailed
    case verificationFailed
    case restoreFailed
}

private final class KeychainRecord {
    var data: Data
    let accessibility: String

    init(data: Data, accessibility: String) {
        self.data = data
        self.accessibility = accessibility
    }
}

final class KeychainCredentialStore {
    private let service = "dev.lorepia.provider-credentials"
    private let requiredAccessibility =
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String

    func status(reference: String) -> NativeCredentialStatus {
        do {
            try PlatformPolicy.validateReference(reference)
            return try read(reference: reference) == nil ? .missing : .available
        } catch {
            return .unreadable
        }
    }

    func read(reference: String) throws -> String? {
        try PlatformPolicy.validateReference(reference)
        let query = baseQuery(reference: reference)
        guard let originalRecord = try copyCredentialRecord(query: query) else {
            return nil
        }
        defer {
            wipe(&originalRecord.data)
        }

        guard
            let decoded = String(data: originalRecord.data, encoding: .utf8)
        else {
            throw KeychainCredentialStoreError.invalidData
        }
        let normalized = try PlatformPolicy.normalizeCredential(decoded)
        var normalizedData = Data(normalized.utf8)
        defer {
            wipe(&normalizedData)
        }

        if originalRecord.data != normalizedData
            || originalRecord.accessibility != requiredAccessibility
        {
            do {
                try upsert(normalizedData, query: query)
                try verify(normalizedData, reference: reference)
            } catch {
                do {
                    try restore(originalRecord, query: query)
                } catch {
                    throw KeychainCredentialStoreError.restoreFailed
                }
                throw error
            }
        }
        return normalized
    }

    func store(reference: String, value: String) throws {
        try PlatformPolicy.validateReference(reference)
        let normalized = try PlatformPolicy.normalizeCredential(value)
        var data = Data(normalized.utf8)
        defer {
            wipe(&data)
        }

        let query = baseQuery(reference: reference)
        let previousRecord = try copyCredentialRecord(query: query)
        defer {
            if let previousRecord {
                wipe(&previousRecord.data)
            }
        }

        do {
            try upsert(data, query: query)
            try verify(data, reference: reference)
        } catch {
            do {
                try restore(previousRecord, query: query)
            } catch {
                throw KeychainCredentialStoreError.restoreFailed
            }
            throw error
        }
    }

    func delete(reference: String) throws {
        try PlatformPolicy.validateReference(reference)
        let status = SecItemDelete(baseQuery(reference: reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainCredentialStoreError.operationFailed
        }
    }

    private func baseQuery(reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: reference,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private func copyCredentialRecord(
        query: [String: Any]
    ) throws -> KeychainRecord? {
        var dataQuery = query
        dataQuery[kSecReturnData as String] = true
        dataQuery[kSecReturnAttributes as String] = true
        dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(dataQuery as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard
            status == errSecSuccess,
            let attributes = result as? [String: Any],
            let data = attributes[kSecValueData as String] as? Data,
            let accessibility =
                attributes[kSecAttrAccessible as String] as? String
        else {
            throw KeychainCredentialStoreError.operationFailed
        }
        guard
            !data.isEmpty,
            data.count <= PlatformPolicy.maximumCredentialBytes
        else {
            throw KeychainCredentialStoreError.invalidData
        }
        return KeychainRecord(
            data: data,
            accessibility: accessibility
        )
    }

    private func upsert(
        _ data: Data,
        query: [String: Any],
        accessibility: String? = nil
    ) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                accessibility ?? requiredAccessibility,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainCredentialStoreError.operationFailed
        }

        var item = query
        attributes.forEach { key, value in
            item[key] = value
        }
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        // A duplicate means another writer won the add race after our
        // not-found result. Do not overwrite that unsnapshotted item: doing so
        // would make a later verification rollback capable of deleting or
        // replacing another process's credential.
        guard addStatus == errSecSuccess else {
            throw KeychainCredentialStoreError.operationFailed
        }
    }

    private func verify(_ expected: Data, reference: String) throws {
        guard let record = try copyCredentialRecord(
            query: baseQuery(reference: reference)
        ) else {
            throw KeychainCredentialStoreError.verificationFailed
        }
        defer {
            wipe(&record.data)
        }
        guard
            record.data == expected,
            record.accessibility == requiredAccessibility
        else {
            throw KeychainCredentialStoreError.verificationFailed
        }
    }

    private func restore(
        _ record: KeychainRecord?,
        query: [String: Any]
    ) throws {
        if let record {
            try upsert(
                record.data,
                query: query,
                accessibility: record.accessibility
            )
            guard let restored = try copyCredentialRecord(query: query) else {
                throw KeychainCredentialStoreError.restoreFailed
            }
            defer {
                wipe(&restored.data)
            }
            guard
                restored.data == record.data,
                restored.accessibility == record.accessibility
            else {
                throw KeychainCredentialStoreError.restoreFailed
            }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainCredentialStoreError.restoreFailed
            }
            guard try copyCredentialRecord(query: query) == nil else {
                throw KeychainCredentialStoreError.restoreFailed
            }
        }
    }

    private func wipe(_ data: inout Data) {
        guard !data.isEmpty else {
            return
        }
        data.resetBytes(in: 0 ..< data.count)
    }
}
