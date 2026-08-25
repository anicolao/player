#!/usr/bin/env xcrun swift
import Foundation

private struct Fixture: Decodable {
  struct Audio: Decodable {
    var file: String
    var byteCount: Int64
    var sha256: String
    var encodedDurationMilliseconds: Int
    var logicalBookDurationMilliseconds: Int
  }
  struct Person: Decodable { var id: UUID; var name: String }
  struct Series: Decodable { var id: UUID; var name: String; var position: String }
  struct Book: Decodable {
    var id: UUID
    var assetID: UUID
    var title: String
    var author: Person
    var narrator: Person
    var series: Series?
    var cover: String
    var positionMilliseconds: Int
    var finished: Bool
    var addedOrder: Int
  }
  struct GeneratedIDs: Decodable { var collection: UUID; var trashTransaction: UUID }
  var fixture: String
  var schemaVersion: Int
  var clock: String
  var audio: Audio
  var books: [Book]
  var currentBookID: UUID
  var upNext: [UUID]
  var viewPreference: String
  var generatedIDs: GeneratedIDs
}

private enum ValidationError: Error { case invalidArguments; case invalidContract }
private func id(_ suffix: Int) -> UUID {
  UUID(uuidString: String(format: "90000000-0000-0000-0000-%012d", suffix))!
}

guard CommandLine.arguments.count == 2 else { throw ValidationError.invalidArguments }
private let fixture = try JSONDecoder().decode(
  Fixture.self,
  from: Data(contentsOf: URL(filePath: CommandLine.arguments[1]))
)
let bookIDs = fixture.books.map(\.id)
let assetIDs = fixture.books.map(\.assetID)
let coverNames = fixture.books.map(\.cover)
guard
  fixture.fixture == "synthetic-populated-library",
  fixture.schemaVersion == 1,
  fixture.clock == "2026-08-18T13:41:00Z",
  fixture.audio.file == "library-book-audio.m4b",
  fixture.audio.byteCount == 8_461,
  fixture.audio.sha256 == "6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7",
  fixture.audio.encodedDurationMilliseconds == 2_100,
  fixture.audio.logicalBookDurationMilliseconds == 120_000,
  bookIDs == (1...5).map(id),
  assetIDs == (101...105).map(id),
  Set(bookIDs).count == 5,
  Set(assetIDs).count == 5,
  coverNames == (1...5).map({ "library-cover-b\($0).png" }),
  fixture.books.map(\.addedOrder) == [1, 2, 3, 4, 5],
  fixture.books.map(\.title) == [
    "Ember at Daybreak", "Tides Between Stars", "The Clockwork Orchard",
    "A Lantern for Winter", "Quiet Maps",
  ],
  fixture.books.map(\.positionMilliseconds) == [45_000, 0, 30_000, 120_000, 0],
  fixture.books.map(\.finished) == [false, false, false, true, false],
  fixture.books.compactMap(\.series?.name) == [
    "Wayfinder", "Wayfinder", "Orchard Hours", "Orchard Hours",
  ],
  fixture.currentBookID == id(1),
  fixture.upNext == [id(2), id(5), id(3)],
  fixture.viewPreference == "shelf",
  fixture.generatedIDs.collection == id(501),
  fixture.generatedIDs.trashTransaction == id(601)
else { throw ValidationError.invalidContract }
