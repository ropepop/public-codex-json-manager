import Foundation

public enum SavedAuthRecordPreference {
    private static let emailRegex = try! NSRegularExpression(
        pattern: #"^[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}$"#,
        options: [.caseInsensitive]
    )
    private static let genericTokens: Set<String> = [
        "account",
        "free",
        "personal",
        "team",
        "workplace",
    ]

    public static func preferredPrimaryRecord(
        in records: [ScannedAuthRecord],
        preferredFolderURL: URL? = nil
    ) -> ScannedAuthRecord? {
        let normalizedPreferredFolderURL = preferredFolderURL?.standardizedFileURL
        return records.sorted {
            compare($0, $1, preferredFolderURL: normalizedPreferredFolderURL)
        }.first
    }

    public static func freshestRecord(in records: [ScannedAuthRecord]) -> ScannedAuthRecord? {
        records.sorted(by: freshnessCompare).first
    }

    public static func compare(
        _ lhs: ScannedAuthRecord,
        _ rhs: ScannedAuthRecord,
        preferredFolderURL: URL? = nil
    ) -> Bool {
        if let preferredFolderURL {
            let lhsPreferred = lhs.folderURL.standardizedFileURL == preferredFolderURL
            let rhsPreferred = rhs.folderURL.standardizedFileURL == preferredFolderURL
            if lhsPreferred != rhsPreferred {
                return lhsPreferred
            }
        }

        let lhsMatchesExpectedPath = pathMatchesExpectedTopLevel(lhs)
        let rhsMatchesExpectedPath = pathMatchesExpectedTopLevel(rhs)
        if lhsMatchesExpectedPath != rhsMatchesExpectedPath {
            return lhsMatchesExpectedPath
        }

        if lhs.baseLabelDescriptionScore != rhs.baseLabelDescriptionScore {
            return lhs.baseLabelDescriptionScore > rhs.baseLabelDescriptionScore
        }

        if let freshnessDecision = compareOptionalDates(lhs.lastRefreshAt, rhs.lastRefreshAt) {
            return freshnessDecision
        }

        if lhs.authFileModifiedAt != rhs.authFileModifiedAt {
            return lhs.authFileModifiedAt > rhs.authFileModifiedAt
        }

        if lhs.relativeFolderPath.count != rhs.relativeFolderPath.count {
            return lhs.relativeFolderPath.count < rhs.relativeFolderPath.count
        }

        return lhs.relativeFolderPath.localizedCaseInsensitiveCompare(rhs.relativeFolderPath) == .orderedAscending
    }

    public static func pathMatchesExpectedTopLevel(_ record: ScannedAuthRecord) -> Bool {
        let normalizedTopLevelName = normalizedTopLevelName(record.topLevelFolderName)
        let expectedTopLevelName = expectedTopLevelFolderName(
            identityName: record.identity.name,
            accountID: record.accountID
        )
        return normalizedTopLevelName.caseInsensitiveCompare(expectedTopLevelName) == .orderedSame
    }

    public static func inferredEmail(fromFolderComponent value: String) -> String? {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return nil
        }

        let parsedBase = FolderNameParser.parse(trimmedValue).baseLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(parsedBase.startIndex..<parsedBase.endIndex, in: parsedBase)
        guard let match = emailRegex.firstMatch(in: parsedBase, options: [], range: range),
              let swiftRange = Range(match.range, in: parsedBase) else {
            return nil
        }

        return parsedBase[swiftRange]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    public static func expectedTopLevelFolderName(identityName: String, accountID: String) -> String {
        if let email = normalizedEmail(identityName) {
            return email
        }

        return "account-\(shortAccountID(from: accountID))"
    }

    public static func descriptiveLabelScore(
        for baseLabel: String,
        identityName: String,
        accountID: String
    ) -> Int {
        let trimmedBaseLabel = baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseLabel.isEmpty else {
            return 0
        }

        if let baseEmail = normalizedEmail(trimmedBaseLabel),
           baseEmail == normalizedEmail(identityName) {
            return 0
        }

        let shortAccountID = shortAccountID(from: accountID).lowercased()
        let meaningfulTokens = trimmedBaseLabel
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { token in
                guard !token.isEmpty else {
                    return false
                }
                if genericTokens.contains(token) {
                    return false
                }
                if token == shortAccountID {
                    return false
                }
                if normalizedEmail(token) != nil {
                    return false
                }
                return true
            }

        guard !meaningfulTokens.isEmpty else {
            return 0
        }

        return meaningfulTokens.count * 100 + meaningfulTokens.joined().count
    }

    private static func freshnessCompare(_ lhs: ScannedAuthRecord, _ rhs: ScannedAuthRecord) -> Bool {
        if let freshnessDecision = compareOptionalDates(lhs.lastRefreshAt, rhs.lastRefreshAt) {
            return freshnessDecision
        }

        if lhs.authFileModifiedAt != rhs.authFileModifiedAt {
            return lhs.authFileModifiedAt > rhs.authFileModifiedAt
        }

        return lhs.relativeFolderPath.localizedCaseInsensitiveCompare(rhs.relativeFolderPath) == .orderedAscending
    }

    private static func compareOptionalDates(_ lhs: Date?, _ rhs: Date?) -> Bool? {
        switch (lhs, rhs) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return nil
        }
    }

    private static func normalizedTopLevelName(_ value: String) -> String {
        if let email = inferredEmail(fromFolderComponent: value) {
            return email
        }

        return FolderNameParser.parse(value).baseLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func normalizedEmail(_ value: String?) -> String? {
        guard let trimmedValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !trimmedValue.isEmpty else {
            return nil
        }

        let range = NSRange(trimmedValue.startIndex..<trimmedValue.endIndex, in: trimmedValue)
        guard emailRegex.firstMatch(in: trimmedValue, options: [], range: range) != nil else {
            return nil
        }
        return trimmedValue
    }

    private static func shortAccountID(from accountID: String) -> String {
        String(accountID.prefix(8))
    }
}
