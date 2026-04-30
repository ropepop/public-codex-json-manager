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
    public typealias CLIUsageFetcher = @Sendable (String, [String: String]) async throws -> CodexLiveQuotaPayload

    public let liveAuthURL: URL
    public let configURL: URL
    public let primaryStateDatabaseURL: URL
    public let fallbackLogDatabaseURL: URL
    public let codexBinary: String
    public let environment: [String: String]

    private let oauthFetcher: OAuthFetcher
    private let cliRPCFetcher: CLIUsageFetcher
    private let cliPTYFetcher: CLIUsageFetcher

    public init(
        liveAuthURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json"),
        configURL: URL? = nil,
        primaryStateDatabaseURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/state_5.sqlite"),
        fallbackLogDatabaseURL: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/logs_1.sqlite"),
        codexBinary: String = "codex",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        oauthFetcher: OAuthFetcher? = nil,
        cliRPCFetcher: CLIUsageFetcher? = nil,
        cliPTYFetcher: CLIUsageFetcher? = nil
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
        self.cliRPCFetcher = cliRPCFetcher ?? { binary, environment in
            try await CodexCLIRPCUsageFetcher.fetchUsage(codexBinary: binary, environment: environment)
        }
        self.cliPTYFetcher = cliPTYFetcher ?? { binary, environment in
            try CodexCLIStatusProbe.fetchUsage(codexBinary: binary, environment: environment)
        }
    }

    public func readLiveStatus() async throws -> LiveCodexStatus? {
        guard FileManager.default.fileExists(atPath: liveAuthURL.path) else {
            return nil
        }

        let resolvedAuth = try readResolvedAuth(at: liveAuthURL)
        var planType = resolvedAuth.identity.planType

        if let credentials = try? CodexOAuthCredentialsStore.parse(data: resolvedAuth.authData) {
            if let oauthPayload = try? await oauthFetcher(credentials, configURL),
               let liveStatus = resolvedLiveStatus(
                accountID: resolvedAuth.identity.accountID,
                trackingKey: resolvedAuth.identity.trackingKey,
                email: resolvedAuth.identity.email,
                authFingerprint: resolvedAuth.authFingerprint,
                source: .oauth,
                payload: oauthPayload,
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
        let credentials = try CodexOAuthCredentialsStore.parse(data: resolvedAuth.authData)
        var planType = resolvedAuth.identity.planType
        let oauthPayload = try await oauthFetcher(credentials, overrideConfigURL ?? configURL)

        guard let liveStatus = resolvedLiveStatus(
            accountID: resolvedAuth.identity.accountID,
            trackingKey: resolvedAuth.identity.trackingKey,
            email: resolvedAuth.identity.email,
            authFingerprint: resolvedAuth.authFingerprint,
            source: .oauth,
            payload: oauthPayload,
            existingPlanType: &planType
        ) else {
            throw CodexDirectStatusReaderError.missingSnapshot
        }

        return liveStatus
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
