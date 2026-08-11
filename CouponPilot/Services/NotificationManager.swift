import UserNotifications

@MainActor
final class NotificationManager: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorizationStatus()
    }

    func requestAuthorization() async {
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            print("Notification permission failed: \(error.localizedDescription)")
        }
        refreshAuthorizationStatus()
    }

    func notifyStoreEntry(_ store: Store, couponCount: Int, savings: Int) async {
        // The location callback can arrive immediately after the user approves the alert.
        // Read the system setting here instead of relying on a previously published value.
        let status = await currentAuthorizationStatus()
        authorizationStatus = status
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(store.name)에 도착했어요"
        content.subtitle = "쿠폰콕 · 위치 기반 쿠폰 알림"
        content.body = "쿠폰 \(couponCount)장을 비교했어요 · 최대 \(savings.formatted())원 절약"
        content.sound = .default
        content.userInfo = ["storeID": store.id]
        let request = UNNotificationRequest(identifier: "store-entry-\(store.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    private func refreshAuthorizationStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self?.authorizationStatus = status }
        }
    }

    private func currentAuthorizationStatus() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
