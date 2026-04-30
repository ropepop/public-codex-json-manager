import Foundation

struct CodexDesktopCloneAppBundleBuilder: Sendable {
    func prepareCloneAppBundle(
        sourceAppURL: URL,
        temporaryRootURL: URL,
        sessionID _: String,
        accountTrackingKey _: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let sourceAppURL = sourceAppURL.standardizedFileURL
        guard fileManager.fileExists(atPath: sourceAppURL.path) else {
            throw CloneAppBundleBuilderError.missingSourceApp(sourceAppURL.path)
        }

        let cloneAppURL = temporaryRootURL.appendingPathComponent("Codex Clone.app", isDirectory: true)
        if fileManager.fileExists(atPath: cloneAppURL.path) {
            try fileManager.removeItem(at: cloneAppURL)
        }

        try Self.copyAppBundle(from: sourceAppURL, to: cloneAppURL)
        return cloneAppURL
    }

    private static func copyAppBundle(from sourceAppURL: URL, to cloneAppURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/cp")
        process.arguments = ["-cR", sourceAppURL.path, cloneAppURL.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            try FileManager.default.copyItem(at: sourceAppURL, to: cloneAppURL)
            return
        }

        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "cp exited with status \(process.terminationStatus)"
            try? FileManager.default.removeItem(at: cloneAppURL)
            do {
                try FileManager.default.copyItem(at: sourceAppURL, to: cloneAppURL)
            } catch {
                throw CloneAppBundleBuilderError.copyFailed("\(message). Fallback copy failed: \(error.localizedDescription)")
            }
        }

        guard FileManager.default.fileExists(atPath: cloneAppURL.path) else {
            throw CloneAppBundleBuilderError.copyFailed("The cloned app bundle was not created.")
        }
    }
}

private enum CloneAppBundleBuilderError: LocalizedError {
    case missingSourceApp(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingSourceApp(path):
            return "The Codex app was not found at \(path)."
        case let .copyFailed(message):
            return "The Codex clone app could not be copied: \(message)"
        }
    }
}
