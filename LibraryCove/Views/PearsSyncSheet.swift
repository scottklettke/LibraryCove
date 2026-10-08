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
    @State private var qrImage: UIImage?
    @State private var showQR = false
    @State private var qrPayload: String = ""
    @State private var showIdentityJoin = false
    @State private var identityJoinInput = ""
    @State private var identityUnlocked = false
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
                advancedSection
            }
            .navigationTitle(mode == .admin ? "Connect Devices — \(library.name)" : "Connect to a Library")
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
            if mode == .admin {
                // The sheet is reachable before the engine boots (fresh
                // install → Libraries → P2P Sync): start it now, else
                // generateJoinKey's guards silently return nil — the
                // reported "Create join link does nothing".
                if !engine.isRunning, let active = LibraryScope.shared.active(context: modelContext),
                   let member = (try? modelContext.fetch(FetchDescriptor<User>(
                       predicate: #Predicate { $0.isActive }
                   )))?.first {
                    engine.start(libraryID: active.id, memberName: member.displayName)
                }
                engine.refreshJoinKeys()
            }
        }
    }

    // MARK: - Admin

    @ViewBuilder private var adminSections: some View {
        Section {
            if !identityUnlocked {
                Button {
                    PearsAuth.authenticate(reason: "Unlock device linking — this controls the whole library") { ok in
                        identityUnlocked = ok
                    }
                } label: {
                    Label("Unlock with Face ID / Touch ID", systemImage: "faceid")
                }
            }
            if identityUnlocked {
            LabeledContent("Identity key (not the invite)", value: engine.currentDriveKey ?? "—")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
            Button {
                // Auto-issue a pending token if none exists, so this
                // button ALWAYS produces a usable device-link invite.
                if !engine.joinKeys.contains(where: { $0.state == .pending }) {
                    _ = engine.generateJoinKey(role: .admin)
                }
                if let key = engine.currentDriveKey,
                   let pending = engine.joinKeys.first(where: { $0.state == .pending }) {
                    UIPasteboard.general.string = "lc1.\(key).\(pending.code)"
                }
            } label: {
                Label("Copy device-link invite", systemImage: "link")
            }
            .disabled(engine.currentDriveKey == nil)
            Button {
                if let key = engine.currentDriveKey,
                   let pending = engine.joinKeys.first(where: { $0.state == .pending }) {
                    let invite = "lc1.\(key).\(pending.code)"
                    qrPayload = invite
                    qrImage = PearsQR.image(for: invite, scale: 8)
                    showQR = qrImage != nil
                }
            } label: {
                Label("Show device-link QR", systemImage: "qrcode")
            }
            .disabled(engine.currentDriveKey == nil || !engine.joinKeys.contains(where: { $0.state == .pending }))
            if engine.joinKeys.contains(where: { $0.state == .pending }) == false {
                Text("Create a join link first — the device-link QR wraps it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                showIdentityJoin = true
            } label: {
                Label("Link another identity (two-way sync)", systemImage: "person.2.wave.2")
            }
            }
        } header: {
            Text("Connect my devices")
        } footer: {
            Text("This identity links your OWN devices: your name, AI settings, library list, and all your libraries' content sync. For sharing ONE library with someone else, use 'Share a library invite' below. Create a join link, then show its QR on the new device.")
        }

        Section {
            Picker("Link grants", selection: $pickedRole) {
                Text("Editor - can edit").tag(PearsJoinKey.Role.editor)
                Text("Guest - view only").tag(PearsJoinKey.Role.guest)
                Text("Admin - full control").tag(PearsJoinKey.Role.admin)
            }
            Button {
                generatedInvite = engine.generateJoinKey(role: pickedRole)
                if generatedInvite == nil { engine.refreshJoinKeys() }
            } label: {
                Label("Create join link", systemImage: "link.badge.plus")
            }
            .disabled(!engine.isRunning || engine.currentDriveKey == nil)
            if !engine.isRunning || engine.currentDriveKey == nil {
                Text(engine.isRunning ? "Starting the sync engine — try again in a moment…" : "The sync engine isn't running yet — it starts when you open this page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Share a library invite")
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
                Button {
                    qrImage = PearsQR.image(for: invite)
                    showQR = qrImage != nil
                } label: {
                    Label("Show QR code", systemImage: "qrcode")
                }
                .sheet(isPresented: $showQR) {
                    VStack(spacing: 16) {
                        Text("Scan with the joining device")
                            .font(.headline)
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 260)
                                .accessibilityLabel("Join QR code")
                        }
                        Text(qrPayload)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(2)
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                    .presentationDetents([.medium])
                }
        .sheet(isPresented: $showIdentityJoin) {
            // Two-way identity link: the other identity owner shares THEIR
            // device-link invite; both sides end up in each other's
            // drives. Uses the same join machinery — the invite exchange
            // is symmetric.
            NavigationStack {
                Form {
                    Section {
                        TextField("Their device-link invite (lc1.…)", text: $identityJoinInput)
                            .font(.system(size: 12, design: .monospaced))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button {
                            engine.joinWithKey(identityJoinInput, memberName: memberName)
                            showIdentityJoin = false
                        } label: {
                            Label("Link identities", systemImage: "person.2.wave.2")
                        }
                        .disabled(identityJoinInput.isEmpty)
                    } header: {
                        Text("Link an identity")
                    } footer: {
                        Text("Both libraries' books and settings sync both ways — nothing on either device is lost. Ask the other person to link back with YOUR invite (Device Sync & Sharing → Link another identity) to complete the two-way connection. The invite is the FULL string from their 'Create join link' — not the bare identity key.")
                    }
                    if let error = engine.lastError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .navigationTitle("Link Identity")
                .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium])
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
            Text("Library invites")
        } footer: {
            Text("Revoking stops a link from ever being used. A member who already joined keeps access until the library's keys are rotated.")
        }
    }

    /// Advanced: what the P2P layer is actually doing. Same section for
    /// admin and joiner — it describes THIS device's engine.
    private var advancedSection: some View {
        Section {
            LabeledContent("Engine", value: engine.isRunning ? "Running" : "Stopped")
            LabeledContent("Drive key", value: engine.currentDriveKey.map { String($0.prefix(12)) + "…" } ?? "—")
                .textSelection(.enabled)
            LabeledContent("This device", value: engine.deviceTag)
            LabeledContent("Connected peers", value: "\(engine.peers)")
            LabeledContent("Last sync", value: engine.lastSyncAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "Never")
            if engine.isSyncing {
                LabeledContent("Sync now") { ProgressView().controlSize(.small) }
            }
            if !engine.counts.isEmpty {
                ForEach(engine.counts.keys.sorted(), id: \.self) { dir in
                    LabeledContent(dir, value: "\(engine.counts[dir] ?? 0)")
                }
            }
            if let error = engine.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            if !engine.consoleLines.isEmpty {
                DisclosureGroup("Worklet console (\(engine.consoleLines.count) lines)") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(engine.consoleLines.enumerated().reversed()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 220)
                }
            }
        } header: {
            Text("Advanced — P2P network")
        } footer: {
            Text("Counts are what the drive currently holds per directory. Peers = devices connected right now. The engine polls for changes every 1.5s while a peer is connected.")
        }
    }


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
            Text("Connect to a shared library")
        } footer: {
            Text("Ask the owner to create a join link and send it. The owner needs to be online when you join. If the link was already used or revoked, you will see this library read-only or nothing at all. If you already have libraries, link from the P2P page instead - both sides keep their libraries and sync two-way.")
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
