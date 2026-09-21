import Foundation
import CoreData

/// Observes NSPersistentCloudKitContainer's event stream and exposes the
/// current iCloud sync activity for the Settings > Sync status UI.
///
/// SwiftData's CloudKit mirroring posts `eventChangedNotification` for each
/// setup/import/export batch. An event carries `endDate == nil` while it is
/// running; succeeded/failed events end the batch. Progress is batch-level
/// (Core Data gives no per-record counts), so the bar is indeterminate while
/// an event runs and the UI communicates "in progress" rather than percent.
@MainActor
final class CloudSyncMonitor: ObservableObject {
    static let shared = CloudSyncMonitor()

    struct SyncActivity: Equatable {
        enum Kind: String {
            case setup, import_, export
            var displayName: String {
                switch self {
                case .setup: return "Setting up iCloud Sync"
                case .import_: return "Downloading from iCloud"
                case .export: return "Uploading to iCloud"
                }
            }
        }
        let kind: Kind
        let startedAt: Date
    }

    /// The currently-running sync event, or nil when everything is synced.
    @Published private(set) var activity: SyncActivity?

    /// Last finished event's outcome, kept briefly for the status line.
    @Published private(set) var lastError: String?

    /// A batch that outlives this window (app suspended mid-upload, a
    /// missed end notification) is treated as lost: without this the
    /// Settings status row stays "Uploading to iCloud" forever. Long
    /// first-sync uploads can take a while, so the window is generous —
    /// the cost of a premature clear is only a missing progress row.
    private static let stalenessTimeout: TimeInterval = 15 * 60
    private var stalenessTimer: Timer?
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            // NSPersistentCloudKitContainer.Event is CoreData; SwiftData's
            // underlying container posts the same notifications.
            let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                as? NSPersistentCloudKitContainer.Event
            guard let event else { return }
            Task { @MainActor in
                self.handle(event: event)
            }
        }
        stalenessTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.clearStaleActivity()
            }
        }
    }

    /// Drops a running activity older than the staleness window. Events
    /// still genuinely running re-post notifications; the next start event
    /// re-populates the row.
    private func clearStaleActivity() {
        guard let activity,
              activity.startedAt.timeIntervalSinceNow < -Self.stalenessTimeout else { return }
        self.activity = nil
    }

    private func handle(event: NSPersistentCloudKitContainer.Event) {
        if event.endDate == nil {
            // Started (or still running). A newer start supersedes a stale
            // shown batch (e.g. the previous batch's end was missed).
            if activity == nil || event.startDate >= (activity?.startedAt ?? .distantPast) {
                activity = SyncActivity(kind: kind(of: event), startedAt: event.startDate)
            }
        } else {
            // Finished.
            if let error = event.error {
                lastError = error.localizedDescription
            } else {
                lastError = nil
            }
            // Clear the shown batch when its own end arrives, or when a
            // batch that started no earlier than it ends (the shown batch's
            // end notification was missed). An OLDER overlapping batch's
            // end must not clear a newer in-flight one.
            if activity?.startedAt == event.startDate
                || event.startDate >= (activity?.startedAt ?? .distantPast) {
                activity = nil
            }
        }
    }

    private func kind(of event: NSPersistentCloudKitContainer.Event) -> SyncActivity.Kind {
        switch event.type {
        case .setup: return .setup
        case .import: return .import_
        case .export: return .export
        default: return .export
        }
    }
}
