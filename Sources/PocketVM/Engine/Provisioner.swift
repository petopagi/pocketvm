import CryptoKit
import Foundation
import Virtualization

enum InstallSource {
    /// Newest macOS this Mac supports, straight from Apple.
    case macLatest
    case ipsw(URL)
    case iso(URL)
    /// A download, verified against the publisher's SHA-256 list when one is given.
    case download(URL, checksums: URL?)
}

struct LinuxPreset: Identifiable, Hashable {
    let id: String
    let title: String
    let distro: String
    let version: String
    let defaultName: String
    let url: URL
    /// The publisher's SHA-256 list; the download must match it.
    let checksums: URL

    static let all: [LinuxPreset] = [
        LinuxPreset(
            id: "ubuntu-desktop", title: "Ubuntu 26.04.1 LTS", distro: "ubuntu",
            version: "Ubuntu 26.04.1 LTS", defaultName: "Ubuntu 26.04",
            url: URL(string: "https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04.1-desktop-arm64.iso")!,
            checksums: URL(string: "https://cdimage.ubuntu.com/releases/26.04/release/SHA256SUMS")!),
        LinuxPreset(
            id: "ubuntu-server", title: "Ubuntu 26.04.1 LTS Server", distro: "ubuntu",
            version: "Ubuntu 26.04.1 LTS", defaultName: "Ubuntu Server",
            url: URL(string: "https://cdimage.ubuntu.com/releases/26.04/release/ubuntu-26.04.1-live-server-arm64.iso")!,
            checksums: URL(string: "https://cdimage.ubuntu.com/releases/26.04/release/SHA256SUMS")!),
        LinuxPreset(
            id: "fedora-workstation", title: "Fedora 44 Workstation", distro: "fedora",
            version: "Fedora 44", defaultName: "Fedora 44",
            url: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-Live-44-1.7.aarch64.iso")!,
            checksums: URL(string: "https://download.fedoraproject.org/pub/fedora/linux/releases/44/Workstation/aarch64/iso/Fedora-Workstation-44-1.7-aarch64-CHECKSUM")!),
    ]
}

extension Machine {
    func provision(from source: InstallSource) {
        status = .preparing
        activity = "Getting ready…"
        provisionTask = Task { [weak self] in
            guard let self else { return }
            do {
                if config.os == .macOS {
                    try await installMac(from: source)
                } else {
                    try await prepareEFI(from: source)
                }
                status = .stopped
                activity = nil
                progress = nil
                refreshDiskUsage()
                Library.shared.open(id)
            } catch {
                status = .stopped
                activity = nil
                progress = nil
                if !(error is CancellationError) && !Task.isCancelled {
                    Library.shared.report(error, title: "Couldn’t set up “\(config.name)”")
                }
            }
        }
    }

    private func installMac(from source: InstallSource) async throws {
        let ipsw: URL
        switch source {
        case .ipsw(let url):
            ipsw = url
        default:
            activity = "Finding the newest macOS…"
            let latest = try await VZMacOSRestoreImage.latestSupported
            let label = "macOS \(latest.operatingSystemVersion.short)"
            ipsw = try await download(latest.url, label: label)
        }

        activity = "Checking the restore image…"
        progress = nil
        let image = try await VZMacOSRestoreImage.image(from: ipsw)
        guard let requirements = image.mostFeaturefulSupportedConfiguration,
              requirements.hardwareModel.isSupported else {
            throw PocketError("This Mac can’t run macOS \(image.operatingSystemVersion.short).")
        }

        let version = image.operatingSystemVersion
        config.osVersion = "macOS \(version.short) (\(image.buildVersion))"
        if config.name.isEmpty { config.name = "macOS \(version.majorVersion)" }
        config.cpuCount = max(config.cpuCount, requirements.minimumSupportedCPUCount)
        config.memoryGB = max(config.memoryGB, Int(requirements.minimumSupportedMemorySize >> 30))

        try requirements.hardwareModel.dataRepresentation.write(to: hardwareModelURL)
        try VZMacMachineIdentifier().dataRepresentation.write(to: machineIdentifierURL)
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: auxiliaryURL, hardwareModel: requirements.hardwareModel, options: [.allowOverwrite])
        try createDisk()
        try save()

        let vm = VZVirtualMachine(configuration: try ConfigBuilder.make(for: self))
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        activity = "Installing macOS \(version.short)…"
        progress = 0
        let observation = installer.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            let fraction = p.fractionCompleted
            Task { @MainActor in
                self?.progress = fraction
                self?.refreshDiskUsage()
            }
        }
        defer { observation.invalidate() }
        try await withTaskCancellationHandler {
            try await installer.install()
        } onCancel: {
            installer.progress.cancel()
        }
        config.installed = true
        try save()
    }

    private func prepareEFI(from source: InstallSource) async throws {
        let iso: URL
        switch source {
        case .iso(let url): iso = url
        case .download(let url, let checksums): iso = try await download(url, label: config.osVersion, checksums: checksums)
        default: throw PocketError("Pick an installer ISO.")
        }
        activity = "Creating the disk…"
        progress = nil
        try createDisk()
        _ = try VZEFIVariableStore(creatingVariableStoreAt: nvramURL, options: [.allowOverwrite])
        try VZGenericMachineIdentifier().dataRepresentation.write(to: machineIdentifierURL)
        config.installerISO = iso.path
        config.installed = true
        try save()
    }

    /// Downloads into the shared cache, so a second machine of the same system skips the wait.
    private func download(_ remote: URL, label: String, checksums: URL? = nil) async throws -> URL {
        let destination = Library.shared.downloadsDir.appending(path: remote.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        // Fetch the expected hash first, so a tampered list can't be swapped in after the fact.
        var expected: String?
        if let checksums {
            activity = "Checking \(label)…"
            expected = try await Downloader.expectedSHA256(of: remote.lastPathComponent, listedAt: checksums)
        }
        activity = "Downloading \(label)…"
        progress = 0
        let file = try await Downloader.fetch(remote, to: destination) { [weak self] received, total in
            guard let self else { return }
            progress = total > 0 ? Double(received) / Double(total) : nil
            activity = total > 0
                ? "Downloading \(label) · \(Bytes.string(received)) of \(Bytes.string(total))"
                : "Downloading \(label) · \(Bytes.string(received))"
        }
        if let expected {
            activity = "Verifying \(label)…"
            progress = nil
            let actual = try await Downloader.sha256(of: file)
            guard actual == expected else {
                try? FileManager.default.removeItem(at: file)
                throw PocketError("The download of \(label) didn’t match its published checksum, so it was deleted. Try again.")
            }
        }
        return file
    }
}

extension OperatingSystemVersion {
    var short: String {
        patchVersion > 0 ? "\(majorVersion).\(minorVersion).\(patchVersion)" : "\(majorVersion).\(minorVersion)"
    }
}

enum Downloader {
    /// Reads a SHA256SUMS / CHECKSUM list and returns the hash published for `filename`.
    static func expectedSHA256(of filename: String, listedAt list: URL) async throws -> String {
        let (data, response) = try await URLSession.shared.data(from: list)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw PocketError("Couldn’t fetch the checksum list for \(filename).")
        }
        let hex = try NSRegularExpression(pattern: "\\b[0-9a-fA-F]{64}\\b")
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) where line.contains(filename) {
            let text = String(line)
            if let match = hex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range, in: text) {
                return text[range].lowercased()
            }
        }
        throw PocketError("\(filename) isn’t in its publisher’s checksum list.")
    }

    static func sha256(of file: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    var hasher = SHA256()
                    while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
                        hasher.update(data: chunk)
                    }
                    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
                })
            }
        }
    }

    /// Downloads to a temp file and moves it into place only when complete,
    /// so the cache never holds a partial image.
    static func fetch(_ remote: URL, to destination: URL,
                      progress: @escaping @MainActor (Int64, Int64) -> Void) async throws -> URL {
        final class Box: @unchecked Sendable {
            var task: URLSessionDownloadTask?
            var observation: NSKeyValueObservation?
            var lastReport = Date.distantPast
        }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.downloadTask(with: remote) { temp, response, error in
                    box.observation?.invalidate()
                    if let error {
                        continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
                        return
                    }
                    guard let temp, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        continuation.resume(throwing: PocketError("The download failed (HTTP \(code))."))
                        return
                    }
                    do {
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: temp, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.task = task
                box.observation = task.progress.observe(\.fractionCompleted) { _, _ in
                    let now = Date()
                    guard now.timeIntervalSince(box.lastReport) > 0.25 else { return }
                    box.lastReport = now
                    let received = task.countOfBytesReceived
                    let total = task.countOfBytesExpectedToReceive
                    Task { @MainActor in progress(received, total) }
                }
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}

/// What to build: shared by the New Virtual Machine sheet and the MCP `create_machine` tool.
struct MachineRecipe {
    var os: GuestOS
    var name = ""
    /// Linux only: a preset to download, or nil to use `file`.
    var linuxPreset: LinuxPreset? = LinuxPreset.all.first
    /// An IPSW (macOS) or ISO (Linux, Windows). For macOS, nil means the newest from Apple.
    var file: URL?
    var cpuCount = min(4, Host.cpuCount)
    var memoryGB = min(8, Host.memoryChoices.last ?? 8)
    var diskGB = 128
    var agentAccess = false

    var needsFile: Bool {
        switch os {
        case .macOS: false
        case .linux: linuxPreset == nil
        case .windows: true
        }
    }

    var defaultName: String {
        switch os {
        case .macOS: "macOS"
        case .windows: "Windows 11"
        case .linux: linuxPreset?.defaultName ?? file?.deletingPathExtension().lastPathComponent ?? "Linux"
        }
    }

    func make() throws -> (VMConfig, InstallSource) {
        if needsFile && file == nil {
            throw PocketError(os == .windows ? "Windows needs an ARM64 installer ISO." : "Pick an installer ISO.")
        }
        if let file, !FileManager.default.fileExists(atPath: file.path) {
            throw PocketError("There’s no file at \(file.path).")
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        var config = VMConfig(
            // macOS fills its name in once it knows the version.
            name: trimmed.isEmpty && os != .macOS ? defaultName : trimmed,
            os: os, osVersion: "",
            cpuCount: cpuCount.clamped(1, Host.cpuCount),
            memoryGB: memoryGB.clamped(2, Swift.max(2, Host.memoryGB - 2)),
            diskGB: diskGB.clamped(16, 8000))
        config.agentAccess = agentAccess
        switch os {
        case .macOS:
            config.osVersion = "macOS"
            return (config, file.map(InstallSource.ipsw) ?? .macLatest)
        case .windows:
            config.osVersion = "Windows 11 ARM"
            return (config, .iso(file!))
        case .linux:
            if let preset = linuxPreset {
                config.distro = preset.distro
                config.osVersion = preset.version
                return (config, .download(preset.url, checksums: preset.checksums))
            }
            let base = file!.deletingPathExtension().lastPathComponent
            config.distro = ["ubuntu", "fedora"].first { base.lowercased().contains($0) }
            config.osVersion = base
            return (config, .iso(file!))
        }
    }
}
