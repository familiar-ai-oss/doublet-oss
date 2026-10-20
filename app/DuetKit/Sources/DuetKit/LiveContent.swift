import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// What the Lock Screen and the Dynamic Island show. The hub pushes this exact shape (hub/src/live.ts `LiveState`),
/// and the app builds it from its own store while it runs.
public struct LiveContent: Codable, Hashable, Sendable {
    public struct Approval: Codable, Hashable, Sendable {
        public var id: String; public var tool: String; public var summary: String; public var risky: Bool
        public init(id: String, tool: String, summary: String, risky: Bool) { self.id = id; self.tool = tool; self.summary = summary; self.risky = risky }
    }
    public struct Worker: Codable, Hashable, Sendable, Identifiable {
        public var id: String; public var name: String; public var place: String; public var tokPerS: Double?; public var busy: Bool
        public init(id: String, name: String, place: String, tokPerS: Double?, busy: Bool) { self.id = id; self.name = name; self.place = place; self.tokPerS = tokPerS; self.busy = busy }
    }
    public var phase: String
    public var symbol: String
    public var busy: Bool
    /// When the turn started, in seconds since 1970 (a plain number, so pushes and local updates agree).
    public var since: Double?
    public var waiting: Int
    public var approval: Approval?
    public var workers: [Worker]

    public init(phase: String, symbol: String, busy: Bool, since: Double?, waiting: Int, approval: Approval?, workers: [Worker]) {
        self.phase = phase; self.symbol = symbol; self.busy = busy; self.since = since; self.waiting = waiting; self.approval = approval; self.workers = workers
    }

    public var sinceDate: Date? { since.map { Date(timeIntervalSince1970: $0) } }
    /// The main local-model worker: the R9700's (the default fleet's big GPU) when it's in the fleet, else the first.
    public var mainWorker: Worker? { workers.first { $0.place.contains("R9700") } ?? workers.first }
    public var active: Bool { busy || waiting > 0 }

    public static let idle = LiveContent(phase: "Idle", symbol: "checkmark.circle", busy: false, since: nil, waiting: 0, approval: nil, workers: [])
}

extension LiveContent {
    /// The same status the hub would push, from the app's store.
    @MainActor public static func from(_ store: DuetStore) -> LiveContent {
        let status = store.leadStatus
        let approval: Approval? = store.attention.lazy.compactMap { item -> Approval? in
            guard case .approval(let a) = item else { return nil }
            return Approval(id: a.id, tool: a.displayName ?? a.tool, summary: ToolSummary.text(a.tool, a.input), risky: a.needsCare)
        }.first
        let waiting = store.attention.count
        let phase = approval != nil ? "Needs your approval" : waiting > 0 ? "\(waiting) waiting on you" : status.busy ? status.label : "Idle"
        let symbol = waiting > 0 ? "hand.raised.fill" : status.symbol
        let workers = store.workers.filter(\.enabled).map { w -> Worker in
            let parts = w.label.split(separator: "·").map { $0.trimmingCharacters(in: .whitespaces) }
            return Worker(id: w.id, name: parts.first ?? w.id, place: parts.dropFirst().first ?? "", tokPerS: w.tokPerS, busy: w.running != nil)
        }
        return LiveContent(phase: phase, symbol: symbol, busy: status.busy, since: status.since?.timeIntervalSince1970, waiting: waiting, approval: approval, workers: workers)
    }
}

#if canImport(ActivityKit) && os(iOS)
/// Duet's Live Activity: one per device, about the hub it's connected to.
public struct DuetActivityAttributes: ActivityAttributes {
    public typealias ContentState = LiveContent
    public var hub: String
    public init(hub: String) { self.hub = hub }
}
#endif
