import AppIntents
import SwiftUI
import WidgetKit

private enum RecallWidgetStore {
  static let suiteName = "group.com.german.ankiReview"
  static let dueCountKey = "due_count"
  static let updatedAtKey = "updated_at"
  static let staleAfter: TimeInterval = 12 * 60 * 60

  static func snapshot(now: Date = Date()) -> RecallDueEntry {
    guard
      let defaults = UserDefaults(suiteName: suiteName),
      defaults.object(forKey: dueCountKey) != nil,
      defaults.object(forKey: updatedAtKey) != nil
    else {
      return RecallDueEntry(date: now, dueCount: nil, updatedAt: nil)
    }
    return RecallDueEntry(
      date: now,
      dueCount: max(0, defaults.integer(forKey: dueCountKey)),
      updatedAt: Date(
        timeIntervalSince1970: defaults.double(forKey: updatedAtKey)
      )
    )
  }
}

struct StartStudyIntent: AppIntent {
  static var title: LocalizedStringResource = "Start Study"
  static var description = IntentDescription(
    "Opens Recall directly on the Study surface."
  )

  func perform() async throws -> some IntentResult & OpensIntent {
    .result(opensIntent: OpenURLIntent(URL(string: "recall://study")!))
  }
}

struct RecallDueEntry: TimelineEntry {
  let date: Date
  let dueCount: Int?
  let updatedAt: Date?

  var isStale: Bool {
    guard let updatedAt else { return true }
    return date.timeIntervalSince(updatedAt) > RecallWidgetStore.staleAfter
  }
}

struct RecallDueProvider: TimelineProvider {
  func placeholder(in context: Context) -> RecallDueEntry {
    RecallDueEntry(date: Date(), dueCount: 12, updatedAt: Date())
  }

  func getSnapshot(
    in context: Context,
    completion: @escaping (RecallDueEntry) -> Void
  ) {
    completion(RecallWidgetStore.snapshot())
  }

  func getTimeline(
    in context: Context,
    completion: @escaping (Timeline<RecallDueEntry>) -> Void
  ) {
    let entry = RecallWidgetStore.snapshot()
    // Re-evaluate freshness without waking the app or touching the network.
    let refresh = Date().addingTimeInterval(30 * 60)
    completion(Timeline(entries: [entry], policy: .after(refresh)))
  }
}

struct RecallDueWidgetView: View {
  let entry: RecallDueEntry

  private let navy = Color(red: 0.07, green: 0.08, blue: 0.16)
  private let yellow = Color(red: 0.99, green: 0.88, blue: 0.28)
  private let muted = Color(red: 0.66, green: 0.67, blue: 0.75)

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("RECALL")
          .font(.system(size: 11, weight: .bold, design: .rounded))
          .tracking(1.3)
          .foregroundStyle(yellow)
        Spacer()
        if entry.isStale {
          Image(systemName: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(muted)
            .accessibilityLabel("Due count may be stale")
        }
      }

      if let dueCount = entry.dueCount {
        Text("\(dueCount)")
          .font(.system(size: 38, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .contentTransition(.numericText())
        Text(dueCount == 1 ? "card due" : "cards due")
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(muted)
      } else {
        Text("Open Recall")
          .font(.system(size: 21, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
        Text("to load your due count")
          .font(.caption)
          .foregroundStyle(muted)
      }

      Button(intent: StartStudyIntent()) {
        Label("Start Study", systemImage: "play.fill")
          .font(.system(size: 12, weight: .bold, design: .rounded))
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.small)
      .tint(yellow)
      .foregroundStyle(navy)

      if let updatedAt = entry.updatedAt {
        HStack(spacing: 3) {
          Text(entry.isStale ? "Stale" : "Updated")
          Text(updatedAt, style: .relative)
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
        .foregroundStyle(muted)
        .lineLimit(1)
      }
    }
    .containerBackground(navy, for: .widget)
    .widgetURL(URL(string: "recall://study"))
  }
}

struct RecallDueWidget: Widget {
  static let kind = "RecallDueWidget"

  var body: some WidgetConfiguration {
    StaticConfiguration(kind: Self.kind, provider: RecallDueProvider()) {
      entry in
      RecallDueWidgetView(entry: entry)
    }
    .configurationDisplayName("Recall Due")
    .description("See what is due and jump straight into Study.")
    .supportedFamilies([.systemSmall, .systemMedium])
  }
}

@main
struct RecallWidgetBundle: WidgetBundle {
  var body: some Widget {
    RecallDueWidget()
  }
}
