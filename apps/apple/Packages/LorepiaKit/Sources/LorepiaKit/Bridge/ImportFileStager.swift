import Foundation
import Darwin

public enum ImportStagingError: Error, LocalizedError, Equatable, Sendable {
    case sourceIsNotRegularFile
    case sourceTooLarge(maxBytes: UInt64)
    case cannotCreateStagingDirectory
    case fileSystemError(code: Int32)

    public var errorDescription: String? {
        switch self {
        case .sourceIsNotRegularFile:
            "일반 파일만 가져올 수 있습니다."
        case let .sourceTooLarge(maxBytes):
            "파일이 허용 크기(\(ByteCountFormatter.string(fromByteCount: Int64(maxBytes), countStyle: .file)))를 초과합니다."
        case .cannotCreateStagingDirectory:
            "앱 전용 임시 가져오기 폴더를 만들 수 없습니다."
        case let .fileSystemError(code):
            "가져오기 파일 작업에 실패했습니다. (errno \(code))"
        }
    }
}

/// Copies a document-provider URL into an app-owned, bounded staging file.
///
/// This layer never parses content. Rust reopens and inspects the staged copy.
public actor ImportFileStager {
    public static let defaultMaximumBytes: UInt64 = 128 * 1024 * 1024

    private let directory: URL
    private let maximumBytes: UInt64
    private let fileManager: FileManager
    private let readChunkSize: Int

    public init(
        directory: URL,
        maximumBytes: UInt64 = ImportFileStager.defaultMaximumBytes,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
        readChunkSize = 64 * 1024
        Self.removeAbandonedFiles(in: directory, fileManager: fileManager)
    }

    init(
        directory: URL,
        maximumBytes: UInt64,
        fileManager: FileManager = .default,
        readChunkSize: Int
    ) {
        precondition(readChunkSize > 0)
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.fileManager = fileManager
        self.readChunkSize = readChunkSize
        Self.removeAbandonedFiles(in: directory, fileManager: fileManager)
    }

    public func stage(_ sourceURL: URL) async throws -> URL {
        try Task.checkCancellation()
        guard maximumBytes > 0 else {
            throw ImportStagingError.sourceTooLarge(maxBytes: maximumBytes)
        }
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw ImportStagingError.cannotCreateStagingDirectory
        }

        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceDescriptor = sourceURL.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard sourceDescriptor >= 0 else {
            if errno == ELOOP {
                throw ImportStagingError.sourceIsNotRegularFile
            }
            throw ImportStagingError.fileSystemError(code: errno)
        }

        var sourceStatus = stat()
        guard Darwin.fstat(sourceDescriptor, &sourceStatus) == 0 else {
            let code = errno
            Darwin.close(sourceDescriptor)
            throw ImportStagingError.fileSystemError(code: code)
        }
        guard sourceStatus.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(sourceDescriptor)
            throw ImportStagingError.sourceIsNotRegularFile
        }
        if sourceStatus.st_size < 0
            || UInt64(sourceStatus.st_size) > maximumBytes
        {
            Darwin.close(sourceDescriptor)
            throw ImportStagingError.sourceTooLarge(maxBytes: maximumBytes)
        }
        do {
            try Task.checkCancellation()
        } catch {
            Darwin.close(sourceDescriptor)
            throw error
        }

        let fileExtension = sourceURL.pathExtension
        let basename = UUID().uuidString
        let finalName = fileExtension.isEmpty
            ? basename
            : "\(basename).\(fileExtension)"
        let destination = directory.appendingPathComponent(finalName)
        let partial = directory.appendingPathComponent("\(finalName).partial")

        let outputDescriptor = partial.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        }
        guard outputDescriptor >= 0 else {
            let code = errno
            Darwin.close(sourceDescriptor)
            throw ImportStagingError.fileSystemError(code: code)
        }

        do {
            let source = FileHandle(
                fileDescriptor: sourceDescriptor,
                closeOnDealloc: true
            )
            let output = FileHandle(
                fileDescriptor: outputDescriptor,
                closeOnDealloc: true
            )
            defer {
                try? source.close()
                try? output.close()
            }

            var copied: UInt64 = 0
            while true {
                try Task.checkCancellation()
                guard
                    let chunk = try source.read(upToCount: readChunkSize),
                    !chunk.isEmpty
                else {
                    break
                }
                let addition = copied.addingReportingOverflow(UInt64(chunk.count))
                guard !addition.overflow, addition.partialValue <= maximumBytes else {
                    throw ImportStagingError.sourceTooLarge(maxBytes: maximumBytes)
                }
                copied = addition.partialValue
                try output.write(contentsOf: chunk)
                await Task.yield()
            }
            try Task.checkCancellation()
            try output.synchronize()
            try Task.checkCancellation()
            try fileManager.moveItem(at: partial, to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    public func remove(_ stagedURL: URL) {
        guard stagedURL.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL
        else {
            return
        }
        try? fileManager.removeItem(at: stagedURL)
    }

    private static func removeAbandonedFiles(
        in directory: URL,
        fileManager: FileManager
    ) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in urls {
            try? fileManager.removeItem(at: url)
        }
    }
}
