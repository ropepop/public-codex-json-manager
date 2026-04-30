import CodexAuthRotatorCore
import Foundation

struct AuthSaveDestination: Hashable, Sendable {
    let folderURL: URL
    let authFileURL: URL
    let kind: AuthSaveDestinationKind

    var isCustom: Bool {
        kind == .customOverride
    }
}

enum AuthSaveDestinationKind: String, Hashable, Sendable {
    case customOverride
    case existingTracked
    case emptyPlaceholder
    case newFolder
}

struct AuthSaveDestinationOverrideStore: Sendable {
    let storageURL: URL

    init(storageURL: URL = Self.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return [:]
        }

        let data = try Data(contentsOf: storageURL)
        return try JSONDecoder().decode([String: String].self, from: data)
    }

    func save(_ overridesByTrackingKey: [String: String]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(overridesByTrackingKey)
        try data.write(to: storageURL, options: .atomic)
    }

    static func defaultStorageURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("CodexAuthRotator", isDirectory: true)
            .appendingPathComponent("save-destination-overrides.json")
    }
}

enum AuthSaveDestinationResolver {
    static func resolve(
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        groups: [DuplicateGroup],
        overridesByTrackingKey: [String: String],
        emptyFolders: [AuthStoreEmptyFolder]? = nil
    ) -> AuthSaveDestination {
        if let customDestination = customOverrideDestination(
            rootURL: rootURL,
            liveStatus: liveStatus,
            overridesByTrackingKey: overridesByTrackingKey
        ) {
            return customDestination
        }

        if let activeGroup = AuthAccountMatcher.preferredSavedGroup(for: liveStatus, in: groups) {
            return AuthSaveDestination(
                folderURL: activeGroup.primaryRecord.folderURL,
                authFileURL: activeGroup.primaryRecord.authFileURL,
                kind: .existingTracked
            )
        }

        let inspectedFolders = emptyFolders ?? AuthStoreFolderInspector.inspect(rootURL: rootURL, liveStatus: liveStatus, groups: groups)
        if let folder = AuthStoreFolderInspector.matchingPlaceholder(in: inspectedFolders) {
            return AuthSaveDestination(
                folderURL: folder.folderURL,
                authFileURL: folder.folderURL.appendingPathComponent("auth.json"),
                kind: .emptyPlaceholder
            )
        }

        let authFileURL = AuthStoreDestinationPlanner.newFolderAuthURL(
            rootURL: rootURL,
            liveStatus: liveStatus,
            groups: groups
        )
        return AuthSaveDestination(
            folderURL: authFileURL.deletingLastPathComponent(),
            authFileURL: authFileURL,
            kind: .newFolder
        )
    }

    private static func isInsideRoot(folderURL: URL, rootURL: URL) -> Bool {
        let standardizedFolderURL = folderURL.standardizedFileURL
        let standardizedRootURL = rootURL.standardizedFileURL
        let rootPath = standardizedRootURL.path
        let folderPath = standardizedFolderURL.path
        return folderPath == rootPath || folderPath.hasPrefix(rootPath + "/")
    }

    private static func customOverrideDestination(
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        overridesByTrackingKey: [String: String]
    ) -> AuthSaveDestination? {
        let candidatePaths = overridePaths(for: liveStatus, overridesByTrackingKey: overridesByTrackingKey)

        for candidatePath in candidatePaths {
            let folderURL = URL(fileURLWithPath: candidatePath, isDirectory: true).standardizedFileURL
            guard isInsideRoot(folderURL: folderURL, rootURL: rootURL) else {
                continue
            }

            return AuthSaveDestination(
                folderURL: folderURL,
                authFileURL: folderURL.appendingPathComponent("auth.json"),
                kind: .customOverride
            )
        }

        return nil
    }

    private static func overridePaths(
        for liveStatus: LiveCodexStatus,
        overridesByTrackingKey: [String: String]
    ) -> [String] {
        var candidates: [String] = []

        if let exactMatch = overridesByTrackingKey[liveStatus.trackingKey] {
            candidates.append(exactMatch)
        }

        let matchingAccountPaths = overridesByTrackingKey.compactMap {
            AuthAccountMatcher.accountID(from: $0.key) == liveStatus.accountID
                ? $0.value
                : nil
        }

        for path in matchingAccountPaths where !candidates.contains(path) {
            candidates.append(path)
        }

        return candidates
    }
}
