import Flutter
import UIKit
import XCTest
@testable import Runner

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
