import SwiftUI
import SwiftData

/// First-launch flow. Three paths, chosen on page 4 (setup):
///
/// 1. **Create a new library** — this device becomes the OWNER: the
///    worklet creates the drive, persists the primary-key credential,
///    and the member row is minted locally. The library name is the
///    drive's identity; the member name is what join redemptions record.
/// 2. **Join with a key** — paste an `lc1.<drive>.<token>` invite.
///    Redemption over the control channel grants write access; the
///    member row is written into the replicated store.
/// 3. **Scan a QR code** — the same invite, delivered as a QR (the
///    owner's sheet shows "Show QR" alongside Copy/Send).
///
/// The old name+library-name form becomes part of path 1: the member
/// name IS the identity the other devices see; the library name names
/// the drive.
struct WelcomeView: View {
    @Environment(\.modelContext) private var modelContext
    /// Called once the profile is created — RootView swaps to the main tabs.
    let onComplete: () -> Void

    enum Path: Hashable { case create, joinKey, joinQR }

    @State private var page = 0
    @State private var name = ""
    @State private var libraryName = ""
    @State private var libraryNameEdited = false
    @State private var selectedPath: Path?
    @State private var inviteInput = ""
    @State private var showScanner = false
    @ObservedObject private var engine = PearsSyncEngine.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcomePage(
                        icon: "books.vertical.fill",
                        title: "Welcome to LibraryCove",
                        text: "Catalog the books you own — scan a barcode or search by title — and organize them your way.",
                        tag: 0
                    )
                    welcomePage(
                        icon: "sparkles",
                        title: "Get help from AI",
                        text: "Ask questions about your collection, get reading suggestions, and let AI suggest genres and categories.",
                        tag: 1
                    )
                    welcomePage(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "Sync without a server",
                        text: "Your devices sync directly to each other, encrypted end-to-end — no account, no cloud middleman. Backups stay yours.",
                        tag: 2
                    )
                    welcomePage(
                        icon: "books.vertical",
                        title: "Multiple libraries",
                        text: "Start with one library — you can create more later in Settings > Libraries and switch between them anytime.",
                        tag: 3
                    )
                    setupPage.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button(page < 4 ? "Continue" : primaryButtonTitle) {
                    if page < 4 {
                        withAnimation { page += 1 }
                    } else {
                        switch selectedPath {
                        case .create: finishCreate()
                        case .joinKey, .joinQR: finishJoin()
                        case .none: break
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(page == 4 && !setupInputValid)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .sheet(isPresented: $showScanner) {
                // The barcode scanner emits ANY machine-readable code; the
                // join path validates the lc1 format itself. A QR payload
                // is the full invite (or a librarycove://join URL).
                ISBNScannerView { code in
                    let cleaned = code
                        .replacingOccurrences(of: "librarycove://join?key=", with: "")
                    if cleaned.hasPrefix("lc1.") {
                        inviteInput = cleaned
                        showScanner = false
                    }
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var setupInputValid: Bool {
        let hasName = !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        switch selectedPath {
        case .create: return hasName
        case .joinKey, .joinQR:
            return hasName && !inviteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .none: return false
        }
    }

    private var primaryButtonTitle: String {
        switch selectedPath {
        case .create: return "Create My Library"
        case .joinKey, .joinQR: return "Join Library"
        case .none: return "Continue"
        }
    }

    /// The setup page: path choice first, then path-specific fields.
    private var setupPage: some View {
        Form {
            Section("About you") {
                TextField("Your name", text: $name)
            }

            Section {
                Picker("This device will", selection: pathBinding) {
                    Text("Create a new library").tag(Path.create)
                    Text("Join an existing library").tag(Path.joinKey)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("Set up sync")
            } footer: {
                Text("Sync runs device-to-device over Pears — encrypted, no account. Create here to be the owner, or join a library someone shared.")
            }

            if selectedPath == .create {
                Section {
                    TextField("Library name", text: $libraryName)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                } header: {
                    Text("Your library")
                } footer: {
                    Text("The library name shows up when you share with others. You can create more libraries later in Settings > Libraries.")
                }
            }

            if selectedPath == .joinKey || selectedPath == .joinQR {
                Section {
                    TextField("Invite (lc1.…)", text: $inviteInput)
                        .font(.system(size: 12, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button {
                        showScanner = true
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                    }
                } header: {
                    Text("Invite")
                } footer: {
                    Text("The owner creates this in their P2P Sync page — each invite works exactly once, and the owner must be online when you join. Scanning fills the field; the owner's P2P page can show the code.")
                }
            }
        }
        .tag(4)
    }

    /// The picker drives the path; QR is join-with-key delivered visually,
    /// so the camera flow lands in the same invite field.
    private var pathBinding: Binding<Path> {
        Binding(
            get: { selectedPath ?? .create },
            set: { selectedPath = ($0 == .joinQR) ? .joinKey : $0 }
        )
    }

    // MARK: - Actions

    /// Path 1: this device owns a new library.
    private func finishCreate() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLibrary = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let derived = SharedLibrarySettings.defaultShareTitle(for: trimmedName)
        let chosenName = trimmedLibrary.isEmpty ? derived : trimmedLibrary

        _ = MemberIdentity.createPrimaryMember(
            displayName: trimmedName,
            email: "local@librarycove.local",
            context: modelContext)
        let library: LibraryInfo
        if let active = LibraryScope.shared.active(context: modelContext) {
            if active.name.isEmpty {
                LibraryScope.shared.rename(id: active.id, to: chosenName, context: modelContext)
            }
            library = active
        } else {
            library = (try? LibraryScope.shared.create(name: chosenName, makeActive: true,
                                                       context: modelContext)) ?? LibraryInfo(
                id: LibraryScope.defaultLibraryID, name: chosenName,
                isActive: true, createdAt: Date())
        }
        SharedLibrarySettings.preferredShareTitle = chosenName
        try? modelContext.save()
        // Boot the engine as OWNER — the worklet creates the drive and
        // persists its credential. The welcome completes; sync begins.
        PearsSyncEngine.shared.start(libraryID: library.id, memberName: trimmedName)
        onComplete()
    }

    /// Paths 2/3: join an existing library via the invite (typed or QR).
    private func finishJoin() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mint the local member row (the mirrored store adopts it after
        // the first pull; the redemption handshake records the name).
        _ = MemberIdentity.createPrimaryMember(
            displayName: trimmedName,
            email: "local@librarycove.local",
            context: modelContext)
        try? modelContext.save()
        PearsSyncEngine.shared.joinWithKey(inviteInput, memberName: trimmedName)
        onComplete()
    }
}

/// One icon+title+text page of the intro carousel.
private func welcomePage(icon: String, title: String, text: String, tag: Int) -> some View {
    VStack(spacing: 18) {
        Image(systemName: icon)
            .font(.system(size: 56))
            .foregroundStyle(.blue)
        Text(title)
            .font(.title2.bold())
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
    }
    .tag(tag)
}
