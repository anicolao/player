#if E2E
import SwiftUI

final class E2EBookmarkClock: PlayerClock, @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(value: Date) { self.value = value }

  func now() -> Date {
    lock.lock()
    defer { lock.unlock() }
    return value
  }

  func advance(by seconds: TimeInterval) {
    lock.lock()
    value = value.addingTimeInterval(seconds)
    lock.unlock()
  }
}

@MainActor
final class E2EBookmarkBridge {
  static let shared = E2EBookmarkBridge()

  private(set) var clock: E2EBookmarkClock?

  var isConfigured: Bool { clock != nil }

  func configure(clock: E2EBookmarkClock) {
    self.clock = clock
  }

  func advanceClock() {
    clock?.advance(by: 60)
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
            E2EBookmarkBridge.shared.advanceClock()
            positionControlVisible = false
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
        transaction.undoneAt == nil ? "none" : "set",
      ].joined(separator: "~")
    }.joined(separator: ";")
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
      "position=\(position)",
      "journal=\(journal)",
    ].joined(separator: "|")
  }
}
#endif
