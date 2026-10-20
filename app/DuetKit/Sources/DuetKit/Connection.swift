import Foundation

public struct HubConfig: Sendable, Equatable {
    public var url: URL
    public var device: String
    public var token: String
    /// What this device is ("mac", "ipad" or "iphone"), told to the hub for its device list. The hub otherwise goes by
    /// the device's name.
    public var kind: String?
    public init(url: URL, device: String, token: String, kind: String? = nil) { self.url = url; self.device = device; self.token = token; self.kind = kind }
}

public enum ConnectionState: Sendable, Equatable {
    case idle
    case connecting
    case connected(device: String)
    case waiting(reason: String, retryIn: Double)
    case failed(String) // e.g. a bad token; no retry
}

public enum ConnectionEvent: Sendable {
    case state(ConnectionState)
    case reset // the hub's log is not the one we were following; start over
    case event(HubEvent)
    /// A connection's replay (everything between welcome and replay_done), in order: applied in one go, so the app
    /// updates once instead of once per event.
    case events([HubEvent])
    case replayDone(headSeq: Int)
    case ptyList([PtyInfo])
    case ptyData(id: String, data: String)
    case ptyExit(id: String, code: Int)
    /// A task for this device's on-device model, and its cancellation.
    case appleTask(AppleTask)
    case appleCancel(taskId: String)
    /// A folder this device watches (its explorer) changed.
    case fsChanged(path: String)
    /// Sessions running outside Duet, and new messages of one this device follows.
    case outsideSessions([OutsideSession])
    case outsideMessages(sessionId: String, messages: [OutsideMessage])
    /// The user's devices (on connecting, and whenever one comes or goes), and a place another device sent here.
    case devices([DeviceInfo])
    case placeSent(PlaceSent)
    /// Reconnect accounting, sent only when it changes (so the store never has to ask the actor per event).
    case stats(gaps: Int, duplicates: Int)
}

public struct Ack: Sendable {
    public let ref: String; public let taskId: String?; public let ptyId: String?
    public var diff: String? = nil; public var truncated: Bool? = nil
    public var listing: FsListing? = nil; public var file: FsFile? = nil
    public var image: String? = nil
    public var chatId: String? = nil; public var files: [String]? = nil
    public var session: OutsideSession? = nil; public var messages: [OutsideMessage]? = nil
    public var sessionId: String? = nil; public var forked: Bool? = nil
    public var queued: Bool? = nil
}

public struct HubError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(message: String) { self.message = message }
}

/// One WebSocket to the hub, reconnecting with backoff. Same rules as hub/src/client.ts:
/// hello{lastSeq} on every connect, events at or below lastSeq dropped as duplicates, jumps counted as gaps.
public actor HubConnection {
    public nonisolated let events: AsyncStream<ConnectionEvent>
    private let continuation: AsyncStream<ConnectionEvent>.Continuation
    private let config: HubConfig
    public private(set) var lastSeq: Int
    public private(set) var gaps = 0
    public private(set) var duplicates = 0
    private var socket: URLSessionWebSocketTask?
    /// Events of the replay in progress, held until replay_done.
    private var replay: [HubEvent]?
    #if DEBUG
    /// Measuring aid: DUET_SPEED_OFF=replay hands the replay over event by event, as before (app/Duet/App/SpeedSwitches.swift).
    private static let batchesReplay = !(ProcessInfo.processInfo.environment["DUET_SPEED_OFF"] ?? "").split(separator: ",").contains("replay")
    #else
    private static let batchesReplay = true
    #endif
    private var running = false
    private var nextRef = 1
    private var acks: [String: CheckedContinuation<Ack, Error>] = [:]
    private let session: URLSession

    public init(config: HubConfig, lastSeq: Int = 0) {
        self.config = config
        self.lastSeq = lastSeq
        (events, continuation) = AsyncStream.makeStream(of: ConnectionEvent.self, bufferingPolicy: .unbounded)
        let c = URLSessionConfiguration.default
        c.waitsForConnectivity = false
        c.timeoutIntervalForRequest = 20
        session = URLSession(configuration: c)
    }

    public func start() {
        guard !running else { return }
        running = true
        Task { await loop() }
    }

    public func stop() {
        running = false
        socket?.cancel(with: .goingAway, reason: nil)
        continuation.yield(.state(.idle))
    }

    /// Drop the socket the way a network failure would. Reconnect follows.
    public func dropConnection() {
        socket?.cancel()
    }

    public var stats: (lastSeq: Int, gaps: Int, duplicates: Int) { (lastSeq, gaps, duplicates) }

    private func loop() async {
        var backoff = 0.5
        while running {
            continuation.yield(.state(.connecting))
            do {
                try await runSocket()
            } catch let e as HubError {
                running = false
                continuation.yield(.state(.failed(e.message)))
                return
            } catch {
                failAcks(error)
            }
            guard running else { return }
            continuation.yield(.state(.waiting(reason: "disconnected", retryIn: backoff)))
            try? await Task.sleep(for: .seconds(backoff))
            backoff = min(backoff * 2, 10)
        }
    }

    private func runSocket() async throws {
        let ws = session.webSocketTask(with: config.url)
        ws.maximumMessageSize = 16 << 20
        socket = ws
        ws.resume()
        defer {
            if socket === ws { socket = nil }
            // A replay the socket dropped partway: what came is still the next events, in order.
            endReplay()
        }
        try await sendJSON(ClientMessage.hello(token: config.token, device: config.device, lastSeq: lastSeq, kind: config.kind).json(ref: nil), on: ws)
        let pinger = Task { [weak ws] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                ws?.sendPing { _ in }
            }
        }
        defer { pinger.cancel() }
        while true {
            let msg = try await ws.receive()
            let data: Data
            switch msg {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            try handle(try JSONDecoder().decode(ServerFrame.self, from: data))
        }
    }

    private func endReplay() {
        if let r = replay, !r.isEmpty { continuation.yield(.events(r)) }
        replay = nil
    }

    private func handle(_ f: ServerFrame) throws {
        switch f {
        case .event(let e):
            if e.seq <= lastSeq {
                duplicates += 1
                continuation.yield(.stats(gaps: gaps, duplicates: duplicates))
                return
            }
            if e.seq != lastSeq + 1 {
                gaps += 1
                continuation.yield(.stats(gaps: gaps, duplicates: duplicates))
            }
            lastSeq = e.seq
            if replay != nil { replay!.append(e) } else { continuation.yield(.event(e)) }
        case .welcome(_, let device, _, _, let reset, let devices):
            if reset { lastSeq = 0; continuation.yield(.reset) }
            continuation.yield(.state(.connected(device: device)))
            if let devices { continuation.yield(.devices(devices)) }
            replay = Self.batchesReplay ? [] : nil
        case .replayDone(let head):
            endReplay()
            continuation.yield(.replayDone(headSeq: head))
        case .ack(let a):
            guard let c = acks.removeValue(forKey: a.ref) else { return }
            if a.ok {
                c.resume(returning: Ack(ref: a.ref, taskId: a.taskId, ptyId: a.ptyId, diff: a.diff, truncated: a.truncated, listing: a.listing, file: a.file, image: a.image, chatId: a.chatId, files: a.files,
                                        session: a.session, messages: a.messages, sessionId: a.sessionId, forked: a.forked, queued: a.queued))
            } else {
                c.resume(throwing: HubError(message: a.error ?? "refused"))
            }
        case .fatal(let error):
            throw HubError(message: error)
        case .ptyList(let l): continuation.yield(.ptyList(l))
        case .ptyData(let id, let data): continuation.yield(.ptyData(id: id, data: data))
        case .ptyExit(let id, let code): continuation.yield(.ptyExit(id: id, code: code))
        case .appleTask(let t): continuation.yield(.appleTask(t))
        case .appleCancel(let id): continuation.yield(.appleCancel(taskId: id))
        case .fsChanged(let path): continuation.yield(.fsChanged(path: path))
        case .outsideSessions(let l): continuation.yield(.outsideSessions(l))
        case .outsideMessages(let id, let m): continuation.yield(.outsideMessages(sessionId: id, messages: m))
        case .devices(let l): continuation.yield(.devices(l))
        case .placeSent(let p): continuation.yield(.placeSent(p))
        case .unknown:
            break
        }
    }

    @discardableResult
    public func send(_ m: ClientMessage) async throws -> Ack {
        guard let ws = socket else { throw HubError(message: "not connected") }
        let ref = String(nextRef)
        nextRef += 1
        return try await withCheckedThrowingContinuation { c in
            acks[ref] = c
            Task {
                do { try await self.sendJSON(m.json(ref: ref), on: ws) } catch { self.failAck(ref, error) }
            }
        }
    }

    private func sendJSON(_ v: JSONValue, on ws: URLSessionWebSocketTask) async throws {
        let data = try JSONEncoder().encode(v)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func failAck(_ ref: String, _ error: Error) {
        acks.removeValue(forKey: ref)?.resume(throwing: error)
    }

    private func failAcks(_ error: Error) {
        let pending = acks
        acks.removeAll()
        for c in pending.values { c.resume(throwing: HubError(message: "connection lost: \(error.localizedDescription)")) }
    }
}
