import AppKit
import CodexAuthRotatorCore
import Foundation

struct CodexSignInStartRequest: Sendable {
    let configURL: URL
    let codexBinary: String
    let environment: [String: String]
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

    private static let defaultFallbackCodexBinaryPaths = [
        "/Applications/Codex.app/Contents/Resources/codex",
        "/Applications/Codex Beta.app/Contents/Resources/codex",
    ]

    let timeout: TimeInterval
    let fallbackCodexBinaryPaths: [String]
    let runner: Runner

    init(
        timeout: TimeInterval = 20 * 60,
        fallbackCodexBinaryPaths: [String] = defaultFallbackCodexBinaryPaths,
        runner: Runner? = nil
    ) {
        let resolvedTimeout = max(1, timeout)
        self.timeout = resolvedTimeout
        self.fallbackCodexBinaryPaths = fallbackCodexBinaryPaths
        self.runner = runner ?? { invocation in
            try await Self.runProcess(invocation: invocation, timeout: resolvedTimeout)
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
                arguments: ["login"],
                environment: environment,
                temporaryRootURL: temporaryRootURL,
                homeDirectoryURL: homeDirectoryURL,
                workingDirectoryURL: workDirectoryURL,
                authFileURL: authFileURL
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
        timeout: TimeInterval
    ) async throws -> CodexSignInProcessResult {
        let processHandle = ProcessHandle()

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

            do {
                try process.run()
                try? inputPipe.fileHandleForWriting.close()
            } catch {
                throw CodexSignInStarterError.processStartFailed(error.localizedDescription)
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
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
            return CodexSignInProcessResult(
                status: process.terminationStatus,
                reason: process.terminationReason == .exit ? .exit : .signal,
                output: combinedOutput
            )
        }, onCancel: {
            processHandle.terminate()
        })
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
