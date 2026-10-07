import Foundation
import Virtualization

/// Installs PocketVM Tools in a running GNOME guest by driving its own keyboard: attach the
/// tools disk, open a terminal, run the installer. It refuses to type unless a fresh terminal
/// is visibly open, so keystrokes never land in a lock screen or another app.
@MainActor
enum ToolsInstaller {
    /// Printed by the installer command; the typed command itself contains `$((40+2))`, not 42.
    private static let doneMarker = "POCKETVM-TOOLS-42"
    /// Leading space keeps it out of shell history. Waits for the disk to mount, installs,
    /// shows the marker for a moment, then closes its own terminal.
    private static let command = " for i in $(seq 30); do [ -f /media/$USER/\(GuestTools.volumeName)/install.sh ] && break; sleep 1; done; sh /media/$USER/\(GuestTools.volumeName)/install.sh && echo POCKETVM-TOOLS-$((40+2)) && sleep 2 && exit\n"

    static func install(_ machine: Machine, step: (String) -> Void) async throws {
        guard let view = machine.display, view.window != nil else {
            throw PocketError("Open “\(machine.config.name)” to install the tools.")
        }
        step("Attaching the tools disk…")
        try await machine.attachGuestTools()

        step("Opening a terminal…")
        let before = try await promptCount(view)
        // Ubuntu binds Ctrl+Alt+T; vanilla GNOME (Arch, Fedora) doesn't, so fall back to the Run dialog.
        try await GuestInput.press(view, combos: "ctrl+alt+t")
        var opened = try await waitForPrompt(view, above: before, seconds: 4)
        if !opened {
            try await GuestInput.press(view, combos: "alt+f2")
            try await Task.sleep(for: .milliseconds(800))
            _ = try await GuestInput.type(view, text: "sh -c \"kgx || ptyxis || gnome-terminal || xterm\"\n")
            opened = try await waitForPrompt(view, above: before, seconds: 8)
        }
        guard opened else {
            throw PocketError("Couldn’t open a terminal. If the machine is locked, unlock it and try again.")
        }
        try await Task.sleep(for: .milliseconds(400))

        step("Installing…")
        _ = try await GuestInput.type(view, text: command)
        for _ in 0..<120 {
            try await Task.sleep(for: .milliseconds(500))
            let hits = try await ScreenGrab.text(in: try await ScreenGrab.frame(of: view))
            if !ScreenGrab.find(doneMarker, in: hits, wholeWords: true).isEmpty { return }
        }
        throw PocketError("The installer didn’t finish. Check the terminal in the machine.")
    }

    /// Signs the guest user out so GNOME loads the extension.
    static func logOut(_ machine: Machine) async throws {
        guard let view = machine.display, view.window != nil else { return }
        _ = try await GuestInput.type(view, text: " gnome-session-quit --logout --no-prompt\n")
    }

    private static func waitForPrompt(_ view: VZVirtualMachineView, above count: Int, seconds: Int) async throws -> Bool {
        for _ in 0..<(seconds * 2) {
            try await Task.sleep(for: .milliseconds(500))
            if try await promptCount(view) > count { return true }
        }
        return false
    }

    /// Shell prompts on screen ("user@host:~$", "root@host:~#").
    private static func promptCount(_ view: VZVirtualMachineView) async throws -> Int {
        let hits = try await ScreenGrab.text(in: try await ScreenGrab.frame(of: view))
        return hits.filter { $0.text.contains(":~") || $0.text.contains("]$") || $0.text.contains("]#") || $0.text.hasSuffix("$") || $0.text.hasSuffix("#") }.count
    }

    static var manualCommand: String { GuestTools.installCommand }

    /// GDM's sign-in screen, or a lock screen asking for a password.
    static func atLoginScreen(_ machine: Machine) async -> Bool {
        guard let view = machine.display, view.window != nil,
              let frame = try? await ScreenGrab.frame(of: view),
              let hits = try? await ScreenGrab.text(in: frame) else { return true }
        let text = hits.map(\.text).joined(separator: "\n").lowercased()
        return text.contains("not listed") || text.contains("password") || text.contains("unlock") || text.contains("login:")
    }
}
