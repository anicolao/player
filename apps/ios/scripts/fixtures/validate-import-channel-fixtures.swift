#!/usr/bin/env xcrun swift
import Foundation

private struct FixtureDescriptor: Decodable {
  struct DocumentOpen: Decodable {
    var file: String
    var jobID: UUID
    var byteCount: Int64
    var sha256: String
  }

  struct ShareExtension: Decodable {
    var file: String
    var envelope: String
    var handoffID: UUID
    var jobID: UUID
    var byteCount: Int64
    var sha256: String
  }

  var fixture: String
  var documentOpen: DocumentOpen
  var shareExtension: ShareExtension
}

private struct ShareImportHandoff: Decodable {
  struct Item: Decodable {
    var relativePath: String
    var originalFilename: String
    var contentTypeIdentifier: String?
    var byteCount: Int64
    var checksumSHA256: String
  }

  var schemaVersion: Int
  var id: UUID
  var createdAt: Date
  var items: [Item]
}

private enum ValidationError: Error {
  case invalidArguments
  case invalidContract
}

guard CommandLine.arguments.count == 3 else { throw ValidationError.invalidArguments }
private let decoder = JSONDecoder()
decoder.dateDecodingStrategy = .iso8601
private let descriptor = try decoder.decode(
  FixtureDescriptor.self,
  from: Data(contentsOf: URL(filePath: CommandLine.arguments[1]))
)
private let handoff = try decoder.decode(
  ShareImportHandoff.self,
  from: Data(contentsOf: URL(filePath: CommandLine.arguments[2]))
)
guard
  descriptor.fixture == "synthetic-import-channels",
  descriptor.documentOpen.file == "document-open-interrupted-acquire.m4a",
  descriptor.documentOpen.byteCount == 9_350,
  descriptor.shareExtension.file == "share-extension-handoff.m4a",
  descriptor.shareExtension.envelope == "share-extension-envelope.json",
  descriptor.shareExtension.handoffID == handoff.id,
  descriptor.shareExtension.byteCount == 9_183,
  handoff.schemaVersion == 1,
  handoff.items.count == 1,
  handoff.items[0].relativePath == "Items/00000.m4a",
  handoff.items[0].contentTypeIdentifier == "public.mpeg-4-audio",
  handoff.items[0].byteCount == descriptor.shareExtension.byteCount,
  handoff.items[0].checksumSHA256 == descriptor.shareExtension.sha256
else { throw ValidationError.invalidContract }
