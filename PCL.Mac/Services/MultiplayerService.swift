import Combine
import Foundation
import Network

struct SavedMinecraftServer: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var port: UInt16
    var instanceName: String?

    init(id: UUID = UUID(), name: String, host: String, port: UInt16 = 25565, instanceName: String? = nil) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.instanceName = instanceName
    }

    var address: String {
        port == 25565 ? host : "\(host):\(port)"
    }
}

final class MultiplayerServerStore: ObservableObject {
    static let shared = MultiplayerServerStore()

    @Published private(set) var servers: [SavedMinecraftServer]
    private let storageKey = "multiplayerServers.v1"
    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SavedMinecraftServer].self, from: data) {
            servers = decoded
        } else {
            servers = []
        }
    }

    func upsert(_ server: SavedMinecraftServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    func remove(id: UUID) {
        servers.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

struct MinecraftServerStatus: Sendable {
    let versionName: String
    let motd: String
    let onlinePlayers: Int
    let maximumPlayers: Int
    let latencyMilliseconds: Int
}

enum MinecraftServerPingError: LocalizedError {
    case invalidAddress
    case connectionFailed(String)
    case connectionClosed
    case timeout
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "服务器地址或端口无效。"
        case .connectionFailed(let reason): "无法连接服务器：\(reason)"
        case .connectionClosed: "服务器在返回状态前关闭了连接。"
        case .timeout: "服务器状态请求超时。"
        case .malformedResponse: "服务器返回了无法识别的状态数据。"
        }
    }
}

private final class PingContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

enum MinecraftServerPinger {
    static func ping(_ server: SavedMinecraftServer, timeoutSeconds: Double = 5) async throws -> MinecraftServerStatus {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let port = NWEndpoint.Port(rawValue: server.port) else {
            throw MinecraftServerPingError.invalidAddress
        }
        let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: .tcp)
        return try await withThrowingTaskGroup(of: MinecraftServerStatus.self) { group in
            group.addTask {
                try await performPing(connection: connection, server: server)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw MinecraftServerPingError.timeout
            }
            defer {
                group.cancelAll()
                connection.cancel()
            }
            guard let result = try await group.next() else {
                throw MinecraftServerPingError.connectionClosed
            }
            return result
        }
    }

    private static func performPing(
        connection: NWConnection,
        server: SavedMinecraftServer
    ) async throws -> MinecraftServerStatus {
        let queue = DispatchQueue(label: "PCL.Mac.ServerPing.\(server.id.uuidString)")
        try await waitUntilReady(connection, queue: queue)
        let startedAt = ContinuousClock.now
        try await send(handshake(host: server.host, port: server.port) + Data([0x01, 0x00]), over: connection)
        let packet = try await receivePacket(from: connection)
        let elapsed = startedAt.duration(to: .now)
        let latency = Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        return try decodeStatus(packet, latencyMilliseconds: latency)
    }

    private static func waitUntilReady(_ connection: NWConnection, queue: DispatchQueue) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = PingContinuationGate()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    guard gate.claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: MinecraftServerPingError.connectionFailed(error.localizedDescription))
                case .cancelled:
                    guard gate.claim() else { return }
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: MinecraftServerPingError.connectionClosed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: MinecraftServerPingError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func receivePacket(from connection: NWConnection) async throws -> Data {
        var buffer = Data()
        while true {
            if let (length, headerLength) = try packetLength(in: buffer),
               buffer.count >= headerLength + length {
                return buffer.subdata(in: headerLength..<(headerLength + length))
            }
            let chunk = try await receiveChunk(from: connection)
            buffer.append(chunk)
            guard buffer.count <= 1_048_576 else {
                throw MinecraftServerPingError.malformedResponse
            }
        }
    }

    private static func receiveChunk(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, complete, error in
                if let error {
                    continuation.resume(throwing: MinecraftServerPingError.connectionFailed(error.localizedDescription))
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if complete {
                    continuation.resume(throwing: MinecraftServerPingError.connectionClosed)
                } else {
                    continuation.resume(throwing: MinecraftServerPingError.malformedResponse)
                }
            }
        }
    }

    private static func handshake(host: String, port: UInt16) -> Data {
        var payload = Data([0x00])
        payload.append(varInt(767))
        payload.append(protocolString(host))
        payload.append(UInt8((port >> 8) & 0xff))
        payload.append(UInt8(port & 0xff))
        payload.append(0x01)
        return varInt(payload.count) + payload
    }

    static func decodeStatus(_ packet: Data, latencyMilliseconds: Int) throws -> MinecraftServerStatus {
        var index = 0
        guard try readVarInt(packet, index: &index) == 0 else {
            throw MinecraftServerPingError.malformedResponse
        }
        let jsonLength = try readVarInt(packet, index: &index)
        guard jsonLength >= 0, index + jsonLength <= packet.count else {
            throw MinecraftServerPingError.malformedResponse
        }
        let jsonData = packet.subdata(in: index..<(index + jsonLength))
        guard let object = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MinecraftServerPingError.malformedResponse
        }
        let version = (object["version"] as? [String: Any])?["name"] as? String ?? "未知版本"
        let players = object["players"] as? [String: Any]
        let online = players?["online"] as? Int ?? 0
        let maximum = players?["max"] as? Int ?? 0
        let motd = flattenChatComponent(object["description"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(
            versionName: version,
            motd: motd.isEmpty ? "Minecraft 服务器" : motd,
            onlinePlayers: online,
            maximumPlayers: maximum,
            latencyMilliseconds: max(0, latencyMilliseconds)
        )
    }

    private static func protocolString(_ value: String) -> Data {
        let data = Data(value.utf8)
        return varInt(data.count) + data
    }

    private static func varInt(_ value: Int) -> Data {
        var unsigned = UInt32(bitPattern: Int32(value))
        var data = Data()
        repeat {
            var byte = UInt8(unsigned & 0x7f)
            unsigned >>= 7
            if unsigned != 0 { byte |= 0x80 }
            data.append(byte)
        } while unsigned != 0
        return data
    }

    private static func packetLength(in data: Data) throws -> (Int, Int)? {
        var result = 0
        var shift = 0
        for (offset, byte) in data.prefix(5).enumerated() {
            result |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return (result, offset + 1) }
            shift += 7
        }
        if data.count >= 5 { throw MinecraftServerPingError.malformedResponse }
        return nil
    }

    private static func readVarInt(_ data: Data, index: inout Int) throws -> Int {
        var result = 0
        var shift = 0
        while index < data.count, shift < 35 {
            let byte = data[index]
            index += 1
            result |= Int(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw MinecraftServerPingError.malformedResponse
    }

    private static func flattenChatComponent(_ value: Any?) -> String {
        if let text = value as? String { return text }
        if let list = value as? [Any] { return list.map(flattenChatComponent).joined() }
        guard let object = value as? [String: Any] else { return "" }
        var result = object["text"] as? String ?? ""
        if let translate = object["translate"] as? String, result.isEmpty { result = translate }
        if let extra = object["extra"] as? [Any] {
            result += extra.map(flattenChatComponent).joined()
        }
        return result
    }
}
