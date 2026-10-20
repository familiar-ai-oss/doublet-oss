import Foundation

/// Who this build is, from its Info.plist: `DuetBundleID` and `DuetDefaultHubURL`, which come from Config/Duet.xcconfig
/// and your git-ignored Config/Local.xcconfig. The bundle id names the Keychain item, the Handoff and pane types and the
/// log subsystem, so the app and its widgets extension agree.
public enum AppIdentity {
    /// The app's bundle id (the widgets extension reports the app's, not its own).
    public static let bundleID: String = info("DuetBundleID") ?? "com.example.doublet"
    /// The hub a fresh install connects to until one is set in Settings. Empty: none.
    public static let defaultHubURL: String = info("DuetDefaultHubURL") ?? ""

    private static func info(_ key: String) -> String? {
        guard let s = Bundle.main.object(forInfoDictionaryKey: key) as? String, !s.isEmpty, !s.contains("$(") else { return nil }
        return s
    }
}
