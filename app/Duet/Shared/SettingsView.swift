import DuetKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var device = ""
    @State private var token = ""
    @AppStorage("suggestRoutes") private var suggestRoutes = true

    var body: some View {
        Form {
            Section {
                TextField("Hub URL", text: $url)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never).keyboardType(.URL)
                    #endif
                TextField("This device's name", text: $device)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField(model.hasToken ? "Device token (saved in the Keychain)" : "Device token", text: $token)
            } header: {
                Text("Hub")
            } footer: {
                Text("Create a token on the hub with `node --experimental-strip-types src/main.ts token add <device>`. It's stored only in this device's Keychain.")
            }
            Section {
                LabeledContent("On this device") { Text(appleState).foregroundStyle(.secondary) }
                Toggle("Suggest where to send messages", isOn: $suggestRoutes)
            } header: {
                Text("Apple Intelligence")
            } footer: {
                Text("While Doublet is open, this device's on-device model is a worker Claude can give summaries and other text work to. It also writes one-line summaries and, if you like, suggests a worker as you type. Nothing leaves the device.")
            }
            VoiceSettingsSection()
            Section {
                ConnectionFooter()
                Button("Save and Reconnect") {
                    model.save(url: url, device: device, token: token)
                    token = ""
                }
                .disabled(url.isEmpty || device.isEmpty)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear {
            url = model.hubURL
            device = model.device
        }
        #if os(iOS)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        #endif
    }

    private var appleState: String {
        let s = model.apple.status
        guard s.available else {
            switch s.reason {
            case "deviceNotEligible": return "Not supported on this device"
            case "appleIntelligenceNotEnabled": return "Off in Settings"
            case "modelNotReady": return "Getting ready"
            default: return "Unavailable"
            }
        }
        return "Ready · \(s.variant.map { "\($0) · " } ?? "")\((s.contextSize ?? 0).formatted())-token context"
    }
}
