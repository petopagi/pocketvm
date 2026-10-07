import Foundation

/// PocketVM Tools for Linux (GNOME): a GNOME Shell extension that can read and write the
/// Wayland clipboard, plus a small relay to the Mac over virtio-vsock. Installs into the
/// user's home folder; no sudo.
enum GuestTools {
    static let version = 2
    /// Bump when the disk format changes so cached tool images are rebuilt.
    static let imageRevision = 2
    static let volumeName = "PocketVM-Tools"
    static let extensionID = "pocketvm-clipboard@pocketvm"

    /// The tools as a small ISO, built once and cached.
    @MainActor static func linuxImage() throws -> URL {
        let image = Library.shared.root.appending(path: "GuestTools/pocketvm-tools-linux-v\(version)r\(imageRevision).iso")
        if FileManager.default.fileExists(atPath: image.path) { return image }
        return try DiskImage.iso(files.map { ($0.0, Data($0.1.utf8)) }, volume: volumeName, at: image)
    }

    /// What to run in the guest once the tools disk is mounted.
    static let installCommand = "sh /media/$USER/\(volumeName)/install.sh"

    private static let files: [(String, String)] = [
        ("install.sh", install),
        ("bridge.py", bridge),
        ("extension.js", shellExtension),
        ("metadata.json", metadata),
        ("README.txt", readme),
    ]

    private static let install = #"""
    #!/bin/sh
    # PocketVM Tools installer. Runs as you; installs into your home folder only.
    set -e
    SRC="$(cd "$(dirname "$0")" && pwd)"
    EXT="$HOME/.local/share/gnome-shell/extensions/pocketvm-clipboard@pocketvm"
    mkdir -p "$HOME/.local/share/pocketvm" "$EXT"
    cp "$SRC/bridge.py" "$HOME/.local/share/pocketvm/bridge.py"
    cp "$SRC/extension.js" "$SRC/metadata.json" "$EXT/"
    python3 - <<'PY'
    import ast, subprocess
    uuid = "pocketvm-clipboard@pocketvm"
    current = subprocess.run(["gsettings", "get", "org.gnome.shell", "enabled-extensions"],
                             capture_output=True, text=True).stdout.strip()
    enabled = [] if current.startswith("@as") or not current else ast.literal_eval(current)
    if uuid not in enabled:
        enabled.append(uuid)
    subprocess.run(["gsettings", "set", "org.gnome.shell", "enabled-extensions", str(enabled)], check=True)
    PY
    echo "PocketVM Tools installed. Log out and back in to start clipboard sharing."
    """#

    private static let bridge = #"""
    #!/usr/bin/env python3
    # PocketVM clipboard relay: passes base64 lines between GNOME Shell (stdin/stdout)
    # and the Mac (virtio-vsock, host CID 2, port 6080). Reconnects until the Mac answers.
    import os, select, socket, sys, time

    PORT = 6080

    def connect():
        while True:
            try:
                s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
                s.connect((socket.VMADDR_CID_HOST, PORT))
                return s
            except OSError:
                time.sleep(3)

    sock = connect()
    out = sys.stdout.buffer
    while True:
        ready, _, _ = select.select([0, sock], [], [])
        if 0 in ready:
            data = os.read(0, 65536)
            if not data:
                sys.exit(0)  # GNOME Shell went away
            sock.sendall(data)
        if sock in ready:
            data = sock.recv(65536)
            if not data:
                sys.exit(1)  # the Mac closed; the extension restarts us
            out.write(data)
            out.flush()
    """#

    private static let shellExtension = #"""
    // PocketVM Tools: syncs the clipboard with the Mac and tells it which app has focus,
    // through bridge.py. Lines: "c <base64 text>" (both ways), "f <window class>" (to the Mac).
    import GLib from 'gi://GLib';
    import Gio from 'gi://Gio';
    import St from 'gi://St';
    import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

    export default class PocketVMClipboard extends Extension {
        enable() {
            this._clipboard = St.Clipboard.get_default();
            this._last = null;
            this._primed = false;
            this._running = true;
            this._start();
            this._poll = GLib.timeout_add(GLib.PRIORITY_DEFAULT, 500, () => {
                this._check();
                return GLib.SOURCE_CONTINUE;
            });
            this._focus = global.display.connect('notify::focus-window', () => this._sendFocus());
        }

        disable() {
            this._running = false;
            if (this._poll) GLib.source_remove(this._poll);
            if (this._restart) GLib.source_remove(this._restart);
            if (this._focus) global.display.disconnect(this._focus);
            this._poll = this._restart = this._focus = 0;
            this._process?.force_exit();
            this._process = this._stdin = this._stdout = null;
            this._clipboard = null;
        }

        _start() {
            const bridge = GLib.build_filenamev([GLib.get_home_dir(), '.local', 'share', 'pocketvm', 'bridge.py']);
            this._process = Gio.Subprocess.new(['python3', bridge],
                Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE);
            this._stdin = this._process.get_stdin_pipe();
            this._stdout = new Gio.DataInputStream({base_stream: this._process.get_stdout_pipe()});
            this._read(this._stdout);
            this._write('v 2');
            this._sendFocus();
            this._process.wait_async(null, (process, result) => {
                try { process.wait_finish(result); } catch (e) {}
                if (!this._running) return;
                this._restart = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 3, () => {
                    this._restart = 0;
                    if (this._running) this._start();
                    return GLib.SOURCE_REMOVE;
                });
            });
        }

        _write(line) {
            if (!this._stdin) return;
            try {
                this._stdin.write_bytes(new GLib.Bytes(new TextEncoder().encode(line + '\n')), null);
            } catch (e) {}
        }

        _sendFocus() {
            const window = global.display.focus_window;
            const name = (window?.get_wm_class() || '').replace(/\s/g, '');
            this._write('f ' + name);
        }

        _read(stream) {
            stream.read_line_async(GLib.PRIORITY_DEFAULT, null, (source, result) => {
                let line = null;
                try { [line] = source.read_line_finish_utf8(result); } catch (e) { return; }
                if (line === null || !this._running) return;
                line = line.trim();
                if (line.startsWith('c ')) {
                    try {
                        const text = new TextDecoder().decode(GLib.base64_decode(line.slice(2)));
                        this._last = text;
                        this._clipboard.set_text(St.ClipboardType.CLIPBOARD, text);
                    } catch (e) {}
                }
                this._read(source);
            });
        }

        _check() {
            this._clipboard?.get_text(St.ClipboardType.CLIPBOARD, (clipboard, text) => {
                if (!this._primed) {
                    // Don't push whatever was copied before login.
                    this._primed = true;
                    this._last = text;
                    return;
                }
                if (!text || text === this._last) return;
                this._last = text;
                this._write('c ' + GLib.base64_encode(new TextEncoder().encode(text)));
            });
        }
    }
    """#

    private static let metadata = #"""
    {
      "uuid": "pocketvm-clipboard@pocketvm",
      "name": "PocketVM Tools",
      "description": "Shares the clipboard with the Mac running this virtual machine, when PocketVM allows it.",
      "shell-version": ["45", "46", "47", "48", "49", "50", "51", "52"],
      "version": 2
    }
    """#

    private static let readme = """
    PocketVM Tools for Linux (GNOME)

    Install:  sh install.sh   (as yourself, no sudo), then log out and back in.
    Removes:  rm -rf ~/.local/share/pocketvm ~/.local/share/gnome-shell/extensions/pocketvm-clipboard@pocketvm

    Clipboard text only crosses while "Share Clipboard" is on in PocketVM.
    """
}

enum DiskImage {
    /// Builds a read-only ISO 9660 + Joliet image holding `files`.
    static func iso(_ files: [(name: String, data: Data)], volume: String, at image: URL) throws -> URL {
        let staging = FileManager.default.temporaryDirectory.appending(path: "pocketvm-iso-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in files {
            try file.data.write(to: staging.appending(path: file.name))
        }
        try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: image)

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        // UDF keeps file names exactly; ISO 9660 + Joliet is the fallback for older guests.
        process.arguments = ["makehybrid", "-iso", "-joliet", "-udf", "-default-volume-name", volume, "-o", image.path, staging.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: image.path) else {
            throw PocketError("Couldn’t build the disk image.")
        }
        return image
    }
}
