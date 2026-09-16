import SwiftUI
import MarkdownUI

/// About & Feedback: app description, feature overview, open-source
/// attributions, the GitHub project, a bundled changelog, the roadmap, and a
/// one-tap feedback link. Reached from Settings → About & Feedback.
struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    /// Central place for the project's public URL (kept in sync with README).
    static let githubURL = URL(string: "https://github.com/aoeu10/LibraryCove")!

    private let roadmap = [
        "Additional AI providers and multi-model selection",
        "Web-search grounding for Ask AI (answers with sources)",
        "Streaming chat for AI conversations",
        "Deeper iCloud-synced metadata and sharing",
        "Widgets and richer home-screen features",
    ]

    private var versionText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? version : "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image("BrandMark")
                            .resizable()
                            .aspectRatio(1, contentMode: .fit)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22))
                            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
                            .accessibilityLabel("LibraryCove app icon")
                            .accessibilityIdentifier("brandMarkAbout")
                        Text("LibraryCove")
                            .font(.title2.weight(.bold))
                        Text("Version \(versionText)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    Text("LibraryCove is a personal book library manager for iPhone and iPad. It helps you catalog what you own, organize it the way you think, and make the most of your collection with AI assistance — all while keeping your data under your control.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Features include barcode and catalog lookup, a crash-safe background scan queue with duplicate handling, free-form tags and curated genres, fiction/non-fiction classification, loan tracking, export/import backups, optional iCloud sync, and an Ask AI assistant grounded in your library.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }

                Section {
                    ForEach(openSourceItems, id: \.name) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.body)
                            Text("\(item.use) — \(item.license)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Text("Apple frameworks (SwiftUI, SwiftData, Foundation Models, NaturalLanguage) are governed by Apple's terms of use.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } header: {
                    Text("Open source software")
                }

                Section {
                    Text("Book metadata and descriptions via Open Library (openlibrary.org) — bibliographic data is dedicated to the public domain (CC0).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Book metadata and descriptions via Google Books (books.google.com).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Description excerpts via Wikipedia (wikipedia.org) — content available under the Creative Commons Attribution-ShareAlike License.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Cover images are fetched via Open Library; their rights follow the source each cover came from.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Developed independently. Cindy's Books (github.com/brainchillz/CindysBooks-IOS), discovered near release, informed one idea: storing each book's Open Library work key at lookup time for deterministic description fetches. All code is original.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Data sources")
                }

                Section {
                    Link(destination: Self.githubURL) {
                        Label("GitHub — LibraryCove", systemImage: "link")
                    }
                    Link(destination: Self.githubURL.appendingPathComponent("issues/new")) {
                        Label("Send feedback / suggestions", systemImage: "envelope")
                    }
                } header: {
                    Text("Project")
                }

                Section {
                    ForEach(roadmap, id: \.self) { item in
                        Label(item, systemImage: "sparkles")
                    }
                } header: {
                    Text("Coming in the future")
                }

                Section {
                    NavigationLink {
                        ChangelogView()
                    } label: {
                        Label("Changelog", systemImage: "clock.arrow.circlepath")
                    }
                } header: {
                    Text("Release notes")
                }
            }
            .navigationTitle("About & Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private struct OSSItem {
        let name: String
        let use: String
        let license: String
    }

    private let openSourceItems: [OSSItem] = [
        OSSItem(name: "MarkdownUI (2.4.1) — by Gonzalez Real",
                use: "Rendering AI chat, suggestions, and the in-app changelog",
                license: "MIT License"),
    ]
}

/// Renders the bundled changelog. The file ships with the app build and is the
/// same content as the repository CHANGELOG.md.
private struct ChangelogView: View {
    @State private var markdown = ""

    var body: some View {
        ScrollView {
            Markdown(markdown)
                .textSelection(.enabled)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Changelog")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard markdown.isEmpty,
                  let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            markdown = text
        }
    }
}
