import CodexAuthRotatorCore
import Foundation

enum SidebarListPresentation {
    case searchResults([DuplicateGroup])
    case sectioned(SidebarGroupSections)

    static func make(
        isSearchActive: Bool,
        filteredGroups: [DuplicateGroup],
        sectionedGroups: SidebarGroupSections
    ) -> SidebarListPresentation {
        if isSearchActive {
            return .searchResults(filteredGroups)
        }

        return .sectioned(sectionedGroups)
    }

    var showsHeaderPanel: Bool {
        switch self {
        case .searchResults:
            return false
        case .sectioned:
            return true
        }
    }

    var orderedGroups: [DuplicateGroup] {
        switch self {
        case .searchResults(let groups):
            return groups
        case .sectioned(let sections):
            return sections.primaryGroups + sections.fiveHourUsedGroups + sections.fullyUsedGroups
        }
    }
}
