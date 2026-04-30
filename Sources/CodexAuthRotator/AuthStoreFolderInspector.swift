import CodexAuthRotatorCore
import Foundation

enum AuthStoreEmptyFolderKind: Hashable, Sendable {
    case supportedPlaceholder
    case stagedShell
}

struct AuthStoreEmptyFolder: Comparable, Hashable, Sendable {
    let folderURL: URL
    let relativePath: String
    let topLevelFolderName: String
    let folderName: String
    let parsedFolderName: ParsedFolderName
    let kind: AuthStoreEmptyFolderKind

    static func < (lhs: AuthStoreEmptyFolder, rhs: AuthStoreEmptyFolder) -> Bool {
        lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
    }
}

struct AuthStoreUnbackedEmailFolder: Comparable, Hashable, Identifiable, Sendable {
    let folderURL: URL
    let relativePath: String
    let folderName: String
    let email: String
    let warning: String?

    var id: String {
        relativePath
    }

    static func < (lhs: AuthStoreUnbackedEmailFolder, rhs: AuthStoreUnbackedEmailFolder) -> Bool {
        lhs.relativePath.localizedCaseInsensitiveCompare(rhs.relativePath) == .orderedAscending
    }
}

enum AuthStoreFolderInspector {
    static func inspect(
        rootURL: URL,
        liveStatus: LiveCodexStatus?,
        groups: [DuplicateGroup] = []
    ) -> [AuthStoreEmptyFolder] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var directories: [URL] = []
        var authParentPaths = Set<String>()

        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                directories.append(url)
            } else if url.lastPathComponent == "auth.json" {
                authParentPaths.insert(url.deletingLastPathComponent().standardizedFileURL.path)
            }
        }

        let directoryPaths = Set(directories.map { $0.standardizedFileURL.path })

        return directories.compactMap { directory in
            let path = directory.standardizedFileURL.path
            guard !authParentPaths.contains(path) else {
                return nil
            }

            let hasNestedDirectory = directoryPaths.contains { candidate in
                candidate.hasPrefix(path + "/")
            }
            guard !hasNestedDirectory else {
                return nil
            }

            let relativePath = relativePath(from: rootURL, to: directory)
            guard !relativePath.localizedCaseInsensitiveContains("not authed") else {
                return nil
            }

            guard relativePath.contains("@") else {
                return nil
            }

            let topLevelFolderName = relativePath.split(separator: "/").map(String.init).first ?? directory.lastPathComponent
            let folderName = directory.lastPathComponent
            let kind: AuthStoreEmptyFolderKind
            if let liveStatus,
               AuthStoreDestinationPlanner.supportsPlaceholder(
                   folderURL: directory,
                   rootURL: rootURL,
                   liveStatus: liveStatus,
                   groups: groups
               ) {
                kind = .supportedPlaceholder
            } else {
                kind = .stagedShell
            }

            return AuthStoreEmptyFolder(
                folderURL: directory,
                relativePath: relativePath,
                topLevelFolderName: topLevelFolderName,
                folderName: folderName,
                parsedFolderName: FolderNameParser.parse(folderName),
                kind: kind
            )
        }
        .sorted()
    }

    static func matchingPlaceholder(in emptyFolders: [AuthStoreEmptyFolder]) -> AuthStoreEmptyFolder? {
        emptyFolders.first(where: { $0.kind == .supportedPlaceholder })
    }

    static func unbackedEmailFolders(
        rootURL: URL,
        groups: [DuplicateGroup],
        emptyFolders: [AuthStoreEmptyFolder] = []
    ) -> [AuthStoreUnbackedEmailFolder] {
        let fileManager = FileManager.default
        guard let topLevelURLs = try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return topLevelURLs.compactMap { folderURL in
            let values = try? folderURL.resourceValues(forKeys: [.isDirectoryKey])
            guard values?.isDirectory == true,
                  let email = SavedAuthRecordPreference.inferredEmail(fromFolderComponent: folderURL.lastPathComponent),
                  !containsSavedAccount(in: folderURL, groups: groups) else {
                return nil
            }

            let relativePath = relativePath(from: rootURL, to: folderURL)
            return AuthStoreUnbackedEmailFolder(
                folderURL: folderURL,
                relativePath: relativePath,
                folderName: folderURL.lastPathComponent,
                email: email,
                warning: stagedShellWarning(forTopLevelRelativePath: relativePath, emptyFolders: emptyFolders)
            )
        }
        .sorted()
    }

    private static func stagedShellWarning(
        forTopLevelRelativePath relativePath: String,
        emptyFolders: [AuthStoreEmptyFolder]
    ) -> String? {
        let hasStagedShell = emptyFolders.contains { emptyFolder in
            emptyFolder.kind == .stagedShell
                && (emptyFolder.relativePath == relativePath || emptyFolder.relativePath.hasPrefix(relativePath + "/"))
        }
        return hasStagedShell ? "Staged store folder has no auth.json yet" : nil
    }

    private static func containsSavedAccount(in folderURL: URL, groups: [DuplicateGroup]) -> Bool {
        let folderPath = folderURL.standardizedFileURL.path
        return groups.flatMap(\.records).contains { record in
            let recordFolderPath = record.folderURL.standardizedFileURL.path
            return recordFolderPath == folderPath || recordFolderPath.hasPrefix(folderPath + "/")
        }
    }

    private static func relativePath(from rootURL: URL, to folderURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path

        guard folderPath.hasPrefix(rootPath) else {
            return folderURL.lastPathComponent
        }

        return String(folderPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum AuthStoreWarningBuilder {
    static func warnings(
        groups: [DuplicateGroup],
        liveStatus: LiveCodexStatus?,
        emptyFolders: [AuthStoreEmptyFolder],
        liveSaveDestination: AuthSaveDestination?
    ) -> [String] {
        var warnings: [String] = []

        if let liveStatus,
           !groups.contains(where: { AuthAccountMatcher.sameAccount($0, as: liveStatus) }),
           AuthStoreFolderInspector.matchingPlaceholder(in: emptyFolders) == nil,
           liveSaveDestination?.kind != .customOverride {
            if let liveEmail = liveStatus.email {
                warnings.append("Current live account \(liveEmail) is not present in the auth store.")
            } else {
                warnings.append("Current live auth is not present in the auth store.")
            }
        }

        return warnings
    }
}
