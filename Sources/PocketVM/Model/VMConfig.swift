import Foundation
import Virtualization

enum GuestOS: String, Codable, CaseIterable, Identifiable {
    case macOS, windows, linux

    var id: String { rawValue }

    var title: String {
        switch self {
        case .macOS: "macOS"
        case .windows: "Windows 11"
        case .linux: "Linux"
        }
    }
}

/// Everything PocketVM persists about a machine. Lives at `<bundle>/config.json`.
struct VMConfig: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var os: GuestOS
    /// "ubuntu", "fedora", … — only used to pick the row glyph.
    var distro: String?
    /// Human readable system line, e.g. "macOS 27.0.1 (26A434)".
    var osVersion: String
    var cpuCount: Int
    var memoryGB: Int
    var diskGB: Int
    var macAddress: String = VZMACAddress.randomLocallyAdministered().string
    /// Installer ISO attached as a USB stick (Linux / Windows).
    var installerISO: String?
    var sharedFolder: String?
    /// Lets MCP clients see the screen and drive the keyboard and mouse.
    var agentAccess = false
    /// localhost ports relayed to the guest while it runs.
    var portForwards: [PortForward] = []

    // Isolation. Every bridge between guest and Mac is off or read-only unless turned on.
    var network: NetworkMode = .nat
    /// Linux: lets the guest read and write the Mac's clipboard (spice-vdagent).
    var clipboardSharing = false
    var sharedFolderReadOnly = true
    /// Linux on M3 and later: lets the guest run its own VMs.
    var nestedVirtualization = false
    /// PocketVM Tools version last seen running in the guest.
    var guestToolsVersion: Int?
    var toolsPromptDismissed = false
    /// In guest terminals: Ctrl+C copies, Ctrl+V pastes, Ctrl+C twice interrupts.
    var terminalShortcuts = true
    var installed = false
    var createdAt = Date()
    var lastUsedAt: Date?

    init(name: String, os: GuestOS, distro: String? = nil, osVersion: String,
         cpuCount: Int, memoryGB: Int, diskGB: Int, installed: Bool = false, createdAt: Date = Date()) {
        self.name = name
        self.os = os
        self.distro = distro
        self.osVersion = osVersion
        self.cpuCount = cpuCount
        self.memoryGB = memoryGB
        self.diskGB = diskGB
        self.installed = installed
        self.createdAt = createdAt
    }

    /// Tolerates configs written by older builds: anything missing takes its default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        os = try c.decode(GuestOS.self, forKey: .os)
        distro = try c.decodeIfPresent(String.self, forKey: .distro)
        osVersion = try c.decodeIfPresent(String.self, forKey: .osVersion) ?? ""
        cpuCount = try c.decodeIfPresent(Int.self, forKey: .cpuCount) ?? 4
        memoryGB = try c.decodeIfPresent(Int.self, forKey: .memoryGB) ?? 8
        diskGB = try c.decodeIfPresent(Int.self, forKey: .diskGB) ?? 64
        macAddress = try c.decodeIfPresent(String.self, forKey: .macAddress) ?? VZMACAddress.randomLocallyAdministered().string
        installerISO = try c.decodeIfPresent(String.self, forKey: .installerISO)
        sharedFolder = try c.decodeIfPresent(String.self, forKey: .sharedFolder)
        agentAccess = try c.decodeIfPresent(Bool.self, forKey: .agentAccess) ?? false
        portForwards = try c.decodeIfPresent([PortForward].self, forKey: .portForwards) ?? []
        network = try c.decodeIfPresent(NetworkMode.self, forKey: .network) ?? .nat
        clipboardSharing = try c.decodeIfPresent(Bool.self, forKey: .clipboardSharing) ?? false
        sharedFolderReadOnly = try c.decodeIfPresent(Bool.self, forKey: .sharedFolderReadOnly) ?? true
        nestedVirtualization = try c.decodeIfPresent(Bool.self, forKey: .nestedVirtualization) ?? false
        guestToolsVersion = try c.decodeIfPresent(Int.self, forKey: .guestToolsVersion)
        toolsPromptDismissed = try c.decodeIfPresent(Bool.self, forKey: .toolsPromptDismissed) ?? false
        terminalShortcuts = try c.decodeIfPresent(Bool.self, forKey: .terminalShortcuts) ?? true
        installed = try c.decodeIfPresent(Bool.self, forKey: .installed) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        lastUsedAt = try c.decodeIfPresent(Date.self, forKey: .lastUsedAt)
    }
}

enum NetworkMode: String, Codable, CaseIterable, Identifiable {
    /// Internet through the Mac. The guest can also reach the Mac's own services and the local network.
    case nat
    /// No network device at all.
    case none

    var id: String { rawValue }
    var title: String { self == .nat ? "Internet (shared with this Mac)" : "None" }
}

struct PortForward: Codable, Hashable, Identifiable {
    var hostPort: UInt16
    var guestPort: UInt16
    var id: UInt16 { hostPort }
}

struct PocketError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Host {
    static let cpuCount = ProcessInfo.processInfo.processorCount
    static let memoryGB = Int(ProcessInfo.processInfo.physicalMemory >> 30)

    static var cpuChoices: [Int] {
        let max = min(cpuCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        return Array(Set([1, 2, 4, 6, 8, 10, 12, 16, 20, 24, 32].filter { $0 <= max } + [max])).sorted()
    }

    static var memoryChoices: [Int] {
        let max = Swift.max(2, memoryGB - 2)
        return [2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128].filter { $0 <= max }
    }

    static let diskChoices = [64, 128, 256, 512, 1000, 2000]
}

enum Bytes {
    static func string(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func disk(_ gb: Int) -> String { string(Int64(gb) * 1_000_000_000) }
}
