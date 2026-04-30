@testable import CodexAuthRotator
import CodexAuthRotatorCore
import Foundation
import Testing

@Test
func usageReturnItemsShowKindAccountTypePercentAndTimerData() {
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let alpha = usageMenuSampleGroup(
        trackingKey: "user:user-alpha|account:acct-alpha",
        accountID: "acct-alpha",
        folderName: "alpha@example.com",
        planType: "plus"
    )
    let beta = usageMenuSampleGroup(
        trackingKey: "user:user-beta|account:acct-beta",
        accountID: "acct-beta",
        folderName: "beta@example.com",
        planType: "free"
    )
    let statuses = [
        alpha.trackingKey: usageMenuSampleStatus(
            now: now,
            weeklyUsagePercent: 80,
            weeklyResetAt: now.addingTimeInterval(2 * 60 * 60),
            shortWindowUsagePercent: 97,
            shortWindowResetAt: now.addingTimeInterval(30 * 60)
        ),
        beta.trackingKey: usageMenuSampleStatus(
            now: now,
            weeklyUsagePercent: 30,
            weeklyResetAt: now.addingTimeInterval(60 * 60),
            shortWindowUsagePercent: 0,
            shortWindowResetAt: now.addingTimeInterval(40 * 60)
        ),
    ]

    let items = SidebarPresentation.usageReturnItems(
        groups: [alpha, beta],
        statusesByTrackingKey: statuses,
        liveStatus: nil,
        currentLiveStatus: nil,
        now: now
    )

    #expect(items.map(\.kind) == [.fiveHour, .weekly, .weekly])
    #expect(items.map(\.accountType) == ["Plus", "Free", "Plus"])
    #expect(items.map(\.usedPercent) == [97, 30, 80])
    #expect(items.map { StatusDisplayFormatter.countdownLabel(until: $0.resetAt, now: now) } == [
        "00:30:00",
        "01:00:00",
        "02:00:00",
    ])
}

@Test
func usageReturnItemsIncludeUntrackedLiveStatus() {
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let liveStatus = LiveCodexStatus(
        accountID: "acct-live",
        trackingKey: "user:user-live|account:acct-live",
        email: "live@example.com",
        planType: "team",
        authFingerprint: "fingerprint-live",
        snapshot: nil,
        source: .oauth
    )
    let currentLiveStatus = usageMenuSampleStatus(
        now: now,
        weeklyUsagePercent: 42,
        weeklyResetAt: now.addingTimeInterval(3 * 24 * 60 * 60 + 4 * 60 * 60 + 5 * 60 + 6),
        shortWindowUsagePercent: nil,
        shortWindowResetAt: nil
    )

    let items = SidebarPresentation.usageReturnItems(
        groups: [],
        statusesByTrackingKey: [:],
        liveStatus: liveStatus,
        currentLiveStatus: currentLiveStatus,
        now: now
    )

    #expect(items.count == 1)
    #expect(items[0].kind == .weekly)
    #expect(items[0].accountType == "Team")
    #expect(items[0].usedPercent == 42)
    #expect(StatusDisplayFormatter.countdownLabel(until: items[0].resetAt, now: now) == "3d 04:05:06")
}

private func usageMenuSampleStatus(
    now: Date,
    weeklyUsagePercent: Int?,
    weeklyResetAt: Date?,
    shortWindowUsagePercent: Int?,
    shortWindowResetAt: Date?
) -> AccountStatus {
    AccountStatus(
        source: .cached,
        capturedAt: now,
        availableNow: true,
        nextAvailabilityAt: nil,
        weeklyUsagePercent: weeklyUsagePercent,
        weeklyResetAt: weeklyResetAt,
        shortWindowUsagePercent: shortWindowUsagePercent,
        shortWindowResetAt: shortWindowResetAt,
        rawFolderResetToken: nil,
        weeklyWindowState: (weeklyUsagePercent != nil || weeklyResetAt != nil) ? .current : .needsRefresh,
        shortWindowState: (shortWindowUsagePercent != nil || shortWindowResetAt != nil) ? .current : .needsRefresh
    )
}

private func usageMenuSampleGroup(
    trackingKey: String,
    accountID: String,
    folderName: String,
    planType: String? = nil
) -> DuplicateGroup {
    let parsed = FolderNameParser.parse(folderName)
    let record = ScannedAuthRecord(
        id: "\(trackingKey)|\(folderName)",
        authFileURL: URL(fileURLWithPath: "/tmp/\(folderName)/auth.json"),
        folderURL: URL(fileURLWithPath: "/tmp/\(folderName)", isDirectory: true),
        relativeFolderPath: "\(folderName)/\(folderName)",
        topLevelFolderName: folderName,
        folderName: folderName,
        parsedFolderName: parsed,
        identity: DisplayIdentity(name: folderName, useLabel: nil),
        trackingKey: trackingKey,
        accountID: accountID,
        authFingerprint: "fingerprint-\(accountID)",
        planType: planType
    )
    return DuplicateGroup(
        authFingerprint: record.authFingerprint,
        trackingKey: trackingKey,
        accountID: accountID,
        records: [record]
    )
}
