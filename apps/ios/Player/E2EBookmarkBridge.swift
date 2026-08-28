#if E2E
import Observation
import SwiftUI

final class E2EBookmarkClock: PlayerClock, @unchecked Sendable {
  private struct State: Codable {
    let schemaVersion: Int
    let secondsSince1970: TimeInterval
  }

  private static let schemaVersion = 1
  private static let stateKeys: Set<String> = ["schemaVersion", "secondsSince1970"]

  private let lock = NSLock()
  private let initialValue: Date
  private let stateURL: URL
  private var value: Date

  init(value initialValue: Date, stateURL: URL) throws {
    guard initialValue.timeIntervalSince1970.isFinite else {
      throw E2EBookmarkClockError.invalidInitialValue
    }
    self.initialValue = initialValue
    self.stateURL = stateURL
    if FileManager.default.fileExists(atPath: stateURL.path) {
      value = try Self.load(from: stateURL, noEarlierThan: initialValue)
    } else {
      try FileManager.default.createDirectory(
        at: stateURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Self.persist(initialValue, to: stateURL)
      value = initialValue
    }
  }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(by seconds: TimeInterval) throws {
    try lock.withLock {
      guard seconds.isFinite, seconds >= 0 else {
        throw E2EBookmarkClockError.invalidAdvance
      }
      let advanced = value.addingTimeInterval(seconds)
      guard advanced.timeIntervalSince1970.isFinite, advanced >= initialValue else {
        throw E2EBookmarkClockError.invalidAdvance
      }
      try Self.persist(advanced, to: stateURL)
      value = advanced
    }
  }

  private static func load(from stateURL: URL, noEarlierThan initialValue: Date) throws -> Date {
    let data = try Data(contentsOf: stateURL)
    let object: [String: Any]
    do {
      guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw E2EBookmarkClockError.invalidState
      }
      object = decoded
    } catch {
      throw E2EBookmarkClockError.invalidState
    }
    guard Set(object.keys) == stateKeys else { throw E2EBookmarkClockError.invalidState }
    let state: State
    do {
      state = try JSONDecoder().decode(State.self, from: data)
    } catch {
      throw E2EBookmarkClockError.invalidState
    }
    guard state.schemaVersion == schemaVersion,
      state.secondsSince1970.isFinite,
      state.secondsSince1970 >= initialValue.timeIntervalSince1970
    else {
      throw E2EBookmarkClockError.invalidState
    }
    return Date(timeIntervalSince1970: state.secondsSince1970)
  }

  private static func persist(_ value: Date, to stateURL: URL) throws {
    let state = State(
      schemaVersion: schemaVersion,
      secondsSince1970: value.timeIntervalSince1970
    )
    try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
  }
}

enum E2EBookmarkClockError: Error, Equatable {
  case invalidInitialValue
  case invalidState
  case invalidAdvance
}

@MainActor
@Observable
final class E2EBookmarkBridge {
  static let shared = E2EBookmarkBridge()

  @ObservationIgnored private var clock: E2EBookmarkClock?
  private(set) var clockEpochSeconds: Int64?
  private(set) var clockAdvanceFailed = false

  var isConfigured: Bool { clock != nil }

  func configure(clock: E2EBookmarkClock) {
    self.clock = clock
    clockEpochSeconds = Int64(clock.now().timeIntervalSince1970)
    clockAdvanceFailed = false
  }

  func advanceClock() -> Bool {
    guard let clock else {
      clockAdvanceFailed = true
      return false
    }
    do {
      try clock.advance(by: 60)
      clockEpochSeconds = Int64(clock.now().timeIntervalSince1970)
      return true
    } catch {
      clockAdvanceFailed = true
      return false
    }
  }
}

@MainActor
struct E2EBookmarkControlSurface: View {
  @Bindable var model: PlayerModel
  @State private var positionControlVisible = true

  var body: some View {
    ZStack {
      E2EBookmarkStateProbe(model: model)
      if positionControlVisible {
        Button {
          Task {
            await model.seek(to: 15, context: .wholeBook)
            if E2EBookmarkBridge.shared.advanceClock() {
              positionControlVisible = false
            }
          }
        } label: {
          Color.white.opacity(0.001)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Prepare second bookmark position")
        .accessibilityIdentifier("e2e-bookmark-second-position")
      }
    }
    .frame(width: 44, height: 44)
  }

}

@MainActor
struct E2EBookmarkStateProbe: View {
  @Bindable var model: PlayerModel

  var body: some View {
    StateProbe(id: "bookmarks-state-probe", value: stateValue)
  }

  private var stateValue: String {
    let bookmarks = model.library.bookmarks
    let bookmarkOrder = bookmarks.map { $0.id.uuidString.lowercased() }.joined(separator: ",")
    let bookmarkValues = bookmarks.map { bookmark in
      [
        bookmark.id.uuidString.lowercased(),
        String(bookmark.bookPositionMilliseconds),
        bookmark.assetID.uuidString.lowercased(),
        String(bookmark.assetPositionMilliseconds),
        bookmark.chapterID ?? "none",
        bookmark.label,
        bookmark.note ?? "none",
        String(Int(bookmark.createdAt.timeIntervalSince1970)),
        String(Int(bookmark.updatedAt.timeIntervalSince1970)),
      ].joined(separator: "~")
    }.joined(separator: ";")
    let transactions = model.library.bookmarkDeletionTransactions
    let transactionValues = transactions.map { transaction in
      [
        transaction.id.uuidString.lowercased(),
        transaction.bookmark.id.uuidString.lowercased(),
        String(transaction.originalIndex),
        transaction.status.rawValue,
        String(Int(transaction.deletedAt.timeIntervalSince1970)),
        transaction.undoneAt.map { String(Int($0.timeIntervalSince1970)) } ?? "none",
      ].joined(separator: "~")
    }.joined(separator: ";")
    let clockValue: String
    if E2EBookmarkBridge.shared.clockAdvanceFailed {
      clockValue = "error"
    } else if let epoch = E2EBookmarkBridge.shared.clockEpochSeconds {
      clockValue = String(epoch)
    } else {
      clockValue = "unconfigured"
    }
    let position = model.library.playbackPosition?.positionMilliseconds ?? 0
    let journal = model.library.positionJournal.map {
      "\($0.sequence):\($0.reason.rawValue)@\($0.positionMilliseconds)"
    }.joined(separator: ",")
    return [
      "bookmarks",
      "schema=1",
      "count=\(bookmarks.count)",
      "order=\(bookmarkOrder.isEmpty ? "none" : bookmarkOrder)",
      "items=\(bookmarkValues.isEmpty ? "none" : bookmarkValues)",
      "transactions=\(transactions.count)",
      "deletions=\(transactionValues.isEmpty ? "none" : transactionValues)",
      "clock=\(clockValue)",
      "position=\(position)",
      "journal=\(journal)",
    ].joined(separator: "|")
  }
}
#endif
