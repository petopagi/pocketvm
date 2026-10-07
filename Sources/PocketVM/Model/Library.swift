import AppKit
import Observation
import Virtualization

enum SortOrder: String, CaseIterable, Identifiable {
    case created = "Date Added"
    case name = "Name"
    case lastUsed = "Last Used"
    case system = "System"

    var id: String { rawValue }
}

struct RestoreRequest: Identifiable {
    let id = UUID()
    let machine: Machine
    let snapshot: Snapshot
}

struct AlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor @Observable
final class Library {
    static let shared = Library()

    var machines: [Machine] = []
    var selection: UUID?
    var showingNewMachine = false
    var editing: Machine?
    var confirmingTrash: Machine?
    var confirmingRestore: RestoreRequest?
    /// Set when a machine finishes setup; the library view opens its window.
    var pendingOpen: UUID?
    var alert: AlertInfo?
    var showingAgents = false
    /// Captured from SwiftUI so non-view code (the MCP server) can open machine windows.
    @ObservationIgnored var openWindow: ((UUID) -> Void)?
    /// Opens (or brings forward) the main PocketVM window.
    @ObservationIgnored var openLibraryWindow: (() -> Void)?
    var sortOrder: SortOrder {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "sortOrder") }
    }

    let isDemo = CommandLine.arguments.contains("--demo")
    let root: URL
    var machinesDir: URL { root.appending(path: "Machines", directoryHint: .isDirectory) }
    var downloadsDir: URL { root.appending(path: "Downloads", directoryHint: .isDirectory) }

    private init() {
        root = URL.applicationSupportDirectory.appending(path: "PocketVM", directoryHint: .isDirectory)
        sortOrder = SortOrder(rawValue: UserDefaults.standard.string(forKey: "sortOrder") ?? "") ?? .created
        if isDemo {
            loadDemo()
        } else {
            try? FileManager.default.createDirectory(at: machinesDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            reload()
        }
    }

    var sorted: [Machine] {
        switch sortOrder {
        case .created: machines.sorted { $0.config.createdAt < $1.config.createdAt }
        case .name: machines.sorted { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
        case .lastUsed: machines.sorted { ($0.config.lastUsedAt ?? .distantPast) > ($1.config.lastUsedAt ?? .distantPast) }
        case .system: machines.sorted { ($0.config.os.rawValue, $0.config.name) < ($1.config.os.rawValue, $1.config.name) }
        }
    }

    func machine(_ id: UUID) -> Machine? { machines.first { $0.id == id } }

    /// Opens a machine's window; works even while the library window is closed.
    func open(_ id: UUID) {
        if let openWindow { openWindow(id) } else { pendingOpen = id }
    }

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let bundles = (try? FileManager.default.contentsOfDirectory(at: machinesDir, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Machine] = []
        for bundle in bundles where bundle.pathExtension == "pocketvm" {
            guard let data = try? Data(contentsOf: bundle.appending(path: "config.json")),
                  let config = try? decoder.decode(VMConfig.self, from: data) else { continue }
            loaded.append(machine(config.id) ?? Machine(config: config, bundle: bundle))
        }
        machines = loaded
    }

    @discardableResult
    func create(_ config: VMConfig, source: InstallSource) -> Machine? {
        let bundle = machinesDir.appending(path: "\(config.id.uuidString).pocketvm", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let machine = Machine(config: config, bundle: bundle)
            try machine.save()
            machines.append(machine)
            selection = machine.id
            machine.provision(from: source)
            return machine
        } catch {
            report(error, title: "Couldn’t create “\(config.name)”")
            return nil
        }
    }

    @discardableResult
    func duplicate(_ machine: Machine, name: String? = nil) -> Machine? {
        guard !machine.isActive, machine.status != .preparing else { return nil }
        var config = machine.config
        config.id = UUID()
        config.name = name ?? "\(machine.config.name) Copy"
        config.macAddress = VZMACAddress.randomLocallyAdministered().string
        config.createdAt = Date()
        config.lastUsedAt = nil
        let bundle = machinesDir.appending(path: "\(config.id.uuidString).pocketvm", directoryHint: .isDirectory)
        do {
            // On APFS this is a clone: the copy takes no space until it diverges.
            try FileManager.default.copyItem(at: machine.bundle, to: bundle)
            let copy = Machine(config: config, bundle: bundle)
            try? FileManager.default.removeItem(at: copy.saveURL)
            try? FileManager.default.removeItem(at: copy.snapshotsDir)
            try copy.save()
            copy.status = .stopped
            machines.append(copy)
            selection = copy.id
            return copy
        } catch {
            report(error, title: "Couldn’t duplicate “\(machine.config.name)”")
            return nil
        }
    }

    func trash(_ machine: Machine) async {
        machine.cancelSetup()
        if machine.isActive { await machine.forceStop() }
        if !isDemo {
            do {
                try FileManager.default.trashItem(at: machine.bundle, resultingItemURL: nil)
            } catch {
                report(error, title: "Couldn’t move “\(machine.config.name)” to the Trash")
                return
            }
        }
        machines.removeAll { $0.id == machine.id }
        if selection == machine.id { selection = sorted.first?.id }
    }

    func report(_ error: Error, title: String) {
        alert = AlertInfo(title: title, message: error.localizedDescription)
    }

    // MARK: Demo

    /// `--demo` fills the library with sample machines (nothing touches disk).
    private func loadDemo() {
        let rows: [(String, GuestOS, String?, Int, Int, Int64, Int, String, Machine.Status)] = [
            ("macOS 27", .macOS, nil, 4, 8, 7_470_000_000, 1000, "macOS 27.0.1 (26A434)", .running),
            ("Windows 11", .windows, nil, 4, 8, 4_900_000_000, 1000, "Windows 11 (25H2)", .running),
            ("Ubuntu 26.04", .linux, "ubuntu", 4, 8, 135_100_000, 1000, "Ubuntu 26.04.1 LTS", .paused),
            ("Agent's Mac", .macOS, nil, 8, 16, 4_200_000, 1000, "macOS 27.0.1 (26A434)", .stopped),
            ("Windows Dev", .windows, nil, 6, 12, 0, 512, "Windows 11 (25H2)", .stopped),
            ("Web Server", .linux, "ubuntu", 2, 4, 0, 128, "Ubuntu 26.04.1 LTS", .stopped),
            ("Xcode Builds", .macOS, nil, 12, 32, 4_200_000, 1000, "macOS 27.0.1 (26A434)", .stopped),
            ("Office PC", .windows, nil, 4, 8, 0, 256, "Windows 11 (25H2)", .stopped),
            ("Clean macOS", .macOS, nil, 4, 8, 4_200_000, 256, "macOS 27.0.1 (26A434)", .stopped),
        ]
        machines = rows.enumerated().map { index, row in
            let config = VMConfig(
                name: row.0, os: row.1, distro: row.2, osVersion: row.7,
                cpuCount: row.3, memoryGB: row.4, diskGB: row.6,
                installed: true, createdAt: Date(timeIntervalSince1970: Double(index)))
            let machine = Machine(config: config, bundle: URL(filePath: "/dev/null"))
            machine.isDemo = true
            machine.allocatedBytes = row.5
            machine.status = row.8
            return machine
        }
        selection = machines[2].id
    }
}

