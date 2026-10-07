import AppKit
import Virtualization

/// Drives a guest through its own virtual keyboard and pointer, by handing synthesized
/// events straight to the machine's `VZVirtualMachineView`. Nothing reaches the host.
@MainActor
enum GuestInput {
    // MARK: Pointer

    enum Button: String { case left, right }

    static func click(_ view: VZVirtualMachineView, x: Double, y: Double, button: Button, count: Int) async throws {
        try move(view, x: x, y: y)
        for n in 1...max(1, count) {
            try mouse(view, button == .left ? .leftMouseDown : .rightMouseDown, x: x, y: y, clicks: n)
            try await pause(0.03)
            try mouse(view, button == .left ? .leftMouseUp : .rightMouseUp, x: x, y: y, clicks: n)
            try await pause(0.06)
        }
    }

    static func move(_ view: VZVirtualMachineView, x: Double, y: Double) throws {
        try mouse(view, .mouseMoved, x: x, y: y, clicks: 0)
    }

    static func drag(_ view: VZVirtualMachineView, from: CGPoint, to: CGPoint) async throws {
        try move(view, x: from.x, y: from.y)
        try mouse(view, .leftMouseDown, x: from.x, y: from.y, clicks: 1)
        let steps = 12
        for step in 1...steps {
            let t = Double(step) / Double(steps)
            try await pause(0.016)
            try mouse(view, .leftMouseDragged, x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t, clicks: 1)
        }
        try mouse(view, .leftMouseUp, x: to.x, y: to.y, clicks: 1)
    }

    static func scroll(_ view: VZVirtualMachineView, x: Double, y: Double, dx: Int32, dy: Int32) throws {
        try move(view, x: x, y: y)
        guard let window = view.window,
              let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else {
            throw PocketError("The machine’s window isn’t open.")
        }
        let local = windowPoint(view, x: x, y: y)
        cg.location = CGPoint(x: window.frame.minX + local.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - (window.frame.minY + local.y))
        guard let event = NSEvent(cgEvent: cg) else { return }
        view.scrollWheel(with: event)
    }

    private static func mouse(_ view: VZVirtualMachineView, _ type: NSEvent.EventType, x: Double, y: Double, clicks: Int) throws {
        guard let window = view.window else { throw PocketError("The machine’s window isn’t open.") }
        guard let event = NSEvent.mouseEvent(
            with: type, location: windowPoint(view, x: x, y: y), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks,
            pressure: type == .leftMouseDown || type == .rightMouseDown || type == .leftMouseDragged ? 1 : 0)
        else { return }
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseUp: view.mouseUp(with: event)
        case .rightMouseDown: view.rightMouseDown(with: event)
        case .rightMouseUp: view.rightMouseUp(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseMoved(with: event)
        }
    }

    /// Agents use top-left-origin points of the screen they were shown.
    private static func windowPoint(_ view: VZVirtualMachineView, x: Double, y: Double) -> CGPoint {
        let px = x.clamped(0, view.bounds.width - 1)
        let py = y.clamped(0, view.bounds.height - 1)
        return view.convert(CGPoint(x: px, y: view.isFlipped ? py : view.bounds.height - py), to: nil)
    }

    // MARK: Keyboard

    /// Types text on a US layout. Returns the characters that have no key.
    static func type(_ view: VZVirtualMachineView, text: String) async throws -> String {
        var skipped = ""
        for character in text {
            guard let (code, shift) = Keys.forCharacter(character) else {
                skipped.append(character)
                continue
            }
            try await press(view, code: code, modifiers: shift ? [.shift] : [], characters: String(character))
            // Faster than this and the guest's USB keyboard drops keys under load.
            try await pause(0.025)
        }
        return skipped
    }

    /// `combo` is like "cmd+shift+4", "return", "ctrl+alt+delete"; several combos may be space-separated.
    static func press(_ view: VZVirtualMachineView, combos: String) async throws {
        for combo in combos.split(separator: " ") where !combo.isEmpty {
            var modifiers: NSEvent.ModifierFlags = []
            var key: (UInt16, String)?
            for part in combo.lowercased().split(separator: "+") {
                if let modifier = Keys.modifiers[String(part)] {
                    modifiers.insert(modifier)
                } else if let named = Keys.named[String(part)] {
                    key = (named, "")
                } else if part.count == 1, let (code, _) = Keys.forCharacter(part.first!) {
                    key = (code, String(part))
                } else {
                    throw PocketError("Unknown key “\(part)”. Use names like return, tab, escape, space, delete, up, f5, or single characters.")
                }
            }
            if let key {
                try await press(view, code: key.0, modifiers: modifiers, characters: key.1)
            } else if !modifiers.isEmpty {
                // A lone modifier tap, e.g. "cmd".
                try await press(view, code: nil, modifiers: modifiers, characters: "")
            }
            try await pause(0.05)
        }
    }

    private static func press(_ view: VZVirtualMachineView, code: UInt16?, modifiers: NSEvent.ModifierFlags, characters: String) async throws {
        guard let window = view.window else { throw PocketError("The machine’s window isn’t open.") }
        // Agents mean exactly the keys they ask for.
        let pocketView = view as? PocketVMView
        pocketView?.bypassShortcuts = true
        defer { pocketView?.bypassShortcuts = false }
        // Each modifier carries its device-dependent "left key" bit too (NX_DEVICEL*KEYMASK);
        // the guest keyboard reads those to know which physical key is down.
        let order: [(NSEvent.ModifierFlags, UInt, UInt16)] = [
            (.control, 0x01, 59), (.option, 0x20, 58), (.shift, 0x02, 56), (.command, 0x08, 55),
        ]
        var held: NSEvent.ModifierFlags = []
        for (flag, device, keyCode) in order where modifiers.contains(flag) {
            held.insert(flag)
            held.insert(NSEvent.ModifierFlags(rawValue: device))
            view.flagsChanged(with: keyEvent(.flagsChanged, keyCode, held, "", window))
        }
        if let code {
            view.keyDown(with: keyEvent(.keyDown, code, held, characters, window))
            try await pause(0.03)
            view.keyUp(with: keyEvent(.keyUp, code, held, characters, window))
        }
        for (flag, device, keyCode) in order.reversed() where modifiers.contains(flag) {
            held.remove(flag)
            held.remove(NSEvent.ModifierFlags(rawValue: device))
            view.flagsChanged(with: keyEvent(.flagsChanged, keyCode, held, "", window))
        }
    }

    private static func keyEvent(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String, _ window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false, keyCode: code)!
    }

    private static func pause(_ seconds: Double) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

/// US ANSI virtual key codes.
enum Keys {
    static let modifiers: [String: NSEvent.ModifierFlags] = [
        "cmd": .command, "command": .command, "meta": .command, "super": .command, "win": .command,
        "shift": .shift,
        "alt": .option, "option": .option, "opt": .option,
        "ctrl": .control, "control": .control,
    ]

    static let named: [String: UInt16] = [
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117, "home": 115, "end": 119,
        "pageup": 116, "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "capslock": 57,
    ]

    private static let plain: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
        "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
        "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50, " ": 49, "\n": 36, "\r": 36, "\t": 48,
    ]

    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
        "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    static func forCharacter(_ character: Character) -> (UInt16, Bool)? {
        if let code = plain[character] { return (code, false) }
        if let base = shifted[character], let code = plain[base] { return (code, true) }
        if character.isUppercase, let lower = character.lowercased().first, let code = plain[lower] { return (code, true) }
        return nil
    }
}
