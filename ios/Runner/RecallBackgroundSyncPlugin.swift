import Flutter
import UIKit

/// Bridges iOS's opportunistic background fetch to Recall's durable Dart
/// outbox. Dart owns all study logic; native code only wakes it and reports
/// the fetch result back to iOS.
final class RecallBackgroundSyncPlugin: NSObject, FlutterPlugin {
  private static let channelName = "com.german.ankiReview/backgroundSync"
  private(set) static var shared: RecallBackgroundSyncPlugin?

  private let channel: FlutterMethodChannel
  private var dartReady = false
  private var pendingFetch: (
    id: UUID,
    deadline: Date,
    completion: (UIBackgroundFetchResult) -> Void
  )?

  private init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    let plugin = RecallBackgroundSyncPlugin(channel: channel)
    shared = plugin
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "ready" else {
      result(FlutterMethodNotImplemented)
      return
    }
    dartReady = true
    UIApplication.shared.setMinimumBackgroundFetchInterval(60 * 60)
    if let pending = pendingFetch {
      pendingFetch = nil
      invokeSync(deadline: pending.deadline, completion: pending.completion)
    }
    result(nil)
  }

  func performFetch(
    completion: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    let deadline = Date().addingTimeInterval(25)
    guard dartReady else {
      pendingFetch?.completion(.failed)
      let id = UUID()
      pendingFetch = (id: id, deadline: deadline, completion: completion)
      DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
        guard let self, self.pendingFetch?.id == id else { return }
        let pending = self.pendingFetch
        self.pendingFetch = nil
        pending?.completion(.failed)
      }
      return
    }
    invokeSync(deadline: deadline, completion: completion)
  }

  private func invokeSync(
    deadline: Date,
    completion: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    let remaining = deadline.timeIntervalSinceNow
    guard remaining > 0 else {
      completion(.failed)
      return
    }
    var completed = false
    let finish: (UIBackgroundFetchResult) -> Void = { value in
      guard !completed else { return }
      completed = true
      completion(value)
    }
    let timeout = DispatchWorkItem { finish(.failed) }
    DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: timeout)

    channel.invokeMethod("performSync", arguments: nil) { value in
      timeout.cancel()
      switch value as? String {
      case "newData": finish(.newData)
      case "noData": finish(.noData)
      default: finish(.failed)
      }
    }
  }
}
