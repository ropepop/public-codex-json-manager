import AppKit
import CodexAuthRotatorCore
import Foundation

struct CodexDesktopSessionStartRequest: Sendable {
    let sourceCodexHomeURL: URL
    let savedAuthFileURL: URL
    let accountTrackingKey: String
    let environment: [String: String]
}

struct CodexDesktopSessionEvent: Sendable {
    enum Kind: Sendable {
        case started
        case ended
    }

    let sessionID: String
    let trackingKey: String
    let authFileURL: URL
    let processIdentifier: pid_t
    let kind: Kind
}

protocol CodexDesktopSessionStarter: Sendable {
    func startSession(
        using request: CodexDesktopSessionStartRequest,
        warningHandler: @escaping @Sendable (String) -> Void,
        eventHandler: @escaping @Sendable (CodexDesktopSessionEvent) -> Void
    ) async throws
}

extension CodexDesktopSessionStarter {
    func startSession(
        using request: CodexDesktopSessionStartRequest,
        warningHandler: @escaping @Sendable (String) -> Void
    ) async throws {
        try await startSession(using: request, warningHandler: warningHandler, eventHandler: { _ in })
    }
}

enum CodexDesktopSessionStarterError: LocalizedError, Sendable {
    case codexAppNotFound
    case cloneAppPreparationFailed(String)
    case appLaunchFailed(String)

    var errorDescription: String? {
        switch self {
        case .codexAppNotFound:
            return "Couldn't find the Codex desktop app."
        case let .cloneAppPreparationFailed(message):
            return "Couldn't prepare a separate Codex clone app: \(message)"
        case let .appLaunchFailed(message):
            return "Couldn't open Codex: \(message)"
        }
    }
}

struct SharedHistoryCodexDesktopSessionStarter: CodexDesktopSessionStarter {
    private final class RunningApplicationBox: @unchecked Sendable {
        let application: NSRunningApplication

        init(_ application: NSRunningApplication) {
            self.application = application
        }
    }

    private let clonePreparer: CodexHomeClonePreparer
    private let syncGuard: CodexAuthTokenSyncGuard
    private let cloneAppBundleBuilder: CodexDesktopCloneAppBundleBuilder
    private let temporaryRootBaseURL: URL
    private let electronProfileRootURL: URL
    private let pollInterval: Duration

    init(
        clonePreparer: CodexHomeClonePreparer = CodexHomeClonePreparer(),
        syncGuard: CodexAuthTokenSyncGuard = CodexAuthTokenSyncGuard(storageURL: CodexAuthTokenSyncGuard.defaultStorageURL()),
        cloneAppBundleBuilder: CodexDesktopCloneAppBundleBuilder = CodexDesktopCloneAppBundleBuilder(),
        temporaryRootBaseURL: URL = FileManager.default.temporaryDirectory,
        electronProfileRootURL: URL? = nil,
        pollInterval: Duration = .seconds(2)
    ) {
        self.clonePreparer = clonePreparer
        self.syncGuard = syncGuard
        self.cloneAppBundleBuilder = cloneAppBundleBuilder
        self.temporaryRootBaseURL = temporaryRootBaseURL
        self.electronProfileRootURL = electronProfileRootURL ?? Self.defaultElectronProfileRootURL()
        self.pollInterval = pollInterval
    }

    func startSession(
        using request: CodexDesktopSessionStartRequest,
        warningHandler: @escaping @Sendable (String) -> Void,
        eventHandler: @escaping @Sendable (CodexDesktopSessionEvent) -> Void
    ) async throws {
        let fileManager = FileManager.default
        let sessionID = UUID().uuidString
        let temporaryRootURL = temporaryRootBaseURL
            .appendingPathComponent("CodexAuthRotator.DesktopSession.\(sessionID)", isDirectory: true)
        let electronProfileURL = electronProfileRootURL
            .appendingPathComponent(Self.safePathComponent(for: request.accountTrackingKey), isDirectory: true)

        do {
            try fileManager.createDirectory(at: temporaryRootURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: electronProfileURL, withIntermediateDirectories: true)

            let clone = try clonePreparer.prepareClone(
                sourceCodexHomeURL: request.sourceCodexHomeURL,
                sourceAuthFileURL: request.savedAuthFileURL,
                temporaryRootURL: temporaryRootURL
            )
            guard let codexAppURL = Self.codexAppURL() else {
                throw CodexDesktopSessionStarterError.codexAppNotFound
            }
            let cloneAppURL: URL
            do {
                cloneAppURL = try cloneAppBundleBuilder.prepareCloneAppBundle(
                    sourceAppURL: codexAppURL,
                    temporaryRootURL: temporaryRootURL,
                    sessionID: sessionID,
                    accountTrackingKey: request.accountTrackingKey
                )
            } catch {
                throw CodexDesktopSessionStarterError.cloneAppPreparationFailed(error.localizedDescription)
            }
            let application = try await launchCodex(
                appURL: cloneAppURL,
                clone: clone,
                electronProfileURL: electronProfileURL,
                inheritedEnvironment: request.environment
            )

            let applicationBox = RunningApplicationBox(application)
            eventHandler(
                CodexDesktopSessionEvent(
                    sessionID: sessionID,
                    trackingKey: request.accountTrackingKey,
                    authFileURL: clone.authFileURL,
                    processIdentifier: application.processIdentifier,
                    kind: .started
                )
            )
            let syncGuard = self.syncGuard
            let clonePreparer = self.clonePreparer
            let sourceCodexHomeURL = request.sourceCodexHomeURL
            let savedAuthFileURL = request.savedAuthFileURL
            let pollInterval = self.pollInterval
            Task.detached(priority: .utility) {
                await Self.monitorSession(
                    applicationBox: applicationBox,
                    clone: clone,
                    sourceCodexHomeURL: sourceCodexHomeURL,
                    savedAuthFileURL: savedAuthFileURL,
                    accountTrackingKey: request.accountTrackingKey,
                    sessionID: sessionID,
                    clonePreparer: clonePreparer,
                    syncGuard: syncGuard,
                    pollInterval: pollInterval,
                    warningHandler: warningHandler,
                    eventHandler: eventHandler
                )
            }
        } catch {
            try? fileManager.removeItem(at: temporaryRootURL)
            throw error
        }
    }

    private func launchCodex(
        appURL: URL,
        clone: CodexHomeClone,
        electronProfileURL: URL,
        inheritedEnvironment: [String: String]
    ) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.createsNewApplicationInstance = true
        configuration.environment = Self.launchEnvironment(
            inheritedEnvironment,
            clone: clone,
            electronProfileURL: electronProfileURL
        )

        return try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                if let application {
                    continuation.resume(returning: application)
                } else if let error {
                    continuation.resume(throwing: CodexDesktopSessionStarterError.appLaunchFailed(error.localizedDescription))
                } else {
                    continuation.resume(throwing: CodexDesktopSessionStarterError.appLaunchFailed("Unknown launch failure."))
                }
            }
        }
    }

    private static func monitorSession(
        applicationBox: RunningApplicationBox,
        clone: CodexHomeClone,
        sourceCodexHomeURL: URL,
        savedAuthFileURL: URL,
        accountTrackingKey: String,
        sessionID: String,
        clonePreparer: CodexHomeClonePreparer,
        syncGuard: CodexAuthTokenSyncGuard,
        pollInterval: Duration,
        warningHandler: @escaping @Sendable (String) -> Void,
        eventHandler: @escaping @Sendable (CodexDesktopSessionEvent) -> Void
    ) async {
        var shouldKeepTemporaryRoot = false
        var lastObservedAuthModificationDate = Self.fileModificationDate(clone.authFileURL)
        defer {
            eventHandler(
                CodexDesktopSessionEvent(
                    sessionID: sessionID,
                    trackingKey: accountTrackingKey,
                    authFileURL: clone.authFileURL,
                    processIdentifier: applicationBox.application.processIdentifier,
                    kind: .ended
                )
            )
        }

        func syncAuth(reason: String) async {
            do {
                let result = try await syncGuard.syncUpdatedAuth(
                    from: clone.authFileURL,
                    backTo: savedAuthFileURL
                )
                switch result {
                case .unchanged, .written:
                    break
                case .rejectedDifferentAccount:
                    shouldKeepTemporaryRoot = true
                    warningHandler("Codex tried to save auth for a different account. The temporary session folder was kept.")
                case .rejectedStaleToken:
                    shouldKeepTemporaryRoot = true
                    warningHandler("Codex tried to save an older token. The saved account was left unchanged.")
                case .rejectedUnusableAuth:
                    shouldKeepTemporaryRoot = true
                    warningHandler("Codex wrote an auth file that could not be safely saved. The temporary session folder was kept.")
                }
            } catch {
                shouldKeepTemporaryRoot = true
                warningHandler("Codex auth changed, but it could not be saved: \(error.localizedDescription)")
            }
        }

        while !applicationBox.application.isTerminated {
            try? await Task.sleep(for: pollInterval)
            let currentModificationDate = Self.fileModificationDate(clone.authFileURL)
            if currentModificationDate != lastObservedAuthModificationDate {
                lastObservedAuthModificationDate = currentModificationDate
                await syncAuth(reason: "change")
            }
        }

        await syncAuth(reason: "exit")

        do {
            _ = try clonePreparer.mergeNewNonAuthItems(from: clone, into: sourceCodexHomeURL)
        } catch {
            shouldKeepTemporaryRoot = true
            warningHandler("Codex created new shared files, but they could not be merged safely: \(error.localizedDescription) The temporary session folder was kept.")
        }

        if !shouldKeepTemporaryRoot {
            try? FileManager.default.removeItem(at: clone.temporaryRootURL)
        }
    }

    private static func launchEnvironment(
        _ inheritedEnvironment: [String: String],
        clone: CodexHomeClone,
        electronProfileURL: URL
    ) -> [String: String] {
        var environment = inheritedEnvironment.reduce(into: [String: String]()) { result, pair in
            guard !pair.key.hasPrefix("CODEX_"),
                  !pair.key.hasPrefix("OPENAI_") else {
                return
            }
            result[pair.key] = pair.value
        }

        environment["CODEX_HOME"] = clone.codexHomeURL.path
        environment["HOME"] = clone.fallbackHomeURL.path
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = electronProfileURL.path
        environment["XDG_CONFIG_HOME"] = clone.temporaryRootURL.appendingPathComponent(".xdg-config", isDirectory: true).path
        environment["XDG_STATE_HOME"] = clone.temporaryRootURL.appendingPathComponent(".xdg-state", isDirectory: true).path
        environment["XDG_CACHE_HOME"] = clone.temporaryRootURL.appendingPathComponent(".xdg-cache", isDirectory: true).path
        return environment
    }

    private static func codexAppURL() -> URL? {
        let fileManager = FileManager.default
        for path in [
            "/Applications/Codex.app",
            "/Applications/Codex Beta.app",
        ] {
            if fileManager.fileExists(atPath: path) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }

        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            return appURL
        }

        return nil
    }

    private static func defaultElectronProfileRootURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return baseURL
            .appendingPathComponent("CodexAuthRotator", isDirectory: true)
            .appendingPathComponent("CodexDesktopProfiles", isDirectory: true)
    }

    private static func safePathComponent(for value: String) -> String {
        let sanitized = value.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" || character == "." {
                return character
            }
            return "_"
        }
        let prefix = String(sanitized).prefix(80)
        return "\(prefix)-\(fnv1aHex(value))"
    }

    private static func fnv1aHex(_ value: String) -> String {
        let basis: UInt64 = 1_469_598_103_934_665_603
        let prime: UInt64 = 1_099_511_628_211
        let hash = value.utf8.reduce(basis) { partial, byte in
            (partial ^ UInt64(byte)) &* prime
        }
        return String(hash, radix: 16)
    }

    private static func fileModificationDate(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }
}
