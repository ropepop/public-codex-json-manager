import Foundation

public struct DuplicatePruneReport: Hashable, Sendable {
    public let removedPaths: [String]
    public let warnings: [String]

    public init(removedPaths: [String], warnings: [String]) {
        self.removedPaths = removedPaths
        self.warnings = warnings
    }
}

public struct ExactDuplicatePruner: Sendable {
    public init() {}

    public func prune(
        groups: [DuplicateGroup],
        preferredFolderURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> DuplicatePruneReport {
        let normalizedPreferredFolderURL = preferredFolderURL?.standardizedFileURL
        var removedPaths: [String] = []
        var warnings: [String] = []

        for group in groups where group.isDuplicateGroup {
            let recordsByFingerprint = Dictionary(grouping: group.records, by: \.authFingerprint)

            for records in recordsByFingerprint.values where records.count > 1 {
                let survivor = canonicalRecord(
                    from: records,
                    preferredFolderURL: normalizedPreferredFolderURL
                )

                for record in records where record.id != survivor.id {
                    guard fileManager.fileExists(atPath: record.folderURL.path) else {
                        continue
                    }

                    guard AuthFolderCleanupInspector.canSafelyDeleteDuplicateFolder(
                        folderURL: record.folderURL,
                        authFileURL: record.authFileURL,
                        fileManager: fileManager
                    ) else {
                        warnings.append("Skipped duplicate prune for \(record.relativeFolderPath) because the folder contains extra files.")
                        continue
                    }

                    do {
                        try fileManager.removeItem(at: record.folderURL)
                        removedPaths.append(record.relativeFolderPath)
                    } catch {
                        warnings.append("Skipped duplicate prune for \(record.relativeFolderPath): \(error.localizedDescription)")
                    }
                }
            }
        }

        return DuplicatePruneReport(removedPaths: removedPaths, warnings: warnings)
    }

    private func canonicalRecord(
        from records: [ScannedAuthRecord],
        preferredFolderURL: URL?
    ) -> ScannedAuthRecord {
        if let preferredFolderURL,
           let preferredRecord = records.first(where: { $0.folderURL.standardizedFileURL == preferredFolderURL }) {
            return preferredRecord
        }

        return SavedAuthRecordPreference.preferredPrimaryRecord(in: records) ?? records[0]
    }
}
