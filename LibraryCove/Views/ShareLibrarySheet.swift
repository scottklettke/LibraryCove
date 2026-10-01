import SwiftUI
import CloudKit

/// "Share library" sheet: shows the share link with Copy up front, plus
/// the native share sheet (Messages/Mail/AirDrop/…) one tap away.
///
/// Replaces UICloudSharingController as the primary entry: the system
/// controller's Messages handoff dismissed without sending in testing,
/// and its "Add participant" flow requires the recipient to already
/// exist as a CloudKit participant. The link is self-service: with the
/// share's public permission set (readWrite for admin/editor links,
/// readOnly for guest), ANY recipient can accept it — LibraryCove
/// assigns the link's role (rolesRecord) after accept.
struct ShareLibrarySheet: View {
    let library: LibraryInfo
    let share: CKShare
    let linkRole: ShareParticipantRole
    let container: CKContainer
    let onFinished: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    init(library: LibraryInfo, share: CKShare, linkRole: ShareParticipantRole,
         container: CKContainer = CKContainer(identifier: SwiftDataiCloudSync.containerIdentifier),
         onFinished: @escaping () -> Void) {
        self.library = library
        self.share = share
        self.linkRole = linkRole
        self.container = container
        self.onFinished = onFinished
    }

    private var linkURL: URL? { share.url }

    /// Shares created before publicPermission was set have `.none` —
    /// their link is DEAD (recipients hit "Item Unavailable"). Offering
    /// a copy/send of a dead link would repeat the exact failure the
    /// user is escaping: surface the recreation requirement instead.
    private var linkIsDead: Bool { share.publicPermission == .none }

    private var roleLabel: String {
        switch linkRole {
        case .admin: return "Full control"
        case .editor: return "Can add and edit books"
        case .guest: return "View only"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if linkIsDead {
                    Section {
                        Label("This share was created by an older version and its link can't be used.", systemImage: "link.badge.plus")
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Link unavailable")
                    } footer: {
                        Text("Stop sharing this library, then share it again — the new link works for anyone who opens it.")
                    }
                } else {
                    linkSection
                    actionsSection
                }
            }
            .navigationTitle("Share “\(library.name)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onFinished()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var linkSection: some View {
        Section {
            if let link = linkURL {
                HStack {
                    Text(link.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = link.absoluteString
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Share link unavailable — try sharing again.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Anyone with this link can join")
        } footer: {
            Text("This link grants: \(roleLabel). Anyone who opens it joins \(library.name) and syncs its books over iCloud.")
        }
    }

    private var actionsSection: some View {
        Section {
            // SwiftUI ShareLink hands the URL to Messages/Mail/AirDrop
            // without the UIActivityViewController-in-sheet path that
            // flash-dismissed in the system sharing controller. If it
            // ever misbehaves, Copy + manual paste is the fallback.
            if let link = linkURL {
                ShareLink(item: link) {
                    Label("Send link…", systemImage: "paperplane")
                }
            } else {
                Label("Send link…", systemImage: "paperplane")
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Send the link however you like — text, email, anything. New members appear in Members after they accept and sync once.")
        }
    }
}
