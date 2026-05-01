import Foundation

public struct FolderRenamer: Sendable {
    public init() {}

    public func syncManagedSuffixes(
        groups: [DuplicateGroup],
        statusesByTrackingKey: [String: AccountStatus],
        preferredBaseLabelsByRecordID: [String: String] = [:],
        preferredAccountTypesByRecordID: [String: String] = [:],
        now: Date,
        calendar: Calendar = .current,
        liveTrackingKey: String? = nil,
        liveTrackedFolderURL: URL? = nil
    ) throws -> RenameReport {
        var changedPaths: [String] = []
        var warnings: [String] = []
        let fileManager = FileManager.default
        let normalizedLiveTrackedFolderURL = liveTrackedFolderURL?.standardizedFileURL

        for group in groups {
            guard let status = statusesByTrackingKey[group.trackingKey],
                  status.source != .unknown else {
                continue
            }

            let isLiveGroup = group.trackingKey == liveTrackingKey
            if isLiveGroup, normalizedLiveTrackedFolderURL == nil {
                continue
            }

            for record in group.records {
                if isLiveGroup,
                   record.folderURL.standardizedFileURL != normalizedLiveTrackedFolderURL {
                    continue
                }

                guard fileManager.fileExists(atPath: record.authFileURL.path) else {
                    continue
                }

                let hasManagedFolderData = record.parsedFolderName.shortWindowUsage != nil
                    || record.parsedFolderName.weeklyUsage != nil
                let desiredAccountType = preferredAccountTypesByRecordID[record.id]
                    ?? record.parsedFolderName.accountType
                    ?? record.planType
                let hasManagedAccountType = record.parsedFolderName.accountType != nil
                    || FolderNameParser.normalizedAccountType(desiredAccountType) != nil
                guard hasManagedFolderData
                        || hasManagedAccountType
                        || status.shortWindowUsagePercent != nil
                        || status.weeklyUsagePercent != nil else {
                    continue
                }

                let desiredName = desiredFolderName(
                    for: record,
                    status: status,
                    preferredBaseLabel: preferredBaseLabelsByRecordID[record.id] ?? record.parsedFolderName.baseLabel,
                    accountType: desiredAccountType,
                    now: now,
                    calendar: calendar
                )

                guard !desiredName.isEmpty, desiredName != record.folderName else {
                    continue
                }

                let parentURL = record.folderURL.deletingLastPathComponent()
                let targetURL = parentURL.appendingPathComponent(desiredName, isDirectory: true)

                if targetURL == record.folderURL {
                    continue
                }

                if fileManager.fileExists(atPath: targetURL.path) {
                    warnings.append("Skipped rename for \(record.relativeFolderPath) because \(desiredName) already exists.")
                    continue
                }

                do {
                    try fileManager.moveItem(at: record.folderURL, to: targetURL)
                    changedPaths.append("\(record.relativeFolderPath) -> \(targetURL.lastPathComponent)")
                } catch {
                    warnings.append("Skipped rename for \(record.relativeFolderPath): \(error.localizedDescription)")
                }
            }
        }

        return RenameReport(changedPaths: changedPaths, warnings: warnings)
    }

    private func desiredFolderName(
        for record: ScannedAuthRecord,
        status: AccountStatus,
        preferredBaseLabel: String,
        accountType: String?,
        now: Date,
        calendar: Calendar
    ) -> String {
        let normalizedAccountType = FolderNameParser.normalizedAccountType(accountType)
        let baseLabel = if normalizedAccountType == nil {
            preferredBaseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            FolderNameParser.baseLabelRemovingTrailingAccountType(preferredBaseLabel)
        }
        var pieces = [baseLabel]
            .filter { !$0.isEmpty }
        if let normalizedAccountType {
            pieces.append(normalizedAccountType)
        }
        pieces.append(contentsOf: managedSuffixPieces(
            prefix: "5hr",
            source: status.source,
            state: status.shortWindowState,
            usagePercent: status.shortWindowUsagePercent,
            resetAt: status.shortWindowResetAt,
            fallbackUsagePercent: record.parsedFolderName.shortWindowUsage,
            fallbackResetToken: record.parsedFolderName.shortWindowResetToken,
            now: now,
            calendar: calendar
        ))
        pieces.append(contentsOf: managedSuffixPieces(
            prefix: "wk",
            source: status.source,
            state: status.weeklyWindowState,
            usagePercent: status.weeklyUsagePercent,
            resetAt: status.weeklyResetAt,
            fallbackUsagePercent: record.parsedFolderName.weeklyUsage,
            fallbackResetToken: record.parsedFolderName.weeklyResetToken,
            now: now,
            calendar: calendar
        ))
        return pieces.joined(separator: " ")
    }

    private func managedSuffixPieces(
        prefix: String,
        source: StatusSource,
        state: AccountWindowState,
        usagePercent: Int?,
        resetAt: Date?,
        fallbackUsagePercent: Int?,
        fallbackResetToken: String?,
        now: Date,
        calendar: Calendar
    ) -> [String] {
        if source == .folderName, state != .current {
            return existingManagedSuffixPieces(
                prefix: prefix,
                usagePercent: fallbackUsagePercent,
                resetToken: fallbackResetToken
            )
        }

        guard let usagePercent else {
            return []
        }

        var pieces = ["\(prefix)\(max(0, min(100, usagePercent)))"]
        if let resetAt {
            let resetToken = prefix == "5hr"
                ? FolderNameParser.formatShortWindowResetToken(resetAt, calendar: calendar)
                : FolderNameParser.formatReset(resetAt, now: now, calendar: calendar)
            pieces.append(resetToken)
        }
        return pieces
    }

    private func existingManagedSuffixPieces(
        prefix: String,
        usagePercent: Int?,
        resetToken: String?
    ) -> [String] {
        guard let usagePercent else {
            return []
        }

        var pieces = ["\(prefix)\(max(0, min(100, usagePercent)))"]
        if let resetToken, !resetToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            pieces.append(resetToken)
        }
        return pieces
    }
}
