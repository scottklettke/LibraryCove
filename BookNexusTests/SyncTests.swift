import Testing
import SwiftData
@testable import BookNexus

@Suite struct SyncTests {

    @Test func optionsExposeAllAndAvailability() {
        #expect(LibrarySync.allCases.count == 5)
        #expect(LibrarySync.localOnly.isAvailableNow)
        #expect(LibrarySync.iCloud.isAvailableNow)
        #expect(!LibrarySync.dropbox.isAvailableNow)
        #expect(!LibrarySync.box.isAvailableNow)
        #expect(!LibrarySync.nextcloud.isAvailableNow)
    }

    @Test func notYetImplementedOptionsAreStructuralOnly() {
        // Dropbox/Box/Nextcloud register in the framework but must not be able
        // to back the store yet.
        for kind in [LibrarySync.dropbox, .box, .nextcloud] {
            #expect(throws: LibrarySyncError.self) {
                try SyncStoreRegistry.provider(for: kind).makeStoreConfiguration()
            }
        }
    }

    @Test func localAndCloudOptionsReturnStoreConfigs() {
        // Both implemented options produce a usable store configuration
        // (actual container creation is exercised at app launch).
        #expect((try? SyncStoreRegistry.provider(for: .localOnly).makeStoreConfiguration()) != nil)
        #expect((try? SyncStoreRegistry.provider(for: .iCloud).makeStoreConfiguration()) != nil)
    }
}
