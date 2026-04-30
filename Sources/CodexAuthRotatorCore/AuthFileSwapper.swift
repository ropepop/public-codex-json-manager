import Foundation

public struct AuthFileSwapper: Sendable {
    public let liveAuthURL: URL

    public init(liveAuthURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")) {
        self.liveAuthURL = liveAuthURL
    }

    public func swapIn(sourceAuthFileURL: URL) throws {
        let fileManager = FileManager.default
        let data = try Data(contentsOf: sourceAuthFileURL)
        let liveDirectory = liveAuthURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: liveDirectory, withIntermediateDirectories: true)

        let tempURL = liveDirectory.appendingPathComponent("auth.json.swap")
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fileManager.fileExists(atPath: liveAuthURL.path) {
            _ = try fileManager.replaceItemAt(liveAuthURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: liveAuthURL)
        }
    }

    public func currentAuthFingerprint() throws -> String? {
        guard FileManager.default.fileExists(atPath: liveAuthURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: liveAuthURL)
        return AuthScanner.fingerprint(for: data)
    }

    public func currentAuthData() throws -> Data? {
        guard FileManager.default.fileExists(atPath: liveAuthURL.path) else {
            return nil
        }
        return try Data(contentsOf: liveAuthURL)
    }

    public func saveCurrentAuth(to destinationURL: URL) throws {
        guard let data = try currentAuthData() else {
            return
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destinationURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
    }
}
