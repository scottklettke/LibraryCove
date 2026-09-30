import SwiftUI
import SwiftData
import CloudKit

/// Library management: list of libraries with the active one checked, create
/// new, switch, and delete non-active libraries. Lives under Settings >
/// Library.
struct LibraryListView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var libraries: [LibraryInfo] = []
    @State private var showCreate = false
    @State private var newLibraryName = ""
    @State private var libraryToDelete: LibraryInfo?
    @State private var createError: String?
    @State private var renameTarget: LibraryInfo?
    @State private var renameText = ""
    @State private var renameError: String?
    @State private var shareSheetLibrary: LibraryInfo?
    @State private var shareSheetShare: CKShare?
    @State private var membersSheetLibrary: LibraryInfo?
    @State private var shareActionError: String?
    @State private var leaveConfirmLibrary: LibraryInfo?
    @State private var stopConfirmLibrary: LibraryInfo?
    /// First-share role picker: what the LINK grants (admin/editor/guest),
    /// shown before the system sharing sheet on this path too.
    @State private var showLinkRolePicker = false
    @State private var pendingLinkRole: ShareParticipantRole = .editor

    var body: some View {
        Form {
            Section {
                if libraries.isEmpty {
                    Text("No libraries yet. Create one below to start adding books.")
                        .foregroundStyle(.secondary)
                }
                ForEach(libraries) { library in
                    // Render activeness from the device's activeID, not the
                    // registry row's flag: the flag is mirrored state that a
                    // remote fold can duplicate — activeID is this device's
                    // truth. (Stale double-flags also swallowed taps via the
                    // old `if !isActive` guard.)
                    let isActive = library.id == LibraryScope.shared.activeID
                    Button {
                        if !isActive {
                            LibraryScope.shared.activate(library, context: modelContext)
                            reload()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.name.isEmpty ? "Untitled Library" : library.name)
                                    .font(isActive ? .body.bold() : .body)
                                Text("\(bookCount(for: library)) books")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isActive {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.blue)
                            }
                        }
                    }
                    .contextMenu {
                        Button {
                            renameTarget = library
                            renameText = library.name
                        } label: {
                            Label("Rename library", systemImage: "pencil")
                        }
                        if !isActive {
                            Button(role: .destructive) {
                                libraryToDelete = library
                            } label: {
                                Label("Delete library", systemImage: "trash")
                            }
                        }
                        // Shared-library controls (role-dependent):
                        // guests view only, editors share links, admins
                        // also manage members and stop sharing.
                        if isShared(library) {
                            Button {
                                Task { await shareOrMembers(library) }
                            } label: {
                                Label("Members", systemImage: "person.2")
                            }
                            if myRole(in: library) != .guest {
                                Button {
                                    Task { await shareOrMembers(library) }
                                } label: {
                                    Label("Share library", systemImage: "person.crop.square.badge.plus")
                                }
                            }
                            if myRole(in: library) == .admin {
                                Button(role: .destructive) {
                                    stopConfirmLibrary = library
                                } label: {
                                    Label("Stop sharing", systemImage: "person.crop.square.badge.minus")
                                }
                            }
                            if SharedLibrarySettings.membership(libraryID: library.id) == .participant {
                                Button(role: .destructive) {
                                    leaveConfirmLibrary = library
                                } label: {
                                    Label("Leave shared library", systemImage: "figure.walk.arrow.right")
                                }
                            }
                        } else {
                            Button {
                                Task { await shareOrMembers(library) }
                            } label: {
                                Label("Share library", systemImage: "person.crop.square.badge.plus")
                            }
                        }
                    }
                }
            } header: {
                Text("Your libraries")
            } footer: {
                Text("Switching libraries changes which books you see. Each library keeps its own books, notes, and reading lists. Long-press to rename the active library or delete a non-active one.")
            }

            Section {
                Button {
                    showCreate = true
                } label: {
                    Label("New library", systemImage: "plus")
                }
            } footer: {
                Text("Creating a library switches to it. Your current library stays saved — back it up first if you want a snapshot.")
            }
        }
        .navigationTitle("Libraries")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reload() }
        // Remote folds (another device's rename/create/delete) post
        // librariesChangedNotification without this view leaving the
        // screen — refresh the visible list instead of showing a stale
        // "Untitled Library" until the next onAppear.
        .onReceive(NotificationCenter.default.publisher(for: LibraryScope.librariesChangedNotification)) { _ in
            reload()
        }
        .alert("Couldn't create library", isPresented: Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createError ?? "")
        }
        .sheet(isPresented: Binding(
            get: { shareSheetShare != nil },
            set: { if !$0 { shareSheetShare = nil; shareSheetLibrary = nil } }
        )) {
            if let share = shareSheetShare,
               let library = shareSheetLibrary, !library.id.isEmpty {
                CloudSharingSheet(share: share, libraryID: library.id)
            }
        }
        .sheet(isPresented: Binding(
            get: { membersSheetLibrary != nil },
            set: { if !$0 { membersSheetLibrary = nil } }
        )) {
            if let library = membersSheetLibrary {
                LibraryMembersSheet(libraryID: library.id,
                                    libraryName: library.name)
            }
        }
        .alert("Leave this shared library?", isPresented: Binding(
            get: { leaveConfirmLibrary != nil },
            set: { if !$0 { leaveConfirmLibrary = nil } }
        )) {
            Button("Leave", role: .destructive) {
                if let library = leaveConfirmLibrary {
                    Task {
                        LibraryScope.shared.activate(libraryInfoForLeaving(library), context: modelContext)
                        try? await SharedLibraryCoordinator.leave(keepCopy: true)
                        reload()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A copy of the shared books will be kept in this library.")
        }
        .alert("Stop sharing?", isPresented: Binding(
            get: { stopConfirmLibrary != nil },
            set: { if !$0 { stopConfirmLibrary = nil } }
        )) {
            Button("Stop Sharing", role: .destructive) {
                if let library = stopConfirmLibrary {
                    Task {
                        LibraryScope.shared.activate(libraryInfoForLeaving(library), context: modelContext)
                        try? await SharedLibraryCoordinator.stopSharing()
                        reload()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everyone loses access to this shared library. Your copy is kept.")
        }
        .alert("Sharing error", isPresented: Binding(
            get: { shareActionError != nil },
            set: { if !$0 { shareActionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(shareActionError ?? "")
        }
        .sheet(isPresented: $showLinkRolePicker) {
            NavigationStack {
                Form {
                    Section {
                        Picker("Link access", selection: $pendingLinkRole) {
                            Text("Admin — full control").tag(ShareParticipantRole.admin)
                            Text("Editor — can edit").tag(ShareParticipantRole.editor)
                            Text("Guest — view only").tag(ShareParticipantRole.guest)
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("Who can use this link?")
                    } footer: {
                        Text("Anyone who joins through this link gets this role. You can change each member's role later in Members.")
                    }
                    Section {
                        Button {
                            Task { await createShareWithPickedRole() }
                        } label: {
                            Text("Continue").frame(maxWidth: .infinity)
                        }
                    }
                }
                .navigationTitle("Share Library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showLinkRolePicker = false }
                    }
                }
                .interactiveDismissDisabled(false)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $showCreate) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Library name", text: $newLibraryName)
                    } footer: {
                        Text("It starts empty; your current library stays saved and switchable. Creating it makes it the active library.")
                    }
                    Section {
                        Button {
                            let name = newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            // Duplicate names make the Libraries list and
                            // backup origins ambiguous — refuse with a hint.
                            if libraries.contains(where: {
                                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                            }) {
                                createError = "A library named \"\(name)\" already exists. Pick a different name."
                                return
                            }
                            do {
                                _ = try LibraryScope.shared.create(
                                    name: name, makeActive: true, context: modelContext)
                                newLibraryName = ""
                                showCreate = false
                                reload()
                            } catch {
                                createError = error.localizedDescription
                            }
                        } label: {
                            Text("Create library")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(newLibraryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationTitle("New library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            newLibraryName = ""
                            showCreate = false
                        }
                    }
                }
                .interactiveDismissDisabled(false)
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            NavigationStack {
                Form {
                    Section {
                        TextField("Library name", text: $renameText)
                    } footer: {
                        Text("Renaming keeps all of this library's books, notes, and reading lists.")
                    }
                    Section {
                        Button {
                            let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty, let target = renameTarget else { return }
                            // Duplicate names make the Libraries list and
                            // backup origins ambiguous — refuse.
                            if libraries.contains(where: {
                                $0.id != target.id
                                    && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                            }) {
                                renameError = "A library named \"\(name)\" already exists. Pick a different name."
                                return
                            }
                            LibraryScope.shared.rename(id: target.id, to: name, context: modelContext)
                            renameTarget = nil
                            renameText = ""
                            reload()
                        } label: {
                            Text("Rename library")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .navigationTitle("Rename library")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            renameTarget = nil
                            renameText = ""
                        }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .alert("Couldn't rename", isPresented: Binding(
            get: { renameError != nil },
            set: { if !$0 { renameError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameError ?? "")
        }
        .alert("Delete this library?", isPresented: Binding(
            get: { libraryToDelete != nil },
            set: { if !$0 { libraryToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let library = libraryToDelete {
                    LibraryScope.shared.delete(library, context: modelContext)
                    reload()
                }
                libraryToDelete = nil
            }
            Button("Cancel", role: .cancel) { libraryToDelete = nil }
        } message: {
            if let library = libraryToDelete {
                Text("“\(library.name)” and all of its books, notes, and reading lists will be deleted. This cannot be undone. Consider backing it up first (Backups > Back up library now while it's active).")
            }
        }
    }

    private func reload() {
        libraries = LibraryScope.shared.all(context: modelContext)
    }

    /// True when this library currently participates in a share (either
    /// side) — controls which context-menu items render.
    private func isShared(_ library: LibraryInfo) -> Bool {
        SharedLibrarySettings.sharedLibraryIDs.contains(library.id)
            && SharedLibrarySettings.membership(libraryID: library.id) != .none
    }

    /// This device's role in `library` (owner => admin).
    private func myRole(in library: LibraryInfo) -> ShareParticipantRole {
        SharedLibraryEngine.shared.myRole(libraryID: library.id)
    }

    /// Sharing a library: fetch its share (creating it on first share for
    /// admins/editors) and present the sharing sheet. The library becomes
    /// active first — the active library's share is the one that syncs.
    private func shareOrMembers(_ library: LibraryInfo) async {
        LibraryScope.shared.activate(library, context: modelContext)
        reload()
        do {
            if let share = try await SharedLibraryEngine.shared.currentShare(libraryID: library.id) {
                shareSheetShare = share
                shareSheetLibrary = library
            } else {
                // First share from the list: same role pre-picker as
                // Settings (the link's default role must be chosen before
                // the system sheet opens). The active library IS this one
                // (activate above), and createShareWithPickedRole finishes
                // the flow.
                pendingLinkRole = SharedLibrarySettings.linkDefaultRole(libraryID: library.id)
                showLinkRolePicker = true
            }
        } catch {
            shareActionError = error.localizedDescription
        }
    }

    /// Role pre-sheet's Continue: create the share with the picked link
    /// role and present the system sharing sheet for the (now active)
    /// library.
    private func createShareWithPickedRole() async {
        guard let library = LibraryScope.shared.active(context: modelContext) else {
            showLinkRolePicker = false
            return
        }
        do {
            SharedLibrarySettings.setLinkDefaultRole(pendingLinkRole, libraryID: library.id)
            let share = try await SharedLibraryCoordinator.beginShare(
                currentTitle: library.name,
                libraryID: library.id,
                linkRole: pendingLinkRole)
            shareSheetShare = share
            shareSheetLibrary = library
            showLinkRolePicker = false
        } catch {
            shareActionError = error.localizedDescription
            showLinkRolePicker = false
        }
    }

    /// Leave/stop target the ACTIVE library's share: activate the chosen
    /// library first so the coordinator operates on the right one.
    private func libraryInfoForLeaving(_ library: LibraryInfo) -> LibraryInfo {
        LibraryScope.shared.activate(library, context: modelContext)
        reload()
        return library
    }

    private func bookCount(for library: LibraryInfo) -> Int {
        let id = library.id
        return (try? modelContext.fetchCount(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? 0
    }
}
