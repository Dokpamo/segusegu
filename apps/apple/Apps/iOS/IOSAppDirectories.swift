import Foundation

enum IOSAppDirectories {
    static func dataRoot() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let root = base.appending(
            component: "LorePia",
            directoryHint: .isDirectory
        )
        try? FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        return root
    }
}
