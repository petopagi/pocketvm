import SwiftUI

@main
struct PocketVMApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = Library.shared

    var body: some Scene {
        Window("PocketVM", id: "library") {
            LibraryView()
                .environment(library)
                .frame(minWidth: 460, minHeight: 260)
                .background(FrostedGlass().ignoresSafeArea())
                .preferredColorScheme(CommandLine.arguments.contains("--light") ? .light : nil)
        }
        .defaultSize(width: 580, height: 500)
        .windowBackgroundDragBehavior(.enabled)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Machine…") { library.showingNewMachine = true }
                    .keyboardShortcut("n")
                Button("Connect AI Agents…") { library.showingAgents = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Machine", for: UUID.self) { $id in
            if let id, let machine = library.machine(id) {
                MachineWindow(machine: machine)
                    .environment(library)
            }
        }
        .defaultSize(width: 1440, height: 928)
        .restorationBehavior(.disabled)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MCPServer.shared.start()
        StatsSampler.shared.start()
        PortForwarder.shared.sync()

        // Developer aid for README screenshots: `--capture-library <file.png>` saves the main
        // window (title bar included) and quits. Pair with --demo for the sample library.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--capture-library"), index + 1 < arguments.count {
            let path = arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                if let window = NSApp.windows.first(where: { $0.title == "PocketVM" && $0.isVisible }),
                   let frame = window.contentView?.superview {
                    // Always 2× so images are sharp on Retina displays.
                    let size = frame.bounds.size
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = size
                    frame.cacheDisplay(in: frame.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: path))
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// Dock menu: the main window, then every machine with its state.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let main = NSMenuItem(title: "PocketVM", action: #selector(showLibrary), keyEquivalent: "")
        main.target = self
        main.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)
        menu.addItem(main)
        let library = Library.shared
        if !library.machines.isEmpty { menu.addItem(.separator()) }
        for machine in library.sorted where !machine.isDemo {
            let item = NSMenuItem(title: machine.config.name, action: #selector(showMachine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = machine.id
            item.subtitle = AgentTools.stateName(machine).capitalized(with: nil)
            item.image = NSImage(systemSymbolName: machine.isActive ? "play.circle.fill" : "circle", accessibilityDescription: nil)
            item.isEnabled = machine.config.installed && machine.status != .preparing
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let new = NSMenuItem(title: "New Virtual Machine…", action: #selector(newMachine), keyEquivalent: "")
        new.target = self
        menu.addItem(new)
        return menu
    }

    /// Clicking the Dock icon with no windows open brings the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }

    @MainActor @objc private func showLibrary() {
        NSApp.activate()
        if let open = Library.shared.openLibraryWindow {
            open()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.contains("library") == true }?.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor @objc private func showMachine(_ item: NSMenuItem) {
        guard let id = item.representedObject as? UUID else { return }
        NSApp.activate()
        Library.shared.open(id)
    }

    @MainActor @objc private func newMachine() {
        showLibrary()
        Library.shared.showingNewMachine = true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let active = Library.shared.machines.filter { $0.isActive && !$0.isDemo }
            guard !active.isEmpty else { return .terminateNow }

            let alert = NSAlert()
            alert.messageText = active.count == 1
                ? "“\(active[0].config.name)” is still running."
                : "\(active.count) virtual machines are still running."
            alert.informativeText = "Suspend saves each machine so it picks up right where it left off. Machines that can’t be suspended are turned off."
            alert.addButton(withTitle: "Suspend and Quit")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Turn Off and Quit")

            switch alert.runModal() {
            case .alertFirstButtonReturn:
                Task { @MainActor in
                    for machine in active where !(await machine.suspend(reportErrors: false)) {
                        await machine.forceStop()
                    }
                    sender.reply(toApplicationShouldTerminate: true)
                }
                return .terminateLater
            case .alertSecondButtonReturn:
                return .terminateCancel
            default:
                return .terminateNow
            }
        }
    }
}
