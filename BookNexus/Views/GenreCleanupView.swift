import SwiftUI
import SwiftData

/// Sheets over the library's genres: asks the model for merge/remove
/// suggestions and applies the user-approved ones to `Book.genres`.
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

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Asking AI to tidy up your genres…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .error(let message):
                    ContentUnavailableView {
                        Label("Couldn't clean up genres", systemImage: "exclamationmark.triangle")
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
                            description: Text("Your genres already look tidy.")
                        )
                    } else {
                        List {
                            Section {
                                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                                    row(index, suggestion)
                                }
                            } footer: {
                                Text("Review the suggestions and pick the ones to apply. Unselected rows are left untouched.")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Clean up genres")
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
        GenreCleanupService.apply(picked, to: books, context: modelContext)
        completed = true
    }

    private func load() async {
        phase = .loading
        let snapshot = GenreCleanupService.snapshot(from: books)
        do {
            let response = try await AIService.shared.generate(
                AIPrompt(
                    system: "You are a careful book-cataloging assistant. Respond with only valid JSON and nothing else.",
                    user: GenreCleanupService.prompt(snapshot: snapshot)
                )
            )
            let parsed = try GenreCleanupService.parseSuggestions(from: Data(response.utf8))
            suggestions = parsed
            selected = Set(parsed.indices)
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
