import AppKit
import Virtualization

/// Turns a `Machine` into a validated `VZVirtualMachineConfiguration`.
@MainActor
enum ConfigBuilder {
    static func make(for machine: Machine) throws -> VZVirtualMachineConfiguration {
        let config = machine.config
        let c = VZVirtualMachineConfiguration()
        c.cpuCount = config.cpuCount.clamped(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        c.memorySize = (UInt64(config.memoryGB) << 30).clamped(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            VZVirtualMachineConfiguration.maximumAllowedMemorySize)

        let disk = try VZDiskImageStorageDeviceAttachment(
            url: machine.diskURL, readOnly: false, cachingMode: .automatic, synchronizationMode: .fsync)

        switch config.os {
        case .macOS:
            try configureMac(c, machine: machine, disk: disk)
        case .linux, .windows:
            try configureEFI(c, machine: machine, disk: disk)
        }

        switch config.network {
        case .nat:
            let network = VZVirtioNetworkDeviceConfiguration()
            network.attachment = VZNATNetworkDeviceAttachment()
            if let mac = VZMACAddress(string: config.macAddress) { network.macAddress = mac }
            c.networkDevices = [network]
        case .none:
            c.networkDevices = []
        }
        c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        let speaker = VZVirtioSoundDeviceOutputStreamConfiguration()
        speaker.sink = VZHostAudioOutputStreamSink()
        let sound = VZVirtioSoundDeviceConfiguration()
        sound.streams = [speaker]
        c.audioDevices = [sound]

        var shares: [VZDirectorySharingDeviceConfiguration] = []
        if let folder = config.sharedFolder {
            // macOS guests mount this automatically under /Volumes/My Shared Files.
            // Linux: `sudo mount -t virtiofs pocketvm /mnt/pocketvm`
            let tag = config.os == .macOS ? VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag : "pocketvm"
            let device = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            device.share = VZSingleDirectoryShare(directory: VZSharedDirectory(url: URL(filePath: folder), readOnly: config.sharedFolderReadOnly))
            shares.append(device)
        }
        if config.os == .linux, VZLinuxRosettaDirectoryShare.availability == .installed,
           let rosetta = try? VZLinuxRosettaDirectoryShare() {
            let device = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
            device.share = rosetta
            shares.append(device)
        }
        c.directorySharingDevices = shares

        try c.validate()
        return c
    }

    private static func configureMac(_ c: VZVirtualMachineConfiguration, machine: Machine, disk: VZDiskImageStorageDeviceAttachment) throws {
        guard let modelData = try? Data(contentsOf: machine.hardwareModelURL),
              let model = VZMacHardwareModel(dataRepresentation: modelData) else {
            throw PocketError("The machine’s hardware model is missing.")
        }
        guard model.isSupported else {
            throw PocketError("This Mac can’t run this version of macOS.")
        }
        guard let idData = try? Data(contentsOf: machine.machineIdentifierURL),
              let identifier = VZMacMachineIdentifier(dataRepresentation: idData) else {
            throw PocketError("The machine’s identifier is missing.")
        }
        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = model
        platform.machineIdentifier = identifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: machine.auxiliaryURL)
        c.platform = platform
        c.bootLoader = VZMacOSBootLoader()

        let graphics = VZMacGraphicsDeviceConfiguration()
        if let screen = NSScreen.main {
            graphics.displays = [VZMacGraphicsDisplayConfiguration(for: screen, sizeInPoints: NSSize(width: 1440, height: 900))]
        } else {
            graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 2880, heightInPixels: 1800, pixelsPerInch: 220)]
        }
        c.graphicsDevices = [graphics]
        c.keyboards = [VZMacKeyboardConfiguration()]
        c.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        c.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
    }

    private static func configureEFI(_ c: VZVirtualMachineConfiguration, machine: Machine, disk: VZDiskImageStorageDeviceAttachment) throws {
        let config = machine.config
        guard let idData = try? Data(contentsOf: machine.machineIdentifierURL),
              let identifier = VZGenericMachineIdentifier(dataRepresentation: idData) else {
            throw PocketError("The machine’s identifier is missing.")
        }
        let platform = VZGenericPlatformConfiguration()
        platform.machineIdentifier = identifier
        if config.os == .linux, config.nestedVirtualization, VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
            platform.isNestedVirtualizationEnabled = true
        }
        c.platform = platform

        let boot = VZEFIBootLoader()
        boot.variableStore = VZEFIVariableStore(url: machine.nvramURL)
        c.bootLoader = boot

        let graphics = VZVirtioGraphicsDeviceConfiguration()
        graphics.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1920, heightInPixels: 1200)]
        c.graphicsDevices = [graphics]
        c.keyboards = [VZUSBKeyboardConfiguration()]
        c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

        // Windows ships an NVMe driver but no virtio-blk one.
        var storage: [VZStorageDeviceConfiguration] = config.os == .windows
            ? [VZNVMExpressControllerDeviceConfiguration(attachment: disk)]
            : [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        if let iso = config.installerISO, FileManager.default.fileExists(atPath: iso) {
            let attachment = try VZDiskImageStorageDeviceAttachment(url: URL(filePath: iso), readOnly: true)
            storage.append(VZUSBMassStorageDeviceConfiguration(attachment: attachment))
        }
        c.storageDevices = storage

        // The SPICE agent channel is always attached so clipboard sharing can be switched live;
        // `sharesClipboard` decides whether anything crosses it. Guests need spice-vdagent
        // (Ubuntu and Fedora desktops ship it; Windows needs the SPICE guest tools).
        let spice = VZSpiceAgentPortAttachment()
        spice.sharesClipboard = config.clipboardSharing
        let port = VZVirtioConsolePortConfiguration()
        port.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        port.attachment = spice
        let console = VZVirtioConsoleDeviceConfiguration()
        console.ports[0] = port
        c.consoleDevices = [console]

        if config.os == .linux {
            // PocketVM Tools talk to the Mac over vsock (clipboard on Wayland, where SPICE can't reach it),
            // and arrive on a USB disk hot-plugged into this controller.
            c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
            c.usbControllers = [VZXHCIControllerConfiguration()]
        }
    }
}

extension Comparable {
    func clamped(_ low: Self, _ high: Self) -> Self { min(max(self, low), high) }
}
