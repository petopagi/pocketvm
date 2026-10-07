import Foundation
import Virtualization

struct Snapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    /// True when memory was saved too, so restoring resumes exactly where it was.
    var hasState: Bool
}

/// Snapshots are APFS clones of the machine's files: instant, and they only take
/// space as the machine changes afterwards.
extension Machine {
    private static let snapshotFiles = ["Disk.img", "NVRAM", "AuxiliaryStorage"]

    var snapshots: [Snapshot] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let folders = (try? FileManager.default.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil)) ?? []
        return folders
            .compactMap { try? decoder.decode(Snapshot.self, from: Data(contentsOf: $0.appending(path: "snapshot.json"))) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func snapshot(named key: String) -> Snapshot? {
        let all = snapshots
        return all.first { $0.id.uuidString.caseInsensitiveCompare(key) == .orderedSame }
            ?? all.last { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Takes a snapshot, briefly pausing a running machine to save its memory alongside the disk.
    @discardableResult
    func takeSnapshot(name: String) async throws -> Snapshot {
        guard config.installed, status != .preparing else { throw PocketError("“\(config.name)” is still being set up.") }
        var snapshot = Snapshot(name: name.isEmpty ? "Snapshot" : name, hasState: false)
        let folder = snapshotsDir.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        do {
            if let vm, status == .running || status == .paused {
                let wasRunning = vm.state == .running
                if wasRunning { try await vm.pause() }
                var failure: Error?
                do {
                    if (try? ConfigBuilder.make(for: self).validateSaveRestoreSupport()) != nil {
                        try await vm.saveMachineStateTo(url: folder.appending(path: "State.vzvmsave"))
                        snapshot.hasState = true
                    }
                    try cloneFiles(from: bundle, to: folder)
                } catch {
                    failure = error
                }
                if wasRunning { try? await vm.resume() }
                if let failure { throw failure }
            } else {
                try cloneFiles(from: bundle, to: folder)
                if status == .suspended, FileManager.default.fileExists(atPath: saveURL.path) {
                    try FileManager.default.copyItem(at: saveURL, to: folder.appending(path: "State.vzvmsave"))
                    snapshot.hasState = true
                }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(snapshot).write(to: folder.appending(path: "snapshot.json"))
            snapshotRevision += 1
            return snapshot
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Rolls the machine back. A running machine is turned off first.
    func restoreSnapshot(_ snapshot: Snapshot) async throws {
        let folder = snapshotsDir.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw PocketError("That snapshot is gone.") }
        if isActive { await forceStop() }
        try? FileManager.default.removeItem(at: saveURL)
        for file in Self.snapshotFiles where FileManager.default.fileExists(atPath: folder.appending(path: file).path) {
            try? FileManager.default.removeItem(at: bundle.appending(path: file))
            try FileManager.default.copyItem(at: folder.appending(path: file), to: bundle.appending(path: file))
        }
        let state = folder.appending(path: "State.vzvmsave")
        if FileManager.default.fileExists(atPath: state.path) {
            try FileManager.default.copyItem(at: state, to: saveURL)
            status = .suspended
        } else {
            status = .stopped
        }
        refreshDiskUsage()
    }

    func deleteSnapshot(_ snapshot: Snapshot) throws {
        try FileManager.default.removeItem(at: snapshotsDir.appending(path: snapshot.id.uuidString, directoryHint: .isDirectory))
        snapshotRevision += 1
    }

    private func cloneFiles(from source: URL, to destination: URL) throws {
        for file in Self.snapshotFiles where FileManager.default.fileExists(atPath: source.appending(path: file).path) {
            // copyItem clones on APFS.
            try FileManager.default.copyItem(at: source.appending(path: file), to: destination.appending(path: file))
        }
    }
}
