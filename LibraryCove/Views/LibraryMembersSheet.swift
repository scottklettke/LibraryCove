import SwiftUI
import CloudKit
import SwiftData

/// Members management for a shared library: list participants with their
/// roles, let admins change roles on the fly (admin/editor/guest), and show
/// the current user's own role. Guests are read-only by CK permission.
struct LibraryMembersSheet: View {
    let libraryID: String
    let libraryName: String
    @Environment(\.dismiss) private var dismiss
    @State private var members: [SharedLibraryMember] = []
    @State private var myRole: ShareParticipantRole = .editor
    @State private var loading = true
    @State private var roleError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if loading {
                        HStack { Spacer(); ProgressView() }
                    } else if members.isEmpty {
                        Text("No members yet. Share the library link to invite people.")
                    } else {
                        ForEach(members, id: \.id) { member in
                            memberRow(member)
                        }
                    }
                } header: {
                    Text("Members")
                } footer: {
                    Text(roleFooter)
                }

                if myRole == .admin {
                    Section {
                        Text("Admins can edit anything, share the library, manage members' roles, and stop sharing. Editors can edit and share links. Guests can only view.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Couldn't update role", isPresented: Binding(
                get: { roleError != nil },
                set: { if !$0 { roleError = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(roleError ?? "")
            }
            .task { await load() }
        }
    }

    private var roleFooter: String {
        switch myRole {
        case .admin: return "You are the admin of this library."
        case .editor: return "You can edit anything and share links, but can't manage members or stop sharing."
        case .guest: return "You have view-only access to this library."
        }
    }

    @ViewBuilder
    private func memberRow(_ member: SharedLibraryMember) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(member.name + (member.isCurrentUser ? " (you)" : ""))
                    .font(.body)
                Text(roleLabel(for: member))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // Admins manage roles for everyone except the owner and themselves.
            if myRole == .admin && !member.isOwner && !member.isCurrentUser {
                Menu {
                    ForEach(ShareParticipantRole.allCases, id: \.self) { role in
                        Button(role.displayName) {
                            applyRole(role, to: member)
                        }
                    }
                } label: {
                    Image(systemName: "person.crop.rectangle.badge.plus")
                }
            }
        }
    }

    private func roleLabel(for member: SharedLibraryMember) -> String {
        var parts: [String] = []
        if member.isOwner { parts.append("Owner") }
        else {
            let role = ShareRoleStore.role(libraryID: libraryID,
                                           participantRecordName: member.id)
            parts.append(role.displayName)
        }
        parts.append(member.acceptanceStatusDescription)
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true
        defer { loading = false }
        myRole = SharedLibraryEngine.shared.myRole(libraryID: libraryID)
        await SharedLibraryEngine.shared.refreshParticipants(libraryID: libraryID)
        members = SharedLibraryEngine.shared.members
    }

    private func applyRole(_ role: ShareParticipantRole, to member: SharedLibraryMember) {
        Task { @MainActor in
            do {
                try await SharedLibraryEngine.shared.setRole(
                    role, participantRecordName: member.id, libraryID: libraryID)
                await load()
            } catch {
                roleError = error.localizedDescription
            }
        }
    }
}
