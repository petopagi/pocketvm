import AppKit
import Observation
import Virtualization

/// A machine on disk plus its live `VZVirtualMachine`, when one is running.
@MainActor @Observable
final class Machine: Identifiable {
    enum Status: Equatable {
        case stopped, preparing, starting, running, paused, suspended, stopping
    }

    var config: VMConfig
    let bundle: URL
    var status: Status = .stopped
    /// Shown in place of the spec line while a machine is being set up.
    var activity: String?
    var progress: Double?
    var allocatedBytes: Int64 = 0
    var vm: VZVirtualMachine?
    var stats: MachineStats?
    var startedAt: Date?
    /// Bumped when snapshots change, so menus listing them refresh.
    var snapshotRevision = 0
    /// The Virtualization XPC process running this machine, for stats.
    @ObservationIgnored var hostPID: pid_t?

    @ObservationIgnored var provisionTask: Task<Void, Never>?
    @ObservationIgnored private var delegate: Delegate?
    @ObservationIgnored private var suspending = false
    @ObservationIgnored var isDemo = false
    /// The live clipboard channel of a running Linux or Windows machine.
    @ObservationIgnored private(set) var spiceAgent: VZSpiceAgentPortAttachment? {
        didSet { clipboardChannelLive = spiceAgent != nil }
    }
    /// Whether the running machine has the clipboard channel (machines started by older builds don't).
    private(set) var clipboardChannelLive = false
    @ObservationIgnored private var clipboardBridge: ClipboardBridge?
    /// PocketVM Tools in the guest are connected.
    var guestToolsConnected = false
    /// Window class of the guest's focused app, reported by PocketVM Tools.
    @ObservationIgnored var guestFocusClass = ""

    /// Ctrl+C / Ctrl+V act as copy / paste: a Linux terminal has focus and the owner wants it.
    var terminalShortcutsActive: Bool {
        guard config.terminalShortcuts, guestToolsConnected else { return false }
        let name = guestFocusClass.lowercased()
        return ["terminal", "ptyxis", "console", "kitty", "alacritty", "xterm", "konsole", "foot",
                "ghostty", "tilix", "wezterm", "terminator", "termite", "urxvt"].contains { name.contains($0) }
    }

    /// The PocketVM Tools card is showing in the machine window.
    var toolsCardVisible = false
    /// The install offer was shown since this machine last started.
    @ObservationIgnored var toolsOfferShown = false

    /// A running Linux machine that has never run PocketVM Tools, and whose owner hasn't said no.
    var shouldOfferGuestTools: Bool {
        config.os == .linux && status == .running && clipboardChannelLive
            && (config.guestToolsVersion ?? 0) < GuestTools.version && !config.toolsPromptDismissed && !toolsOfferShown && !isDemo
    }
    private var toolsDisk: VZUSBMassStorageDevice?
    private var filesDisk: VZUSBMassStorageDevice?
    var guestToolsAttached: Bool { toolsDisk != nil }
    /// The on-screen view, registered by the machine window; agents read and drive it.
    @ObservationIgnored weak var display: VZVirtualMachineView?

    nonisolated var id: UUID { _id }
    @ObservationIgnored private nonisolated let _id: UUID

    init(config: VMConfig, bundle: URL) {
        self.config = config
        self.bundle = bundle
        self._id = config.id
        if FileManager.default.fileExists(atPath: saveURL.path) { status = .suspended }
        refreshDiskUsage()
    }

    // MARK: Files

    var configURL: URL { bundle.appending(path: "config.json") }
    var diskURL: URL { bundle.appending(path: "Disk.img") }
    var auxiliaryURL: URL { bundle.appending(path: "AuxiliaryStorage") }
    var hardwareModelURL: URL { bundle.appending(path: "HardwareModel") }
    var machineIdentifierURL: URL { bundle.appending(path: "MachineIdentifier") }
    var nvramURL: URL { bundle.appending(path: "NVRAM") }
    var saveURL: URL { bundle.appending(path: "State.vzvmsave") }
    var snapshotsDir: URL { bundle.appending(path: "Snapshots", directoryHint: .isDirectory) }

    func save() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    func refreshDiskUsage() {
        guard !isDemo else { return }
        let values = try? diskURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        allocatedBytes = Int64(values?.totalFileAllocatedSize ?? 0)
    }

    func createDisk() throws {
        FileManager.default.createFile(atPath: diskURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: diskURL)
        try handle.truncate(atOffset: UInt64(config.diskGB) * 1_000_000_000)
        try handle.close()
    }

    /// Disks only ever grow; the guest resizes its own partition.
    func growDisk(to gb: Int) throws {
        guard gb > config.diskGB else { return }
        let handle = try FileHandle(forWritingTo: diskURL)
        try handle.truncate(atOffset: UInt64(gb) * 1_000_000_000)
        try handle.close()
        config.diskGB = gb
    }

    // MARK: State

    var isActive: Bool { [.starting, .running, .paused, .stopping].contains(status) }
    var canStart: Bool { config.installed && [.stopped, .suspended, .paused].contains(status) }

    var specLine: String {
        "\(config.cpuCount) CPU · \(config.memoryGB) GB RAM · \(Bytes.string(allocatedBytes)) of \(Bytes.disk(config.diskGB)) · \(config.osVersion)"
    }

    // MARK: Lifecycle

    func start() async {
        if isDemo { status = .running; return }
        if status == .paused { await resume(); return }
        guard canStart else { return }
        let wasSuspended = status == .suspended
        status = .starting
        let existingProcesses = HostProcesses.virtualMachinePIDs()
        do {
            let vm = try makeVM()
            if wasSuspended {
                do {
                    try await vm.restoreMachineStateFrom(url: saveURL)
                    try await vm.resume()
                    self.vm = vm
                } catch {
                    // A stale or incompatible save: boot cleanly instead.
                    let fresh = try makeVM()
                    try await fresh.start()
                    self.vm = fresh
                }
                try? FileManager.default.removeItem(at: saveURL)
            } else {
                try await vm.start()
                self.vm = vm
            }
            status = .running
            startBridge()
            startedAt = Date()
            hostPID = HostProcesses.virtualMachinePIDs().subtracting(existingProcesses).first
            config.lastUsedAt = Date()
            try? save()
        } catch {
            vm = nil
            status = FileManager.default.fileExists(atPath: saveURL.path) ? .suspended : .stopped
            Library.shared.report(error, title: "Couldn’t start “\(config.name)”")
        }
    }

    func pause() async {
        if isDemo { status = .paused; return }
        guard let vm, status == .running, vm.canPause else { return }
        do {
            try await vm.pause()
            status = .paused
        } catch {
            Library.shared.report(error, title: "Couldn’t pause “\(config.name)”")
        }
    }

    func resume() async {
        if isDemo { status = .running; return }
        guard let vm, status == .paused, vm.canResume else { return }
        do {
            try await vm.resume()
            status = .running
        } catch {
            Library.shared.report(error, title: "Couldn’t resume “\(config.name)”")
        }
    }

    /// Saves memory to disk and powers off, so the next start picks up where it left off.
    @discardableResult
    func suspend(reportErrors: Bool = true) async -> Bool {
        guard let vm, status == .running || status == .paused else { return false }
        do {
            try ConfigBuilder.make(for: self).validateSaveRestoreSupport()
        } catch {
            if reportErrors {
                Library.shared.report(
                    PocketError("Remove the installer ISO in Settings first — USB devices can’t be saved."),
                    title: "“\(config.name)” can’t be suspended")
            }
            return false
        }
        await detachGuestTools()
        await detachFiles()
        suspending = true
        defer { suspending = false }
        do {
            if vm.state == .running { try await vm.pause() }
            status = .paused
            try await vm.saveMachineStateTo(url: saveURL)
            try await vm.stop()
            self.vm = nil
            spiceAgent = nil
            stopBridge()
            hostPID = nil
            startedAt = nil
            status = .suspended
            refreshDiskUsage()
            return true
        } catch {
            try? FileManager.default.removeItem(at: saveURL)
            if reportErrors { Library.shared.report(error, title: "Couldn’t suspend “\(config.name)”") }
            return false
        }
    }

    /// Asks the guest to shut down, like pressing the power button.
    func shutDown() {
        if isDemo { status = .stopped; return }
        guard let vm, vm.canRequestStop else { return }
        do {
            // The guest may ignore the power button, so stay usable until it actually stops.
            try vm.requestStop()
        } catch {
            Library.shared.report(error, title: "Couldn’t shut down “\(config.name)”")
        }
    }

    func forceStop() async {
        if isDemo { status = .stopped; return }
        guard let vm else { return }
        try? await vm.stop()
        didStop(error: nil)
    }

    func cancelSetup() {
        provisionTask?.cancel()
    }

    fileprivate func didStop(error: Error?) {
        guard !suspending else { return }
        vm = nil
        spiceAgent = nil
        stopBridge()
        hostPID = nil
        startedAt = nil
        stats = nil
        status = .stopped
        refreshDiskUsage()
        if let error { Library.shared.report(error, title: "“\(config.name)” stopped unexpectedly") }
    }

    /// Turns clipboard sharing on or off. Returns false when the running machine was started
    /// without the clipboard channel, so the change waits for its next start.
    @discardableResult
    func setClipboardSharing(_ on: Bool) -> Bool {
        config.clipboardSharing = on
        if !isDemo { try? save() }
        if on { clipboardBridge?.syncNow() }
        guard let spiceAgent else { return !isActive }
        spiceAgent.sharesClipboard = on
        return true
    }

    private func startBridge() {
        stopBridge()
        if let device = vm?.socketDevices.first as? VZVirtioSocketDevice {
            clipboardBridge = ClipboardBridge(machine: self, device: device)
        }
    }

    private func stopBridge() {
        toolsOfferShown = false
        clipboardBridge?.stop()
        clipboardBridge = nil
        guestToolsConnected = false
        guestFocusClass = ""
        toolsDisk = nil
        filesDisk = nil
    }

    /// Hot-plugs the PocketVM Tools disk; the guest mounts it and runs `GuestTools.installCommand`.
    func attachGuestTools() async throws {
        guard config.os == .linux else { throw PocketError("PocketVM Tools are for Linux machines.") }
        guard status == .running, let vm else { throw PocketError("Start “\(config.name)” first.") }
        guard let controller = vm.usbControllers.first else {
            throw PocketError("“\(config.name)” was started by an older PocketVM. Shut it down and start it again.")
        }
        guard toolsDisk == nil else { return }
        let attachment = try VZDiskImageStorageDeviceAttachment(url: try GuestTools.linuxImage(), readOnly: true)
        let disk = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        try await controller.attach(device: disk)
        toolsDisk = disk
    }

    /// Hot-plugs a read-only disk holding `files` (replacing any sent before). Linux only.
    func sendFiles(_ files: [(name: String, data: Data)]) async throws -> String {
        guard config.os == .linux else { throw PocketError("Sending files works with Linux machines.") }
        guard status == .running, let vm else { throw PocketError("Start “\(config.name)” first.") }
        guard let controller = vm.usbControllers.first else {
            throw PocketError("“\(config.name)” was started by an older PocketVM. Shut it down and start it again.")
        }
        await detachFiles()
        let volume = "POCKETVM-FILES"
        let image = try DiskImage.iso(files, volume: volume,
                                      at: FileManager.default.temporaryDirectory.appending(path: "pocketvm-files-\(id.uuidString).iso"))
        let attachment = try VZDiskImageStorageDeviceAttachment(url: image, readOnly: true)
        let disk = VZUSBMassStorageDevice(configuration: VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        try await controller.attach(device: disk)
        filesDisk = disk
        return volume
    }

    func detachFiles() async {
        guard let disk = filesDisk, let controller = vm?.usbControllers.first else { filesDisk = nil; return }
        try? await controller.detach(device: disk)
        filesDisk = nil
    }

    func detachGuestTools() async {
        guard let disk = toolsDisk, let controller = vm?.usbControllers.first else { toolsDisk = nil; return }
        try? await controller.detach(device: disk)
        toolsDisk = nil
    }

    var supportsClipboardSharing: Bool { config.os != .macOS }

    private func makeVM() throws -> VZVirtualMachine {
        let configuration = try ConfigBuilder.make(for: self)
        spiceAgent = (configuration.consoleDevices.first as? VZVirtioConsoleDeviceConfiguration)?
            .ports[0]?.attachment as? VZSpiceAgentPortAttachment
        let vm = VZVirtualMachine(configuration: configuration)
        let delegate = Delegate(machine: self)
        vm.delegate = delegate
        self.delegate = delegate
        return vm
    }
}

private final class Delegate: NSObject, VZVirtualMachineDelegate {
    weak var machine: Machine?

    init(machine: Machine) { self.machine = machine }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        MainActor.assumeIsolated { machine?.didStop(error: nil) }
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        MainActor.assumeIsolated { machine?.didStop(error: error) }
    }
}
