import Foundation
import BackgroundTasks

/// Registers and drives the `BGAppRefreshTask` that periodically wakes the app
/// to pull new Gmail messages and fire local notifications for important mail.
///
/// ## How it works
///
/// 1. `register(store:)` is called ONCE at app startup (before the first scene
///    becomes active) to bind the task identifier to its handler. iOS requires
///    this to happen before the app finishes launching — after `application(_:
///    willFinishLaunchingWithOptions:)` it's too late.
///
/// 2. The handler calls `store.backgroundRefresh()`, which either uses the fast
///    `history.list` incremental path (when a stored `historyId` is available)
///    or falls back to a full unread-ID page. Either way the store is updated
///    in memory and persisted.
///
/// 3. If the refresh surfaces NEW important mail (Needs you / Waiting / Security)
///    AND the user has enabled `preferences.notifyImportantMail`, a local
///    notification banner is fired immediately.
///
/// 4. The daily brief and weekly recap are rescheduled on every background fire
///    so their bodies stay current.
///
/// 5. Before the handler returns it schedules the NEXT background refresh, keeping
///    the cadence alive. iOS decides the actual delivery time; `earliestBeginDate`
///    of 15 minutes is a hint, not a guarantee.
///
/// ## iOS opportunistic scheduling note
///
/// `BGAppRefreshTask` is opportunistic: iOS delivers it based on app usage
/// patterns, charging state, network, and thermal conditions. Users who open the
/// app frequently get more regular background updates; the app cannot control the
/// exact cadence. This is expected behaviour for App Refresh tasks — document it
/// in user-facing copy rather than trying to work around it.
enum InboxWatchScheduler {
    /// The stable task identifier registered in `Info.plist` under
    /// `BGTaskSchedulerPermittedIdentifiers`.
    static let taskIdentifier = "com.laveesingh.LifeCoach.inbox.refresh"

    /// How soon after app-backgrounding iOS should TRY to fire the next refresh.
    /// iOS may delay considerably beyond this — it's a minimum, not a promise.
    private static let minimumInterval: TimeInterval = 15 * 60  // 15 minutes

    // MARK: - Registration

    /// Guards against registering the launch handler more than once — a second
    /// `BGTaskScheduler.register` for the same identifier throws an exception.
    /// `register` is only ever called from `LifeCoachApp.init()` (main actor), so a
    /// plain flag is sufficient.
    private static var didRegister = false

    /// Registers the background-task handler with `BGTaskScheduler`. MUST be called
    /// exactly once, from `LifeCoachApp.init()`, BEFORE the app finishes launching —
    /// iOS crashes on a handler registered after launch completes OR registered a
    /// second time for the same identifier. The handler builds its OWN ephemeral
    /// `InboxStore` from the `AppStore` when it fires, so it never depends on a
    /// view-owned store that may not exist (or may have been re-created) by the time
    /// iOS wakes the app.
    @MainActor
    static func register(appStore: AppStore) {
        guard !didRegister else { return }
        didRegister = true
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task: refreshTask, appStore: appStore)
        }
    }

    // MARK: - Scheduling

    /// Asks iOS to fire the next background refresh no sooner than
    /// `minimumInterval` from now. Call this at app startup AND from within the
    /// task handler to keep the cadence alive.
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minimumInterval)
        // Submitting may fail if the identifier isn't in Info.plist or the device
        // doesn't support background refresh; errors are non-fatal (best-effort).
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Task handler

    /// Runs inside a `BGAppRefreshTask`. The expiration handler cancels the task
    /// gracefully if iOS terminates it early (low battery, user force-quit, etc.).
    private static func handle(task: BGAppRefreshTask, appStore: AppStore) {
        // Schedule the NEXT refresh immediately so the chain stays alive even if
        // this execution is cancelled by the expiration handler.
        scheduleNext()

        let taskHandle = Task {
            // Build an ephemeral store on the main actor (InboxStore is @MainActor):
            // it loads the persisted cache + watch state from disk, so it can refresh
            // and de-dupe notifications independently of any on-screen store.
            let store = await MainActor.run { InboxStore(store: appStore) }
            // Run the incremental (or full fallback) inbox refresh.
            let result = await store.backgroundRefresh()

            // Read the notification preferences on the main actor before leaving it.
            let (notifyEnabled, dailyBriefHour, senderMemory) = await MainActor.run {
                (
                    store.preferences.notifyImportantMail,
                    store.preferences.dailyBriefHour,
                    store.senderMemorySnapshot
                )
            }

            // Fire a notification for new important mail if the user opted in.
            if result.hasNewImportantMail && notifyEnabled {
                NotificationManager.fireImportantMailAlert(for: result.newImportant)
            }

            // Keep the daily brief and weekly recap bodies current.
            NotificationManager.scheduleInboxDailyBrief(
                hour: dailyBriefHour,
                brief: result.updatedBrief
            )
            NotificationManager.scheduleInboxWeeklyRecap(senderMemory: senderMemory)

            task.setTaskCompleted(success: true)
        }

        // iOS will call this if it decides to terminate the background task early.
        // Cancel the async work and mark the task complete so iOS doesn't penalise
        // future scheduling.
        task.expirationHandler = {
            taskHandle.cancel()
            task.setTaskCompleted(success: false)
        }
    }
}
