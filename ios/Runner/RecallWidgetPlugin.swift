import Flutter
import UIKit
import WidgetKit

/// Writes the only two values the widget is allowed to read: the aggregate
/// count and its update time. Flutter never sends account, deck, or card data.
final class RecallWidgetPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.german.ankiReview/widget"
  private static let suiteName = "group.com.german.ankiReview"
  private static let dueCountKey = "due_count"
  private static let updatedAtKey = "updated_at"
  private static let widgetKind = "RecallDueWidget"

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(RecallWidgetPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let defaults = UserDefaults(suiteName: Self.suiteName) else {
      result(
        FlutterError(
          code: "app_group_unavailable",
          message: "Recall widget App Group is unavailable.",
          details: nil
        )
      )
      return
    }

    switch call.method {
    case "update":
      guard
        let arguments = call.arguments as? [String: Any],
        let dueNumber = arguments["dueCount"] as? NSNumber,
        let updatedNumber = arguments["updatedAtEpochMs"] as? NSNumber,
        dueNumber.intValue >= 0,
        updatedNumber.doubleValue.isFinite,
        updatedNumber.doubleValue > 0
      else {
        result(
          FlutterError(
            code: "invalid_widget_snapshot",
            message: "Expected a non-negative due count and update time.",
            details: nil
          )
        )
        return
      }
      defaults.set(dueNumber.intValue, forKey: Self.dueCountKey)
      defaults.set(
        updatedNumber.doubleValue / 1_000,
        forKey: Self.updatedAtKey
      )
      WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
      result(nil)

    case "clear":
      defaults.removeObject(forKey: Self.dueCountKey)
      defaults.removeObject(forKey: Self.updatedAtKey)
      WidgetCenter.shared.reloadTimelines(ofKind: Self.widgetKind)
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}
