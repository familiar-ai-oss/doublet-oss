import Foundation

extension DuetStore {
    /// How Claude asks before it acts, as the hub last said: "default" (Ask, also before the hub says), "acceptEdits",
    /// "auto", "plan" or "bypassPermissions". It changes when a device sends `.setPermissionMode`, and when Claude
    /// leaves plan mode itself (its plan approved: back to the mode from before plan mode).
    public var permissionMode: String { leadInfo?.permissionMode ?? "default" }
}
