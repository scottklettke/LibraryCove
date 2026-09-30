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
    @State private var showSystemShare = false
    @State private var showSystemSharingController = false

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

                Section {
                    Button {
                        showSystemShare = true
                    } label: {
                        Label("Send link…", systemImage: "paperplane")
                    }
                    .disabled(linkURL == nil)

                    Button {
                        showSystemSharingController = true
                    } label: {
                        Label("Manage participants…", systemImage: "person.2")
                    }
                } footer: {
                    Text("Send the link however you like — text, email, anything. New members appear in Members after they accept and sync once.")
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
            .sheet(isPresented: $showSystemShare) {
                if let link = linkURL {
                    ShareLinkSheet(url: link)
                }
            }
            .sheet(isPresented: $showSystemSharingController) {
                CloudSharingSheet(share: share, libraryID: library.id, container: container)
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// System share sheet (Messages, Mail, AirDrop, Copy) presenting the
/// link URL itself.
private struct ShareLinkSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
