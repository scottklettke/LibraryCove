import SwiftUI
import SwiftData

/// "Reorganize shelves": asks the model to (a) propose canonical shelf
/// categories for the library's tags, (b) map every tag to one or more shelves,
/// and (c) classify each tag as Fiction or Non-fiction. The user previews the
/// resulting two-tier organization (Fiction / Non-fiction / Uncategorized →
/// shelves), approves it, and the app stores the plan and writes the proposed
/// Fiction/Non-fiction labels to the books (still editable per book afterward).
///
/// What "shelves" are (shown in-app): AI-proposed, library-specific groupings
/// derived from the books' tags — not a controlled vocabulary, and re-runnable
/// as the library grows. The stored tags themselves are never changed here.
struct ShelfCategoriesView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let books: [Book]

    private enum Phase: Equatable {
        case loading
        case error(String)
        case ready
        case applied
    }

    @State private var plan: ShelfCategoryPlan?
    @State private var tiers: [(top: String, shelves: [ShelfCategorizer.ShelfSection])] = []
    @State private var phase: Phase = .loading
    @State private var liveLog: [String] = []
    @State private var outcome = ""
    @State private var labeledCount = 0

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(liveLog.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
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
                case .ready, .applied:
                    List {
                        Section {
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Shelves are groupings the AI proposes from your library's tags — a small set of categories that cover your collection, with every tag mapped onto one or more of them. They are not your tags: your stored tags are never changed here, and you can re-run this as your library grows. Group by tags then shows Fiction / Non-fiction / Uncategorized, each holding the relevant shelves. A book appears on every shelf its tags map to; anything left over goes under Other so it is never unreachable.")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            } label: {
                                Label("What are shelves?", systemImage: "questionmark.circle")
                                    .font(.subheadline)
                            }
                        }
                        if !outcome.isEmpty {
                            Section {
                                Text(outcome)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        ForEach(tiers, id: \.top) { tier in
                            Section(tier.top) {
                                ForEach(tier.shelves, id: \.shelf) { shelfSection in
                                    HStack {
                                        Text(shelfSection.shelf)
                                        Spacer()
                                        Text("\(shelfSection.books.count)")
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                }
                            }
                        }
                        if tiers.isEmpty {
                            ContentUnavailableView(
                                "Nothing to organize",
                                systemImage: "books.vertical",
                                description: Text("Add tags to your books first.")
                            )
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
                    switch phase {
                    case .applied:
                        Button("Done") { dismiss() }
                    case .ready:
                        Button("Use these shelves") { apply() }
                            .disabled(plan == nil)
                    default:
                        EmptyView()
                    }
                }
            }
        }
        .task { await load() }
    }

    private func apply() {
        guard let plan else { return }
        ShelfCategorizer.store(plan)
        // Write the model's proposed Fiction/Non-fiction labels (still editable
        // per-book in the form; a book is only labeled when the model is
        // confident via a tag majority).
        var changed = 0
        for book in books {
            guard let proposed = ShelfCategorizer.proposedKind(for: book, plan: plan),
                  book.kind != proposed.rawValue else { continue }
            book.kind = proposed.rawValue
            changed += 1
        }
        if changed > 0 { try? modelContext.save() }
        labeledCount = changed
        outcome = "Saved. \(tiers.reduce(0) { $0 + $1.shelves.count }) shelf groups; fiction/non-fiction proposed for \(changed) book\(changed == 1 ? "" : "s")."
        phase = .applied
    }

    private func load() async {
        phase = .loading
        liveLog = ["Reading \(books.count) book\(books.count == 1 ? "" : "s")…"]
        do {
            liveLog.append("Asking the AI model to propose shelves and fiction/non-fiction…")
            let newPlan = try await ShelfCategorizer.generatePlan(books: books)
            plan = newPlan
            tiers = ShelfCategorizer.twoTierSections(books: books, plan: newPlan) ?? []
            let mappedTags = newPlan.mappings.count
            liveLog.append("Model returned \(mappedTags) tag mappings across \(newPlan.mappings.reduce(Set<String>()) { $0.union($1.categories) }.count) shelves.")
            let bookCount = books.count
            let kinded = books.filter { ShelfCategorizer.proposedKind(for: $0, plan: newPlan) != nil }.count
            outcome = "Preview: \(bookCount) book\(bookCount == 1 ? "" : "s"); \(kinded) would get a fiction/non-fiction label. Nothing is changed until you tap Use these shelves."
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
