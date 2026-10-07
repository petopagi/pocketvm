import AppKit
import Virtualization

/// Syncs plain text between the Mac clipboard and PocketVM Tools in a Linux guest, over a
/// virtio-vsock port only that machine can reach. Nothing crosses while sharing is off.
///
/// Wire format: one message per line. "c <base64 UTF-8>" carries clipboard text (both ways);
/// "f <window class>" reports the guest's focused app (guest to Mac).
@MainActor
final class ClipboardBridge: NSObject, VZVirtioSocketListenerDelegate {
    static let port: UInt32 = 6080
    private static let maxBytes = 1 << 20

    private weak var machine: Machine?
    private let device: VZVirtioSocketDevice
    private let listener = VZVirtioSocketListener()
    private var connection: VZVirtioSocketConnection?
    private var handle: FileHandle?
    private var buffer = Data()
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastText: String?

    init(machine: Machine, device: VZVirtioSocketDevice) {
        self.machine = machine
        self.device = device
        super.init()
        listener.delegate = self
        device.setSocketListener(listener, forPort: Self.port)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollMac() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        drop()
        device.removeSocketListener(forPort: Self.port)
    }

    /// Pushes the Mac's current clipboard, e.g. right after sharing is turned on.
    func syncNow() {
        lastChangeCount = -1
        pollMac()
    }

    nonisolated func listener(_ listener: VZVirtioSocketListener,
                              shouldAcceptNewConnection connection: VZVirtioSocketConnection,
                              from socketDevice: VZVirtioSocketDevice) -> Bool {
        MainActor.assumeIsolated { adopt(connection) }
        return true
    }

    private var sharing: Bool { machine?.config.clipboardSharing == true }

    private func adopt(_ new: VZVirtioSocketConnection) {
        drop()
        connection = new
        let handle = FileHandle(fileDescriptor: new.fileDescriptor, closeOnDealloc: false)
        handle.readabilityHandler = { [weak self] fileHandle in
            let data = fileHandle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        self.handle = handle
        machine?.guestToolsConnected = true
        // Tools are in; their install disk can go.
        Task { await machine?.detachGuestTools() }
        if sharing { syncNow() }
    }

    private func drop() {
        handle?.readabilityHandler = nil
        handle = nil
        connection?.close()
        connection = nil
        buffer.removeAll()
        machine?.guestToolsConnected = false
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { drop(); return }
        buffer.append(data)
        if buffer.count > Self.maxBytes * 2 { buffer.removeAll(); return }
        while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            let message = String(decoding: line, as: UTF8.self)
            if message.hasPrefix("v "), let version = Int(message.dropFirst(2)), let machine {
                if machine.config.guestToolsVersion != version {
                    machine.config.guestToolsVersion = version
                    try? machine.save()
                }
                continue
            }
            if message.hasPrefix("f ") || message == "f" {
                machine?.guestFocusClass = String(message.dropFirst(2))
                continue
            }
            // v1 tools sent bare base64 lines and no version; remember them as version 1.
            if !message.hasPrefix("c "), machine?.config.guestToolsVersion == nil {
                machine?.config.guestToolsVersion = 1
                try? machine?.save()
            }
            let payload = message.hasPrefix("c ") ? String(message.dropFirst(2)) : message
            guard sharing, let decoded = Data(base64Encoded: payload), decoded.count <= Self.maxBytes,
                  let text = String(data: decoded, encoding: .utf8), text != lastText else { continue }
            lastText = text
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            lastChangeCount = pasteboard.changeCount
        }
    }

    private func pollMac() {
        let pasteboard = NSPasteboard.general
        guard sharing, handle != nil, pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let text = pasteboard.string(forType: .string), text != lastText,
              text.utf8.count <= Self.maxBytes else { return }
        lastText = text
        try? handle?.write(contentsOf: Data(("c " + Data(text.utf8).base64EncodedString() + "\n").utf8))
    }
}
