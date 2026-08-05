import Flutter
import UserNotifications

protocol RecallStudyNotificationCenter: AnyObject {
  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @escaping @Sendable (Bool, Error?) -> Void
  )
  func removePendingNotificationRequests(withIdentifiers identifiers: [String])
  func add(
    _ request: UNNotificationRequest,
    withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?
  )
}

extension UNUserNotificationCenter: RecallStudyNotificationCenter {}

/// Native-only delivery for one daily Recall study reminder. Preferences and
/// study logic remain in Dart; this class owns only iOS permission/scheduling.
final class RecallStudyReminderPlugin: NSObject, FlutterPlugin {
  static let notificationIdentifier = "recall.dailyStudy"
  private static let channelName = "com.german.ankiReview/studyReminder"
  private let notificationCenter: RecallStudyNotificationCenter
  private let now: () -> Date
  private let calendar: Calendar

  init(
    notificationCenter: RecallStudyNotificationCenter = UNUserNotificationCenter.current(),
    now: @escaping () -> Date = Date.init,
    calendar: Calendar = .autoupdatingCurrent
  ) {
    self.notificationCenter = notificationCenter
    self.now = now
    self.calendar = calendar
    super.init()
  }

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
      notificationCenter.requestAuthorization(
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
        let studiedToday = arguments["studiedToday"] as? Bool,
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
      let dueCount = arguments["dueCount"] as? Int
      notificationCenter.removePendingNotificationRequests(
        withIdentifiers: [Self.notificationIdentifier]
      )
      guard enabled, let dueCount, dueCount > 0, !studiedToday else {
        result(nil)
        return
      }
      guard let request = Self.makeRequest(
        hour: hour,
        minute: minute,
        now: now(),
        calendar: calendar
      ) else {
        result(nil)
        return
      }
      notificationCenter.add(request) { error in
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
      notificationCenter.removePendingNotificationRequests(
        withIdentifiers: [Self.notificationIdentifier]
      )
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  static func makeRequest(
    hour: Int,
    minute: Int,
    now: Date = Date(),
    calendar: Calendar = .autoupdatingCurrent
  ) -> UNNotificationRequest? {
    guard (0...23).contains(hour), (0...59).contains(minute) else {
      return nil
    }
    var target = calendar.dateComponents([.year, .month, .day], from: now)
    target.hour = hour
    target.minute = minute
    target.second = 0
    guard var fireDate = calendar.date(from: target) else {
      return nil
    }
    if fireDate <= now {
      guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) else {
        return nil
      }
      target = calendar.dateComponents([.year, .month, .day], from: tomorrow)
      target.hour = hour
      target.minute = minute
      target.second = 0
      guard let nextFireDate = calendar.date(from: target) else {
        return nil
      }
      fireDate = nextFireDate
    }

    var matching = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute],
      from: fireDate
    )
    matching.calendar = calendar
    matching.timeZone = calendar.timeZone
    let content = UNMutableNotificationContent()
    content.title = "Time to Recall"
    content.body = "A short review now keeps tomorrow's queue lighter."
    content.sound = .default
    content.userInfo = ["url": "recall://study"]
    let trigger = UNCalendarNotificationTrigger(
      dateMatching: matching,
      repeats: false
    )
    return UNNotificationRequest(
      identifier: notificationIdentifier,
      content: content,
      trigger: trigger
    )
  }
}
