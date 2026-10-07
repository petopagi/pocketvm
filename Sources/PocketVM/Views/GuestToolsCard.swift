import SwiftUI

/// A small card in the machine window's bottom-right corner offering PocketVM Tools.
/// Installing runs in the background; the machine stays usable.
struct GuestToolsCard: View {
    let machine: Machine
    let dismiss: () -> Void

    private enum Phase: Equatable {
        case offer
        case working(String)
        case installed
        case failed(String)
    }

    @State private var phase: Phase = .offer
    @State private var shareClipboard = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(machine.config.name).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !isWorking {
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
            }

            switch phase {
            case .offer:
                Text("Copy and paste between this machine and your Mac, and Ctrl+C / Ctrl+V in terminals. Installs into your home folder; no password needed.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Share clipboard once installed", isOn: $shareClipboard)
                    .font(.system(size: 12))
                HStack {
                    Button("Don’t Ask Again") {
                        machine.config.toolsPromptDismissed = true
                        try? machine.save()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                    Spacer()
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Install", action: install)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }

            case .working(let step):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step).font(.system(size: 12))
                        Text("A terminal opens for a few seconds; avoid typing until it closes.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .installed:
                Text("Log out of \(machine.config.name) and back in to finish. Clipboard sharing \(shareClipboard ? "starts" : "is available") after that.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Later") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Log Out Now") {
                        Task {
                            try? await ToolsInstaller.logOut(machine)
                            dismiss()
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                }

            case .failed(let message):
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("To install by hand, run this in a terminal in the machine:")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text(ToolsInstaller.manualCommand)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                HStack {
                    Spacer()
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Try Again", action: install)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: phase)
    }

    private var title: String {
        switch phase {
        case .installed: "PocketVM Tools installed"
        case .failed: "Couldn’t install PocketVM Tools"
        default: "Install PocketVM Tools?"
        }
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private func install() {
        phase = .working("Starting…")
        Task {
            do {
                try await ToolsInstaller.install(machine) { phase = .working($0) }
                if shareClipboard { machine.setClipboardSharing(true) }
                phase = .installed
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}
