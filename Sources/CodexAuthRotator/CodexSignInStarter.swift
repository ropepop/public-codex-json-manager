import AppKit
import CodexAuthRotatorCore
import Foundation

typealias CodexSignInStatusUpdateHandler = @Sendable (String) async -> Void

struct CodexSignInStartRequest: Sendable {
    let configURL: URL
    let codexBinary: String
    let environment: [String: String]
    let statusUpdate: CodexSignInStatusUpdateHandler

    init(
        configURL: URL,
        codexBinary: String,
        environment: [String: String],
        statusUpdate: @escaping CodexSignInStatusUpdateHandler = { _ in }
    ) {
        self.configURL = configURL
        self.codexBinary = codexBinary
        self.environment = environment
        self.statusUpdate = statusUpdate
    }
}

struct CodexSignInResult: Sendable {
    let authData: Data
}

enum CodexSignInProcessTerminationReason: Sendable {
    case exit
    case signal
}

struct CodexSignInProcessInvocation: Sendable {
    let codexBinary: String
    let arguments: [String]
    let environment: [String: String]
    let temporaryRootURL: URL
    let homeDirectoryURL: URL
    let workingDirectoryURL: URL
    let authFileURL: URL
    let statusUpdate: CodexSignInStatusUpdateHandler
}

struct CodexSignInProcessResult: Sendable {
    let status: Int32
    let reason: CodexSignInProcessTerminationReason
    let output: String

    var succeeded: Bool {
        reason == .exit && status == 0
    }

    var failureDescription: String {
        let base = switch reason {
        case .exit:
            "exit \(status)"
        case .signal:
            "signal \(status)"
        }
        let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOutput.isEmpty else {
            return base
        }
        return "\(base): \(trimmedOutput)"
    }
}

protocol CodexSignInStarter: Sendable {
    func startSignIn(using request: CodexSignInStartRequest) async throws -> CodexSignInResult
}

enum CodexSignInStarterError: LocalizedError, Sendable {
    case terminalLaunchFailed
    case privateSafariLaunchFailed(String)
    case processStartFailed(String)
    case interrupted
    case timedOut
    case processFailed(status: String)
    case missingAuthFile
    case unusableAuthFile

    var errorDescription: String? {
        switch self {
        case .terminalLaunchFailed:
            return "Couldn't open a Terminal window for Codex sign-in."
        case let .privateSafariLaunchFailed(message):
            let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedMessage.isEmpty else {
                return "Couldn't open a private Safari window for Codex sign-in."
            }
            return "Couldn't open a private Safari window for Codex sign-in: \(trimmedMessage)"
        case let .processStartFailed(message):
            return "Couldn't start Codex sign-in: \(message)"
        case .interrupted:
            return "Codex sign-in was interrupted before it finished."
        case .timedOut:
            return "Timed out waiting for Codex sign-in to finish."
        case let .processFailed(status):
            return "Codex sign-in did not finish successfully. Exit status: \(status)."
        case .missingAuthFile:
            return "Codex sign-in finished, but no new auth file was created."
        case .unusableAuthFile:
            return "Codex sign-in finished, but the new auth file did not contain a usable account."
        }
    }
}

struct BrowserCodexSignInStarter: CodexSignInStarter {
    typealias Runner = @Sendable (CodexSignInProcessInvocation) async throws -> CodexSignInProcessResult
    typealias PrivateSafariOpener = @Sendable (URL) async throws -> Void

    private final class ProcessHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func set(_ process: Process) {
            lock.lock()
            self.process = process
            lock.unlock()
        }

        func terminate() {
            lock.lock()
            let process = self.process
            lock.unlock()

            guard let process, process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private final class AppServerOutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var output = ""
        private var stdoutBuffer = ""
        private var privateSafariTask: Task<Void, Never>?
        private var privateSafariError: Error?
        private var loginCompleted = false
        private var loginError: Error?

        func appendStdout(
            _ data: Data,
            statusUpdate: @escaping CodexSignInStatusUpdateHandler,
            privateSafariOpener: @escaping PrivateSafariOpener
        ) {
            appendOutput(data)

            guard !data.isEmpty else {
                return
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            guard !text.isEmpty else {
                return
            }

            lock.lock()
            stdoutBuffer += text
            let lines = completeStdoutLines()
            lock.unlock()

            for line in lines {
                parseStdoutLine(
                    line,
                    statusUpdate: statusUpdate,
                    privateSafariOpener: privateSafariOpener
                )
            }
        }

        func appendStderr(_ data: Data) {
            appendOutput(data)
        }

        private func appendOutput(_ data: Data) {
            guard !data.isEmpty else {
                return
            }

            let text = String(data: data, encoding: .utf8) ?? ""
            guard !text.isEmpty else {
                return
            }

            lock.lock()
            output += text
            lock.unlock()
        }

        private func completeStdoutLines() -> [String] {
            var lines: [String] = []
            while let newlineIndex = stdoutBuffer.firstIndex(of: "\n") {
                let line = String(stdoutBuffer[..<newlineIndex])
                stdoutBuffer.removeSubrange(...newlineIndex)
                lines.append(line)
            }
            return lines
        }

        private func parseStdoutLine(
            _ line: String,
            statusUpdate: @escaping CodexSignInStatusUpdateHandler,
            privateSafariOpener: @escaping PrivateSafariOpener
        ) {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }

            if isLoginStartResponse(json) {
                if let error = json["error"] as? [String: Any] {
                    recordLoginError(Self.error(from: error))
                    return
                }

                guard let result = json["result"] as? [String: Any],
                      let type = result["type"] as? String,
                      type == "chatgpt",
                      let rawURL = result["authUrl"] as? String,
                      let url = URL(string: rawURL) else {
                    recordLoginError(CodexSignInStarterError.processFailed(status: "unexpected login response"))
                    return
                }

                startPrivateSafariIfNeeded(
                    url: url,
                    statusUpdate: statusUpdate,
                    privateSafariOpener: privateSafariOpener
                )
                return
            }

            guard json["method"] as? String == "account/login/completed",
                  let params = json["params"] as? [String: Any] else {
                return
            }

            if params["success"] as? Bool == true {
                lock.lock()
                loginCompleted = true
                lock.unlock()
            } else {
                let message = params["error"] as? String ?? "Login was not completed."
                recordLoginError(CodexSignInStarterError.processFailed(status: message))
            }
        }

        private func startPrivateSafariIfNeeded(
            url: URL,
            statusUpdate: @escaping CodexSignInStatusUpdateHandler,
            privateSafariOpener: @escaping PrivateSafariOpener
        ) {
            lock.lock()
            let shouldStart = privateSafariTask == nil
            if shouldStart {
                privateSafariTask = Task {
                    await statusUpdate("Complete sign-in in Safari Private Browsing.")
                    do {
                        try await privateSafariOpener(url)
                    } catch {
                        self.recordPrivateSafariError(error)
                    }
                }
            }
            lock.unlock()
        }

        func collectedOutput() -> String {
            lock.lock()
            defer { lock.unlock() }
            return output
        }

        func loginCompletionError() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return loginError
        }

        func hasCompletedLogin() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return loginCompleted
        }

        func privateSafariFailure() -> Error? {
            lock.lock()
            defer { lock.unlock() }
            return privateSafariError
        }

        func waitForPrivateSafariOpen() async throws {
            await currentPrivateSafariTask()?.value

            if let error = privateSafariFailure() {
                throw error
            }
        }

        private func currentPrivateSafariTask() -> Task<Void, Never>? {
            lock.lock()
            defer { lock.unlock() }
            return privateSafariTask
        }

        private func recordPrivateSafariError(_ error: Error) {
            lock.lock()
            privateSafariError = error
            lock.unlock()
        }

        private func recordLoginError(_ error: Error) {
            lock.lock()
            loginError = error
            lock.unlock()
        }

        private func isLoginStartResponse(_ json: [String: Any]) -> Bool {
            switch json["id"] {
            case let value as Int:
                return value == Self.loginStartRequestID
            case let value as Double:
                return value == Double(Self.loginStartRequestID)
            case let value as String:
                return value == String(Self.loginStartRequestID)
            default:
                return false
            }
        }

        private static func error(from json: [String: Any]) -> Error {
            if let message = json["message"] as? String {
                return CodexSignInStarterError.processFailed(status: message)
            }
            return CodexSignInStarterError.processFailed(status: "unknown app-server login error")
        }

        private static let loginStartRequestID = 2
    }

    private static let defaultFallbackCodexBinaryPaths = [
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/Codex Beta.app/Contents/Resources/codex",
    ]

    let timeout: TimeInterval
    let fallbackCodexBinaryPaths: [String]
    let privateSafariOpener: PrivateSafariOpener
    let runner: Runner

    init(
        timeout: TimeInterval = 20 * 60,
        fallbackCodexBinaryPaths: [String] = defaultFallbackCodexBinaryPaths,
        privateSafariOpener: PrivateSafariOpener? = nil,
        runner: Runner? = nil
    ) {
        let resolvedTimeout = max(1, timeout)
        let resolvedPrivateSafariOpener = privateSafariOpener ?? Self.openInPrivateSafari
        self.timeout = resolvedTimeout
        self.fallbackCodexBinaryPaths = fallbackCodexBinaryPaths
        self.privateSafariOpener = resolvedPrivateSafariOpener
        self.runner = runner ?? { invocation in
            try await Self.runProcess(
                invocation: invocation,
                timeout: resolvedTimeout,
                privateSafariOpener: resolvedPrivateSafariOpener
            )
        }
    }

    func startSignIn(using request: CodexSignInStartRequest) async throws -> CodexSignInResult {
        let fileManager = FileManager.default
        let temporaryRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexAuthRotator.SignIn.\(UUID().uuidString)", isDirectory: true)
        let homeDirectoryURL = temporaryRootURL
        let codexDirectoryURL = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        let authFileURL = codexDirectoryURL.appendingPathComponent("auth.json")
        let workDirectoryURL = temporaryRootURL.appendingPathComponent("workdir", isDirectory: true)
        let xdgConfigURL = temporaryRootURL.appendingPathComponent(".xdg-config", isDirectory: true)
        let xdgStateURL = temporaryRootURL.appendingPathComponent(".xdg-state", isDirectory: true)
        let xdgCacheURL = temporaryRootURL.appendingPathComponent(".xdg-cache", isDirectory: true)

        do {
            try fileManager.createDirectory(at: codexDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: xdgConfigURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: xdgStateURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: xdgCacheURL, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: request.configURL.path) {
                try Self.copyFile(
                    from: request.configURL,
                    to: codexDirectoryURL.appendingPathComponent("config.toml")
                )
            }

            let environment = sanitizedEnvironment(
                from: request.environment,
                homeDirectoryURL: homeDirectoryURL,
                xdgConfigURL: xdgConfigURL,
                xdgStateURL: xdgStateURL,
                xdgCacheURL: xdgCacheURL
            )
            let invocation = CodexSignInProcessInvocation(
                codexBinary: Self.resolvedCodexBinary(
                    request.codexBinary,
                    environment: environment,
                    fallbackCodexBinaryPaths: fallbackCodexBinaryPaths
                ),
                arguments: ["app-server", "--listen", "stdio://"],
                environment: environment,
                temporaryRootURL: temporaryRootURL,
                homeDirectoryURL: homeDirectoryURL,
                workingDirectoryURL: workDirectoryURL,
                authFileURL: authFileURL,
                statusUpdate: request.statusUpdate
            )
            let processResult = try await runner(invocation)
            guard processResult.succeeded else {
                if processResult.reason == .signal {
                    throw CodexSignInStarterError.interrupted
                }
                throw CodexSignInStarterError.processFailed(status: processResult.failureDescription)
            }

            let authData = try Self.readUsableAuthData(from: authFileURL)
            try? fileManager.removeItem(at: temporaryRootURL)
            return CodexSignInResult(authData: authData)
        } catch {
            try? fileManager.removeItem(at: temporaryRootURL)
            throw error
        }
    }

    private static func runProcess(
        invocation: CodexSignInProcessInvocation,
        timeout: TimeInterval,
        privateSafariOpener: @escaping PrivateSafariOpener
    ) async throws -> CodexSignInProcessResult {
        let processHandle = ProcessHandle()
        let outputCollector = AppServerOutputCollector()

        return try await withTaskCancellationHandler(operation: {
            let process = Process()
            let inputPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            processHandle.set(process)

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [invocation.codexBinary] + invocation.arguments
            process.environment = invocation.environment
            process.currentDirectoryURL = invocation.workingDirectoryURL
            process.standardInput = inputPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                outputCollector.appendStdout(
                    fileHandle.availableData,
                    statusUpdate: invocation.statusUpdate,
                    privateSafariOpener: privateSafariOpener
                )
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
                outputCollector.appendStderr(fileHandle.availableData)
            }

            do {
                try process.run()
                try sendAppServerRequest(
                    [
                        "method": "initialize",
                        "id": 1,
                        "params": [
                            "clientInfo": [
                                "name": "CodexAuthRotator",
                                "title": "Codex Auth Rotator",
                                "version": "0",
                            ],
                            "capabilities": [
                                "experimentalApi": true,
                            ],
                        ],
                    ],
                    to: inputPipe
                )
                try sendAppServerRequest(
                    [
                        "method": "initialized",
                    ],
                    to: inputPipe
                )
                try sendAppServerRequest(
                    [
                        "method": "account/login/start",
                        "id": 2,
                        "params": [
                            "type": "chatgpt",
                            "codexStreamlinedLogin": false,
                        ],
                    ],
                    to: inputPipe
                )
            } catch {
                throw CodexSignInStarterError.processStartFailed(error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                if let privateSafariFailure = outputCollector.privateSafariFailure() {
                    processHandle.terminate()
                    process.waitUntilExit()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    throw privateSafariFailure
                }
                if let loginCompletionError = outputCollector.loginCompletionError() {
                    processHandle.terminate()
                    process.waitUntilExit()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    throw loginCompletionError
                }
                if outputCollector.hasCompletedLogin() || Self.authFileContainsUsableAuth(authFileURL: invocation.authFileURL) {
                    processHandle.terminate()
                    process.waitUntilExit()
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    try await outputCollector.waitForPrivateSafariOpen()
                    return CodexSignInProcessResult(
                        status: 0,
                        reason: .exit,
                        output: outputCollector.collectedOutput()
                    )
                }

                do {
                    try await Task.sleep(for: .milliseconds(100))
                } catch {
                    processHandle.terminate()
                    throw CodexSignInStarterError.interrupted
                }
            }

            if process.isRunning {
                process.terminate()
                usleep(200_000)
                if process.isRunning {
                    process.interrupt()
                }
                throw CodexSignInStarterError.timedOut
            }

            process.waitUntilExit()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            outputCollector.appendStdout(
                stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
                statusUpdate: invocation.statusUpdate,
                privateSafariOpener: privateSafariOpener
            )
            outputCollector.appendStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            try await outputCollector.waitForPrivateSafariOpen()

            return CodexSignInProcessResult(
                status: process.terminationStatus,
                reason: process.terminationReason == .exit ? .exit : .signal,
                output: outputCollector.collectedOutput()
            )
        }, onCancel: {
            processHandle.terminate()
        })
    }

    private static func sendAppServerRequest(_ object: [String: Any], to inputPipe: Pipe) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        inputPipe.fileHandleForWriting.write(data)
        inputPipe.fileHandleForWriting.write(Data("\n".utf8))
    }

    static func privateSafariAppleScript() -> String {
        """
        on run argv
          set targetURL to item 1 of argv

          tell application "Safari"
            launch
            activate
          end tell

          tell application "System Events"
            repeat until exists process "Safari"
              delay 0.05
            end repeat
            keystroke "n" using {shift down, command down}
          end tell

          delay 0.2

          tell application "Safari"
            set URL of front document to targetURL
          end tell
        end run
        """
    }

    private static func openInPrivateSafari(_ url: URL) async throws {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", privateSafariAppleScript(), url.absoluteString]
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw CodexSignInStarterError.privateSafariLaunchFailed(error.localizedDescription)
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let error = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            let message = [output, error]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw CodexSignInStarterError.privateSafariLaunchFailed(message)
        }
    }

    private func sanitizedEnvironment(
        from environment: [String: String],
        homeDirectoryURL: URL,
        xdgConfigURL: URL,
        xdgStateURL: URL,
        xdgCacheURL: URL
    ) -> [String: String] {
        let allowedKeys = Set([
            "PATH",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "ALL_PROXY",
            "NO_PROXY",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "TERM",
        ])
        var sanitized = environment.reduce(into: [String: String]()) { result, pair in
            guard allowedKeys.contains(pair.key),
                  Self.isShellEnvironmentKey(pair.key),
                  !pair.key.hasPrefix("CODEX_"),
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

    private static func resolvedCodexBinary(
        _ codexBinary: String,
        environment: [String: String],
        fallbackCodexBinaryPaths: [String]
    ) -> String {
        let trimmedBinary = codexBinary.trimmingCharacters(in: .whitespacesAndNewlines)
        let binary = trimmedBinary.isEmpty ? "codex" : trimmedBinary
        guard !binary.contains("/") else {
            return binary
        }

        let fileManager = FileManager.default
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent(binary)
                .path
            if fileManager.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        for candidate in fallbackCodexBinaryPaths where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }

        return binary
    }

    private static func readUsableAuthData(from authFileURL: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw CodexSignInStarterError.missingAuthFile
        }

        let data = try Data(contentsOf: authFileURL)
        let payload = try JSONDecoder().decode(StoredAuthPayload.self, from: data)
        guard payload.resolvedIdentity() != nil else {
            throw CodexSignInStarterError.unusableAuthFile
        }
        return data
    }

    private static func authFileContainsUsableAuth(authFileURL: URL) -> Bool {
        (try? readUsableAuthData(from: authFileURL)) != nil
    }

    private static func copyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destinationURL, options: .atomic)
    }

    private static func isShellEnvironmentKey(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first) else {
            return false
        }

        return value.unicodeScalars.allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }
}

struct TerminalCodexSignInStarter: CodexSignInStarter {
    private static let defaultFallbackCodexBinaryPaths = [
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/Codex Beta.app/Contents/Resources/codex",
    ]

    let timeout: TimeInterval
    let pollInterval: Duration

    init(
        timeout: TimeInterval = 20 * 60,
        pollInterval: Duration = .seconds(1)
    ) {
        self.timeout = max(1, timeout)
        self.pollInterval = pollInterval
    }

    func startSignIn(using request: CodexSignInStartRequest) async throws -> CodexSignInResult {
        let fileManager = FileManager.default
        let temporaryRootURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexAuthRotator.SignIn.\(UUID().uuidString)", isDirectory: true)
        let homeDirectoryURL = temporaryRootURL
        let codexDirectoryURL = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        let authFileURL = codexDirectoryURL.appendingPathComponent("auth.json")
        let workDirectoryURL = temporaryRootURL.appendingPathComponent("workdir", isDirectory: true)
        let xdgConfigURL = temporaryRootURL.appendingPathComponent(".xdg-config", isDirectory: true)
        let xdgStateURL = temporaryRootURL.appendingPathComponent(".xdg-state", isDirectory: true)
        let xdgCacheURL = temporaryRootURL.appendingPathComponent(".xdg-cache", isDirectory: true)
        let doneURL = temporaryRootURL.appendingPathComponent("login.done")
        let failedURL = temporaryRootURL.appendingPathComponent("login.failed")
        let scriptURL = temporaryRootURL.appendingPathComponent("codex-sign-in.command")

        do {
            try fileManager.createDirectory(at: codexDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: xdgConfigURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: xdgStateURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: xdgCacheURL, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: request.configURL.path) {
                try Self.copyFile(
                    from: request.configURL,
                    to: codexDirectoryURL.appendingPathComponent("config.toml")
                )
            }

            let environment = sanitizedEnvironment(
                from: request.environment,
                homeDirectoryURL: homeDirectoryURL,
                xdgConfigURL: xdgConfigURL,
                xdgStateURL: xdgStateURL,
                xdgCacheURL: xdgCacheURL
            )
            let script = Self.script(
                codexBinary: request.codexBinary,
                environment: environment,
                workDirectoryURL: workDirectoryURL,
                authFileURL: authFileURL,
                doneURL: doneURL,
                failedURL: failedURL
            )
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

            let opened = await MainActor.run {
                NSWorkspace.shared.open(scriptURL)
            }
            guard opened else {
                throw CodexSignInStarterError.terminalLaunchFailed
            }

            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if fileManager.fileExists(atPath: doneURL.path) {
                    let authData = try Self.readUsableAuthData(from: authFileURL)
                    try? fileManager.removeItem(at: temporaryRootURL)
                    return CodexSignInResult(authData: authData)
                }

                if fileManager.fileExists(atPath: failedURL.path) {
                    let rawStatus = try? String(contentsOf: failedURL, encoding: .utf8)
                    let trimmedStatus = rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let status = if let trimmedStatus, !trimmedStatus.isEmpty {
                        trimmedStatus
                    } else {
                        "unknown"
                    }
                    try? fileManager.removeItem(at: temporaryRootURL)
                    throw CodexSignInStarterError.processFailed(status: status)
                }

                try await Task.sleep(for: pollInterval)
            }

            throw CodexSignInStarterError.timedOut
        } catch {
            if let signInError = error as? CodexSignInStarterError,
               case .timedOut = signInError {
                // Leave the temporary login home in place so a slow sign-in is not interrupted.
            } else {
                try? fileManager.removeItem(at: temporaryRootURL)
            }
            throw error
        }
    }

    static func script(
        codexBinary: String,
        environment: [String: String],
        workDirectoryURL: URL,
        authFileURL: URL,
        doneURL: URL,
        failedURL: URL,
        fallbackCodexBinaryPaths: [String] = defaultFallbackCodexBinaryPaths
    ) -> String {
        let exports = environment
            .sorted { $0.key < $1.key }
            .map { "export \($0.key)=\(shellSingleQuoted($0.value))" }
            .joined(separator: "\n")
        let fallbackResolutionBlock = fallbackCodexBinaryPaths.isEmpty
            ? ""
            : """
              for candidate in \(fallbackCodexBinaryPaths.map(shellSingleQuoted).joined(separator: " ")); do
                if [ -x "$candidate" ]; then
                  codex_command="$candidate"
                  break
                fi
              done
              """

        return """
        #!/bin/zsh
        set -u

        \(exports)

        for name in ${(k)parameters}; do
          case "$name" in
            CODEX_*|OPENAI_*)
              unset "$name"
              ;;
          esac
        done

        rm -f \(shellSingleQuoted(doneURL.path)) \(shellSingleQuoted(failedURL.path))
        cd \(shellSingleQuoted(workDirectoryURL.path))

        echo "Starting isolated Codex sign-in."
        echo "Your active ~/.codex/auth.json and running Codex apps will not be changed."
        echo

        codex_command=\(shellSingleQuoted(codexBinary))
        if [[ "$codex_command" != */* ]]; then
          resolved_codex_command="$(command -v -- "$codex_command" 2>/dev/null || true)"
          if [ -n "$resolved_codex_command" ]; then
            codex_command="$resolved_codex_command"
          else
        \(fallbackResolutionBlock)
          fi
        fi

        "$codex_command" login --device-auth
        login_status=$?

        if [ "$login_status" -eq 0 ] && [ -s \(shellSingleQuoted(authFileURL.path)) ]; then
          touch \(shellSingleQuoted(doneURL.path))
          echo
          echo "Sign-in complete. This account is being added to Codex Auth Rotator."
        else
          echo "$login_status" > \(shellSingleQuoted(failedURL.path))
          echo
          echo "Sign-in did not complete."
        fi

        echo
        echo "Press Return to close this window."
        read -r _
        """
    }

    private func sanitizedEnvironment(
        from environment: [String: String],
        homeDirectoryURL: URL,
        xdgConfigURL: URL,
        xdgStateURL: URL,
        xdgCacheURL: URL
    ) -> [String: String] {
        let allowedKeys = Set([
            "PATH",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "ALL_PROXY",
            "NO_PROXY",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "TERM",
        ])
        var sanitized = environment.reduce(into: [String: String]()) { result, pair in
            guard allowedKeys.contains(pair.key),
                  Self.isShellEnvironmentKey(pair.key),
                  !pair.key.hasPrefix("CODEX_"),
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

    private static func readUsableAuthData(from authFileURL: URL) throws -> Data {
        guard FileManager.default.fileExists(atPath: authFileURL.path) else {
            throw CodexSignInStarterError.missingAuthFile
        }

        let data = try Data(contentsOf: authFileURL)
        let payload = try JSONDecoder().decode(StoredAuthPayload.self, from: data)
        guard payload.resolvedIdentity() != nil else {
            throw CodexSignInStarterError.unusableAuthFile
        }
        return data
    }

    private static func copyFile(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destinationURL, options: .atomic)
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func isShellEnvironmentKey(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              first == "_" || CharacterSet.letters.contains(first) else {
            return false
        }

        return value.unicodeScalars.allSatisfy {
            $0 == "_" || CharacterSet.alphanumerics.contains($0)
        }
    }
}
