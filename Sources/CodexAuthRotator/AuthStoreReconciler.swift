import CodexAuthRotatorCore
import Foundation

struct AuthStoreReconciliationReport: Hashable {
    let changedPaths: [String]
    let warnings: [String]

    var didChange: Bool {
        !changedPaths.isEmpty
    }
}

enum AuthStoreReconciler {
    static func reconcile(
        rootURL: URL,
        groups: [DuplicateGroup],
        liveStatus: LiveCodexStatus?,
        preferredFolderPathsByTrackingKey: [String: String] = [:],
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) throws -> AuthStoreReconciliationReport {
        let preferredFolderURLsByTrackingKey = preferredFolderPathsByTrackingKey.reduce(into: [String: URL]()) { result, entry in
            result[entry.key] = URL(fileURLWithPath: entry.value, isDirectory: true).standardizedFileURL
        }

        var changedPaths: [String] = []
        var warnings: [String] = []

        for group in groups where !group.records.isEmpty {
            let preferredFolderURL = preferredFolderURLsByTrackingKey[group.trackingKey]
            guard let survivor = SavedAuthRecordPreference.preferredPrimaryRecord(
                in: group.records,
                preferredFolderURL: preferredFolderURL
            ) else {
                continue
            }

            let matchingLiveStatus = liveStatus.flatMap { AuthAccountMatcher.sameAccount(group, as: $0) ? $0 : nil }
            let freshestRecord = SavedAuthRecordPreference.freshestRecord(in: group.records) ?? survivor
            let freshestData = try? Data(contentsOf: freshestRecord.authFileURL)

            for record in group.records where record.id != survivor.id {
                guard fileManager.fileExists(atPath: record.folderURL.path) else {
                    continue
                }

                if AuthFolderCleanupInspector.canSafelyDeleteDuplicateFolder(
                    folderURL: record.folderURL,
                    authFileURL: record.authFileURL,
                    fileManager: fileManager
                ) {
                    do {
                        try fileManager.removeItem(at: record.folderURL)
                        changedPaths.append("\(record.relativeFolderPath) removed")
                    } catch {
                        warnings.append("Skipped duplicate cleanup for \(record.relativeFolderPath): \(error.localizedDescription)")
                    }
                    continue
                }

                let reviewURL = reviewFolderURL(
                    rootURL: rootURL,
                    relativeFolderPath: record.relativeFolderPath,
                    now: now,
                    fileManager: fileManager
                )

                do {
                    try fileManager.createDirectory(at: reviewURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: record.folderURL, to: reviewURL)
                    changedPaths.append("\(record.relativeFolderPath) -> \(relativePath(from: rootURL, to: reviewURL))")
                } catch {
                    warnings.append("Skipped review move for \(record.relativeFolderPath): \(error.localizedDescription)")
                }
            }

            guard fileManager.fileExists(atPath: survivor.folderURL.path) else {
                continue
            }

            var finalSurvivorFolderURL = survivor.folderURL.standardizedFileURL
            if let desiredTargetURL = desiredSurvivorFolderURL(
                for: survivor,
                rootURL: rootURL,
                liveStatus: matchingLiveStatus,
                preferredFolderURL: preferredFolderURL,
                now: now,
                calendar: calendar,
                fileManager: fileManager
            ), desiredTargetURL.standardizedFileURL != finalSurvivorFolderURL {
                let resolvedTargetURL = availableTargetURL(
                    startingWith: desiredTargetURL,
                    parentURL: desiredTargetURL.deletingLastPathComponent(),
                    fileManager: fileManager
                )

                do {
                    try fileManager.createDirectory(at: resolvedTargetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.moveItem(at: finalSurvivorFolderURL, to: resolvedTargetURL)
                    changedPaths.append("\(survivor.relativeFolderPath) -> \(relativePath(from: rootURL, to: resolvedTargetURL))")
                    finalSurvivorFolderURL = resolvedTargetURL.standardizedFileURL
                } catch {
                    warnings.append("Skipped repair move for \(survivor.relativeFolderPath): \(error.localizedDescription)")
                }
            }

            guard let freshestData else {
                continue
            }

            let destinationAuthURL = finalSurvivorFolderURL.appendingPathComponent("auth.json")
            let existingData = try? Data(contentsOf: destinationAuthURL)
            guard existingData != freshestData else {
                continue
            }

            do {
                try freshestData.write(to: destinationAuthURL, options: .atomic)
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationAuthURL.path)
                changedPaths.append("\(relativePath(from: rootURL, to: finalSurvivorFolderURL))/auth.json refreshed")
            } catch {
                warnings.append("Skipped auth refresh for \(relativePath(from: rootURL, to: finalSurvivorFolderURL)): \(error.localizedDescription)")
            }
        }

        return AuthStoreReconciliationReport(changedPaths: changedPaths, warnings: warnings)
    }

    private static func desiredSurvivorFolderURL(
        for record: ScannedAuthRecord,
        rootURL: URL,
        liveStatus: LiveCodexStatus?,
        preferredFolderURL: URL?,
        now: Date,
        calendar: Calendar,
        fileManager: FileManager
    ) -> URL? {
        if let preferredFolderURL {
            if record.folderURL.standardizedFileURL == preferredFolderURL {
                return preferredFolderURL
            }
            return nil
        }

        guard !SavedAuthRecordPreference.pathMatchesExpectedTopLevel(record) else {
            return nil
        }

        let topLevelFolderName = SavedAuthRecordPreference.expectedTopLevelFolderName(
            identityName: record.identity.name,
            accountID: record.accountID
        )
        let parentURL = rootURL.appendingPathComponent(topLevelFolderName, isDirectory: true)
        let baseLabel = ManagedFolderBaseLabelResolver.preferredBaseLabel(
            for: record,
            liveStatus: liveStatus
        ) ?? ManagedFolderBaseLabelResolver.fallbackBaseLabel(for: record)
        let desiredFolderName = AuthStoreDestinationPlanner.buildManagedFolderName(
            baseLabel: baseLabel,
            parsedFolderName: record.parsedFolderName,
            now: now,
            calendar: calendar
        )
        let resolvedFolderName = desiredFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? ManagedFolderBaseLabelResolver.fallbackBaseLabel(for: record)
            : desiredFolderName

        return parentURL.appendingPathComponent(resolvedFolderName, isDirectory: true)
    }

    private static func reviewFolderURL(
        rootURL: URL,
        relativeFolderPath: String,
        now: Date,
        fileManager: FileManager
    ) -> URL {
        let reviewRootURL = rootURL
            .appendingPathComponent("trash", isDirectory: true)
            .appendingPathComponent("review", isDirectory: true)
        let timestamp = timestampToken(now)
        let sanitizedRelativePath = AuthStoreDestinationPlanner.sanitizedPathComponent(relativeFolderPath)
        let preferredName = "\(timestamp)--\(sanitizedRelativePath)"
        let folderName = AuthStoreDestinationPlanner.uniqueFolderName(
            startingWith: preferredName,
            in: reviewRootURL,
            fileManager: fileManager
        )
        return reviewRootURL.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func availableTargetURL(
        startingWith targetURL: URL,
        parentURL: URL,
        fileManager: FileManager
    ) -> URL {
        guard fileManager.fileExists(atPath: targetURL.path) else {
            return targetURL
        }

        let uniqueName = AuthStoreDestinationPlanner.uniqueFolderName(
            startingWith: targetURL.lastPathComponent,
            in: parentURL,
            fileManager: fileManager
        )
        return parentURL.appendingPathComponent(uniqueName, isDirectory: true)
    }

    private static func relativePath(from rootURL: URL, to folderURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path

        guard folderPath.hasPrefix(rootPath) else {
            return folderURL.lastPathComponent
        }

        return String(folderPath.dropFirst(rootPath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func timestampToken(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
