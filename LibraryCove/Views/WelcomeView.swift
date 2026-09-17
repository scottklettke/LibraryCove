import SwiftUI
import SwiftData

/// First-launch welcome flow: three swipeable pages describing what
/// LibraryCove does, then a setup form asking for the user's name and their
/// library's name (prefilled from the name, e.g. "Alex" → "Alex's
/// Library"). The library name is what appears when the library is shared.
struct WelcomeView: View {
    @Environment(\.modelContext) private var modelContext
    /// Called once the profile is created — RootView swaps to the main tabs.
    let onComplete: () -> Void

    @State private var page = 0
    @State private var name = ""
    @State private var libraryName = ""
    @State private var libraryNameEdited = false

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
                        icon: "person.2.fill",
                        title: "Share with family",
                        text: "Share your library with the people you live with over iCloud — everyone can add, edit, and remove books.",
                        tag: 2
                    )
                    welcomePage(
                        icon: "books.vertical",
                        title: "Multiple libraries",
                        text: "Start with one library — you can create more later in Settings > Libraries and switch between them anytime.",
                        tag: 21
                    )
                    setupPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .automatic))
                .indexViewStyle(.page(backgroundDisplayMode: .always))

                Button(page < 3 ? "Continue" : "Create My Library") {
                    if page < 3 {
                        withAnimation { page += 1 }
                    } else {
                        finish()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(page == 3 && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func welcomePage(icon: String, title: String, text: String, tag: Int) -> some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 56))
                .foregroundStyle(.blue)
                .frame(height: 90)
            Text(title)
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Text(text)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 90)
        .tag(tag)
    }

    private var setupPage: some View {
        Form {
            Section("About you") {
                TextField("Your name", text: $name)
                    .textInputAutocapitalization(.words)
                    .onChange(of: name) { _, newValue in
                        // Prefill the library name from the name until the
                        // user edits the library field themselves.
                        if !libraryNameEdited {
                            libraryName = SharedLibrarySettings.defaultShareTitle(for: newValue)
                        }
                    }
            }
            Section {
                TextField("Library name", text: $libraryName)
                    .textInputAutocapitalization(.words)
                    .onChange(of: libraryName) { _, newValue in
                        libraryNameEdited = !newValue.isEmpty &&
                            newValue != SharedLibrarySettings.defaultShareTitle(for: name)
                    }
            } header: {
                Text("Your library")
            } footer: {
                Text("The library name shows up when you share your library with others. You can create more libraries later in Settings > Libraries.")
            }
        }
        .tag(3)
    }

    private func finish() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLibrary = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = User(email: "local@librarycove.local",
                        displayName: trimmedName)
        modelContext.insert(user)
        // The library name chosen here names the DEFAULT library (created
        // at launch by LibraryScope.migrateIfNeeded).
        let chosenName = trimmedLibrary.isEmpty
            ? SharedLibrarySettings.defaultShareTitle(for: trimmedName)
            : trimmedLibrary
        LibraryScope.shared.rename(id: LibraryScope.defaultLibraryID, to: chosenName,
                            context: modelContext)
        SharedLibrarySettings.preferredShareTitle = chosenName
        try? modelContext.save()
        onComplete()
    }

}
