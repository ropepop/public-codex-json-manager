import Foundation
import Darwin

public struct CodexLiveQuotaPayload: Hashable, Sendable {
    public let planType: String?
    public let workspaceName: String?
    public let snapshot: QuotaSnapshot?

    public init(planType: String?, workspaceName: String? = nil, snapshot: QuotaSnapshot?) {
        self.planType = planType
        self.workspaceName = workspaceName
        self.snapshot = snapshot
    }
}

public struct CodexOAuthCredentials: Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String?
    public let accountID: String?
    public let lastRefresh: Date?

    public init(
        accessToken: String,
        refreshToken: String,
        idToken: String?,
        accountID: String?,
        lastRefresh: Date?
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.lastRefresh = lastRefresh
    }
}

public enum CodexOAuthCredentialsError: LocalizedError, Sendable {
    case notFound
    case invalidJSON
    case missingTokens

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "Codex auth.json not found."
        case .invalidJSON:
            return "Codex auth.json could not be decoded."
        case .missingTokens:
            return "Codex auth.json does not contain OAuth tokens."
        }
    }
}

public enum CodexOAuthCredentialsStore {
    public static func load(from authFileURL: URL) throws -> CodexOAuthCredentials {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw CodexOAuthCredentialsError.notFound
        }

        return try parse(data: Data(contentsOf: authFileURL))
    }

    public static func parse(data: Data) throws -> CodexOAuthCredentials {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexOAuthCredentialsError.invalidJSON
        }

        if let apiKey = stringValue(in: json, snakeCaseKey: "OPENAI_API_KEY", camelCaseKey: "openAIAPIKey"),
           !apiKey.isEmpty {
            return CodexOAuthCredentials(
                accessToken: apiKey,
                refreshToken: "",
                idToken: nil,
                accountID: nil,
                lastRefresh: nil
            )
        }

        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = stringValue(in: tokens, snakeCaseKey: "access_token", camelCaseKey: "accessToken"),
              !accessToken.isEmpty else {
            throw CodexOAuthCredentialsError.missingTokens
        }

        return CodexOAuthCredentials(
            accessToken: accessToken,
            refreshToken: stringValue(in: tokens, snakeCaseKey: "refresh_token", camelCaseKey: "refreshToken") ?? "",
            idToken: stringValue(in: tokens, snakeCaseKey: "id_token", camelCaseKey: "idToken"),
            accountID: stringValue(in: tokens, snakeCaseKey: "account_id", camelCaseKey: "accountId"),
            lastRefresh: parseDate(json["last_refresh"])
        )
    }

    private static func parseDate(_ raw: Any?) -> Date? {
        guard let string = raw as? String, !string.isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = formatter.date(from: string) {
            return parsed
        }

        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }

    private static func stringValue(
        in dictionary: [String: Any],
        snakeCaseKey: String,
        camelCaseKey: String
    ) -> String? {
        if let value = dictionary[snakeCaseKey] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        if let value = dictionary[camelCaseKey] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return nil
    }
}

public struct CodexOAuthUsageResponse: Decodable, Sendable {
    public let planType: String?
    public let rateLimit: RateLimit?

    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }

    public struct RateLimit: Decodable, Sendable {
        public let primaryWindow: Window?
        public let secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public struct Window: Decodable, Sendable {
        public let usedPercent: Int
        public let resetAt: Int
        public let limitWindowSeconds: Int

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }
    }
}

public enum CodexOAuthFetchError: LocalizedError, Sendable {
    case unauthorized
    case invalidResponse
    case serverError(Int)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Codex OAuth credentials were rejected."
        case .invalidResponse:
            return "Codex OAuth usage response was invalid."
        case let .serverError(code):
            return "Codex OAuth usage request failed with status \(code)."
        case let .network(message):
            return "Codex OAuth usage request failed: \(message)"
        }
    }
}

public enum CodexOAuthUsageFetcher {
    public typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let defaultBaseURL = "https://chatgpt.com/backend-api"

    public static func fetchUsage(
        credentials: CodexOAuthCredentials,
        configURL: URL,
        now: Date = Date(),
        dataLoader: DataLoader? = nil
    ) async throws -> CodexLiveQuotaPayload {
        let request = makeRequest(credentials: credentials, configURL: configURL)
        let loader = dataLoader ?? defaultDataLoader

        do {
            let (data, response) = try await loader(request)

            switch response.statusCode {
            case 200 ... 299:
                let decoded = try JSONDecoder().decode(CodexOAuthUsageResponse.self, from: data)
                return CodexLiveQuotaPayload(
                    planType: decoded.planType?.trimmingCharacters(in: .whitespacesAndNewlines),
                    workspaceName: nil,
                    snapshot: snapshot(from: decoded, capturedAt: now)
                )
            case 401, 403:
                throw CodexOAuthFetchError.unauthorized
            default:
                throw CodexOAuthFetchError.serverError(response.statusCode)
            }
        } catch let error as CodexOAuthFetchError {
            throw error
        } catch _ as DecodingError {
            throw CodexOAuthFetchError.invalidResponse
        } catch {
            throw CodexOAuthFetchError.network(error.localizedDescription)
        }
    }

    public static func makeRequest(credentials: CodexOAuthCredentials, configURL: URL) -> URLRequest {
        var request = URLRequest(url: resolveUsageURL(configURL: configURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexAuthRotator", forHTTPHeaderField: "User-Agent")

        if let accountID = credentials.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        return request
    }

    public static func resolveUsageURL(configURL: URL) -> URL {
        let configContents = try? String(contentsOf: configURL, encoding: .utf8)
        let parsedBaseURL = configContents.flatMap(parseChatGPTBaseURL(from:))
        let normalizedBaseURL = normalizeBaseURL(parsedBaseURL ?? defaultBaseURL)
        return URL(string: normalizedBaseURL + "/wham/usage")
            ?? URL(string: defaultBaseURL + "/wham/usage")!
    }

    private static func snapshot(from response: CodexOAuthUsageResponse, capturedAt: Date) -> QuotaSnapshot? {
        guard let rateLimit = response.rateLimit else {
            return nil
        }

        let primary = rateLimit.primaryWindow.map {
            RateLimitWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: $0.limitWindowSeconds / 60,
                resetAfterSeconds: nil,
                resetAt: $0.resetAt
            )
        }
        let secondary = rateLimit.secondaryWindow.map {
            RateLimitWindow(
                usedPercent: $0.usedPercent,
                windowMinutes: $0.limitWindowSeconds / 60,
                resetAfterSeconds: nil,
                resetAt: $0.resetAt
            )
        }

        let normalized = QuotaSnapshot(
            event: CodexRateLimitEvent(
                type: "codex.rate_limits",
                planType: response.planType,
                rateLimits: RateLimitsPayload(
                    allowed: !isBlocked(primary: primary, secondary: secondary),
                    limitReached: isBlocked(primary: primary, secondary: secondary),
                    primary: primary,
                    secondary: secondary
                )
            ),
            capturedAt: capturedAt
        )
        return normalized
    }

    private static func isBlocked(primary: RateLimitWindow?, secondary: RateLimitWindow?) -> Bool {
        QuotaAvailabilityPolicy.blocks(usedPercent: primary?.usedPercent, windowMinutes: primary?.windowMinutes)
            || QuotaAvailabilityPolicy.blocks(usedPercent: secondary?.usedPercent, windowMinutes: secondary?.windowMinutes)
    }

    private static func normalizeBaseURL(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.isEmpty {
            trimmed = defaultBaseURL
        }
        if (trimmed.hasPrefix("https://chatgpt.com") || trimmed.hasPrefix("https://chat.openai.com")),
           !trimmed.contains("/backend-api") {
            trimmed += "/backend-api"
        }
        return trimmed
    }

    private static func parseChatGPTBaseURL(from contents: String) -> String? {
        for line in contents.split(whereSeparator: \.isNewline) {
            let rawLine = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url" else {
                continue
            }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            } else if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func defaultDataLoader(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexOAuthFetchError.invalidResponse
        }
        return (data, httpResponse)
    }
}

enum TextParsing {
    static func stripANSICodes(_ text: String) -> String {
        let pattern = #"\u001B\[[0-?]*[ -/]*[@-~]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    static func firstNumber(pattern: String, text: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return parseNumber(String(text[valueRange]))
    }

    static func firstInt(pattern: String, text: String) -> Int? {
        firstNumber(pattern: pattern, text: text).map(Int.init)
    }

    static func firstLine(matching pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let valueRange = Range(match.range(at: 0), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    static func percentLeft(fromLine line: String) -> Int? {
        firstInt(pattern: #"([0-9]{1,3})%\s+left"#, text: line)
    }

    static func resetString(fromLine line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"resets?\s+(.+)"#, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseNumber(_ raw: String) -> Double? {
        var normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.replacingOccurrences(of: "\u{00A0}", with: "")
        normalized = normalized.replacingOccurrences(of: "\u{202F}", with: "")
        normalized = normalized.replacingOccurrences(of: " ", with: "")

        let hasComma = normalized.contains(",")
        let hasDot = normalized.contains(".")
        if hasComma, hasDot {
            if let lastComma = normalized.lastIndex(of: ","), let lastDot = normalized.lastIndex(of: ".") {
                if lastComma > lastDot {
                    normalized = normalized.replacingOccurrences(of: ".", with: "")
                    normalized = normalized.replacingOccurrences(of: ",", with: ".")
                } else {
                    normalized = normalized.replacingOccurrences(of: ",", with: "")
                }
            }
        } else if hasComma {
            if normalized.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil {
                normalized = normalized.replacingOccurrences(of: ",", with: "")
            } else {
                normalized = normalized.replacingOccurrences(of: ",", with: ".")
            }
        } else if hasDot,
                  normalized.range(of: #"^\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
            normalized = normalized.replacingOccurrences(of: ".", with: "")
        }

        return Double(normalized)
    }
}

private struct CodexCLIAccountResponse: Decodable {
    let account: CodexCLIAccountDetails?
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum CodexCLIAccountDetails: Decodable {
    case apiKey
    case chatgpt(email: String, planType: String, workspaceName: String?)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        let type = try container.decode(String.self, forKey: DynamicCodingKey("type"))
        switch type.lowercased() {
        case "apikey":
            self = .apiKey
        case "chatgpt":
            self = .chatgpt(
                email: try container.decodeIfPresent(String.self, forKey: DynamicCodingKey("email")) ?? "",
                planType: try container.decodeFirstString(forKeys: ["planType", "plan_type"]) ?? "",
                workspaceName: try container.decodeFirstString(
                    forKeys: [
                        "workspaceName",
                        "workspace_name",
                        "organizationName",
                        "organization_name",
                        "teamName",
                        "team_name",
                        "name",
                    ]
                )
            )
        default:
            self = .apiKey
        }
    }
}

private extension KeyedDecodingContainer where K == DynamicCodingKey {
    func decodeFirstString(forKeys keys: [String]) throws -> String? {
        for key in keys {
            if let value = try decodeIfPresent(String.self, forKey: DynamicCodingKey(key))?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private struct CodexCLIRateLimitsResponse: Decodable {
    let rateLimits: CodexCLIRateLimitSnapshot
}

private struct CodexCLIRateLimitSnapshot: Decodable {
    let primary: CodexCLIRateLimitWindow?
    let secondary: CodexCLIRateLimitWindow?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType
        case plan_type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        primary = try container.decodeIfPresent(CodexCLIRateLimitWindow.self, forKey: .primary)
        secondary = try container.decodeIfPresent(CodexCLIRateLimitWindow.self, forKey: .secondary)
        planType = try container.decodeIfPresent(String.self, forKey: .planType)
            ?? container.decodeIfPresent(String.self, forKey: .plan_type)
    }
}

private struct CodexCLIRateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Int?
}

private enum CodexRPCWireError: LocalizedError {
    case startFailed(String)
    case requestFailed(String)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case let .startFailed(message):
            return "Codex CLI app-server failed to start: \(message)"
        case let .requestFailed(message):
            return "Codex CLI app-server request failed: \(message)"
        case let .malformed(message):
            return "Codex CLI app-server returned invalid data: \(message)"
        }
    }
}

private final class CodexRPCClient: @unchecked Sendable {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutLineStream: AsyncStream<Data>
    private let stdoutLineContinuation: AsyncStream<Data>.Continuation
    private var nextID = 1

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func appendAndDrainLines(_ data: Data) -> [Data] {
            lock.lock()
            defer { lock.unlock() }

            buffer.append(data)
            var drained: [Data] = []
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if !line.isEmpty {
                    drained.append(line)
                }
            }
            return drained
        }
    }

    init(codexBinary: String, environment: [String: String]) throws {
        var continuation: AsyncStream<Data>.Continuation!
        stdoutLineStream = AsyncStream<Data> { streamContinuation in
            continuation = streamContinuation
        }
        stdoutLineContinuation = continuation

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [codexBinary, "-s", "read-only", "-a", "untrusted", "app-server"]
        process.environment = environment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexRPCWireError.startFailed(error.localizedDescription)
        }

        let lineBuffer = LineBuffer()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [stdoutLineContinuation] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutLineContinuation.finish()
                return
            }

            for line in lineBuffer.appendAndDrainLines(data) {
                stdoutLineContinuation.yield(line)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }
    }

    func initialize(clientName: String, clientVersion: String) async throws {
        _ = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": clientName, "version": clientVersion]]
        )
        try sendNotification(method: "initialized")
    }

    func fetchAccount() async throws -> CodexCLIAccountResponse {
        try decodeResult(from: try await request(method: "account/read"))
    }

    func fetchRateLimits() async throws -> CodexCLIRateLimitsResponse {
        try decodeResult(from: try await request(method: "account/rateLimits/read"))
    }

    func shutdown() {
        if process.isRunning {
            process.terminate()
        }
    }

    private func request(method: String, params: [String: Any]? = nil) async throws -> [String: Any] {
        let requestID = nextID
        nextID += 1
        try sendRequest(id: requestID, method: method, params: params)

        while true {
            let message = try await readNextMessage()

            if message["id"] == nil {
                continue
            }

            guard jsonID(message["id"]) == requestID else {
                continue
            }

            if let error = message["error"] as? [String: Any],
               let messageText = error["message"] as? String {
                throw CodexRPCWireError.requestFailed(messageText)
            }

            return message
        }
    }

    private func sendNotification(method: String, params: [String: Any]? = nil) throws {
        try sendPayload(["method": method, "params": params ?? [:]])
    }

    private func sendRequest(id: Int, method: String, params: [String: Any]? = nil) throws {
        try sendPayload(["id": id, "method": method, "params": params ?? [:]])
    }

    private func sendPayload(_ payload: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func readNextMessage() async throws -> [String: Any] {
        for await line in stdoutLineStream {
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                return message
            }
        }
        throw CodexRPCWireError.malformed("codex app-server closed stdout")
    }

    private func decodeResult<T: Decodable>(from message: [String: Any]) throws -> T {
        guard let result = message["result"] else {
            throw CodexRPCWireError.malformed("missing result")
        }
        let data = try JSONSerialization.data(withJSONObject: result)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func jsonID(_ raw: Any?) -> Int? {
        switch raw {
        case let int as Int:
            return int
        case let number as NSNumber:
            return number.intValue
        default:
            return nil
        }
    }
}

enum CodexCLIRPCUsageFetcher {
    static func fetchUsage(
        codexBinary: String,
        environment: [String: String],
        now: Date = Date()
    ) async throws -> CodexLiveQuotaPayload {
        let rpc = try CodexRPCClient(codexBinary: codexBinary, environment: environment)
        defer { rpc.shutdown() }

        try await rpc.initialize(clientName: "codex-auth-rotator", clientVersion: "1.0")
        let limits = try await rpc.fetchRateLimits().rateLimits
        let account = try? await rpc.fetchAccount()

        let planTypeFromAccount = account?.account.flatMap { details -> String? in
            switch details {
            case let .chatgpt(_, planType, _):
                return planType.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            case .apiKey:
                return nil
            }
        }
        let planType = planTypeFromAccount ?? limits.planType?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let workspaceName = account?.account.flatMap { details -> String? in
            switch details {
            case let .chatgpt(_, _, workspaceName):
                return workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            case .apiKey:
                return nil
            }
        }

        let primary = limits.primary.map {
            RateLimitWindow(
                usedPercent: Int($0.usedPercent.rounded()),
                windowMinutes: $0.windowDurationMins,
                resetAfterSeconds: nil,
                resetAt: $0.resetsAt
            )
        }
        let secondary = limits.secondary.map {
            RateLimitWindow(
                usedPercent: Int($0.usedPercent.rounded()),
                windowMinutes: $0.windowDurationMins,
                resetAfterSeconds: nil,
                resetAt: $0.resetsAt
            )
        }

        let blocked = QuotaAvailabilityPolicy.blocks(usedPercent: primary?.usedPercent, windowMinutes: primary?.windowMinutes)
            || QuotaAvailabilityPolicy.blocks(usedPercent: secondary?.usedPercent, windowMinutes: secondary?.windowMinutes)
        let snapshot = QuotaSnapshot(
            event: CodexRateLimitEvent(
                type: "codex.rate_limits",
                planType: planType,
                rateLimits: RateLimitsPayload(
                    allowed: !blocked,
                    limitReached: blocked,
                    primary: primary,
                    secondary: secondary
                )
            ),
            capturedAt: now
        )

        return CodexLiveQuotaPayload(planType: planType, workspaceName: workspaceName, snapshot: snapshot)
    }
}

public struct CodexCLIStatusSnapshot: Hashable, Sendable {
    public let fiveHourPercentLeft: Int?
    public let weeklyPercentLeft: Int?
    public let fiveHourResetDescription: String?
    public let weeklyResetDescription: String?
    public let fiveHourResetsAt: Date?
    public let weeklyResetsAt: Date?
    public let rawText: String

    public init(
        fiveHourPercentLeft: Int?,
        weeklyPercentLeft: Int?,
        fiveHourResetDescription: String?,
        weeklyResetDescription: String?,
        fiveHourResetsAt: Date?,
        weeklyResetsAt: Date?,
        rawText: String
    ) {
        self.fiveHourPercentLeft = fiveHourPercentLeft
        self.weeklyPercentLeft = weeklyPercentLeft
        self.fiveHourResetDescription = fiveHourResetDescription
        self.weeklyResetDescription = weeklyResetDescription
        self.fiveHourResetsAt = fiveHourResetsAt
        self.weeklyResetsAt = weeklyResetsAt
        self.rawText = rawText
    }
}

public enum CodexCLIStatusProbeError: LocalizedError, Sendable {
    case timedOut
    case parseFailed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Codex /status probe timed out."
        case let .parseFailed(message):
            return "Codex /status output could not be parsed: \(message)"
        }
    }
}

public enum CodexCLIStatusProbe {
    public static func fetchUsage(
        codexBinary: String,
        environment: [String: String],
        now: Date = Date(),
        timeout: TimeInterval = 8
    ) throws -> CodexLiveQuotaPayload {
        let status = try parse(
            text: PTYCommandRunner.run(
                codexBinary: codexBinary,
                arguments: ["-s", "read-only", "-a", "untrusted"],
                send: "/status\n/quit\n",
                timeout: timeout,
                environment: environment
            ),
            now: now
        )

        let primary = status.fiveHourPercentLeft.map {
            RateLimitWindow(
                usedPercent: max(0, 100 - $0),
                windowMinutes: 300,
                resetAfterSeconds: nil,
                resetAt: status.fiveHourResetsAt.map { Int($0.timeIntervalSince1970) }
            )
        }
        let secondary = status.weeklyPercentLeft.map {
            RateLimitWindow(
                usedPercent: max(0, 100 - $0),
                windowMinutes: 10_080,
                resetAfterSeconds: nil,
                resetAt: status.weeklyResetsAt.map { Int($0.timeIntervalSince1970) }
            )
        }

        let blocked = QuotaAvailabilityPolicy.blocks(usedPercent: primary?.usedPercent, windowMinutes: primary?.windowMinutes)
            || QuotaAvailabilityPolicy.blocks(usedPercent: secondary?.usedPercent, windowMinutes: secondary?.windowMinutes)
        let snapshot = QuotaSnapshot(
            event: CodexRateLimitEvent(
                type: "codex.rate_limits",
                planType: nil,
                rateLimits: RateLimitsPayload(
                    allowed: !blocked,
                    limitReached: blocked,
                    primary: primary,
                    secondary: secondary
                )
            ),
            capturedAt: now
        )

        return CodexLiveQuotaPayload(planType: nil, workspaceName: nil, snapshot: snapshot)
    }

    public static func parse(text: String, now: Date = Date()) throws -> CodexCLIStatusSnapshot {
        let clean = TextParsing.stripANSICodes(text)
        guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CodexCLIStatusProbeError.timedOut
        }

        let fiveLine = TextParsing.firstLine(matching: #"5h limit[^\n]*"#, text: clean)
        let weeklyLine = TextParsing.firstLine(matching: #"Weekly limit[^\n]*"#, text: clean)
        let fivePercentLeft = fiveLine.flatMap(TextParsing.percentLeft(fromLine:))
        let weeklyPercentLeft = weeklyLine.flatMap(TextParsing.percentLeft(fromLine:))
        let fiveResetDescription = fiveLine.flatMap(TextParsing.resetString(fromLine:))
        let weeklyResetDescription = weeklyLine.flatMap(TextParsing.resetString(fromLine:))

        if fivePercentLeft == nil, weeklyPercentLeft == nil {
            throw CodexCLIStatusProbeError.parseFailed(String(clean.prefix(400)))
        }

        return CodexCLIStatusSnapshot(
            fiveHourPercentLeft: fivePercentLeft,
            weeklyPercentLeft: weeklyPercentLeft,
            fiveHourResetDescription: fiveResetDescription,
            weeklyResetDescription: weeklyResetDescription,
            fiveHourResetsAt: parseResetDate(from: fiveResetDescription, now: now),
            weeklyResetsAt: parseResetDate(from: weeklyResetDescription, now: now),
            rawText: clean
        )
    }

    private static func parseResetDate(from raw: String?, now: Date) -> Date? {
        guard var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.defaultDate = now

        if let match = text.firstMatch(of: /^([0-9]{1,2}:[0-9]{2}) on ([0-9]{1,2} [A-Za-z]{3})$/) {
            formatter.dateFormat = "d MMM HH:mm"
            return formatter.date(from: "\(match.output.2) \(match.output.1)").flatMap {
                bumpYearIfNeeded($0, now: now, calendar: calendar)
            }
        }

        if let match = text.firstMatch(of: /^([0-9]{1,2}:[0-9]{2}) on ([A-Za-z]{3} [0-9]{1,2})$/) {
            formatter.dateFormat = "MMM d HH:mm"
            return formatter.date(from: "\(match.output.2) \(match.output.1)").flatMap {
                bumpYearIfNeeded($0, now: now, calendar: calendar)
            }
        }

        for format in ["HH:mm", "H:mm"] {
            formatter.dateFormat = format
            if let parsedTime = formatter.date(from: text) {
                let components = calendar.dateComponents([.hour, .minute], from: parsedTime)
                guard let anchored = calendar.date(
                    bySettingHour: components.hour ?? 0,
                    minute: components.minute ?? 0,
                    second: 0,
                    of: now
                ) else {
                    continue
                }

                if anchored >= now {
                    return anchored
                }
                return calendar.date(byAdding: .day, value: 1, to: anchored)
            }
        }

        return nil
    }

    private static func bumpYearIfNeeded(_ date: Date, now: Date, calendar: Calendar) -> Date? {
        if date >= now {
            return date
        }
        return calendar.date(byAdding: .year, value: 1, to: date)
    }
}

private enum PTYCommandRunner {
    static func run(
        codexBinary: String,
        arguments: [String],
        send: String,
        timeout: TimeInterval,
        environment: [String: String],
        rows: UInt16 = 60,
        cols: UInt16 = 200
    ) throws -> String {
        var masterFD: Int32 = -1
        var slaveFD: Int32 = -1
        var windowSize = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)

        guard openpty(&masterFD, &slaveFD, nil, nil, &windowSize) == 0 else {
            throw CodexCLIStatusProbeError.timedOut
        }

        defer {
            if masterFD >= 0 {
                close(masterFD)
            }
            if slaveFD >= 0 {
                close(slaveFD)
            }
        }

        let currentFlags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, currentFlags | O_NONBLOCK)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [codexBinary] + arguments
        process.environment = environment

        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        try process.run()
        slaveFD = -1

        let scriptData = Array(send.utf8)
        let deadline = Date().addingTimeInterval(timeout)
        let sendAfter = Date().addingTimeInterval(0.5)
        var sentInput = false
        var output = Data()

        while Date() < deadline {
            if !sentInput, Date() >= sendAfter {
                _ = scriptData.withUnsafeBytes { bytes in
                    write(masterFD, bytes.baseAddress, bytes.count)
                }
                sentInput = true
            }

            var chunk = [UInt8](repeating: 0, count: 4_096)
            let count = read(masterFD, &chunk, chunk.count)
            if count > 0 {
                output.append(chunk, count: count)
            } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                break
            }

            if !process.isRunning, count <= 0 {
                break
            }

            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }

        return String(decoding: output, as: UTF8.self)
    }
}
