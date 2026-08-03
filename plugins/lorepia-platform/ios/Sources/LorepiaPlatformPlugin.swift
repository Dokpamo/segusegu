import Foundation
import Tauri
import UIKit
import UniformTypeIdentifiers

private protocol RedactedDescription: CustomStringConvertible,
    CustomDebugStringConvertible {}

extension RedactedDescription {
    var description: String {
        "[REDACTED]"
    }

    var debugDescription: String {
        description
    }
}

private struct ReferenceArgs: Decodable, RedactedDescription {
    let reference: String
}

private struct CredentialArgs: Decodable, RedactedDescription {
    let reference: String
    let value: String
}

private struct StagedPathArgs: Decodable, RedactedDescription {
    let path: String
}

private struct PathResponse: Encodable, RedactedDescription {
    let path: String
}

private struct CredentialResponse: Encodable, RedactedDescription {
    let value: String?
}

private struct CredentialStatusResponse: Encodable {
    let status: String
}

private struct PickResponse: Encodable, RedactedDescription {
    let selected: Bool
    let path: String?
    let displayName: String?
    let sizeBytes: UInt64?
}

private struct NativeStorage {
    let dataRoot: URL
    let stager: ImportStager

    init() throws {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ImportStagingError.storageUnavailable
        }
        dataRoot = applicationSupport.appendingPathComponent(
            "LorePia",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: dataRoot,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        stager = try ImportStager(dataRoot: dataRoot)
    }
}

final class PlatformWorkQueues {
    private let credentialQueue = DispatchQueue(
        label: "dev.lorepia.tauri.platform.credential",
        qos: .userInitiated
    )
    private let stagingQueue = DispatchQueue(
        label: "dev.lorepia.tauri.platform.staging",
        qos: .userInitiated
    )

    func scheduleCredential(_ operation: @escaping () -> Void) {
        credentialQueue.async(execute: operation)
    }

    func scheduleStaging(_ operation: @escaping () -> Void) {
        stagingQueue.async(execute: operation)
    }
}

final class LorepiaPlatformPlugin: Plugin, UIDocumentPickerDelegate {
    private let credentialStore = KeychainCredentialStore()
    private let workQueues = PlatformWorkQueues()
    private let storage: Result<NativeStorage, Error>
    private var pendingPickerInvoke: Invoke?

    override init() {
        storage = Result {
            try NativeStorage()
        }
        super.init()
    }

    @objc public func dataRoot(_ invoke: Invoke) {
        do {
            let storage = try storage.get()
            invoke.resolve(PathResponse(path: storage.dataRoot.path))
        } catch {
            invoke.reject("storage unavailable", code: "storage_unavailable")
        }
    }

    @objc public func credentialStatus(_ invoke: Invoke) {
        workQueues.scheduleCredential {
            do {
                let args = try invoke.parseArgs(ReferenceArgs.self)
                let status = self.credentialStore.status(
                    reference: args.reference
                )
                invoke.resolve(
                    CredentialStatusResponse(status: status.rawValue)
                )
            } catch {
                invoke.resolve(
                    CredentialStatusResponse(
                        status: NativeCredentialStatus.unreadable.rawValue
                    )
                )
            }
        }
    }

    @objc public func readCredential(_ invoke: Invoke) {
        workQueues.scheduleCredential {
            do {
                let args = try invoke.parseArgs(ReferenceArgs.self)
                let value = try self.credentialStore.read(
                    reference: args.reference
                )
                invoke.resolve(CredentialResponse(value: value))
            } catch {
                self.rejectCredential(invoke, error: error)
            }
        }
    }

    @objc public func storeCredential(_ invoke: Invoke) {
        workQueues.scheduleCredential {
            do {
                let args = try invoke.parseArgs(CredentialArgs.self)
                try self.credentialStore.store(
                    reference: args.reference,
                    value: args.value
                )
                invoke.resolve()
            } catch {
                self.rejectCredential(invoke, error: error)
            }
        }
    }

    @objc public func deleteCredential(_ invoke: Invoke) {
        workQueues.scheduleCredential {
            do {
                let args = try invoke.parseArgs(ReferenceArgs.self)
                try self.credentialStore.delete(reference: args.reference)
                invoke.resolve()
            } catch {
                invoke.reject(
                    "credential unavailable",
                    code: "credential_unavailable"
                )
            }
        }
    }

    @objc public func pickImport(_ invoke: Invoke) {
        DispatchQueue.main.async {
            guard self.pendingPickerInvoke == nil else {
                invoke.reject("file picker is busy", code: "busy")
                return
            }
            guard let viewController = self.manager.viewController else {
                invoke.reject(
                    "file selection failed",
                    code: "selection_failed"
                )
                return
            }

            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: [.data],
                asCopy: false
            )
            picker.allowsMultipleSelection = false
            picker.delegate = self
            self.pendingPickerInvoke = invoke
            viewController.present(picker, animated: true)
        }
    }

    @objc public func discardStagedImport(_ invoke: Invoke) {
        workQueues.scheduleStaging {
            do {
                let args = try invoke.parseArgs(StagedPathArgs.self)
                let storage = try self.storage.get()
                try storage.stager.discard(path: args.path)
                invoke.resolve()
            } catch {
                invoke.reject(
                    "storage unavailable",
                    code: "storage_unavailable"
                )
            }
        }
    }

    func documentPicker(
        _ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]
    ) {
        guard let invoke = takePendingPickerInvoke() else {
            return
        }
        guard let selectedURL = urls.first else {
            invoke.resolve(
                PickResponse(
                    selected: false,
                    path: nil,
                    displayName: nil,
                    sizeBytes: nil
                )
            )
            return
        }

        workQueues.scheduleStaging {
            do {
                let storage = try self.storage.get()
                let staged = try storage.stager.stage(
                    securityScopedURL: selectedURL
                )
                invoke.resolve(
                    PickResponse(
                        selected: true,
                        path: staged.path,
                        displayName: staged.displayName,
                        sizeBytes: staged.sizeBytes
                    )
                )
            } catch ImportStagingError.selectedFileTooLarge {
                invoke.reject(
                    "selected file is too large",
                    code: "selected_file_too_large"
                )
            } catch {
                invoke.reject(
                    "file selection failed",
                    code: "selection_failed"
                )
            }
        }
    }

    func documentPickerWasCancelled(
        _ controller: UIDocumentPickerViewController
    ) {
        takePendingPickerInvoke()?.resolve(
            PickResponse(
                selected: false,
                path: nil,
                displayName: nil,
                sizeBytes: nil
            )
        )
    }

    private func takePendingPickerInvoke() -> Invoke? {
        dispatchPrecondition(condition: .onQueue(.main))
        defer {
            pendingPickerInvoke = nil
        }
        return pendingPickerInvoke
    }

    private func rejectCredential(_ invoke: Invoke, error: Error) {
        let code: String
        if let storeError = error as? KeychainCredentialStoreError,
            case .restoreFailed = storeError
        {
            code = "credential_recovery_required"
        } else {
            code = "credential_unavailable"
        }
        invoke.reject("credential unavailable", code: code)
    }
}

@_cdecl("init_plugin_lorepia_platform")
func initPlugin() -> Plugin {
    LorepiaPlatformPlugin()
}
