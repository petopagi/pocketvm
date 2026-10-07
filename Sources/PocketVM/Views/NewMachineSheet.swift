import SwiftUI
import UniformTypeIdentifiers

struct NewMachineSheet: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var os: GuestOS?
    @State private var name = ""
    @State private var cpu = min(4, Host.cpuCount)
    @State private var memory = min(8, Host.memoryChoices.last ?? 8)
    @State private var disk = 256
    @State private var macLatest = true
    @State private var linuxPreset: LinuxPreset? = LinuxPreset.all.first
    @State private var file: URL?
    @State private var agentAccess = false

    var body: some View {
        VStack(spacing: 0) {
            if let os {
                configure(os)
            } else {
                chooser
            }
        }
        .frame(width: 460)
        .animation(.easeOut(duration: 0.18), value: os)
    }

    // MARK: Step 1

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Virtual Machine").font(.system(size: 15, weight: .semibold))
                Text("Pick a system. PocketVM downloads it and sets it up for you.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                SystemTile(os: .macOS, distro: nil, title: "macOS", detail: "Straight from Apple") { pick(.macOS) }
                SystemTile(os: .windows, distro: nil, title: "Windows 11", detail: "From your ARM64 ISO") { pick(.windows) }
                SystemTile(os: .linux, distro: "ubuntu", title: "Linux", detail: "Ubuntu or Fedora") { pick(.linux) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
    }

    private func pick(_ os: GuestOS) {
        self.os = os
        file = nil
        disk = os == .linux ? 128 : 256
    }

    // MARK: Step 2

    private func configure(_ os: GuestOS) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                OSGlyph(os: os, distro: os == .linux ? (linuxPreset?.distro ?? "ubuntu") : nil, size: 20)
                Text(os.title).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 4)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text(defaultName(os)))
                }
                Section {
                    switch os {
                    case .macOS:
                        Picker("Install", selection: $macLatest) {
                            Text("Newest macOS from Apple").tag(true)
                            Text("An IPSW file").tag(false)
                        }
                        if !macLatest { fileRow("Restore image", types: [UTType(filenameExtension: "ipsw") ?? .data]) }
                    case .linux:
                        Picker("Distribution", selection: $linuxPreset) {
                            ForEach(LinuxPreset.all) { Text($0.title).tag(Optional($0)) }
                            Divider()
                            Text("An ISO file").tag(LinuxPreset?.none)
                        }
                        if linuxPreset == nil { fileRow("Installer", types: [UTType(filenameExtension: "iso") ?? .diskImage]) }
                    case .windows:
                        fileRow("Installer", types: [UTType(filenameExtension: "iso") ?? .diskImage])
                    }
                } header: {
                    Text("System")
                } footer: {
                    footer(os)
                }
                Section("Hardware") {
                    Picker("Processors", selection: $cpu) {
                        ForEach(Host.cpuChoices, id: \.self) { Text("\($0) CPU").tag($0) }
                    }
                    Picker("Memory", selection: $memory) {
                        ForEach(Host.memoryChoices, id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    Picker("Disk", selection: $disk) {
                        ForEach(Host.diskChoices, id: \.self) { Text(Bytes.disk($0)).tag($0) }
                    }
                }
                Section {
                    Toggle("Let AI agents use this machine", isOn: $agentAccess)
                } footer: {
                    Text("Agents connected over MCP can see its screen and use its keyboard and mouse. Your Mac stays untouched.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Back") { self.os = nil }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create(os) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(needsFile(os) && file == nil)
            }
            .padding([.horizontal, .bottom], 18)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func footer(_ os: GuestOS) -> some View {
        switch os {
        case .macOS where macLatest:
            Text("About 18 GB, downloaded once and kept for your next Mac VM.").foregroundStyle(.secondary)
        case .windows:
            Text("Experimental: Windows on Apple’s Virtualization framework has no GPU or network drivers until you install the virtio drivers.")
                .foregroundStyle(.secondary)
        case .linux where linuxPreset != nil:
            Text("Downloaded once and kept for your next Linux VM.").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private func fileRow(_ label: String, types: [UTType]) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(file?.lastPathComponent ?? "None")
                    .foregroundStyle(file == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = types
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK { file = panel.url }
                }
            }
        }
    }

    private func needsFile(_ os: GuestOS) -> Bool {
        os == .macOS ? !macLatest : MachineRecipe(os: os, linuxPreset: linuxPreset).needsFile
    }

    private func defaultName(_ os: GuestOS) -> String {
        MachineRecipe(os: os, linuxPreset: os == .linux ? linuxPreset : nil, file: file).defaultName
    }

    private func create(_ os: GuestOS) {
        let recipe = MachineRecipe(
            os: os, name: name, linuxPreset: os == .linux ? linuxPreset : nil,
            file: os == .macOS && macLatest ? nil : file,
            cpuCount: cpu, memoryGB: memory, diskGB: disk, agentAccess: agentAccess)
        do {
            let (config, source) = try recipe.make()
            library.create(config, source: source)
            dismiss()
        } catch {
            library.report(error, title: "Couldn’t create the machine")
        }
    }
}

private struct SystemTile: View {
    let os: GuestOS
    let distro: String?
    let title: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                OSGlyph(os: os, distro: distro, size: 28)
                    .padding(.top, 2)
                VStack(spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Text(detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.primary.opacity(hovering ? 0.08 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.primary.opacity(0.08))
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("\(title), \(detail)")
    }
}
