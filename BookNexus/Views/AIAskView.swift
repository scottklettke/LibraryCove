import SwiftUI
import SwiftData

/// "Ask AI" tab: a chat with recommendations and book answers, grounded in a
/// snapshot of the library and a locally persisted short transcript.
struct AIAskView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var books: [Book]
    @Query private var users: [User]

    @State private var turns: [AITurn] = []
    @State private var input = ""
    @State private var isSending = false
    @State private var errorText: String?
    @State private var lastTokenRate: Double?
    @State private var memory: any ConversationMemory = ConversationMemoryFactory.make()
    @Environment(\.openLibraryTab) private var openLibraryTab

    private static let suggestions = [
        "What should I read next?",
        "Recommend authors like my favorites",
        "About my current book",
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if turns.isEmpty {
                            emptyState
                        } else {
                            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                                bubble(turn)
                                    .id(index)
                            }
                        }
                        if let errorText {
                            Text(errorText)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.top, 4)
                        }
                        if isSending {
                            thinkingBubble
                                .id("thinking")
                        }
                    }
                    .padding()
                }
                .onChange(of: turns.count) {
                    guard let last = turns.indices.last else { return }
                    withAnimation {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
                .onChange(of: isSending) {
                    if isSending {
                        withAnimation {
                            proxy.scrollTo("thinking", anchor: .bottom)
                        }
                    }
                }
            }

            suggestionChips
                .padding(.horizontal)
                .padding(.bottom, 8)

            inputBar
                .padding(.horizontal)
                .padding(.bottom, 8)

            footer
        }
        .navigationTitle("Ask AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    openLibraryTab()
                } label: {
                    Label("Library", systemImage: "chevron.left")
                }
                .accessibilityLabel("Back to library")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    turns = []
                    memory.clear()
                } label: {
                    Label("Clear conversation", systemImage: "trash")
                }
                .disabled(turns.isEmpty || isSending)
            }
        }
        .onAppear {
            if turns.isEmpty {
                turns = memory.load()
            }
        }
    }

    // MARK: - Sections

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
            Text("Ask about your library")
                .font(.headline)
            Text("Recommendations, author suggestions, and answers grounded in the books you own.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 48)
        .padding(.horizontal)
    }

    private var thinkingBubble: some View {
        HStack {
            HStack(spacing: 8) {
                ProgressView()
                Text("Thinking…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemFill))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 48)
        }
    }

    private func bubble(_ turn: AITurn) -> some View {
        HStack {
            if turn.role == .user { Spacer(minLength: 48) }
            Text(turn.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(turn.role == .user ? Color.accentColor : Color(uiColor: .secondarySystemFill))
                .foregroundStyle(turn.role == .user ? .white : .primary)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .textSelection(.enabled)
                .frame(maxWidth: 340, alignment: turn.role == .user ? .trailing : .leading)
            if turn.role == .assistant { Spacer(minLength: 48) }
        }
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        input = suggestion
                    } label: {
                        Text(suggestion)
                            .font(.caption)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask about your library…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Capsule().fill(Color(uiColor: .secondarySystemFill)))
                .onSubmit {
                    send()
                }
            Button(action: send) {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .font(.title2)
                    .labelStyle(.iconOnly)
            }
            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
            .opacity(isSending ? 0.5 : 1)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Engine: \(AIConfig.selectedEngine.displayName) — change in Settings")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            if AIConfig.showTokenRate, let lastTokenRate {
                Text(String(format: "≈%.0f tok/s", lastTokenRate))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - Send

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }

        let userTurn = AITurn(role: .user, text: text, date: Date())
        turns.append(userTurn)
        memory.append(userTurn)
        input = ""
        errorText = nil
        lastTokenRate = nil
        isSending = true

        Task {
            defer { isSending = false }
            do {
                let snapshot = AILibrarySnapshot.build(books: books, users: users)
                let window = memory.window(limit: AIPromptFactory.transcriptWindow)
                // The current user turn is already in the window (it was
                // appended before the request), so render it with the history.
                let conversation = window
                    .map { "\($0.role == .user ? "User" : "Assistant"): \($0.text)" }
                    .joined(separator: "\n")

                let start = Date()
                let response = try await AIService.shared.generate(
                    AIPrompt(
                        system: AIPromptFactory.systemPrompt(snapshot: snapshot),
                        user: conversation
                    )
                )
                let elapsed = Date().timeIntervalSince(start)
                lastTokenRate = AIPromptFactory.tokensPerSecond(text: response, seconds: elapsed)
                let assistantTurn = AITurn(role: .assistant, text: response, date: Date())
                turns.append(assistantTurn)
                memory.append(assistantTurn)
            } catch let error as AIError {
                switch error {
                case .notConfigured, .engineUnavailable:
                    errorText = "AI isn't ready. Set up an engine in Settings → AI."
                default:
                    errorText = error.localizedDescription
                }
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}
