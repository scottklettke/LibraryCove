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
    /// Role picked for the link — drives the ShareLibrarySheet's copy
    /// ("grants write access" vs view-only wording).
    /// P2P sheet (admin mode from the context menu, join mode from a
    /// stashed librarycove://join URL).
    @State private var pearsSheetLibrary: LibraryInfo?
    @State private var pearsMode: PearsSyncSheet.Mode = .admin
    @State private var showPearsSheet = false
    @State private var pearsPendingKey: String?
    @State private var membersSheetLibrary: LibraryInfo?
    @State private var shareActionError: String?
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
                        Button {
                                pearsSheetLibrary = library
                                pearsMode = .admin
                            } label: {
                                Label("P2P Sync (beta)", systemImage: "antenna.radiowaves.left.and.right")
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
        .onAppear {
            reload()
            // A librarycove://join URL stashed at launch (or while the app
            // was open) presents the joiner sheet with the invite filled.
            if let key = PearsPendingJoin.shared.consume() {
                pearsMode = .joiner
                pearsSheetLibrary = LibraryInfo(id: "join", name: "Join", isActive: false, createdAt: Date())
                pearsPendingKey = key
                showPearsSheet = true
            }
        }
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
        .sheet(isPresented: $showPearsSheet, onDismiss: {
            pearsSheetLibrary = nil
            pearsPendingKey = nil
        }) {
            if let library = pearsSheetLibrary {
                PearsSyncSheet(mode: pearsMode, library: library, prefillInvite: pearsPendingKey)
            }
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

    /// This device's role in `library` (owner => admin).

    /// Sharing a library: fetch its share (creating it on first share for
    /// admins/editors) and present the sharing sheet. The library becomes
    /// active first — the active library's share is the one that syncs.



    private func bookCount(for library: LibraryInfo) -> Int {
        let id = library.id
        return (try? modelContext.fetchCount(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? 0
    }
}
