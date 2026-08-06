import SwiftUI
import SwiftData

@main
struct BookNexusApp: App {
    let container: ModelContainer

    init() {
        container = Persistence.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
