import CryptoKit
import Foundation

public struct AuthScanner: Sendable {
    public init() {}

    public func scan(root: URL) throws -> [DuplicateGroup] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: root.path) else {
            return []
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var records: [ScannedAuthRecord] = []

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent == "auth.json" else {
                continue
            }

            let data = try Data(contentsOf: fileURL)
            let payload = try JSONDecoder().decode(StoredAuthPayload.self, from: data)
            guard let resolvedIdentity = payload.resolvedIdentity() else {
                continue
            }

            let folderURL = fileURL.deletingLastPathComponent()
            let folderName = folderURL.lastPathComponent
            let relativeFolderPath = relativePath(from: root, to: folderURL)
            let relativeComponents = relativeFolderPath.split(separator: "/").map(String.init)
            let topLevel = relativeComponents.first ?? folderName
            let parsedFolder = FolderNameParser.parse(folderName)
            let folderAccountType = FolderNameParser.normalizedAccountType(parsedFolder.accountType)
            let folderIdentity = FolderNameParser.inferIdentity(
                topLevelFolderName: topLevel,
                baseLabel: parsedFolder.baseLabel
            )
            let identity = Self.displayIdentity(
                folderIdentity: folderIdentity,
                resolvedIdentity: resolvedIdentity
            )
            let fingerprint = Self.fingerprint(for: data)
            let id = "\(fingerprint)|\(relativeFolderPath)"
            let authFileModifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                ?? .distantPast
            let pathEmail = SavedAuthRecordPreference.inferredEmail(fromFolderComponent: topLevel)
            let baseLabelDescriptionScore = SavedAuthRecordPreference.descriptiveLabelScore(
                for: parsedFolder.baseLabel,
                identityName: identity.name,
                accountID: resolvedIdentity.accountID
            )

            records.append(
                ScannedAuthRecord(
                    id: id,
                    authFileURL: fileURL,
                    folderURL: folderURL,
                    relativeFolderPath: relativeFolderPath,
                    topLevelFolderName: topLevel,
                    folderName: folderName,
                    parsedFolderName: parsedFolder,
                    identity: identity,
                    trackingKey: resolvedIdentity.trackingKey,
                    accountID: resolvedIdentity.accountID,
                    authFingerprint: fingerprint,
                    planType: folderAccountType ?? resolvedIdentity.planType,
                    lastRefreshAt: Self.parseLastRefreshDate(from: payload.lastRefresh),
                    authFileModifiedAt: authFileModifiedAt,
                    pathEmail: pathEmail,
                    baseLabelDescriptionScore: baseLabelDescriptionScore
                )
            )
        }

        let grouped = Dictionary(grouping: records, by: \.trackingKey)
        return grouped
            .values
            .map { values in
                let primaryRecordID = SavedAuthRecordPreference.preferredPrimaryRecord(in: values)?.id
                return DuplicateGroup(
                    authFingerprint: values[0].authFingerprint,
                    trackingKey: values[0].trackingKey,
                    accountID: values[0].accountID,
                    records: values,
                    primaryRecordID: primaryRecordID
                )
            }
            .sorted { lhs, rhs in
                lhs.primaryRecord.relativeFolderPath.localizedCaseInsensitiveCompare(rhs.primaryRecord.relativeFolderPath) == .orderedAscending
            }
    }

    public static func fingerprint(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func displayIdentity(
        folderIdentity: DisplayIdentity,
        resolvedIdentity: ResolvedAuthIdentity
    ) -> DisplayIdentity {
        guard let resolvedEmail = resolvedIdentity.email else {
            return folderIdentity
        }

        return DisplayIdentity(
            name: resolvedEmail,
            useLabel: folderIdentity.useLabel
        )
    }

    private static func parseLastRefreshDate(from value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsedDate = formatter.date(from: value) {
            return parsedDate
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private func relativePath(from root: URL, to folder: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path

        guard folderPath.hasPrefix(rootPath) else {
            return folder.lastPathComponent
        }

        return String(folderPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
