import Foundation

public struct CodexHomeClone: Sendable {
    public let temporaryRootURL: URL
    public let fallbackHomeURL: URL
    public let codexHomeURL: URL
    public let authFileURL: URL

    public init(
        temporaryRootURL: URL,
        fallbackHomeURL: URL,
        codexHomeURL: URL,
        authFileURL: URL
    ) {
        self.temporaryRootURL = temporaryRootURL
        self.fallbackHomeURL = fallbackHomeURL
        self.codexHomeURL = codexHomeURL
        self.authFileURL = authFileURL
    }
}

public struct CodexHomeClonePreparer: Sendable {
    private static let atomicallyRewrittenSharedItemNames: Set<String> = [
        ".codex-global-state.json",
        ".codex-global-state.json.bak",
    ]

    public init() {}

    public func prepareClone(
        sourceCodexHomeURL: URL,
        sourceAuthFileURL: URL,
        temporaryRootURL: URL
    ) throws -> CodexHomeClone {
        let fileManager = FileManager.default
        let codexHomeURL = temporaryRootURL.appendingPathComponent("codex-home", isDirectory: true)
        let fallbackHomeURL = temporaryRootURL.appendingPathComponent("home", isDirectory: true)
        let fallbackCodexLinkURL = fallbackHomeURL.appendingPathComponent(".codex")
        let authFileURL = codexHomeURL.appendingPathComponent("auth.json")

        try fileManager.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: fallbackHomeURL, withIntermediateDirectories: true)

        try copyAuth(from: sourceAuthFileURL, to: authFileURL)
        try linkSharedCodexHomeItems(from: sourceCodexHomeURL, to: codexHomeURL)
        try fileManager.createSymbolicLink(at: fallbackCodexLinkURL, withDestinationURL: codexHomeURL)
        try linkFallbackKeychains(from: sourceCodexHomeURL, to: fallbackHomeURL)

        return CodexHomeClone(
            temporaryRootURL: temporaryRootURL,
            fallbackHomeURL: fallbackHomeURL,
            codexHomeURL: codexHomeURL,
            authFileURL: authFileURL
        )
    }

    public func mergeNewNonAuthItems(from clone: CodexHomeClone, into sourceCodexHomeURL: URL) throws -> [String] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: clone.codexHomeURL.path) else {
            return []
        }

        try fileManager.createDirectory(at: sourceCodexHomeURL, withIntermediateDirectories: true)

        var mergedNames: [String] = []
        for itemURL in try fileManager.contentsOfDirectory(
            at: clone.codexHomeURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            let name = itemURL.lastPathComponent
            guard name != "auth.json" else {
                continue
            }

            if (try? fileManager.destinationOfSymbolicLink(atPath: itemURL.path)) != nil {
                continue
            }

            let destinationURL = sourceCodexHomeURL.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destinationURL.path) {
                if Self.atomicallyRewrittenSharedItemNames.contains(name),
                   try isRegularFile(itemURL),
                   try isRegularFile(destinationURL) {
                    _ = try fileManager.replaceItemAt(
                        destinationURL,
                        withItemAt: itemURL,
                        backupItemName: nil,
                        options: []
                    )
                    mergedNames.append(name)
                    continue
                }

                throw CodexHomeClonePreparerError.mergeConflict(name)
            }

            try fileManager.moveItem(at: itemURL, to: destinationURL)
            mergedNames.append(name)
        }

        return mergedNames
    }

    private func linkSharedCodexHomeItems(from sourceCodexHomeURL: URL, to cloneCodexHomeURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sourceCodexHomeURL.path) else {
            return
        }

        let itemURLs = try fileManager.contentsOfDirectory(
            at: sourceCodexHomeURL,
            includingPropertiesForKeys: nil,
            options: []
        )

        for itemURL in itemURLs where itemURL.lastPathComponent != "auth.json" {
            let cloneItemURL = cloneCodexHomeURL.appendingPathComponent(itemURL.lastPathComponent)
            try fileManager.createSymbolicLink(at: cloneItemURL, withDestinationURL: itemURL)
        }
    }

    private func linkFallbackKeychains(from sourceCodexHomeURL: URL, to fallbackHomeURL: URL) throws {
        let fileManager = FileManager.default
        let sourceHomeURL = sourceCodexHomeURL.deletingLastPathComponent()
        let sourceKeychainsURL = sourceHomeURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Keychains", isDirectory: true)

        guard fileManager.fileExists(atPath: sourceKeychainsURL.path) else {
            return
        }

        let fallbackLibraryURL = fallbackHomeURL.appendingPathComponent("Library", isDirectory: true)
        let fallbackKeychainsURL = fallbackLibraryURL.appendingPathComponent("Keychains", isDirectory: true)
        try fileManager.createDirectory(at: fallbackLibraryURL, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: fallbackKeychainsURL, withDestinationURL: sourceKeychainsURL)
    }

    private func copyAuth(from sourceAuthFileURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: sourceAuthFileURL)
        try data.write(to: destinationURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
    }

    private func isRegularFile(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        return values.isRegularFile == true
    }
}

public enum CodexHomeClonePreparerError: LocalizedError, Equatable, Sendable {
    case mergeConflict(String)

    public var errorDescription: String? {
        switch self {
        case let .mergeConflict(name):
            return "Temporary Codex home created \(name), but the real Codex home already has an item with that name."
        }
    }
}
