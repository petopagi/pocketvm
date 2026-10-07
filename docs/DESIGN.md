# Design notes

## Layout

| Folder | What's there |
| --- | --- |
| `Sources/PocketVM/Model` | `VMConfig` (persisted JSON), `Machine` (a live VM and its lifecycle), `Library` (all machines and UI state) |
| `Sources/PocketVM/Engine` | `ConfigBuilder` (Virtualization configuration per OS), `Provisioner` (downloads with SHA-256 checks, macOS install, `MachineRecipe`), `Snapshots`, `HostStats`, `PortForwarder`, `ClipboardBridge`, `GuestTools`, `ToolsInstaller` |
| `Sources/PocketVM/Agent` | `MCPServer` (HTTP + JSON-RPC on 127.0.0.1:7979), `AgentTools` (the tool registry), `GuestInput` (synthesized keyboard and mouse events), `ScreenGrab` (capture + Vision OCR), `GuestNetwork` (guest IP, SSH) |
| `Sources/PocketVM/Views` | Library window, rows, sheets, machine window |

## Interface

- System font only. Names 13 pt semibold, details 11 pt with `.monospacedDigit()`. Never change letter spacing.
- Icon-only buttons get an accessibility label and a tooltip. Status is spoken, not only colored.
- Motion: opacity and transform only, ease-out, 200 ms or less, and none with Reduce Motion.
- No gradients, glows or decorative shadows in the interface. One accent color (the system's).
- The library window background is plain behind-window frosting (`FrostedGlass`).
- Destructive actions confirm first. Empty states offer exactly one action.

## Isolation

Every bridge between a guest and the Mac starts closed: clipboard off, shared folders read-only, nested virtualization off. Anything PocketVM listens on binds to `127.0.0.1`. Keep it that way when adding features.

## Concurrency

Never block Swift's cooperative thread pool. Vision OCR, process waits and file hashing run on dispatch queues and resume through continuations; concurrent blocking Vision requests can otherwise starve every task in the app.

## Guest input

Synthesized events go straight to the machine's `VZVirtualMachineView`. Modifier events must carry the device-dependent left-key bits (`NX_DEVICEL*KEYMASK`), or the guest ignores Shift, Control and friends. Typing faster than about 30 ms per key can drop keys in busy guests; deliver long text with `send_files`.
