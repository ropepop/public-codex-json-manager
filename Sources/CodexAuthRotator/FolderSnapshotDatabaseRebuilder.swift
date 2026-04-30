import CodexAuthRotatorCore
import Foundation

enum FolderSnapshotDatabaseRebuilder {
    static func rebuild(
        rootURL: URL,
        scanner: AuthScanner = AuthScanner(),
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [String: QuotaSnapshot] {
        let groups = try scanner.scan(root: rootURL)
        return rebuild(groups: groups, now: now, calendar: calendar)
    }

    static func rebuild(
        groups: [DuplicateGroup],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [String: QuotaSnapshot] {
        var snapshots: [String: QuotaSnapshot] = [:]

        for group in groups {
            guard let snapshot = snapshot(for: group, now: now, calendar: calendar) else {
                continue
            }
            snapshots[group.trackingKey] = snapshot
        }

        return snapshots
    }

    private static func snapshot(
        for group: DuplicateGroup,
        now: Date,
        calendar: Calendar
    ) -> QuotaSnapshot? {
        let parsedFolderName = group.primaryRecord.parsedFolderName
        guard parsedFolderName.shortWindowUsage != nil || parsedFolderName.weeklyUsage != nil else {
            return nil
        }

        let shortResetAt = parsedFolderName.shortWindowResetToken.flatMap {
            parseManagedResetToken($0, now: now, calendar: calendar, interpretation: .shortWindow)
        }
        let weeklyResetAt = parsedFolderName.weeklyResetToken.flatMap {
            parseManagedResetToken($0, now: now, calendar: calendar)
        }

        let shortWindowUsage = normalizedUsage(
            rawUsage: parsedFolderName.shortWindowUsage,
            resetAt: shortResetAt,
            now: now
        )
        let weeklyUsage = normalizedUsage(
            rawUsage: parsedFolderName.weeklyUsage,
            resetAt: weeklyResetAt,
            now: now
        )
        let isBlocked = QuotaAvailabilityPolicy.blocksShortWindow(usedPercent: shortWindowUsage)
            || QuotaAvailabilityPolicy.blocksWeeklyWindow(usedPercent: weeklyUsage)

        return QuotaSnapshot(
            capturedAt: now,
            allowed: !isBlocked,
            limitReached: isBlocked,
            primaryUsedPercent: shortWindowUsage,
            primaryResetAt: shortResetAt,
            primaryWindowMinutes: shortWindowUsage == nil ? nil : 300,
            secondaryUsedPercent: weeklyUsage,
            secondaryResetAt: weeklyResetAt,
            secondaryWindowMinutes: weeklyUsage == nil ? nil : 10_080
        )
    }

    private static func parseManagedResetToken(
        _ token: String,
        now: Date,
        calendar: Calendar,
        interpretation: FolderNameParser.ResetTokenInterpretation = .dateOrTime
    ) -> Date? {
        FolderNameParser.interpretedResetDate(
            from: token,
            now: now,
            calendar: calendar,
            interpretation: interpretation
        )
    }

    private static func normalizedUsage(
        rawUsage: Int?,
        resetAt: Date?,
        now: Date
    ) -> Int? {
        guard let rawUsage else {
            return nil
        }

        let isStale = resetAt.map { $0 <= now } ?? false
        return isStale ? 0 : max(0, min(100, rawUsage))
    }
}
