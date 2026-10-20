#if os(iOS)
import ActivityKit
import DuetKit
import Foundation
import OSLog
import UIKit

/// Duet's Live Activity on this iPhone or iPad. The app starts one when Claude starts working (or something waits on
/// you) while it's open, keeps it current while it runs, and ends it once things go quiet. The hub's pushes keep it
/// current when the app isn't running, and can start one (push-to-start), once it has an APNs key.
@MainActor
final class LiveActivityController {
    typealias DuetActivity = Activity<DuetActivityAttributes>

    private weak var model: AppModel?
    /// The activity on the Lock Screen, by id: ActivityKit's Activity isn't Sendable, so the controller keeps only the
    /// id and looks the activity up each time it acts on it.
    private var activityID: String?
    private var shown: LiveContent?
    private var scheduled = false
    private var lastUpdate = Date.distantPast
    private var token: String?
    private var startToken: String?
    private var wasConnected = false
    private var watchers: [Task<Void, Never>] = []
    private let log = Logger(subsystem: AppIdentity.bundleID, category: "live")

    /// Development-signed builds get APNs sandbox tokens.
    static var environment: String {
        #if DEBUG
        "development"
        #else
        "production"
        #endif
    }

    init(model: AppModel) {
        self.model = model
        // The token the hub can start an activity with while the app is closed.
        watchers.append(Task { [weak self] in
            for await data in DuetActivity.pushToStartTokenUpdates {
                self?.startToken = data.hexString
                self?.register()
            }
        })
        // Activities the hub started, or one left from an earlier launch.
        watchers.append(Task { [weak self] in
            for await a in DuetActivity.activityUpdates { self?.adopt(a.id) }
        })
        if let id = DuetActivity.activities.first(where: { $0.activityState == .active || $0.activityState == .stale })?.id { adopt(id) }
    }

    nonisolated private static func find(_ id: String?) -> DuetActivity? {
        id.flatMap { id in DuetActivity.activities.first { $0.id == id } }
    }

    /// Every store change: reconnects re-register, status changes reach the Lock Screen within a second.
    func storeChanged(_ store: DuetStore) {
        let connected = if case .connected = store.connection { true } else { false }
        if connected, !wasConnected, token != nil || startToken != nil { register() }
        wasConnected = connected
        // A half-replayed log isn't the present.
        guard store.replayedOnce, !scheduled, LiveContent.from(store) != shown else { return }
        scheduled = true
        let wait = max(0, 1 - Date.now.timeIntervalSince(lastUpdate))
        Task { [weak self] in
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard let self, let store = self.model?.store else { return }
            self.scheduled = false
            await self.apply(LiveContent.from(store))
        }
    }

    private func apply(_ content: LiveContent) async {
        lastUpdate = .now
        shown = content
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        if let a = Self.find(activityID), a.activityState == .active || a.activityState == .stale {
            if content.active {
                await a.update(ActivityContent(state: content, staleDate: .now + 300))
            } else {
                // Done: it says so for a quarter of an hour, then leaves the Lock Screen.
                await a.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .after(.now + 15 * 60))
            }
        } else if content.active, UIApplication.shared.applicationState == .active {
            // Only an app in the foreground can start one.
            await start(content)
        }
    }

    private func start(_ content: LiveContent) async {
        // Whatever an earlier stretch of work left on the Lock Screen goes first.
        for id in DuetActivity.activities.map(\.id) { await Self.find(id)?.end(nil, dismissalPolicy: .immediate) }
        let attributes = DuetActivityAttributes(hub: hubName)
        let initial = ActivityContent(state: content, staleDate: Date.now + 300)
        do {
            adopt(try DuetActivity.request(attributes: attributes, content: initial, pushType: .token).id)
        } catch {
            // Without push (no APNs entitlement in this build), it still works while the app runs.
            log.error("live activity with push: \(error.localizedDescription, privacy: .public)")
            if let id = (try? DuetActivity.request(attributes: attributes, content: initial, pushType: nil))?.id { adopt(id) }
        }
    }

    private func adopt(_ id: String) {
        guard activityID != id else { return }
        // One at a time: if the hub's start raced the app's own, the newer one stays.
        if let old = activityID { Task { await Self.find(old)?.end(nil, dismissalPolicy: .immediate) } }
        activityID = id
        token = nil
        watchers.append(Task { [weak self] in
            guard let a = Self.find(id) else { return }
            for await data in a.pushTokenUpdates {
                guard self?.activityID == id else { return }
                self?.token = data.hexString
                self?.register()
            }
        })
        watchers.append(Task { [weak self] in
            guard let a = Self.find(id) else { return }
            for await state in a.activityStateUpdates where state == .ended || state == .dismissed {
                self?.ended(id)
                return
            }
        })
    }

    private func ended(_ id: String) {
        guard activityID == id else { return }
        activityID = nil
        token = nil
        model?.send(.liveActivityEnd, quiet: true)
    }

    /// Where the hub should push: over the WebSocket when connected, else over HTTPS (a background launch has none).
    private func register() {
        guard let model, token != nil || startToken != nil else { return }
        if case .connected = model.store.connection {
            model.send(.liveActivity(token: token, startToken: startToken, environment: Self.environment), quiet: true)
        } else {
            var body = ["environment": Self.environment]
            body["token"] = token
            body["startToken"] = startToken
            Task { [log] in
                do { try await HubHTTP.post("/api/live", body) } catch { log.error("live activity token: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    private var hubName: String {
        URL(string: model?.hubURL ?? "")?.host()?.split(separator: ".").first.map(String.init) ?? "hub"
    }
}

private extension Data {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
#endif
