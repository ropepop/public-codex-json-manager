import CodexAuthRotatorCore
import CoreGraphics
import Foundation

struct SidebarQuotaSummary: Hashable {
    let totalFiveHourUsed: Int?
    let totalFiveHourRemaining: Int?
    let totalWeeklyUsed: Int?
    let totalWeeklyRemaining: Int?
    let freeWeeklyRemaining: Int?
    let otherWeeklyRemaining: Int?
    let accountCount: Int
    let availableAccountCount: Int
}

struct SidebarSummaryChip: Hashable, Identifiable {
    let title: String
    let value: String

    var id: String {
        title
    }
}

struct SidebarSummaryChipLayoutItem: Hashable, Identifiable {
    let chip: SidebarSummaryChip
    let leadingSpacing: CGFloat

    var id: String {
        chip.id
    }
}

struct SidebarUsageReturnItem: Hashable, Identifiable {
    enum Kind: Hashable {
        case fiveHour
        case weekly

        var label: String {
            switch self {
            case .fiveHour:
                return "5h"
            case .weekly:
                return "Week"
            }
        }

        fileprivate var sortOrder: Int {
            switch self {
            case .fiveHour:
                return 0
            case .weekly:
                return 1
            }
        }
    }

    let id: String
    let kind: Kind
    let accountType: String
    let usedPercent: Int
    let resetAt: Date
}

struct SidebarGroupSections {
    let primaryGroups: [DuplicateGroup]
    let fiveHourUsedGroups: [DuplicateGroup]
    let fullyUsedGroups: [DuplicateGroup]
}

enum SidebarPresentation {
    static let summaryChipSpacing: CGFloat = 10
    static let summaryChipGroupedSpacing: CGFloat = 24

    static func quotaSummary(
        groups: [DuplicateGroup],
        statusesByTrackingKey: [String: AccountStatus],
        liveStatus: LiveCodexStatus?,
        currentLiveStatus: AccountStatus?
    ) -> SidebarQuotaSummary {
        let groupsByTrackingKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.trackingKey, $0) })
        let uniqueStatuses = uniqueQuotaStatuses(
            groups: groups,
            statusesByTrackingKey: statusesByTrackingKey,
            liveStatus: liveStatus,
            currentLiveStatus: currentLiveStatus
        )

        let fiveHourUsed = uniqueStatuses.values.compactMap(\.shortWindowUsagePercent)
        let weeklyUsed = uniqueStatuses.values.compactMap(\.weeklyUsagePercent)
        let fiveHourRemaining = uniqueStatuses.values.compactMap { effectiveFiveHourRemainingPercent(status: $0) }
        let weeklyRemaining = weeklyUsed.compactMap(remainingPercent(fromUsedPercent:))
        var freeWeeklyRemaining: [Int] = []
        var otherWeeklyRemaining: [Int] = []

        for (trackingKey, status) in uniqueStatuses {
            guard let weeklyRemainingPercent = remainingPercent(fromUsedPercent: status.weeklyUsagePercent) else {
                continue
            }

            if isFreePlan(
                trackingKey: trackingKey,
                groupsByTrackingKey: groupsByTrackingKey,
                liveStatus: liveStatus
            ) {
                freeWeeklyRemaining.append(weeklyRemainingPercent)
            } else {
                otherWeeklyRemaining.append(weeklyRemainingPercent)
            }
        }

        return SidebarQuotaSummary(
            totalFiveHourUsed: fiveHourUsed.isEmpty ? nil : fiveHourUsed.reduce(0, +),
            totalFiveHourRemaining: fiveHourRemaining.isEmpty ? nil : fiveHourRemaining.reduce(0, +),
            totalWeeklyUsed: weeklyUsed.isEmpty ? nil : weeklyUsed.reduce(0, +),
            totalWeeklyRemaining: weeklyRemaining.isEmpty ? nil : weeklyRemaining.reduce(0, +),
            freeWeeklyRemaining: freeWeeklyRemaining.isEmpty ? nil : freeWeeklyRemaining.reduce(0, +),
            otherWeeklyRemaining: otherWeeklyRemaining.isEmpty ? nil : otherWeeklyRemaining.reduce(0, +),
            accountCount: uniqueStatuses.count,
            availableAccountCount: uniqueStatuses.values.filter { $0.availableNow == true }.count
        )
    }

    static func usageReturnItems(
        groups: [DuplicateGroup],
        statusesByTrackingKey: [String: AccountStatus],
        liveStatus: LiveCodexStatus?,
        currentLiveStatus: AccountStatus?,
        now: Date = Date()
    ) -> [SidebarUsageReturnItem] {
        let groupsByTrackingKey = Dictionary(uniqueKeysWithValues: groups.map { ($0.trackingKey, $0) })
        let uniqueStatuses = uniqueQuotaStatuses(
            groups: groups,
            statusesByTrackingKey: statusesByTrackingKey,
            liveStatus: liveStatus,
            currentLiveStatus: currentLiveStatus
        )

        var items: [SidebarUsageReturnItem] = []
        for (trackingKey, status) in uniqueStatuses {
            let accountType = accountTypeLabel(
                trackingKey: trackingKey,
                groupsByTrackingKey: groupsByTrackingKey,
                liveStatus: liveStatus
            )

            if let usedPercent = returningUsagePercent(status.shortWindowUsagePercent),
               let resetAt = futureReset(status.shortWindowResetAt, now: now) {
                items.append(
                    SidebarUsageReturnItem(
                        id: "\(trackingKey)|5h",
                        kind: .fiveHour,
                        accountType: accountType,
                        usedPercent: usedPercent,
                        resetAt: resetAt
                    )
                )
            }

            if let usedPercent = returningUsagePercent(status.weeklyUsagePercent),
               let resetAt = futureReset(status.weeklyResetAt, now: now) {
                items.append(
                    SidebarUsageReturnItem(
                        id: "\(trackingKey)|week",
                        kind: .weekly,
                        accountType: accountType,
                        usedPercent: usedPercent,
                        resetAt: resetAt
                    )
                )
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.resetAt != rhs.resetAt {
                return lhs.resetAt < rhs.resetAt
            }
            if lhs.kind.sortOrder != rhs.kind.sortOrder {
                return lhs.kind.sortOrder < rhs.kind.sortOrder
            }
            return lhs.id < rhs.id
        }
    }

    static func quotaSummaryChips(
        summary: SidebarQuotaSummary,
        splitsWeeklyRemainingByPlanType: Bool
    ) -> [SidebarSummaryChip] {
        var chips = [
            SidebarSummaryChip(
                title: "5-Hour Left",
                value: StatusDisplayFormatter.usagePercentLabel(summary.totalFiveHourRemaining)
            ),
        ]

        if splitsWeeklyRemainingByPlanType {
            chips.append(
                SidebarSummaryChip(
                    title: "Other Left",
                    value: StatusDisplayFormatter.usagePercentLabel(summary.otherWeeklyRemaining)
                )
            )
            chips.append(
                SidebarSummaryChip(
                    title: "Free Left",
                    value: StatusDisplayFormatter.usagePercentLabel(summary.freeWeeklyRemaining)
                )
            )
        } else {
            chips.append(
                SidebarSummaryChip(
                    title: "Week Left",
                    value: StatusDisplayFormatter.usagePercentLabel(summary.totalWeeklyRemaining)
                )
            )
        }

        chips.append(
            SidebarSummaryChip(
                title: "Accounts",
                value: "\(summary.accountCount) • \(summary.availableAccountCount) up"
            )
        )

        return chips
    }

    static func quotaSummaryChipLayout(
        summary: SidebarQuotaSummary,
        splitsWeeklyRemainingByPlanType: Bool
    ) -> [SidebarSummaryChipLayoutItem] {
        let chips = quotaSummaryChips(
            summary: summary,
            splitsWeeklyRemainingByPlanType: splitsWeeklyRemainingByPlanType
        )

        return chips.enumerated().map { index, chip in
            let leadingSpacing: CGFloat
            if index == 0 {
                leadingSpacing = 0
            } else if splitsWeeklyRemainingByPlanType, chip.title == "Free Left" {
                leadingSpacing = summaryChipGroupedSpacing
            } else {
                leadingSpacing = summaryChipSpacing
            }

            return SidebarSummaryChipLayoutItem(
                chip: chip,
                leadingSpacing: leadingSpacing
            )
        }
    }

    static func remainingPercent(fromUsedPercent usedPercent: Int?) -> Int? {
        guard let usedPercent else {
            return nil
        }
        return max(0, 100 - usedPercent)
    }

    static func effectiveFiveHourRemainingPercent(
        status: AccountStatus?,
        fallbackUsedPercent: Int? = nil
    ) -> Int? {
        let usedPercent = status?.shortWindowUsagePercent ?? fallbackUsedPercent
        guard let usedPercent else {
            return nil
        }
        guard !isFiveHourWindowBlocked(status: status, usedPercent: usedPercent) else {
            return 0
        }
        return remainingPercent(fromUsedPercent: usedPercent)
    }

    static func shouldShowFiveHourBlockedLabel(
        status: AccountStatus?,
        fallbackUsedPercent: Int? = nil
    ) -> Bool {
        guard let usedPercent = status?.shortWindowUsagePercent ?? fallbackUsedPercent else {
            return false
        }
        guard usedPercent == 0 else {
            return false
        }
        return isWeeklyBlockingFiveHourWindow(status)
    }

    static func activeGroup(
        groups: [DuplicateGroup],
        liveStatus: LiveCodexStatus?
    ) -> DuplicateGroup? {
        guard let liveStatus else {
            return nil
        }

        if let exactMatch = groups.first(where: { group in
            group.records.contains(where: { $0.authFingerprint == liveStatus.authFingerprint })
        }) {
            return exactMatch
        }

        return groups.first(where: { AuthAccountMatcher.sameAccount($0, as: liveStatus) })
    }

    static func isActive(
        group: DuplicateGroup,
        groups: [DuplicateGroup],
        liveStatus: LiveCodexStatus?
    ) -> Bool {
        activeGroup(groups: groups, liveStatus: liveStatus)?.id == group.id
    }

    static func compactSortedGroups(
        groups: [DuplicateGroup],
        statusesByTrackingKey: [String: AccountStatus],
        sort: CompactSidebarSort,
        now: Date = Date()
    ) -> [DuplicateGroup] {
        groups.sorted { lhs, rhs in
            let leftStatus = statusesByTrackingKey[lhs.trackingKey]
            let rightStatus = statusesByTrackingKey[rhs.trackingKey]

            switch sort {
            case .nameAscending:
                return compareNames(lhs, rhs)
            case .fiveHourRemainingMost:
                return compareOptionalInts(
                    left: effectiveFiveHourRemainingPercent(status: leftStatus),
                    right: effectiveFiveHourRemainingPercent(status: rightStatus),
                    descending: true,
                    lhs: lhs,
                    rhs: rhs
                )
            case .fiveHourRemainingLeast:
                return compareOptionalInts(
                    left: effectiveFiveHourRemainingPercent(status: leftStatus),
                    right: effectiveFiveHourRemainingPercent(status: rightStatus),
                    descending: false,
                    lhs: lhs,
                    rhs: rhs
                )
            case .weeklyRemainingMost:
                return compareOptionalInts(
                    left: remainingPercent(fromUsedPercent: leftStatus?.weeklyUsagePercent),
                    right: remainingPercent(fromUsedPercent: rightStatus?.weeklyUsagePercent),
                    descending: true,
                    lhs: lhs,
                    rhs: rhs
                )
            case .weeklyRemainingLeast:
                return compareOptionalInts(
                    left: remainingPercent(fromUsedPercent: leftStatus?.weeklyUsagePercent),
                    right: remainingPercent(fromUsedPercent: rightStatus?.weeklyUsagePercent),
                    descending: false,
                    lhs: lhs,
                    rhs: rhs
                )
            case .fiveHourResetShortest:
                return compareOptionalDates(
                    left: leftStatus?.shortWindowResetAt,
                    right: rightStatus?.shortWindowResetAt,
                    descending: false,
                    now: now,
                    lhs: lhs,
                    rhs: rhs
                )
            case .fiveHourResetLongest:
                return compareOptionalDates(
                    left: leftStatus?.shortWindowResetAt,
                    right: rightStatus?.shortWindowResetAt,
                    descending: true,
                    now: now,
                    lhs: lhs,
                    rhs: rhs
                )
            case .weeklyResetShortest:
                return compareOptionalDates(
                    left: leftStatus?.weeklyResetAt,
                    right: rightStatus?.weeklyResetAt,
                    descending: false,
                    now: now,
                    lhs: lhs,
                    rhs: rhs
                )
            case .weeklyResetLongest:
                return compareOptionalDates(
                    left: leftStatus?.weeklyResetAt,
                    right: rightStatus?.weeklyResetAt,
                    descending: true,
                    now: now,
                    lhs: lhs,
                    rhs: rhs
                )
            }
        }
    }

    static func sectionedGroups(
        groups: [DuplicateGroup],
        statusesByTrackingKey: [String: AccountStatus],
        separatesFullyUsedGroups: Bool
    ) -> SidebarGroupSections {
        guard separatesFullyUsedGroups else {
            return SidebarGroupSections(
                primaryGroups: groups,
                fiveHourUsedGroups: [],
                fullyUsedGroups: []
            )
        }

        var primaryGroups: [DuplicateGroup] = []
        var fiveHourUsedGroups: [DuplicateGroup] = []
        var fullyUsedGroups: [DuplicateGroup] = []

        for group in groups {
            let status = statusesByTrackingKey[group.trackingKey]

            if isWeeklyUsedUp(status) {
                fullyUsedGroups.append(group)
            } else if isFiveHourUsedUp(status) {
                fiveHourUsedGroups.append(group)
            } else {
                primaryGroups.append(group)
            }
        }

        return SidebarGroupSections(
            primaryGroups: primaryGroups,
            fiveHourUsedGroups: fiveHourUsedGroups,
            fullyUsedGroups: fullyUsedGroups
        )
    }

    private static func isFiveHourUsedUp(_ status: AccountStatus?) -> Bool {
        guard !isWeeklyUsedUp(status) else {
            return false
        }

        return QuotaAvailabilityPolicy.blocksShortWindow(usedPercent: status?.shortWindowUsagePercent)
    }

    private static func isFiveHourWindowBlocked(
        status: AccountStatus?,
        usedPercent: Int
    ) -> Bool {
        guard status?.availableNow == false else {
            return false
        }
        return QuotaAvailabilityPolicy.blocksShortWindow(usedPercent: usedPercent)
            || isWeeklyBlockingFiveHourWindow(status)
    }

    private static func isWeeklyBlockingFiveHourWindow(_ status: AccountStatus?) -> Bool {
        guard status?.availableNow == false else {
            return false
        }
        return isWeeklyUsedUp(status)
    }

    private static func isWeeklyUsedUp(_ status: AccountStatus?) -> Bool {
        QuotaAvailabilityPolicy.blocksWeeklyWindow(usedPercent: status?.weeklyUsagePercent)
    }

    private static func compareOptionalInts(
        left: Int?,
        right: Int?,
        descending: Bool,
        lhs: DuplicateGroup,
        rhs: DuplicateGroup
    ) -> Bool {
        switch (left, right) {
        case let (left?, right?) where left != right:
            return descending ? left > right : left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return compareNames(lhs, rhs)
        }
    }

    private static func compareOptionalDates(
        left: Date?,
        right: Date?,
        descending: Bool,
        now: Date,
        lhs: DuplicateGroup,
        rhs: DuplicateGroup
    ) -> Bool {
        let leftInterval = left.map { max(0, $0.timeIntervalSince(now)) }
        let rightInterval = right.map { max(0, $0.timeIntervalSince(now)) }

        switch (leftInterval, rightInterval) {
        case let (left?, right?) where left != right:
            return descending ? left > right : left < right
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return compareNames(lhs, rhs)
        }
    }

    private static func compareNames(_ lhs: DuplicateGroup, _ rhs: DuplicateGroup) -> Bool {
        let leftName = lhs.primaryRecord.identity.name
        let rightName = rhs.primaryRecord.identity.name
        let comparison = leftName.localizedCaseInsensitiveCompare(rightName)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }

        let leftUseLabel = lhs.primaryRecord.identity.useLabel ?? ""
        let rightUseLabel = rhs.primaryRecord.identity.useLabel ?? ""
        let useLabelComparison = leftUseLabel.localizedCaseInsensitiveCompare(rightUseLabel)
        if useLabelComparison != .orderedSame {
            return useLabelComparison == .orderedAscending
        }

        return lhs.primaryRecord.relativeFolderPath.localizedCaseInsensitiveCompare(rhs.primaryRecord.relativeFolderPath) == .orderedAscending
    }

    private static func isFreePlan(
        trackingKey: String,
        groupsByTrackingKey: [String: DuplicateGroup],
        liveStatus: LiveCodexStatus?
    ) -> Bool {
        let livePlanType: String? = if liveStatus?.trackingKey == trackingKey {
            liveStatus?.planType
        } else {
            nil
        }
        let savedPlanType = groupsByTrackingKey[trackingKey]?.primaryRecord.planType
        let normalizedPlanType = (livePlanType ?? savedPlanType)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedPlanType == "free"
    }

    private static func accountTypeLabel(
        trackingKey: String,
        groupsByTrackingKey: [String: DuplicateGroup],
        liveStatus: LiveCodexStatus?
    ) -> String {
        let livePlanType: String? = if liveStatus?.trackingKey == trackingKey {
            liveStatus?.planType
        } else {
            nil
        }

        return accountTypeLabel(
            from: knownPlanType(livePlanType) ?? knownPlanType(groupsByTrackingKey[trackingKey]?.primaryRecord.planType)
        )
    }

    private static func accountTypeLabel(from planType: String?) -> String {
        guard let normalizedPlanType = AuthStoreDestinationPlanner.normalizedPlanType(planType),
              !normalizedPlanType.isEmpty else {
            return "Unknown"
        }

        switch normalizedPlanType {
        case "workplace":
            return "Team"
        default:
            return normalizedPlanType.capitalized
        }
    }

    private static func knownPlanType(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func uniqueQuotaStatuses(
        groups: [DuplicateGroup],
        statusesByTrackingKey: [String: AccountStatus],
        liveStatus: LiveCodexStatus?,
        currentLiveStatus: AccountStatus?
    ) -> [String: AccountStatus] {
        var uniqueStatuses: [String: AccountStatus] = [:]

        for group in groups {
            if let status = statusesByTrackingKey[group.trackingKey] {
                uniqueStatuses[group.trackingKey] = status
            }
        }

        if let liveStatus, let currentLiveStatus, uniqueStatuses[liveStatus.trackingKey] == nil {
            uniqueStatuses[liveStatus.trackingKey] = currentLiveStatus
        }

        return uniqueStatuses
    }

    private static func returningUsagePercent(_ percent: Int?) -> Int? {
        guard let percent, percent > 0 else {
            return nil
        }
        return percent
    }

    private static func futureReset(_ resetAt: Date?, now: Date) -> Date? {
        guard let resetAt, resetAt > now else {
            return nil
        }
        return resetAt
    }
}
