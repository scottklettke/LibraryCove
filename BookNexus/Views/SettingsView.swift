import SwiftUI
import SwiftData

/// Settings screen: shows current family member and sync/AI provider state.
struct SettingsView: View {
    let user: User
    @State private var showSync = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    LabeledContent("Name", value: user.displayName)
                    LabeledContent("Email", value: user.email)
                }
                Section("Sync") {
                    LabeledContent("Provider", value: "iCloud / CloudKit (planned)")
                    LabeledContent("Status", value: "Local-only")
                }
                Section("AI") {
                    LabeledContent("Inference", value: "Local model or endpoint")
                }
            }
            .navigationTitle("Settings")
        }
    }
}
