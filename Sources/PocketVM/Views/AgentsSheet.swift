import SwiftUI

struct AgentsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var server = MCPServer.shared
    @State private var client: Client = .claudeCode
    @State private var installing = false
    @State private var installResult: (ok: Bool, message: String)?
    @State private var copied = false

    enum Client: String, CaseIterable, Identifiable {
        case claudeCode = "Claude Code", codex = "Codex", gemini = "Gemini CLI", other = "Other"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var server = server
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Connect AI Agents").font(.system(size: 15, weight: .semibold))
                Text("Agents see a machine’s screen and use its own keyboard and mouse, so they never need permissions on your Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(server.listening ? Palette.running : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(serverStatus)
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Toggle("MCP server", isOn: $server.enabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("MCP server")
            }

            Picker("Client", selection: $client) {
                ForEach(Client.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 6) {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    Text(snippet)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize()
                        .padding(10)
                }
                .scrollIndicators(.never)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let installResult {
                Text(installResult.message)
                    .font(.system(size: 11))
                    .foregroundStyle(installResult.ok ? Palette.running : .red)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            HStack(spacing: 8) {
                Button("New Token") {
                    server.regenerateToken()
                    installResult = nil
                }
                .help("Disconnects every agent using the current token")
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                }
                if client == .claudeCode {
                    Button(installing ? "Adding…" : "Add to Claude Code", action: addToClaudeCode)
                        .buttonStyle(.glassProminent)
                        .disabled(installing)
                } else {
                    Button("Done") { dismiss() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }

            Text("Only machines with “Let AI agents use this machine” turned on are available. Screenshots may ask once for Screen Recording permission.")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 460)
        .animation(.easeOut(duration: 0.15), value: installResult?.message)
        .onExitCommand { dismiss() }
    }

    private var serverStatus: String {
        if !server.enabled { return "Off" }
        if let error = server.lastError { return "Not running: \(error)" }
        return server.listening ? "Listening on \(server.endpoint)" : "Starting…"
    }

    private var caption: String {
        switch client {
        case .claudeCode: "Run in Terminal, or press Add to Claude Code:"
        case .codex: "Add to ~/.codex/config.toml:"
        case .gemini: "Add to ~/.gemini/settings.json:"
        case .other: "Streamable HTTP endpoint with a bearer token:"
        }
    }

    private var claudeCommand: String {
        "claude mcp add --transport http --scope user pocketvm \(server.endpoint) --header \"Authorization: Bearer \(server.token)\""
    }

    private var snippet: String {
        switch client {
        case .claudeCode:
            return claudeCommand
        case .codex:
            return """
            [mcp_servers.pocketvm]
            url = "\(server.endpoint)"
            http_headers = { "Authorization" = "Bearer \(server.token)" }
            """
        case .gemini:
            return """
            "mcpServers": {
              "pocketvm": {
                "httpUrl": "\(server.endpoint)",
                "headers": { "Authorization": "Bearer \(server.token)" }
              }
            }
            """
        case .other:
            return """
            {
              "type": "http",
              "url": "\(server.endpoint)",
              "headers": { "Authorization": "Bearer \(server.token)" }
            }
            """
        }
    }

    private func addToClaudeCode() {
        installing = true
        installResult = nil
        let script = "claude mcp remove --scope user pocketvm >/dev/null 2>&1; \(claudeCommand)"
        // Blocking process work stays off Swift's cooperative pool.
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lc", script]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var output = ""
            var ok = false
            do {
                try process.run()
                output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                ok = process.terminationStatus == 0
            } catch {
                output = error.localizedDescription
            }
            let succeeded = ok
            let message = ok
                ? "Added. Start a new Claude Code session and ask it to use a PocketVM machine."
                : (output.contains("not found")
                    ? "Couldn’t find the claude command. Copy the command and run it where Claude Code is installed."
                    : output.trimmingCharacters(in: .whitespacesAndNewlines))
            DispatchQueue.main.async {
                installing = false
                installResult = (succeeded, message)
            }
        }
    }
}
