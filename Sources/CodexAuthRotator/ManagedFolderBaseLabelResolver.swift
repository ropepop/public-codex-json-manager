import CodexAuthRotatorCore
import Foundation

enum ManagedFolderBaseLabelResolver {
    static func preferredBaseLabels(
        groups: [DuplicateGroup],
        liveStatus: LiveCodexStatus?
    ) -> [String: String] {
        groups.reduce(into: [String: String]()) { result, group in
            let matchingLiveStatus = liveStatus.flatMap { AuthAccountMatcher.sameAccount(group, as: $0) ? $0 : nil }

            for record in group.records {
                guard let preferredBaseLabel = preferredBaseLabel(
                    for: record,
                    liveStatus: matchingLiveStatus
                ) else {
                    continue
                }

                let currentBaseLabel = record.parsedFolderName.baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard preferredBaseLabel.caseInsensitiveCompare(currentBaseLabel) != .orderedSame else {
                    continue
                }

                result[record.id] = preferredBaseLabel
            }
        }
    }

    static func preferredBaseLabel(
        for record: ScannedAuthRecord,
        liveStatus: LiveCodexStatus?
    ) -> String? {
        let currentBaseLabel = record.parsedFolderName.baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let planType = liveStatus?.planType ?? record.planType
        let workspaceName = liveStatus?.workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard AuthStoreDestinationPlanner.normalizedPlanType(planType) != nil
                || !(workspaceName?.isEmpty ?? true) else {
            return nil
        }

        let kindLabel = AuthStoreDestinationPlanner
            .variantBaseLabel(planType: planType, workspaceName: workspaceName)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !kindLabel.isEmpty else {
            return nil
        }

        if currentBaseLabel.isEmpty || isGenericManagedBaseLabel(currentBaseLabel) {
            return kindLabel
        }

        return AuthStoreDestinationPlanner.sanitizedPathComponent(currentBaseLabel)
    }

    static func fallbackBaseLabel(for record: ScannedAuthRecord) -> String {
        if let useLabel = normalizedNonEmpty(record.identity.useLabel) {
            return AuthStoreDestinationPlanner.sanitizedPathComponent(useLabel)
        }

        if let preferredBaseLabel = preferredBaseLabel(for: record, liveStatus: nil) {
            return preferredBaseLabel
        }

        let currentBaseLabel = record.parsedFolderName.baseLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentBaseLabel.isEmpty, !currentBaseLabel.contains("@") {
            return AuthStoreDestinationPlanner.sanitizedPathComponent(currentBaseLabel)
        }

        return "account"
    }

    private static func isGenericManagedBaseLabel(_ value: String) -> Bool {
        let normalizedValue = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalizedValue == "account" || normalizedValue.hasPrefix("account-")
    }

    private static func normalizedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
