import SwiftUI
import SwiftData

/// "Reorganize shelves": asks the model to propose canonical shelf categories
/// for the library's genre tags, previews the resulting shelf layout
/// (category → book count, with the multi-membership and Other behavior shown),
/// and stores the approved plan. The plan is what "Group by genre" uses.
///
/// This sheet always re-runs the analysis when opened — it is the manual
/// re-run control for when the library grows; automatic regeneration is gated
/// by the plan fingerprint in `LibraryView`.
struct ShelfCategoriesView: View {
    @Environment(\.dismiss) private var dismiss
    let books: [Book]

    private enum Phase: Equatable {
        case loading
        case error(String)
        case ready
    }

    @State private var plan: ShelfCategoryPlan?
    @State private var sections: [(category: String, books: [Book])] = []
    @State private var phase: Phase = .loading
    @State private var applied = false

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Asking AI to organize your shelves…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error(let message):
                    ContentUnavailableView {
                        Label("Couldn't organize shelves", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                            .multilineTextAlignment(.center)
                    } actions: {
                        Button("Retry") {
                            Task { await load() }
                        }
                    }
                case .ready:
                    if sections.isEmpty {
                        ContentUnavailableView(
                            "Nothing to organize",
                            systemImage: "books.vertical",
                            description: Text("Add genre tags to your books first.")
                        )
                    } else {
                        List {
                            Section {
                                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                                    HStack(spacing: 10) {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(section.category)
                                        Spacer()
                                        Text("\(section.books.count)")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            } footer: {
                                Text("Group by genre will organize books under these shelves. A book can appear on more than one shelf; books whose tags don't fit go under Other. You can re-run this later as your library grows.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Reorganize shelves")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if applied {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Use these shelves") { apply() }
                            .disabled(phase != .ready || plan == nil)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func apply() {
        if let plan {
            ShelfCategorizer.store(plan)
        }
        applied = true
    }

    private func load() async {
        phase = .loading
        do {
            let newPlan = try await ShelfCategorizer.generatePlan(books: books)
            plan = newPlan
            sections = ShelfCategorizer.shelfSections(books: books, plan: newPlan) ?? []
            phase = .ready
        } catch let error as AIError {
            switch error {
            case .notConfigured, .engineUnavailable:
                phase = .error("AI isn't ready. Set up an engine in Settings → AI.")
            default:
                phase = .error(error.localizedDescription)
            }
        } catch {
            phase = .error(error.localizedDescription)
        }
    }
}
