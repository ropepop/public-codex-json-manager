import Foundation

public struct QuotaSnapshotStore: Sendable {
    private static let retentionInterval: TimeInterval = 7 * 24 * 60 * 60

    public let storageURL: URL

    public init(storageURL: URL = QuotaSnapshotStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    public func load(asOf now: Date = Date()) throws -> [String: QuotaSnapshot] {
        guard let snapshots = try loadRawIfPresent() else {
            return [:]
        }
        return Self.retainedSnapshots(snapshots, asOf: now)
    }

    public func save(_ snapshots: [String: QuotaSnapshot], asOf now: Date = Date()) throws {
        try persist(Self.retainedSnapshots(snapshots, asOf: now))
    }

    public func purgeExpiredSnapshots(asOf now: Date = Date()) throws {
        guard let snapshots = try loadRawIfPresent() else {
            return
        }

        let retained = Self.retainedSnapshots(snapshots, asOf: now)
        guard retained != snapshots else {
            return
        }

        try persist(retained)
    }

    public static func defaultStorageURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return applicationSupport
            .appendingPathComponent("CodexAuthRotator", isDirectory: true)
            .appendingPathComponent("quota-snapshots.json")
    }

    private func loadRawIfPresent() throws -> [String: QuotaSnapshot]? {
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: storageURL)
        guard !data.isEmpty else {
            return [:]
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([String: QuotaSnapshot].self, from: data)
    }

    private func persist(_ snapshots: [String: QuotaSnapshot]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshots)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func retainedSnapshots(
        _ snapshots: [String: QuotaSnapshot],
        asOf now: Date
    ) -> [String: QuotaSnapshot] {
        let cutoff = now.addingTimeInterval(-retentionInterval)
        return snapshots.reduce(into: [:]) { result, entry in
            guard entry.value.capturedAt >= cutoff else {
                return
            }
            result[entry.key] = entry.value
        }
    }
}
