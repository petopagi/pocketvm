import SwiftUI
import Virtualization

struct MachineSettingsSheet: View {
    let machine: Machine
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cpu = 4
    @State private var memory = 8
    @State private var disk = 128
    @State private var sharedFolder: String?
    @State private var installerISO: String?
    @State private var agentAccess = false
    @State private var forwards: [PortForward] = []
    @State private var network: NetworkMode = .nat
    @State private var clipboard = false
    @State private var folderReadOnly = true
    @State private var nested = false
    @State private var terminalShortcuts = true
    @State private var newHostPort = ""
    @State private var newGuestPort = ""

    private var locked: Bool { machine.isActive || machine.status == .suspended }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                MachineBadge(machine: machine, size: 20)
                Text(machine.config.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer()
            }
            .padding([.horizontal, .top], 18)
            .padding(.bottom, 4)

            Form {
                Section {
                    TextField("Name", text: $name)
                    LabeledContent("System", value: machine.config.osVersion)
                }
                Section {
                    Picker("Processors", selection: $cpu) {
                        ForEach(Set(Host.cpuChoices + [cpu]).sorted(), id: \.self) { Text("\($0) CPU").tag($0) }
                    }
                    Picker("Memory", selection: $memory) {
                        ForEach(Set(Host.memoryChoices + [memory]).sorted(), id: \.self) { Text("\($0) GB").tag($0) }
                    }
                    Picker("Disk", selection: $disk) {
                        ForEach(Set(Host.diskChoices.filter { $0 >= machine.config.diskGB } + [machine.config.diskGB]).sorted(), id: \.self) {
                            Text(Bytes.disk($0)).tag($0)
                        }
                    }
                } header: {
                    Text("Hardware")
                } footer: {
                    if locked {
                        Text("Shut the machine down to change its hardware.").foregroundStyle(.secondary)
                    } else {
                        Text("Disks can grow but not shrink. \(Bytes.string(machine.allocatedBytes)) is in use.").foregroundStyle(.secondary)
                    }
                }
                .disabled(locked)

                Section {
                    Picker("Network", selection: $network) {
                        ForEach(NetworkMode.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(locked)
                    if machine.supportsClipboardSharing {
                        // Switchable while running.
                        Toggle("Share clipboard", isOn: $clipboard)
                    }
                    if machine.config.os == .linux, VZGenericPlatformConfiguration.isNestedVirtualizationSupported {
                        Toggle("Nested virtualization", isOn: $nested)
                            .disabled(locked)
                    }
                } header: {
                    Text("Isolation")
                } footer: {
                    Text(network == .nat
                         ? "The machine runs on Apple’s hypervisor in its own sandboxed process; these settings are its only ways out. With Internet on, it can also reach services on this Mac and devices on your network."
                         : "The machine runs on Apple’s hypervisor in its own sandboxed process, with no network at all.")
                        .foregroundStyle(.secondary)
                }

                if machine.config.os == .linux {
                    Section {
                        Toggle("Ctrl+C copies and Ctrl+V pastes in terminals", isOn: $terminalShortcuts)
                    } header: {
                        Text("Keyboard")
                    } footer: {
                        Text("Press Ctrl+C twice quickly to interrupt. Other apps get your keys unchanged. Needs PocketVM Tools.")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Sharing") {
                    pathRow("Shared folder", path: $sharedFolder, directories: true)
                    if sharedFolder != nil {
                        Toggle("Read-only", isOn: $folderReadOnly)
                    }
                    if machine.config.os != .macOS {
                        pathRow("Installer ISO", path: $installerISO, directories: false)
                    }
                }
                .disabled(locked)

                Section {
                    ForEach(forwards) { forward in
                        HStack {
                            Text(verbatim: "localhost:\(forward.hostPort)")
                                .monospacedDigit()
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("to")
                            Text(verbatim: "port \(forward.guestPort)")
                                .monospacedDigit()
                            Spacer()
                            Button("Remove") { forwards.removeAll { $0 == forward } }
                        }
                    }
                    HStack {
                        TextField("Mac port", text: $newHostPort, prompt: Text("8080"))
                            .labelsHidden()
                            .frame(width: 70)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
                        TextField("Machine port", text: $newGuestPort, prompt: Text("80"))
                            .labelsHidden()
                            .frame(width: 70)
                        Spacer()
                        Button("Add", action: addForward)
                            .disabled(UInt16(newHostPort).map { $0 < 1024 } ?? true || UInt16(newGuestPort) == nil)
                    }
                } header: {
                    Text("Port Forwarding")
                } footer: {
                    Text("Reach a server in the machine at localhost on your Mac while it runs.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Let AI agents use this machine", isOn: $agentAccess)
                } footer: {
                    Text("Agents connected over MCP can see its screen, use its keyboard and mouse, and run commands over SSH.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
            }
            .padding([.horizontal, .bottom], 18)
            .padding(.top, 4)
        }
        .frame(width: 440)
        .onAppear {
            let c = machine.config
            name = c.name
            cpu = c.cpuCount
            memory = c.memoryGB
            disk = c.diskGB
            sharedFolder = c.sharedFolder
            installerISO = c.installerISO
            agentAccess = c.agentAccess
            forwards = c.portForwards
            network = c.network
            clipboard = c.clipboardSharing
            folderReadOnly = c.sharedFolderReadOnly
            nested = c.nestedVirtualization
            terminalShortcuts = c.terminalShortcuts
        }
    }

    private func pathRow(_ label: String, path: Binding<String?>, directories: Bool) -> some View {
        LabeledContent(label) {
            HStack(spacing: 8) {
                Text(path.wrappedValue.map { URL(filePath: $0).lastPathComponent } ?? "None")
                    .foregroundStyle(path.wrappedValue == nil ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if path.wrappedValue != nil {
                    Button("Remove") { path.wrappedValue = nil }
                }
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directories
                    panel.canChooseFiles = !directories
                    if panel.runModal() == .OK, let url = panel.url { path.wrappedValue = url.path }
                }
            }
        }
    }

    private func addForward() {
        guard let host = UInt16(newHostPort), let guest = UInt16(newGuestPort), host >= 1024 else { return }
        forwards.removeAll { $0.hostPort == host }
        forwards.append(PortForward(hostPort: host, guestPort: guest))
        newHostPort = ""
        newGuestPort = ""
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { machine.config.name = trimmed }
        machine.config.agentAccess = agentAccess
        machine.config.portForwards = forwards
        machine.config.terminalShortcuts = terminalShortcuts
        if clipboard != machine.config.clipboardSharing { machine.setClipboardSharing(clipboard) }
        if !locked {
            machine.config.cpuCount = cpu
            machine.config.memoryGB = memory
            machine.config.sharedFolder = sharedFolder
            machine.config.installerISO = installerISO
            machine.config.network = network
            machine.config.sharedFolderReadOnly = folderReadOnly
            machine.config.nestedVirtualization = nested
            do {
                try machine.growDisk(to: disk)
            } catch {
                library.report(error, title: "Couldn’t resize the disk")
            }
        }
        if !machine.isDemo { try? machine.save() }
        PortForwarder.shared.sync()
        machine.refreshDiskUsage()
        dismiss()
    }
}
