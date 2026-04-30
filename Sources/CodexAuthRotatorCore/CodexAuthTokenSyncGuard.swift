import Foundation

public enum CodexAuthTokenSyncResult: Equatable, Sendable {
    case unchanged
    case written
    case rejectedDifferentAccount
    case rejectedStaleToken
    case rejectedUnusableAuth
}

public actor CodexAuthTokenSyncGuard {
    public static let defaultLimit = 200

    public let storageURL: URL
    public let limit: Int

    public init(storageURL: URL, limit: Int = defaultLimit) {
        self.storageURL = storageURL
        self.limit = max(1, limit)
    }

    public static func defaultStorageURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

        return baseURL
            .appendingPathComponent("CodexAuthRotator", isDirectory: true)
            .appendingPathComponent("retired-codex-tokens.json")
    }

    public func retiredTokens() throws -> [String] {
        try loadTokens()
    }

    public func retire(_ tokenValues: [String]) throws {
        let updated = Self.rollingTokenList(
            existing: try loadTokens(),
            adding: tokenValues,
            limit: limit
        )
        try saveTokens(updated)
    }

    public func syncUpdatedAuth(from updatedAuthURL: URL, backTo savedAuthURL: URL) throws -> CodexAuthTokenSyncResult {
        guard FileManager.default.fileExists(atPath: updatedAuthURL.path),
              let updatedData = try? Data(contentsOf: updatedAuthURL),
              !updatedData.isEmpty else {
            return .rejectedUnusableAuth
        }

        let savedData = try? Data(contentsOf: savedAuthURL)
        if savedData == updatedData {
            return .unchanged
        }

        let decoder = JSONDecoder()
        guard let updatedPayload = try? decoder.decode(StoredAuthPayload.self, from: updatedData),
              let updatedIdentity = updatedPayload.resolvedIdentity(),
              Self.payloadContainsUsableOAuthCredentials(updatedPayload) else {
            return .rejectedUnusableAuth
        }

        guard let savedData,
              let savedPayload = try? decoder.decode(StoredAuthPayload.self, from: savedData),
              let savedIdentity = savedPayload.resolvedIdentity(),
              AuthAccountMatcher.sameAccount(savedIdentity, as: updatedIdentity) else {
            return .rejectedDifferentAccount
        }

        let incomingTokenValues = Self.tokenValues(in: updatedPayload)
        let retiredTokenSet = Set(try loadTokens())
        guard incomingTokenValues.allSatisfy({ !retiredTokenSet.contains($0) }) else {
            return .rejectedStaleToken
        }

        let incomingTokenSet = Set(incomingTokenValues)
        let replacedTokenValues = Self.tokenValues(in: savedPayload)
            .filter { !incomingTokenSet.contains($0) }
        try retire(replacedTokenValues)
        try Self.copyData(updatedData, to: savedAuthURL)
        return .written
    }

    public static func tokenValues(in payload: StoredAuthPayload) -> [String] {
        [
            payload.tokens?.accessToken,
            payload.tokens?.refreshToken,
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
    }

    static func rollingTokenList(existing: [String], adding tokenValues: [String], limit: Int) -> [String] {
        let sanitizedNewValues = tokenValues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !sanitizedNewValues.isEmpty else {
            return Array(existing.suffix(max(1, limit)))
        }

        var result = existing.filter { existingValue in
            !sanitizedNewValues.contains(existingValue)
        }
        result.append(contentsOf: sanitizedNewValues)
        return Array(result.suffix(max(1, limit)))
    }

    private func loadTokens() throws -> [String] {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return []
        }

        let data = try Data(contentsOf: storageURL)
        let decoded = try JSONDecoder().decode([String].self, from: data)
        return decoded
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func saveTokens(_ tokenValues: [String]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(tokenValues)
        try data.write(to: storageURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    private static func payloadContainsUsableOAuthCredentials(_ payload: StoredAuthPayload) -> Bool {
        guard let accessToken = payload.tokens?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !accessToken.isEmpty,
              let refreshToken = payload.tokens?.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !refreshToken.isEmpty else {
            return false
        }

        return true
    }

    private static func copyData(_ data: Data, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(destinationURL.lastPathComponent).guarded-sync")
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        }
    }
}
