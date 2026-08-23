#!/usr/bin/env xcrun swift
import Foundation

private struct Fixture: Decodable {
  struct IDs: Decodable {
    var job: UUID
    var proposal: UUID
    var asset: UUID
    var book: UUID
  }

  struct Audio: Decodable {
    var file: String
    var byteCount: Int64
    var sha256: String
  }

  struct Field: Decodable {
    var value: String?
    var values: [String]?
    var name: String?
    var position: String?
    var source: String
    var confidence: String
  }

  struct Cover: Decodable {
    var file: String
    var source: String
  }

  struct Proposal: Decodable {
    var title: Field
    var authors: Field
    var narrators: Field
    var series: Field
    var cover: Cover
  }

  struct Repair: Decodable {
    var title: String
    var explicitlyClear: [String]
    var explicitlyLock: [String]
    var replacementCover: String
    var undoRestores: String
  }

  var fixture: String
  var ids: IDs
  var audio: Audio
  var proposal: Proposal
  var repair: Repair
}

private enum ValidationError: Error {
  case invalidArguments
  case invalidContract
}

guard CommandLine.arguments.count == 2 else { throw ValidationError.invalidArguments }
private let fixture = try JSONDecoder().decode(
  Fixture.self,
  from: Data(contentsOf: URL(filePath: CommandLine.arguments[1]))
)
guard
  fixture.fixture == "synthetic-metadata-repair",
  fixture.ids.job == UUID(uuidString: "80000000-0000-0000-0000-000000000001"),
  fixture.ids.proposal == UUID(uuidString: "80000000-0000-0000-0000-000000000002"),
  fixture.ids.asset == UUID(uuidString: "80000000-0000-0000-0000-000000000003"),
  fixture.ids.book == UUID(uuidString: "80000000-0000-0000-0000-000000000004"),
  fixture.audio.file == "metadata-repair-source.m4b",
  fixture.audio.byteCount == 8_461,
  fixture.audio.sha256 == "6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7",
  fixture.proposal.title.value == "The Brass Lantern",
  fixture.proposal.title.source == "embedded-tag",
  fixture.proposal.authors.values == ["Mira Sol"],
  fixture.proposal.narrators.values == ["Anika Reed"],
  fixture.proposal.series.name == "Night Signals",
  fixture.proposal.series.position == "4",
  fixture.proposal.cover.source == "embedded-artwork",
  fixture.repair.title == "The Amber Signal",
  fixture.repair.explicitlyClear == ["narrators"],
  fixture.repair.explicitlyLock == ["series"],
  fixture.repair.replacementCover == "metadata-repair-replacement-cover.png",
  fixture.repair.undoRestores == "proposal-revision-0"
else { throw ValidationError.invalidContract }
