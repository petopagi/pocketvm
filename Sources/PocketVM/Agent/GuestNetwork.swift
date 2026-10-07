import Foundation

enum GuestNetwork {
    /// The guest's current IPv4 address. The Mac's ARP table is checked first because it reflects
    /// live traffic whatever DHCP client ID the guest used (systemd-networkd sends a DUID, not the MAC);
    /// otherwise the newest DHCP lease for the MAC.
    static func ipAddress(for mac: String) -> String? {
        arpAddress(for: mac) ?? leaseAddress(for: mac)
    }

    private static func leaseAddress(for mac: String) -> String? {
        guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        let wanted = normalize(mac)
        var best: (ip: String, expiry: UInt64)?
        for block in leases.components(separatedBy: "}") {
            var ip: String?, hardware: String?, expiry: UInt64 = 0
            for line in block.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("ip_address=") { ip = String(trimmed.dropFirst("ip_address=".count)) }
                if trimmed.hasPrefix("lease=0x") { expiry = UInt64(trimmed.dropFirst("lease=0x".count), radix: 16) ?? 0 }
                if trimmed.hasPrefix("hw_address=") {
                    // "1,a:b:c:d:e:f": leading zeros are dropped.
                    hardware = trimmed.dropFirst("hw_address=".count).split(separator: ",").last.map(String.init)
                }
            }
            if let ip, let hardware, normalize(hardware) == wanted, expiry >= (best?.expiry ?? 0) {
                best = (ip, expiry)
            }
        }
        return best?.ip
    }

    private static func arpAddress(for mac: String) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/arp")
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let wanted = normalize(mac)
        // "? (192.168.64.6) at 32:a7:aa:56:5f:8 on bridge100 ifscope [bridge]"
        for line in output.split(separator: "\n") where line.contains(" on bridge") {
            let parts = line.split(separator: " ")
            guard parts.count >= 4, let open = parts[1].firstIndex(of: "("), let close = parts[1].firstIndex(of: ")") else { continue }
            if normalize(String(parts[3])) == wanted {
                return String(parts[1][parts[1].index(after: open)..<close])
            }
        }
        return nil
    }

    private static func normalize(_ mac: String) -> [Int] {
        mac.split(separator: ":").compactMap { Int($0, radix: 16) }
    }

    struct CommandResult {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a command in the guest over SSH with the host user's keys.
    static func run(_ command: String, user: String, host: String, timeout: TimeInterval) async throws -> CommandResult {
        let knownHosts = URL.applicationSupportDirectory.appending(path: "PocketVM/known_hosts").path
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHosts)",
            "-o", "ConnectTimeout=8",
            "-o", "LogLevel=ERROR",
            // Never hand the guest anything of the Mac's: no agent, X11, or tunnels, whatever ~/.ssh/config says.
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
            "-o", "PermitLocalCommand=no",
            "-o", "Tunnel=no",
            "-T",
            "\(user)@\(host)", command,
        ]
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        // Blocking waits run on a plain dispatch thread, not the cooperative pool.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try runToCompletion(process, out: out, err: err, timeout: timeout) })
            }
        }
    }

    private static func runToCompletion(_ process: Process, out: Pipe, err: Pipe, timeout: TimeInterval) throws -> CommandResult {
            try process.run()
            final class Flag: @unchecked Sendable { var timedOut = false }
            let flag = Flag()
            let watchdog = DispatchWorkItem {
                if process.isRunning { flag.timedOut = true; process.terminate() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
            // Drain both pipes concurrently so a chatty command can't fill a buffer and stall.
            var errorData = Data()
            let drained = DispatchGroup()
            drained.enter()
            DispatchQueue.global().async {
                errorData = err.fileHandleForReading.readDataToEndOfFile()
                drained.leave()
            }
            let outputData = out.fileHandleForReading.readDataToEndOfFile()
            drained.wait()
            process.waitUntilExit()
            watchdog.cancel()
            if flag.timedOut { throw PocketError("The command timed out after \(Int(timeout)) seconds.") }
            return CommandResult(
                status: process.terminationStatus,
                stdout: String(decoding: outputData, as: UTF8.self),
                stderr: String(decoding: errorData, as: UTF8.self))
    }
}
