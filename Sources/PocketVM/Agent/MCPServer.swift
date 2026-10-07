import Foundation
import Network
import Observation

/// A Model Context Protocol server (Streamable HTTP, JSON responses) bound to 127.0.0.1.
/// MCP clients (coding agents and the like) connect to it to see and drive the machines that allow it.
@MainActor @Observable
final class MCPServer {
    static let shared = MCPServer()
    static let protocolVersion = "2025-06-18"

    var enabled: Bool {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "mcpEnabled")
            enabled ? start() : stop()
        }
    }
    private(set) var port: UInt16
    private(set) var token: String
    private(set) var listening = false
    private(set) var lastError: String?

    var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

    @ObservationIgnored private var listener: NWListener?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "mcpEnabled") as? Bool ?? true
        let stored = defaults.integer(forKey: "mcpPort")
        port = stored > 0 ? UInt16(stored) : 7979
        if let saved = defaults.string(forKey: "mcpToken") {
            token = saved
        } else {
            token = Self.makeToken()
            defaults.set(token, forKey: "mcpToken")
        }
    }

    func regenerateToken() {
        token = Self.makeToken()
        UserDefaults.standard.set(token, forKey: "mcpToken")
    }

    func start() {
        guard enabled, listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                HTTPConnection(connection).start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.listening = true
                        self.lastError = nil
                    case .failed(let error):
                        self.listening = false
                        self.lastError = error.localizedDescription
                        self.listener?.cancel()
                        self.listener = nil
                    case .cancelled:
                        self.listening = false
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listening = false
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return "pvm_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: JSON-RPC

    /// Returns the HTTP status and an optional JSON body.
    func handle(body: Data) async -> (Int, Any?) {
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            return (400, rpcError(id: NSNull(), code: -32700, message: "Parse error"))
        }
        if let batch = json as? [[String: Any]] {
            var responses: [Any] = []
            for message in batch {
                if let response = await handle(message: message) { responses.append(response) }
            }
            return responses.isEmpty ? (202, nil) : (200, responses)
        }
        guard let message = json as? [String: Any] else {
            return (400, rpcError(id: NSNull(), code: -32600, message: "Invalid request"))
        }
        if let response = await handle(message: message) { return (200, response) }
        return (202, nil)
    }

    private func handle(message: [String: Any]) async -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil } // a response from the client
        guard let id = message["id"] else { return nil } // a notification
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return rpcResult(id: id, [
                "protocolVersion": requested ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "pocketvm", "title": "PocketVM", "version": "0.1.0-alpha"],
                "instructions": AgentTools.instructions,
            ])
        case "ping":
            return rpcResult(id: id, [:])
        case "tools/list":
            return rpcResult(id: id, ["tools": AgentTools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return rpcError(id: id, code: -32602, message: "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            return rpcResult(id: id, await AgentTools.call(name, arguments))
        case "resources/list":
            return rpcResult(id: id, ["resources": []])
        case "prompts/list":
            return rpcResult(id: id, ["prompts": []])
        default:
            return rpcError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func rpcResult(id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func rpcError(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }
}

/// Minimal HTTP/1.1 over one TCP connection, with keep-alive.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private var buffer = Data()

    init(_ connection: NWConnection) { self.connection = connection }

    func start() {
        connection.start(queue: .main)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, isComplete, error in
            if let data { buffer.append(data) }
            if processBuffer() { return }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                receive()
            }
        }
    }

    /// Returns true when a full request was taken and is being answered.
    private func processBuffer() -> Bool {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { respond(400, json: nil); return true }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.count - bodyStart >= length else { return false }
        let body = buffer[bodyStart..<bodyStart + length]
        buffer.removeSubrange(..<(bodyStart + length))

        let method = String(requestLine[0])
        let path = String(requestLine[1]).split(separator: "?").first.map(String.init) ?? "/"

        // Browsers can reach localhost too; refuse anything a web page could send.
        if let origin = headers["origin"], !(origin.hasPrefix("http://127.0.0.1") || origin.hasPrefix("http://localhost")) {
            respond(403, json: ["error": "Forbidden origin"])
            return true
        }

        Task { @MainActor in
            let server = MCPServer.shared
            guard path == "/mcp" else {
                self.respond(404, json: ["error": "Not found. The MCP endpoint is /mcp."])
                return
            }
            guard headers["authorization"] == "Bearer \(server.token)" else {
                self.respond(401, json: ["error": "Missing or wrong bearer token. Copy it from PocketVM → Connect AI Agents."])
                return
            }
            switch method {
            case "POST":
                let (status, json) = await server.handle(body: Data(body))
                self.respond(status, json: json)
            case "DELETE":
                self.respond(200, json: nil)
            default:
                self.respond(405, json: nil, extra: ["Allow": "POST, DELETE"])
            }
        }
        return true
    }

    private func respond(_ status: Int, json: Any?, extra: [String: String] = [:]) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Length: \(body.count)\r\n"
        if json != nil { head += "Content-Type: application/json\r\n" }
        for (key, value) in extra { head += "\(key): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [self] error in
            if error != nil { connection.cancel(); return }
            if !processBuffer() { receive() }
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        default: "Error"
        }
    }
}
