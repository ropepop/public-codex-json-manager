import CodexAuthRotatorCore
import Foundation
import Testing
import Darwin

@Test
func folderParserKeepsLooseHumanTextAndManagedSuffix() {
    let parsed = FolderNameParser.parse("personal trial till 26:03  w100 till 29")

    #expect(parsed.baseLabel == "personal trial till 26:03")
    #expect(parsed.weeklyUsage == 100)
    #expect(parsed.resetToken == "till 29")
}

@Test
func folderParserStripsRepeatedManagedSuffixesBeforeRewriting() {
    let parsed = FolderNameParser.parse("catsim trial till 24∕04 w18 till 12∕04 w18 till 12∕04 w18 till 12∕04")

    #expect(parsed.baseLabel == "catsim trial till 24∕04")
    #expect(parsed.weeklyUsage == 18)
    #expect(parsed.resetToken == "till 12∕04")
}

@Test
func folderParserReadsTrailingAccountType() {
    let parsed = FolderNameParser.parse("primary plus 5hr18 08.04-01:15 wk44 15.04")

    #expect(parsed.baseLabel == "primary plus")
    #expect(parsed.accountType == "plus")
    #expect(parsed.shortWindowUsage == 18)
    #expect(parsed.weeklyUsage == 44)
}

@Test
func folderBuilderStoresCanonicalAccountTypeBeforeUsageSuffixes() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let weeklyReset = calendar.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 12, minute: 0))!

    let built = FolderNameParser.buildFolderName(
        baseLabel: "primary personal",
        accountType: "pro",
        shortWindowUsage: nil,
        shortWindowResetAt: nil,
        weeklyUsage: 44,
        weeklyResetAt: weeklyReset,
        now: now,
        calendar: calendar
    )
    let parsed = FolderNameParser.parse(built)

    #expect(built == "primary plus wk44 15.04")
    #expect(parsed.baseLabel == "primary plus")
    #expect(parsed.accountType == "plus")
    #expect(parsed.weeklyUsage == 44)
}

@Test
func authScannerUsesFolderAccountTypeAsSavedSourceOfTruth() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let authURL = root.appendingPathComponent("saved/primary free/auth.json")
    try writeAuth(
        authURL,
        payload: authPayload(
            accountID: "acct-folder-type",
            tokenSeed: "folder-type",
            userID: "user-folder-type",
            email: "folder-type@example.com",
            planType: "plus"
        )
    )

    let group = try #require(AuthScanner().scan(root: root).first)

    #expect(group.primaryRecord.parsedFolderName.accountType == "free")
    #expect(group.primaryRecord.planType == "free")
}

@Test
func folderBuilderPreservesFutureWeeklyResetClockTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_606_400) // 2026-04-08 00:00 UTC
    let sameDayReset = now.addingTimeInterval(4 * 60 * 60 + 15 * 60)
    let laterReset = calendar.date(from: DateComponents(year: 2026, month: 4, day: 13, hour: 4, minute: 0))!

    #expect(
        FolderNameParser.buildFolderName(baseLabel: "personal free", weeklyUsage: 58, weeklyResetAt: sameDayReset, now: now, calendar: calendar)
            == "personal free wk58 08.04-04:15"
    )
    #expect(
        FolderNameParser.buildFolderName(baseLabel: "personal free", weeklyUsage: 58, weeklyResetAt: laterReset, now: now, calendar: calendar)
            == "personal free wk58 13.04-04:00"
    )
    #expect(
        FolderNameParser.interpretedResetDate(from: "13.04-04:00", now: now, calendar: calendar)
            == laterReset
    )
}

@Test
func folderBuilderKeepsNoonWeeklyResetAsDateOnly() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_606_400) // 2026-04-08 00:00 UTC
    let noonReset = calendar.date(from: DateComponents(year: 2026, month: 4, day: 13, hour: 12, minute: 0))!

    #expect(
        FolderNameParser.buildFolderName(baseLabel: "personal free", weeklyUsage: 58, weeklyResetAt: noonReset, now: now, calendar: calendar)
            == "personal free wk58 13.04"
    )
}

@Test
func folderParserAndBuilderSupportDualWindowManagedSuffixes() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let hourlyReset = now.addingTimeInterval(75 * 60)
    let weeklyReset = calendar.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 12, minute: 0))!

    let built = FolderNameParser.buildFolderName(
        baseLabel: "team",
        shortWindowUsage: 68,
        shortWindowResetAt: hourlyReset,
        weeklyUsage: 67,
        weeklyResetAt: weeklyReset,
        now: now,
        calendar: calendar
    )
    let parsed = FolderNameParser.parse(built)

    #expect(built == "team 5hr68 08.04-01:15 wk67 15.04")
    #expect(parsed.baseLabel == "team")
    #expect(parsed.shortWindowUsage == 68)
    #expect(parsed.shortWindowResetToken == "08.04-01:15")
    #expect(parsed.weeklyUsage == 67)
    #expect(parsed.weeklyResetToken == "15.04")
}

@Test
func folderBuilderKeepsZeroShortWindowWhenResetIsKnown() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let hourlyReset = now.addingTimeInterval(75 * 60)
    let weeklyReset = calendar.date(from: DateComponents(year: 2026, month: 4, day: 15, hour: 12, minute: 0))!

    let built = FolderNameParser.buildFolderName(
        baseLabel: "team",
        shortWindowUsage: 0,
        shortWindowResetAt: hourlyReset,
        weeklyUsage: 67,
        weeklyResetAt: weeklyReset,
        now: now,
        calendar: calendar
    )
    let parsed = FolderNameParser.parse(built)

    #expect(built == "team 5hr0 08.04-01:15 wk67 15.04")
    #expect(parsed.shortWindowUsage == 0)
    #expect(parsed.shortWindowResetToken == "08.04-01:15")
}

@Test
func folderBuilderFormatsNextDayShortWindowResetAsDatedTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 22, minute: 30))!
    let hourlyReset = calendar.date(from: DateComponents(year: 2026, month: 4, day: 9, hour: 3, minute: 15))!

    let built = FolderNameParser.buildFolderName(
        baseLabel: "team",
        shortWindowUsage: 97,
        shortWindowResetAt: hourlyReset,
        weeklyUsage: nil,
        weeklyResetAt: nil,
        now: now,
        calendar: calendar
    )

    #expect(built == "team 5hr97 09.04-03:15")
    #expect(
        FolderNameParser.interpretedResetDate(
            from: "09.04-03:15",
            now: now,
            calendar: calendar,
            interpretation: .shortWindow
        ) == hourlyReset
    )
}

@Test
func quotaSnapshotTreatsSingleLongWindowAsWeeklyQuota() {
    let event = CodexRateLimitEvent(
        type: "codex.rate_limits",
        planType: "free",
        rateLimits: RateLimitsPayload(
            allowed: true,
            limitReached: false,
            primary: RateLimitWindow(
                usedPercent: 82,
                windowMinutes: 10_080,
                resetAfterSeconds: 604_800,
                resetAt: 1_776_254_400
            ),
            secondary: nil
        )
    )

    let snapshot = QuotaSnapshot(event: event, capturedAt: Date(timeIntervalSince1970: 1_775_606_400))

    #expect(snapshot?.primaryUsedPercent == nil)
    #expect(snapshot?.primaryWindowMinutes == nil)
    #expect(snapshot?.secondaryUsedPercent == 82)
    #expect(snapshot?.secondaryWindowMinutes == 10_080)
}

@Test
func quotaSnapshotOrdersTwoWindowsByDuration() {
    let event = CodexRateLimitEvent(
        type: "codex.rate_limits",
        planType: "plus",
        rateLimits: RateLimitsPayload(
            allowed: true,
            limitReached: false,
            primary: RateLimitWindow(
                usedPercent: 41,
                windowMinutes: 10_080,
                resetAfterSeconds: 604_800,
                resetAt: 1_776_254_400
            ),
            secondary: RateLimitWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetAfterSeconds: 18_000,
                resetAt: 1_775_607_000
            )
        )
    )

    let snapshot = QuotaSnapshot(event: event, capturedAt: Date(timeIntervalSince1970: 1_775_606_400))

    #expect(snapshot?.primaryUsedPercent == 12)
    #expect(snapshot?.primaryWindowMinutes == 300)
    #expect(snapshot?.secondaryUsedPercent == 41)
    #expect(snapshot?.secondaryWindowMinutes == 10_080)
}

@Test
func resetDisplayTreatsTillPrefixedLegacyColonValuesAsDates() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_606_400) // 2026-04-08 00:00 UTC

    #expect(
        FolderNameParser.displayReset("till 12:04", now: now, calendar: calendar)
            == "12.04"
    )
}

@Test
func resetDisplayPromotesPastTodayColonValuesToFutureDatesWhenPlausible() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_665_080) // 2026-04-08 16:18 UTC

    #expect(
        FolderNameParser.displayReset("13:04", now: now, calendar: calendar)
            == "13.04"
    )
}

@Test
func resetDisplayKeepsFutureSameDayTimeWhenItIsStillAhead() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_642_400) // 2026-04-08 10:00 UTC

    #expect(
        FolderNameParser.displayReset("13:04", now: now, calendar: calendar)
            == "13:04"
    )
}

@Test
func shortWindowResetDisplayKeepsPastClockTimeAsTime() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_665_080) // 2026-04-08 16:18 UTC

    #expect(
        FolderNameParser.displayReset("13:04", now: now, calendar: calendar, interpretation: .shortWindow)
            == "13:04"
    )
}

@Test
func shortWindowResetDisplayShowsDateWhenTokenIncludesDate() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_775_665_080) // 2026-04-08 16:18 UTC

    #expect(
        FolderNameParser.displayReset("09.04-22:00", now: now, calendar: calendar, interpretation: .shortWindow)
            == "22:00 09.04"
    )
}

@Test
func shortWindowResetParserRollsNearMidnightClockTimeForwardWithinWindow() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 22, minute: 30))!

    let parsed = FolderNameParser.interpretedResetDate(
        from: "03:15",
        now: now,
        calendar: calendar,
        interpretation: .shortWindow
    )

    #expect(parsed == calendar.date(from: DateComponents(year: 2026, month: 4, day: 9, hour: 3, minute: 15)))
}

@Test
func inferIdentityUsesOnlyEmailAsPrimaryNameForRootLevelManagedFolder() {
    let identity = FolderNameParser.inferIdentity(
        topLevelFolderName: "ante-grabby.4n@icloud.com free w100 11:04",
        baseLabel: "ante-grabby.4n@icloud.com free"
    )

    #expect(identity.name == "ante-grabby.4n@icloud.com")
    #expect(identity.useLabel == "free")
}

@Test
func inferIdentityKeepsChildLabelWhenTopLevelFolderContainsManagedSuffix() {
    let identity = FolderNameParser.inferIdentity(
        topLevelFolderName: "iamb.hide-0e@icloud.com w100 06:04",
        baseLabel: "free personal"
    )

    #expect(identity.name == "iamb.hide-0e@icloud.com")
    #expect(identity.useLabel == "free personal")
}

@Test
func scannerGroupsExactDuplicateFilesButKeepsDifferentRealAccountsSeparate() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let duplicatePayload = authPayload(accountID: "acct-shared", tokenSeed: "shared")
    let distinctPayload = authPayload(accountID: "acct-team", tokenSeed: "team", userID: "user-team", email: "team@example.com")

    try writeAuth(root.appendingPathComponent("a/person w10 11:04/auth.json"), payload: duplicatePayload)
    try writeAuth(root.appendingPathComponent("b/person copy w10 11:04/auth.json"), payload: duplicatePayload)
    try writeAuth(root.appendingPathComponent("b/team w20 12:04/auth.json"), payload: distinctPayload)

    let groups = try AuthScanner().scan(root: root)

    #expect(groups.count == 2)
    #expect(groups.first(where: { $0.accountID == "acct-shared" })?.records.count == 2)
    #expect(groups.first(where: { $0.accountID == "acct-team" })?.records.count == 1)
}

@Test
func scannerBuildsDistinctTrackingKeysForSharedTeamAccountIDs() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let catsim = authPayload(
        accountID: "acct-team",
        tokenSeed: "catsim",
        userID: "user-catsim",
        email: "catsimulator@jolkins.id.lv"
    )
    let aleks = authPayload(
        accountID: "acct-team",
        tokenSeed: "aleks",
        userID: "user-aleks",
        email: "aleksjolk@gmail.com"
    )

    try writeAuth(root.appendingPathComponent("catsimulator/catsim/auth.json"), payload: catsim)
    try writeAuth(root.appendingPathComponent("aleks/team/auth.json"), payload: aleks)

    let groups = try AuthScanner().scan(root: root)

    #expect(groups.count == 2)
    #expect(Set(groups.map(\.trackingKey)).count == 2)
}

@Test
func scannerGroupsSameAccountWithDifferentFingerprintsIntoOneRow() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let older = authPayload(
        accountID: "acct-catsim",
        tokenSeed: "older",
        userID: "user-catsim",
        email: "catsimulator@jolkins.id.lv",
        planType: "team"
    )
    let newer = authPayload(
        accountID: "acct-catsim",
        tokenSeed: "newer",
        userID: "user-catsim",
        email: "catsimulator@jolkins.id.lv",
        planType: "team"
    )

    try writeAuth(root.appendingPathComponent("catsimulator@jolkins.id.lv/catsim team/auth.json"), payload: older)
    try writeAuth(root.appendingPathComponent("catsimulator@jolkins.id.lv/team/auth.json"), payload: newer)

    let groups = try AuthScanner().scan(root: root)
    let group = try #require(groups.first)

    #expect(groups.count == 1)
    #expect(group.records.count == 2)
    #expect(group.trackingKey == "user:user-catsim|account:acct-catsim")
}

@Test
func scannerPrefersResolvedAuthEmailOverStaleFolderParentName() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    try writeAuth(
        root.appendingPathComponent("aleksjolk@gmail.com/team 22dd878e/auth.json"),
        payload: authPayload(
            accountID: "acct-team",
            tokenSeed: "team",
            userID: "user-team",
            email: "catsimulator@jolkins.id.lv",
            planType: "team"
        )
    )

    let group = try #require(AuthScanner().scan(root: root).first)

    #expect(group.primaryRecord.identity.name == "catsimulator@jolkins.id.lv")
    #expect(group.primaryRecord.identity.useLabel == "team 22dd878e")
}

@Test
func liveStatusWinsWhileSavedRowsStillUseFolderNames() {
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
    let shortReset = now.addingTimeInterval(2 * 60 * 60)

    let record = sampleGroup(
        accountID: "acct-live",
        fingerprint: "fingerprint-live",
        folderName: "personal free w41 till 13:04"
    )
    let inactive = sampleGroup(
        accountID: "acct-cached",
        fingerprint: "fingerprint-cached",
        folderName: "catsim w58 till 15:04"
    )

    let liveSnapshot = QuotaSnapshot(
        capturedAt: now,
        allowed: false,
        limitReached: true,
        primaryUsedPercent: 100,
        primaryResetAt: shortReset,
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 41,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let cachedSnapshot = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-3_600),
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 20,
        primaryResetAt: now.addingTimeInterval(-600),
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 58,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolve(
        groups: [record, inactive],
        liveStatus: LiveCodexStatus(
            accountID: "acct-live",
            trackingKey: "account:acct-live",
            email: nil,
            planType: nil,
            authFingerprint: "fingerprint-live",
            snapshot: liveSnapshot,
            source: .oauth
        ),
        snapshotsByTrackingKey: ["account:acct-cached": cachedSnapshot],
        now: now
    )

    #expect(statuses["account:acct-live"]?.source == .oauth)
    #expect(statuses["account:acct-live"]?.availableNow == true)
    #expect(statuses["account:acct-live"]?.nextAvailabilityAt == nil)
    #expect(statuses["account:acct-live"]?.shortWindowUsagePercent == nil)
    #expect(statuses["account:acct-live"]?.shortWindowState == .current)
    #expect(statuses["account:acct-live"]?.weeklyUsagePercent == 41)

    #expect(statuses["account:acct-cached"]?.source == .folderName)
    #expect(statuses["account:acct-cached"]?.availableNow == true)
    #expect(statuses["account:acct-cached"]?.weeklyUsagePercent == 58)
}

@Test
func statusResolverMarksFiveHourUsageBeyond96PercentAsCoolingDown() {
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let shortReset = now.addingTimeInterval(45 * 60)
    let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
    let liveGroup = sampleGroup(
        accountID: "acct-threshold",
        fingerprint: "fingerprint-threshold",
        folderName: "team 5h97 00:45 w41 till 10∕04"
    )

    let snapshot = QuotaSnapshot(
        capturedAt: now,
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 97,
        primaryResetAt: shortReset,
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 41,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolve(
        groups: [liveGroup],
        liveStatus: LiveCodexStatus(
            accountID: "acct-threshold",
            trackingKey: liveGroup.trackingKey,
            email: nil,
            planType: nil,
            authFingerprint: liveGroup.authFingerprint,
            snapshot: snapshot,
            source: .oauth
        ),
        snapshotsByTrackingKey: [:],
        now: now
    )

    #expect(statuses[liveGroup.trackingKey]?.shortWindowUsagePercent == 97)
    #expect(statuses[liveGroup.trackingKey]?.availableNow == false)
    #expect(statuses[liveGroup.trackingKey]?.nextAvailabilityAt == shortReset)
}

@Test
func statusResolverAppliesFiveHourCoolingDownThresholdToFolderFallback() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 18, minute: 0))!
    let shortReset = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 18, minute: 30))!
    let coolingRecord = sampleGroup(
        accountID: "acct-folder-cool",
        fingerprint: "fingerprint-folder-cool",
        folderName: "team 5h97 18:30 w41 till 10∕04"
    ).primaryRecord
    let availableRecord = sampleGroup(
        accountID: "acct-folder-ok",
        fingerprint: "fingerprint-folder-ok",
        folderName: "team 5h96 18:30 w41 till 10∕04"
    ).primaryRecord

    let coolingStatus = StatusResolver.resolveStatus(
        trackingKey: "account:acct-folder-cool",
        liveStatus: nil,
        snapshotsByTrackingKey: [:],
        fallbackRecord: coolingRecord,
        now: now,
        calendar: calendar
    )
    let availableStatus = StatusResolver.resolveStatus(
        trackingKey: "account:acct-folder-ok",
        liveStatus: nil,
        snapshotsByTrackingKey: [:],
        fallbackRecord: availableRecord,
        now: now,
        calendar: calendar
    )

    #expect(coolingStatus.availableNow == false)
    #expect(coolingStatus.nextAvailabilityAt == shortReset)
    #expect(availableStatus.availableNow == true)
    #expect(availableStatus.nextAvailabilityAt == nil)
}

@Test
func statusResolverTreatsPastFiveHourResetAsExpiredFolderData() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 19, minute: 0))!
    let expiredRecord = sampleGroup(
        accountID: "acct-folder-expired",
        fingerprint: "fingerprint-folder-expired",
        folderName: "team 5h97 18:30 w41 till 10∕04"
    ).primaryRecord

    let status = StatusResolver.resolveStatus(
        trackingKey: "account:acct-folder-expired",
        liveStatus: nil,
        snapshotsByTrackingKey: [:],
        fallbackRecord: expiredRecord,
        now: now,
        calendar: calendar
    )

    #expect(status.source == .folderName)
    #expect(status.availableNow == true)
    #expect(status.nextAvailabilityAt == nil)
    #expect(status.shortWindowUsagePercent == nil)
    #expect(status.shortWindowResetAt == nil)
    #expect(status.weeklyUsagePercent == 41)
}

@Test
func statusResolverDoesNotPromotePastFiveHourTimeToCalendarDate() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 16, minute: 18))!
    let record = sampleGroup(
        accountID: "acct-folder-ambiguous-time",
        fingerprint: "fingerprint-folder-ambiguous-time",
        folderName: "team 5h97 13:04 w41 till 10∕04"
    ).primaryRecord

    let status = StatusResolver.resolveStatus(
        trackingKey: "account:acct-folder-ambiguous-time",
        liveStatus: nil,
        snapshotsByTrackingKey: [:],
        fallbackRecord: record,
        now: now,
        calendar: calendar
    )

    #expect(status.source == .folderName)
    #expect(status.availableNow == true)
    #expect(status.nextAvailabilityAt == nil)
    #expect(status.shortWindowUsagePercent == nil)
    #expect(status.shortWindowResetAt == nil)
    #expect(status.weeklyUsagePercent == 41)
}

@Test
func statusResolverKeepsZeroShortWindowFromFolderDataWhenResetIsFuture() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 6, minute: 0))!
    let record = sampleGroup(
        accountID: "acct-folder-zero",
        fingerprint: "fingerprint-folder-zero",
        folderName: "team 5hr0 09:27 wk39 16.04"
    ).primaryRecord

    let status = StatusResolver.resolveStatus(
        trackingKey: "account:acct-folder-zero",
        liveStatus: nil,
        snapshotsByTrackingKey: [:],
        fallbackRecord: record,
        now: now,
        calendar: calendar
    )

    #expect(status.source == .folderName)
    #expect(status.availableNow == true)
    #expect(status.shortWindowUsagePercent == 0)
    #expect(status.shortWindowResetAt == calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 9, minute: 27)))
    #expect(status.weeklyUsagePercent == 39)
}

@Test
func statusResolverMarksMissingFolderResetAsUnreadableWhileKeepingCurrentWeek() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 19, minute: 0))!
    let missingResetRecord = sampleGroup(
        accountID: "acct-folder-unknown",
        fingerprint: "fingerprint-folder-unknown",
        folderName: "team 5h97 wk41 10.04"
    ).primaryRecord

    let status = StatusResolver.resolveStatus(
        trackingKey: "account:acct-folder-unknown",
        liveStatus: nil,
        snapshotsByTrackingKey: [:],
        fallbackRecord: missingResetRecord,
        now: now,
        calendar: calendar
    )

    #expect(status.source == .folderName)
    #expect(status.availableNow == nil)
    #expect(status.nextAvailabilityAt == nil)
    #expect(status.shortWindowUsagePercent == nil)
    #expect(status.shortWindowResetAt == nil)
    #expect(status.shortWindowState == .unreadable)
    #expect(status.weeklyUsagePercent == 41)
    #expect(status.weeklyWindowState == .current)
}

@Test
func statusResolverTreatsWeeklyOnlySavedFreeFolderAsCurrentWithoutFiveHourWindow() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let calendar = utcCalendar()
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 11, hour: 7, minute: 13))!
    let authURL = root.appendingPathComponent("sample/personal free wk100 13.04/auth.json")

    try writeAuth(
        authURL,
        payload: authPayload(
            accountID: "acct-weekly-only",
            tokenSeed: "weekly-only",
            userID: "user-weekly-only",
            email: "weekly@example.com",
            planType: "free"
        )
    )

    let group = try #require(AuthScanner().scan(root: root).first)
    let status = StatusResolver.resolveStatus(
        trackingKey: group.trackingKey,
        liveStatus: nil,
        fallbackRecord: group.primaryRecord,
        now: now,
        calendar: calendar
    )

    #expect(status.source == .folderName)
    #expect(status.shortWindowUsagePercent == nil)
    #expect(status.shortWindowResetAt == nil)
    #expect(status.shortWindowState == .current)
    #expect(status.weeklyUsagePercent == 100)
    #expect(status.weeklyWindowState == .current)
    #expect(status.hasNeedsRefreshWindow == false)
}

@Test
func statusResolverTreatsPersonalLabelFreePlanAsWeeklyOnly() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let calendar = utcCalendar()
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 27, hour: 19, minute: 30))!
    let authURL = root.appendingPathComponent("sample/personal wk99 29.04-02:46/auth.json")

    try writeAuth(
        authURL,
        payload: authPayload(
            accountID: "acct-personal-free",
            tokenSeed: "personal-free",
            userID: "user-personal-free",
            email: "personal-free@example.com",
            planType: "free"
        )
    )

    let group = try #require(AuthScanner().scan(root: root).first)
    let status = StatusResolver.resolveStatus(
        trackingKey: group.trackingKey,
        liveStatus: nil,
        fallbackRecord: group.primaryRecord,
        now: now,
        calendar: calendar
    )

    #expect(status.source == .folderName)
    #expect(status.shortWindowUsagePercent == nil)
    #expect(status.shortWindowResetAt == nil)
    #expect(status.shortWindowState == .current)
    #expect(status.weeklyUsagePercent == 99)
    #expect(status.weeklyWindowState == .current)
    #expect(status.hasNeedsRefreshWindow == false)
}

@Test
func statusResolverTreatsWeeklyOnlyLiveSnapshotAsCurrentForFreePlan() {
    let now = Date(timeIntervalSince1970: 1_775_865_180) // 2026-04-11 07:13 UTC
    let weeklyReset = Date(timeIntervalSince1970: 1_776_038_400) // 2026-04-13 08:00 UTC
    let trackingKey = "user:user-weekly-only|account:acct-weekly-only"

    let status = StatusResolver.resolveStatus(
        trackingKey: trackingKey,
        liveStatus: LiveCodexStatus(
            accountID: "acct-weekly-only",
            trackingKey: trackingKey,
            email: "weekly@example.com",
            planType: "free",
            authFingerprint: "fingerprint-weekly-only",
            snapshot: QuotaSnapshot(
                capturedAt: now,
                allowed: false,
                limitReached: true,
                primaryUsedPercent: nil,
                primaryResetAt: nil,
                primaryWindowMinutes: nil,
                secondaryUsedPercent: 100,
                secondaryResetAt: weeklyReset,
                secondaryWindowMinutes: 10_080
            ),
            source: .oauth
        ),
        fallbackRecord: nil,
        now: now,
        calendar: utcCalendar()
    )

    #expect(status.source == .oauth)
    #expect(status.shortWindowUsagePercent == nil)
    #expect(status.shortWindowResetAt == nil)
    #expect(status.shortWindowState == .current)
    #expect(status.weeklyUsagePercent == 100)
    #expect(status.weeklyWindowState == .current)
    #expect(status.hasNeedsRefreshWindow == false)
}

@Test
func statusResolverLetsFreshLivePlanReplaceStoredFolderAccountType() {
    let now = Date(timeIntervalSince1970: 1_775_865_180) // 2026-04-11 07:13 UTC
    let shortReset = Date(timeIntervalSince1970: 1_775_883_180) // 2026-04-11 12:13 UTC
    let weeklyReset = Date(timeIntervalSince1970: 1_776_038_400) // 2026-04-13 08:00 UTC
    let trackingKey = "user:user-daubs|account:acct-daubs"
    let fallbackRecord = sampleGroup(
        accountID: "acct-daubs",
        trackingKey: trackingKey,
        fingerprint: "fingerprint-daubs",
        folderName: "free wk62 30.04",
        planType: "plus"
    ).primaryRecord

    let status = StatusResolver.resolveStatus(
        trackingKey: trackingKey,
        liveStatus: LiveCodexStatus(
            accountID: "acct-daubs",
            trackingKey: trackingKey,
            email: "daubs-foot3e@icloud.com",
            planType: "plus",
            authFingerprint: "fingerprint-daubs",
            snapshot: QuotaSnapshot(
                capturedAt: now,
                allowed: true,
                limitReached: false,
                primaryUsedPercent: 88,
                primaryResetAt: shortReset,
                primaryWindowMinutes: 300,
                secondaryUsedPercent: 62,
                secondaryResetAt: weeklyReset,
                secondaryWindowMinutes: 10_080
            ),
            source: .oauth
        ),
        fallbackRecord: fallbackRecord,
        now: now,
        calendar: utcCalendar()
    )

    #expect(status.source == .oauth)
    #expect(status.shortWindowUsagePercent == 88)
    #expect(status.shortWindowResetAt == shortReset)
    #expect(status.shortWindowState == .current)
    #expect(status.weeklyUsagePercent == 62)
    #expect(status.weeklyWindowState == .current)
    #expect(status.hasNeedsRefreshWindow == false)
}

@Test
func statusResolverSupportsShortWindowOnlyForPlansThatActuallyHaveOne() {
    #expect(StatusResolver.supportsShortWindow(planType: "free") == false)
    #expect(StatusResolver.supportsShortWindow(planType: "plus") == true)
    #expect(StatusResolver.supportsShortWindow(planType: "pro") == true)
    #expect(StatusResolver.supportsShortWindow(planType: "team") == true)
    #expect(StatusResolver.supportsShortWindow(planType: "plus", baseLabel: "free") == false)
    #expect(StatusResolver.supportsShortWindow(planType: "team", baseLabel: "free") == false)
    #expect(StatusResolver.supportsShortWindow(planType: "free", baseLabel: "personal") == false)
    #expect(StatusResolver.supportsShortWindow(planType: "plus", baseLabel: "free@example.com") == true)
    #expect(StatusResolver.supportsShortWindow(planType: nil, baseLabel: "personal free") == false)
    #expect(StatusResolver.supportsShortWindow(planType: nil, baseLabel: "personal") == true)
    #expect(StatusResolver.supportsShortWindow(planType: nil, baseLabel: "bigcorp team") == true)
}

@Test
func statusResolverSeparatesSharedAccountIDsAcrossDifferentUsers() {
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)

    let catsim = sampleGroup(
        accountID: "acct-team",
        trackingKey: "user:user-catsim|account:acct-team",
        fingerprint: "fingerprint-catsim",
        folderName: "catsim w50 till 12:04"
    )
    let aleks = sampleGroup(
        accountID: "acct-team",
        trackingKey: "user:user-aleks|account:acct-team",
        fingerprint: "fingerprint-aleks",
        folderName: "catsim w18 till 12:04"
    )

    let liveSnapshot = QuotaSnapshot(
        capturedAt: now,
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 0,
        primaryResetAt: now.addingTimeInterval(3_600),
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 50,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )
    let cachedSnapshot = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-1_800),
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 0,
        primaryResetAt: now.addingTimeInterval(1_800),
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 18,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolve(
        groups: [catsim, aleks],
        liveStatus: LiveCodexStatus(
            accountID: "acct-team",
            trackingKey: catsim.trackingKey,
            email: "catsimulator@jolkins.id.lv",
            planType: "team",
            authFingerprint: catsim.authFingerprint,
            snapshot: liveSnapshot,
            source: .oauth
        ),
        snapshotsByTrackingKey: [aleks.trackingKey: cachedSnapshot],
        now: now
    )

    #expect(statuses[catsim.trackingKey]?.weeklyUsagePercent == 50)
    #expect(statuses[catsim.trackingKey]?.source == .oauth)
    #expect(statuses[aleks.trackingKey]?.weeklyUsagePercent == 18)
    #expect(statuses[aleks.trackingKey]?.source == .folderName)
}

@Test
func suggestReplacementSkipsCoolingDownAccounts() {
    let cooling = sampleGroup(
        accountID: "acct-cooling",
        trackingKey: "user:user-cooling|account:acct-cooling",
        fingerprint: "fingerprint-cooling",
        folderName: "cooling team 5h97 18:30 w41 till 10∕04"
    )
    let unknown = sampleGroup(
        accountID: "acct-unknown",
        trackingKey: "user:user-unknown|account:acct-unknown",
        fingerprint: "fingerprint-unknown",
        folderName: "unknown team"
    )

    let suggestion = StatusResolver.suggestReplacement(
        groups: [cooling, unknown],
        statusesByTrackingKey: [
            cooling.trackingKey: AccountStatus(
                source: .cached,
                capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                availableNow: false,
                nextAvailabilityAt: Date(timeIntervalSince1970: 1_775_610_000),
                weeklyUsagePercent: 41,
                weeklyResetAt: Date(timeIntervalSince1970: 1_775_865_600),
                shortWindowUsagePercent: 97,
                shortWindowResetAt: Date(timeIntervalSince1970: 1_775_610_000),
                rawFolderResetToken: nil
            ),
            unknown.trackingKey: AccountStatus(
                source: .unknown,
                capturedAt: nil,
                availableNow: nil,
                nextAvailabilityAt: nil,
                weeklyUsagePercent: nil,
                weeklyResetAt: nil,
                shortWindowUsagePercent: nil,
                shortWindowResetAt: nil,
                rawFolderResetToken: nil
            ),
        ],
        currentTrackingKey: nil
    )

    #expect(suggestion?.trackingKey == unknown.trackingKey)
}

@Test
func suggestReplacementPrefersFreeCandidateWhenCurrentAccountIsFree() {
    let freeCandidate = sampleGroup(
        accountID: "acct-free",
        trackingKey: "user:user-free|account:acct-free",
        fingerprint: "fingerprint-free",
        folderName: "candidate free",
        planType: "free"
    )
    let otherCandidate = sampleGroup(
        accountID: "acct-other",
        trackingKey: "user:user-other|account:acct-other",
        fingerprint: "fingerprint-other",
        folderName: "candidate team",
        planType: "team"
    )

    let suggestion = StatusResolver.suggestReplacement(
        groups: [freeCandidate, otherCandidate],
        statusesByTrackingKey: [
            freeCandidate.trackingKey: AccountStatus(
                source: .cached,
                capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                availableNow: true,
                nextAvailabilityAt: nil,
                weeklyUsagePercent: 41,
                weeklyResetAt: Date(timeIntervalSince1970: 1_775_865_600),
                shortWindowUsagePercent: nil,
                shortWindowResetAt: nil,
                rawFolderResetToken: nil
            ),
            otherCandidate.trackingKey: AccountStatus(
                source: .cached,
                capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                availableNow: true,
                nextAvailabilityAt: nil,
                weeklyUsagePercent: 12,
                weeklyResetAt: Date(timeIntervalSince1970: 1_775_865_600),
                shortWindowUsagePercent: nil,
                shortWindowResetAt: nil,
                rawFolderResetToken: nil
            ),
        ],
        currentTrackingKey: "user:user-current|account:acct-current",
        preferSameKindAsCurrent: true,
        currentPlanType: "free"
    )

    #expect(suggestion?.trackingKey == freeCandidate.trackingKey)
}

@Test
func suggestReplacementPrefersOtherCandidateWhenCurrentAccountIsNonFree() {
    let freeCandidate = sampleGroup(
        accountID: "acct-free",
        trackingKey: "user:user-free|account:acct-free",
        fingerprint: "fingerprint-free",
        folderName: "candidate free",
        planType: "free"
    )
    let otherCandidate = sampleGroup(
        accountID: "acct-other",
        trackingKey: "user:user-other|account:acct-other",
        fingerprint: "fingerprint-other",
        folderName: "candidate plus",
        planType: "plus"
    )

    let suggestion = StatusResolver.suggestReplacement(
        groups: [freeCandidate, otherCandidate],
        statusesByTrackingKey: [
            freeCandidate.trackingKey: AccountStatus(
                source: .cached,
                capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                availableNow: true,
                nextAvailabilityAt: nil,
                weeklyUsagePercent: 11,
                weeklyResetAt: Date(timeIntervalSince1970: 1_775_865_600),
                shortWindowUsagePercent: nil,
                shortWindowResetAt: nil,
                rawFolderResetToken: nil
            ),
            otherCandidate.trackingKey: AccountStatus(
                source: .cached,
                capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                availableNow: true,
                nextAvailabilityAt: nil,
                weeklyUsagePercent: 39,
                weeklyResetAt: Date(timeIntervalSince1970: 1_775_865_600),
                shortWindowUsagePercent: nil,
                shortWindowResetAt: nil,
                rawFolderResetToken: nil
            ),
        ],
        currentTrackingKey: "user:user-current|account:acct-current",
        preferSameKindAsCurrent: true,
        currentPlanType: "team"
    )

    #expect(suggestion?.trackingKey == otherCandidate.trackingKey)
}

@Test
func suggestReplacementFallsBackToDifferentKindWhenNoSameKindCandidateIsSuitable() {
    let freeCandidate = sampleGroup(
        accountID: "acct-free",
        trackingKey: "user:user-free|account:acct-free",
        fingerprint: "fingerprint-free",
        folderName: "candidate free",
        planType: "free"
    )
    let otherCandidate = sampleGroup(
        accountID: "acct-other",
        trackingKey: "user:user-other|account:acct-other",
        fingerprint: "fingerprint-other",
        folderName: "candidate team",
        planType: "team"
    )

    let suggestion = StatusResolver.suggestReplacement(
        groups: [freeCandidate, otherCandidate],
        statusesByTrackingKey: [
            freeCandidate.trackingKey: AccountStatus(
                source: .cached,
                capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                availableNow: false,
                nextAvailabilityAt: Date(timeIntervalSince1970: 1_775_610_000),
                weeklyUsagePercent: 9,
                weeklyResetAt: Date(timeIntervalSince1970: 1_775_865_600),
                shortWindowUsagePercent: 100,
                shortWindowResetAt: Date(timeIntervalSince1970: 1_775_610_000),
                rawFolderResetToken: nil
            ),
            otherCandidate.trackingKey: AccountStatus(
                source: .cached,
                capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                availableNow: true,
                nextAvailabilityAt: nil,
                weeklyUsagePercent: 50,
                weeklyResetAt: Date(timeIntervalSince1970: 1_775_865_600),
                shortWindowUsagePercent: nil,
                shortWindowResetAt: nil,
                rawFolderResetToken: nil
            ),
        ],
        currentTrackingKey: "user:user-current|account:acct-current",
        preferSameKindAsCurrent: true,
        currentPlanType: "free"
    )

    #expect(suggestion?.trackingKey == otherCandidate.trackingKey)
}

@Test
func statusResolverFallsBackToCachedSnapshotWhenLiveStatusHasNoFreshQuota() {
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
    let liveGroup = sampleGroup(
        accountID: "acct-live",
        trackingKey: "user:user-live|account:acct-live",
        fingerprint: "fingerprint-live",
        folderName: "personal free w41 till 13:04"
    )
    let cachedSnapshot = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-1_800),
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 0,
        primaryResetAt: now.addingTimeInterval(3_600),
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 41,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolve(
        groups: [liveGroup],
        liveStatus: LiveCodexStatus(
            accountID: "acct-live",
            trackingKey: liveGroup.trackingKey,
            email: "live@example.com",
            planType: "plus",
            authFingerprint: "fingerprint-live",
            snapshot: nil,
            source: .oauth
        ),
        snapshotsByTrackingKey: [liveGroup.trackingKey: cachedSnapshot],
        now: now
    )

    #expect(statuses[liveGroup.trackingKey]?.source == .cached)
    #expect(statuses[liveGroup.trackingKey]?.weeklyUsagePercent == 41)
}

@Test
func statusResolverPrefersFolderDataForSavedRowsWhenSnapshotIsOlderThanFolder() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let shortReset = now.addingTimeInterval(5 * 60 * 60)
    let weeklyReset = now.addingTimeInterval(6 * 60 * 60 + 4 * 60)
    let authURL = root.appendingPathComponent("sample/personal free 5h18 05:00 w44 06:04/auth.json")

    try writeAuth(authURL, payload: authPayload(accountID: "acct-live", tokenSeed: "live"))
    try FileManager.default.setAttributes(
        [.modificationDate: now],
        ofItemAtPath: authURL.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: now],
        ofItemAtPath: authURL.deletingLastPathComponent().path
    )

    let storedGroup = try #require(AuthScanner().scan(root: root).first)
    let cachedSnapshot = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-60),
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 81,
        primaryResetAt: shortReset,
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 12,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolve(
        groups: [storedGroup],
        liveStatus: nil,
        snapshotsByTrackingKey: [storedGroup.trackingKey: cachedSnapshot],
        now: now,
        calendar: utcCalendar()
    )

    #expect(statuses[storedGroup.trackingKey]?.source == .folderName)
    #expect(statuses[storedGroup.trackingKey]?.shortWindowUsagePercent == 18)
    #expect(statuses[storedGroup.trackingKey]?.weeklyUsagePercent == 44)
}

@Test
func statusResolverUsesFolderDataForSavedRowsEvenWhenSnapshotIsNewer() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let folderModifiedAt = now.addingTimeInterval(-600)
    let shortReset = now.addingTimeInterval(5 * 60 * 60)
    let weeklyReset = now.addingTimeInterval(6 * 60 * 60 + 4 * 60)
    let authURL = root.appendingPathComponent("sample/personal free 5h18 05:00 w44 06:04/auth.json")

    try writeAuth(authURL, payload: authPayload(accountID: "acct-live", tokenSeed: "live"))
    try FileManager.default.setAttributes(
        [.modificationDate: folderModifiedAt],
        ofItemAtPath: authURL.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: folderModifiedAt],
        ofItemAtPath: authURL.deletingLastPathComponent().path
    )

    let storedGroup = try #require(AuthScanner().scan(root: root).first)
    let cachedSnapshot = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-60),
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 81,
        primaryResetAt: shortReset,
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 12,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolve(
        groups: [storedGroup],
        liveStatus: nil,
        snapshotsByTrackingKey: [storedGroup.trackingKey: cachedSnapshot],
        now: now,
        calendar: utcCalendar()
    )

    #expect(statuses[storedGroup.trackingKey]?.source == .folderName)
    #expect(statuses[storedGroup.trackingKey]?.shortWindowUsagePercent == 18)
    #expect(statuses[storedGroup.trackingKey]?.weeklyUsagePercent == 44)
}

@Test
func savedDisplayStatusesUseFolderNameDataOnly() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let calendar = utcCalendar()
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let folderModifiedAt = now.addingTimeInterval(-600)
    let shortReset = now.addingTimeInterval(3 * 60 * 60 + 27 * 60)
    let weeklyReset = now.addingTimeInterval(7 * 24 * 60 * 60)
    let authURL = root.appendingPathComponent("sample/team 5hr0 09:27/auth.json")

    try writeAuth(authURL, payload: authPayload(accountID: "acct-display", tokenSeed: "display"))
    try FileManager.default.setAttributes(
        [.modificationDate: folderModifiedAt],
        ofItemAtPath: authURL.path
    )
    try FileManager.default.setAttributes(
        [.modificationDate: folderModifiedAt],
        ofItemAtPath: authURL.deletingLastPathComponent().path
    )

    let storedGroup = try #require(AuthScanner().scan(root: root).first)
    let cachedSnapshot = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-60),
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 0,
        primaryResetAt: shortReset,
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 0,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolveSavedStatusesForDisplay(
        groups: [storedGroup],
        snapshotsByTrackingKey: [storedGroup.trackingKey: cachedSnapshot],
        now: now,
        calendar: calendar
    )

    #expect(statuses[storedGroup.trackingKey]?.source == .folderName)
    #expect(statuses[storedGroup.trackingKey]?.shortWindowUsagePercent == 0)
    #expect(statuses[storedGroup.trackingKey]?.shortWindowResetAt == calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 9, minute: 27)))
    #expect(statuses[storedGroup.trackingKey]?.shortWindowState == .current)
    #expect(statuses[storedGroup.trackingKey]?.weeklyUsagePercent == nil)
    #expect(statuses[storedGroup.trackingKey]?.weeklyResetAt == nil)
    #expect(statuses[storedGroup.trackingKey]?.weeklyWindowState == .needsRefresh)
}

@Test
func statusResolverTreatsSavedRowsWithoutFolderWeeklyUsageAsNeedsRefresh() {
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let weeklyReset = now.addingTimeInterval(2 * 24 * 60 * 60)
    let storedGroup = sampleGroup(
        accountID: "acct-cached-expired",
        fingerprint: "fingerprint-cached-expired",
        folderName: "personal free"
    )
    let cachedSnapshot = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-60),
        allowed: false,
        limitReached: true,
        primaryUsedPercent: 98,
        primaryResetAt: now.addingTimeInterval(-30),
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 41,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolve(
        groups: [storedGroup],
        liveStatus: nil,
        snapshotsByTrackingKey: [storedGroup.trackingKey: cachedSnapshot],
        now: now
    )

    #expect(statuses[storedGroup.trackingKey]?.source == .folderName)
    #expect(statuses[storedGroup.trackingKey]?.availableNow == nil)
    #expect(statuses[storedGroup.trackingKey]?.nextAvailabilityAt == nil)
    #expect(statuses[storedGroup.trackingKey]?.shortWindowUsagePercent == nil)
    #expect(statuses[storedGroup.trackingKey]?.shortWindowResetAt == nil)
    #expect(statuses[storedGroup.trackingKey]?.shortWindowState == .current)
    #expect(statuses[storedGroup.trackingKey]?.weeklyUsagePercent == nil)
    #expect(statuses[storedGroup.trackingKey]?.weeklyResetAt == nil)
    #expect(statuses[storedGroup.trackingKey]?.weeklyWindowState == .needsRefresh)
}

@Test
func statusResolverSuppressesHourlyWindowForFreeLiveStatusAndUsesWeeklyReset() {
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let shortReset = now.addingTimeInterval(45 * 60)
    let weeklyReset = now.addingTimeInterval(3 * 24 * 60 * 60)
    let liveGroup = sampleGroup(
        accountID: "acct-live",
        trackingKey: "user:user-live|account:acct-live",
        fingerprint: "fingerprint-live",
        folderName: "personal free w100 till 12:04"
    )
    let liveSnapshot = QuotaSnapshot(
        capturedAt: now,
        allowed: false,
        limitReached: true,
        primaryUsedPercent: 100,
        primaryResetAt: shortReset,
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 100,
        secondaryResetAt: weeklyReset,
        secondaryWindowMinutes: 10_080
    )

    let statuses = StatusResolver.resolve(
        groups: [liveGroup],
        liveStatus: LiveCodexStatus(
            accountID: "acct-live",
            trackingKey: liveGroup.trackingKey,
            email: "live@example.com",
            planType: "free",
            authFingerprint: "fingerprint-live",
            snapshot: liveSnapshot,
            source: .oauth
        ),
        snapshotsByTrackingKey: [:],
        now: now
    )

    #expect(statuses[liveGroup.trackingKey]?.shortWindowUsagePercent == nil)
    #expect(statuses[liveGroup.trackingKey]?.shortWindowResetAt == nil)
    #expect(statuses[liveGroup.trackingKey]?.shortWindowState == .current)
    #expect(statuses[liveGroup.trackingKey]?.weeklyUsagePercent == 100)
    #expect(statuses[liveGroup.trackingKey]?.weeklyResetAt == weeklyReset)
    #expect(statuses[liveGroup.trackingKey]?.nextAvailabilityAt == weeklyReset)
}

@Test
func renamerUpdatesFolderNameAndSkipsCollisions() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let payload = authPayload(accountID: "acct-rename", tokenSeed: "rename-a")
    let payloadB = authPayload(accountID: "acct-rename", tokenSeed: "rename-b")
    let sourceA = root.appendingPathComponent("acct/personal old w10 11:04/auth.json")
    let sourceB = root.appendingPathComponent("acct/personal old w99 till 30/auth.json")

    try writeAuth(sourceA, payload: payload)
    try writeAuth(sourceB, payload: payloadB)

    let groups = try AuthScanner().scan(root: root)
    let status = AccountStatus(
        source: .oauth,
        capturedAt: Date(),
        availableNow: true,
        nextAvailabilityAt: nil,
        weeklyUsagePercent: 18,
        weeklyResetAt: Date(timeIntervalSince1970: 1_775_952_000),
        shortWindowUsagePercent: nil,
        shortWindowResetAt: nil,
        rawFolderResetToken: nil,
        weeklyWindowState: .current,
        shortWindowState: .needsRefresh
    )

    let report = try FolderRenamer().syncManagedSuffixes(
        groups: groups,
        statusesByTrackingKey: ["account:acct-rename": status],
        now: Date(timeIntervalSince1970: 1_775_606_400),
        calendar: Calendar(identifier: .gregorian)
    )

    #expect(report.changedPaths.count == 1)
    #expect(report.warnings.count == 1)
}

@Test
func renamerUpdatesStoredAccountTypeFromFreshState() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let authURL = root.appendingPathComponent("acct/primary team wk44 15.04/auth.json")
    try writeAuth(
        authURL,
        payload: authPayload(
            accountID: "acct-type-update",
            tokenSeed: "type-update",
            userID: "user-type-update",
            email: "type-update@example.com",
            planType: "team"
        )
    )

    let calendar = utcCalendar()
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let group = try #require(AuthScanner().scan(root: root).first)
    let status = AccountStatus(
        source: .oauth,
        capturedAt: now,
        availableNow: true,
        nextAvailabilityAt: nil,
        weeklyUsagePercent: 44,
        weeklyResetAt: Date(timeIntervalSince1970: 1_776_254_400),
        shortWindowUsagePercent: nil,
        shortWindowResetAt: nil,
        rawFolderResetToken: nil,
        weeklyWindowState: .current,
        shortWindowState: .needsRefresh
    )

    let report = try FolderRenamer().syncManagedSuffixes(
        groups: [group],
        statusesByTrackingKey: [group.trackingKey: status],
        preferredAccountTypesByRecordID: [group.primaryRecord.id: "plus"],
        now: now,
        calendar: calendar
    )

    #expect(report.changedPaths == ["acct/primary team wk44 15.04 -> primary plus wk44 15.04"])
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("acct/primary plus wk44 15.04/auth.json").path))
    #expect(!FileManager.default.fileExists(atPath: authURL.path))
}

@Test
func renamerPreservesExpiredManagedWindowsUntilFreshDataArrives() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let expiredAuthURL = root.appendingPathComponent("acct/expired team 5h97 18:30 wk41 10.04/auth.json")
    let unknownAuthURL = root.appendingPathComponent("acct/unknown team 5h97 wk41 10.04/auth.json")
    try writeAuth(expiredAuthURL, payload: authPayload(accountID: "acct-expired", tokenSeed: "expired"))
    try writeAuth(unknownAuthURL, payload: authPayload(accountID: "acct-unknown", tokenSeed: "unknown"))

    let calendar = utcCalendar()
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 19, minute: 0))!
    let groups = try AuthScanner().scan(root: root)

    let statuses = Dictionary(uniqueKeysWithValues: groups.map { group in
        (
            group.trackingKey,
            StatusResolver.resolveStatus(
                trackingKey: group.trackingKey,
                liveStatus: nil,
                snapshotsByTrackingKey: [:],
                fallbackRecord: group.primaryRecord,
                now: now,
                calendar: calendar
            )
        )
    })

    let report = try FolderRenamer().syncManagedSuffixes(
        groups: groups,
        statusesByTrackingKey: statuses,
        now: now,
        calendar: calendar
    )

    #expect(report.changedPaths.contains("acct/expired team 5h97 18:30 wk41 10.04 -> expired team 5hr97 18:30 wk41 10.04"))
    #expect(report.changedPaths.contains("acct/unknown team 5h97 wk41 10.04 -> unknown team 5hr97 wk41 10.04"))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("acct/expired team 5hr97 18:30 wk41 10.04/auth.json").path))
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("acct/unknown team 5hr97 wk41 10.04/auth.json").path))
}

@Test
func renamerMigratesLegacyManagedSuffixesFromFolderDerivedStatus() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let authURL = root.appendingPathComponent("acct/personal old 5h18 11:04 w44 till 15∕04/auth.json")
    try writeAuth(authURL, payload: authPayload(accountID: "acct-migrate", tokenSeed: "migrate"))

    let calendar = utcCalendar()
    let now = calendar.date(from: DateComponents(year: 2026, month: 4, day: 8, hour: 0, minute: 0))!
    let groups = try AuthScanner().scan(root: root)
    let group = try #require(groups.first)
    let status = StatusResolver.resolveStatus(
        trackingKey: group.trackingKey,
        liveStatus: nil,
        snapshotsByTrackingKey: [:],
        fallbackRecord: group.primaryRecord,
        now: now,
        calendar: calendar
    )

    let report = try FolderRenamer().syncManagedSuffixes(
        groups: groups,
        statusesByTrackingKey: [group.trackingKey: status],
        now: now,
        calendar: calendar
    )

    let migratedURL = root.appendingPathComponent("acct/personal old 5hr18 08.04-11:04 wk44 15.04/auth.json")

    #expect(report.changedPaths == ["acct/personal old 5h18 11:04 w44 till 15∕04 -> personal old 5hr18 08.04-11:04 wk44 15.04"])
    #expect(FileManager.default.fileExists(atPath: migratedURL.path))
    #expect(!FileManager.default.fileExists(atPath: authURL.path))
}

@Test
func exactDuplicatePrunerKeepsPreferredFolderAndSkipsFoldersWithExtraFiles() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let sharedPayload = authPayload(accountID: "acct-dup", tokenSeed: "dup", userID: "user-dup", email: "dup@example.com")
    let removableAuth = root.appendingPathComponent("a/dup one/auth.json")
    let extraFilesAuth = root.appendingPathComponent("b/dup two/auth.json")
    let preferredAuth = root.appendingPathComponent("c/dup three/auth.json")

    try writeAuth(removableAuth, payload: sharedPayload)
    try writeAuth(extraFilesAuth, payload: sharedPayload)
    try writeAuth(preferredAuth, payload: sharedPayload)
    try "keep".write(to: extraFilesAuth.deletingLastPathComponent().appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

    let groups = try AuthScanner().scan(root: root)
    let report = try ExactDuplicatePruner().prune(
        groups: groups,
        preferredFolderURL: preferredAuth.deletingLastPathComponent()
    )

    #expect(report.removedPaths == ["a/dup one"])
    #expect(report.warnings.count == 1)
    #expect(FileManager.default.fileExists(atPath: preferredAuth.path))
    #expect(FileManager.default.fileExists(atPath: extraFilesAuth.path))
    #expect(!FileManager.default.fileExists(atPath: removableAuth.path))
}

@Test
func snapshotStoreRoundTripsSavedQuotaHistory() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = QuotaSnapshotStore(storageURL: root.appendingPathComponent("quota-snapshots.json"))
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let snapshot = QuotaSnapshot(
        capturedAt: now,
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 12,
        primaryResetAt: Date(timeIntervalSince1970: 1_775_607_000),
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 44,
        secondaryResetAt: Date(timeIntervalSince1970: 1_776_206_400),
        secondaryWindowMinutes: 10_080
    )

    try store.save(["acct-store": snapshot], asOf: now)
    let loaded = try store.load(asOf: now)

    #expect(loaded["acct-store"] == snapshot)
}

@Test
func snapshotStoreFiltersAndPurgesEntriesOlderThanSevenDays() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = QuotaSnapshotStore(storageURL: root.appendingPathComponent("quota-snapshots.json"))
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let fresh = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-(6 * 24 * 60 * 60)),
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 12,
        primaryResetAt: now.addingTimeInterval(3_600),
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 44,
        secondaryResetAt: now.addingTimeInterval(2 * 24 * 60 * 60),
        secondaryWindowMinutes: 10_080
    )
    let stale = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 1),
        allowed: false,
        limitReached: true,
        primaryUsedPercent: 100,
        primaryResetAt: now.addingTimeInterval(3_600),
        primaryWindowMinutes: 300,
        secondaryUsedPercent: 100,
        secondaryResetAt: now.addingTimeInterval(24 * 60 * 60),
        secondaryWindowMinutes: 10_080
    )

    try writeRawSnapshotStore(
        ["fresh": fresh, "stale": stale],
        to: store.storageURL
    )

    let loaded = try store.load(asOf: now)

    #expect(loaded["fresh"] == fresh)
    #expect(loaded["stale"] == nil)

    try store.purgeExpiredSnapshots(asOf: now)
    let persisted = try readRawSnapshotStore(from: store.storageURL)

    #expect(persisted["fresh"] == fresh)
    #expect(persisted["stale"] == nil)
}

@Test
func snapshotStoreKeepsEntriesCapturedExactlySevenDaysAgo() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = QuotaSnapshotStore(storageURL: root.appendingPathComponent("quota-snapshots.json"))
    let now = Date(timeIntervalSince1970: 1_775_606_400)
    let boundary = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60)),
        allowed: true,
        limitReached: false,
        primaryUsedPercent: 0,
        primaryResetAt: nil,
        primaryWindowMinutes: nil,
        secondaryUsedPercent: 57,
        secondaryResetAt: now.addingTimeInterval(24 * 60 * 60),
        secondaryWindowMinutes: 10_080
    )
    let stale = QuotaSnapshot(
        capturedAt: now.addingTimeInterval(-(7 * 24 * 60 * 60) - 1),
        allowed: false,
        limitReached: true,
        primaryUsedPercent: nil,
        primaryResetAt: nil,
        primaryWindowMinutes: nil,
        secondaryUsedPercent: 100,
        secondaryResetAt: now.addingTimeInterval(24 * 60 * 60),
        secondaryWindowMinutes: 10_080
    )

    try store.save(["boundary": boundary, "stale": stale], asOf: now)
    let loaded = try store.load(asOf: now)

    #expect(loaded["boundary"] == boundary)
    #expect(loaded["stale"] == nil)
}

@Test
func snapshotStorePurgeIsNoOpForMissingOrEmptyCacheFile() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let store = QuotaSnapshotStore(storageURL: root.appendingPathComponent("quota-snapshots.json"))
    let now = Date(timeIntervalSince1970: 1_775_606_400)

    try store.purgeExpiredSnapshots(asOf: now)
    #expect(!FileManager.default.fileExists(atPath: store.storageURL.path))

    try FileManager.default.createDirectory(at: store.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: store.storageURL)

    try store.purgeExpiredSnapshots(asOf: now)

    let data = try Data(contentsOf: store.storageURL)
    let loaded = try store.load(asOf: now)
    #expect(data.isEmpty)
    #expect(loaded.isEmpty)
}

@Test
func swapperCanSaveCurrentAuthBeforeReplacingLiveAuth() throws {
    let root = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let liveAuthURL = root.appendingPathComponent(".codex/auth.json")
    let storedAuthURL = root.appendingPathComponent("store/current/auth.json")
    let nextAuthURL = root.appendingPathComponent("store/next/auth.json")

    try writeAuth(liveAuthURL, payload: authPayload(accountID: "acct-live", tokenSeed: "live"))
    try writeAuth(nextAuthURL, payload: authPayload(accountID: "acct-next", tokenSeed: "next"))

    let swapper = AuthFileSwapper(liveAuthURL: liveAuthURL)
    try swapper.saveCurrentAuth(to: storedAuthURL)
    try swapper.swapIn(sourceAuthFileURL: nextAuthURL)

    let liveData = try Data(contentsOf: liveAuthURL)
    let storedData = try Data(contentsOf: storedAuthURL)
    let nextData = try Data(contentsOf: nextAuthURL)

    #expect(storedData != nextData)
    #expect(liveData == nextData)

    let storedPayload = try JSONDecoder().decode(StoredAuthPayload.self, from: storedData)
    #expect(storedPayload.tokens?.accountID == "acct-live")
    let livePayload = try JSONDecoder().decode(StoredAuthPayload.self, from: liveData)
    #expect(livePayload.tokens?.accountID == "acct-next")
}

@Suite(.serialized)
struct CodexStatusReaderTests {
    @Test
    func codexOAuthCredentialsParserLoadsTokensAndDates() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let liveAuthURL = root.appendingPathComponent(".codex/auth.json")

        try writeAuth(
            liveAuthURL,
            payload: authPayload(
                accountID: "acct-live",
                tokenSeed: "live",
                userID: "user-live",
                email: "live@example.com",
                planType: "plus"
            )
        )

        let credentials = try CodexOAuthCredentialsStore.load(from: liveAuthURL)

        #expect(credentials.accessToken == "access-live")
        #expect(credentials.refreshToken == "refresh-live")
        #expect(credentials.accountID == "acct-live")
        #expect(credentials.idToken != nil)
        #expect(credentials.lastRefresh != nil)
    }

    @Test
    func codexOAuthUsageFetcherHonorsConfigBaseURLAndAccountHeader() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        chatgpt_base_url = "https://example.test/backend-api"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let credentials = CodexOAuthCredentials(
            accessToken: "access-live",
            refreshToken: "refresh-live",
            idToken: nil,
            accountID: "acct-live",
            lastRefresh: nil
        )

        final class RequestBox: @unchecked Sendable {
            var request: URLRequest?
        }
        let box = RequestBox()

        let payload = oauthUsageResponseData(planType: "team", primaryUsedPercent: 68, weeklyUsedPercent: 67)
        let live = try await CodexOAuthUsageFetcher.fetchUsage(
            credentials: credentials,
            configURL: configURL,
            now: Date(timeIntervalSince1970: 1_775_606_400),
            dataLoader: { request in
                box.request = request
                return (
                    payload,
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                )
            }
        )

        #expect(box.request?.url?.absoluteString == "https://example.test/backend-api/wham/usage")
        #expect(box.request?.value(forHTTPHeaderField: "Authorization") == "Bearer access-live")
        #expect(box.request?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-live")
        #expect(live.planType == "team")
        #expect(live.snapshot?.primaryUsedPercent == 68)
        #expect(live.snapshot?.secondaryUsedPercent == 67)
    }

    @Test
    func codexStatusReaderUsesOAuthBeforeCLIFallbacks() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let liveAuthURL = root.appendingPathComponent(".codex/auth.json")
        try writeAuth(
            liveAuthURL,
            payload: authPayload(
                accountID: "acct-live",
                tokenSeed: "live",
                userID: "user-live",
                email: "live@example.com",
                planType: "team"
            )
        )

        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let rpcCalls = Counter()
        let ptyCalls = Counter()

        let status = try await CodexStatusReader(
            liveAuthURL: liveAuthURL,
            oauthFetcher: { _, _ in
                CodexLiveQuotaPayload(
                    planType: "team",
                    snapshot: QuotaSnapshot(
                        capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                        allowed: true,
                        limitReached: false,
                        primaryUsedPercent: 68,
                        primaryResetAt: Date(timeIntervalSince1970: 1_775_624_600),
                        primaryWindowMinutes: 300,
                        secondaryUsedPercent: 67,
                        secondaryResetAt: Date(timeIntervalSince1970: 1_776_254_400),
                        secondaryWindowMinutes: 10_080
                    )
                )
            },
            cliRPCFetcher: { _, _ in
                rpcCalls.value += 1
                return CodexLiveQuotaPayload(planType: "team", snapshot: nil)
            },
            cliPTYFetcher: { _, _ in
                ptyCalls.value += 1
                return CodexLiveQuotaPayload(planType: "team", snapshot: nil)
            }
        ).readLiveStatus()

        #expect(status?.source == .oauth)
        #expect(status?.snapshot?.primaryUsedPercent == 68)
        #expect(status?.snapshot?.secondaryUsedPercent == 67)
        #expect(rpcCalls.value == 0)
        #expect(ptyCalls.value == 0)
    }

    @Test
    func codexStatusReaderFallsBackToCLIRPCWhenOAuthFails() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let liveAuthURL = root.appendingPathComponent(".codex/auth.json")
        try writeAuth(
            liveAuthURL,
            payload: authPayload(
                accountID: "acct-live",
                tokenSeed: "live",
                userID: "user-live",
                email: "live@example.com",
                planType: nil
            )
        )

        let status = try await CodexStatusReader(
            liveAuthURL: liveAuthURL,
            oauthFetcher: { _, _ in
                throw CodexOAuthFetchError.unauthorized
            },
            cliRPCFetcher: { _, _ in
                CodexLiveQuotaPayload(
                    planType: "free",
                    snapshot: QuotaSnapshot(
                        capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                        allowed: true,
                        limitReached: false,
                        primaryUsedPercent: 12,
                        primaryResetAt: Date(timeIntervalSince1970: 1_775_624_600),
                        primaryWindowMinutes: 300,
                        secondaryUsedPercent: 46,
                        secondaryResetAt: Date(timeIntervalSince1970: 1_776_254_400),
                        secondaryWindowMinutes: 10_080
                    )
                )
            },
            cliPTYFetcher: { _, _ in
                CodexLiveQuotaPayload(planType: nil, snapshot: nil)
            }
        ).readLiveStatus()

        #expect(status?.source == .cliRPC)
        #expect(status?.planType == "free")
        #expect(status?.snapshot?.primaryUsedPercent == 12)
        #expect(status?.snapshot?.secondaryUsedPercent == 46)
    }

    @Test
    func codexStatusReaderReadsPlanTypeFromCurrentRPCQuotaPayload() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let liveAuthURL = root.appendingPathComponent(".codex/auth.json")
        try writeAuth(
            liveAuthURL,
            payload: authPayload(
                accountID: "acct-live",
                tokenSeed: "live",
                userID: "user-live",
                email: "live@example.com",
                planType: nil
            )
        )

        let fakeCodexURL = root.appendingPathComponent("fake-codex")
        let fakeCodex = """
        #!/bin/zsh
        sleep 0.1
        print -r -- '{"id":1,"result":{"userAgent":"fake","codexHome":"\(root.path)","platformFamily":"unix","platformOs":"macos"}}'
        sleep 0.1
        print -r -- '{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":42.4,"windowDurationMins":300,"resetsAt":1775624600},"secondary":{"usedPercent":65.6,"windowDurationMins":10080,"resetsAt":1776254400},"planType":"team","rateLimitReachedType":null},"rateLimitsByLimitId":{}}}'
        sleep 0.1
        print -r -- '{"id":3,"error":{"message":"account unavailable"}}'
        sleep 5
        """
        try fakeCodex.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeCodexURL.path)

        let status = try await CodexStatusReader(
            liveAuthURL: liveAuthURL,
            codexBinary: fakeCodexURL.path,
            environment: ["PATH": "/usr/bin:/bin"],
            oauthFetcher: { _, _ in
                throw CodexOAuthFetchError.unauthorized
            },
            cliPTYFetcher: { _, _ in
                struct ProbeFailure: Error {}
                throw ProbeFailure()
            }
        ).readLiveStatus()

        #expect(status?.source == .cliRPC)
        #expect(status?.planType == "team")
        #expect(status?.snapshot?.primaryUsedPercent == 42)
        #expect(status?.snapshot?.secondaryUsedPercent == 66)
    }

    @Test
    func codexStatusReaderFallsBackToCLIStatusWhenRPCFails() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let liveAuthURL = root.appendingPathComponent(".codex/auth.json")
        try writeAuth(
            liveAuthURL,
            payload: authPayload(
                accountID: "acct-live",
                tokenSeed: "live",
                userID: "user-live",
                email: "live@example.com",
                planType: "free"
            )
        )

        let status = try await CodexStatusReader(
            liveAuthURL: liveAuthURL,
            oauthFetcher: { _, _ in
                CodexLiveQuotaPayload(planType: "free", snapshot: nil)
            },
            cliRPCFetcher: { _, _ in
                struct ProbeFailure: Error {}
                throw ProbeFailure()
            },
            cliPTYFetcher: { _, _ in
                CodexLiveQuotaPayload(
                    planType: nil,
                    snapshot: QuotaSnapshot(
                        capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                        allowed: false,
                        limitReached: true,
                        primaryUsedPercent: 100,
                        primaryResetAt: Date(timeIntervalSince1970: 1_775_607_000),
                        primaryWindowMinutes: 300,
                        secondaryUsedPercent: 67,
                        secondaryResetAt: Date(timeIntervalSince1970: 1_776_254_400),
                        secondaryWindowMinutes: 10_080
                    )
                )
            }
        ).readLiveStatus()

        #expect(status?.source == .cliPTY)
        #expect(status?.planType == "free")
        #expect(status?.snapshot?.primaryUsedPercent == 100)
        #expect(status?.snapshot?.secondaryUsedPercent == 67)
    }

    @Test
    func codexStatusReaderReadsDirectOAuthStatusForSavedAuthFileWithoutCLIFallbacks() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let savedAuthURL = root.appendingPathComponent("saved/team/auth.json")
        try writeAuth(
            savedAuthURL,
            payload: authPayload(
                accountID: "acct-saved",
                tokenSeed: "saved",
                userID: "user-saved",
                email: "saved@example.com",
                planType: "team"
            )
        )

        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let rpcCalls = Counter()
        let ptyCalls = Counter()

        let status = try await CodexStatusReader(
            oauthFetcher: { credentials, _ in
                #expect(credentials.accessToken == "access-saved")
                return CodexLiveQuotaPayload(
                    planType: "team",
                    snapshot: QuotaSnapshot(
                        capturedAt: Date(timeIntervalSince1970: 1_775_606_400),
                        allowed: true,
                        limitReached: false,
                        primaryUsedPercent: 24,
                        primaryResetAt: Date(timeIntervalSince1970: 1_775_624_600),
                        primaryWindowMinutes: 300,
                        secondaryUsedPercent: 61,
                        secondaryResetAt: Date(timeIntervalSince1970: 1_776_254_400),
                        secondaryWindowMinutes: 10_080
                    )
                )
            },
            cliRPCFetcher: { _, _ in
                rpcCalls.value += 1
                return CodexLiveQuotaPayload(planType: nil, snapshot: nil)
            },
            cliPTYFetcher: { _, _ in
                ptyCalls.value += 1
                return CodexLiveQuotaPayload(planType: nil, snapshot: nil)
            }
        ).readDirectOAuthStatus(authFileURL: savedAuthURL)

        #expect(status.source == .oauth)
        #expect(status.trackingKey == "user:user-saved|account:acct-saved")
        #expect(status.planType == "team")
        #expect(status.snapshot?.primaryUsedPercent == 24)
        #expect(status.snapshot?.secondaryUsedPercent == 61)
        #expect(rpcCalls.value == 0)
        #expect(ptyCalls.value == 0)
    }

    @Test
    func codexStatusReaderDirectOAuthStatusDoesNotInvokeCLIFallbacksWhenOAuthFails() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let savedAuthURL = root.appendingPathComponent("saved/personal/auth.json")
        try writeAuth(
            savedAuthURL,
            payload: authPayload(
                accountID: "acct-saved",
                tokenSeed: "saved",
                userID: "user-saved",
                email: "saved@example.com",
                planType: "plus"
            )
        )

        final class Counter: @unchecked Sendable {
            var value = 0
        }
        let rpcCalls = Counter()
        let ptyCalls = Counter()
        let reader = CodexStatusReader(
            oauthFetcher: { _, _ in
                throw CodexOAuthFetchError.unauthorized
            },
            cliRPCFetcher: { _, _ in
                rpcCalls.value += 1
                return CodexLiveQuotaPayload(planType: "free", snapshot: nil)
            },
            cliPTYFetcher: { _, _ in
                ptyCalls.value += 1
                return CodexLiveQuotaPayload(planType: "free", snapshot: nil)
            }
        )

        do {
            _ = try await reader.readDirectOAuthStatus(authFileURL: savedAuthURL)
            Issue.record("Expected direct OAuth status read to fail.")
        } catch let error as CodexOAuthFetchError {
            switch error {
            case .unauthorized:
                break
            default:
                Issue.record("Expected unauthorized error, got \(error.localizedDescription)")
            }
        }

        #expect(rpcCalls.value == 0)
        #expect(ptyCalls.value == 0)
    }

    @Test
    func isolatedWindowStarterPreparesPrivateHomeSanitizesEnvironmentAndCleansUp() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("saved/auth.json")
        let configURL = root.appendingPathComponent("live/.codex/config.toml")
        try writeAuth(
            authURL,
            payload: authPayload(
                accountID: "acct-primary",
                tokenSeed: "primary",
                userID: "user-primary",
                email: "primary@example.com",
                planType: "team"
            )
        )
        try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "model = \"gpt-5\"\n".write(to: configURL, atomically: true, encoding: .utf8)

        let recorder = WindowStartInvocationRecorder()
        let starter = IsolatedCodexExecWindowStarter(
            syncGuard: CodexAuthTokenSyncGuard(storageURL: root.appendingPathComponent("retired-window-tokens.json")),
            runner: { invocation in
            await recorder.record(invocation)

            let isolatedAuthURL = invocation.homeDirectoryURL.appendingPathComponent(".codex/auth.json")
            let isolatedConfigURL = invocation.homeDirectoryURL.appendingPathComponent(".codex/config.toml")

            #expect(FileManager.default.fileExists(atPath: isolatedAuthURL.path))
            #expect(FileManager.default.fileExists(atPath: isolatedConfigURL.path))
            #expect(FileManager.default.fileExists(atPath: invocation.workingDirectoryURL.path))
            #expect(invocation.environment["PATH"] == "/tmp/test-bin")
            #expect(invocation.environment["HTTPS_PROXY"] == "http://proxy.test")
            #expect(invocation.environment["HOME"] == invocation.homeDirectoryURL.path)
            #expect(invocation.environment["XDG_CONFIG_HOME"] == invocation.temporaryRootURL.appendingPathComponent(".xdg-config").path)
            #expect(invocation.environment["XDG_STATE_HOME"] == invocation.temporaryRootURL.appendingPathComponent(".xdg-state").path)
            #expect(invocation.environment["XDG_CACHE_HOME"] == invocation.temporaryRootURL.appendingPathComponent(".xdg-cache").path)
            #expect(invocation.environment["CODEX_THREAD_ID"] == nil)
            #expect(invocation.environment["OPENAI_API_KEY"] == nil)

            let copiedAuth = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: isolatedAuthURL))
            let copiedConfig = try String(contentsOf: isolatedConfigURL, encoding: .utf8)
            #expect(copiedAuth.tokens?.accessToken == "access-primary")
            #expect(copiedConfig == "model = \"gpt-5\"\n")
            #expect(invocation.arguments.contains("gpt-5.4-mini"))
            #expect(invocation.arguments.contains("model_reasoning_effort=\"none\""))
            #expect(invocation.arguments.contains("Reply with OK only."))
            }
        )

        try await starter.startWindow(
            using: CodexWindowStartRequest(
                authFileURL: authURL,
                configURL: configURL,
                codexBinary: "codex",
                environment: [
                    "PATH": "/tmp/test-bin",
                    "HTTPS_PROXY": "http://proxy.test",
                    "CODEX_THREAD_ID": "thread-123",
                    "OPENAI_API_KEY": "secret",
                ]
            )
        )

        let invocation = try #require(await recorder.value())
        #expect(!FileManager.default.fileExists(atPath: invocation.temporaryRootURL.path))
    }

    @Test
    func isolatedWindowStarterPersistsUpdatedAuthBackToSourceFile() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("saved/auth.json")
        let configURL = root.appendingPathComponent("live/.codex/config.toml")
        try writeAuth(
            authURL,
            payload: authPayload(
                accountID: "acct-refresh",
                tokenSeed: "stale",
                userID: "user-refresh",
                email: "refresh@example.com",
                planType: "team"
            )
        )

        let starter = IsolatedCodexExecWindowStarter(
            syncGuard: CodexAuthTokenSyncGuard(storageURL: root.appendingPathComponent("retired-window-tokens.json")),
            runner: { invocation in
            let isolatedAuthURL = invocation.homeDirectoryURL.appendingPathComponent(".codex/auth.json")
            let copiedAuth = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: isolatedAuthURL))
            #expect(copiedAuth.tokens?.accessToken == "access-stale")

            try writeAuth(
                isolatedAuthURL,
                payload: authPayload(
                    accountID: "acct-refresh",
                    tokenSeed: "fresh",
                    userID: "user-refresh",
                    email: "refresh@example.com",
                    planType: "team"
                )
            )
            }
        )

        try await starter.startWindow(
            using: CodexWindowStartRequest(
                authFileURL: authURL,
                configURL: configURL,
                codexBinary: "codex",
                environment: [:]
            )
        )

        let refreshedAuth = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: authURL))
        #expect(refreshedAuth.tokens?.accessToken == "access-fresh")
        #expect(refreshedAuth.tokens?.refreshToken == "refresh-fresh")
    }

    @Test
    func isolatedWindowStarterRefusesUpdatedAuthForDifferentUserSharingAccountID() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("saved/auth.json")
        let configURL = root.appendingPathComponent("live/.codex/config.toml")
        try writeAuth(
            authURL,
            payload: authPayload(
                accountID: "acct-shared",
                tokenSeed: "original",
                userID: "user-original",
                email: "original@example.com",
                planType: "team"
            )
        )

        let starter = IsolatedCodexExecWindowStarter(
            syncGuard: CodexAuthTokenSyncGuard(storageURL: root.appendingPathComponent("retired-window-tokens.json")),
            runner: { invocation in
            let isolatedAuthURL = invocation.homeDirectoryURL.appendingPathComponent(".codex/auth.json")
            let copiedAuth = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: isolatedAuthURL))
            #expect(copiedAuth.tokens?.accessToken == "access-original")

            try writeAuth(
                isolatedAuthURL,
                payload: authPayload(
                    accountID: "acct-shared",
                    tokenSeed: "other",
                    userID: "user-other",
                    email: "other@example.com",
                    planType: "team"
                )
            )
            }
        )

        try await starter.startWindow(
            using: CodexWindowStartRequest(
                authFileURL: authURL,
                configURL: configURL,
                codexBinary: "codex",
                environment: [:]
            )
        )

        let savedAuth = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: authURL))
        #expect(savedAuth.tokens?.accessToken == "access-original")
        #expect(savedAuth.tokens?.refreshToken == "refresh-original")
    }

    @Test
    func isolatedWindowStarterRefusesUpdatedOAuthAuthWithoutIdentity() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("saved/auth.json")
        let configURL = root.appendingPathComponent("live/.codex/config.toml")
        try writeAuth(
            authURL,
            payload: authPayload(
                accountID: "acct-primary",
                tokenSeed: "original",
                userID: "user-primary",
                email: "primary@example.com",
                planType: "team"
            )
        )

        let starter = IsolatedCodexExecWindowStarter(
            syncGuard: CodexAuthTokenSyncGuard(storageURL: root.appendingPathComponent("retired-window-tokens.json")),
            runner: { invocation in
            let isolatedAuthURL = invocation.homeDirectoryURL.appendingPathComponent(".codex/auth.json")
            try writeAuth(
                isolatedAuthURL,
                payload: StoredAuthPayload(
                    authMode: "chatgpt",
                    lastRefresh: "2026-04-08T00:00:00Z",
                    tokens: AuthTokens(
                        accountID: nil,
                        accessToken: "access-unidentified",
                        idToken: nil,
                        refreshToken: "refresh-unidentified"
                    ),
                    openAIAPIKey: nil
                )
            )
            }
        )

        try await starter.startWindow(
            using: CodexWindowStartRequest(
                authFileURL: authURL,
                configURL: configURL,
                codexBinary: "codex",
                environment: [:]
            )
        )

        let savedAuth = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: authURL))
        #expect(savedAuth.tokens?.accessToken == "access-original")
        #expect(savedAuth.tokens?.refreshToken == "refresh-original")
    }

    @Test
    func isolatedWindowStarterRefusesAuthRefreshThatDropsRefreshToken() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("saved/auth.json")
        let configURL = root.appendingPathComponent("live/.codex/config.toml")
        try writeAuth(
            authURL,
            payload: authPayload(
                accountID: "acct-loss",
                tokenSeed: "original",
                userID: "user-loss",
                email: "loss@example.com",
                planType: "team"
            )
        )

        let starter = IsolatedCodexExecWindowStarter(
            syncGuard: CodexAuthTokenSyncGuard(storageURL: root.appendingPathComponent("retired-window-tokens.json")),
            runner: { invocation in
                let isolatedAuthURL = invocation.homeDirectoryURL.appendingPathComponent(".codex/auth.json")
                try writeAuth(
                    isolatedAuthURL,
                    payload: StoredAuthPayload(
                        authMode: "chatgpt",
                        lastRefresh: "2026-04-08T00:00:00Z",
                        tokens: AuthTokens(
                            accountID: "acct-loss",
                            accessToken: "access-new",
                            idToken: makeIDToken(
                                accountID: "acct-loss",
                                userID: "user-loss",
                                email: "loss@example.com",
                                planType: "team"
                            ),
                            refreshToken: nil
                        ),
                        openAIAPIKey: nil
                    )
                )
            }
        )

        try await starter.startWindow(
            using: CodexWindowStartRequest(
                authFileURL: authURL,
                configURL: configURL,
                codexBinary: "codex",
                environment: [:]
            )
        )

        let savedAuth = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: authURL))
        #expect(savedAuth.tokens?.accessToken == "access-original")
        #expect(savedAuth.tokens?.refreshToken == "refresh-original")
    }

    @Test
    func isolatedWindowStarterFallsBackToNextReasoningEffortAndMiniModelWhenNeeded() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let authURL = root.appendingPathComponent("saved/auth.json")
        let configURL = root.appendingPathComponent("live/.codex/config.toml")
        try writeAuth(
            authURL,
            payload: authPayload(
                accountID: "acct-fallback",
                tokenSeed: "fallback",
                userID: "user-fallback",
                email: "fallback@example.com",
                planType: "team"
            )
        )

        let recorder = WindowStartInvocationRecorder()
        let starter = IsolatedCodexExecWindowStarter(
            syncGuard: CodexAuthTokenSyncGuard(storageURL: root.appendingPathComponent("retired-window-tokens.json")),
            runner: { invocation in
            await recorder.record(invocation)

            switch await recorder.values().count {
            case 1:
                throw CodexWindowStarterError.processFailed(
                    status: 1,
                    output: "invalid value for model_reasoning_effort"
                )
            case 2:
                throw CodexWindowStarterError.processFailed(
                    status: 1,
                    output: "model gpt-5.4-mini not found"
                )
            case 3:
                return
            default:
                Issue.record("Unexpected extra fallback attempt.")
            }
            }
        )

        try await starter.startWindow(
            using: CodexWindowStartRequest(
                authFileURL: authURL,
                configURL: configURL,
                codexBinary: "codex",
                environment: [:]
            )
        )

        let invocations = await recorder.values()
        #expect(invocations.count == 3)
        #expect(argumentValue(after: "-m", in: invocations[0].arguments) == "gpt-5.4-mini")
        #expect(invocations[0].arguments.contains("model_reasoning_effort=\"none\""))
        #expect(argumentValue(after: "-m", in: invocations[1].arguments) == "gpt-5.4-mini")
        #expect(invocations[1].arguments.contains("model_reasoning_effort=\"minimal\""))
        #expect(argumentValue(after: "-m", in: invocations[2].arguments) == "gpt-5-mini")
        #expect(invocations[2].arguments.contains("model_reasoning_effort=\"none\""))
    }

    @Test
    func codexHomeCloneUsesPrivateAuthAndSharedHomeLinks() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceHomeURL = root.appendingPathComponent("real-home/.codex", isDirectory: true)
        let sourceKeychainsURL = root.appendingPathComponent("real-home/Library/Keychains", isDirectory: true)
        let savedAuthURL = root.appendingPathComponent("saved/auth.json")
        let temporaryRootURL = root.appendingPathComponent("session", isDirectory: true)
        try writeAuth(
            sourceHomeURL.appendingPathComponent("auth.json"),
            payload: authPayload(accountID: "acct-live", tokenSeed: "live")
        )
        try writeAuth(
            savedAuthURL,
            payload: authPayload(accountID: "acct-saved", tokenSeed: "saved")
        )
        try FileManager.default.createDirectory(
            at: sourceHomeURL.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "history\n".write(
            to: sourceHomeURL.appendingPathComponent("history.jsonl"),
            atomically: true,
            encoding: .utf8
        )
        try Data([1, 2, 3]).write(to: sourceHomeURL.appendingPathComponent("state_5.sqlite"))
        try FileManager.default.createDirectory(at: sourceKeychainsURL, withIntermediateDirectories: true)

        let clone = try CodexHomeClonePreparer().prepareClone(
            sourceCodexHomeURL: sourceHomeURL,
            sourceAuthFileURL: savedAuthURL,
            temporaryRootURL: temporaryRootURL
        )

        let clonedAuth = try JSONDecoder().decode(
            StoredAuthPayload.self,
            from: Data(contentsOf: clone.authFileURL)
        )
        #expect(clonedAuth.tokens?.accessToken == "access-saved")
        #expect(
            clone.codexHomeURL
                .appendingPathComponent("history.jsonl")
                .resolvingSymlinksInPath()
                .path == sourceHomeURL.appendingPathComponent("history.jsonl").path
        )
        #expect(
            clone.codexHomeURL
                .appendingPathComponent("sessions")
                .resolvingSymlinksInPath()
                .path == sourceHomeURL.appendingPathComponent("sessions").path
        )
        #expect(
            clone.codexHomeURL
                .appendingPathComponent("state_5.sqlite")
                .resolvingSymlinksInPath()
                .path == sourceHomeURL.appendingPathComponent("state_5.sqlite").path
        )
        #expect(
            clone.fallbackHomeURL
                .appendingPathComponent(".codex")
                .resolvingSymlinksInPath()
                .path == clone.codexHomeURL.path
        )
        #expect(
            clone.fallbackHomeURL
                .appendingPathComponent("Library/Keychains")
                .resolvingSymlinksInPath()
                .path == sourceKeychainsURL.path
        )
    }

    @Test
    func codexHomeCloneMergesAtomicallyRewrittenSharedGlobalStateFiles() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let sourceHomeURL = root.appendingPathComponent("real-home/.codex", isDirectory: true)
        let savedAuthURL = root.appendingPathComponent("saved/auth.json")
        let temporaryRootURL = root.appendingPathComponent("session", isDirectory: true)
        let stateURL = sourceHomeURL.appendingPathComponent(".codex-global-state.json")
        let stateBackupURL = sourceHomeURL.appendingPathComponent(".codex-global-state.json.bak")
        try writeAuth(
            sourceHomeURL.appendingPathComponent("auth.json"),
            payload: authPayload(accountID: "acct-live", tokenSeed: "live")
        )
        try writeAuth(
            savedAuthURL,
            payload: authPayload(accountID: "acct-saved", tokenSeed: "saved")
        )
        try #"{"source":true}"#.write(to: stateURL, atomically: true, encoding: .utf8)
        try #"{"sourceBackup":true}"#.write(to: stateBackupURL, atomically: true, encoding: .utf8)

        let preparer = CodexHomeClonePreparer()
        let clone = try preparer.prepareClone(
            sourceCodexHomeURL: sourceHomeURL,
            sourceAuthFileURL: savedAuthURL,
            temporaryRootURL: temporaryRootURL
        )
        let cloneStateURL = clone.codexHomeURL.appendingPathComponent(".codex-global-state.json")
        let cloneStateBackupURL = clone.codexHomeURL.appendingPathComponent(".codex-global-state.json.bak")

        try FileManager.default.removeItem(at: cloneStateURL)
        try FileManager.default.removeItem(at: cloneStateBackupURL)
        try #"{"clone":true}"#.write(to: cloneStateURL, atomically: true, encoding: .utf8)
        try #"{"cloneBackup":true}"#.write(to: cloneStateBackupURL, atomically: true, encoding: .utf8)

        let mergedNames = try preparer.mergeNewNonAuthItems(from: clone, into: sourceHomeURL)

        #expect(Set(mergedNames) == [".codex-global-state.json", ".codex-global-state.json.bak"])
        #expect(try String(contentsOf: stateURL, encoding: .utf8) == #"{"clone":true}"#)
        #expect(try String(contentsOf: stateBackupURL, encoding: .utf8) == #"{"cloneBackup":true}"#)
    }

    @Test
    func guardedAuthSyncWritesFreshTokensAndRetiresPreviousAccessAndRefresh() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let savedAuthURL = root.appendingPathComponent("saved/auth.json")
        let updatedAuthURL = root.appendingPathComponent("session/auth.json")
        let historyURL = root.appendingPathComponent("history/retired.json")
        try writeAuth(
            savedAuthURL,
            payload: authPayload(
                accountID: "acct-sync",
                tokenSeed: "old",
                userID: "user-sync",
                email: "sync@example.com"
            )
        )
        try writeAuth(
            updatedAuthURL,
            payload: authPayload(
                accountID: "acct-sync",
                tokenSeed: "fresh",
                userID: "user-sync",
                email: "sync@example.com"
            )
        )

        let guardStore = CodexAuthTokenSyncGuard(storageURL: historyURL)
        let result = try await guardStore.syncUpdatedAuth(from: updatedAuthURL, backTo: savedAuthURL)
        let savedPayload = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: savedAuthURL))
        let retiredTokens = try await guardStore.retiredTokens()

        #expect(result == .written)
        #expect(savedPayload.tokens?.accessToken == "access-fresh")
        #expect(savedPayload.tokens?.refreshToken == "refresh-fresh")
        #expect(retiredTokens.contains("access-old"))
        #expect(retiredTokens.contains("refresh-old"))
        #expect(!retiredTokens.contains(savedPayload.tokens?.idToken ?? ""))
    }

    @Test
    func guardedAuthSyncRejectsRetiredAccessOrRefreshToken() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let savedAuthURL = root.appendingPathComponent("saved/auth.json")
        let updatedAuthURL = root.appendingPathComponent("session/auth.json")
        let historyURL = root.appendingPathComponent("history/retired.json")
        try writeAuth(
            savedAuthURL,
            payload: authPayload(accountID: "acct-stale", tokenSeed: "current")
        )
        try writeAuth(
            updatedAuthURL,
            payload: authPayload(accountID: "acct-stale", tokenSeed: "stale")
        )

        let guardStore = CodexAuthTokenSyncGuard(storageURL: historyURL)
        try await guardStore.retire(["access-stale"])
        let result = try await guardStore.syncUpdatedAuth(from: updatedAuthURL, backTo: savedAuthURL)
        let savedPayload = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: savedAuthURL))

        #expect(result == .rejectedStaleToken)
        #expect(savedPayload.tokens?.accessToken == "access-current")
        #expect(savedPayload.tokens?.refreshToken == "refresh-current")
    }

    @Test
    func guardedAuthSyncRejectsOAuthTokenLoss() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let savedAuthURL = root.appendingPathComponent("saved/auth.json")
        let updatedAuthURL = root.appendingPathComponent("session/auth.json")
        let historyURL = root.appendingPathComponent("history/retired.json")
        try writeAuth(
            savedAuthURL,
            payload: authPayload(
                accountID: "acct-loss",
                tokenSeed: "current",
                userID: "user-loss",
                email: "loss@example.com"
            )
        )
        try writeAuth(
            updatedAuthURL,
            payload: StoredAuthPayload(
                authMode: "chatgpt",
                lastRefresh: "2026-04-08T00:00:00Z",
                tokens: AuthTokens(
                    accountID: "acct-loss",
                    accessToken: "access-new",
                    idToken: makeIDToken(accountID: "acct-loss", userID: "user-loss", email: "loss@example.com", planType: nil),
                    refreshToken: nil
                ),
                openAIAPIKey: nil
            )
        )

        let guardStore = CodexAuthTokenSyncGuard(storageURL: historyURL)
        let result = try await guardStore.syncUpdatedAuth(from: updatedAuthURL, backTo: savedAuthURL)
        let savedPayload = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: savedAuthURL))

        #expect(result == .rejectedUnusableAuth)
        #expect(savedPayload.tokens?.accessToken == "access-current")
        #expect(savedPayload.tokens?.refreshToken == "refresh-current")
    }

    @Test
    func guardedAuthSyncIgnoresAccountIDIDTokenAndAPIKeyForTokenHistory() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let savedAuthURL = root.appendingPathComponent("saved/auth.json")
        let updatedAuthURL = root.appendingPathComponent("session/auth.json")
        let historyURL = root.appendingPathComponent("history/retired.json")
        try writeAuth(
            savedAuthURL,
            payload: authPayload(accountID: "acct-ignore", tokenSeed: "old")
        )
        try writeAuth(
            updatedAuthURL,
            payload: StoredAuthPayload(
                authMode: "chatgpt",
                lastRefresh: "2026-04-08T00:00:00Z",
                tokens: AuthTokens(
                    accountID: "acct-ignore",
                    accessToken: "access-new",
                    idToken: "ignored-id-token",
                    refreshToken: "refresh-new"
                ),
                openAIAPIKey: "ignored-api-key"
            )
        )

        let guardStore = CodexAuthTokenSyncGuard(storageURL: historyURL)
        try await guardStore.retire(["acct-ignore", "ignored-id-token", "ignored-api-key"])
        let result = try await guardStore.syncUpdatedAuth(from: updatedAuthURL, backTo: savedAuthURL)
        let savedPayload = try JSONDecoder().decode(StoredAuthPayload.self, from: Data(contentsOf: savedAuthURL))

        #expect(result == .written)
        #expect(savedPayload.tokens?.accessToken == "access-new")
        #expect(savedPayload.tokens?.refreshToken == "refresh-new")
    }

    @Test
    func guardedAuthSyncTreatsIdenticalAuthAsNoOpEvenWhenTokenWasRetired() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let savedAuthURL = root.appendingPathComponent("saved/auth.json")
        let updatedAuthURL = root.appendingPathComponent("session/auth.json")
        let historyURL = root.appendingPathComponent("history/retired.json")
        let payload = authPayload(accountID: "acct-same", tokenSeed: "same")
        try writeAuth(savedAuthURL, payload: payload)
        try writeAuth(updatedAuthURL, payload: payload)

        let guardStore = CodexAuthTokenSyncGuard(storageURL: historyURL)
        try await guardStore.retire(["access-same"])
        let result = try await guardStore.syncUpdatedAuth(from: updatedAuthURL, backTo: savedAuthURL)

        #expect(result == .unchanged)
    }

    @Test
    func codexCLIStatusProbeParsesHourlyAndWeeklyResets() throws {
        let now = Date(timeIntervalSince1970: 1_775_606_400)
        let text = """
        Credits: 12.0
        5h limit 32% left resets 19:00
        Weekly limit 55% left resets 23:50 on 12 Apr
        """

        let parsed = try CodexCLIStatusProbe.parse(text: text, now: now)

        #expect(parsed.fiveHourPercentLeft == 32)
        #expect(parsed.weeklyPercentLeft == 55)
        #expect(parsed.fiveHourResetDescription == "19:00")
        #expect(parsed.weeklyResetDescription == "23:50 on 12 Apr")
    }
}

private func makeTempDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func oauthUsageResponseData(
    planType: String,
    primaryUsedPercent: Int,
    weeklyUsedPercent: Int
) -> Data {
    let json = """
    {
      "plan_type": "\(planType)",
      "rate_limit": {
        "primary_window": {
          "used_percent": \(primaryUsedPercent),
          "reset_at": 1775624600,
          "limit_window_seconds": 18000
        },
        "secondary_window": {
          "used_percent": \(weeklyUsedPercent),
          "reset_at": 1776254400,
          "limit_window_seconds": 604800
        }
      }
    }
    """
    return Data(json.utf8)
}

private func writeRawSnapshotStore(
    _ snapshots: [String: QuotaSnapshot],
    to url: URL
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(snapshots)
    try data.write(to: url, options: .atomic)
}

private func readRawSnapshotStore(from url: URL) throws -> [String: QuotaSnapshot] {
    let data = try Data(contentsOf: url)
    guard !data.isEmpty else {
        return [:]
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode([String: QuotaSnapshot].self, from: data)
}

private func authPayload(
    accountID: String,
    tokenSeed: String,
    userID: String? = nil,
    email: String? = nil,
    planType: String? = nil
) -> StoredAuthPayload {
    StoredAuthPayload(
        authMode: "chatgpt",
        lastRefresh: "2026-04-08T00:00:00Z",
        tokens: AuthTokens(
            accountID: accountID,
            accessToken: "access-\(tokenSeed)",
            idToken: makeIDToken(accountID: accountID, userID: userID, email: email, planType: planType),
            refreshToken: "refresh-\(tokenSeed)"
        ),
        openAIAPIKey: nil
    )
}

private func writeAuth(_ url: URL, payload: StoredAuthPayload) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(payload)
    try data.write(to: url)
}

private func writeRateLimitDatabase(
    at url: URL,
    payloadColumn: String,
    rows: [(ts: Int, payload: String)]
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: url)

    let createTableSQL = "create table logs (id integer primary key autoincrement, ts integer not null, \(payloadColumn) text not null);"
    let insertSQL = rows.map { row in
        let escapedPayload = row.payload.replacingOccurrences(of: "'", with: "''")
        return "insert into logs (ts, \(payloadColumn)) values (\(row.ts), '\(escapedPayload)');"
    }.joined(separator: "\n")

    try runSQLite(databaseURL: url, sql: "\(createTableSQL)\n\(insertSQL)")
}

private func runSQLite(databaseURL: URL, sql: String) throws {
    try withSQLiteShellLock {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [databaseURL.path, sql]
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "sqlite3 failed"
            throw NSError(domain: "CoreTests", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: errorMessage
            ])
        }
    }
}

private func withSQLiteShellLock<T>(_ body: () throws -> T) throws -> T {
    let lockPath = FileManager.default.temporaryDirectory
        .appendingPathComponent("CodexAuthRotator.sqlite.lock")
        .path
    let fileDescriptor = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard fileDescriptor >= 0 else {
        throw NSError(domain: "CoreTests", code: 500, userInfo: [
            NSLocalizedDescriptionKey: "Unable to create the SQLite shell lock."
        ])
    }

    defer { close(fileDescriptor) }

    guard flock(fileDescriptor, LOCK_EX) == 0 else {
        throw NSError(domain: "CoreTests", code: 500, userInfo: [
            NSLocalizedDescriptionKey: "Unable to acquire the SQLite shell lock."
        ])
    }

    defer { flock(fileDescriptor, LOCK_UN) }

    return try body()
}

private func jsonString(for event: CodexRateLimitEvent) -> String {
    let encoder = JSONEncoder()
    let data = try! encoder.encode(event)
    return String(decoding: data, as: UTF8.self)
}

private actor WindowStartInvocationRecorder {
    private var invocations: [CodexWindowStartInvocation] = []

    func record(_ invocation: CodexWindowStartInvocation) {
        invocations.append(invocation)
    }

    func value() -> CodexWindowStartInvocation? {
        invocations.last
    }

    func values() -> [CodexWindowStartInvocation] {
        invocations
    }
}

private func argumentValue(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag),
          arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func sampleGroup(
    accountID: String,
    trackingKey: String? = nil,
    fingerprint: String,
    folderName: String,
    planType: String? = nil
) -> DuplicateGroup {
    let folderURL = URL(fileURLWithPath: "/tmp/\(folderName)")
    let parsed = FolderNameParser.parse(folderName)
    let record = ScannedAuthRecord(
        id: "\(fingerprint)|\(folderName)",
        authFileURL: folderURL.appendingPathComponent("auth.json"),
        folderURL: folderURL,
        relativeFolderPath: folderName,
        topLevelFolderName: "sample",
        folderName: folderName,
        parsedFolderName: parsed,
        identity: FolderNameParser.inferIdentity(topLevelFolderName: "sample", baseLabel: parsed.baseLabel),
        trackingKey: trackingKey ?? "account:\(accountID)",
        accountID: accountID,
        authFingerprint: fingerprint,
        planType: planType
    )
    return DuplicateGroup(
        authFingerprint: fingerprint,
        trackingKey: record.trackingKey,
        accountID: accountID,
        records: [record]
    )
}

private func makeIDToken(accountID: String, userID: String?, email: String?, planType: String?) -> String? {
    guard userID != nil || email != nil || planType != nil else {
        return nil
    }

    let header = ["alg": "none", "typ": "JWT"]
    let payload = TestIDTokenPayload(
        email: email,
        auth: TestOpenAIAuthClaims(
            chatGPTAccountID: accountID,
            chatGPTPlanType: planType,
            userID: userID
        )
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]

    func segment<T: Encodable>(_ value: T) -> String {
        let data = try! encoder.encode(AnyEncodable(value))
        return data
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    return "\(segment(header)).\(segment(payload)).signature"
}

private struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        self.encodeImpl = value.encode(to:)
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

private struct TestIDTokenPayload: Encodable {
    let email: String?
    let auth: TestOpenAIAuthClaims

    enum CodingKeys: String, CodingKey {
        case email
        case auth = "https://api.openai.com/auth"
    }
}

private struct TestOpenAIAuthClaims: Encodable {
    let chatGPTAccountID: String
    let chatGPTPlanType: String?
    let userID: String?

    enum CodingKeys: String, CodingKey {
        case chatGPTAccountID = "chatgpt_account_id"
        case chatGPTPlanType = "chatgpt_plan_type"
        case userID = "user_id"
    }
}
