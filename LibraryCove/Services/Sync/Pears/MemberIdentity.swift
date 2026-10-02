import Foundation
import SwiftData

/// Member identity helpers, retained from the retired iCloud-sharing
/// coordinator: the welcome flow creates the canonical member row and
/// launch repair keeps exactly one active. Pears uses the same
/// identity (the member name is what join-key redemption records).
enum MemberIdentity {
    /// keeps the member name identical across devices: a device that
    /// onboards after the first import lands reuses the cloud's row
    /// (updating its name only when the user typed one) instead of minting
    /// a diverging duplicate. Legacy UUID-keyed rows are converged by
    /// `repairDuplicateActiveMembersIfNeeded` on the next launch.
    @MainActor
    @discardableResult
        static func createPrimaryMember(displayName: String, email: String,
                                    context: ModelContext) -> User {
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let primaryID = LibraryScope.primaryMemberID
        let existing = (try? context.fetch(FetchDescriptor<User>(
            predicate: #Predicate { $0.id == primaryID }
        )))?.first
        if let existing {
            if !trimmedName.isEmpty, existing.displayName != trimmedName {
                // One rename across all rows (legacy rows included) so the
                // greeting and "Added by" agree immediately.
                let all = (try? context.fetch(FetchDescriptor<User>())) ?? []
                for row in all where row.displayName != trimmedName {
                    row.displayName = trimmedName
                }
            }
            // Adopting the canonical row = becoming the active member.
            // A reset/reinstall cycle re-delivers the old row via CloudKit
            // with isActive=false (the pre-reset repair deactivated it);
            // without this, WelcomeView's finish() returns an inactive
            // row and the app loops on the welcome screen forever.
            if !existing.isActive {
                let all = (try? context.fetch(FetchDescriptor<User>())) ?? []
                for row in all where row.isActive && row.id != existing.id {
                    row.isActive = false
                }
                existing.isActive = true
            }
            try? context.save()
            return existing
        }
        let user = User(id: LibraryScope.primaryMemberID,
                        email: email.isEmpty ? "local@librarycove.local" : email,
                        displayName: trimmedName)
        context.insert(user)
        try? context.save()
        return user
    }

    /// Deactivates duplicate ACTIVE members and converges legacy UUID-keyed
    /// identity rows onto the canonical primary row. CloudKit stores can
    /// hold older identity records, and mirroring delivers them alongside
    /// the current one — multiple isActive rows make
    /// "first(where: \.isActive)" nondeterministic across views.
        static func repairDuplicateActiveMembersIfNeeded(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<User>())) ?? []
        guard !all.isEmpty else { return }

        // Identity convergence: pre-primary-id builds created one UUID-keyed
        // member row per device, so the same iCloud account could hold two
        // rows whose names diverged ("Scott" vs "Test") and a rename of all
        // rows on one device still lost to the other device's locally
        // minted row. Unify: pick the canonical primary row (creating it if
        // only legacy rows exist), copy the newest row's identity fields
        // into it, deactivate legacy rows, and DELETE them — CloudKit
        // mirroring propagates the deletions so every device converges on
        // exactly one row.
        if let primary = all.first(where: { $0.id == LibraryScope.primaryMemberID }) {
            let legacy = all.filter { $0.id != LibraryScope.primaryMemberID }
            // Adopt whichever legacy row is newest per field so no rename
            // from any device is lost in the merge.
            let newest = legacy.max { lhs, rhs in
                (lhs.lastLoginAt ?? lhs.createdAt) < (rhs.lastLoginAt ?? rhs.createdAt)
            } ?? primary
            let newestName = newest.displayName.trimmingCharacters(in: .whitespaces)
            let newestEmail = newest.email.trimmingCharacters(in: .whitespaces)
            if !newestName.isEmpty, primary.displayName != newestName {
                primary.displayName = newestName
            }
            if !newestEmail.isEmpty, primary.email != newestEmail,
               primary.email.isEmpty || primary.email.hasSuffix(".local") {
                primary.email = newestEmail
            }
            if legacy.contains(where: \.isActive) { primary.isActive = true }
            // Re-point row references BEFORE deleting the legacy rows, or
            // "Added by" attribution and per-member note lookups break.
            let legacyIDs = Set(legacy.map(\.id))
            if let books = try? context.fetch(FetchDescriptor<Book>(
                predicate: #Predicate { $0.ownerID != nil && legacyIDs.contains($0.ownerID!) }
            )) {
                for book in books { book.ownerID = LibraryScope.primaryMemberID }
            }
            if let notes = try? context.fetch(FetchDescriptor<Note>(
                predicate: #Predicate { legacyIDs.contains($0.userID) }
            )) {
                for note in notes { note.userID = LibraryScope.primaryMemberID }
            }
            // ReadingList.ownerID is a non-optional String ("" = unset).
            if let lists = try? context.fetch(FetchDescriptor<ReadingList>(
                predicate: #Predicate { legacyIDs.contains($0.ownerID) }
            )) {
                for list in lists where !list.ownerID.isEmpty {
                    list.ownerID = LibraryScope.primaryMemberID
                }
            }
            for stale in legacy { context.delete(stale) }
            try? context.save()
        } else if all.count > 1 {
            // No primary row yet: crown one (newest wins, matching the old
            // active-repair rule) by re-keying its id and deleting the rest,
            // then re-point references to the surviving row.
            let sorted = all.sorted { lhs, rhs in
                (lhs.lastLoginAt ?? lhs.createdAt) > (rhs.lastLoginAt ?? rhs.createdAt)
            }
            let winner = sorted[0]
            let winnerID = winner.id
            let legacyIDs = Set(all.filter { $0.id != winnerID }.map(\.id))
            if let books = try? context.fetch(FetchDescriptor<Book>(
                predicate: #Predicate { $0.ownerID != nil && legacyIDs.contains($0.ownerID!) }
            )) {
                for book in books { book.ownerID = winnerID }
            }
            if let notes = try? context.fetch(FetchDescriptor<Note>(
                predicate: #Predicate { legacyIDs.contains($0.userID) }
            )) {
                for note in notes { note.userID = winnerID }
            }
            if let lists = try? context.fetch(FetchDescriptor<ReadingList>(
                predicate: #Predicate { legacyIDs.contains($0.ownerID) }
            )) {
                for list in lists where !list.ownerID.isEmpty {
                    list.ownerID = winnerID
                }
            }
            for stale in sorted.dropFirst() { context.delete(stale) }
            winner.id = LibraryScope.primaryMemberID
            try? context.save()
        } else if all.count == 1, all[0].id != LibraryScope.primaryMemberID {
            // Single legacy row: re-key it to the canonical id in place so
            // every device converges on the same identity without a merge.
            let row = all[0]
            let oldID = row.id
            if let books = try? context.fetch(FetchDescriptor<Book>(
                predicate: #Predicate { $0.ownerID != nil && $0.ownerID == oldID }
            )) {
                for book in books { book.ownerID = LibraryScope.primaryMemberID }
            }
            if let notes = try? context.fetch(FetchDescriptor<Note>(
                predicate: #Predicate { $0.userID == oldID }
            )) {
                for note in notes { note.userID = LibraryScope.primaryMemberID }
            }
            if let lists = try? context.fetch(FetchDescriptor<ReadingList>(
                predicate: #Predicate { $0.ownerID == oldID }
            )) {
                for list in lists where !list.ownerID.isEmpty {
                    list.ownerID = LibraryScope.primaryMemberID
                }
            }
            row.id = LibraryScope.primaryMemberID
            try? context.save()
        }

        // Keep exactly one active member so the login gate and greeting
        // resolve deterministically.
        let refreshed = (try? context.fetch(FetchDescriptor<User>())) ?? []
        let active = refreshed.filter(\.isActive)
        guard active.count > 1 else { return }
        let sorted = active.sorted { lhs, rhs in
            let l = lhs.lastLoginAt ?? lhs.createdAt
            let r = rhs.lastLoginAt ?? rhs.createdAt
            return l > r
        }
        for stale in sorted.dropFirst() {
            stale.isActive = false
        }
        try? context.save()
    }
}
