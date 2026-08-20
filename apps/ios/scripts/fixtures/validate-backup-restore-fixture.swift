#!/usr/bin/env xcrun swift

import Foundation

private struct Fixture: Decodable {
  struct Audio: Decodable {
    let file: String
    let byteCount: Int
    let sha256: String
    let logicalDurationMilliseconds: Int
  }

  struct Book: Decodable {
    let id: UUID
    let assetID: UUID
    let title: String
    let authors: [String]
    let narrators: [String]
    let series: String
    let seriesPosition: String
    let positionMilliseconds: Int
    let finished: Bool
  }

  struct Bookmark: Decodable {
    let id: UUID
    let bookID: UUID
    let positionMilliseconds: Int
    let label: String
    let note: String
  }

  struct Collection: Decodable {
    let id: UUID
    let name: String
    let bookIDs: [UUID]
  }

  struct Settings: Decodable {
    let playbackRate: Double
    let skipBackwardSeconds: Int
    let skipForwardSeconds: Int
    let smartRewindEnabled: Bool
    let smartRewindMaximumSeconds: Int
    let sleepTimerFadeEnabled: Bool
    let libraryView: String
  }

  let fixture: String
  let schemaVersion: Int
  let clock: String
  let audio: Audio
  let books: [Book]
  let bookmarks: [Bookmark]
  let collections: [Collection]
  let currentBookID: UUID
  let upNext: [UUID]
  let settings: Settings
}

private enum ValidationError: Error {
  case invalidArguments
  case invalidContract
}

private func id(_ suffix: Int) -> UUID {
  UUID(uuidString: String(format: "a1000000-0000-0000-0000-%012d", suffix))!
}

guard CommandLine.arguments.count == 2 else { throw ValidationError.invalidArguments }
private let fixture = try JSONDecoder().decode(
  Fixture.self,
  from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
)

guard
  fixture.fixture == "synthetic-backup-restore",
  fixture.schemaVersion == 1,
  fixture.clock == "2026-08-20T13:41:00Z",
  fixture.audio.file == "backup-restore-audio.m4b",
  fixture.audio.byteCount == 8_461,
  fixture.audio.sha256 == "6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7",
  fixture.audio.logicalDurationMilliseconds == 120_000,
  fixture.books.map(\.id) == [id(1), id(2)],
  fixture.books.map(\.assetID) == [id(101), id(102)],
  fixture.books.map(\.title) == ["Signal at Dawn", "Harbor of Glass"],
  fixture.books.map(\.authors) == [["Iris Vale"], ["Iris Vale"]],
  fixture.books.map(\.narrators) == [["Oren Pike"], ["Mara North"]],
  fixture.books.map(\.series) == ["Signal Maps", "Signal Maps"],
  fixture.books.map(\.seriesPosition) == ["1", "2"],
  fixture.books.map(\.positionMilliseconds) == [45_000, 120_000],
  fixture.books.map(\.finished) == [false, true],
  fixture.bookmarks.count == 1,
  fixture.bookmarks[0].id == id(301),
  fixture.bookmarks[0].bookID == id(1),
  fixture.bookmarks[0].positionMilliseconds == 42_000,
  fixture.bookmarks[0].label == "Opening Signal · 0:42",
  fixture.bookmarks[0].note == "Return to the quiet clue.",
  fixture.collections.count == 1,
  fixture.collections[0].id == id(401),
  fixture.collections[0].name == "Weekend Signals",
  fixture.collections[0].bookIDs == [id(2), id(1)],
  fixture.currentBookID == id(1),
  fixture.upNext == [id(1), id(2)],
  fixture.settings.playbackRate == 1.25,
  fixture.settings.skipBackwardSeconds == 15,
  fixture.settings.skipForwardSeconds == 30,
  fixture.settings.smartRewindEnabled,
  fixture.settings.smartRewindMaximumSeconds == 20,
  fixture.settings.sleepTimerFadeEnabled,
  fixture.settings.libraryView == "list"
else { throw ValidationError.invalidContract }
