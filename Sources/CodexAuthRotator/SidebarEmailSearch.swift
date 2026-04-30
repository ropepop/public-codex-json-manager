import CodexAuthRotatorCore
import Foundation

enum SidebarEmailSearch {
    static func filteredGroups(
        _ groups: [DuplicateGroup],
        query: String
    ) -> [DuplicateGroup] {
        guard let normalizedQuery = normalizedQuery(query) else {
            return groups
        }

        return groups.filter { matches($0, normalizedQuery: normalizedQuery) }
    }

    static func normalizedQuery(_ query: String) -> String? {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return nil
        }
        return trimmedQuery.lowercased()
    }

    static func matches(_ group: DuplicateGroup, query: String) -> Bool {
        guard let normalizedQuery = normalizedQuery(query) else {
            return true
        }
        return matches(group, normalizedQuery: normalizedQuery)
    }

    private static func matches(
        _ group: DuplicateGroup,
        normalizedQuery: String
    ) -> Bool {
        group.primaryRecord.identity.name.lowercased().contains(normalizedQuery)
    }
}
