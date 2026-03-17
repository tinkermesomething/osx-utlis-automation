import UserNotifications

enum NotificationManager {

    /// Request permission lazily — only prompts once; subsequent calls are no-ops if already determined.
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            log("NotificationManager: authorizationStatus=\(settings.authorizationStatus.rawValue)")
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, error in
                    if let error {
                        log("NotificationManager: requestAuthorization error — \(error)")
                    } else {
                        log("NotificationManager: permission \(granted ? "granted" : "denied")")
                    }
                }
            case .denied:
                log("NotificationManager: previously denied — open System Settings > Notifications to re-enable")
            case .authorized, .provisional, .ephemeral:
                log("NotificationManager: already authorised (\(settings.authorizationStatus.rawValue))")
            @unknown default:
                log("NotificationManager: unknown authorizationStatus \(settings.authorizationStatus.rawValue)")
            }
        }
    }

    static func send(title: String, body: String) {
        let content       = UNMutableNotificationContent()
        content.title     = title
        content.body      = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content:    content,
            trigger:    nil  // deliver immediately
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error { log("NotificationManager: failed — \(error)") }
        }
    }
}
