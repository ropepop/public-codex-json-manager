import Darwin
import Foundation

public struct CodexWindowStartRequest: Sendable {
    public let authFileURL: URL
    public let configURL: URL
    public let codexBinary: String
    public let environment: [String: String]

    public init(
        authFileURL: URL,
        configURL: URL,
        codexBinary: String,
        environment: [String: String]
    ) {
        self.authFileURL = authFileURL
        self.configURL = configURL
        self.codexBinary = codexBinary
        self.environment = environment
    }
}

public struct CodexWindowStartInvocation: Sendable {
    public let codexBinary: String
    public let arguments: [String]
    public let environment: [String: String]
    public let temporaryRootURL: URL
    public let homeDirectoryURL: URL
    public let workingDirectoryURL: URL

    public init(
        codexBinary: String,
        arguments: [String],
        environment: [String: String],
        temporaryRootURL: URL,
        homeDirectoryURL: URL,
        workingDirectoryURL: URL
    ) {
        self.codexBinary = codexBinary
        self.arguments = arguments
        self.environment = environment
        self.temporaryRootURL = temporaryRootURL
        self.homeDirectoryURL = homeDirectoryURL
        self.workingDirectoryURL = workingDirectoryURL
    }
}

public protocol CodexWindowStarter: Sendable {
    func startWindow(using request: CodexWindowStartRequest) async throws
}

public enum CodexWindowStarterError: LocalizedError, Sendable {
    case timedOut
    case processFailed(status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Timed out while asking Codex to start the 5-hour window."
        case let .processFailed(status, output):
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedOutput.isEmpty {
                return "Codex exited with status \(status) while starting the 5-hour window."
            }
            return "Codex exited with status \(status): \(trimmedOutput)"
        }
    }
}

public struct IsolatedCodexExecWindowStarter: CodexWindowStarter {
    public typealias Runner = @Sendable (CodexWindowStartInvocation) async throws -> Void

    public static let defaultModel = "gpt-5.4-mini"
    public static let defaultReasoningEffort = "none"
    public static let defaultModelCandidates = [
        defaultModel,
        "gpt-5-mini",
        "gpt-4.1-mini",
        "gpt-4o-mini",
    ]
    public static let defaultReasoningEffortCandidates = [
        defaultReasoningEffort,
        "minimal",
        "low",
    ]

    private let prompt: String
    private let timeout: TimeInterval
    private let modelCandidates: [String]
    private let reasoningEffortCandidates: [String]
    private let syncGuard: CodexAuthTokenSyncGuard
    private let runner: Runner

    public init(
        prompt: String = "Reply with OK only.",
        model: String = defaultModel,
        reasoningEffort: String = defaultReasoningEffort,
        timeout: TimeInterval = 60,
        syncGuard: CodexAuthTokenSyncGuard = CodexAuthTokenSyncGuard(storageURL: CodexAuthTokenSyncGuard.defaultStorageURL()),
        runner: Runner? = nil
    ) {
        let resolvedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedReasoningEffort = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTimeout = max(1, timeout)
        self.prompt = resolvedPrompt.isEmpty ? "Reply with OK only." : resolvedPrompt
        self.modelCandidates = Self.normalizedCandidates(
            [resolvedModel] + Self.defaultModelCandidates,
            fallback: Self.defaultModelCandidates
        )
        self.reasoningEffortCandidates = Self.normalizedCandidates(
            [resolvedReasoningEffort] + Self.defaultReasoningEffortCandidates,
            fallback: Self.defaultReasoningEffortCandidates
        )
        self.timeout = resolvedTimeout
        self.syncGuard = syncGuard
        self.runner = runner ?? { invocation in
            try await Self.runProcess(invocation: invocation, timeout: resolvedTimeout)
        }
    }

    public func startWindow(using request: CodexWindowStartRequest) async throws {
        let fileManager = FileManager.default
        let temporaryRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexAuthRotator.WindowStarter.\(UUID().uuidString)", isDirectory: true)
        let homeDirectoryURL = temporaryRootURL
        let codexDirectoryURL = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        let isolatedAuthURL = codexDirectoryURL.appendingPathComponent("auth.json")
        let workingDirectoryURL = temporaryRootURL.appendingPathComponent("workdir", isDirectory: true)
        let xdgConfigURL = temporaryRootURL.appendingPathComponent(".xdg-config", isDirectory: true)
        let xdgStateURL = temporaryRootURL.appendingPathComponent(".xdg-state", isDirectory: true)
        let xdgCacheURL = temporaryRootURL.appendingPathComponent(".xdg-cache", isDirectory: true)

        try fileManager.createDirectory(at: codexDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: xdgConfigURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: xdgStateURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: xdgCacheURL, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: temporaryRootURL)
        }

        try Self.copyFile(
            from: request.authFileURL,
            to: isolatedAuthURL
        )
        if fileManager.fileExists(atPath: request.configURL.path) {
            try Self.copyFile(
                from: request.configURL,
                to: codexDirectoryURL.appendingPathComponent("config.toml")
            )
        }

        let environment = Self.sanitizedEnvironment(
            from: request.environment,
            homeDirectoryURL: homeDirectoryURL,
            xdgConfigURL: xdgConfigURL,
            xdgStateURL: xdgStateURL,
            xdgCacheURL: xdgCacheURL
        )

        var lastSelectionError: CodexWindowStarterError?

        modelLoop: for model in modelCandidates {
            for reasoningEffort in reasoningEffortCandidates {
                let invocation = Self.makeInvocation(
                    codexBinary: request.codexBinary,
                    prompt: prompt,
                    model: model,
                    reasoningEffort: reasoningEffort,
                    environment: environment,
                    temporaryRootURL: temporaryRootURL,
                    homeDirectoryURL: homeDirectoryURL,
                    workingDirectoryURL: workingDirectoryURL
                )

                do {
                    try await runner(invocation)
                    _ = try? await syncGuard.syncUpdatedAuth(
                        from: isolatedAuthURL,
                        backTo: request.authFileURL
                    )
                    return
                } catch let error as CodexWindowStarterError {
                    if Self.isReasoningSelectionFailure(error) {
                        lastSelectionError = error
                        continue
                    }
                    if Self.isModelSelectionFailure(error) {
                        lastSelectionError = error
                        continue modelLoop
                    }
                    throw error
                }
            }
        }

        if let lastSelectionError {
            throw lastSelectionError
        }
    }

    private static func makeInvocation(
        codexBinary: String,
        prompt: String,
        model: String,
        reasoningEffort: String,
        environment: [String: String],
        temporaryRootURL: URL,
        homeDirectoryURL: URL,
        workingDirectoryURL: URL
    ) -> CodexWindowStartInvocation {
        CodexWindowStartInvocation(
            codexBinary: codexBinary,
            arguments: [
                "exec",
                "--ephemeral",
                "--skip-git-repo-check",
                "-m",
                model,
                "-c",
                "model_reasoning_effort=\"\(reasoningEffort)\"",
                "-s",
                "read-only",
                "-C",
                workingDirectoryURL.path,
                prompt,
            ],
            environment: environment,
            temporaryRootURL: temporaryRootURL,
            homeDirectoryURL: homeDirectoryURL,
            workingDirectoryURL: workingDirectoryURL
        )
    }

    private static func normalizedCandidates(_ candidates: [String], fallback: [String]) -> [String] {
        let trimmed = candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = trimmed.reduce(into: [String]()) { result, candidate in
            if !result.contains(candidate) {
                result.append(candidate)
            }
        }
        return unique.isEmpty ? fallback : unique
    }

    private static func isModelSelectionFailure(_ error: CodexWindowStarterError) -> Bool {
        guard case let .processFailed(_, output) = error else {
            return false
        }
        let lowercasedOutput = output.lowercased()
        guard lowercasedOutput.contains("model") else {
            return false
        }
        return selectionFailureMarkers.contains { lowercasedOutput.contains($0) }
    }

    private static func isReasoningSelectionFailure(_ error: CodexWindowStarterError) -> Bool {
        guard case let .processFailed(_, output) = error else {
            return false
        }
        let lowercasedOutput = output.lowercased()
        guard lowercasedOutput.contains("reasoning")
            || lowercasedOutput.contains("model_reasoning_effort") else {
            return false
        }
        return selectionFailureMarkers.contains { lowercasedOutput.contains($0) }
    }

    private static let selectionFailureMarkers = [
        "invalid",
        "unknown",
        "unsupported",
        "unrecognized",
        "unavailable",
        "not available",
        "not found",
        "no such",
        "does not exist",
        "expected one of",
    ]

    private static func sanitizedEnvironment(
        from environment: [String: String],
        homeDirectoryURL: URL,
        xdgConfigURL: URL,
        xdgStateURL: URL,
        xdgCacheURL: URL
    ) -> [String: String] {
        var sanitized = environment.reduce(into: [String: String]()) { result, pair in
            guard !pair.key.hasPrefix("CODEX_"),
                  !pair.key.hasPrefix("OPENAI_") else {
                return
            }
            result[pair.key] = pair.value
        }

        sanitized["HOME"] = homeDirectoryURL.path
        sanitized["XDG_CONFIG_HOME"] = xdgConfigURL.path
        sanitized["XDG_STATE_HOME"] = xdgStateURL.path
        sanitized["XDG_CACHE_HOME"] = xdgCacheURL.path
        return sanitized
    }

    private static func copyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destinationURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destinationURL.path)
    }

    private static func runProcess(
        invocation: CodexWindowStartInvocation,
        timeout: TimeInterval
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [invocation.codexBinary] + invocation.arguments
            process.environment = invocation.environment
            process.currentDirectoryURL = invocation.workingDirectoryURL
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            try process.run()

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                usleep(100_000)
            }

            if process.isRunning {
                process.terminate()
                usleep(200_000)
                if process.isRunning {
                    process.interrupt()
                }
                throw CodexWindowStarterError.timedOut
            }

            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                let stdout = String(
                    data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let combinedOutput = [stdout, stderr]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                throw CodexWindowStarterError.processFailed(
                    status: process.terminationStatus,
                    output: combinedOutput
                )
            }
        }.value
    }
}
