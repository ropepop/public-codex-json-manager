import CodexAuthRotatorCore
import Darwin
import Foundation

enum AppRuntimeConfiguration {
    static let safeVerificationEnvKey = "CODEX_AUTH_ROTATOR_SAFE_VERIFICATION"
    static let safeVerificationRootEnvKey = "CODEX_AUTH_ROTATOR_SAFE_ROOT"
    static let safeVerificationArgument = "--safe-verification"
    static let safeVerificationRootArgument = "--safe-verification-root"

    @MainActor
    static func makeStore(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = CommandLine.arguments
    ) -> AppStore {
        guard safeVerificationRequested(environment: environment, arguments: arguments) else {
            return AppStore()
        }

        do {
            return try makeSafeVerificationStore(rootURL: safeVerificationRoot(environment: environment, arguments: arguments))
        } catch {
            NSLog("Codex Auth Rotator safe verification setup failed: \(error.localizedDescription)")
            return fallbackSafeVerificationStore(rootURL: safeVerificationRoot(environment: environment, arguments: arguments))
        }
    }

    private static func safeVerificationRequested(environment: [String: String], arguments: [String]) -> Bool {
        if arguments.contains(safeVerificationArgument) {
            return true
        }

        guard let rawValue = environment[safeVerificationEnvKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }

        return ["1", "true", "yes", "on"].contains(rawValue)
    }

    private static func safeVerificationRoot(environment: [String: String], arguments: [String]) -> URL {
        if let argumentRoot = argumentValue(named: safeVerificationRootArgument, in: arguments) {
            return URL(fileURLWithPath: argumentRoot, isDirectory: true).standardizedFileURL
        }

        if let environmentRoot = environment[safeVerificationRootEnvKey], !environmentRoot.isEmpty {
            return URL(fileURLWithPath: environmentRoot, isDirectory: true).standardizedFileURL
        }

        return FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-rotator-safe-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
    }

    private static func argumentValue(named name: String, in arguments: [String]) -> String? {
        for index in arguments.indices {
            let argument = arguments[index]
            if argument == name, arguments.indices.contains(index + 1) {
                return arguments[index + 1]
            }

            let prefix = "\(name)="
            if argument.hasPrefix(prefix) {
                return String(argument.dropFirst(prefix.count))
            }
        }

        return nil
    }

    @MainActor
    private static func makeSafeVerificationStore(rootURL: URL) throws -> AppStore {
        let fixture = SafeVerificationFixture(rootURL: rootURL)
        try fixture.prepare()

        return AppStore(
            authRootPath: fixture.authStoreURL.path,
            populateStorageFolderEnabled: false,
            refreshInterval: .seconds15,
            autoRefreshSavedAccounts: false,
            statusReader: fixture.statusReader(),
            windowStarter: SafeVerificationWindowStarter(),
            desktopSessionStarter: SafeVerificationDesktopSessionStarter(),
            signInStarter: SafeVerificationSignInStarter(),
            managedApplicationClient: SafeVerificationManagedApplicationClient(),
            allowsManagedApplicationControl: false,
            saveDestinationOverrideStore: AuthSaveDestinationOverrideStore(storageURL: fixture.supportURL.appendingPathComponent("save-destination-overrides.json"))
        )
    }

    @MainActor
    private static func fallbackSafeVerificationStore(rootURL: URL) -> AppStore {
        let authStoreURL = rootURL.appendingPathComponent("auth-store", isDirectory: true)
        let supportURL = rootURL.appendingPathComponent("support", isDirectory: true)
        let liveAuthURL = rootURL.appendingPathComponent("home/.codex/auth.json")
        try? FileManager.default.createDirectory(at: authStoreURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: liveAuthURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        return AppStore(
            authRootPath: authStoreURL.path,
            populateStorageFolderEnabled: false,
            refreshInterval: .seconds15,
            autoRefreshSavedAccounts: false,
            statusReader: CodexStatusReader(
                liveAuthURL: liveAuthURL,
                primaryStateDatabaseURL: supportURL.appendingPathComponent("state_5.sqlite"),
                fallbackLogDatabaseURL: supportURL.appendingPathComponent("logs_1.sqlite"),
                codexBinary: "/usr/bin/false",
                environment: safeEnvironment(homeURL: rootURL.appendingPathComponent("home", isDirectory: true)),
                oauthFetcher: { _, _ in
                    CodexLiveQuotaPayload(planType: nil, snapshot: nil)
                },
                cliRPCFetcher: { _, _ in
                    CodexLiveQuotaPayload(planType: nil, snapshot: nil)
                },
                cliPTYFetcher: { _, _ in
                    CodexLiveQuotaPayload(planType: nil, snapshot: nil)
                }
            ),
            windowStarter: SafeVerificationWindowStarter(),
            desktopSessionStarter: SafeVerificationDesktopSessionStarter(),
            signInStarter: SafeVerificationSignInStarter(),
            managedApplicationClient: SafeVerificationManagedApplicationClient(),
            allowsManagedApplicationControl: false,
            saveDestinationOverrideStore: AuthSaveDestinationOverrideStore(storageURL: supportURL.appendingPathComponent("save-destination-overrides.json"))
        )
    }

    static func safeEnvironment(homeURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeURL.path
        environment["CODEX_HOME"] = homeURL.appendingPathComponent(".codex", isDirectory: true).path
        return environment
    }
}

private struct SafeVerificationFixture: Sendable {
    let rootURL: URL

    var authStoreURL: URL {
        rootURL.appendingPathComponent("auth-store", isDirectory: true)
    }

    var homeURL: URL {
        rootURL.appendingPathComponent("home", isDirectory: true)
    }

    var codexHomeURL: URL {
        homeURL.appendingPathComponent(".codex", isDirectory: true)
    }

    var liveAuthURL: URL {
        codexHomeURL.appendingPathComponent("auth.json")
    }

    var supportURL: URL {
        rootURL.appendingPathComponent("support", isDirectory: true)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: authStoreURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexHomeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)

        try writeAuth(
            authStoreURL.appendingPathComponent("verification-live@example.test/personal/auth.json"),
            payload: authPayload(
                accountID: "acct-verification-live",
                tokenSeed: "verification-live",
                userID: "user-verification-live",
                email: "verification-live@example.test",
                planType: "plus"
            )
        )
        try writeAuth(
            authStoreURL.appendingPathComponent("verification-team@example.test/team/auth.json"),
            payload: authPayload(
                accountID: "acct-verification-team",
                tokenSeed: "verification-team",
                userID: "user-verification-team",
                email: "verification-team@example.test",
                planType: "team"
            )
        )
        try writeAuth(
            authStoreURL.appendingPathComponent("verification-free@example.test/free/auth.json"),
            payload: authPayload(
                accountID: "acct-verification-free",
                tokenSeed: "verification-free",
                userID: "user-verification-free",
                email: "verification-free@example.test",
                planType: "free"
            )
        )
        try writeAuth(
            liveAuthURL,
            payload: authPayload(
                accountID: "acct-verification-live",
                tokenSeed: "verification-live",
                userID: "user-verification-live",
                email: "verification-live@example.test",
                planType: "plus"
            )
        )
    }

    func statusReader() -> CodexStatusReader {
        CodexStatusReader(
            liveAuthURL: liveAuthURL,
            primaryStateDatabaseURL: supportURL.appendingPathComponent("state_5.sqlite"),
            fallbackLogDatabaseURL: supportURL.appendingPathComponent("logs_1.sqlite"),
            codexBinary: "/usr/bin/false",
            environment: AppRuntimeConfiguration.safeEnvironment(homeURL: homeURL),
            oauthFetcher: { credentials, _ in
                CodexLiveQuotaPayload(
                    planType: planType(for: credentials.accessToken),
                    workspaceName: "Safe Verification",
                    snapshot: snapshot(for: credentials.accessToken)
                )
            },
            cliRPCFetcher: { _, _ in
                CodexLiveQuotaPayload(planType: nil, snapshot: nil)
            },
            cliPTYFetcher: { _, _ in
                CodexLiveQuotaPayload(planType: nil, snapshot: nil)
            }
        )
    }

    private func authPayload(
        accountID: String,
        tokenSeed: String,
        userID: String,
        email: String,
        planType: String
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
        try encoder.encode(payload).write(to: url)
    }

    private func makeIDToken(accountID: String, userID: String, email: String, planType: String) -> String {
        let header = #"{"alg":"none","typ":"JWT"}"#
        let payload = """
        {"email":"\(email)","https://api.openai.com/auth":{"chatgpt_account_id":"\(accountID)","chatgpt_plan_type":"\(planType)","user_id":"\(userID)"}}
        """
        return "\(base64URLEncoded(header)).\(base64URLEncoded(payload))."
    }

    private func base64URLEncoded(_ string: String) -> String {
        Data(string.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func planType(for accessToken: String) -> String {
        if accessToken.contains("verification-free") {
            return "free"
        }
        if accessToken.contains("verification-team") {
            return "team"
        }
        return "plus"
    }

    private func snapshot(for accessToken: String) -> QuotaSnapshot {
        let now = Date()
        let shortUsage = accessToken.contains("verification-team") ? 24 : 8
        let weeklyUsage = accessToken.contains("verification-free") ? 38 : 52

        return QuotaSnapshot(
            capturedAt: now,
            allowed: true,
            limitReached: false,
            primaryUsedPercent: shortUsage,
            primaryResetAt: now.addingTimeInterval(2 * 60 * 60),
            primaryWindowMinutes: accessToken.contains("verification-free") ? nil : 300,
            secondaryUsedPercent: weeklyUsage,
            secondaryResetAt: now.addingTimeInterval(3 * 24 * 60 * 60),
            secondaryWindowMinutes: 10_080
        )
    }
}

@MainActor
private final class SafeVerificationManagedApplicationClient: ManagedApplicationClient {
    func runningApplications(withBundleIdentifier _: String) -> [ManagedApplicationInstance] {
        []
    }

    func terminateApplication(_: ManagedApplicationInstance) -> Bool {
        false
    }

    func launchApplication(withBundleIdentifier _: String) async throws {}
}

private struct SafeVerificationWindowStarter: CodexWindowStarter {
    func startWindow(using _: CodexWindowStartRequest) async throws {}
}

private struct SafeVerificationDesktopSessionStarter: CodexDesktopSessionStarter {
    func startSession(
        using request: CodexDesktopSessionStartRequest,
        warningHandler _: @escaping @Sendable (String) -> Void,
        eventHandler: @escaping @Sendable (CodexDesktopSessionEvent) -> Void
    ) async throws {
        let sessionID = "safe-verification-\(UUID().uuidString)"
        eventHandler(
            CodexDesktopSessionEvent(
                sessionID: sessionID,
                trackingKey: request.accountTrackingKey,
                authFileURL: request.savedAuthFileURL,
                processIdentifier: 0,
                kind: .started
            )
        )
        eventHandler(
            CodexDesktopSessionEvent(
                sessionID: sessionID,
                trackingKey: request.accountTrackingKey,
                authFileURL: request.savedAuthFileURL,
                processIdentifier: 0,
                kind: .ended
            )
        )
    }
}

private struct SafeVerificationSignInStarter: CodexSignInStarter {
    func startSignIn(using _: CodexSignInStartRequest) async throws -> CodexSignInResult {
        throw CodexSignInStarterError.interrupted
    }
}
