import Darwin
import Foundation

struct ParallelCodexSessionProcessInspector: Sendable {
    struct ProcessSnapshot: Hashable, Sendable {
        let processIdentifier: pid_t
        let parentProcessIdentifier: pid_t
        let command: String

        init(
            processIdentifier: pid_t,
            parentProcessIdentifier: pid_t,
            command: String
        ) {
            self.processIdentifier = processIdentifier
            self.parentProcessIdentifier = parentProcessIdentifier
            self.command = command
        }
    }

    private let snapshotProvider: @Sendable () -> [ProcessSnapshot]

    init(snapshotProvider: @escaping @Sendable () -> [ProcessSnapshot] = Self.currentProcessSnapshots) {
        self.snapshotProvider = snapshotProvider
    }

    func protectsParallelSession(rootProcessIdentifier: pid_t) -> Bool {
        Self.protectsParallelSession(
            rootProcessIdentifier: rootProcessIdentifier,
            snapshots: snapshotProvider()
        )
    }

    static func protectsParallelSession(
        rootProcessIdentifier: pid_t,
        snapshots: [ProcessSnapshot]
    ) -> Bool {
        let snapshotsByPID = Dictionary(uniqueKeysWithValues: snapshots.map {
            ($0.processIdentifier, $0)
        })
        let snapshotsByParentPID = Dictionary(grouping: snapshots, by: \.parentProcessIdentifier)

        var visitedProcessIdentifiers = Set<pid_t>()
        var pendingProcessIdentifiers = [rootProcessIdentifier]

        while let processIdentifier = pendingProcessIdentifiers.popLast() {
            guard visitedProcessIdentifiers.insert(processIdentifier).inserted else {
                continue
            }

            if let snapshot = snapshotsByPID[processIdentifier],
               commandBelongsToParallelSession(snapshot.command) {
                return true
            }

            let childProcessIdentifiers = snapshotsByParentPID[processIdentifier]?.map(\.processIdentifier) ?? []
            pendingProcessIdentifiers.append(contentsOf: childProcessIdentifiers)
        }

        return false
    }

    static func snapshots(fromPSOutput output: String) -> [ProcessSnapshot] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> ProcessSnapshot? in
                let fields = line.split(
                    maxSplits: 2,
                    omittingEmptySubsequences: true,
                    whereSeparator: \.isWhitespace
                )
                guard fields.count == 3,
                      let processIdentifier = Int32(fields[0]),
                      let parentProcessIdentifier = Int32(fields[1])
                else {
                    return nil
                }

                return ProcessSnapshot(
                    processIdentifier: processIdentifier,
                    parentProcessIdentifier: parentProcessIdentifier,
                    command: String(fields[2])
                )
            }
    }

    private static func currentProcessSnapshots() -> [ProcessSnapshot] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]

        let standardOutput = Pipe()
        process.standardOutput = standardOutput
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return []
        }

        let outputData = standardOutput.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: outputData, encoding: .utf8)
        else {
            return []
        }

        return snapshots(fromPSOutput: output)
    }

    private static func commandBelongsToParallelSession(_ command: String) -> Bool {
        command.contains("CodexAuthRotator/CodexDesktopProfiles")
            || command.contains("CodexAuthRotator.DesktopSession.")
            || command.contains("CODEX_ELECTRON_USER_DATA_PATH=")
    }
}
