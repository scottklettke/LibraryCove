import SwiftUI
import SwiftData

/// Sheets over the library's tags: asks the model for merge/remove
/// suggestions and applies the user-approved ones to `Book.tags`.
struct GenreCleanupView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let books: [Book]

    private enum Phase: Equatable {
        case loading
        case error(String)
        case ready
    }

    @State private var suggestions: [GenreSuggestion] = []
    @State private var selected = Set<Int>()
    @State private var phase: Phase = .loading
    @State private var completed = false
    @State private var liveLog: [String] = []
    @State private var outcome = ""

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
                        Label("Couldn't clean up tags", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                            .multilineTextAlignment(.center)
                    } actions: {
                        Button("Retry") {
                            Task { await load() }
                        }
                    }
                case .ready:
                    if suggestions.isEmpty {
                        ContentUnavailableView(
                            "Nothing to clean up",
                            systemImage: "checkmark.seal",
                            description: Text("Your tags already look tidy.")
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
                                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                                    row(index, suggestion)
                                }
                            } footer: {
                                Text("Review the suggestions and pick the ones to apply. Unselected rows are left untouched. Full request/response detail is in Settings → AI logs.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Clean up tags")
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

    private func row(_ index: Int, _ suggestion: GenreSuggestion) -> some View {
        let isOn = selected.contains(index)
        return HStack(spacing: 10) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isOn ? Color.accentColor : Color(uiColor: .secondaryLabel))
            Text(suggestion.from)
                .strikethrough(suggestion.to == nil)
            Image(systemName: "arrow.right")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(suggestion.to ?? "remove")
                .foregroundStyle(suggestion.to == nil ? .red : .primary)
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isOn {
                selected.remove(index)
            } else {
                selected.insert(index)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func apply() {
        let picked = selected.sorted().compactMap { index -> GenreSuggestion? in
            suggestions.indices.contains(index) ? suggestions[index] : nil
        }
        let changed = GenreCleanupService.apply(picked, to: books, context: modelContext)
        outcome = "Applied. \(picked.count) suggestion\(picked.count == 1 ? "" : "s") changed \(changed) book\(changed == 1 ? "" : "s")."
        completed = true
    }

    private func load() async {
        phase = .loading
        liveLog = ["Reading \(books.count) book\(books.count == 1 ? "" : "s")…"]
        let snapshot = GenreCleanupService.snapshot(from: books)
        do {
            liveLog.append("Asking the AI model to find similar or duplicate tags…")
            let response = try await AIService.shared.generate(
                AIPrompt(
                    system: "You are a careful book-cataloging assistant. Respond with only valid JSON and nothing else.",
                    user: GenreCleanupService.prompt(snapshot: snapshot)
                )
            )
            let parsed = try GenreCleanupService.parseSuggestions(from: Data(response.text.utf8))
            suggestions = parsed
            selected = Set(parsed.indices)
            liveLog.append("Model returned \(parsed.count) suggestions; review below before applying.")
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
