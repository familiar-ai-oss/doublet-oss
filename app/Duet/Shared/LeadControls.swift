import DuetKit
import SwiftUI

/// Claude's model. Each model offers its own effort levels.
struct LeadModelMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let info = model.store.leadInfo
        let current = model.currentLeadModel
        Menu {
            ForEach(model.leadModelChoices) { m in
                Button { model.send(.setModel(m.value)) } label: {
                    if m.id == current?.id { Label(m.displayName, systemImage: "checkmark") } else { Text(m.displayName) }
                }
            }
        } label: {
            Label(current?.displayName ?? info?.model ?? "Model", systemImage: "sparkles")
        }
        .accessibilityIdentifier("lead-model")
    }
}

/// Effort for Claude: Auto, or one of the levels the current model accepts. Applies from the next turn.
struct LeadEffortMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let effort = model.store.effort
        Menu {
            Section("Effort (from the next turn)") {
                Button { model.send(.setEffort(nil)) } label: {
                    if effort == nil { Label("Auto", systemImage: "checkmark") } else { Text("Auto") }
                }
                ForEach(model.currentLeadModel?.effortLevels ?? EffortLevel.allCases, id: \.self) { l in
                    Button { model.send(.setEffort(l)) } label: {
                        if l == effort { Label(effortLabel(l.rawValue), systemImage: "checkmark") } else { Text(effortLabel(l.rawValue)) }
                    }
                }
            }
        } label: {
            Label(effort.map { effortLabel($0.rawValue) } ?? "Auto", systemImage: "gauge.with.dots.needle.50percent")
        }
        .accessibilityIdentifier("lead-effort")
    }
}

/// How Claude asks before it acts (Claude Code's permission modes). The hub keeps it: it applies at once, mid-turn too,
/// and new conversations start in it. Only Claude changes mode; workers and side chats keep theirs.
struct PermissionModeChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    /// What Claude does in it, for the menu.
    let detail: String
    /// The line above the composer while it's on (nil for Ask, the default).
    let banner: String?

    static let all: [PermissionModeChoice] = [
        PermissionModeChoice(id: "default", title: "Ask", symbol: "hand.raised", detail: "Claude asks before it edits a file or runs a command", banner: nil),
        PermissionModeChoice(id: "acceptEdits", title: "Accept Edits", symbol: "pencil.line", detail: "Edits go ahead; commands still ask",
                             banner: "Accept Edits: Claude edits files without asking; commands still ask"),
        PermissionModeChoice(id: "auto", title: "Auto", symbol: "wand.and.stars", detail: "Claude Code decides what's safe to run, and asks when it can't tell",
                             banner: "Auto: Claude Code decides what's safe to run, and asks when it can't tell"),
        PermissionModeChoice(id: "plan", title: "Plan", symbol: "list.bullet.clipboard", detail: "Claude reads and plans, and changes nothing until you approve its plan",
                             banner: "Plan: Claude reads and plans, and changes nothing until you approve its plan"),
        PermissionModeChoice(id: "bypassPermissions", title: "Bypass Permissions", symbol: "exclamationmark.shield", detail: "Nothing asks: Claude runs and edits anything",
                             banner: "Bypass Permissions: nothing asks. Claude runs and edits anything"),
    ]

    static func named(_ id: String) -> PermissionModeChoice { all.first { $0.id == id } ?? all[0] }

    var risky: Bool { id == "bypassPermissions" }
}

/// Claude's permission mode: Ask, Accept Edits, Auto, Plan or Bypass Permissions, which asks again before it's on.
struct LeadModeMenu: View {
    @Environment(AppModel.self) private var model
    @State private var confirmingBypass = false

    var body: some View {
        let current = PermissionModeChoice.named(model.permissionMode)
        let supported = model.permissionModesSupported
        Menu {
            // A hub from before modes refuses them: say so rather than fail quietly.
            Section(supported ? "When Claude acts" : "Needs a hub update") {
                ForEach(PermissionModeChoice.all) { m in
                    Button {
                        if m.risky { confirmingBypass = true } else { model.setPermissionMode(m.id) }
                    } label: {
                        Label {
                            Text(m.title)
                            Text(m.detail)
                        } icon: {
                            Image(systemName: m == current ? "checkmark" : m.symbol)
                        }
                    }
                    .disabled(!supported)
                }
            }
        } label: {
            Label(current.title, systemImage: current.symbol)
        }
        .tint(current.risky ? .red : nil)
        .help("How Claude asks before it acts: \(current.detail)")
        .confirmationDialog("Bypass permissions?", isPresented: $confirmingBypass, titleVisibility: .visible) {
            Button("Bypass Permissions", role: .destructive) { model.setPermissionMode("bypassPermissions") }
        } message: {
            Text("Claude runs every command and edits any file on the hub without asking, until you switch back. Workers already run this way.")
        }
        .accessibilityIdentifier("lead-mode")
    }
}

/// Above the composer while Claude isn't in Ask mode: which mode it's in, and the way back to Ask.
struct PermissionModeLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = PermissionModeChoice.named(model.permissionMode)
        if let banner = current.banner {
            HStack(spacing: 8) {
                Label(banner, systemImage: current.symbol)
                    .foregroundStyle(current.risky ? Color.red : .secondary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button("Back to Ask") { model.setPermissionMode("default") }
                    .buttonStyle(.borderless)
            }
            .font(.caption)
            .accessibilityIdentifier("permission-mode-line")
        }
    }
}
