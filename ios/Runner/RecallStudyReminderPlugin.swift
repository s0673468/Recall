import Flutter
import UserNotifications

/// Native-only delivery for one daily Recall study reminder. Preferences and
/// study logic remain in Dart; this class owns only iOS permission/scheduling.
final class RecallStudyReminderPlugin: NSObject, FlutterPlugin {
  static let notificationIdentifier = "recall.dailyStudy"
  private static let channelName = "com.german.ankiReview/studyReminder"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(RecallStudyReminderPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "requestPermission":
      UNUserNotificationCenter.current().requestAuthorization(
        options: [.alert, .badge, .sound]
      ) { granted, error in
        DispatchQueue.main.async {
          if let error {
            result(
              FlutterError(
                code: "notification_permission_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          } else {
            result(granted)
          }
        }
      }

    case "apply":
      guard
        let arguments = call.arguments as? [String: Any],
        let enabled = arguments["enabled"] as? Bool,
        let hour = arguments["hour"] as? Int,
        let minute = arguments["minute"] as? Int,
        (0...23).contains(hour),
        (0...59).contains(minute)
      else {
        result(
          FlutterError(
            code: "invalid_reminder_settings",
            message: "Expected enabled and a valid local reminder time.",
            details: nil
          )
        )
        return
      }
      let center = UNUserNotificationCenter.current()
      center.removePendingNotificationRequests(
        withIdentifiers: [Self.notificationIdentifier]
      )
      guard enabled else {
        result(nil)
        return
      }
      center.add(Self.makeRequest(hour: hour, minute: minute)) { error in
        DispatchQueue.main.async {
          if let error {
            result(
              FlutterError(
                code: "reminder_schedule_failed",
                message: error.localizedDescription,
                details: nil
              )
            )
          } else {
            result(nil)
          }
        }
      }

    case "cancel":
      UNUserNotificationCenter.current().removePendingNotificationRequests(
        withIdentifiers: [Self.notificationIdentifier]
      )
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func makeRequest(hour: Int, minute: Int) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = "Time to Recall"
    content.body = "A short review now keeps tomorrow's queue lighter."
    content.sound = .default
    content.userInfo = ["url": "recall://study"]
    let trigger = UNCalendarNotificationTrigger(
      dateMatching: DateComponents(hour: hour, minute: minute),
      repeats: true
    )
    return UNNotificationRequest(
      identifier: notificationIdentifier,
      content: content,
      trigger: trigger
    )
  }
}
