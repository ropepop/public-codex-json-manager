import CodexAuthRotatorCore
import Foundation

enum AuthStoreDestinationPlanner {
    static func preferredFolderURL(
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        groups: [DuplicateGroup] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> URL {
        let folderName = buildManagedFolderName(
            baseLabel: layoutBaseLabel(
                rootURL: rootURL,
                liveStatus: liveStatus,
                groups: groups,
                fileManager: fileManager
            ),
            liveStatus: liveStatus,
            now: now,
            calendar: calendar
        )

        if usesNestedLayout(
            rootURL: rootURL,
            liveStatus: liveStatus,
            groups: groups,
            fileManager: fileManager
        ) {
            return canonicalParentFolderURL(rootURL: rootURL, liveStatus: liveStatus)
                .appendingPathComponent(folderName, isDirectory: true)
        }

        return rootURL.appendingPathComponent(folderName, isDirectory: true)
    }

    static func newFolderAuthURL(
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        groups: [DuplicateGroup] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
        fileManager: FileManager = .default
    ) -> URL {
        let preferredFolderURL = preferredFolderURL(
            rootURL: rootURL,
            liveStatus: liveStatus,
            groups: groups,
            now: now,
            calendar: calendar,
            fileManager: fileManager
        )
        let folderName = uniqueFolderName(
            startingWith: preferredFolderURL.lastPathComponent,
            in: preferredFolderURL.deletingLastPathComponent(),
            fileManager: fileManager
        )
        return preferredFolderURL
            .deletingLastPathComponent()
            .appendingPathComponent(folderName, isDirectory: true)
            .appendingPathComponent("auth.json")
    }

    static func supportsPlaceholder(
        folderURL: URL,
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        groups: [DuplicateGroup] = []
    ) -> Bool {
        let standardizedFolderURL = folderURL.standardizedFileURL
        let expectedParentURL = usesNestedLayout(
            rootURL: rootURL,
            liveStatus: liveStatus,
            groups: groups,
            fileManager: .default
        )
            ? canonicalParentFolderURL(rootURL: rootURL, liveStatus: liveStatus).standardizedFileURL
            : rootURL.standardizedFileURL
        let candidateParentURL = standardizedFolderURL.deletingLastPathComponent().standardizedFileURL

        let candidateBaseLabel = FolderNameParser.baseLabelRemovingTrailingAccountType(
            FolderNameParser.parse(standardizedFolderURL.lastPathComponent).baseLabel
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let expectedBaseLabel = FolderNameParser.baseLabelRemovingTrailingAccountType(
            layoutBaseLabel(
                rootURL: rootURL,
                liveStatus: liveStatus,
                groups: groups,
                fileManager: .default
            )
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if candidateParentURL == expectedParentURL,
           candidateBaseLabel == expectedBaseLabel {
            return true
        }

        guard let legacyParentURL = legacyPlaceholderParentURL(
            rootURL: rootURL,
            liveStatus: liveStatus
        )?.standardizedFileURL else {
            return false
        }

        let legacyBaseLabel = canonicalEmailFolderName(for: liveStatus)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return candidateParentURL == legacyParentURL
            && candidateBaseLabel == legacyBaseLabel
    }

    static func canonicalParentFolderURL(rootURL: URL, liveStatus: LiveCodexStatus) -> URL {
        rootURL.appendingPathComponent(canonicalEmailFolderName(for: liveStatus), isDirectory: true)
    }

    static func canonicalEmailFolderName(for liveStatus: LiveCodexStatus) -> String {
        sanitizedPathComponent(
            liveStatus.email ?? "account-\(shortAccountID(from: liveStatus.accountID))"
        )
    }

    static func variantBaseLabel(for liveStatus: LiveCodexStatus) -> String {
        variantBaseLabel(planType: liveStatus.planType, workspaceName: liveStatus.workspaceName)
    }

    static func variantBaseLabel(planType: String?, workspaceName: String?) -> String {
        switch normalizedPlanType(planType) {
        case "free":
            return "free"
        case "plus", "pro", "personal":
            return "personal"
        case "team", "workplace":
            return sanitizedPathComponent(workspaceName ?? "team")
        default:
            return sanitizedPathComponent(workspaceName ?? "account")
        }
    }

    static func layoutBaseLabel(
        rootURL: URL,
        liveStatus: LiveCodexStatus,
        groups: [DuplicateGroup],
        fileManager: FileManager = .default
    ) -> String {
        usesNestedLayout(
            rootURL: rootURL,
            liveStatus: liveStatus,
            groups: groups,
            fileManager: fileManager
        )
            ? variantBaseLabel(for: liveStatus)
            : canonicalEmailFolderName(for: liveStatus)
    }

    static func usesNestedLayout(
        rootURL: URL? = nil,
        liveStatus: LiveCodexStatus,
        groups: [DuplicateGroup],
        fileManager: FileManager = .default
    ) -> Bool {
        if !matchingVariantGroups(for: liveStatus, groups: groups).isEmpty {
            return true
        }

        guard let rootURL else {
            return false
        }

        var isDirectory = ObjCBool(false)
        let canonicalParentURL = canonicalParentFolderURL(rootURL: rootURL, liveStatus: liveStatus)
        return fileManager.fileExists(atPath: canonicalParentURL.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    static func matchingVariantGroups(
        for liveStatus: LiveCodexStatus,
        groups: [DuplicateGroup]
    ) -> [DuplicateGroup] {
        let liveEmail = normalizedEmail(liveStatus.email)

        return groups.filter { group in
            if group.accountID == liveStatus.accountID {
                return true
            }

            if let liveEmail,
               normalizedEmail(group.primaryRecord.identity.name) == liveEmail {
                return true
            }

            if group.trackingKey == liveStatus.trackingKey {
                return true
            }

            return false
        }
    }

    static func buildManagedFolderName(
        baseLabel: String,
        liveStatus: LiveCodexStatus,
        now: Date,
        calendar: Calendar
    ) -> String {
        let status = StatusResolver.resolveCurrentLiveStatus(
            liveStatus: liveStatus,
            fallbackRecord: nil,
            now: now,
            calendar: calendar
        )
        return FolderNameParser.buildFolderName(
            baseLabel: baseLabel,
            accountType: liveStatus.planType,
            shortWindowUsage: status?.shortWindowUsagePercent,
            shortWindowResetAt: status?.shortWindowResetAt,
            weeklyUsage: status?.weeklyUsagePercent,
            weeklyResetAt: status?.weeklyResetAt,
            now: now,
            calendar: calendar
        )
    }

    static func buildManagedFolderName(
        baseLabel: String,
        accountType: String? = nil,
        parsedFolderName: ParsedFolderName,
        now: Date,
        calendar: Calendar
    ) -> String {
        let shortResetAt = parsedFolderName.shortWindowResetToken.flatMap {
            FolderNameParser.interpretedResetDate(
                from: $0,
                now: now,
                calendar: calendar,
                interpretation: .shortWindow
            )
        }
        let weeklyResetAt = parsedFolderName.weeklyResetToken.flatMap {
            FolderNameParser.interpretedResetDate(from: $0, now: now, calendar: calendar)
        }

        return FolderNameParser.buildFolderName(
            baseLabel: baseLabel,
            accountType: accountType ?? parsedFolderName.accountType,
            shortWindowUsage: parsedFolderName.shortWindowUsage,
            shortWindowResetAt: shortResetAt,
            weeklyUsage: parsedFolderName.weeklyUsage,
            weeklyResetAt: weeklyResetAt,
            now: now,
            calendar: calendar
        )
    }

    static func uniqueFolderName(
        startingWith preferredName: String,
        in parentURL: URL,
        fileManager: FileManager
    ) -> String {
        let baseName = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fileManager.fileExists(atPath: parentURL.appendingPathComponent(baseName).path) {
            return baseName
        }

        var suffix = 2
        while true {
            let candidate = "\(baseName) \(suffix)"
            if !fileManager.fileExists(atPath: parentURL.appendingPathComponent(candidate).path) {
                return candidate
            }
            suffix += 1
        }
    }

    static func normalizedPlanType(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func sanitizedPathComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "∕")
            .replacingOccurrences(of: ":", with: "-")
    }

    static func shortAccountID(from accountID: String) -> String {
        String(accountID.prefix(8))
    }

    private static func legacyPlaceholderParentURL(rootURL: URL, liveStatus: LiveCodexStatus) -> URL? {
        guard let folderName = legacyPlaceholderTopLevelFolderName(for: liveStatus) else {
            return nil
        }

        return rootURL.appendingPathComponent(folderName, isDirectory: true)
    }

    private static func legacyPlaceholderTopLevelFolderName(for liveStatus: LiveCodexStatus) -> String? {
        switch normalizedPlanType(liveStatus.planType) {
        case "free":
            return "free"
        case "plus", "pro", "personal":
            return "personal"
        case "team", "workplace":
            return "team"
        default:
            return nil
        }
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        guard let trimmed = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
