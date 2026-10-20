// Compiled into the iOS app and its widget extension: the widget shows these buttons, and iOS runs the intent in the
// app's process (in the background if need be).
import ActivityKit
import AppIntents
import DuetKit
import Foundation
import Security
import UIKit

/// Approve Claude's request from the Lock Screen or the Dynamic Island. It asks you to unlock first: anyone can pick
/// up a locked phone.
struct ApproveIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Approve Claude's Request"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let isDiscoverable = false

    @Parameter(title: "Request") var approvalId: String

    init() {}
    init(approvalId: String) { self.approvalId = approvalId }

    func perform() async throws -> some IntentResult {
        try await HubHTTP.decide(approvalId, allow: true)
        return .result()
    }
}

/// Reject it: always safe, so no unlock.
struct RejectIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Reject Claude's Request"
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @Parameter(title: "Request") var approvalId: String

    init() {}
    init(approvalId: String) { self.approvalId = approvalId }

    func perform() async throws -> some IntentResult {
        try await HubHTTP.decide(approvalId, allow: false)
        return .result()
    }
}

/// The hub over plain HTTPS, for when there's no WebSocket: the Lock Screen's buttons, and a Live Activity's token
/// from a background launch. The app's own settings: hub URL and device name in UserDefaults, the token in the Keychain.
@MainActor
enum HubHTTP {
    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    static func post(_ path: String, _ body: [String: String]) async throws {
        let defaults = UserDefaults.standard
        let hub = defaults.string(forKey: "hubURL") ?? AppIdentity.defaultHubURL
        let device = defaults.string(forKey: "device") ?? (UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")
        guard var c = URLComponents(string: hub) else { throw Failure(status: 0, message: "The hub URL isn't valid.") }
        c.scheme = c.scheme == "ws" ? "http" : "https"
        c.path = path
        c.query = nil
        guard let url = c.url else { throw Failure(status: 0, message: "The hub URL isn't valid.") }
        guard let token = token(device) else { throw Failure(status: 0, message: "This device has no hub token yet. Open Doublet's settings.") }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue(device, forHTTPHeaderField: "x-duet-device")
        r.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        r.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await URLSession.shared.data(for: r)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            let reason = (try? JSONDecoder().decode(Reply.self, from: data))?.error ?? "The hub said \(status)."
            throw Failure(status: status, message: reason)
        }
    }

    private struct Reply: Decodable { let error: String? }

    /// Decide, then show it on the Lock Screen at once; the next update (the hub's push, or the app's) has the rest.
    static func decide(_ id: String, allow: Bool) async throws {
        do {
            try await post("/api/decide", ["id": id, "decision": allow ? "allow" : "deny"])
        } catch let f as Failure where f.status == 409 {
            // Already decided: on another device, or by a second tap.
        }
        for a in Activity<DuetActivityAttributes>.activities {
            var s = a.content.state
            guard s.approval?.id == id else { continue }
            s.approval = nil
            s.waiting = max(0, s.waiting - 1)
            s.phase = allow ? "Approved" : "Rejected"
            s.symbol = allow ? "checkmark.circle" : "xmark.circle"
            await a.update(ActivityContent(state: s, staleDate: .now + 300))
        }
    }

    private static func token(_ device: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AppIdentity.bundleID + ".hub-token",
                                kSecAttrAccount as String: device, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}
