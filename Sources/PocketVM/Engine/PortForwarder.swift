import Foundation
import Network

/// Relays 127.0.0.1:<host port> to <guest IP>:<guest port> for every configured forward.
/// Listeners stay up while PocketVM runs; connections are refused while the guest has no address.
@MainActor
final class PortForwarder {
    static let shared = PortForwarder()

    private var listeners: [UInt16: (machine: UUID, guest: UInt16, listener: NWListener)] = [:]
    private(set) var failures: [UInt16: String] = [:]

    /// Brings listeners in line with every machine's `portForwards`.
    func sync() {
        var wanted: [UInt16: (UUID, UInt16)] = [:]
        for machine in Library.shared.machines where !machine.isDemo {
            for forward in machine.config.portForwards { wanted[forward.hostPort] = (machine.id, forward.guestPort) }
        }
        for (port, entry) in listeners where wanted[port].map({ $0.0 != entry.machine || $0.1 != entry.guest }) ?? true {
            entry.listener.cancel()
            listeners[port] = nil
        }
        failures = failures.filter { wanted[$0.key] != nil }
        for (port, target) in wanted where listeners[port] == nil {
            listen(on: port, machine: target.0, guestPort: target.1)
        }
    }

    func isListening(_ port: UInt16) -> Bool { listeners[port] != nil && failures[port] == nil }

    private func listen(on port: UInt16, machine: UUID, guestPort: UInt16) {
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { inbound in
                Task { @MainActor in PortForwarder.relay(inbound, machine: machine, guestPort: guestPort) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Task { @MainActor in
                        PortForwarder.shared.failures[port] = error.localizedDescription
                        PortForwarder.shared.listeners[port] = nil
                    }
                }
            }
            listener.start(queue: .main)
            listeners[port] = (machine, guestPort, listener)
        } catch {
            failures[port] = error.localizedDescription
        }
    }

    private static func relay(_ inbound: NWConnection, machine id: UUID, guestPort: UInt16) {
        guard let machine = Library.shared.machine(id), machine.status == .running,
              let ip = GuestNetwork.ipAddress(for: machine.config.macAddress) else {
            inbound.cancel()
            return
        }
        let outbound = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: guestPort)!, using: .tcp)
        let close: @Sendable () -> Void = {
            inbound.cancel()
            outbound.cancel()
        }
        outbound.stateUpdateHandler = { state in
            switch state {
            case .ready:
                pump(from: inbound, to: outbound, close: close)
                pump(from: outbound, to: inbound, close: close)
            case .failed, .cancelled:
                close()
            default:
                break
            }
        }
        inbound.stateUpdateHandler = { state in
            if case .failed = state { close() }
        }
        inbound.start(queue: .main)
        outbound.start(queue: .main)
    }

    private nonisolated static func pump(from source: NWConnection, to sink: NWConnection, close: @escaping @Sendable () -> Void) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { close(); return }
                    if isComplete {
                        sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
                    } else {
                        pump(from: source, to: sink, close: close)
                    }
                })
            } else if isComplete {
                sink.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .idempotent)
            } else if error != nil {
                close()
            } else {
                pump(from: source, to: sink, close: close)
            }
        }
    }
}

enum PortScanner {
    static let commonPorts: [UInt16] = [22, 80, 443, 3000, 3389, 5000, 5900, 8000, 8080, 8443]

    /// Ports on `host` that accept a TCP connection within `timeout`.
    static func open(host: String, ports: [UInt16], timeout: TimeInterval = 1) async -> [UInt16] {
        await withTaskGroup(of: UInt16?.self) { group in
            for port in ports {
                group.addTask { await accepts(host: host, port: port, timeout: timeout) ? port : nil }
            }
            var open: [UInt16] = []
            for await port in group { if let port { open.append(port) } }
            return open.sorted()
        }
    }

    private static func accepts(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let once = Once()
            let finish: @Sendable (Bool) -> Void = { value in
                guard once.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }
}

/// True exactly once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
