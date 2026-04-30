import CodexAuthRotatorCore
import Foundation

enum StatusDisplayFormatter {
    static func compactWeeklyUsage(
        status: AccountStatus?,
        fallbackWeeklyUsage: Int?
    ) -> String {
        usagePercentLabel(
            status?.weeklyUsagePercent,
            fallbackPercent: fallbackWeeklyUsage,
            state: status?.weeklyWindowState
        )
    }

    static func usagePercentLabel(
        _ percent: Int?,
        fallbackPercent: Int? = nil,
        state: AccountWindowState? = nil,
        isApplicable: Bool = true
    ) -> String {
        guard isApplicable else {
            return ""
        }
        guard let percent = percent ?? fallbackPercent else {
            return windowStateLabel(state) ?? "Unknown"
        }
        return "\(percent)%"
    }

    static func shortWindowUsageLabel(
        status: AccountStatus?,
        fallbackUsedPercent: Int? = nil,
        display: CompactSidebarUsageDisplay = .used,
        isApplicable: Bool = true
    ) -> String {
        guard isApplicable else {
            return ""
        }
        if display == .used,
           SidebarPresentation.shouldShowFiveHourBlockedLabel(
            status: status,
            fallbackUsedPercent: fallbackUsedPercent
           ) {
            return "Blocked"
        }

        let resolvedPercent: Int? = switch display {
        case .remaining:
            SidebarPresentation.effectiveFiveHourRemainingPercent(
                status: status,
                fallbackUsedPercent: fallbackUsedPercent
            )
        case .used:
            status?.shortWindowUsagePercent ?? fallbackUsedPercent
        }

        return usagePercentLabel(
            resolvedPercent,
            state: status?.shortWindowState,
            isApplicable: isApplicable
        )
    }

    static func compactUsagePercentLabel(
        fromUsedPercent usedPercent: Int?,
        fallbackUsedPercent: Int? = nil,
        display: CompactSidebarUsageDisplay,
        state: AccountWindowState? = nil,
        isApplicable: Bool = true
    ) -> String {
        guard isApplicable else {
            return ""
        }
        switch display {
        case .remaining:
            return remainingPercentLabel(
                fromUsedPercent: usedPercent,
                fallbackUsedPercent: fallbackUsedPercent,
                state: state,
                isApplicable: isApplicable
            )
        case .used:
            return usagePercentLabel(
                usedPercent,
                fallbackPercent: fallbackUsedPercent,
                state: state,
                isApplicable: isApplicable
            )
        }
    }

    static func remainingPercentLabel(
        fromUsedPercent usedPercent: Int?,
        fallbackUsedPercent: Int? = nil,
        state: AccountWindowState? = nil,
        isApplicable: Bool = true
    ) -> String {
        usagePercentLabel(
            SidebarPresentation.remainingPercent(fromUsedPercent: usedPercent),
            fallbackPercent: SidebarPresentation.remainingPercent(fromUsedPercent: fallbackUsedPercent),
            state: state,
            isApplicable: isApplicable
        )
    }

    static func compactResetSummary(
        status: AccountStatus?,
        fallbackShortResetToken: String? = nil,
        fallbackResetToken: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        var pieces: [String] = []

        if let shortSummary = resetSummary(
            title: "5-Hour",
            resetAt: status?.shortWindowResetAt,
            state: status?.shortWindowState,
            fallbackToken: status?.rawShortWindowResetToken ?? fallbackShortResetToken,
            now: now,
            calendar: calendar,
            interpretation: .shortWindow
        ) {
            pieces.append(shortSummary)
        }
        if let weeklySummary = resetSummary(
            title: "Week",
            resetAt: status?.weeklyResetAt,
            state: status?.weeklyWindowState,
            fallbackToken: status?.rawFolderResetToken ?? fallbackResetToken,
            now: now,
            calendar: calendar
        ) {
            pieces.append(weeklySummary)
        }

        return pieces.isEmpty ? "Unknown" : pieces.joined(separator: " · ")
    }

    static func hourlyResetLabel(
        status: AccountStatus?,
        fallbackResetToken: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        isApplicable: Bool = true
    ) -> String {
        guard isApplicable else {
            return ""
        }
        if let resetAt = status?.shortWindowResetAt {
            return shortWindowResetLabel(for: resetAt, now: now, calendar: calendar)
        }
        if let stateLabel = windowStateLabel(status?.shortWindowState) {
            return stateLabel
        }
        if let fallbackResetToken {
            return FolderNameParser.displayReset(
                fallbackResetToken,
                now: now,
                calendar: calendar,
                interpretation: .shortWindow
            )
        }
        return "Unknown"
    }

    static func compactHourlyResetLabel(
        status: AccountStatus?,
        fallbackResetToken: String? = nil,
        now: Date = Date(),
        calendar: Calendar = .current,
        isApplicable: Bool = true
    ) -> String {
        guard isApplicable else {
            return ""
        }
        if let resetAt = status?.shortWindowResetAt {
            return shortWindowResetLabel(for: resetAt, now: now, calendar: calendar)
        }
        if let stateLabel = windowStateLabel(status?.shortWindowState) {
            return stateLabel
        }
        if let fallbackResetToken {
            return FolderNameParser.displayReset(
                fallbackResetToken,
                now: now,
                calendar: calendar,
                interpretation: .shortWindow
            )
        }
        return "Unknown"
    }

    static func compactWeeklyResetLabel(
        status: AccountStatus?,
        fallbackResetToken: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if let resetAt = status?.weeklyResetAt {
            return compactResetLabel(for: resetAt, now: now, calendar: calendar)
        }
        if let stateLabel = windowStateLabel(status?.weeklyWindowState) {
            return stateLabel
        }
        if let fallbackToken = status?.rawFolderResetToken ?? fallbackResetToken {
            return FolderNameParser.displayReset(fallbackToken, now: now, calendar: calendar)
        }
        return "Unknown"
    }

    static func weeklyResetLabel(
        status: AccountStatus?,
        fallbackResetToken: String?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if let resetAt = status?.weeklyResetAt {
            return detailedResetLabel(for: resetAt, now: now, calendar: calendar)
        }
        if let stateLabel = windowStateLabel(status?.weeklyWindowState) {
            return stateLabel
        }
        if let fallbackToken = status?.rawFolderResetToken ?? fallbackResetToken {
            return FolderNameParser.displayReset(fallbackToken, now: now, calendar: calendar)
        }
        return "Unknown"
    }

    static func freshnessLabel(
        status: AccountStatus?,
        now: Date = Date()
    ) -> String {
        switch status?.source {
        case .oauth:
            return "OAuth"
        case .cliRPC:
            return "CLI RPC"
        case .cliPTY:
            return "CLI /status"
        case .folderName:
            if status?.hasUnreadableWindow == true {
                return "Unreadable"
            }
            if status?.hasNeedsRefreshWindow == true {
                return "Needs refresh"
            }
            return "From folder"
        default:
            return "Unknown"
        }
    }

    static func currentLiveSourceSummaryLabel(status: AccountStatus?) -> String {
        switch status?.source {
        case .oauth:
            return "Fresh from OAuth"
        case .cliRPC:
            return "Fresh from CLI RPC"
        case .cliPTY:
            return "Fresh from CLI /status"
        case .folderName:
            if status?.hasUnreadableWindow == true {
                return "Unreadable"
            }
            if status?.hasNeedsRefreshWindow == true {
                return "Needs refresh"
            }
            return "From folder"
        default:
            return "Unknown"
        }
    }

    static func availabilityLabel(status: AccountStatus?) -> String {
        switch status?.availableNow {
        case true:
            return "Available"
        case false:
            return "Cooling down"
        case nil:
            if status?.hasUnreadableWindow == true {
                return "Unreadable"
            }
            if status?.hasNeedsRefreshWindow == true {
                return "Needs refresh"
            }
            return "Unknown"
        }
    }

    static func currentLiveStatusSummaryLabel(status: AccountStatus?) -> String {
        let availability = availabilityLabel(status: status)
        let sourceSummary = currentLiveSourceSummaryLabel(status: status)
        return availability == sourceSummary
            ? availability
            : "\(availability) • \(sourceSummary)"
    }

    static func countdownLabel(
        until date: Date,
        now: Date = Date()
    ) -> String {
        let remainingSeconds = max(0, Int(date.timeIntervalSince(now)))
        let days = remainingSeconds / 86_400
        let hours = (remainingSeconds % 86_400) / 3_600
        let minutes = (remainingSeconds % 3_600) / 60
        let seconds = remainingSeconds % 60
        let clock = String(format: "%02d:%02d:%02d", hours, minutes, seconds)

        if days > 0 {
            return "\(days)d \(clock)"
        }
        return clock
    }

    private static func resetSummary(
        title: String,
        resetAt: Date?,
        state: AccountWindowState?,
        fallbackToken: String?,
        now: Date,
        calendar: Calendar,
        interpretation: FolderNameParser.ResetTokenInterpretation = .dateOrTime
    ) -> String? {
        if let resetAt {
            let resetLabel = interpretation == .shortWindow
                ? shortWindowResetLabel(for: resetAt, now: now, calendar: calendar)
                : compactResetLabel(for: resetAt, now: now, calendar: calendar)
            return "\(title) \(resetLabel)"
        }
        if let stateLabel = windowStateLabel(state) {
            return "\(title) \(stateLabel)"
        }
        if let fallbackToken {
            let resetLabel = FolderNameParser.displayReset(
                fallbackToken,
                now: now,
                calendar: calendar,
                interpretation: interpretation
            )
            return "\(title) \(resetLabel)"
        }
        return nil
    }

    private static func windowStateLabel(_ state: AccountWindowState?) -> String? {
        switch state {
        case .needsRefresh:
            return "Needs refresh"
        case .unreadable:
            return "Unreadable"
        default:
            return nil
        }
    }

    private static func compactResetLabel(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeLabel(for: date, calendar: calendar)
        }
        return FolderNameParser.shortDate(date, calendar: calendar)
    }

    private static func detailedResetLabel(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        let time = timeLabel(for: date, calendar: calendar)
        if calendar.isDate(date, inSameDayAs: now) {
            return time
        }
        return "\(time) \(FolderNameParser.shortDate(date, calendar: calendar))"
    }

    private static func shortWindowResetLabel(
        for date: Date,
        now: Date,
        calendar: Calendar
    ) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return timeLabel(for: date, calendar: calendar)
        }
        return detailedResetLabel(for: date, now: now, calendar: calendar)
    }

    private static func timeLabel(
        for date: Date,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
