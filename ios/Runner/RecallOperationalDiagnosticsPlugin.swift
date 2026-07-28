import CoreFoundation
import Flutter
import Foundation

final class RecallOperationalDiagnosticsPlugin: NSObject, FlutterPlugin {
  private static let channelName =
    "com.german.ankiReview/operationalDiagnostics"

  private let writer: RecallOperationalDiagnosticsWriter

  init(writer: RecallOperationalDiagnosticsWriter = .init()) {
    self.writer = writer
    super.init()
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(
      RecallOperationalDiagnosticsPlugin(),
      channel: channel
    )
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "mirror" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      Set(arguments.keys) == Set(["payload"]),
      let payload = arguments["payload"] as? String
    else {
      result(
        FlutterError(
          code: "invalid_operational_diagnostics",
          message: "Expected one bounded operational-event/v2 array.",
          details: nil
        )
      )
      return
    }

    do {
      try writer.write(payload: payload)
      result(nil)
    } catch {
      result(
        FlutterError(
          code: "operational_diagnostics_write_failed",
          message: "Could not update the local diagnostics mirror.",
          details: nil
        )
      )
    }
  }
}

final class RecallOperationalDiagnosticsWriter {
  static let maxPayloadBytes = 64 * 1024

  typealias CommitReplacement = (_ temporary: URL, _ destination: URL) throws
    -> Void

  private static let requiredKeys: Set<String> = [
    "schema",
    "timestamp",
    "level",
    "project",
    "component",
    "operation",
    "outcome",
    "cause_code",
    "retryable",
    "run_id",
  ]
  private static let optionalKeys: Set<String> = [
    "commit_sha",
    "exit_code",
    "duration_ms",
  ]
  private static let components: Set<String> = [
    "framework",
    "background_sync",
    "foreground_sync",
    "auth",
  ]
  private static let operations: Set<String> = [
    "handle_framework_error",
    "handle_uncaught_error",
    "sync_pending",
    "observe_auth_state",
  ]
  private static let outcomes: Set<String> = [
    "started",
    "succeeded",
    "failed",
    "skipped",
  ]
  private static let causeCodes: Set<String> = [
    "none",
    "flutter.framework_error",
    "flutter.uncaught_error",
    "sync.background_failed",
    "sync.foreground_failed",
    "auth.stream_error",
  ]
  private static let runIDPattern = try! NSRegularExpression(
    pattern: #"^[A-Za-z0-9_-]{1,64}$"#
  )
  private static let commitPattern = try! NSRegularExpression(
    pattern: #"^[0-9a-f]{7,64}$"#
  )

  private let fileManager: FileManager
  private let applicationSupportDirectory: URL?
  private let commitReplacement: CommitReplacement

  init(
    fileManager: FileManager = .default,
    applicationSupportDirectory: URL? = nil,
    commitReplacement: CommitReplacement? = nil
  ) {
    self.fileManager = fileManager
    self.applicationSupportDirectory =
      applicationSupportDirectory
      ?? fileManager.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first
    self.commitReplacement =
      commitReplacement
      ?? { temporary, destination in
        if fileManager.fileExists(atPath: destination.path) {
          _ = try fileManager.replaceItemAt(
            destination,
            withItemAt: temporary,
            backupItemName: nil,
            options: []
          )
        } else {
          try fileManager.moveItem(at: temporary, to: destination)
        }
      }
  }

  func write(payload: String) throws {
    let data = Data(payload.utf8)
    guard data.count <= Self.maxPayloadBytes else {
      throw WriterError.payloadTooLarge
    }
    try Self.validate(data: data)
    guard let applicationSupportDirectory else {
      throw WriterError.applicationSupportUnavailable
    }

    let directory = applicationSupportDirectory
      .appendingPathComponent("RecallDiagnostics", isDirectory: true)
    let destination = directory
      .appendingPathComponent("operational-events-v2.json", isDirectory: false)
    try prepareDirectory(directory)

    let temporary = directory.appendingPathComponent(
      ".operational-events-v2.\(UUID().uuidString).tmp",
      isDirectory: false
    )
    defer { try? fileManager.removeItem(at: temporary) }

    try data.write(
      to: temporary,
      options: [
        .withoutOverwriting,
        .completeFileProtectionUntilFirstUserAuthentication,
      ]
    )
    try fileManager.setAttributes(
      [
        .posixPermissions: 0o600,
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
      ],
      ofItemAtPath: temporary.path
    )
    var fileResourceValues = URLResourceValues()
    fileResourceValues.isExcludedFromBackup = true
    var mutableTemporary = temporary
    try mutableTemporary.setResourceValues(fileResourceValues)

    try commitReplacement(temporary, destination)
  }

  private func prepareDirectory(_ directory: URL) throws {
    try fileManager.createDirectory(
      at: directory,
      withIntermediateDirectories: true,
      attributes: [
        .posixPermissions: 0o700,
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
      ]
    )
    try fileManager.setAttributes(
      [
        .posixPermissions: 0o700,
        .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
      ],
      ofItemAtPath: directory.path
    )
    var directoryResourceValues = URLResourceValues()
    directoryResourceValues.isExcludedFromBackup = true
    var mutableDirectory = directory
    try mutableDirectory.setResourceValues(directoryResourceValues)
  }

  private static func validate(data: Data) throws {
    let root = try JSONSerialization.jsonObject(with: data)
    guard let events = root as? [[String: Any]] else {
      throw WriterError.invalidEnvelope
    }
    guard events.count <= 100, events.allSatisfy({ validate(event: $0) }) else {
      throw WriterError.invalidEnvelope
    }
  }

  private static func validate(event: [String: Any]) -> Bool {
    let keys = Set(event.keys)
    guard
      requiredKeys.isSubset(of: keys),
      keys.isSubset(of: requiredKeys.union(optionalKeys)),
      event["schema"] as? String == "operational-event/v2",
      event["project"] as? String == "recall",
      event["level"] as? String == "error",
      let component = event["component"] as? String,
      components.contains(component),
      let operation = event["operation"] as? String,
      operations.contains(operation),
      let outcome = event["outcome"] as? String,
      outcomes.contains(outcome),
      let causeCode = event["cause_code"] as? String,
      causeCodes.contains(causeCode),
      isBoolean(event["retryable"]),
      let timestamp = event["timestamp"] as? String,
      isTimestamp(timestamp),
      let runID = event["run_id"] as? String,
      matches(runID, pattern: runIDPattern)
    else {
      return false
    }

    if let commitSHA = event["commit_sha"] {
      guard
        let value = commitSHA as? String,
        matches(value, pattern: commitPattern)
      else {
        return false
      }
    }
    if let exitCode = event["exit_code"], !isInteger(exitCode) {
      return false
    }
    if let duration = event["duration_ms"] {
      guard isInteger(duration), (duration as! NSNumber).int64Value >= 0 else {
        return false
      }
    }
    return true
  }

  private static func isBoolean(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  private static func isInteger(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    let numericType = String(cString: number.objCType)
    return CFGetTypeID(number) != CFBooleanGetTypeID()
      && !["f", "d"].contains(numericType)
  }

  private static func isTimestamp(_ value: String) -> Bool {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if fractional.date(from: value) != nil { return true }
    return ISO8601DateFormatter().date(from: value) != nil
  }

  private static func matches(
    _ value: String,
    pattern: NSRegularExpression
  ) -> Bool {
    let range = NSRange(value.startIndex..., in: value)
    return pattern.firstMatch(in: value, range: range) != nil
  }

  private enum WriterError: Error {
    case applicationSupportUnavailable
    case invalidEnvelope
    case payloadTooLarge
  }
}
