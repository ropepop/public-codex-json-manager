import Foundation

public enum CodexDirectStatusReaderError: LocalizedError, Sendable {
    case missingFile(URL)
    case unresolvedIdentity
    case missingSnapshot

    public var errorDescription: String? {
        switch self {
        case let .missingFile(url):
            return "Auth file not found at \(url.path)."
        case .unresolvedIdentity:
            return "Auth file does not contain a usable account identity."
        case .missingSnapshot:
            return "Direct usage check did not return quota details."
        }
    }
}

public struct CodexStatusReader: Sendable {
    public typealias OAuthFetcher = @Sendable (CodexOAuthCredentials, URL) async throws -> CodexLiveQuotaPayload
    public typealias OAuthTokenRefresher = @Sendable (CodexOAuthCredentials) async throws -> CodexOAuthCredentials
    public typealias CLIUsageFetcher = @Sendable (String, [String: String]) async throws -> CodexLiveQuotaPayload

    public let liveAuthURL: URL
    public let configURL: URL
    public let primaryStateDatabaseURL: URL
    public let fallbackLogDatabaseURL: URL
    public let codexBinary: String
    public let environment: [String: String]

    private let oauthFetcher: OAuthFetcher
    private let oauthTokenRefresher: OAuthTokenRefresher
    private let cliRPCFetcher: CLIUsageFetcher
    private let cliPTYFetcher: CLIUsageFetcher
    private let nowProvider: @Sendable () -> Date

    private static let tokenRefreshLeeway: TimeInterval = 5 * 60

    public init(
        liveAuthURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json"),
        configURL: URL? = nil,
        primaryStateDatabaseURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite"),
        fallbackLogDatabaseURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/logs_1.sqlite"),
        codexBinary: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        oauthFetcher: OAuthFetcher? = nil,
        oauthTokenRefresher: OAuthTokenRefresher? = nil,
        cliRPCFetcher: CLIUsageFetcher? = nil,
        cliPTYFetcher: CLIUsageFetcher? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.liveAuthURL = liveAuthURL
        self.configURL = configURL ?? liveAuthURL.deletingLastPathComponent().appendingPathComponent("config.toml")
        self.primaryStateDatabaseURL = primaryStateDatabaseURL
        self.fallbackLogDatabaseURL = fallbackLogDatabaseURL
        self.codexBinary = codexBinary
        self.environment = environment
        self.oauthFetcher = oauthFetcher ?? { credentials, configURL in
            try await CodexOAuthUsageFetcher.fetchUsage(credentials: credentials, configURL: configURL)
        }
        self.oauthTokenRefresher = oauthTokenRefresher ?? { credentials in
            try await CodexOAuthTokenRefresher.refresh(credentials: credentials)
        }
        self.cliRPCFetcher = cliRPCFetcher ?? { binary, environment in
            try await CodexCLIRPCUsageFetcher.fetchUsage(codexBinary: binary, environment: environment)
        }
        self.cliPTYFetcher = cliPTYFetcher ?? { binary, environment in
            try CodexCLIStatusProbe.fetchUsage(codexBinary: binary, environment: environment)
        }
        self.nowProvider = now
    }

    public func readLiveStatus() async throws -> LiveCodexStatus? {
        guard FileManager.default.fileExists(atPath: liveAuthURL.path) else {
            return nil
        }

        let resolvedAuth = try readResolvedAuth(at: liveAuthURL)
        var planType = resolvedAuth.identity.planType

        if (try? CodexOAuthCredentialsStore.parse(data: resolvedAuth.authData)) != nil {
            if let liveStatus = try? await readOAuthStatus(
                authFileURL: liveAuthURL,
                resolvedAuth: resolvedAuth,
                overrideConfigURL: nil,
                existingPlanType: &planType
            ) {
                return liveStatus
            }
        }

        if let rpcPayload = try? await cliRPCFetcher(codexBinary, environment),
           let liveStatus = resolvedLiveStatus(
            accountID: resolvedAuth.identity.accountID,
            trackingKey: resolvedAuth.identity.trackingKey,
            email: resolvedAuth.identity.email,
            authFingerprint: resolvedAuth.authFingerprint,
            source: .cliRPC,
            payload: rpcPayload,
            existingPlanType: &planType
        ) {
            return liveStatus
        }

        if let ptyPayload = try? await cliPTYFetcher(codexBinary, environment),
           let liveStatus = resolvedLiveStatus(
            accountID: resolvedAuth.identity.accountID,
            trackingKey: resolvedAuth.identity.trackingKey,
            email: resolvedAuth.identity.email,
            authFingerprint: resolvedAuth.authFingerprint,
            source: .cliPTY,
            payload: ptyPayload,
            existingPlanType: &planType
        ) {
            return liveStatus
        }

        return LiveCodexStatus(
            accountID: resolvedAuth.identity.accountID,
            trackingKey: resolvedAuth.identity.trackingKey,
            email: resolvedAuth.identity.email,
            planType: planType,
            workspaceName: nil,
            authFingerprint: resolvedAuth.authFingerprint,
            snapshot: nil,
            source: .unknown
        )
    }

    public func readDirectOAuthStatus(
        authFileURL: URL,
        configURL overrideConfigURL: URL? = nil
    ) async throws -> LiveCodexStatus {
        let resolvedAuth = try readResolvedAuth(at: authFileURL)
        var planType = resolvedAuth.identity.planType
        guard let liveStatus = try await readOAuthStatus(
            authFileURL: authFileURL,
            resolvedAuth: resolvedAuth,
            overrideConfigURL: overrideConfigURL,
            existingPlanType: &planType
        ) else {
            throw CodexDirectStatusReaderError.missingSnapshot
        }

        return liveStatus
    }

    private func readOAuthStatus(
        authFileURL: URL,
        resolvedAuth: ResolvedAuth,
        overrideConfigURL: URL?,
        existingPlanType: inout String?
    ) async throws -> LiveCodexStatus? {
        var prepared = try await preparedOAuthCredentials(
            authFileURL: authFileURL,
            resolvedAuth: resolvedAuth
        )
        let resolvedConfigURL = overrideConfigURL ?? configURL
        let oauthPayload: CodexLiveQuotaPayload

        do {
            oauthPayload = try await oauthFetcher(prepared.credentials, resolvedConfigURL)
        } catch CodexOAuthFetchError.tokenExpired {
            prepared = try await refreshAfterExpiredToken(
                prepared,
                authFileURL: authFileURL
            )
            oauthPayload = try await oauthFetcher(prepared.credentials, resolvedConfigURL)
        }

        return resolvedLiveStatus(
            accountID: prepared.identity.accountID,
            trackingKey: prepared.identity.trackingKey,
            email: prepared.identity.email,
            authFingerprint: prepared.authFingerprint,
            source: .oauth,
            payload: oauthPayload,
            existingPlanType: &existingPlanType
        )
    }

    private func preparedOAuthCredentials(
        authFileURL: URL,
        resolvedAuth: ResolvedAuth
    ) async throws -> PreparedOAuthCredentials {
        let credentials = try CodexOAuthCredentialsStore.parse(data: resolvedAuth.authData)
        let prepared = PreparedOAuthCredentials(
            credentials: credentials,
            identity: resolvedAuth.identity,
            authFingerprint: resolvedAuth.authFingerprint,
            didRefresh: false
        )

        guard shouldRefresh(credentials, now: nowProvider()) else {
            return prepared
        }

        return try await refreshOAuthCredentials(
            prepared,
            authFileURL: authFileURL
        )
    }

    private func refreshAfterExpiredToken(
        _ prepared: PreparedOAuthCredentials,
        authFileURL: URL
    ) async throws -> PreparedOAuthCredentials {
        guard !prepared.didRefresh else {
            throw CodexOAuthFetchError.tokenExpired
        }
        guard !prepared.credentials.isAPIKey else {
            throw CodexOAuthFetchError.tokenExpired
        }
        return try await refreshOAuthCredentials(
            prepared,
            authFileURL: authFileURL
        )
    }

    private func refreshOAuthCredentials(
        _ prepared: PreparedOAuthCredentials,
        authFileURL: URL
    ) async throws -> PreparedOAuthCredentials {
        let refreshedCredentials = try await oauthTokenRefresher(prepared.credentials)
        try CodexOAuthCredentialsStore.writeRefreshedCredentials(
            refreshedCredentials,
            to: authFileURL,
            now: nowProvider()
        )
        let refreshedAuth = try readResolvedAuth(at: authFileURL)
        guard AuthAccountMatcher.sameAccount(prepared.identity, as: refreshedAuth.identity) else {
            throw CodexOAuthTokenRefreshError.invalidResponse("Renewed token identity did not match the saved account")
        }
        let persistedCredentials = try CodexOAuthCredentialsStore.parse(data: refreshedAuth.authData)
        return PreparedOAuthCredentials(
            credentials: persistedCredentials,
            identity: refreshedAuth.identity,
            authFingerprint: refreshedAuth.authFingerprint,
            didRefresh: true
        )
    }

    private func shouldRefresh(_ credentials: CodexOAuthCredentials, now: Date) -> Bool {
        guard CodexOAuthCredentialsStore.canRefresh(credentials),
              let expiresAt = CodexOAuthAccessToken.expirationDate(in: credentials.accessToken) else {
            return false
        }
        return expiresAt <= now.addingTimeInterval(Self.tokenRefreshLeeway)
    }

    private func resolvedLiveStatus(
        accountID: String,
        trackingKey: String,
        email: String?,
        authFingerprint: String,
        source: StatusSource,
        payload: CodexLiveQuotaPayload,
        existingPlanType: inout String?
    ) -> LiveCodexStatus? {
        let livePayload = payload
        if existingPlanType == nil {
            existingPlanType = livePayload.planType
        }
        guard let snapshot = livePayload.snapshot else {
            return nil
        }

        return LiveCodexStatus(
            accountID: accountID,
            trackingKey: trackingKey,
            email: email,
            planType: existingPlanType ?? livePayload.planType,
            workspaceName: livePayload.workspaceName,
            authFingerprint: authFingerprint,
            snapshot: snapshot,
            source: source
        )
    }

    private func readResolvedAuth(at authFileURL: URL) throws -> ResolvedAuth {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw CodexDirectStatusReaderError.missingFile(authFileURL)
        }

        let authData = try Data(contentsOf: authFileURL)
        let authPayload = try JSONDecoder().decode(StoredAuthPayload.self, from: authData)
        guard let resolvedIdentity = authPayload.resolvedIdentity() else {
            throw CodexDirectStatusReaderError.unresolvedIdentity
        }

        return ResolvedAuth(
            authData: authData,
            authFingerprint: AuthScanner.fingerprint(for: authData),
            identity: resolvedIdentity
        )
    }
}

private struct ResolvedAuth {
    let authData: Data
    let authFingerprint: String
    let identity: ResolvedAuthIdentity
}

private struct PreparedOAuthCredentials {
    let credentials: CodexOAuthCredentials
    let identity: ResolvedAuthIdentity
    let authFingerprint: String
    let didRefresh: Bool
}
