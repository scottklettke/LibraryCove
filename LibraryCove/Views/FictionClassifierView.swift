import SwiftUI
import SwiftData

/// "Classify fiction/non-fiction": asks the model to propose Fiction /
/// Non-fiction for every book that isn't labeled yet, shows each proposal as a
/// toggleable row for the user to approve, and writes only the approved ones.
/// Existing manual labels are never overwritten.
struct FictionClassifierView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let books: [Book]

    private enum Phase: Equatable {
        case loading
        case error(String)
        case ready
    }

    /// Row keyed by absolute index into `proposals`.
    @State private var proposals: [BookKindProposal] = []
    @State private var rows: [(bookID: String, kind: String)] = []
    @State private var selected = Set<Int>()
    @State private var phase: Phase = .loading
    @State private var completed = false
    @State private var liveLog: [String] = []
    @State private var outcome = ""

    private var unclassifiedCount: Int { books.filter { $0.kind.isEmpty }.count }

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
                        Label("Couldn't classify books", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                            .multilineTextAlignment(.center)
                    } actions: {
                        Button("Retry") {
                            Task { await load() }
                        }
                    }
                case .ready:
                    if rows.isEmpty {
                        ContentUnavailableView(
                            "Nothing to classify",
                            systemImage: "checkmark.seal",
                            description: Text("Every book already has a fiction/non-fiction label.")
                        )
                    } else {
                        List {
                            if !outcome.isEmpty {
                                Section {
                                    Text(outcome)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Section {
                                ForEach(Array((0..<rows.count)), id: \.self) { index in
                                    row(index)
                                }
                            } footer: {
                                Text("Review each proposal before applying. Books you skip keep their current (or missing) label. Full request/response detail is in Settings → AI logs.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Classify fiction / non-fiction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if completed {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Apply (\(selected.count))") { apply() }
                            .disabled(selected.isEmpty || phase != .ready)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func row(_ index: Int) -> some View {
        let isOn = selected.contains(index)
        let item = rows[index]
        let kindLabel = BookKind(rawValue: item.kind)?.displayName ?? "Unclassified"
        let bookTitle = title(for: item.bookID) ?? "Unknown book"
        return HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? Color.accentColor : Color(uiColor: .secondaryLabel))
            VStack(alignment: .leading, spacing: 2) {
                Text(bookTitle)
                    .lineLimit(1)
                Text(kindLabel)
                    .font(.caption)
                    .foregroundStyle(kindLabel == "Fiction" ? .primary : .secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn { selected.remove(index) } else { selected.insert(index) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var booksByID: [String: Book] {
        var out: [String: Book] = [:]
        for book in books where out[book.id] == nil { out[book.id] = book }
        return out
    }

    private func title(for id: String) -> String? {
        booksByID[id]?.title
    }

    private func apply() {
        let picked = selected.sorted().compactMap { index -> BookKindProposal? in
            guard rows.indices.contains(index) else { return nil }
            let r = rows[index]
            return BookKindProposal(bookID: r.bookID, kind: r.kind)
        }
        let changed = FictionClassifier.apply(picked, to: books, context: modelContext)
        outcome = "Applied. Labeled \(changed) book\(changed == 1 ? "" : "s")."
        completed = true
    }

    private func load() async {
        phase = .loading
        liveLog = ["Found \(unclassifiedCount) unclassified book\(unclassifiedCount == 1 ? "" : "s")."]
        do {
            liveLog.append("Asking the AI model to classify each one…")
            let parsed = try await FictionClassifier.generateProposals(books: books)
            // Merge proposals with their matching books; drop anything that
            // doesn't reference a real unclassified book.
            let byID = books.reduce(into: [String: Book]()) { dict, book in
                if dict[book.id] == nil { dict[book.id] = book }
            }
            var list: [(bookID: String, kind: String)] = []
            for proposal in parsed {
                guard let kind = proposal.kind, kind.isEmpty == false else { continue }
                guard let book = byID[proposal.bookID], book.kind.isEmpty else { continue }
                list.append((bookID: proposal.bookID, kind: kind))
            }
            rows = list
            selected = Set(list.indices)
            liveLog.append("Model returned \(list.count) usable proposal\(list.count == 1 ? "" : "s"); review below.")
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
