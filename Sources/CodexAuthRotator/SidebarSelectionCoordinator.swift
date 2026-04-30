import Foundation

enum SidebarSelectionCoordinator {
    static func clickSelection(
        currentSelection: Set<String>,
        clickedGroupID: String,
        currentPrimaryGroupID: String?,
        orderedGroupIDs: [String],
        extendsRange: Bool,
        togglesMembership: Bool
    ) -> Set<String> {
        if extendsRange {
            let anchorGroupID = currentPrimaryGroupID.flatMap { primaryGroupID in
                orderedGroupIDs.contains(primaryGroupID) ? primaryGroupID : nil
            } ?? orderedGroupIDs.first { currentSelection.contains($0) }
            return rangeSelection(
                anchorGroupID: anchorGroupID,
                targetGroupID: clickedGroupID,
                orderedGroupIDs: orderedGroupIDs
            )
        }

        if togglesMembership {
            var nextSelection = currentSelection
            if nextSelection.contains(clickedGroupID) {
                if nextSelection.count > 1 {
                    nextSelection.remove(clickedGroupID)
                }
            } else {
                nextSelection.insert(clickedGroupID)
            }
            return nextSelection
        }

        return [clickedGroupID]
    }

    static func rangeSelection(
        anchorGroupID: String?,
        targetGroupID: String,
        orderedGroupIDs: [String]
    ) -> Set<String> {
        guard let anchorGroupID,
              let anchorIndex = orderedGroupIDs.firstIndex(of: anchorGroupID),
              let targetIndex = orderedGroupIDs.firstIndex(of: targetGroupID) else {
            return [targetGroupID]
        }

        let range = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(orderedGroupIDs[range])
    }

    static func visibleSelection(
        currentSelection: Set<String>,
        currentPrimaryGroupID: String?,
        orderedVisibleGroupIDs: [String]
    ) -> Set<String> {
        let visibleGroupIDs = Set(orderedVisibleGroupIDs)
        let filteredSelection = currentSelection.intersection(visibleGroupIDs)

        if !filteredSelection.isEmpty {
            return filteredSelection
        }

        if let currentPrimaryGroupID,
           visibleGroupIDs.contains(currentPrimaryGroupID) {
            return [currentPrimaryGroupID]
        }

        guard let firstVisibleGroupID = orderedVisibleGroupIDs.first else {
            return []
        }

        return [firstVisibleGroupID]
    }

    static func primaryGroupID(
        for newSelection: Set<String>,
        previousSelection: Set<String>,
        currentPrimaryGroupID: String?,
        orderedGroupIDs: [String]
    ) -> String? {
        guard !newSelection.isEmpty else {
            return nil
        }

        if newSelection.count == 1 {
            return newSelection.first
        }

        let addedGroupIDs = orderedGroupIDs.filter { newSelection.contains($0) && !previousSelection.contains($0) }
        if !addedGroupIDs.isEmpty {
            if let currentPrimaryGroupID,
               let currentIndex = orderedGroupIDs.firstIndex(of: currentPrimaryGroupID) {
                return addedGroupIDs.max { lhs, rhs in
                    let leftDistance = abs((orderedGroupIDs.firstIndex(of: lhs) ?? currentIndex) - currentIndex)
                    let rightDistance = abs((orderedGroupIDs.firstIndex(of: rhs) ?? currentIndex) - currentIndex)
                    return leftDistance < rightDistance
                }
            }

            return addedGroupIDs.last
        }

        if let currentPrimaryGroupID, newSelection.contains(currentPrimaryGroupID) {
            return currentPrimaryGroupID
        }

        return orderedGroupIDs.first(where: newSelection.contains)
    }

    static func queueSelection(
        existingSelection: Set<String>,
        sidebarSelection: Set<String>,
        hasSidebarSelection: Bool,
        validTrackingKeys: Set<String>,
        fallbackTrackingKey: String?
    ) -> Set<String> {
        let sanitizedExistingSelection = existingSelection.intersection(validTrackingKeys)
        let sanitizedSidebarSelection = sidebarSelection.intersection(validTrackingKeys)

        if hasSidebarSelection {
            return sanitizedSidebarSelection
        }

        if !sanitizedExistingSelection.isEmpty {
            return sanitizedExistingSelection
        }

        guard let fallbackTrackingKey, validTrackingKeys.contains(fallbackTrackingKey) else {
            return []
        }

        return [fallbackTrackingKey]
    }

    static func orderedQueueTrackingKeys(
        selection: Set<String>,
        orderedTrackingKeys: [String]
    ) -> [String] {
        orderedTrackingKeys.filter { selection.contains($0) }
    }
}
