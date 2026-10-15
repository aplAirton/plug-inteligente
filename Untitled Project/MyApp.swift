import SwiftUI
import BackgroundTasks
import UserNotifications

@main struct MyApp: App {
    static let refreshID = "plug.refresh"
    @Environment(\.scenePhase) private var phase

    init() {
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task { _ = await Notifier.requestPermission() }
        }
        .onChange(of: phase) { _, new in
            if new == .background { Self.scheduleRefresh() }
        }
        .backgroundTask(.appRefresh(Self.refreshID)) {
            await PlugViewModel.shared.backgroundRefresh()
            await Self.scheduleRefresh()
        }
    }

    /// Pede ao iOS para acordar o app periodicamente (o sistema decide o momento; tipicamente 15–60 min).
    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshID)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
}
