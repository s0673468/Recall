import Flutter
import UIKit
import XCTest
@testable import Runner

private final class MockStudyNotificationCenter: RecallStudyNotificationCenter {
  var authorizationGranted = true
  var authorizationCalls = 0
  var removedIdentifiers: [[String]] = []
  var addedRequests: [UNNotificationRequest] = []
  var addError: Error?

  func requestAuthorization(
    options: UNAuthorizationOptions,
    completionHandler: @escaping @Sendable (Bool, Error?) -> Void
  ) {
    authorizationCalls += 1
    completionHandler(authorizationGranted, nil)
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    removedIdentifiers.append(identifiers)
  }

  func add(
    _ request: UNNotificationRequest,
    withCompletionHandler completionHandler: (@Sendable (Error?) -> Void)?
  ) {
    addedRequests.append(request)
    completionHandler?(addError)
  }
}

class RunnerTests: XCTestCase {

  private let validPayload = """
  [{"schema":"operational-event/v2","timestamp":"2026-07-28T15:00:00.000Z","level":"error","project":"recall","component":"auth","operation":"observe_auth_state","outcome":"failed","cause_code":"auth.stream_error","retryable":true,"run_id":"run-test"}]
  """

  func testDiagnosticsWriterCreatesPrivateProtectedExcludedFile() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = RecallOperationalDiagnosticsWriter(
      applicationSupportDirectory: root
    )

    try writer.write(payload: validPayload)

    let directory = root.appendingPathComponent("RecallDiagnostics", isDirectory: true)
    let file = directory.appendingPathComponent("operational-events-v2.json")
    let directoryAttributes = try FileManager.default.attributesOfItem(
      atPath: directory.path
    )
    let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
    let resourceValues = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])

    XCTAssertEqual(directoryAttributes[.posixPermissions] as? NSNumber, 0o700)
    XCTAssertEqual(fileAttributes[.posixPermissions] as? NSNumber, 0o600)
    let protection = fileAttributes[.protectionKey] as? FileProtectionType
    #if targetEnvironment(simulator)
      // The simulator may omit protection metadata even when the write option
      // and explicit attribute are accepted. A physical device must report it.
      XCTAssertTrue(
        protection == nil
          || protection == .completeUntilFirstUserAuthentication
      )
    #else
      XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
    #endif
    XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), validPayload)
  }

  func testInvalidOrOversizedPayloadLeavesPreviousFileUntouched() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = RecallOperationalDiagnosticsWriter(
      applicationSupportDirectory: root
    )
    try writer.write(payload: validPayload)
    let file = root
      .appendingPathComponent("RecallDiagnostics", isDirectory: true)
      .appendingPathComponent("operational-events-v2.json")

    XCTAssertThrowsError(try writer.write(payload: "{bad json"))
    XCTAssertThrowsError(
      try writer.write(payload: "[\"\(String(repeating: "x", count: 64 * 1024))\"]")
    )
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), validPayload)
  }

  func testUnknownPrivateKeyLeavesPreviousFileUntouched() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = RecallOperationalDiagnosticsWriter(
      applicationSupportDirectory: root
    )
    try writer.write(payload: validPayload)
    let file = root
      .appendingPathComponent("RecallDiagnostics", isDirectory: true)
      .appendingPathComponent("operational-events-v2.json")
    let payload = validPayload.replacingOccurrences(
      of: "\"run_id\":\"run-test\"",
      with: "\"run_id\":\"run-test\",\"card_id\":42"
    )

    XCTAssertThrowsError(try writer.write(payload: payload))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), validPayload)
  }

  func testMoreThanRingCapacityLeavesPreviousFileUntouched() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = RecallOperationalDiagnosticsWriter(
      applicationSupportDirectory: root
    )
    try writer.write(payload: validPayload)
    let file = root
      .appendingPathComponent("RecallDiagnostics", isDirectory: true)
      .appendingPathComponent("operational-events-v2.json")
    let event = String(validPayload.dropFirst().dropLast())
    let payload = "[\(Array(repeating: event, count: 101).joined(separator: ","))]"

    XCTAssertThrowsError(try writer.write(payload: payload))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), validPayload)
  }

  func testCommitFailureLeavesPreviousFileUntouched() throws {
    let root = try temporaryRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = RecallOperationalDiagnosticsWriter(
      applicationSupportDirectory: root
    )
    try writer.write(payload: validPayload)
    let failingWriter = RecallOperationalDiagnosticsWriter(
      applicationSupportDirectory: root,
      commitReplacement: { _, _ in
        throw CocoaError(.fileWriteUnknown)
      }
    )
    let file = root
      .appendingPathComponent("RecallDiagnostics", isDirectory: true)
      .appendingPathComponent("operational-events-v2.json")

    XCTAssertThrowsError(try failingWriter.write(payload: validPayload))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), validPayload)
  }

  func testStudyReminderDueZeroCancelsWithoutScheduling() {
    let center = MockStudyNotificationCenter()
    let plugin = makeReminderPlugin(center: center)

    callReminder(
      plugin,
      method: "apply",
      arguments: [
        "enabled": true,
        "hour": 19,
        "minute": 0,
        "dueCount": 0,
        "studiedToday": false,
      ]
    )

    XCTAssertEqual(center.addedRequests, [])
    XCTAssertEqual(center.removedIdentifiers.count, 1)
  }

  func testStudyReminderDisabledSettingCancelsWithoutDueSnapshot() {
    let center = MockStudyNotificationCenter()
    let plugin = makeReminderPlugin(center: center)

    callReminder(
      plugin,
      method: "apply",
      arguments: [
        "enabled": false,
        "hour": 19,
        "minute": 0,
        "studiedToday": true,
      ]
    )

    XCTAssertEqual(center.addedRequests, [])
    XCTAssertEqual(center.removedIdentifiers.count, 1)
  }

  func testStudyReminderStudiedTodayCancelsWithoutScheduling() {
    let center = MockStudyNotificationCenter()
    let plugin = makeReminderPlugin(center: center)

    callReminder(
      plugin,
      method: "apply",
      arguments: [
        "enabled": true,
        "hour": 19,
        "minute": 0,
        "dueCount": 3,
        "studiedToday": true,
      ]
    )

    XCTAssertEqual(center.addedRequests, [])
    XCTAssertEqual(center.removedIdentifiers.count, 1)
  }

  func testStudyReminderDueAndNotStudiedSchedulesOneUpcomingEveningSlot() {
    let center = MockStudyNotificationCenter()
    let plugin = makeReminderPlugin(center: center)

    callReminder(
      plugin,
      method: "apply",
      arguments: [
        "enabled": true,
        "hour": 19,
        "minute": 0,
        "dueCount": 3,
        "studiedToday": false,
      ]
    )

    XCTAssertEqual(center.addedRequests.count, 1)
    let request = center.addedRequests[0]
    XCTAssertEqual(request.identifier, RecallStudyReminderPlugin.notificationIdentifier)
    XCTAssertEqual(request.content.title, "Time to Recall")
    XCTAssertEqual(request.content.body, "A short review now keeps tomorrow's queue lighter.")
    XCTAssertEqual(request.content.userInfo["url"] as? String, "recall://study")
    let trigger = request.trigger as? UNCalendarNotificationTrigger
    XCTAssertNotNil(trigger)
    XCTAssertFalse(trigger?.repeats ?? true)
    XCTAssertEqual(trigger?.dateComponents.year, 2026)
    XCTAssertEqual(trigger?.dateComponents.month, 8)
    XCTAssertEqual(trigger?.dateComponents.day, 5)
    XCTAssertEqual(trigger?.dateComponents.hour, 19)
    XCTAssertEqual(trigger?.dateComponents.minute, 0)
  }

  func testStudyReminderRescheduleReplacesThePendingEveningSlot() {
    let center = MockStudyNotificationCenter()
    let plugin = makeReminderPlugin(center: center)

    callReminder(
      plugin,
      method: "apply",
      arguments: [
        "enabled": true,
        "hour": 19,
        "minute": 0,
        "dueCount": 3,
        "studiedToday": false,
      ]
    )
    callReminder(
      plugin,
      method: "apply",
      arguments: [
        "enabled": true,
        "hour": 20,
        "minute": 30,
        "dueCount": 3,
        "studiedToday": false,
      ]
    )

    XCTAssertEqual(center.removedIdentifiers.count, 2)
    XCTAssertEqual(center.addedRequests.count, 2)
    let trigger = center.addedRequests.last?.trigger as? UNCalendarNotificationTrigger
    XCTAssertEqual(trigger?.dateComponents.hour, 20)
    XCTAssertEqual(trigger?.dateComponents.minute, 30)
  }

  func testStudyReminderAfterTheSlotUsesTheNextLocalEvening() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -3)!
    let now = calendar.date(
      from: DateComponents(year: 2026, month: 8, day: 5, hour: 20, minute: 0)
    )!

    let request = RecallStudyReminderPlugin.makeRequest(
      hour: 19,
      minute: 0,
      now: now,
      calendar: calendar
    )
    let trigger = request?.trigger as? UNCalendarNotificationTrigger

    XCTAssertEqual(trigger?.dateComponents.year, 2026)
    XCTAssertEqual(trigger?.dateComponents.month, 8)
    XCTAssertEqual(trigger?.dateComponents.day, 6)
    XCTAssertEqual(trigger?.dateComponents.hour, 19)
    XCTAssertEqual(trigger?.dateComponents.minute, 0)
  }

  func testStudyReminderCancelRemovesThePendingSlot() {
    let center = MockStudyNotificationCenter()
    let plugin = makeReminderPlugin(center: center)

    callReminder(plugin, method: "cancel", arguments: nil)

    XCTAssertEqual(center.removedIdentifiers, [[RecallStudyReminderPlugin.notificationIdentifier]])
    XCTAssertEqual(center.addedRequests, [])
  }

  func testStudyReminderPermissionUsesTheExistingAuthorizationGate() {
    let center = MockStudyNotificationCenter()
    center.authorizationGranted = false
    let plugin = makeReminderPlugin(center: center)
    var granted: Bool?
    let permissionExpectation = expectation(description: "permission result")

    plugin.handle(FlutterMethodCall(methodName: "requestPermission", arguments: nil)) {
      granted = $0 as? Bool
      permissionExpectation.fulfill()
    }

    wait(for: [permissionExpectation], timeout: 1)
    XCTAssertEqual(center.authorizationCalls, 1)
    XCTAssertEqual(granted, false)
  }

  private func makeReminderPlugin(
    center: MockStudyNotificationCenter
  ) -> RecallStudyReminderPlugin {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: -3)!
    let now = calendar.date(
      from: DateComponents(year: 2026, month: 8, day: 5, hour: 18, minute: 30)
    )!
    return RecallStudyReminderPlugin(
      notificationCenter: center,
      now: { now },
      calendar: calendar
    )
  }

  private func callReminder(
    _ plugin: RecallStudyReminderPlugin,
    method: String,
    arguments: [String: Any]?
  ) {
    plugin.handle(FlutterMethodCall(methodName: method, arguments: arguments)) { _ in }
  }

  private func temporaryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    return root
  }

}
