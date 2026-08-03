import Foundation

enum PlatformPolicyError: Error {
    case invalidCredential
    case invalidReference
}

enum PlatformPolicy {
    static let maximumReferenceBytes = 256
    static let maximumCredentialBytes = 16 * 1_024
    static let maximumImportBytes: UInt64 = 128 * 1_024 * 1_024
    static let copyBufferBytes = 64 * 1_024
    static let maximumDisplayNameCharacters = 255
    static let ownedStagingPrefix = "lorepia-tauri-"
    static let abandonedStagingAge: TimeInterval = 24 * 60 * 60

    static func validateReference(_ reference: String) throws {
        guard
            !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            reference.utf8.count <= maximumReferenceBytes
        else {
            throw PlatformPolicyError.invalidReference
        }
    }

    static func normalizeCredential(_ value: String) throws -> String {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !normalized.isEmpty,
            normalized.utf8.count <= maximumCredentialBytes
        else {
            throw PlatformPolicyError.invalidCredential
        }
        return normalized
    }

    static func sanitizeDisplayName(_ value: String?) -> String {
        guard let value else {
            return "selected-file"
        }
        let scalars = value.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar)
                ? "\u{FFFD}"
                : Character(String(scalar))
        }
        let sanitized = String(scalars.prefix(maximumDisplayNameCharacters))
        return sanitized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "selected-file"
            : sanitized
    }

    static func stagingSuffix(for displayName: String) -> String {
        switch (displayName as NSString).pathExtension.lowercased() {
        case "charx":
            ".charx"
        case "json":
            ".json"
        case "zip":
            ".zip"
        default:
            ".pending"
        }
    }

    static func shouldRemoveAbandonedStagingFile(
        name: String,
        isRegularFile: Bool,
        modifiedAt: Date?,
        now: Date
    ) -> Bool {
        guard
            name.hasPrefix(ownedStagingPrefix),
            isRegularFile,
            let modifiedAt,
            now >= modifiedAt
        else {
            return false
        }
        return now.timeIntervalSince(modifiedAt) >= abandonedStagingAge
    }
}
