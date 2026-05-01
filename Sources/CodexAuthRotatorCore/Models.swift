import Foundation

public struct AuthTokens: Codable, Hashable, Sendable {
    public let accountID: String?
    public let accessToken: String?
    public let idToken: String?
    public let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case accessToken = "access_token"
        case idToken = "id_token"
        case refreshToken = "refresh_token"
    }

    public init(accountID: String?, accessToken: String? = nil, idToken: String? = nil, refreshToken: String? = nil) {
        self.accountID = accountID
        self.accessToken = accessToken
        self.idToken = idToken
        self.refreshToken = refreshToken
    }
}

public struct StoredAuthPayload: Codable, Hashable, Sendable {
    public let authMode: String?
    public let lastRefresh: String?
    public let tokens: AuthTokens?
    public let openAIAPIKey: String?

    enum CodingKeys: String, CodingKey {
        case authMode = "auth_mode"
        case lastRefresh = "last_refresh"
        case tokens
        case openAIAPIKey = "OPENAI_API_KEY"
    }

    public init(authMode: String?, lastRefresh: String?, tokens: AuthTokens?, openAIAPIKey: String?) {
        self.authMode = authMode
        self.lastRefresh = lastRefresh
        self.tokens = tokens
        self.openAIAPIKey = openAIAPIKey
    }
}

public struct ParsedFolderName: Hashable, Sendable {
    public let original: String
    public let baseLabel: String
    public let accountType: String?
    public let shortWindowUsage: Int?
    public let shortWindowResetToken: String?
    public let weeklyUsage: Int?
    public let weeklyResetToken: String?

    public init(
        original: String,
        baseLabel: String,
        accountType: String? = nil,
        shortWindowUsage: Int?,
        shortWindowResetToken: String?,
        weeklyUsage: Int?,
        weeklyResetToken: String?
    ) {
        self.original = original
        self.baseLabel = baseLabel
        self.accountType = accountType
        self.shortWindowUsage = shortWindowUsage
        self.shortWindowResetToken = shortWindowResetToken
        self.weeklyUsage = weeklyUsage
        self.weeklyResetToken = weeklyResetToken
    }

    public var resetToken: String? {
        weeklyResetToken
    }
}

public struct DisplayIdentity: Hashable, Sendable {
    public let name: String
    public let useLabel: String?

    public init(name: String, useLabel: String?) {
        self.name = name
        self.useLabel = useLabel
    }
}

public struct ScannedAuthRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let authFileURL: URL
    public let folderURL: URL
    public let relativeFolderPath: String
    public let topLevelFolderName: String
    public let folderName: String
    public let parsedFolderName: ParsedFolderName
    public let identity: DisplayIdentity
    public let trackingKey: String
    public let accountID: String
    public let authFingerprint: String
    public let planType: String?
    public let lastRefreshAt: Date?
    public let authFileModifiedAt: Date
    public let pathEmail: String?
    public let baseLabelDescriptionScore: Int

    public init(
        id: String,
        authFileURL: URL,
        folderURL: URL,
        relativeFolderPath: String,
        topLevelFolderName: String,
        folderName: String,
        parsedFolderName: ParsedFolderName,
        identity: DisplayIdentity,
        trackingKey: String,
        accountID: String,
        authFingerprint: String,
        planType: String? = nil,
        lastRefreshAt: Date? = nil,
        authFileModifiedAt: Date = .distantPast,
        pathEmail: String? = nil,
        baseLabelDescriptionScore: Int = 0
    ) {
        self.id = id
        self.authFileURL = authFileURL
        self.folderURL = folderURL
        self.relativeFolderPath = relativeFolderPath
        self.topLevelFolderName = topLevelFolderName
        self.folderName = folderName
        self.parsedFolderName = parsedFolderName
        self.identity = identity
        self.trackingKey = trackingKey
        self.accountID = accountID
        self.authFingerprint = authFingerprint
        self.planType = planType
        self.lastRefreshAt = lastRefreshAt
        self.authFileModifiedAt = authFileModifiedAt
        self.pathEmail = pathEmail
        self.baseLabelDescriptionScore = baseLabelDescriptionScore
    }
}

public struct DuplicateGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let authFingerprint: String
    public let trackingKey: String
    public let accountID: String
    public let records: [ScannedAuthRecord]

    public init(
        authFingerprint: String,
        trackingKey: String,
        accountID: String,
        records: [ScannedAuthRecord],
        primaryRecordID: String? = nil
    ) {
        self.id = trackingKey
        self.trackingKey = trackingKey
        self.accountID = accountID
        self.records = records.sorted { lhs, rhs in
            if lhs.id == primaryRecordID {
                return true
            }
            if rhs.id == primaryRecordID {
                return false
            }
            return lhs.relativeFolderPath.localizedCaseInsensitiveCompare(rhs.relativeFolderPath) == .orderedAscending
        }
        self.authFingerprint = self.records.first?.authFingerprint ?? authFingerprint
    }

    public var primaryRecord: ScannedAuthRecord {
        records[0]
    }

    public var isDuplicateGroup: Bool {
        records.count > 1
    }
}

public struct RateLimitWindow: Codable, Hashable, Sendable {
    public let usedPercent: Int?
    public let windowMinutes: Int?
    public let resetAfterSeconds: Int?
    public let resetAt: Int?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAfterSeconds = "reset_after_seconds"
        case resetAt = "reset_at"
    }

    public init(usedPercent: Int?, windowMinutes: Int?, resetAfterSeconds: Int?, resetAt: Int?) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetAfterSeconds = resetAfterSeconds
        self.resetAt = resetAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.usedPercent = try container.decodeIfPresent(Int.self, forKey: .usedPercent)
        if let explicitMinutes = try container.decodeIfPresent(Int.self, forKey: .windowMinutes) {
            self.windowMinutes = explicitMinutes
        } else if let limitWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .limitWindowSeconds) {
            self.windowMinutes = limitWindowSeconds / 60
        } else {
            self.windowMinutes = nil
        }
        self.resetAfterSeconds = try container.decodeIfPresent(Int.self, forKey: .resetAfterSeconds)
        self.resetAt = try container.decodeIfPresent(Int.self, forKey: .resetAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try container.encodeIfPresent(windowMinutes, forKey: .windowMinutes)
        try container.encodeIfPresent(resetAfterSeconds, forKey: .resetAfterSeconds)
        try container.encodeIfPresent(resetAt, forKey: .resetAt)
    }
}

public struct RateLimitsPayload: Codable, Hashable, Sendable {
    public let allowed: Bool
    public let limitReached: Bool
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?

    enum CodingKeys: String, CodingKey {
        case allowed
        case limitReached = "limit_reached"
        case primary
        case secondary
    }

    public init(allowed: Bool, limitReached: Bool, primary: RateLimitWindow?, secondary: RateLimitWindow?) {
        self.allowed = allowed
        self.limitReached = limitReached
        self.primary = primary
        self.secondary = secondary
    }
}

public struct CodexRateLimitEvent: Codable, Hashable, Sendable {
    public let type: String
    public let planType: String?
    public let rateLimits: RateLimitsPayload?

    enum CodingKeys: String, CodingKey {
        case type
        case planType = "plan_type"
        case rateLimits = "rate_limits"
    }

    public init(type: String, planType: String?, rateLimits: RateLimitsPayload?) {
        self.type = type
        self.planType = planType
        self.rateLimits = rateLimits
    }
}

public struct QuotaSnapshot: Codable, Hashable, Sendable {
    public let capturedAt: Date
    public let allowed: Bool
    public let limitReached: Bool
    public let primaryUsedPercent: Int?
    public let primaryResetAt: Date?
    public let primaryWindowMinutes: Int?
    public let secondaryUsedPercent: Int?
    public let secondaryResetAt: Date?
    public let secondaryWindowMinutes: Int?

    public init(
        capturedAt: Date,
        allowed: Bool,
        limitReached: Bool,
        primaryUsedPercent: Int?,
        primaryResetAt: Date?,
        primaryWindowMinutes: Int?,
        secondaryUsedPercent: Int?,
        secondaryResetAt: Date?,
        secondaryWindowMinutes: Int?
    ) {
        self.capturedAt = capturedAt
        self.allowed = allowed
        self.limitReached = limitReached
        self.primaryUsedPercent = primaryUsedPercent
        self.primaryResetAt = primaryResetAt
        self.primaryWindowMinutes = primaryWindowMinutes
        self.secondaryUsedPercent = secondaryUsedPercent
        self.secondaryResetAt = secondaryResetAt
        self.secondaryWindowMinutes = secondaryWindowMinutes
    }

    public init?(event: CodexRateLimitEvent, capturedAt: Date) {
        guard let limits = event.rateLimits else {
            return nil
        }
        let normalized = Self.normalizedRateLimitWindows(
            primary: limits.primary,
            secondary: limits.secondary
        )
        self.init(
            capturedAt: capturedAt,
            allowed: limits.allowed,
            limitReached: limits.limitReached,
            primaryUsedPercent: normalized.shortWindow?.usedPercent,
            primaryResetAt: normalized.shortWindow?.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            primaryWindowMinutes: normalized.shortWindow?.windowMinutes,
            secondaryUsedPercent: normalized.weeklyWindow?.usedPercent,
            secondaryResetAt: normalized.weeklyWindow?.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            secondaryWindowMinutes: normalized.weeklyWindow?.windowMinutes
        )
    }

    private static func normalizedRateLimitWindows(
        primary: RateLimitWindow?,
        secondary: RateLimitWindow?
    ) -> NormalizedRateLimitWindows {
        let ranked = [primary, secondary]
            .enumerated()
            .compactMap { index, window in
                window.map { RankedRateLimitWindow(rawIndex: index, window: $0) }
            }

        switch ranked.count {
        case 0:
            return NormalizedRateLimitWindows(shortWindow: nil, weeklyWindow: nil)
        case 1:
            let only = ranked[0]
            guard let windowMinutes = only.window.windowMinutes else {
                return only.rawIndex == 0
                    ? NormalizedRateLimitWindows(shortWindow: only.window, weeklyWindow: nil)
                    : NormalizedRateLimitWindows(shortWindow: nil, weeklyWindow: only.window)
            }

            if windowMinutes >= 1_440 {
                return NormalizedRateLimitWindows(shortWindow: nil, weeklyWindow: only.window)
            }
            return NormalizedRateLimitWindows(shortWindow: only.window, weeklyWindow: nil)
        default:
            let ordered = ranked.sorted { lhs, rhs in
                switch (lhs.window.windowMinutes, rhs.window.windowMinutes) {
                case let (left?, right?) where left != right:
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return lhs.rawIndex < rhs.rawIndex
                }
            }

            return NormalizedRateLimitWindows(
                shortWindow: ordered.first?.window,
                weeklyWindow: ordered.dropFirst().first?.window
            )
        }
    }
}

private struct RankedRateLimitWindow {
    let rawIndex: Int
    let window: RateLimitWindow
}

private struct NormalizedRateLimitWindows {
    let shortWindow: RateLimitWindow?
    let weeklyWindow: RateLimitWindow?
}

public enum StatusSource: String, Codable, Hashable, Sendable {
    case oauth
    case cliRPC = "cli-rpc"
    case cliPTY = "cli-pty"
    case folderName
    case unknown

    public var isLiveQuotaSource: Bool {
        switch self {
        case .oauth, .cliRPC, .cliPTY:
            return true
        case .folderName, .unknown:
            return false
        }
    }
}

public extension StatusSource {
    static var cached: StatusSource { .folderName }
}

public enum AccountWindowState: String, Codable, Hashable, Sendable {
    case current
    case needsRefresh
    case unreadable
}

public struct AccountStatus: Hashable, Sendable {
    public let source: StatusSource
    public let capturedAt: Date?
    public let availableNow: Bool?
    public let nextAvailabilityAt: Date?
    public let weeklyUsagePercent: Int?
    public let weeklyResetAt: Date?
    public let weeklyWindowState: AccountWindowState
    public let shortWindowUsagePercent: Int?
    public let shortWindowResetAt: Date?
    public let shortWindowState: AccountWindowState
    public let rawFolderResetToken: String?
    public let rawShortWindowResetToken: String?

    public init(
        source: StatusSource,
        capturedAt: Date?,
        availableNow: Bool?,
        nextAvailabilityAt: Date?,
        weeklyUsagePercent: Int?,
        weeklyResetAt: Date?,
        shortWindowUsagePercent: Int?,
        shortWindowResetAt: Date?,
        rawFolderResetToken: String?,
        weeklyWindowState: AccountWindowState = .needsRefresh,
        shortWindowState: AccountWindowState = .needsRefresh,
        rawShortWindowResetToken: String? = nil
    ) {
        self.source = source
        self.capturedAt = capturedAt
        self.availableNow = availableNow
        self.nextAvailabilityAt = nextAvailabilityAt
        self.weeklyUsagePercent = weeklyUsagePercent
        self.weeklyResetAt = weeklyResetAt
        self.weeklyWindowState = weeklyWindowState
        self.shortWindowUsagePercent = shortWindowUsagePercent
        self.shortWindowResetAt = shortWindowResetAt
        self.shortWindowState = shortWindowState
        self.rawFolderResetToken = rawFolderResetToken
        self.rawShortWindowResetToken = rawShortWindowResetToken
    }

    public var hasNeedsRefreshWindow: Bool {
        shortWindowState == .needsRefresh || weeklyWindowState == .needsRefresh
    }

    public var hasUnreadableWindow: Bool {
        shortWindowState == .unreadable || weeklyWindowState == .unreadable
    }
}

public enum QuotaAvailabilityPolicy {
    public static let shortWindowCoolingDownUsageThreshold = 97
    public static let weeklyCoolingDownUsageThreshold = 100

    public static func blocksShortWindow(usedPercent: Int?) -> Bool {
        guard let usedPercent else {
            return false
        }
        return usedPercent >= shortWindowCoolingDownUsageThreshold
    }

    public static func blocksWeeklyWindow(usedPercent: Int?) -> Bool {
        guard let usedPercent else {
            return false
        }
        return usedPercent >= weeklyCoolingDownUsageThreshold
    }

    public static func blocks(usedPercent: Int?, windowMinutes: Int?) -> Bool {
        guard let usedPercent else {
            return false
        }

        if windowMinutes == 10_080 {
            return blocksWeeklyWindow(usedPercent: usedPercent)
        }

        return blocksShortWindow(usedPercent: usedPercent)
    }
}

public struct LiveCodexStatus: Hashable, Sendable {
    public let accountID: String
    public let trackingKey: String
    public let email: String?
    public let planType: String?
    public let workspaceName: String?
    public let authFingerprint: String
    public let snapshot: QuotaSnapshot?
    public let source: StatusSource

    public init(
        accountID: String,
        trackingKey: String,
        email: String?,
        planType: String?,
        workspaceName: String? = nil,
        authFingerprint: String,
        snapshot: QuotaSnapshot?,
        source: StatusSource = .unknown
    ) {
        self.accountID = accountID
        self.trackingKey = trackingKey
        self.email = email
        self.planType = planType
        self.workspaceName = workspaceName
        self.authFingerprint = authFingerprint
        self.snapshot = snapshot
        self.source = source
    }
}

public struct RenameReport: Hashable, Sendable {
    public let changedPaths: [String]
    public let warnings: [String]

    public init(changedPaths: [String], warnings: [String]) {
        self.changedPaths = changedPaths
        self.warnings = warnings
    }
}

public enum FolderNameParser {
    public enum ResetTokenInterpretation: Sendable {
        case dateOrTime
        case shortWindow
    }

    private static let folderSafeSlash = "∕"
    private static let shortWindowResetHorizon: TimeInterval = 6 * 60 * 60
    private static let tillPrefixRegex = try! NSRegularExpression(
        pattern: #"^\s*till\s+"#,
        options: [.caseInsensitive]
    )
    private static let managedResetRegex = try! NSRegularExpression(
        pattern: #"^(?:\d{1,2}:\d{2}|\d{1,2}[/.∕]\d{2}(?:-\d{1,2}:\d{2})?|till\s+\d{1,2}(?:[/:.∕]\d{2}(?:-\d{1,2}:\d{2})?)?)$"#,
        options: [.caseInsensitive]
    )
    private static let standaloneResetRegex = try! NSRegularExpression(
        pattern: #"^\d{1,2}(?::\d{2}|[/.∕]\d{2}(?:-\d{1,2}:\d{2})?)$"#,
        options: [.caseInsensitive]
    )
    private static let tillResetPartRegex = try! NSRegularExpression(
        pattern: #"^\d{1,2}(?:(?::|[/.∕])\d{2}(?:-\d{1,2}:\d{2})?)?$"#,
        options: [.caseInsensitive]
    )
    private static let shortWindowUsageTokenRegex = try! NSRegularExpression(
        pattern: #"^(?:5h|5hr)(\d{1,3})$"#,
        options: [.caseInsensitive]
    )
    private static let weeklyUsageTokenRegex = try! NSRegularExpression(
        pattern: #"^(?:w|wk)(\d{1,3})$"#,
        options: [.caseInsensitive]
    )
    private static let emailRegex = try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])

    public static func parse(_ folderName: String) -> ParsedFolderName {
        let trimmed = folderName.trimmingWhitespace()
        let tokens = trimmed
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        guard !tokens.isEmpty else {
            return ParsedFolderName(
                original: folderName,
                baseLabel: trimmed,
                shortWindowUsage: nil,
                shortWindowResetToken: nil,
                weeklyUsage: nil,
                weeklyResetToken: nil
            )
        }

        var workingTokens = tokens
        var capturedShortWindowUsage: Int?
        var capturedShortResetToken: String?
        var capturedWeeklyUsage: Int?
        var capturedWeeklyResetToken: String?
        var strippedManagedSuffix = false

        while let suffix = stripTrailingManagedSuffix(from: &workingTokens) {
            strippedManagedSuffix = true
            switch suffix.kind {
            case .shortWindow where capturedShortWindowUsage == nil:
                capturedShortWindowUsage = suffix.usage
                capturedShortResetToken = suffix.resetToken
            case .weekly where capturedWeeklyUsage == nil:
                capturedWeeklyUsage = suffix.usage
                capturedWeeklyResetToken = suffix.resetToken
            default:
                break
            }
        }

        let accountType = trailingAccountType(in: workingTokens)

        guard strippedManagedSuffix else {
            return ParsedFolderName(
                original: folderName,
                baseLabel: trimmed,
                accountType: accountType,
                shortWindowUsage: nil,
                shortWindowResetToken: nil,
                weeklyUsage: nil,
                weeklyResetToken: nil
            )
        }

        let base = workingTokens.joined(separator: " ").trimmingWhitespace()

        return ParsedFolderName(
            original: folderName,
            baseLabel: base,
            accountType: accountType,
            shortWindowUsage: capturedShortWindowUsage,
            shortWindowResetToken: capturedShortResetToken,
            weeklyUsage: capturedWeeklyUsage,
            weeklyResetToken: capturedWeeklyResetToken
        )
    }

    public static func inferIdentity(topLevelFolderName: String, baseLabel: String) -> DisplayIdentity {
        let cleanBase = baseLabel.trimmingWhitespace()
        let cleanTopLevel = parse(topLevelFolderName).baseLabel.trimmingWhitespace()

        if let topEmailRange = firstEmailRange(in: cleanTopLevel) {
            let email = String(cleanTopLevel[topEmailRange]).trimmingWhitespace()
            let topLevelLabel = surroundingLabel(in: cleanTopLevel, removing: topEmailRange)

            var useLabelParts: [String] = []
            if let topLevelLabel {
                useLabelParts.append(topLevelLabel)
            }

            if !cleanBase.isEmpty {
                if let baseEmailRange = firstEmailRange(in: cleanBase) {
                    let baseEmail = String(cleanBase[baseEmailRange]).trimmingWhitespace()
                    if baseEmail.caseInsensitiveCompare(email) == .orderedSame,
                       let baseRemainder = surroundingLabel(in: cleanBase, removing: baseEmailRange) {
                        useLabelParts.append(baseRemainder)
                    } else if cleanBase.caseInsensitiveCompare(cleanTopLevel) != .orderedSame {
                        useLabelParts.append(cleanBase)
                    }
                } else if cleanBase.caseInsensitiveCompare(cleanTopLevel) != .orderedSame {
                    useLabelParts.append(cleanBase)
                }
            }

            return DisplayIdentity(name: email, useLabel: combinedUseLabel(from: useLabelParts))
        }

        if let emailRange = firstEmailRange(in: cleanBase) {
            let email = String(cleanBase[emailRange]).trimmingWhitespace()
            let useLabel = surroundingLabel(in: cleanBase, removing: emailRange)

            return DisplayIdentity(name: email, useLabel: useLabel)
        }

        return DisplayIdentity(name: cleanBase.nilIfEmpty ?? topLevelFolderName, useLabel: nil)
    }

    public static func buildFolderName(
        baseLabel: String,
        accountType: String? = nil,
        shortWindowUsage: Int?,
        shortWindowResetAt: Date?,
        weeklyUsage: Int?,
        weeklyResetAt: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let normalizedAccountType = normalizedAccountType(accountType)
        let trimmedBase = if normalizedAccountType == nil {
            baseLabel.trimmingWhitespace()
        } else {
            baseLabelRemovingTrailingAccountType(baseLabel)
        }
        let normalizedShortWindowUsage = normalizedManagedUsage(
            shortWindowUsage,
            keepsZeroWhenResetAtKnown: shortWindowResetAt != nil
        )
        let normalizedWeeklyUsage = normalizedManagedUsage(
            weeklyUsage,
            keepsZeroWhenResetAtKnown: weeklyResetAt != nil
        )

        guard normalizedAccountType != nil || normalizedShortWindowUsage != nil || normalizedWeeklyUsage != nil else {
            return trimmedBase
        }

        var pieces = [trimmedBase].filter { !$0.isEmpty }
        if let normalizedAccountType {
            pieces.append(normalizedAccountType)
        }
        if let normalizedShortWindowUsage {
            pieces.append("5hr\(normalizedShortWindowUsage)")
            if let shortWindowResetAt {
                pieces.append(formatShortWindowResetToken(shortWindowResetAt, calendar: calendar))
            }
        }
        if let normalizedWeeklyUsage {
            pieces.append("wk\(normalizedWeeklyUsage)")
            if let weeklyResetAt {
                pieces.append(formatReset(weeklyResetAt, now: now, calendar: calendar))
            }
        }
        return pieces.joined(separator: " ")
    }

    public static func buildFolderName(
        baseLabel: String,
        accountType: String? = nil,
        weeklyUsage: Int?,
        weeklyResetAt: Date?,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        buildFolderName(
            baseLabel: baseLabel,
            accountType: accountType,
            shortWindowUsage: nil,
            shortWindowResetAt: nil,
            weeklyUsage: weeklyUsage,
            weeklyResetAt: weeklyResetAt,
            now: now,
            calendar: calendar
        )
    }

    public static func formatReset(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        guard !isNoon(date, calendar: calendar) else {
            return folderSafeShortDate(date, calendar: calendar)
        }

        return formatDatedTimeReset(date, calendar: calendar)
    }

    public static func formatShortWindowReset(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    public static func formatShortWindowResetToken(_ date: Date, calendar: Calendar = .current) -> String {
        formatDatedTimeReset(date, calendar: calendar)
    }

    public static func shortDate(_ date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "dd.MM"
        return formatter.string(from: date)
    }

    public static func folderSafeShortDate(_ date: Date, calendar: Calendar = .current) -> String {
        shortDate(date, calendar: calendar).replacingOccurrences(of: "/", with: folderSafeSlash)
    }

    public static func compactResetDisplay(_ token: String) -> String {
        token
            .replacingOccurrences(of: #"(?i)^till\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: folderSafeSlash, with: ".")
            .replacingOccurrences(of: "/", with: ".")
            .trimmingWhitespace()
    }

    public static func normalizedAccountType(_ value: String?) -> String? {
        guard let normalized = value?.trimmingWhitespace().lowercased(),
              !normalized.isEmpty else {
            return nil
        }

        switch normalized {
        case "free":
            return "free"
        case "plus", "pro", "personal":
            return "plus"
        case "team", "workplace":
            return "team"
        default:
            return nil
        }
    }

    public static func baseLabelRemovingTrailingAccountType(_ value: String) -> String {
        var tokens = value
            .trimmingWhitespace()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        var removedAccountType = false
        while let last = tokens.last {
            let isCanonicalAccountType = trailingAccountType(in: [last]) != nil
            let isLegacyAccountType = tokens.count > 1 && normalizedAccountType(last) != nil
            guard isCanonicalAccountType || isLegacyAccountType else {
                break
            }

            tokens.removeLast()
            removedAccountType = true
        }

        guard removedAccountType else {
            return value.trimmingWhitespace()
        }
        return tokens.joined(separator: " ").trimmingWhitespace()
    }

    public static func displayReset(
        _ token: String,
        now: Date,
        calendar: Calendar = .current,
        interpretation: ResetTokenInterpretation = .dateOrTime
    ) -> String {
        let compact = compactResetDisplay(token)
        if token.contains(":") || token.contains("/") || token.contains(".") || token.contains(folderSafeSlash) {
            let hasPreciseDate = compact.contains("-")
            if let resetAt = interpretedResetDate(
                from: token,
                now: now,
                calendar: calendar,
                interpretation: interpretation
            ) {
                if interpretation == .shortWindow, hasPreciseDate {
                    return detailedResetDisplay(resetAt, calendar: calendar)
                }
                if interpretation == .shortWindow {
                    return formatShortWindowReset(resetAt, calendar: calendar)
                }
                if hasPreciseDate {
                    return detailedResetDisplay(resetAt, calendar: calendar)
                }
                if calendar.isDate(resetAt, inSameDayAs: now) {
                    return formatShortWindowReset(resetAt, calendar: calendar)
                }
                return shortDate(resetAt, calendar: calendar)
            }
        }
        return compact
    }

    public static func interpretedResetDate(
        from token: String,
        now: Date,
        calendar: Calendar = .current,
        interpretation: ResetTokenInterpretation = .dateOrTime
    ) -> Date? {
        let cleaned = compactResetDisplay(token)
            .replacingOccurrences(of: ".", with: "/")
            .trimmingWhitespace()
        guard !cleaned.isEmpty else {
            return nil
        }

        if let preciseDate = dayMonthDateTimeCandidate(
            from: cleaned,
            now: now,
            calendar: calendar
        ) {
            return preciseDate
        }

        if interpretation == .shortWindow {
            return shortWindowTimeCandidate(from: cleaned, now: now, calendar: calendar)
        }

        if let slashDate = dayMonthDateCandidate(
            from: cleaned,
            separator: "/",
            now: now,
            calendar: calendar
        ) {
            return slashDate
        }

        if cleaned.contains(":") {
            let dateCandidate = dayMonthDateCandidate(
                from: cleaned,
                separator: ":",
                now: now,
                calendar: calendar
            )
            let timeCandidate = sameDayTimeCandidate(from: cleaned, now: now, calendar: calendar)

            if prefersDateInterpretation(token) {
                return dateCandidate ?? timeCandidate
            }
            if let timeCandidate, timeCandidate > now {
                return timeCandidate
            }
            if let dateCandidate, dateCandidate > now {
                return dateCandidate
            }
            return timeCandidate ?? dateCandidate
        }

        if let day = Int(cleaned),
           (1...31).contains(day) {
            var components = calendar.dateComponents([.year, .month], from: now)
            components.day = day
            components.hour = 12
            components.minute = 0
            return calendar.date(from: components)
        }

        return nil
    }

    private static func detailedResetDisplay(_ date: Date, calendar: Calendar) -> String {
        "\(formatShortWindowReset(date, calendar: calendar)) \(shortDate(date, calendar: calendar))"
    }

    private static func formatDatedTimeReset(_ date: Date, calendar: Calendar) -> String {
        "\(folderSafeShortDate(date, calendar: calendar))-\(formatShortWindowReset(date, calendar: calendar))"
    }

    public static func isManagedResetToken(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return managedResetRegex.firstMatch(in: token, options: [], range: range) != nil
    }

    private static func normalizedManagedUsage(
        _ usage: Int?,
        keepsZeroWhenResetAtKnown: Bool = false
    ) -> Int? {
        guard let usage else {
            return nil
        }

        let clamped = max(0, min(100, usage))
        if clamped > 0 {
            return clamped
        }
        return keepsZeroWhenResetAtKnown ? 0 : nil
    }

    private static func prefersDateInterpretation(_ token: String) -> Bool {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return tillPrefixRegex.firstMatch(in: token, options: [], range: range) != nil
    }

    private static func dayMonthDateCandidate(
        from token: String,
        separator: Character,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let parts = token.split(separator: separator).map(String.init)
        guard parts.count == 2,
              let day = Int(parts[0]),
              let month = Int(parts[1]),
              (1...31).contains(day),
              (1...12).contains(month) else {
            return nil
        }

        var components = calendar.dateComponents([.year], from: now)
        components.month = month
        components.day = day
        components.hour = 12
        components.minute = 0
        return calendar.date(from: components)
    }

    private static func dayMonthDateTimeCandidate(
        from token: String,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        let pieces = token.split(separator: "-", maxSplits: 1).map(String.init)
        guard pieces.count == 2 else {
            return nil
        }

        let dateParts = pieces[0].split(separator: "/").map(String.init)
        let timeParts = pieces[1].split(separator: ":").map(String.init)
        guard dateParts.count == 2,
              timeParts.count == 2,
              let day = Int(dateParts[0]),
              let month = Int(dateParts[1]),
              let hour = Int(timeParts[0]),
              let minute = Int(timeParts[1]),
              (1...31).contains(day),
              (1...12).contains(month),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        var components = calendar.dateComponents([.year], from: now)
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)
    }

    private static func sameDayTimeCandidate(from token: String, now: Date, calendar: Calendar) -> Date? {
        let parts = token.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)
    }

    private static func shortWindowTimeCandidate(from token: String, now: Date, calendar: Calendar) -> Date? {
        guard let sameDay = sameDayTimeCandidate(from: token, now: now, calendar: calendar) else {
            return nil
        }

        guard sameDay <= now else {
            return sameDay
        }

        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: sameDay),
              nextDay.timeIntervalSince(now) <= shortWindowResetHorizon else {
            return sameDay
        }
        return nextDay
    }

    private static func isNoon(_ date: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return components.hour == 12 && components.minute == 0
    }

    private static func stripTrailingManagedSuffix(from tokens: inout [String]) -> ManagedSuffix? {
        guard !tokens.isEmpty else {
            return nil
        }

        var workingEnd = tokens.count
        var resetToken: String?

        if let trailingReset = trailingResetToken(in: tokens) {
            resetToken = trailingReset.value
            workingEnd -= trailingReset.tokenCount
        }

        guard workingEnd > 0,
              let managedToken = managedToken(from: tokens[workingEnd - 1]) else {
            return nil
        }

        tokens.removeSubrange((workingEnd - 1)..<tokens.count)
        return ManagedSuffix(kind: managedToken.kind, usage: managedToken.usage, resetToken: resetToken)
    }

    private static func trailingResetToken(in tokens: [String]) -> (value: String, tokenCount: Int)? {
        guard let last = tokens.last else {
            return nil
        }

        if tokens.count >= 2 {
            let previous = tokens[tokens.count - 2]
            if previous.caseInsensitiveCompare("till") == .orderedSame,
               matches(last, using: tillResetPartRegex) {
                return ("till \(last)", 2)
            }
        }

        if matches(last, using: standaloneResetRegex) {
            return (last, 1)
        }

        return nil
    }

    private static func managedToken(from token: String) -> (kind: ManagedUsageKind, usage: Int)? {
        if let shortWindowUsage = usage(from: token, using: shortWindowUsageTokenRegex) {
            return (.shortWindow, shortWindowUsage)
        }
        if let weeklyUsage = usage(from: token, using: weeklyUsageTokenRegex) {
            return (.weekly, weeklyUsage)
        }
        return nil
    }

    private static func trailingAccountType(in tokens: [String]) -> String? {
        guard let token = tokens.last else {
            return nil
        }

        switch token.trimmingWhitespace().lowercased() {
        case "free", "plus", "team":
            return token.trimmingWhitespace().lowercased()
        default:
            return nil
        }
    }

    private static func usage(from token: String, using regex: NSRegularExpression) -> Int? {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        guard let match = regex.firstMatch(in: token, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: token) else {
            return nil
        }
        return Int(token[valueRange])
    }

    private static func matches(_ token: String, using regex: NSRegularExpression) -> Bool {
        let range = NSRange(token.startIndex..<token.endIndex, in: token)
        return regex.firstMatch(in: token, options: [], range: range) != nil
    }

    private static func firstEmailRange(in string: String) -> Range<String.Index>? {
        let nsRange = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = emailRegex.firstMatch(in: string, options: [], range: nsRange),
              let range = Range(match.range(at: 0), in: string) else {
            return nil
        }
        return range
    }

    private static func surroundingLabel(in string: String, removing range: Range<String.Index>) -> String? {
        let prefix = String(string[..<range.lowerBound]).trimmingWhitespace()
        let suffix = String(string[range.upperBound...]).trimmingWhitespace()
        return [prefix, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .nilIfEmpty
    }

    private static func combinedUseLabel(from parts: [String]) -> String? {
        var merged: [String] = []

        for part in parts.map({ $0.trimmingWhitespace() }).filter({ !$0.isEmpty }) {
            let normalizedPart = part.lowercased()

            if let existingIndex = merged.firstIndex(where: {
                let normalizedExisting = $0.lowercased()
                return normalizedExisting == normalizedPart || normalizedExisting.contains(normalizedPart)
            }) {
                if merged[existingIndex].count < part.count {
                    merged[existingIndex] = part
                }
                continue
            }

            if let existingIndex = merged.firstIndex(where: {
                normalizedPart.contains($0.lowercased())
            }) {
                merged[existingIndex] = part
                continue
            }

            merged.append(part)
        }

        return merged.joined(separator: " ").nilIfEmpty
    }

    private struct ManagedSuffix {
        let kind: ManagedUsageKind
        let usage: Int
        let resetToken: String?
    }

    private enum ManagedUsageKind {
        case shortWindow
        case weekly
    }
}

public enum StatusResolver {
    public static func resolve(
        groups: [DuplicateGroup],
        liveStatus: LiveCodexStatus?,
        now: Date,
        calendar: Calendar = .current
    ) -> [String: AccountStatus] {
        let trackingKeys = Set(groups.map(\.trackingKey))
        var statuses: [String: AccountStatus] = [:]

        for trackingKey in trackingKeys {
            let fallbackRecord = groups.first(where: { $0.trackingKey == trackingKey })?.primaryRecord
            statuses[trackingKey] = resolveStatus(
                trackingKey: trackingKey,
                liveStatus: liveStatus,
                fallbackRecord: fallbackRecord,
                now: now,
                calendar: calendar
            )
        }

        return statuses
    }

    public static func resolveSavedStatusesFromFolderNames(
        groups: [DuplicateGroup],
        now: Date,
        calendar: Calendar = .current
    ) -> [String: AccountStatus] {
        resolve(
            groups: groups,
            liveStatus: nil,
            now: now,
            calendar: calendar
        )
    }

    public static func resolve(
        groups: [DuplicateGroup],
        liveStatus: LiveCodexStatus?,
        snapshotsByTrackingKey _: [String: QuotaSnapshot],
        now: Date,
        calendar: Calendar = .current
    ) -> [String: AccountStatus] {
        resolve(
            groups: groups,
            liveStatus: liveStatus,
            now: now,
            calendar: calendar
        )
    }

    public static func resolveSavedStatusesForDisplay(
        groups: [DuplicateGroup],
        snapshotsByTrackingKey _: [String: QuotaSnapshot],
        now: Date,
        calendar: Calendar = .current
    ) -> [String: AccountStatus] {
        resolveSavedStatusesFromFolderNames(
            groups: groups,
            now: now,
            calendar: calendar
        )
    }

    public static func resolveStatus(
        trackingKey: String,
        liveStatus: LiveCodexStatus?,
        fallbackRecord: ScannedAuthRecord?,
        now: Date,
        calendar: Calendar = .current
    ) -> AccountStatus {
        let isCurrentLiveTrackingKey = liveStatus?.trackingKey == trackingKey

        if let liveStatus, isCurrentLiveTrackingKey, let liveSnapshot = liveStatus.snapshot {
            let fallbackBaseLabel = fallbackRecord?.parsedFolderName.baseLabel
            let baseLabel = liveStatus.planType == nil
                ? fallbackBaseLabel
                : fallbackBaseLabel.map(FolderNameParser.baseLabelRemovingTrailingAccountType)
            return status(
                from: liveSnapshot,
                source: liveStatus.source,
                expectedWindows: expectedQuotaWindows(
                    planType: liveStatus.planType,
                    baseLabel: baseLabel
                ),
                now: now
            )
        }

        if let fallbackRecord {
            return status(from: fallbackRecord, now: now, calendar: calendar)
        }

        return unknownStatus()
    }

    public static func resolveStatus(
        trackingKey: String,
        liveStatus: LiveCodexStatus?,
        snapshotsByTrackingKey _: [String: QuotaSnapshot],
        fallbackRecord: ScannedAuthRecord?,
        now: Date,
        calendar: Calendar = .current
    ) -> AccountStatus {
        resolveStatus(
            trackingKey: trackingKey,
            liveStatus: liveStatus,
            fallbackRecord: fallbackRecord,
            now: now,
            calendar: calendar
        )
    }

    private static func status(from fallbackRecord: ScannedAuthRecord, now: Date, calendar: Calendar) -> AccountStatus {
        let expectedWindows = expectedQuotaWindows(
            planType: fallbackRecord.planType,
            baseLabel: fallbackRecord.parsedFolderName.baseLabel
        )
        let shortWindow = interpretedFolderWindow(
            usedPercent: fallbackRecord.parsedFolderName.shortWindowUsage,
            resetToken: fallbackRecord.parsedFolderName.shortWindowResetToken,
            isExpected: expectedWindows.includesShortWindow,
            now: now,
            calendar: calendar,
            interpretation: .shortWindow
        )
        let weeklyWindow = interpretedFolderWindow(
            usedPercent: fallbackRecord.parsedFolderName.weeklyUsage,
            resetToken: fallbackRecord.parsedFolderName.weeklyResetToken,
            isExpected: expectedWindows.includesWeeklyWindow,
            now: now,
            calendar: calendar
        )

        let blockingReset = [
            blockingResetDate(
                usedPercent: shortWindow.displayedUsedPercent,
                resetAt: shortWindow.displayedResetAt,
                coolingDownThreshold: QuotaAvailabilityPolicy.shortWindowCoolingDownUsageThreshold,
                now: now
            ),
            blockingResetDate(
                usedPercent: weeklyWindow.displayedUsedPercent,
                resetAt: weeklyWindow.displayedResetAt,
                coolingDownThreshold: QuotaAvailabilityPolicy.weeklyCoolingDownUsageThreshold,
                now: now
            ),
        ]
        .compactMap { $0 }
        .min()

        let hasCurrentWindow = shortWindow.displayedUsedPercent != nil
            || shortWindow.displayedResetAt != nil
            || weeklyWindow.displayedUsedPercent != nil
            || weeklyWindow.displayedResetAt != nil
        let hasUnreadableWindow = shortWindow.state == .unreadable || weeklyWindow.state == .unreadable
        let availableNow: Bool? = if blockingReset != nil {
            false
        } else if hasUnreadableWindow {
            nil
        } else if hasCurrentWindow {
            true
        } else {
            nil
        }

        return AccountStatus(
            source: .folderName,
            capturedAt: nil,
            availableNow: availableNow,
            nextAvailabilityAt: blockingReset,
            weeklyUsagePercent: weeklyWindow.displayedUsedPercent,
            weeklyResetAt: weeklyWindow.displayedResetAt,
            shortWindowUsagePercent: shortWindow.displayedUsedPercent,
            shortWindowResetAt: shortWindow.displayedResetAt,
            rawFolderResetToken: fallbackRecord.parsedFolderName.weeklyResetToken,
            weeklyWindowState: weeklyWindow.state,
            shortWindowState: shortWindow.state,
            rawShortWindowResetToken: fallbackRecord.parsedFolderName.shortWindowResetToken
        )
    }

    private static func interpretedFolderWindow(
        usedPercent rawUsage: Int?,
        resetToken: String?,
        isExpected: Bool,
        now: Date,
        calendar: Calendar,
        interpretation: FolderNameParser.ResetTokenInterpretation = .dateOrTime
    ) -> InterpretedFolderWindow {
        guard let rawUsage else {
            return InterpretedFolderWindow(
                state: isExpected ? .needsRefresh : .current,
                displayedUsedPercent: nil,
                displayedResetAt: nil
            )
        }

        let clampedUsage = max(0, min(100, rawUsage))
        guard let resetToken else {
            return InterpretedFolderWindow(state: .unreadable, displayedUsedPercent: nil, displayedResetAt: nil)
        }

        guard let resetAt = FolderNameParser.interpretedResetDate(
            from: resetToken,
            now: now,
            calendar: calendar,
            interpretation: interpretation
        ) else {
            return InterpretedFolderWindow(state: .unreadable, displayedUsedPercent: nil, displayedResetAt: nil)
        }

        guard resetAt > now else {
            return InterpretedFolderWindow(state: .needsRefresh, displayedUsedPercent: nil, displayedResetAt: nil)
        }

        return InterpretedFolderWindow(state: .current, displayedUsedPercent: clampedUsage, displayedResetAt: resetAt)
    }

    public static func resolveCurrentLiveStatus(
        liveStatus: LiveCodexStatus?,
        fallbackRecord: ScannedAuthRecord?,
        now: Date,
        calendar: Calendar = .current
    ) -> AccountStatus? {
        guard let liveStatus else {
            return nil
        }

        return resolveStatus(
            trackingKey: liveStatus.trackingKey,
            liveStatus: liveStatus,
            fallbackRecord: fallbackRecord,
            now: now,
            calendar: calendar
        )
    }

    public static func resolveCurrentLiveStatus(
        liveStatus: LiveCodexStatus?,
        snapshotsByTrackingKey _: [String: QuotaSnapshot],
        fallbackRecord: ScannedAuthRecord?,
        now: Date,
        calendar: Calendar = .current
    ) -> AccountStatus? {
        resolveCurrentLiveStatus(
            liveStatus: liveStatus,
            fallbackRecord: fallbackRecord,
            now: now,
            calendar: calendar
        )
    }

    public static func supportsShortWindow(planType: String?, baseLabel: String? = nil) -> Bool {
        expectedQuotaWindows(
            planType: planType,
            baseLabel: baseLabel
        ).includesShortWindow
    }

    public static func suggestReplacement(
        groups: [DuplicateGroup],
        statusesByTrackingKey: [String: AccountStatus],
        currentTrackingKey: String?,
        preferSameKindAsCurrent: Bool = false,
        currentPlanType: String? = nil
    ) -> DuplicateGroup? {
        let currentSuggestionKind = suggestionKind(
            forPlanType: currentPlanType,
            treatsMissingPlanTypeAsOther: false
        )

        return groups
            .filter { $0.trackingKey != currentTrackingKey }
            .filter { statusesByTrackingKey[$0.trackingKey]?.availableNow != false }
            .sorted { lhs, rhs in
                let left = statusesByTrackingKey[lhs.trackingKey]
                let right = statusesByTrackingKey[rhs.trackingKey]

                let leftAvailability = availabilityRank(for: left)
                let rightAvailability = availabilityRank(for: right)
                if leftAvailability != rightAvailability {
                    return leftAvailability < rightAvailability
                }

                if preferSameKindAsCurrent, let currentSuggestionKind {
                    let leftMatchesCurrent = suggestionKind(
                        forPlanType: lhs.primaryRecord.planType,
                        treatsMissingPlanTypeAsOther: true
                    ) == currentSuggestionKind
                    let rightMatchesCurrent = suggestionKind(
                        forPlanType: rhs.primaryRecord.planType,
                        treatsMissingPlanTypeAsOther: true
                    ) == currentSuggestionKind
                    if leftMatchesCurrent != rightMatchesCurrent {
                        return leftMatchesCurrent
                    }
                }

                let leftWeekly = left?.weeklyUsagePercent ?? 999
                let rightWeekly = right?.weeklyUsagePercent ?? 999
                if leftWeekly != rightWeekly {
                    return leftWeekly < rightWeekly
                }

                return lhs.primaryRecord.identity.name.localizedCaseInsensitiveCompare(rhs.primaryRecord.identity.name) == .orderedAscending
            }
            .first
    }

    private enum SuggestionKind {
        case free
        case other
    }

    private static func suggestionKind(
        forPlanType planType: String?,
        treatsMissingPlanTypeAsOther: Bool
    ) -> SuggestionKind? {
        guard let normalizedPlanType = normalizedQuotaPlanType(planType) else {
            return treatsMissingPlanTypeAsOther ? .other : nil
        }

        return normalizedPlanType == "free" ? .free : .other
    }

    private static func availabilityRank(for status: AccountStatus?) -> Int {
        switch status?.availableNow {
        case true:
            return 0
        case false:
            return 1
        case nil:
            return 2
        }
    }

    private static func status(
        from snapshot: QuotaSnapshot,
        source: StatusSource,
        expectedWindows: ExpectedQuotaWindows,
        now: Date
    ) -> AccountStatus {
        let weeklyResetAt = expectedWindows.includesWeeklyWindow
            ? projectedResetDate(
                originalResetAt: snapshot.secondaryResetAt,
                windowMinutes: snapshot.secondaryWindowMinutes,
                now: now
            )
            : nil
        let shortResetAt = expectedWindows.includesShortWindow
            ? projectedResetDate(
                originalResetAt: snapshot.primaryResetAt,
                windowMinutes: snapshot.primaryWindowMinutes,
                now: now
            )
            : nil
        let weeklyUsage = expectedWindows.includesWeeklyWindow
            ? effectiveUsedPercent(
                original: snapshot.secondaryUsedPercent,
                resetAt: snapshot.secondaryResetAt,
                windowMinutes: snapshot.secondaryWindowMinutes,
                now: now
            )
            : nil
        let shortUsage = expectedWindows.includesShortWindow
            ? effectiveUsedPercent(
                original: snapshot.primaryUsedPercent,
                resetAt: snapshot.primaryResetAt,
                windowMinutes: snapshot.primaryWindowMinutes,
                now: now
            )
            : nil
        let nextAvailabilityAt = blockingResetDate(snapshot: snapshot, expectedWindows: expectedWindows, now: now)
        let hasCurrentWindow = weeklyUsage != nil
            || weeklyResetAt != nil
            || shortUsage != nil
            || shortResetAt != nil
        let availableNow: Bool? = if nextAvailabilityAt != nil {
            false
        } else if hasCurrentWindow {
            true
        } else {
            nil
        }

        return AccountStatus(
            source: source,
            capturedAt: snapshot.capturedAt,
            availableNow: availableNow,
            nextAvailabilityAt: nextAvailabilityAt,
            weeklyUsagePercent: weeklyUsage,
            weeklyResetAt: weeklyResetAt,
            shortWindowUsagePercent: shortUsage,
            shortWindowResetAt: shortResetAt,
            rawFolderResetToken: nil,
            weeklyWindowState: windowState(
                displayedUsedPercent: weeklyUsage,
                displayedResetAt: weeklyResetAt,
                isExpected: expectedWindows.includesWeeklyWindow
            ),
            shortWindowState: windowState(
                displayedUsedPercent: shortUsage,
                displayedResetAt: shortResetAt,
                isExpected: expectedWindows.includesShortWindow
            )
        )
    }

    private static func windowState(
        displayedUsedPercent: Int?,
        displayedResetAt: Date?,
        isExpected: Bool
    ) -> AccountWindowState {
        if displayedUsedPercent != nil || displayedResetAt != nil {
            return .current
        }
        return isExpected ? .needsRefresh : .current
    }

    private static func expectedQuotaWindows(
        planType: String?,
        baseLabel: String?
    ) -> ExpectedQuotaWindows {
        let tokenSet = explicitQuotaKindTokens(from: baseLabel)
        if tokenSet.contains("free") {
            return .weeklyOnly
        }
        if normalizedQuotaPlanType(planType) == "free" {
            return .weeklyOnly
        }
        if !tokenSet.isDisjoint(with: ["personal", "plus", "pro", "team", "workplace"]) {
            return .both
        }

        switch normalizedQuotaPlanType(planType) {
        case "team", "workplace":
            return .both
        default:
            break
        }

        return .both
    }

    private static func explicitQuotaKindTokens(from baseLabel: String?) -> Set<String> {
        let labelWithoutEmailComponents = (baseLabel ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .filter { !$0.contains("@") }
            .joined(separator: " ")
        let normalizedTokens = labelWithoutEmailComponents
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return Set(normalizedTokens)
    }

    private static func normalizedQuotaPlanType(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func effectiveUsedPercent(
        original: Int?,
        resetAt: Date?,
        windowMinutes: Int?,
        now: Date
    ) -> Int? {
        guard let original else {
            return nil
        }
        guard resetAt != nil else {
            return original
        }
        guard projectedResetDate(originalResetAt: resetAt, windowMinutes: windowMinutes, now: now) != nil else {
            return nil
        }
        return original
    }

    private static func blockingResetDate(
        snapshot: QuotaSnapshot,
        expectedWindows: ExpectedQuotaWindows,
        now: Date
    ) -> Date? {
        let primaryBlocks = expectedWindows.includesShortWindow
            && QuotaAvailabilityPolicy.blocksShortWindow(usedPercent: snapshot.primaryUsedPercent)
        let secondaryBlocks = expectedWindows.includesWeeklyWindow
            && QuotaAvailabilityPolicy.blocksWeeklyWindow(usedPercent: snapshot.secondaryUsedPercent)

        let primaryReset = primaryBlocks
            ? projectedResetDate(originalResetAt: snapshot.primaryResetAt, windowMinutes: snapshot.primaryWindowMinutes, now: now)
            : nil
        let secondaryReset = secondaryBlocks
            ? projectedResetDate(originalResetAt: snapshot.secondaryResetAt, windowMinutes: snapshot.secondaryWindowMinutes, now: now)
            : nil

        let candidates = [primaryReset, secondaryReset].compactMap { $0 }.filter { $0 > now }
        return candidates.min()
    }

    private static func blockingResetDate(
        usedPercent: Int?,
        resetAt: Date?,
        coolingDownThreshold: Int,
        now: Date
    ) -> Date? {
        guard let usedPercent, usedPercent >= coolingDownThreshold, let resetAt, resetAt > now else {
            return nil
        }
        return resetAt
    }

    private static func projectedResetDate(originalResetAt: Date?, windowMinutes: Int?, now: Date) -> Date? {
        guard let resetAt = originalResetAt else {
            return nil
        }
        guard resetAt > now else {
            return nil
        }
        return resetAt
    }

    private static func unknownStatus() -> AccountStatus {
        AccountStatus(
            source: .unknown,
            capturedAt: nil,
            availableNow: nil,
            nextAvailabilityAt: nil,
            weeklyUsagePercent: nil,
            weeklyResetAt: nil,
            shortWindowUsagePercent: nil,
            shortWindowResetAt: nil,
            rawFolderResetToken: nil,
            weeklyWindowState: .needsRefresh,
            shortWindowState: .needsRefresh
        )
    }
}

private struct InterpretedFolderWindow {
    let state: AccountWindowState
    let displayedUsedPercent: Int?
    let displayedResetAt: Date?
}

private struct ExpectedQuotaWindows {
    let includesShortWindow: Bool
    let includesWeeklyWindow: Bool

    static let both = ExpectedQuotaWindows(includesShortWindow: true, includesWeeklyWindow: true)
    static let weeklyOnly = ExpectedQuotaWindows(includesShortWindow: false, includesWeeklyWindow: true)
}

extension String {
    func trimmingWhitespace() -> String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfEmpty: String? {
        let trimmed = trimmingWhitespace()
        return trimmed.isEmpty ? nil : trimmed
    }
}
