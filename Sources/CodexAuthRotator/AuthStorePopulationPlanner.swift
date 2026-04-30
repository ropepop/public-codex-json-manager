import CodexAuthRotatorCore
import Foundation

struct AuthStorePopulationReport: Hashable {
    let changedPaths: [String]

    var didChange: Bool {
        !changedPaths.isEmpty
    }
}

enum AuthStorePopulationPlanner {
    static func populateIfNeeded(
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        groups: [DuplicateGroup],
        overridesByTrackingKey: [String: String],
        swapper: AuthFileSwapper,
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) throws -> AuthStorePopulationReport {
        guard AuthAccountMatcher.preferredSavedGroup(for: liveStatus, in: groups) == nil else {
            return AuthStorePopulationReport(changedPaths: [])
        }

        var changedPaths: [String] = []
        let overrideFolderPaths = Set(
            overridesByTrackingKey.values.map {
                URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path
            }
        )

        let matchingGroups = AuthStoreDestinationPlanner.matchingVariantGroups(for: liveStatus, groups: groups)
        if matchingGroups.count == 1,
           let existingRecord = matchingGroups.first?.primaryRecord,
           shouldMigrateSingleRecord(
            existingRecord,
            rootURL: rootURL,
            liveStatus: liveStatus,
            overrideFolderPaths: overrideFolderPaths
           ) {
            let targetFolderURL = migratedFolderURL(
                for: existingRecord,
                rootURL: rootURL,
                liveStatus: liveStatus,
                now: now,
                calendar: calendar,
                fileManager: fileManager
            )
            if targetFolderURL.standardizedFileURL != existingRecord.folderURL.standardizedFileURL {
                try fileManager.createDirectory(at: targetFolderURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: existingRecord.folderURL, to: targetFolderURL)
                changedPaths.append("\(existingRecord.relativeFolderPath) -> \(targetFolderURL.path)")
            }
        }

        let refreshedGroups = try AuthScanner().scan(root: rootURL)
        guard AuthAccountMatcher.preferredSavedGroup(for: liveStatus, in: refreshedGroups) == nil else {
            return AuthStorePopulationReport(changedPaths: changedPaths)
        }

        let destination = AuthSaveDestinationResolver.resolve(
            rootURL: rootURL,
            liveStatus: liveStatus,
            groups: refreshedGroups,
            overridesByTrackingKey: overridesByTrackingKey
        )
        try swapper.saveCurrentAuth(to: destination.authFileURL)
        changedPaths.append(destination.authFileURL.path)

        return AuthStorePopulationReport(changedPaths: changedPaths)
    }

    private static func shouldMigrateSingleRecord(
        _ record: ScannedAuthRecord,
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        overrideFolderPaths: Set<String>
    ) -> Bool {
        if overrideFolderPaths.contains(record.folderURL.standardizedFileURL.path) {
            return false
        }

        let canonicalParentURL = AuthStoreDestinationPlanner.canonicalParentFolderURL(rootURL: rootURL, liveStatus: liveStatus)
        return record.folderURL.deletingLastPathComponent().standardizedFileURL != canonicalParentURL.standardizedFileURL
    }

    private static func migratedFolderURL(
        for record: ScannedAuthRecord,
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        now: Date,
        calendar: Calendar,
        fileManager: FileManager
    ) -> URL {
        let parentURL = AuthStoreDestinationPlanner.canonicalParentFolderURL(rootURL: rootURL, liveStatus: liveStatus)
        let baseLabel = uniqueNestedBaseLabel(
            preferredLabel: existingVariantBaseLabel(for: record),
            parentURL: parentURL,
            accountID: record.accountID,
            fileManager: fileManager
        )
        let folderName = AuthStoreDestinationPlanner.buildManagedFolderName(
            baseLabel: baseLabel,
            parsedFolderName: record.parsedFolderName,
            now: now,
            calendar: calendar
        )
        let uniqueFolderName = AuthStoreDestinationPlanner.uniqueFolderName(
            startingWith: folderName,
            in: parentURL,
            fileManager: fileManager
        )
        return parentURL.appendingPathComponent(uniqueFolderName, isDirectory: true)
    }

    private static func existingVariantBaseLabel(for record: ScannedAuthRecord) -> String {
        if let useLabel = normalizedNonEmpty(record.identity.useLabel) {
            return AuthStoreDestinationPlanner.sanitizedPathComponent(useLabel)
        }

        if let data = try? Data(contentsOf: record.authFileURL),
           let payload = try? JSONDecoder().decode(StoredAuthPayload.self, from: data),
           let resolvedIdentity = payload.resolvedIdentity() {
            return AuthStoreDestinationPlanner.variantBaseLabel(
                planType: resolvedIdentity.planType,
                workspaceName: nil
            )
        }

        let parsedBaseLabel = record.parsedFolderName.baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !parsedBaseLabel.isEmpty, !parsedBaseLabel.contains("@") {
            return AuthStoreDestinationPlanner.sanitizedPathComponent(parsedBaseLabel)
        }

        return "account"
    }

    private static func uniqueNestedBaseLabel(
        preferredLabel: String,
        parentURL: URL,
        accountID: String,
        fileManager: FileManager
    ) -> String {
        let normalizedPreferredLabel = preferredLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPreferredLabel.isEmpty else {
            return "account"
        }

        let existingSiblingBaseLabels = (try? fileManager.contentsOfDirectory(
            at: parentURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?
            .compactMap { url -> String? in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true else {
                    return nil
                }
                return FolderNameParser.parse(url.lastPathComponent).baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? []

        if !existingSiblingBaseLabels.contains(where: {
            $0.caseInsensitiveCompare(normalizedPreferredLabel) == .orderedSame
        }) {
            return normalizedPreferredLabel
        }

        return "\(normalizedPreferredLabel) \(AuthStoreDestinationPlanner.shortAccountID(from: accountID))"
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
