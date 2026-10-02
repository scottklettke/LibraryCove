import Foundation

/// Hands a join key from the librarycove://join URL handler to the
/// joiner sheet: the URL arrives wherever the app was (often Settings),
/// the sheet presents with the invite pre-filled.
@MainActor
final class PearsPendingJoin: ObservableObject {
    static let shared = PearsPendingJoin()

    @Published var pendingKey: String?

    func stash(_ key: String) {
        pendingKey = key
    }

    func consume() -> String? {
        defer { pendingKey = nil }
        return pendingKey
    }
}

import SwiftUI

/// Settings entry: routes to the admin Pears sheet for the active
/// library (the sync section is a NavigationLink because Settings is a
/// Form — the sheet variant is used from the Libraries list).
struct PearsSheetRouter: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        if let library = LibraryScope.shared.active(context: modelContext) {
            PearsSyncSheet(mode: .admin, library: library)
        } else {
            Text("No library yet — create one first.")
                .foregroundStyle(.secondary)
        }
    }
}
