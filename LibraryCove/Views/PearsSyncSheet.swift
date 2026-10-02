import SwiftUI
import SwiftData

/// Pears P2P sharing sheet — admin and joiner sides.
///
/// Admin (library owner): generate single-use join tokens, see
/// pending/used/revoked with the member names that redeemed them,
/// revoke pending ones.
///
/// Joiner: paste the invite (lc1.<driveKey>.<token>) or arrive via
/// librarycove://join?key=... — the engine handles both identically.
/// A failed redemption leaves the device read-only (the guest state).
struct PearsSyncSheet: View {
    enum Mode { case admin, joiner }

    let mode: Mode
    let library: LibraryInfo
    var prefillInvite: String? = nil
    @State private var inviteInput = ""
    @State private var memberName = ""
    @State private var generatedInvite: String?
    @State private var pickedRole: PearsJoinKey.Role = .editor
    @State private var copied = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engine = PearsSyncEngine.shared

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .admin: adminSections
                case .joiner: joinerSections
                }
            }
            .navigationTitle(mode == .admin ? "P2P Sync — \(library.name)" : "Join Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            memberName = currentMemberName()
            if let prefill = prefillInvite { inviteInput = prefill }
            if mode == .admin { engine.refreshJoinKeys() }
        }
    }

    // MARK: - Admin

    @ViewBuilder private var adminSections: some View {
        Section {
            Picker("Link grants", selection: $pickedRole) {
                Text("Editor - can edit").tag(PearsJoinKey.Role.editor)
                Text("Guest - view only").tag(PearsJoinKey.Role.guest)
                Text("Admin - full control").tag(PearsJoinKey.Role.admin)
            }
            Button {
                generatedInvite = engine.generateJoinKey(role: pickedRole)
            } label: {
                Label("Create join link", systemImage: "link.badge.plus")
            }
        } header: {
            Text("Invite a member")
        } footer: {
            Text("Each link works exactly once. The owner must be online when the member joins - the key that grants write access is handed over directly, never sent in the message.")
        }

        if let invite = generatedInvite {
            Section {
                HStack {
                    Text(invite)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(3)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = invite
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }
                if let url = URL(string: "librarycove://join?key=\(invite)") {
                    ShareLink(item: url) {
                        Label("Send link...", systemImage: "paperplane")
                    }
                }
            } header: {
                Text("Send this - works once")
            } footer: {
                Text("Text, email, anything. The recipient taps it and LibraryCove opens the join screen with the key filled in.")
            }
        }

        Section {
            if engine.joinKeys.isEmpty {
                Text("No join links yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.joinKeys) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key.role.rawValue.capitalized)
                                .font(.subheadline)
                            switch key.state {
                            case .pending:
                                Text("Waiting for someone to join")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .used:
                                Text("Used by \(key.usedBy ?? "someone")")
                                    .font(.caption).foregroundStyle(.secondary)
                            case .revoked:
                                Text("Revoked")
                                    .font(.caption).foregroundStyle(.red)
                            }
                        }
                        Spacer()
                        if key.state == .pending {
                            Button(role: .destructive) {
                                engine.revokeJoinKey(key.code)
                            } label: {
                                Text("Revoke")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        } header: {
            Text("Join links")
        } footer: {
            Text("Revoking stops a link from ever being used. A member who already joined keeps access until the library's keys are rotated.")
        }
    }

    // MARK: - Joiner

    @ViewBuilder private var joinerSections: some View {
        Section {
            TextField("Your display name", text: $memberName)
            TextField("Paste the invite (lc1....)", text: $inviteInput)
                .font(.system(size: 12, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button {
                engine.joinWithKey(inviteInput, memberName: memberName)
            } label: {
                Label("Join library", systemImage: "person.badge.plus")
            }
            .disabled(inviteInput.isEmpty || memberName.isEmpty)
        } header: {
            Text("Join a shared library")
        } footer: {
            Text("Ask the owner to create a join link and send it. The owner needs to be online when you join. If the link was already used or revoked, you will see this library read-only or nothing at all.")
        }

        if let error = engine.lastError {
            Section {
                Text(error).foregroundStyle(.red).font(.footnote)
            }
        }
    }

    private func currentMemberName() -> String {
        (try? modelContext.fetch(FetchDescriptor<User>(
            predicate: #Predicate { $0.isActive }
        )))?.first?.displayName ?? ""
    }
}
