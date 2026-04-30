import CoreGraphics
import Foundation

enum AppPreferenceKey {
    static let splitWeeklyLeftByPlanType = "codexAuthRotator.splitWeeklyLeftByPlanType"
}

enum MainWindowLayout {
    static let autosaveName = "CodexAuthRotator.MainWindow"
    static let splitViewAutosaveName = "CodexAuthRotator.MainSplitView"
    static let defaultWidth: CGFloat = 1420
    static let defaultHeight: CGFloat = 860
    static let minimumWidth: CGFloat = 1220
    static let minimumHeight: CGFloat = 760
    static let sidebarMinimumWidth: CGFloat = 420
    static let sidebarIdealWidth: CGFloat = defaultWidth / 2
    static let sidebarMaximumWidth: CGFloat = 920
}

enum SidebarViewMode: String, CaseIterable {
    case cards
    case compact

    var label: String {
        switch self {
        case .cards:
            return "Cards"
        case .compact:
            return "Compact"
        }
    }

    var systemImage: String {
        switch self {
        case .cards:
            return "rectangle.grid.1x2"
        case .compact:
            return "list.bullet"
        }
    }
}

enum CompactSidebarSort: String, CaseIterable {
    case nameAscending
    case fiveHourRemainingMost
    case fiveHourRemainingLeast
    case weeklyRemainingMost
    case weeklyRemainingLeast
    case fiveHourResetShortest
    case fiveHourResetLongest
    case weeklyResetShortest
    case weeklyResetLongest

    var label: String {
        switch self {
        case .nameAscending:
            return "Name"
        case .fiveHourRemainingMost:
            return "5-Hour Remaining: Most"
        case .fiveHourRemainingLeast:
            return "5-Hour Remaining: Least"
        case .weeklyRemainingMost:
            return "Week Remaining: Most"
        case .weeklyRemainingLeast:
            return "Week Remaining: Least"
        case .fiveHourResetShortest:
            return "5-Hour Reset: Soonest"
        case .fiveHourResetLongest:
            return "5-Hour Reset: Latest"
        case .weeklyResetShortest:
            return "Week Reset: Soonest"
        case .weeklyResetLongest:
            return "Week Reset: Latest"
        }
    }
}

enum CompactSidebarUsageDisplay: String, CaseIterable {
    case remaining
    case used

    var label: String {
        switch self {
        case .remaining:
            return "Usage: Left"
        case .used:
            return "Usage: Used"
        }
    }

    var shortLabel: String {
        switch self {
        case .remaining:
            return "Left"
        case .used:
            return "Used"
        }
    }
}

enum RefreshIntervalOption: String, CaseIterable {
    case seconds15 = "15s"
    case seconds30 = "30s"
    case minute1 = "1m"
    case minutes2 = "2m"
    case minutes5 = "5m"
    case minutes10 = "10m"
    case minutes30 = "30m"
    case minutes60 = "60m"

    var label: String {
        rawValue
    }

    var duration: Duration {
        switch self {
        case .seconds15:
            return .seconds(15)
        case .seconds30:
            return .seconds(30)
        case .minute1:
            return .seconds(60)
        case .minutes2:
            return .seconds(120)
        case .minutes5:
            return .seconds(300)
        case .minutes10:
            return .seconds(600)
        case .minutes30:
            return .seconds(1_800)
        case .minutes60:
            return .seconds(3_600)
        }
    }
}

enum TopControlsRowMode: String, CaseIterable {
    case automatic = "auto"
    case oneRow = "1"
    case twoRows = "2"
    case threeRows = "3"

    var label: String {
        switch self {
        case .automatic:
            return "Rows: Auto"
        case .oneRow:
            return "Rows: 1"
        case .twoRows:
            return "Rows: 2"
        case .threeRows:
            return "Rows: 3"
        }
    }

    var shortLabel: String {
        switch self {
        case .automatic:
            return "Auto"
        case .oneRow:
            return "1 Row"
        case .twoRows:
            return "2 Rows"
        case .threeRows:
            return "3 Rows"
        }
    }

    var maximumRows: Int? {
        switch self {
        case .automatic:
            return nil
        case .oneRow:
            return 1
        case .twoRows:
            return 2
        case .threeRows:
            return 3
        }
    }
}
