import SwiftUI

struct MachineRow: View {
    let machine: Machine
    let selected: Bool
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            MachineBadge(machine: machine, size: 22)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(machine.config.name.isEmpty ? machine.config.os.title : machine.config.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                subtitle
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 8)

            primaryControl
                .frame(width: 26, height: 26)
                .transition(.opacity)

            Menu {
                MachineActions(machine: machine, open: open)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
            .accessibilityLabel("More actions for \(machine.config.name)")
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .contentShape(.rect)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.primary.opacity(selected ? 0.08 : hovering ? 0.04 : 0))
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: machine.status)
        .contextMenu {
            MachineActions(machine: machine, open: open)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var subtitle: some View {
        if machine.status == .preparing {
            Text(machine.activity ?? "Getting ready…")
        } else if !machine.config.installed {
            Text("Setup didn’t finish. Move it to the Trash and try again.")
        } else {
            Text(machine.specLine)
        }
    }

    @ViewBuilder
    private var primaryControl: some View {
        switch machine.status {
        case .preparing:
            if let progress = machine.progress {
                ProgressRing(progress: progress)
            } else {
                ProgressView().controlSize(.mini)
            }
        case .starting, .stopping:
            ProgressView().controlSize(.mini)
        case .running:
            RowButton(symbol: "pause.circle", label: "Pause") {
                Task { await machine.pause() }
            }
        case .paused, .suspended, .stopped:
            RowButton(symbol: "play", label: machine.status == .stopped ? "Start" : "Resume", action: open)
                .disabled(!machine.config.installed)
        }
    }
}

private struct RowButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

struct ProgressRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.12), lineWidth: 2)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Palette.preparing, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 15, height: 15)
        .help("\(Int(progress * 100))%")
        .accessibilityElement()
        .accessibilityLabel("Setting up")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

/// Shared by the ••• menu and the context menu.
struct MachineActions: View {
    let machine: Machine
    let open: () -> Void
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch machine.status {
        case .preparing:
            Button("Cancel Setup") { Task { await library.trash(machine) } }
        case .running:
            Button("Show Window") { openWindow(value: machine.id) }
            Divider()
            Button("Pause") { Task { await machine.pause() } }
            Button("Suspend") { Task { await machine.suspend() } }
            Button("Shut Down") { machine.shutDown() }
            Button("Force Stop") { Task { await machine.forceStop() } }
        case .paused:
            Button("Resume", action: open)
            Button("Suspend") { Task { await machine.suspend() } }
            Button("Force Stop") { Task { await machine.forceStop() } }
        case .starting, .stopping:
            Button("Show Window") { openWindow(value: machine.id) }
            Button("Force Stop") { Task { await machine.forceStop() } }
        case .stopped, .suspended:
            Button(machine.status == .suspended ? "Resume" : "Start", action: open)
                .disabled(!machine.config.installed)
        }

        Divider()

        if machine.config.installed && !machine.isDemo {
            SnapshotsMenu(machine: machine)
        }
        if machine.config.os == .linux && machine.status == .running && (machine.config.guestToolsVersion ?? 0) < GuestTools.version {
            Button("Install PocketVM Tools…") {
                openWindow(value: machine.id)
                machine.toolsCardVisible = true
            }
        }
        Button("Settings…") { library.editing = machine }
            .disabled(machine.status == .preparing)
        if machine.config.installerISO != nil {
            Button("Eject Installer") {
                machine.config.installerISO = nil
                try? machine.save()
            }
            .disabled(machine.isActive)
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([machine.bundle])
        }
        .disabled(machine.isDemo)
        Button("Duplicate") { library.duplicate(machine) }
            .disabled(machine.isActive || machine.status == .preparing || !machine.config.installed || machine.isDemo)

        Divider()

        Button("Move to Trash…", role: .destructive) { library.confirmingTrash = machine }
    }
}

private struct SnapshotsMenu: View {
    let machine: Machine
    @Environment(Library.self) private var library

    var body: some View {
        let _ = machine.snapshotRevision
        let snapshots = machine.snapshots
        Menu("Snapshots") {
            Button("Take Snapshot") {
                Task {
                    do {
                        try await machine.takeSnapshot(name: Date().formatted(date: .abbreviated, time: .shortened))
                    } catch {
                        library.report(error, title: "Couldn’t take a snapshot")
                    }
                }
            }
            .disabled(machine.status == .starting || machine.status == .stopping)
            if !snapshots.isEmpty {
                Divider()
                ForEach(snapshots.reversed()) { snapshot in
                    Menu(snapshot.name) {
                        Button("Restore…") { library.confirmingRestore = RestoreRequest(machine: machine, snapshot: snapshot) }
                        Button("Delete", role: .destructive) {
                            do { try machine.deleteSnapshot(snapshot) } catch { library.report(error, title: "Couldn’t delete the snapshot") }
                        }
                    }
                }
            }
        }
    }
}
