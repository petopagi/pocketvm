import SwiftUI
import Virtualization

struct MachineWindow: View {
    let machine: Machine
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // The display sits below the title bar; only the black backdrop runs under it.
        ZStack {
            if let vm = machine.vm {
                VMDisplay(machine: machine, vm: vm)
            }

            if machine.status != .running {
                cover
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: machine.status == .running)
        .background(Color.black.ignoresSafeArea())
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle(machine.config.name)
        .navigationSubtitle(statusText)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if machine.supportsClipboardSharing {
                    Toggle(isOn: clipboardBinding) {
                        Label("Share Clipboard", systemImage: machine.config.clipboardSharing ? "list.clipboard.fill" : "list.clipboard")
                    }
                    .toggleStyle(.button)
                    .help(clipboardHelp)
                }
                switch machine.status {
                case .running:
                    Button { Task { await machine.pause() } } label: { Label("Pause", systemImage: "pause") }
                case .paused, .suspended, .stopped:
                    Button { Task { await machine.start() } } label: { Label("Start", systemImage: "play") }
                        .disabled(!machine.config.installed)
                default:
                    EmptyView()
                }
                Menu {
                    Button("Shut Down") { machine.shutDown() }
                        .disabled(machine.status != .running)
                    Button("Suspend") { Task { await machine.suspend() } }
                        .disabled(machine.status != .running && machine.status != .paused)
                    Divider()
                    Button("Force Stop") { Task { await machine.forceStop() } }
                        .disabled(!machine.isActive)
                } label: {
                    Label("Power", systemImage: "power")
                }
                .menuIndicator(.hidden)
            }
        }
        .task(id: machine.status) {
            // Offer PocketVM Tools once the guest has had time to reach its desktop.
            guard machine.shouldOfferGuestTools else { return }
            try? await Task.sleep(for: .seconds(20))
            // Wait out the login screen; the installer needs a signed-in desktop.
            while machine.shouldOfferGuestTools, await ToolsInstaller.atLoginScreen(machine) {
                try? await Task.sleep(for: .seconds(10))
            }
            guard machine.shouldOfferGuestTools, !Task.isCancelled else { return }
            machine.toolsOfferShown = true
            machine.toolsCardVisible = true
        }
        .overlay(alignment: .bottomTrailing) {
            if machine.toolsCardVisible {
                GuestToolsCard(machine: machine) { machine.toolsCardVisible = false }
                    .padding(16)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: machine.toolsCardVisible)
        .onAppear {
            Library.shared.openWindow = Library.shared.openWindow ?? { openWindow(value: $0) }
            Library.shared.openLibraryWindow = Library.shared.openLibraryWindow ?? { openWindow(id: "library") }
            if machine.status == .stopped || machine.status == .suspended {
                Task { await machine.start() }
            }
        }
        .onDisappear {
            if machine.status == .running { Task { await machine.pause() } }
        }
    }

    private var clipboardBinding: Binding<Bool> {
        Binding(
            get: { machine.config.clipboardSharing },
            set: { on in
                if !machine.setClipboardSharing(on) && on {
                    Library.shared.alert = AlertInfo(
                        title: "Clipboard sharing starts after a restart",
                        message: "“\(machine.config.name)” was started without the clipboard channel. Shut it down and start it again; after that this switch works instantly.")
                }
            })
    }

    private var clipboardHelp: String {
        if machine.isActive && !machine.clipboardChannelLive && machine.config.clipboardSharing {
            return "Clipboard sharing is on and starts after a restart"
        }
        if machine.config.os == .linux && machine.config.clipboardSharing && machine.isActive && !machine.guestToolsConnected {
            return "Clipboard sharing is on. On GNOME with Wayland it needs PocketVM Tools (••• menu → Install PocketVM Tools)."
        }
        return machine.config.clipboardSharing
            ? "Clipboard is shared with this Mac. Click to stop sharing."
            : "Clipboard isn’t shared. Click to share it with this Mac (needs spice-vdagent in the guest)."
    }

    private var statusText: String {
        switch machine.status {
        case .running:
            if let stats = machine.stats {
                "Running · \(Int(stats.cpuPercent.rounded()))% CPU · \(Bytes.string(Int64(stats.memoryBytes))) memory"
            } else {
                "Running"
            }
        case .paused: "Paused"
        case .suspended: "Suspended"
        case .starting: "Starting"
        case .stopping: "Shutting down"
        case .preparing: machine.activity ?? "Setting up"
        case .stopped: "Off"
        }
    }

    /// Sits over the screen whenever the machine isn't running, so stray clicks never land in the guest.
    private var cover: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                MachineBadge(machine: machine, size: 36)
                Text(statusText).font(.system(size: 13, weight: .semibold))
                switch machine.status {
                case .preparing:
                    if let progress = machine.progress {
                        ProgressView(value: progress).frame(width: 220)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                case .starting, .stopping:
                    ProgressView().controlSize(.small)
                default:
                    Button { Task { await machine.start() } } label: {
                        Label(machine.status == .stopped ? "Start" : "Resume", systemImage: "play.fill")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!machine.config.installed)
                }
            }
        }
        .transition(.opacity)
    }
}

struct VMDisplay: NSViewRepresentable {
    let machine: Machine
    let vm: VZVirtualMachine

    func makeNSView(context: Context) -> PocketVMView {
        let view = PocketVMView()
        view.machine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true
        view.virtualMachine = vm
        machine.display = view
        return view
    }

    func updateNSView(_ view: PocketVMView, context: Context) {
        if view.virtualMachine !== vm { view.virtualMachine = vm }
        view.machine = machine
        machine.display = view
    }
}

/// The machine's screen. In guest terminals (reported by PocketVM Tools) it turns Ctrl+C into
/// copy and Ctrl+V into paste, the way Windows Terminal does; Ctrl+C twice quickly interrupts.
final class PocketVMView: VZVirtualMachineView {
    weak var machine: Machine?
    /// Set while PocketVM itself types for an agent, so its keys go through untouched.
    var bypassShortcuts = false
    private var lastCopy: TimeInterval = 0
    private var swallowKeyUp: UInt16?

    private static let cKey: UInt16 = 8, vKey: UInt16 = 9, shiftKey: UInt16 = 56
    private static let leftShiftDevice = NSEvent.ModifierFlags(rawValue: 0x02)

    override func keyDown(with event: NSEvent) {
        guard !bypassShortcuts, !event.isARepeat, machine?.terminalShortcutsActive == true,
              event.modifierFlags.intersection([.control, .shift, .option, .command]) == .control,
              event.keyCode == Self.cKey || event.keyCode == Self.vKey else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == Self.cKey && event.timestamp - lastCopy < 0.45 {
            // Second tap: the real Ctrl+C.
            lastCopy = 0
            super.keyDown(with: event)
            return
        }
        if event.keyCode == Self.cKey { lastCopy = event.timestamp }
        sendWithShift(event)
        swallowKeyUp = event.keyCode
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == swallowKeyUp {
            swallowKeyUp = nil
            return
        }
        super.keyUp(with: event)
    }

    /// Replays the key as Ctrl+Shift+<key>, the terminal's copy / paste.
    private func sendWithShift(_ event: NSEvent) {
        guard let window else { return }
        let base = event.modifierFlags
        let shifted = base.union([.shift, Self.leftShiftDevice])
        func make(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: event.timestamp,
                windowNumber: window.windowNumber, context: nil,
                characters: type == .flagsChanged ? "" : event.charactersIgnoringModifiers?.uppercased() ?? "",
                charactersIgnoringModifiers: type == .flagsChanged ? "" : event.charactersIgnoringModifiers ?? "",
                isARepeat: false, keyCode: code)
        }
        if let shiftDown = make(.flagsChanged, Self.shiftKey, shifted) { super.flagsChanged(with: shiftDown) }
        if let down = make(.keyDown, event.keyCode, shifted) { super.keyDown(with: down) }
        if let up = make(.keyUp, event.keyCode, shifted) { super.keyUp(with: up) }
        if let shiftUp = make(.flagsChanged, Self.shiftKey, base) { super.flagsChanged(with: shiftUp) }
    }
}
