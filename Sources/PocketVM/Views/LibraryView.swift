import SwiftUI

struct LibraryView: View {
    @Environment(Library.self) private var library
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var library = library
        Group {
            if library.machines.isEmpty {
                EmptyLibrary()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(library.sorted) { machine in
                            MachineRow(machine: machine, selected: library.selection == machine.id) {
                                open(machine)
                            }
                            .onTapGesture(count: 2) { open(machine) }
                            .simultaneousGesture(TapGesture().onEnded {
                                library.selection = machine.id
                                focused = true
                            })
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 2)
                    .padding(.bottom, 10)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: library.sorted.map(\.id))
                }
                .scrollIndicators(.never)
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { moveSelection(-1) }
        .onKeyPress(.downArrow) { moveSelection(1) }
        .onKeyPress(.return) {
            guard let id = library.selection, let machine = library.machine(id) else { return .ignored }
            open(machine)
            return .handled
        }
        .onAppear {
            focused = true
            library.openWindow = { openWindow(value: $0) }
            library.openLibraryWindow = { openWindow(id: "library") }
        }
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItemGroup {
                Menu {
                    Picker("Sort By", selection: $library.sortOrder) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Connect AI Agents…") { library.showingAgents = true }
                    Button("Show Machines in Finder") {
                        NSWorkspace.shared.open(library.machinesDir)
                    }
                    .disabled(library.isDemo)
                } label: {
                    Label("View Options", systemImage: "slider.horizontal.3")
                }
                .menuIndicator(.hidden)

                Button {
                    library.showingNewMachine = true
                } label: {
                    Label("New Virtual Machine", systemImage: "plus")
                }
            }
        }
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .modifier(LibraryDialogs())
        .onChange(of: library.pendingOpen) { _, id in
            guard let id else { return }
            library.pendingOpen = nil
            openWindow(value: id)
        }
    }

    private func open(_ machine: Machine) {
        library.selection = machine.id
        guard machine.config.installed else { return }
        if !machine.isDemo { openWindow(value: machine.id) }
        Task { await machine.start() }
    }

    private func moveSelection(_ delta: Int) -> KeyPress.Result {
        let list = library.sorted
        guard !list.isEmpty else { return .ignored }
        let index = list.firstIndex { $0.id == library.selection } ?? (delta > 0 ? -1 : list.count)
        library.selection = list[(index + delta).clamped(0, list.count - 1)].id
        return .handled
    }
}

private struct EmptyLibrary: View {
    @Environment(Library.self) private var library

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 16) {
                OSGlyph(os: .macOS, distro: nil, size: 24)
                OSGlyph(os: .windows, distro: nil, size: 24)
                OSGlyph(os: .linux, distro: "ubuntu", size: 24)
            }
            .accessibilityHidden(true)
            .padding(.bottom, 4)
            Text("No virtual machines")
                .font(.system(size: 13, weight: .semibold))
            Text("macOS, Windows and Linux, side by side on your Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("New Virtual Machine") { library.showingNewMachine = true }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Sheets and confirmations owned by the library window.
private struct LibraryDialogs: ViewModifier {
    @Environment(Library.self) private var library

    func body(content: Content) -> some View {
        @Bindable var library = library
        content
            .sheet(isPresented: $library.showingNewMachine) {
                NewMachineSheet().environment(library)
            }
            .sheet(isPresented: $library.showingAgents) {
                AgentsSheet()
            }
            .sheet(item: $library.editing) { machine in
                MachineSettingsSheet(machine: machine).environment(library)
            }
            .alert(
                library.confirmingTrash.map { "Move “\($0.config.name)” to the Trash?" } ?? "",
                isPresented: Binding(get: { library.confirmingTrash != nil }, set: { if !$0 { library.confirmingTrash = nil } }),
                presenting: library.confirmingTrash
            ) { machine in
                Button("Move to Trash", role: .destructive) {
                    Task { await library.trash(machine) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { machine in
                Text(machine.isActive
                     ? "It’s running and will be turned off. You can restore it from the Trash."
                     : "You can restore it from the Trash until you empty it.")
            }
            .alert(
                library.confirmingRestore.map { "Restore “\($0.machine.config.name)” to “\($0.snapshot.name)”?" } ?? "",
                isPresented: Binding(get: { library.confirmingRestore != nil }, set: { if !$0 { library.confirmingRestore = nil } }),
                presenting: library.confirmingRestore
            ) { request in
                Button("Restore", role: .destructive) {
                    Task {
                        do { try await request.machine.restoreSnapshot(request.snapshot) } catch { library.report(error, title: "Couldn’t restore the snapshot") }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text(request.machine.isActive
                     ? "The machine will be turned off. Everything since the snapshot is lost."
                     : "Everything since the snapshot is lost.")
            }
            .alert(
                library.alert?.title ?? "",
                isPresented: Binding(get: { library.alert != nil }, set: { if !$0 { library.alert = nil } }),
                presenting: library.alert
            ) { _ in
                Button("OK") {}
            } message: { info in
                Text(info.message)
            }
    }
}
