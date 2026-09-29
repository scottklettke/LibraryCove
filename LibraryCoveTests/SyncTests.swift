import Testing
import SwiftData
@testable import LibraryCove

@Suite struct SyncTests {

    @Test func optionsExposeAllAndAvailability() {
        #expect(LibrarySync.allCases.count == 3)
        #expect(LibrarySync.localOnly.isAvailableNow)
        #expect(LibrarySync.iCloud.isAvailableNow)
        #expect(LibrarySync.sharedLibrary.isAvailableNow)
    }

    @Test func localAndCloudOptionsReturnStoreConfigs() {
        // Both implemented options produce a usable store configuration
        // (actual container creation is exercised at app launch).
        #expect((try? SyncStoreRegistry.provider(for: .localOnly).makeStoreConfiguration()) != nil)
        #expect((try? SyncStoreRegistry.provider(for: .iCloud).makeStoreConfiguration()) != nil)
        #expect((try? SyncStoreRegistry.provider(for: .sharedLibrary).makeStoreConfiguration()) != nil)
    }
}
