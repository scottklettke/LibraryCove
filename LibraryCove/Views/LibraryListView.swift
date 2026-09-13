import SwiftUI
import SwiftData

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

    var body: some View {
        Form {
            Section {
                ForEach(libraries) { library in
                    let isActive = library.isActive
                    Button {
                        if !isActive {
                            LibraryScope.activate(library, context: modelContext)
                            reload()
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(library.name.isEmpty ? "Untitled Library" : library.name)
                                    .font(.body)
                                Text(isActive ? "Active" : "\(bookCount(for: library)) books")
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
                        if !isActive {
                            Button(role: .destructive) {
                                libraryToDelete = library
                            } label: {
                                Label("Delete library", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Your libraries")
            } footer: {
                Text("Switching libraries changes which books you see. Each library keeps its own books, notes, and reading lists. Tap and hold a non-active library to delete it.")
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
        .alert("Couldn't create library", isPresented: Binding(
            get: { createError != nil },
            set: { if !$0 { createError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(createError ?? "")
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
                            do {
                                _ = try LibraryScope.create(
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
        .alert("Delete this library?", isPresented: Binding(
            get: { libraryToDelete != nil },
            set: { if !$0 { libraryToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let library = libraryToDelete {
                    LibraryScope.delete(library, context: modelContext)
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
        libraries = LibraryScope.all(context: modelContext)
    }

    private func bookCount(for library: LibraryInfo) -> Int {
        let id = library.id
        return (try? modelContext.fetchCount(FetchDescriptor<Book>(
            predicate: #Predicate { $0.libraryID == id }
        ))) ?? 0
    }
}
