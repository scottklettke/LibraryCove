import SwiftUI
import SwiftData
import MarkdownUI

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
    @State private var transientThinking: String?
    @State private var memory: any ConversationMemory = ConversationMemoryFactory.make()
    @Environment(\.openLibraryTab) private var openLibraryTab

    /// Context-aware chips: fixed starters on an empty chat, then follow-ups
    /// derived from the conversation and library. Tapping one fills the input
    /// (it doesn't auto-send). Deterministic — no model call — so they update
    /// instantly and the selected engine only runs when a chip is actually
    /// sent.
    private var suggestions: [String] {
        AskSuggestions.forChat(turns: turns, books: books)
    }

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
                        if let transientThinking {
                            Text(transientThinking)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(uiColor: .secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .textSelection(.enabled)
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
            // Render markdown (bold, lists, headings) the model may emit; a
            // parsed bubble keeps the transcript stored as plain text so the
            // markdown survives re-rendering and copying verbatim.
            Markdown(turn.text)
                .markdownTextStyle {
                    ForegroundColor(turn.role == .user ? Color(uiColor: .white) : Color.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(turn.role == .user ? Color.accentColor : Color(uiColor: .secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .textSelection(.enabled)
                .frame(maxWidth: 340, alignment: turn.role == .user ? .trailing : .leading)
            if turn.role == .assistant { Spacer(minLength: 48) }
        }
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
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
            // Size the context to the engine's *reported* window: on-device
            // reports Apple's fixed session budget, OpenAI-compatible the
            // configured one. The snapshot then only embeds the full detail of
            // the books this question is actually about (retrieval runs
            // app-side, on-device, before the LLM).
            let limit = await AIService.shared.effectiveContextTokens()
            do {
                let snapshot = AILibrarySnapshot.build(books: books, users: users, query: text, contextLimit: limit)
                // Keep only as much prior conversation as fits the model's
                // context window; the current turn is always included.
                let window = memory.window(limit: AIPromptFactory.transcriptWindow)
                let scoped = AIPromptFactory.transcript(for: window, budget: AIPromptFactory.transcriptBudget(limit: limit))
                let conversation = scoped
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
                let text = response.text
                lastTokenRate = AIPromptFactory.tokensPerSecond(text: text, seconds: elapsed)
                let assistantTurn = AITurn(role: .assistant, text: text, date: Date())
                turns.append(assistantTurn)
                memory.append(assistantTurn)
                // Surface a short slice of the model's chain-of-thought, then
                // auto-clear it once the reply is on screen.
                if let reasoning = response.reasoning, !reasoning.isEmpty {
                    transientThinking = Self.thinkingPreview(reasoning)
                    Task {
                        try? await Task.sleep(for: .milliseconds(1600))
                        if !Task.isCancelled {
                            transientThinking = nil
                        }
                    }
                }
            } catch {
                errorText = Self.aiErrorText(error, limit: limit)
            }
        }
    }

    private static func thinkingPreview(_ reasoning: String) -> String {
        let lines = reasoning
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .prefix(3)
            .joined(separator: "\n")
        let trimmed = String(lines).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 360 else { return trimmed }
        return String(trimmed.prefix(360)) + "…"
    }

    private static func aiErrorText(_ error: Error, limit: Int) -> String {
        guard let aiError = error as? AIError else { return error.localizedDescription }
        switch aiError {
        case .notConfigured, .engineUnavailable:
            return "AI isn't ready. Set up an engine in Settings → AI."
        case .contextSizeExceeded:
            switch AIConfig.selectedEngine {
            case .onDevice:
                // The on-device window is fixed — it can't be raised, and the
                // app already sends only a compact index plus relevant books,
                // so the user just needs to rephrase. A fresh request gets a
                // fresh session, so the conversation never needs clearing.
                return "This question was too large for the on-device model's context window (\(limit) tokens total). The app already sends only a compact index plus the books relevant to your question, so rephrasing it more concisely usually fits. Your conversation is preserved — nothing needs clearing."
            case .openAI:
                return "This request exceeded the model's context window (configured \(limit) tokens). The app sends a compact snapshot, so this is unusual — try a shorter question, or raise the context window in Settings → AI to match your model."
            }
        default:
            return aiError.localizedDescription
        }
    }
}
