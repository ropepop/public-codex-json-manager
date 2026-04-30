import Foundation

public enum AuthAccountMatcher {
    public static func sameAccount(_ group: DuplicateGroup, as liveStatus: LiveCodexStatus) -> Bool {
        sameAccount(
            lhsTrackingKey: group.trackingKey,
            lhsAccountID: group.accountID,
            rhsTrackingKey: liveStatus.trackingKey,
            rhsAccountID: liveStatus.accountID
        )
    }

    public static func sameAccount(_ identity: ResolvedAuthIdentity, as liveStatus: LiveCodexStatus) -> Bool {
        sameAccount(
            lhsTrackingKey: identity.trackingKey,
            lhsAccountID: identity.accountID,
            rhsTrackingKey: liveStatus.trackingKey,
            rhsAccountID: liveStatus.accountID
        )
    }

    public static func sameAccount(_ lhs: ResolvedAuthIdentity, as rhs: ResolvedAuthIdentity) -> Bool {
        sameAccount(
            lhsTrackingKey: lhs.trackingKey,
            lhsAccountID: lhs.accountID,
            rhsTrackingKey: rhs.trackingKey,
            rhsAccountID: rhs.accountID
        )
    }

    public static func preferredSavedGroup(
        for liveStatus: LiveCodexStatus,
        in groups: [DuplicateGroup]
    ) -> DuplicateGroup? {
        if let exactCopy = groups.first(where: { group in
            group.records.contains(where: { $0.authFingerprint == liveStatus.authFingerprint })
        }) {
            return exactCopy
        }

        return groups.first(where: { sameAccount($0, as: liveStatus) })
    }

    public static func accountID(from trackingKey: String) -> String? {
        guard let range = trackingKey.range(of: "account:", options: .backwards) else {
            return nil
        }

        let accountID = trackingKey[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return accountID.isEmpty ? nil : String(accountID)
    }

    private static func allowsAccountIDFallback(_ trackingKey: String) -> Bool {
        !trackingKey.contains("user:") && !trackingKey.contains("email:")
    }

    private static func sameAccount(
        lhsTrackingKey: String,
        lhsAccountID: String,
        rhsTrackingKey: String,
        rhsAccountID: String
    ) -> Bool {
        if lhsTrackingKey == rhsTrackingKey {
            return true
        }

        guard allowsAccountIDFallback(lhsTrackingKey) || allowsAccountIDFallback(rhsTrackingKey) else {
            return false
        }
        return lhsAccountID == rhsAccountID
    }
}
