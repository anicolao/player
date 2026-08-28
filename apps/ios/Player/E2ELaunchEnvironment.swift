import CryptoKit
import Foundation
import Observation
import Security
import UIKit

struct E2EPersistedLibrary {
  let snapshot: LibrarySnapshot
  let encoded: String

  static func load(from libraryURL: URL) throws -> E2EPersistedLibrary? {
    guard FileManager.default.fileExists(atPath: libraryURL.path) else { return nil }
    let data = try Data(contentsOf: libraryURL)
    guard let encoded = String(data: data, encoding: .utf8) else {
      throw PlayerCoreError.fileOperation("The persisted E2E library is not UTF-8 JSON.")
    }
    struct Envelope: Decodable {
      var library: LibrarySnapshot
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(Envelope.self, from: data)
    return E2EPersistedLibrary(snapshot: envelope.library, encoded: encoded)
  }
}

struct E2EPlaybackControlConfiguration: Equatable {
  static let configurationOSStatusArgument = "-e2e-audio-session-configure-osstatus"

  static let disabled = E2EPlaybackControlConfiguration(
    eventControls: false,
    rewindExpiryControl: false,
    configurationOSStatus: nil
  )

  let eventControls: Bool
  let rewindExpiryControl: Bool
  let configurationOSStatus: Int?
}

enum E2EFixture: String, CaseIterable {
  case emptyLibrary = "empty-library"
  case singleAudiobookReady = "single-audiobook-ready"
  case receiverCompletionBaseline = "receiver-completion-baseline"
  case committedCurrentBook = "committed-current-book"
  case monetizationExhausted = "monetization-exhausted"
  case zeroDurationCurrentBook = "zero-duration-current-book"
  case metadataRichBook = "metadata-rich-book"
  case messyMultifileUnicode = "messy-multifile-unicode"
  case safeZipImport = "safe-zip-import"
  case importRecoveryStorage = "import-recovery-storage"
  case syntheticImportChannels = "synthetic-import-channels"
  case syntheticMetadataRepair = "synthetic-metadata-repair"
  case syntheticCommittedMetadata = "synthetic-committed-metadata"
  case syntheticPopulatedLibrary = "synthetic-populated-library"
  case syntheticPermanentTrash = "synthetic-permanent-trash"
  case smartRewind = "smart-rewind"
  case sleepTimer = "sleep-timer"
  case bookmarks
  case portableBackup = "portable-backup"
  case offlineRecovery = "offline-recovery"
}

struct E2ELaunchConfiguration: Equatable {
  enum ResetPolicy: Equatable {
    case preserve
    case reset

    var shouldReset: Bool { self == .reset }
  }

  static let modeArgument = "-e2e"
  static let fixtureArgument = "-e2e-fixture"
  static let resetArgument = "-e2e-reset"

  let fixture: E2EFixture
  let resetPolicy: ResetPolicy
  private let resetLease: E2EFixtureResetLease

  init(fixture: E2EFixture, resetPolicy: ResetPolicy) {
    self.fixture = fixture
    self.resetPolicy = resetPolicy
    resetLease = E2EFixtureResetLease(shouldReset: resetPolicy.shouldReset)
  }

  static func == (lhs: E2ELaunchConfiguration, rhs: E2ELaunchConfiguration) -> Bool {
    lhs.fixture == rhs.fixture && lhs.resetPolicy == rhs.resetPolicy
  }

  func consumeReset() -> Bool {
    resetLease.consume()
  }

  static func parse(arguments: [String]) throws -> E2ELaunchConfiguration? {
    let e2eArguments = arguments.filter { $0.hasPrefix("-e2e") }
    guard !e2eArguments.isEmpty else { return nil }

    if let unknown = e2eArguments.first(where: { !recognizedArguments.contains($0) }) {
      throw PlayerCoreError.fileOperation("Unknown E2E launch option: \(unknown)")
    }

    let modeCount = arguments.filter { $0 == modeArgument }.count
    guard modeCount == 1 else {
      let reason = modeCount == 0 ? "Missing" : "Duplicate"
      throw PlayerCoreError.fileOperation("\(reason) top-level E2E mode marker.")
    }

    for argument in recognizedArguments {
      guard arguments.filter({ $0 == argument }).count <= 1 else {
        throw PlayerCoreError.fileOperation("Duplicate E2E launch option: \(argument)")
      }
    }

    for argument in valueArguments {
      guard let index = arguments.firstIndex(of: argument) else { continue }
      guard arguments.indices.contains(index + 1) else {
        throw PlayerCoreError.fileOperation("Missing E2E launch value for: \(argument)")
      }
      let value = arguments[index + 1]
      let acceptsSignedInteger = argument == E2EPlaybackControlConfiguration
        .configurationOSStatusArgument && Int(value) != nil
      guard !value.isEmpty, !value.hasPrefix("-") || acceptsSignedInteger else {
        throw PlayerCoreError.fileOperation("Invalid E2E launch value for: \(argument)")
      }
    }

    guard let fixtureIndex = arguments.firstIndex(of: fixtureArgument) else {
      throw PlayerCoreError.fileOperation("Missing top-level E2E fixture marker.")
    }
    let fixtureValue = arguments[fixtureIndex + 1]
    guard let fixture = E2EFixture(rawValue: fixtureValue) else {
      throw PlayerCoreError.fileOperation("Invalid top-level E2E fixture: \(fixtureValue)")
    }

    return E2ELaunchConfiguration(
      fixture: fixture,
      resetPolicy: arguments.contains(resetArgument) ? .reset : .preserve
    )
  }

  // This is the complete public launch-argument vocabulary owned by the E2E
  // harness. Keeping it centralized prevents a misspelled test option from
  // silently selecting a different fixture or the production environment.
  private static let flagArguments: Set<String> = [
    modeArgument,
    resetArgument,
    "-e2e-event-controls",
    "-e2e-rewind-expiry-control",
    "-e2e-computer-receiver-ready",
    "-e2e-mirroring-drop-progress",
    "-e2e-computer-receiver-completed",
    "-e2e-computer-receiver-paused",
    "-e2e-show-mirroring-tip",
    "-e2e-hide-mirroring-tip",
  ]

  private static let valueArguments: Set<String> = [
    fixtureArgument,
    "-e2e-metadata-rich-namespace",
    "-e2e-committed-metadata-namespace",
    "-e2e-sleep-timer-namespace",
    "-e2e-smart-rewind-scenario",
    "-e2e-recovery-scenario",
    "-e2e-zip-case",
    "-e2e-zip-limits",
    "-e2e-zip-fail-once",
    "-e2e-import-channel",
    "-e2e-import-pause",
    E2EPlaybackControlConfiguration.configurationOSStatusArgument,
    "-e2e-stage-share-handoff",
    "-e2e-start-section",
    "-e2e-start-settings-route",
    // Retained for the checked-in multifile story's canonical launch contract.
    "-e2e-acquisition",
  ]

  private static let recognizedArguments = flagArguments.union(valueArguments)
}

private final class E2EFixtureResetLease: @unchecked Sendable {
  private let lock = NSLock()
  private var shouldReset: Bool

  init(shouldReset: Bool) {
    self.shouldReset = shouldReset
  }

  func consume() -> Bool {
    lock.withLock {
      defer { shouldReset = false }
      return shouldReset
    }
  }
}

#if E2E
  enum E2EPersistedIDSequence {
    private struct Envelope: Decodable {
      let schemaVersion: Int
      let library: LibrarySnapshot
    }

    static func nextSuffix(
      in libraryURL: URL,
      prefix: String,
      initialSuffix: Int,
      requiredCount: Int
    ) throws -> Int {
      guard initialSuffix > 0, requiredCount > 0,
        initialSuffix <= 999_999_999_999 - (requiredCount - 1),
        prefix.utf8.count == 8,
        prefix.utf8.allSatisfy({
          (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains($0)
        })
      else {
        throw PlayerCoreError.fileOperation("Invalid deterministic E2E ID sequence.")
      }
      guard FileManager.default.fileExists(atPath: libraryURL.path) else {
        return initialSuffix
      }

      let data = try Data(contentsOf: libraryURL)
      let envelope: Envelope
      do {
        envelope = try JSONDecoder.playerDecoder.decode(Envelope.self, from: data)
      } catch {
        throw PlayerCoreError.invalidStore
      }
      guard envelope.schemaVersion == CodableLibraryStore.currentSchemaVersion else {
        throw PlayerCoreError.invalidStore
      }
      _ = envelope.library

      guard let encoded = String(data: data, encoding: .utf8),
        let expression = try? NSRegularExpression(
          pattern: "\(prefix)-0000-0000-0000-([0-9]{12})",
          options: [.caseInsensitive]
        )
      else {
        throw PlayerCoreError.invalidStore
      }
      let range = NSRange(encoded.startIndex..<encoded.endIndex, in: encoded)
      let suffixes = expression.matches(in: encoded, range: range).compactMap { match -> Int? in
        guard let suffixRange = Range(match.range(at: 1), in: encoded) else { return nil }
        return Int(encoded[suffixRange])
      }
      let next = max(initialSuffix, (suffixes.max() ?? (initialSuffix - 1)) + 1)
      guard next <= 999_999_999_999 - (requiredCount - 1) else {
        throw PlayerCoreError.fileOperation("Deterministic E2E ID sequence is exhausted.")
      }
      return next
    }
  }

  func resetE2EFixtureRoot(_ root: URL) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: root.path) {
      try fileManager.removeItem(at: root)
    }
    guard !fileManager.fileExists(atPath: root.path) else {
      throw PlayerCoreError.fileOperation("Could not reset E2E fixture root: \(root.lastPathComponent)")
    }
  }

  enum E2EMetadataRichBookNamespace {
    static let argument = "-e2e-metadata-rich-namespace"

    static func parse(arguments: [String]) throws -> String {
      let markers = arguments.indices.filter { arguments[$0] == argument }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Metadata Rich Book E2E namespace.")
      }
      let marker = markers[0]
      guard arguments.indices.contains(marker + 1) else {
        throw PlayerCoreError.fileOperation("Missing Metadata Rich Book E2E namespace value.")
      }
      let namespace = arguments[marker + 1]
      let bytes = Array(namespace.utf8)
      let isLowercaseLetterOrDigit: (UInt8) -> Bool = {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
      }
      guard (1...64).contains(bytes.count),
        bytes.first.map(isLowercaseLetterOrDigit) == true,
        bytes.last.map(isLowercaseLetterOrDigit) == true,
        bytes.allSatisfy({ isLowercaseLetterOrDigit($0) || $0 == UInt8(ascii: "-") })
      else {
        throw PlayerCoreError.fileOperation("Invalid Metadata Rich Book E2E namespace.")
      }
      return namespace
    }

    static func root(in support: URL, namespace: String) -> URL {
      return support.appending(
        path: "PlayerE2EMetadataRichBook-\(namespace)",
        directoryHint: .isDirectory
      )
    }
  }

  enum E2ECommittedMetadataNamespace {
    static let argument = "-e2e-committed-metadata-namespace"

    static func parse(arguments: [String]) throws -> String {
      let markers = arguments.indices.filter { arguments[$0] == argument }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Committed Metadata E2E namespace.")
      }
      let marker = markers[0]
      guard arguments.indices.contains(marker + 1) else {
        throw PlayerCoreError.fileOperation("Missing Committed Metadata E2E namespace value.")
      }
      let namespace = arguments[marker + 1]
      let bytes = Array(namespace.utf8)
      let isLowercaseLetterOrDigit: (UInt8) -> Bool = {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0)
          || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
      }
      guard (1...64).contains(bytes.count),
        bytes.first.map(isLowercaseLetterOrDigit) == true,
        bytes.last.map(isLowercaseLetterOrDigit) == true,
        bytes.allSatisfy({ isLowercaseLetterOrDigit($0) || $0 == UInt8(ascii: "-") })
      else {
        throw PlayerCoreError.fileOperation("Invalid Committed Metadata E2E namespace.")
      }
      return namespace
    }

    static func root(in support: URL, namespace: String) -> URL {
      support.appending(
        path: "PlayerE2ECommittedMetadata-\(namespace)",
        directoryHint: .isDirectory
      )
    }
  }

  enum E2ESleepTimerNamespace: String, CaseIterable {
    static let argument = "-e2e-sleep-timer-namespace"

    case preset10 = "preset-10"
    case preset15 = "preset-15"
    case preset30 = "preset-30"
    case preset45 = "preset-45"
    case preset60 = "preset-60"
    case custom25 = "custom-25"
    case endChapter = "end-chapter"
    case endTrack = "end-track"
    case replaceCancel = "replace-cancel"
    case persistent

    static func parseRequired(arguments: [String]) throws -> E2ESleepTimerNamespace {
      let markers = arguments.indices.filter { arguments[$0] == argument }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Sleep Timer E2E namespace.")
      }
      let marker = markers[0]
      guard arguments.indices.contains(marker + 1) else {
        throw PlayerCoreError.fileOperation("Missing Sleep Timer E2E namespace value.")
      }
      let value = arguments[marker + 1]
      guard !value.isEmpty, !value.hasPrefix("-"), let namespace = Self(rawValue: value) else {
        throw PlayerCoreError.fileOperation("Invalid Sleep Timer E2E namespace: \(value)")
      }
      return namespace
    }
  }

  enum E2ESmartRewindScenario: String, CaseIterable {
    static let argument = "-e2e-smart-rewind-scenario"

    case belowThreshold = "below-threshold"
    case short
    case medium
    case long
    case maximum
    case disabled
    case chapterClamp = "chapter-clamp"

    static func parseRequired(arguments: [String]) throws -> E2ESmartRewindScenario {
      let markers = arguments.indices.filter { arguments[$0] == argument }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Smart Rewind E2E scenario.")
      }
      let marker = markers[0]
      guard arguments.indices.contains(marker + 1) else {
        throw PlayerCoreError.fileOperation("Missing Smart Rewind E2E scenario value.")
      }
      let value = arguments[marker + 1]
      guard !value.isEmpty, !value.hasPrefix("-"), let scenario = Self(rawValue: value) else {
        throw PlayerCoreError.fileOperation("Invalid Smart Rewind E2E scenario: \(value)")
      }
      return scenario
    }
  }

  enum E2EImportRecoveryScenario: String, CaseIterable {
    static let argument = "-e2e-recovery-scenario"

    case lowSpace = "low-space"
    case mixed
    case managedDuplicate = "managed-duplicate"
    case allCorrupt = "all-corrupt"

    static func parseRequired(arguments: [String]) throws -> E2EImportRecoveryScenario {
      let markers = arguments.indices.filter { arguments[$0] == argument }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Import Recovery E2E scenario.")
      }
      let marker = markers[0]
      guard arguments.indices.contains(marker + 1) else {
        throw PlayerCoreError.fileOperation("Missing Import Recovery E2E scenario value.")
      }
      let value = arguments[marker + 1]
      guard !value.isEmpty, !value.hasPrefix("-"), let scenario = Self(rawValue: value) else {
        throw PlayerCoreError.fileOperation("Invalid Import Recovery E2E scenario: \(value)")
      }
      return scenario
    }
  }

  enum E2EMetadataReplacementCoverPayload {
    static let environmentKey = "PLAYER_E2E_METADATA_REPLACEMENT_COVER_BASE64"
    static let maximumDecodedBytes = 20 * 1_024 * 1_024

    static func parse(
      environment: [String: String],
      maximumDecodedBytes: Int = maximumDecodedBytes
    ) throws -> Data {
      guard let encoded = environment[environmentKey] else {
        throw PlayerCoreError.fileOperation(
          "Missing synthetic metadata-repair replacement cover."
        )
      }
      guard maximumDecodedBytes > 0, !encoded.isEmpty else {
        throw PlayerCoreError.fileOperation(
          "Invalid synthetic metadata-repair replacement cover."
        )
      }
      let maximumEncodedBytes = ((maximumDecodedBytes + 2) / 3) * 4
      guard encoded.utf8.count <= maximumEncodedBytes,
        let data = Data(base64Encoded: encoded),
        !data.isEmpty,
        data.count <= maximumDecodedBytes,
        UIImage(data: data) != nil
      else {
        throw PlayerCoreError.fileOperation(
          "Invalid synthetic metadata-repair replacement cover."
        )
      }
      return data
    }
  }

  enum E2EZIPFixturePayload {
    static let environmentKey = "PLAYER_E2E_ZIP_FIXTURE_BASE64"
    static let maximumDecodedBytes = 32 * 1_024 * 1_024

    static func parse(
      environment: [String: String],
      maximumDecodedBytes: Int = maximumDecodedBytes
    ) throws -> Data {
      guard let encoded = environment[environmentKey] else {
        throw PlayerCoreError.fileOperation("Missing E2E ZIP fixture payload.")
      }
      let data = try decodeBoundedBase64(
        encoded,
        maximumDecodedBytes: maximumDecodedBytes,
        description: "E2E ZIP fixture payload"
      )
      guard isZIPArchive(data) else {
        throw PlayerCoreError.fileOperation("Invalid E2E ZIP fixture payload.")
      }
      return data
    }

    private static func isZIPArchive(_ data: Data) -> Bool {
      let header = Array(data.prefix(4))
      guard header == [0x50, 0x4B, 0x03, 0x04]
        || header == [0x50, 0x4B, 0x05, 0x06]
        || header == [0x50, 0x4B, 0x07, 0x08]
      else { return false }

      let endRecord = Data([0x50, 0x4B, 0x05, 0x06])
      let maximumEndRecordLength = Int(UInt16.max) + 22
      let searchStart = max(0, data.count - maximumEndRecordLength)
      return data.range(
        of: endRecord,
        options: .backwards,
        in: searchStart..<data.count
      ) != nil
    }
  }

  enum E2EMetadataRichCoverPayload {
    static let environmentKey = "PLAYER_E2E_METADATA_RICH_COVER_BASE64"
    static let maximumDecodedBytes = 20 * 1_024 * 1_024

    static func parseOverride(
      environment: [String: String],
      maximumDecodedBytes: Int = maximumDecodedBytes
    ) throws -> Data? {
      guard let encoded = environment[environmentKey] else { return nil }
      let data = try decodeBoundedBase64(
        encoded,
        maximumDecodedBytes: maximumDecodedBytes,
        description: "Metadata Rich Book E2E cover override"
      )
      let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
      guard data.starts(with: pngSignature), UIImage(data: data) != nil else {
        throw PlayerCoreError.fileOperation(
          "Invalid Metadata Rich Book E2E cover override."
        )
      }
      return data
    }
  }

  private func decodeBoundedBase64(
    _ encoded: String,
    maximumDecodedBytes: Int,
    description: String
  ) throws -> Data {
    guard maximumDecodedBytes > 0, !encoded.isEmpty else {
      throw PlayerCoreError.fileOperation("Invalid \(description).")
    }
    let maximumEncodedBytes = ((maximumDecodedBytes + 2) / 3) * 4
    guard encoded.utf8.count <= maximumEncodedBytes,
      let data = Data(base64Encoded: encoded),
      !data.isEmpty,
      data.count <= maximumDecodedBytes
    else {
      throw PlayerCoreError.fileOperation("Invalid \(description).")
    }
    return data
  }

  extension E2EPlaybackControlConfiguration {
    static let eventControlsArgument = "-e2e-event-controls"
    static let rewindExpiryControlArgument = "-e2e-rewind-expiry-control"

    static func parse(arguments: [String]) throws -> E2EPlaybackControlConfiguration {
      guard let launch = try E2ELaunchConfiguration.parse(arguments: arguments) else {
        return .disabled
      }

      for marker in [eventControlsArgument, rewindExpiryControlArgument] {
        guard arguments.filter({ $0 == marker }).count <= 1 else {
          throw PlayerCoreError.fileOperation("Duplicate E2E playback-control option: \(marker)")
        }
      }

      let eventControls = arguments.contains(eventControlsArgument)
      let rewindExpiryControl = arguments.contains(rewindExpiryControlArgument)
      let statusMarkers = arguments.indices.filter {
        arguments[$0] == configurationOSStatusArgument
      }
      guard statusMarkers.count <= 1 else {
        throw PlayerCoreError.fileOperation(
          "Duplicate E2E audio-session configuration status."
        )
      }
      let configurationOSStatus: Int?
      if let marker = statusMarkers.first {
        guard arguments.indices.contains(marker + 1),
          let parsed = Int(arguments[marker + 1])
        else {
          throw PlayerCoreError.fileOperation(
            "Invalid E2E audio-session configuration status."
          )
        }
        configurationOSStatus = parsed
      } else {
        configurationOSStatus = nil
      }
      let fixture = launch.fixture

      guard !eventControls || fixture == .committedCurrentBook else {
        throw PlayerCoreError.fileOperation(
          "E2E event controls require the committed-current-book fixture."
        )
      }
      if rewindExpiryControl {
        guard fixture == .smartRewind else {
          throw PlayerCoreError.fileOperation(
            "The E2E rewind-expiry control requires the smart-rewind fixture."
          )
        }
        let scenario = try E2ESmartRewindScenario.parseRequired(arguments: arguments)
        guard scenario.supportsRewindExpiryControl else {
          throw PlayerCoreError.fileOperation(
            "The E2E rewind-expiry control requires a scenario that applies a rewind."
          )
        }
      }
      guard configurationOSStatus == nil || fixture == .emptyLibrary else {
        throw PlayerCoreError.fileOperation(
          "An E2E audio-session configuration failure requires the empty-library fixture."
        )
      }

      return E2EPlaybackControlConfiguration(
        eventControls: eventControls,
        rewindExpiryControl: rewindExpiryControl,
        configurationOSStatus: configurationOSStatus
      )
    }
  }

  private extension E2ESmartRewindScenario {
    var supportsRewindExpiryControl: Bool {
      switch self {
      case .short, .medium, .long, .maximum, .chapterClamp: true
      case .belowThreshold, .disabled: false
      }
    }
  }

  struct E2ESafeZIPArguments: Equatable {
    enum ArchiveCase: String, CaseIterable {
      case valid
      case traversal
      case symlink
      case ratio
      case count
      case size
    }

    enum FailOnce: String {
      case inspection
    }

    struct Limits: Equatable {
      let maximumEntryCount: Int
      let maximumEntryBytes: UInt64
      let maximumEntryExpansionRatio: Double
    }

    static let caseArgument = "-e2e-zip-case"
    static let limitsArgument = "-e2e-zip-limits"
    static let failOnceArgument = "-e2e-zip-fail-once"

    let archiveCase: ArchiveCase
    let limits: Limits
    let failOnce: FailOnce?

    static func parse(arguments: [String]) throws -> E2ESafeZIPArguments {
      let caseValue = try requiredValue(after: caseArgument, in: arguments)
      guard let archiveCase = ArchiveCase(rawValue: caseValue) else {
        throw PlayerCoreError.fileOperation("Invalid Safe ZIP E2E case: \(caseValue)")
      }

      let limitsValue = try requiredValue(after: limitsArgument, in: arguments)
      let limits = try parseLimits(limitsValue)

      let failOnceValue = try optionalValue(after: failOnceArgument, in: arguments)
      let failOnce: FailOnce?
      if let failOnceValue {
        guard let parsed = FailOnce(rawValue: failOnceValue), archiveCase == .valid else {
          throw PlayerCoreError.fileOperation(
            "Invalid Safe ZIP E2E fail-once configuration: \(failOnceValue)"
          )
        }
        failOnce = parsed
      } else {
        failOnce = nil
      }

      return E2ESafeZIPArguments(
        archiveCase: archiveCase,
        limits: limits,
        failOnce: failOnce
      )
    }

    private static func requiredValue(after marker: String, in arguments: [String]) throws -> String {
      let markers = arguments.indices.filter { arguments[$0] == marker }
      guard markers.count == 1 else {
        let reason = markers.isEmpty ? "Missing" : "Duplicate"
        throw PlayerCoreError.fileOperation("\(reason) Safe ZIP E2E option: \(marker)")
      }
      return try value(after: marker, at: markers[0], in: arguments)
    }

    private static func optionalValue(after marker: String, in arguments: [String]) throws -> String? {
      let markers = arguments.indices.filter { arguments[$0] == marker }
      guard markers.count <= 1 else {
        throw PlayerCoreError.fileOperation("Duplicate Safe ZIP E2E option: \(marker)")
      }
      guard let index = markers.first else { return nil }
      return try value(after: marker, at: index, in: arguments)
    }

    private static func value(after marker: String, at index: Int, in arguments: [String]) throws -> String {
      guard arguments.indices.contains(index + 1) else {
        throw PlayerCoreError.fileOperation("Missing Safe ZIP E2E value for: \(marker)")
      }
      let value = arguments[index + 1]
      guard !value.isEmpty, !value.hasPrefix("-") else {
        throw PlayerCoreError.fileOperation("Invalid Safe ZIP E2E value for: \(marker)")
      }
      return value
    }

    private static func parseLimits(_ value: String) throws -> Limits {
      let components = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
      guard components.count == 3,
        let entryCount = positiveInt(components[0]),
        let entryBytes = positiveUInt64(components[1]),
        let expansionRatio = positiveDecimal(components[2])
      else {
        throw PlayerCoreError.fileOperation("Invalid Safe ZIP E2E limits: \(value)")
      }
      return Limits(
        maximumEntryCount: entryCount,
        maximumEntryBytes: entryBytes,
        maximumEntryExpansionRatio: expansionRatio
      )
    }

    private static func positiveInt(_ value: String) -> Int? {
      guard isASCIIInteger(value), let parsed = Int(value), parsed > 0 else { return nil }
      return parsed
    }

    private static func positiveUInt64(_ value: String) -> UInt64? {
      guard isASCIIInteger(value), let parsed = UInt64(value), parsed > 0 else { return nil }
      return parsed
    }

    private static func positiveDecimal(_ value: String) -> Double? {
      let components = value.split(separator: ".", omittingEmptySubsequences: false)
      guard (1...2).contains(components.count), components.allSatisfy({ isASCIIInteger(String($0)) }),
        let parsed = Double(value), parsed.isFinite, parsed > 0
      else { return nil }
      return parsed
    }

    private static func isASCIIInteger(_ value: String) -> Bool {
      !value.isEmpty && value.utf8.allSatisfy {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0)
      }
    }
  }

  @MainActor
  final class E2EConfigurableAudioSessionController: AudioSessionControlling {
    private let configurationOSStatus: Int?

    init(configurationOSStatus: Int?) {
      self.configurationOSStatus = configurationOSStatus
    }

    func configure() throws {
      if let configurationOSStatus {
        throw NSError(domain: NSOSStatusErrorDomain, code: configurationOSStatus)
      }
    }

    func activate() throws {}

    func installEventHandler(
      _ handler: @escaping @MainActor @Sendable (AudioSessionEvent) async -> Void
    ) {}
  }

  @MainActor
  @Observable
  final class E2EMonetizationStoreKitClient: StoreKitClient {
    enum Phase: String {
      case idle
      case awaitingProducts = "awaiting-products"
      case ready
      case awaitingPurchase = "awaiting-purchase"
      case awaitingRestore = "awaiting-restore"
      case awaitingOfferCompletion = "awaiting-offer-completion"
      case offline
    }

    static let shared = E2EMonetizationStoreKitClient()
    static let suiteName = "com.spnss.player.e2e.monetization-exhausted"

    private(set) var phase = Phase.idle
    private(set) var isConfigured = false
    private var defaults: UserDefaults?
    private var productsContinuation: CheckedContinuation<[StoreKitProduct], any Error>?
    private var purchaseContinuation: CheckedContinuation<StoreKitPurchaseResult, any Error>?
    private var restoreContinuation: CheckedContinuation<Void, any Error>?

    private init() {}

    func configure(defaults: UserDefaults, reset: Bool) {
      precondition(productsContinuation == nil && purchaseContinuation == nil && restoreContinuation == nil)
      self.defaults = defaults
      if reset {
        defaults.removePersistentDomain(forName: Self.suiteName)
        defaults.set(MonetizationSnapshot.includedPlaybackSeconds, forKey: "allowance-seconds")
      }
      isConfigured = true
      phase = defaults.bool(forKey: "offline") ? .offline : .idle
    }

    func products(for identifiers: [String]) async throws -> [StoreKitProduct] {
      guard phase != .offline else { throw E2EMonetizationStoreError.offline }
      guard identifiers == [StoreKitMonetizationManager.fullUnlockProductID] else {
        throw E2EMonetizationStoreError.invalidProductRequest
      }
      phase = .awaitingProducts
      return try await withCheckedThrowingContinuation { continuation in
        productsContinuation = continuation
      }
    }

    func purchase(productID: String) async throws -> StoreKitPurchaseResult {
      guard phase != .offline else { throw E2EMonetizationStoreError.offline }
      guard productID == StoreKitMonetizationManager.fullUnlockProductID else {
        throw E2EMonetizationStoreError.invalidProductRequest
      }
      phase = .awaitingPurchase
      return try await withCheckedThrowingContinuation { continuation in
        purchaseContinuation = continuation
      }
    }

    func sync() async throws {
      guard phase != .offline else { throw E2EMonetizationStoreError.offline }
      phase = .awaitingRestore
      try await withCheckedThrowingContinuation { continuation in
        restoreContinuation = continuation
      }
    }

    func entitlementStatus(productID: String) async throws -> StoreKitEntitlementStatus {
      guard productID == StoreKitMonetizationManager.fullUnlockProductID else {
        throw E2EMonetizationStoreError.invalidProductRequest
      }
      guard phase != .offline else { return .unavailable }
      return ownsUnlock ? .active(transaction) : .noEntitlement
    }

    func transactionUpdates() -> AsyncStream<StoreKitTransactionVerification> {
      AsyncStream { _ in }
    }

    func completeProductLoad() {
      guard let continuation = productsContinuation else { return }
      productsContinuation = nil
      phase = .ready
      continuation.resume(returning: [
        StoreKitProduct(
          id: StoreKitMonetizationManager.fullUnlockProductID,
          displayPrice: "$9.99",
          isFamilyShareable: true,
          type: .nonConsumable
        )
      ])
    }

    func completePurchase() {
      guard let continuation = purchaseContinuation else { return }
      purchaseContinuation = nil
      ownsUnlock = true
      phase = .ready
      continuation.resume(returning: .success(.verified(transaction)))
    }

    func completeRestoreWithoutEntitlement() {
      guard let continuation = restoreContinuation else { return }
      restoreContinuation = nil
      ownsUnlock = false
      phase = .ready
      continuation.resume()
    }

    func beginOfferCodeCompletion() {
      guard phase == .ready else { return }
      phase = .awaitingOfferCompletion
    }

    func completeOfferCodeWithoutSheet() {
      guard phase == .awaitingOfferCompletion else { return }
      phase = .ready
    }

    func prepareOfflineRelaunch() {
      defaults?.set(true, forKey: "offline")
      phase = .offline
    }

    var probeValue: String {
      "scripted-storekit|schema=1|phase=\(phase.rawValue)|owned=\(ownsUnlock)"
    }

    private var ownsUnlock: Bool {
      get { defaults?.bool(forKey: "store-owns-unlock") == true }
      set { defaults?.set(newValue, forKey: "store-owns-unlock") }
    }

    private var transaction: StoreKitTransaction {
      StoreKitTransaction(
        id: 12,
        productID: StoreKitMonetizationManager.fullUnlockProductID,
        environment: .sandbox,
        isRevoked: false
      )
    }
  }

  private enum E2EMonetizationStoreError: Error {
    case invalidProductRequest
    case offline
  }

  @MainActor
  private final class E2EMonetizationPlaybackKeychain: PlaybackAllowanceKeychain {
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
      self.defaults = defaults
    }

    func loadSeconds(service: String, account: String) -> TimeInterval? {
      defaults.object(forKey: "allowance-seconds") as? TimeInterval
    }

    func saveSeconds(_ seconds: TimeInterval, service: String, account: String) -> OSStatus {
      defaults.set(seconds, forKey: "allowance-seconds")
      return errSecSuccess
    }
  }
#endif

@MainActor
extension PlayerEnvironment {
  static func launchEnvironment(
    e2eLaunchConfiguration: E2ELaunchConfiguration?,
    playbackControls: E2EPlaybackControlConfiguration = .disabled
  ) throws -> PlayerEnvironment {
    #if E2E
      let arguments = ProcessInfo.processInfo.arguments
      if let launch = e2eLaunchConfiguration {
        let fixture = launch.fixture
        let reset = launch.consumeReset()
        switch fixture {
        case .emptyLibrary:
          return try emptyLibraryEnvironment(reset: reset, playbackControls: playbackControls)
        case .singleAudiobookReady:
          return try singleAudiobookReadyEnvironment(reset: reset)
        case .receiverCompletionBaseline:
          return try receiverCompletionBaselineEnvironment(reset: reset)
        case .committedCurrentBook:
          return try committedCurrentBookEnvironment(
            reset: reset,
            playbackControls: playbackControls
          )
        case .monetizationExhausted:
          return try monetizationExhaustedEnvironment(reset: reset)
        case .zeroDurationCurrentBook:
          return try zeroDurationCurrentBookEnvironment(reset: reset)
        case .metadataRichBook:
          return try metadataRichBookEnvironment(
            reset: reset,
            namespace: E2EMetadataRichBookNamespace.parse(arguments: arguments)
          )
        case .messyMultifileUnicode:
          return try messyMultifileEnvironment(reset: reset)
        case .safeZipImport:
          return try safeZipEnvironment(reset: reset)
        case .importRecoveryStorage:
          return try E2EImportRecoveryEnvironment.make(
            reset: reset,
            scenario: E2EImportRecoveryScenario.parseRequired(arguments: arguments).rawValue
          )
        case .syntheticImportChannels:
          return try importIngressEnvironment(reset: reset)
        case .syntheticMetadataRepair:
          return try metadataRepairEnvironment(reset: reset)
        case .syntheticCommittedMetadata:
          return try committedMetadataEnvironment(
            reset: reset,
            namespace: E2ECommittedMetadataNamespace.parse(arguments: arguments)
          )
        case .syntheticPopulatedLibrary:
          return try populatedLibraryEnvironment(reset: reset)
        case .syntheticPermanentTrash:
          return try permanentTrashEnvironment(reset: reset)
        case .smartRewind:
          return try smartRewindEnvironment(
            reset: reset,
            scenario: E2ESmartRewindScenario.parseRequired(arguments: arguments).rawValue
          )
        case .sleepTimer:
          return try sleepTimerEnvironment(
            reset: reset,
            namespace: E2ESleepTimerNamespace.parseRequired(arguments: arguments).rawValue
          )
        case .bookmarks:
          return try bookmarksEnvironment(reset: reset)
        case .portableBackup:
          return try portableBackupEnvironment(reset: reset)
        case .offlineRecovery:
          return try offlineRecoveryEnvironment(reset: reset)
        }
      }
    #endif
    return try production()
  }

  #if E2E
    private static func emptyLibraryEnvironment(
      reset: Bool,
      playbackControls: E2EPlaybackControlConfiguration
    ) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EEmptyLibrary",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(snapshot: .empty),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        audioSession: E2EConfigurableAudioSessionController(
          configurationOSStatus: playbackControls.configurationOSStatus
        ),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(
          values: (1...32).map {
            UUID(uuidString: String(format: "01000000-0000-0000-0000-%012d", $0))!
          }
        )
      )
    }

    private static func singleAudiobookReadyEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2ESingleAudiobook",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }

      let jobID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
      let proposalID = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
      let bookID = UUID(uuidString: "10000000-0000-0000-0000-000000000004")!
      let stagedRelativePath = "Staging/\(jobID.uuidString.lowercased())/source.m4a"
      let stagedURL = root.appending(path: stagedRelativePath)
      try FileManager.default.createDirectory(
        at: stagedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("player deterministic e2e media".utf8).write(to: stagedURL)

      let asset = AudioAsset(
        id: assetID,
        originalFilename: "lighthouse-signal.m4a",
        managedRelativePath: "",
        checksumSHA256: "6d7366e728dc036ebd67c6464449885939f5eb06f13a361caf3b08a2dc49fc4d",
        byteCount: 30,
        durationSeconds: 1_113,
        container: "M4A"
      )
      let proposal = BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: "The Lighthouse Signal",
        authors: ["Mara Vale"],
        durationSeconds: 1_113,
        artworkData: nil,
        asset: asset,
        warnings: []
      )
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let job = ImportJob(
        id: jobID,
        sourceFilename: asset.originalFilename,
        phase: .ready,
        progress: ImportProgress(completed: 30, total: 30),
        stagedRelativePath: stagedRelativePath,
        proposal: proposal,
        committedBookID: nil,
        failure: nil,
        createdAt: date,
        updatedAt: date
      )
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [], importJobs: [job], currentBookID: nil)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(
          result: .success(
            InspectedAudio(
              title: proposal.title,
              authors: proposal.authors,
              durationSeconds: proposal.durationSeconds,
              artworkData: nil,
              container: "M4A"
            )
          )
        ),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(
          values: (1...4).map {
            UUID(uuidString: String(format: "11000000-0000-0000-0000-%012d", $0))!
          }
        )
      )
    }

    private static func receiverCompletionBaselineEnvironment(reset: Bool) throws
      -> PlayerEnvironment
    {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EReceiverCompletionBaseline",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }

      let bookID = UUID(uuidString: "12000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "12000000-0000-0000-0000-000000000002")!
      let proposalID = UUID(uuidString: "12000000-0000-0000-0000-000000000003")!
      let jobID = UUID(uuidString: "12000000-0000-0000-0000-000000000004")!
      let managedRelativePath = "Media/baseline/lighthouse-signal.m4a"
      let managedURL = root.appending(path: managedRelativePath)
      try FileManager.default.createDirectory(
        at: managedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("receiver baseline media".utf8).write(to: managedURL, options: .atomic)

      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "lighthouse-signal.m4a",
        managedRelativePath: managedRelativePath,
        checksumSHA256: "e2e-receiver-completion-baseline",
        byteCount: 23,
        durationSeconds: 1_113,
        container: "M4A"
      )
      let proposal = BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: "The Lighthouse Signal",
        authors: ["Mara Vale"],
        durationSeconds: 1_113,
        artworkData: nil,
        asset: asset,
        warnings: []
      )
      let book = Book(
        id: bookID,
        title: proposal.title,
        authors: proposal.authors,
        durationSeconds: proposal.durationSeconds,
        artworkData: nil,
        assets: [asset],
        dateAdded: date
      )
      let job = ImportJob(
        id: jobID,
        sourceFilename: asset.originalFilename,
        phase: .committed,
        progress: ImportProgress(completed: asset.byteCount, total: asset.byteCount),
        stagedRelativePath: nil,
        proposal: proposal,
        committedBookID: bookID,
        failure: nil,
        createdAt: date,
        updatedAt: date
      )
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [book], importJobs: [job], currentBookID: nil)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .success(InspectedAudio(
          title: "Project Hail Mary",
          authors: ["Andy Weir"],
          durationSeconds: 32,
          artworkData: nil,
          container: "M4A"
        ))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(
          values: (1...32).map {
            UUID(uuidString: String(format: "13000000-0000-0000-0000-%012d", $0))!
          }
        )
      )
    }

    static func committedCurrentBookEnvironment(
      reset: Bool,
      playbackControls: E2EPlaybackControlConfiguration,
      monetization: (any MonetizationManaging)? = nil,
      root overrideRoot: URL? = nil
    ) throws -> PlayerEnvironment {
      let root: URL
      if let overrideRoot {
        root = overrideRoot
      } else {
        let support = try FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
        root = support.appending(
          path: "PlayerE2EPositionRestore",
          directoryHint: .isDirectory
        )
      }
      if reset { try resetE2EFixtureRoot(root) }
      let libraryURL = root.appending(path: "Library.json")
      let firstAvailableSuffix = try E2EPersistedIDSequence.nextSuffix(
        in: libraryURL,
        prefix: "21000000",
        initialSuffix: 1,
        requiredCount: 12
      )

      let bookID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
      let seedEventID = UUID(uuidString: "20000000-0000-0000-0000-000000000003")!
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4a"
      let managedURL = root.appending(path: managedPath)
      if !FileManager.default.fileExists(atPath: managedURL.path) {
        try FileManager.default.createDirectory(
          at: managedURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data("player deterministic position fixture".utf8).write(to: managedURL)
      }

      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "midnight-current.m4a",
        managedRelativePath: managedPath,
        checksumSHA256: "e2e-position-fixture",
        byteCount: 37,
        durationSeconds: 120,
        container: "M4A"
      )
      let book = Book(
        id: bookID,
        title: "The Midnight Current",
        authors: ["Mara Vale"],
        durationSeconds: 120,
        artworkData: nil,
        assets: [asset],
        dateAdded: date
      )
      let seedEvent = PositionEvent.acknowledged(
        id: seedEventID,
        bookID: bookID,
        positionMilliseconds: 12_000,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: date,
        previousEventID: nil
      )
      let seed = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: seedEvent.positionMilliseconds,
          sequence: seedEvent.sequence,
          sourceEventID: seedEvent.id,
          updatedAt: date
        ),
        positionJournal: [seedEvent]
      )
      let persisted = CodableLibraryStore(fileURL: libraryURL)
      let ids = (firstAvailableSuffix...(firstAvailableSuffix + 11)).map {
        UUID(uuidString: String(format: "21000000-0000-0000-0000-%012d", $0))!
      }
      let playbackEventBridge = E2EPlaybackEventBridge.shared
      if playbackControls.eventControls { playbackEventBridge.reset() }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(base: persisted, seed: seed),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        audioSession: playbackControls.eventControls
          ? AVAudioSessionController(
            platform: playbackEventBridge,
            notificationSource: playbackEventBridge
          )
          : DisabledAudioSessionController(),
        remoteCommands: playbackControls.eventControls
          ? MPRemoteCommandController(source: playbackEventBridge)
          : DisabledRemoteCommandController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(values: ids),
        monetization: monetization ?? DisabledMonetizationManager()
      )
    }

    private static func monetizationExhaustedEnvironment(reset: Bool) throws -> PlayerEnvironment {
      guard let defaults = UserDefaults(suiteName: E2EMonetizationStoreKitClient.suiteName) else {
        throw PlayerCoreError.fileOperation("Could not create the isolated E2E monetization sandbox.")
      }
      let storeKit = E2EMonetizationStoreKitClient.shared
      storeKit.configure(defaults: defaults, reset: reset)
      let persistence = PlaybackAllowancePersistence(
        storeEnvironment: .sandbox,
        userDefaults: defaults,
        keychainService: E2EMonetizationStoreKitClient.suiteName,
        keychain: E2EMonetizationPlaybackKeychain(defaults: defaults)
      )
      if reset {
        _ = persistence.saveConsumedPlaybackSeconds(MonetizationSnapshot.includedPlaybackSeconds)
        persistence.saveCachedUnlock(false)
      }
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      return try committedCurrentBookEnvironment(
        reset: reset,
        playbackControls: .disabled,
        monetization: StoreKitMonetizationManager(
          persistence: persistence,
          storeEnvironment: .sandbox,
          userDefaults: defaults,
          storeKit: storeKit
        ),
        root: support.appending(
          path: "PlayerE2EMonetizationExhausted",
          directoryHint: .isDirectory
        )
      )
    }

    private static func zeroDurationCurrentBookEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EZeroDuration",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let bookID = UUID(uuidString: "22000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "22000000-0000-0000-0000-000000000002")!
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "atmosphere.m4b",
        managedRelativePath: "Media/atmosphere.m4b",
        checksumSHA256: "e2e-zero-duration-fixture",
        byteCount: 1,
        durationSeconds: 0,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: "Atmosphere",
        authors: ["Taylor Jenkins Reid"],
        durationSeconds: 0,
        artworkData: nil,
        assets: [asset],
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000)
      )
      let managedURL = root.appending(path: asset.managedRelativePath)
      try FileManager.default.createDirectory(
        at: managedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data([0]).write(to: managedURL)
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(
          snapshot: LibrarySnapshot(books: [book], importJobs: [], currentBookID: bookID)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: [])
      )
    }

    private static func sleepTimerEnvironment(
      reset: Bool,
      namespace: String
    ) throws -> PlayerEnvironment {
      guard namespace.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
        throw PlayerCoreError.fileOperation("Invalid Sleep Timer E2E namespace.")
      }
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2ESleepTimer-\(namespace)",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let libraryURL = root.appending(path: "Library.json")
      let persistedLibrary = try E2EPersistedLibrary.load(from: libraryURL)

      let bookID = UUID(uuidString: "52000000-0000-0000-0000-000000000001")!
      let firstAssetID = UUID(uuidString: "52000000-0000-0000-0000-000000000002")!
      let secondAssetID = UUID(uuidString: "52000000-0000-0000-0000-000000000003")!
      let pauseEventID = UUID(uuidString: "52000000-0000-0000-0000-000000000004")!
      let managedAssets = [
        (
          firstAssetID,
          "quiet-hours-part-01.m4b",
          "Media/\(bookID.uuidString.lowercased())/\(firstAssetID.uuidString.lowercased()).m4b",
          0.0
        ),
        (
          secondAssetID,
          "quiet-hours-part-02.m4b",
          "Media/\(bookID.uuidString.lowercased())/\(secondAssetID.uuidString.lowercased()).m4b",
          90.0
        ),
      ]
      for (_, filename, path, _) in managedAssets {
        let url = root.appending(path: path)
        if !FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try Data("player deterministic sleep timer fixture \(filename)".utf8)
            .write(to: url)
        }
      }

      let date = Date(timeIntervalSince1970: 1_700_020_000)
      let assets = managedAssets.enumerated().map { index, item in
        AudioAsset(
          id: item.0,
          originalFilename: item.1,
          managedRelativePath: item.2,
          checksumSHA256: "e2e-sleep-timer-part-\(index + 1)",
          byteCount: 50,
          durationSeconds: 90,
          container: "M4B",
          timelineStartSeconds: item.3,
          discNumber: 1,
          trackNumber: index + 1,
          importOrder: index
        )
      }
      let book = Book(
        id: bookID,
        title: "The Quiet Hours",
        authors: ["Mara Vale"],
        durationSeconds: 180,
        artworkData: nil,
        assets: assets,
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        chapters: [
          Chapter(
            id: "sleep-1", title: "Settling In", startSeconds: 0,
            durationSeconds: 60, source: .embedded, assetID: firstAssetID
          ),
          Chapter(
            id: "sleep-2", title: "Drifting", startSeconds: 60,
            durationSeconds: 60, source: .embedded, assetID: firstAssetID
          ),
          Chapter(
            id: "sleep-3", title: "Morning Light", startSeconds: 120,
            durationSeconds: 60, source: .embedded, assetID: secondAssetID
          ),
        ]
      )
      let pause = PositionEvent.acknowledged(
        id: pauseEventID,
        bookID: bookID,
        positionMilliseconds: 70_000,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: date,
        previousEventID: nil
      )
      let seed = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: 70_000,
          sequence: 1,
          sourceEventID: pause.id,
          updatedAt: date
        ),
        positionJournal: [pause]
      )
      let firstAvailableSuffix = nextSleepTimerIDSuffix(in: persistedLibrary?.encoded)
      let ids = (firstAvailableSuffix...(firstAvailableSuffix + 79)).map {
        UUID(uuidString: String(format: "52000000-0000-0000-0000-%012d", $0))!
      }
      let clock = E2EMutablePlayerClock(value: date)
      E2ESleepTimerBridge.shared.configure(clock: clock)
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: clock,
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func nextSleepTimerIDSuffix(in encoded: String?) -> Int {
      guard
        let encoded,
        let expression = try? NSRegularExpression(
          pattern: "52000000-0000-0000-0000-([0-9]{12})",
          options: [.caseInsensitive]
        )
      else { return 101 }
      let range = NSRange(encoded.startIndex..<encoded.endIndex, in: encoded)
      let suffixes = expression.matches(in: encoded, range: range).compactMap { match -> Int? in
        guard let suffixRange = Range(match.range(at: 1), in: encoded) else { return nil }
        return Int(encoded[suffixRange])
      }
      return max(101, (suffixes.max() ?? 100) + 1)
    }

    private static func bookmarksEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2EBookmarks",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let libraryURL = root.appending(path: "Library.json")
      let persistedLibrary = try E2EPersistedLibrary.load(from: libraryURL)

      let bookID = UUID(uuidString: "53000000-0000-0000-0000-000000000001")!
      let firstAssetID = UUID(uuidString: "53000000-0000-0000-0000-000000000002")!
      let secondAssetID = UUID(uuidString: "53000000-0000-0000-0000-000000000003")!
      let pauseEventID = UUID(uuidString: "53000000-0000-0000-0000-000000000004")!
      let assetDetails = [
        (
          firstAssetID,
          "mapped-signals-part-01.m4b",
          "Media/\(bookID.uuidString.lowercased())/\(firstAssetID.uuidString.lowercased()).m4b",
          0.0
        ),
        (
          secondAssetID,
          "mapped-signals-part-02.m4b",
          "Media/\(bookID.uuidString.lowercased())/\(secondAssetID.uuidString.lowercased()).m4b",
          60.0
        ),
      ]
      for (_, filename, relativePath, _) in assetDetails {
        let url = root.appending(path: relativePath)
        if !FileManager.default.fileExists(atPath: url.path) {
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try Data("player deterministic bookmark fixture \(filename)".utf8).write(to: url)
        }
      }

      let date = Date(timeIntervalSince1970: 1_700_030_000)
      let assets = assetDetails.enumerated().map { index, details in
        AudioAsset(
          id: details.0,
          originalFilename: details.1,
          managedRelativePath: details.2,
          checksumSHA256: "e2e-bookmark-part-\(index + 1)",
          byteCount: 48,
          durationSeconds: 60,
          container: "M4B",
          timelineStartSeconds: details.3,
          discNumber: 1,
          trackNumber: index + 1,
          importOrder: index
        )
      }
      let book = Book(
        id: bookID,
        title: "Mapped Signals",
        authors: ["Mara Vale"],
        durationSeconds: 120,
        artworkData: nil,
        assets: assets,
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        chapters: [
          Chapter(
            id: "opening", title: "Opening Signal", startSeconds: 0,
            durationSeconds: 60, source: .embedded, assetID: firstAssetID
          ),
          Chapter(
            id: "crossing", title: "The Crossing", startSeconds: 60,
            durationSeconds: 60, source: .embedded, assetID: secondAssetID
          ),
        ]
      )
      let pause = PositionEvent.acknowledged(
        id: pauseEventID,
        bookID: bookID,
        positionMilliseconds: 60_000,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: date,
        previousEventID: nil
      )
      let seed = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: 60_000,
          sequence: 1,
          sourceEventID: pause.id,
          updatedAt: date
        ),
        positionJournal: [pause]
      )
      let firstAvailableSuffix = nextBookmarkIDSuffix(in: persistedLibrary?.encoded)
      let ids = (firstAvailableSuffix...(firstAvailableSuffix + 39)).map {
        UUID(uuidString: String(format: "53000000-0000-0000-0000-%012d", $0))!
      }
      let clock = try E2EBookmarkClock(
        value: date,
        stateURL: root.appending(path: "BookmarkClock.json")
      )
      E2EBookmarkBridge.shared.configure(clock: clock)
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: clock,
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func nextBookmarkIDSuffix(in encoded: String?) -> Int {
      guard
        let encoded,
        let expression = try? NSRegularExpression(
          pattern: "53000000-0000-0000-0000-([0-9]{12})",
          options: [.caseInsensitive]
        )
      else { return 101 }
      let range = NSRange(encoded.startIndex..<encoded.endIndex, in: encoded)
      let suffixes = expression.matches(in: encoded, range: range).compactMap { match -> Int? in
        guard let suffixRange = Range(match.range(at: 1), in: encoded) else { return nil }
        return Int(encoded[suffixRange])
      }
      return max(101, (suffixes.max() ?? 100) + 1)
    }

    private static func smartRewindEnvironment(
      reset: Bool,
      scenario: String
    ) throws -> PlayerEnvironment {
      struct Scenario {
        var secondsAway: TimeInterval
        var positionMilliseconds: Int64
        var preferences: SmartRewindPreferences
      }

      var preferences = SmartRewindPreferences.default
      let configuration: Scenario
      switch scenario {
      case "below-threshold":
        configuration = Scenario(
          secondsAway: 29,
          positionMilliseconds: 120_000,
          preferences: preferences
        )
      case "short":
        configuration = Scenario(
          secondsAway: 30,
          positionMilliseconds: 120_000,
          preferences: preferences
        )
      case "medium":
        configuration = Scenario(
          secondsAway: 600,
          positionMilliseconds: 120_000,
          preferences: preferences
        )
      case "long":
        configuration = Scenario(
          secondsAway: 3_601,
          positionMilliseconds: 170_000,
          preferences: preferences
        )
      case "maximum":
        configuration = Scenario(
          secondsAway: 3_601,
          positionMilliseconds: 170_000,
          preferences: preferences
        )
      case "disabled":
        preferences.isEnabled = false
        configuration = Scenario(
          secondsAway: 3_601,
          positionMilliseconds: 120_000,
          preferences: preferences
        )
      case "chapter-clamp":
        configuration = Scenario(
          secondsAway: 600,
          positionMilliseconds: 110_000,
          preferences: preferences
        )
      default:
        throw PlayerCoreError.fileOperation("Unknown Smart Rewind E2E scenario: \(scenario)")
      }

      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2ESmartRewind-\(scenario)",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let libraryURL = root.appending(path: "Library.json")
      let persistedLibrary = try E2EPersistedLibrary.load(from: libraryURL)?.snapshot

      let bookID = UUID(uuidString: "51000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "51000000-0000-0000-0000-000000000002")!
      let pauseEventID = UUID(uuidString: "51000000-0000-0000-0000-000000000003")!
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let managedURL = root.appending(path: managedPath)
      if !FileManager.default.fileExists(atPath: managedURL.path) {
        try FileManager.default.createDirectory(
          at: managedURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data("player deterministic smart rewind fixture".utf8).write(to: managedURL)
      }

      let resumedAt = Date(timeIntervalSince1970: 1_700_010_000)
      let pausedAt = resumedAt.addingTimeInterval(-configuration.secondsAway)
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "intervals-of-quiet.m4b",
        managedRelativePath: managedPath,
        checksumSHA256: "e2e-smart-rewind-fixture",
        byteCount: 41,
        durationSeconds: 180,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: "Intervals of Quiet",
        authors: ["Mara Vale"],
        durationSeconds: 180,
        artworkData: nil,
        assets: [asset],
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        chapters: [
          Chapter(
            id: "smart-rewind-1",
            title: "Before the Pause",
            startSeconds: 0,
            durationSeconds: 60,
            source: .embedded,
            assetID: assetID
          ),
          Chapter(
            id: "smart-rewind-2",
            title: "A Familiar Thread",
            startSeconds: 60,
            durationSeconds: 40,
            source: .embedded,
            assetID: assetID
          ),
          Chapter(
            id: "smart-rewind-3",
            title: "Finding the Thread",
            startSeconds: 100,
            durationSeconds: 40,
            source: .embedded,
            assetID: assetID
          ),
          Chapter(
            id: "smart-rewind-4",
            title: "Moving Forward",
            startSeconds: 140,
            durationSeconds: 40,
            source: .embedded,
            assetID: assetID
          ),
        ]
      )
      let pauseEvent = PositionEvent.acknowledged(
        id: pauseEventID,
        bookID: bookID,
        positionMilliseconds: configuration.positionMilliseconds,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: pausedAt,
        previousEventID: nil
      )
      let seed = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: configuration.positionMilliseconds,
          sequence: 1,
          sourceEventID: pauseEvent.id,
          updatedAt: pausedAt
        ),
        positionJournal: [pauseEvent],
        smartRewindPreferences: configuration.preferences
      )
      let journalIDs = persistedLibrary?.positionJournal.map(\.id) ?? []
      let transactionIDs = persistedLibrary?.resumeRewindTransactions.flatMap {
          [$0.id, $0.preRewindEventID, $0.rewindEventID]
            + [$0.undoEventID].compactMap { $0 }
        } ?? []
      let persistedIDs = journalIDs + transactionIDs
      let largestPersistedSuffix = persistedIDs.compactMap { id in
        Int(id.uuidString.split(separator: "-").last ?? "")
      }.max() ?? 100
      let firstAvailableSuffix = max(101, largestPersistedSuffix + 1)
      let ids = (firstAvailableSuffix...(firstAvailableSuffix + 39)).map {
        UUID(uuidString: String(format: "51000000-0000-0000-0000-%012d", $0))!
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: resumedAt),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    static func metadataRichBookEnvironment(
      reset: Bool,
      namespace: String,
      root overrideRoot: URL? = nil
    ) throws -> PlayerEnvironment {
      let artworkOverride = try E2EMetadataRichCoverPayload.parseOverride(
        environment: ProcessInfo.processInfo.environment
      )
      let root: URL
      if let overrideRoot {
        root = overrideRoot
      } else {
        let support = try FileManager.default.url(
          for: .applicationSupportDirectory,
          in: .userDomainMask,
          appropriateFor: nil,
          create: true
        )
        root = E2EMetadataRichBookNamespace.root(in: support, namespace: namespace)
      }
      if reset { try resetE2EFixtureRoot(root) }
      let libraryURL = root.appending(path: "Library.json")
      let firstAvailableSuffix = try E2EPersistedIDSequence.nextSuffix(
        in: libraryURL,
        prefix: "31000000",
        initialSuffix: 1,
        requiredCount: 40
      )

      let bookID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let managedURL = root.appending(path: managedPath)
      if !FileManager.default.fileExists(atPath: managedURL.path) {
        try FileManager.default.createDirectory(
          at: managedURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data("player deterministic metadata fixture".utf8).write(to: managedURL)
      }

      let chapters = [
        Chapter(
          id: "embedded-1",
          title: "First Light",
          startSeconds: 0,
          durationSeconds: 30,
          source: .embedded,
          assetID: assetID
        ),
        Chapter(
          id: "embedded-2",
          title: "Crossing the Bar",
          startSeconds: 30,
          durationSeconds: 45,
          source: .embedded,
          assetID: assetID
        ),
        Chapter(
          id: "embedded-3",
          title: "Safe Harbor",
          startSeconds: 75,
          durationSeconds: 45,
          source: .embedded,
          assetID: assetID
        ),
      ]
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "harbor-at-dawn.m4b",
        managedRelativePath: managedPath,
        checksumSHA256: "e2e-metadata-fixture",
        byteCount: 37,
        durationSeconds: 120,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: "Harbor at Dawn",
        authors: ["Mara Vale"],
        durationSeconds: 120,
        artworkData: metadataRichArtwork(override: artworkOverride),
        assets: [asset],
        dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
        narrators: ["Imani Chen"],
        seriesName: "Harbor Signals",
        seriesPosition: "2",
        artworkMediaType: "image/png",
        chapters: chapters
      )
      let ids = (firstAvailableSuffix...(firstAvailableSuffix + 39)).map {
        UUID(uuidString: String(format: "31000000-0000-0000-0000-%012d", $0))!
      }
      let seed = LibrarySnapshot(books: [book], importJobs: [], currentBookID: nil)
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func committedMetadataEnvironment(
      reset: Bool,
      namespace: String
    ) throws -> PlayerEnvironment {
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = E2ECommittedMetadataNamespace.root(in: support, namespace: namespace)
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

      let libraryURL = root.appending(path: "Library.json")
      let targetBookID = UUID(uuidString: "a7000000-0000-0000-0000-000000000001")!
      let atlasBookID = UUID(uuidString: "a7000000-0000-0000-0000-000000000002")!
      let cedarBookID = UUID(uuidString: "a7000000-0000-0000-0000-000000000003")!
      let targetAssetID = UUID(uuidString: "a7000000-0000-0000-0000-000000000101")!
      let atlasAssetID = UUID(uuidString: "a7000000-0000-0000-0000-000000000102")!
      let cedarAssetID = UUID(uuidString: "a7000000-0000-0000-0000-000000000103")!
      let transactionID = UUID(uuidString: "a7100000-0000-0000-0000-000000000001")!
      let date = Date(timeIntervalSince1970: 1_730_000_000)
      let cover = metadataRichArtwork(override: nil)

      let targetBytes = Data([
        0x00, 0x00, 0x00, 0x18, 0x66, 0x74, 0x79, 0x70,
        0x4d, 0x34, 0x42, 0x20, 0x00, 0x00, 0x00, 0x00,
        0x4d, 0x34, 0x42, 0x20, 0x69, 0x73, 0x6f, 0x6d,
        0x63, 0x6f, 0x6d, 0x6d, 0x69, 0x74, 0x74, 0x65,
        0x64, 0x2d, 0x6d, 0x65, 0x74, 0x61, 0x64, 0x61,
      ])
      var atlasBytes = targetBytes
      atlasBytes[atlasBytes.index(before: atlasBytes.endIndex)] = 0x73
      var cedarBytes = targetBytes
      cedarBytes[cedarBytes.index(before: cedarBytes.endIndex)] = 0x72

      let sourceURL = root.appending(path: "Input/zulu-harbor-source.m4b")
      let targetPath = "Media/\(targetBookID.uuidString.lowercased())/\(targetAssetID.uuidString.lowercased()).m4b"
      let atlasPath = "Media/\(atlasBookID.uuidString.lowercased())/\(atlasAssetID.uuidString.lowercased()).m4b"
      let cedarPath = "Media/\(cedarBookID.uuidString.lowercased())/\(cedarAssetID.uuidString.lowercased()).m4b"
      let artifacts: [(URL, Data)] = [
        (sourceURL, targetBytes),
        (root.appending(path: targetPath), targetBytes),
        (root.appending(path: atlasPath), atlasBytes),
        (root.appending(path: cedarPath), cedarBytes),
      ]
      if FileManager.default.fileExists(atPath: libraryURL.path) {
        guard artifacts.allSatisfy({ (try? Data(contentsOf: $0.0)) == $0.1 }) else {
          throw PlayerCoreError.fileOperation(
            "The committed metadata E2E audio fixture does not match its persisted library."
          )
        }
      } else {
        for (url, data) in artifacts {
          try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try data.write(to: url, options: .atomic)
        }
      }

      let importedState = MetadataFieldState.imported(
        provenance: .embeddedTag,
        confidence: .high
      )
      let targetMetadata = AudiobookMetadata(
        title: "Zulu Harbor",
        sortTitle: "Zulu Harbor",
        subtitle: "A Quiet Beginning",
        authors: [Contributor(displayName: "Ari North")],
        narrators: [Contributor(displayName: "Milo Grey")],
        seriesMemberships: [],
        description: "An original harbor journal.",
        genres: ["Memoir"],
        tags: ["calm"],
        language: "en",
        publicationYear: 2012,
        publisher: "Old Quay Press",
        edition: "First edition",
        abridgement: .unknown,
        cover: CoverArtwork(originalData: cover, mediaType: "image/png", source: .embedded),
        fieldStates: Dictionary(
          uniqueKeysWithValues: MetadataField.allCases.map { ($0, importedState) }
        )
      )
      let targetAsset = AudioAsset(
        id: targetAssetID,
        originalFilename: "zulu-harbor.m4b",
        managedRelativePath: targetPath,
        checksumSHA256: committedMetadataChecksum(targetBytes),
        byteCount: Int64(targetBytes.count),
        durationSeconds: 120,
        container: "M4B"
      )
      let targetBook = Book(
        id: targetBookID,
        title: targetMetadata.title,
        authors: targetMetadata.authors.map(\.displayName),
        durationSeconds: targetAsset.durationSeconds,
        artworkData: cover,
        assets: [targetAsset],
        dateAdded: date.addingTimeInterval(2),
        narrators: targetMetadata.narrators.map(\.displayName),
        artworkMediaType: "image/png",
        metadata: targetMetadata
      )
      let atlasBook = committedMetadataCompanionBook(
        id: atlasBookID,
        assetID: atlasAssetID,
        title: "Atlas Before Dawn",
        author: "Bea Moss",
        narrator: "Ada Coil",
        series: "Atlas Cycle",
        seriesPosition: "2",
        relativePath: atlasPath,
        bytes: atlasBytes,
        date: date,
        cover: cover
      )
      let cedarBook = committedMetadataCompanionBook(
        id: cedarBookID,
        assetID: cedarAssetID,
        title: "Cedar Signals",
        author: "Nico Vale",
        narrator: "Soren Bell",
        series: "Cedar Arc",
        seriesPosition: "1",
        relativePath: cedarPath,
        bytes: cedarBytes,
        date: date.addingTimeInterval(1),
        cover: cover
      )
      let seed = LibrarySnapshot(
        books: [targetBook, atlasBook, cedarBook],
        importJobs: [],
        currentBookID: nil,
        allBooksViewStyle: .shelf
      )
      E2ECommittedMetadataBridge.shared.configure(
        libraryURL: libraryURL,
        targetBookID: targetBookID,
        expectedTransactionID: transactionID,
        originalMetadata: targetMetadata,
        sourceURL: sourceURL,
        expectedArtifacts: artifacts
      )
      let ids = (1...40).compactMap {
        UUID(uuidString: String(format: "a7100000-0000-0000-0000-%012d", $0))
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryURL),
          seed: seed
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func committedMetadataCompanionBook(
      id: UUID,
      assetID: UUID,
      title: String,
      author: String,
      narrator: String,
      series: String,
      seriesPosition: String,
      relativePath: String,
      bytes: Data,
      date: Date,
      cover: Data
    ) -> Book {
      let metadata = AudiobookMetadata.imported(
        title: title,
        authors: [author],
        narrators: [narrator],
        seriesName: series,
        seriesPosition: seriesPosition,
        artworkData: cover,
        artworkMediaType: "image/png"
      )
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "\(title.lowercased().replacingOccurrences(of: " ", with: "-")).m4b",
        managedRelativePath: relativePath,
        checksumSHA256: committedMetadataChecksum(bytes),
        byteCount: Int64(bytes.count),
        durationSeconds: 120,
        container: "M4B"
      )
      return Book(
        id: id,
        title: title,
        authors: [author],
        durationSeconds: asset.durationSeconds,
        artworkData: cover,
        assets: [asset],
        dateAdded: date,
        narrators: [narrator],
        seriesName: series,
        seriesPosition: seriesPosition,
        artworkMediaType: "image/png",
        metadata: metadata
      )
    }

    private static func committedMetadataChecksum(_ data: Data) -> String {
      SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func metadataRepairEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let environment = ProcessInfo.processInfo.environment
      guard
        let audioEncoded = environment["PLAYER_E2E_METADATA_AUDIO_BASE64"],
        let audio = Data(base64Encoded: audioEncoded),
        let coverEncoded = environment["PLAYER_E2E_METADATA_ORIGINAL_COVER_BASE64"],
        let cover = Data(base64Encoded: coverEncoded)
      else {
        throw PlayerCoreError.fileOperation("The synthetic metadata-repair fixture is unavailable.")
      }
      let replacementCover = try E2EMetadataReplacementCoverPayload.parse(
        environment: environment
      )

      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(
        path: "PlayerE2EMetadataRepair",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let jobID = UUID(uuidString: "80000000-0000-0000-0000-000000000001")!
      let proposalID = UUID(uuidString: "80000000-0000-0000-0000-000000000002")!
      let assetID = UUID(uuidString: "80000000-0000-0000-0000-000000000003")!
      let bookID = UUID(uuidString: "80000000-0000-0000-0000-000000000004")!
      let sourceURL = root.appending(path: "Input/metadata-repair-source.m4b")
      let stagedRelativePath = "Staging/\(jobID.uuidString.lowercased())/metadata-repair-source.m4b"
      let stagedURL = root.appending(path: stagedRelativePath)
      for url in [sourceURL, stagedURL] {
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try audio.write(to: url, options: .atomic)
      }

      let checksum = "6c5a700ee340ace483b4cd45188403ca9a77fd60d94ba248063ee2c7fc6366f7"
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "metadata-repair-source.m4b",
        managedRelativePath: "",
        checksumSHA256: checksum,
        byteCount: Int64(audio.count),
        durationSeconds: 2.4,
        container: "M4B"
      )
      let metadata = AudiobookMetadata.imported(
        title: "The Brass Lantern",
        authors: ["Mira Sol"],
        narrators: ["Anika Reed"],
        seriesName: "Night Signals",
        seriesPosition: "4",
        artworkData: cover,
        artworkMediaType: "image/png",
        provenance: .embeddedTag,
        confidence: .high
      )
      let proposal = BookProposal(
        id: proposalID,
        proposedBookID: bookID,
        title: metadata.title,
        authors: metadata.authors.map(\.displayName),
        durationSeconds: asset.durationSeconds,
        artworkData: cover,
        asset: asset,
        warnings: [],
        narrators: metadata.narrators.map(\.displayName),
        seriesName: metadata.seriesMemberships.first?.name,
        seriesPosition: metadata.seriesMemberships.first?.position,
        artworkMediaType: "image/png",
        metadata: metadata
      )
      let date = Date(timeIntervalSince1970: 1_700_000_000)
      let job = ImportJob(
        id: jobID,
        sourceFilename: asset.originalFilename,
        phase: .ready,
        progress: ImportProgress(completed: Int64(audio.count), total: Int64(audio.count)),
        stagedRelativePath: stagedRelativePath,
        proposal: proposal,
        committedBookID: nil,
        failure: nil,
        createdAt: date,
        updatedAt: date
      )
      let managedURL = root.appending(
        path: "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      )
      E2EMetadataRepairBridge.shared.configure(
        sourceURL: sourceURL,
        sourceBytes: audio,
        managedURL: managedURL,
        libraryURL: root.appending(path: "Library.json"),
        checksum: checksum,
        replacementCoverData: replacementCover
      )
      let ids = (10...30).compactMap {
        UUID(uuidString: String(format: "80000000-0000-0000-0000-%012d", $0))
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
          seed: LibrarySnapshot(books: [], importJobs: [job], currentBookID: nil)
        ),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func populatedLibraryEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let launchEnvironment = ProcessInfo.processInfo.environment
      guard
        let descriptorEncoded = launchEnvironment["PLAYER_E2E_LIBRARY_DESCRIPTOR_BASE64"],
        let descriptorData = Data(base64Encoded: descriptorEncoded),
        let audioEncoded = launchEnvironment["PLAYER_E2E_LIBRARY_AUDIO_BASE64"],
        let audio = Data(base64Encoded: audioEncoded)
      else {
        throw PlayerCoreError.fileOperation("The synthetic populated-library fixture is unavailable.")
      }
      let covers = try (1...5).map { index -> Data in
        guard
          let encoded = launchEnvironment["PLAYER_E2E_LIBRARY_COVER_B\(index)_BASE64"],
          let cover = Data(base64Encoded: encoded)
        else {
          throw PlayerCoreError.fileOperation(
            "A synthetic populated-library cover is unavailable."
          )
        }
        return cover
      }

      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      let root = support.appending(path: "PlayerE2EPopulatedLibrary", directoryHint: .isDirectory)
      return try populatedLibraryEnvironment(
        reset: reset,
        root: root,
        descriptorData: descriptorData,
        audio: audio,
        covers: covers,
        permanentTrashScenario: false
      )
    }

    private static func permanentTrashEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let launchEnvironment = ProcessInfo.processInfo.environment
      guard
        let descriptorEncoded = launchEnvironment["PLAYER_E2E_LIBRARY_DESCRIPTOR_BASE64"],
        let descriptorData = Data(base64Encoded: descriptorEncoded),
        let audioEncoded = launchEnvironment["PLAYER_E2E_LIBRARY_AUDIO_BASE64"],
        let audio = Data(base64Encoded: audioEncoded)
      else {
        throw PlayerCoreError.fileOperation(
          "The permanent-Trash fixture payload is unavailable."
        )
      }
      let covers = try (1...5).map { index -> Data in
        guard let encoded = launchEnvironment["PLAYER_E2E_LIBRARY_COVER_B\(index)_BASE64"],
          let data = Data(base64Encoded: encoded)
        else {
          throw PlayerCoreError.fileOperation(
            "The permanent-Trash cover fixture is unavailable."
          )
        }
        return data
      }
      let support = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
      )
      return try populatedLibraryEnvironment(
        reset: reset,
        root: support.appending(
          path: "PlayerE2EPermanentTrash",
          directoryHint: .isDirectory
        ),
        descriptorData: descriptorData,
        audio: audio,
        covers: covers,
        permanentTrashScenario: true
      )
    }

    static func populatedLibraryEnvironment(
      reset: Bool,
      root: URL,
      descriptorData: Data,
      audio: Data,
      covers: [Data],
      permanentTrashScenario: Bool = false
    ) throws -> PlayerEnvironment {
      let validated = try E2EPopulatedLibraryDescriptor.validated(
        data: descriptorData,
        audio: audio
      )
      let descriptor = validated.descriptor
      guard covers.count == descriptor.books.count else {
        throw PlayerCoreError.fileOperation(
          "The synthetic populated-library fixture has the wrong cover count."
        )
      }

      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      var purgeTargetAudio = audio
      if permanentTrashScenario, !purgeTargetAudio.isEmpty {
        purgeTargetAudio[purgeTargetAudio.index(before: purgeTargetAudio.endIndex)] ^= 0x01
      }
      let purgeTargetChecksum = SHA256.hash(data: purgeTargetAudio)
        .map { String(format: "%02x", $0) }.joined()
      let sourceRoot = FileManager.default.temporaryDirectory.appending(
        path: permanentTrashScenario
          ? "PlayerE2EPermanentTrashSource" : "PlayerE2EPopulatedLibrarySource",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(sourceRoot) }
      try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
      let sourceURL = sourceRoot.appending(path: "library-book-audio.m4b")
      if !FileManager.default.fileExists(atPath: sourceURL.path) {
        try purgeTargetAudio.write(to: sourceURL, options: .atomic)
      }
      let libraryFileURL = root.appending(path: "Library.json")
      let persistedLibrary = try E2EPersistedLibrary.load(from: libraryFileURL)?.snapshot
      let media = FileSystemMediaManager(rootURL: root)

      let clock = validated.clock
      var books: [Book] = []
      for (index, fixtureBook) in descriptor.books.enumerated() {
        let bookID = validated.bookIDs[index]
        let assetID = validated.assetIDs[index]
        let cover = covers[index]
        let assetAudio = permanentTrashScenario && index == 0 ? purgeTargetAudio : audio
        let assetChecksum = permanentTrashScenario && index == 0
          ? purgeTargetChecksum : descriptor.audio.sha256
        let relativePath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
        let managedURL = root.appending(path: relativePath)
        let shouldHaveManagedCopy = persistedLibrary?.books.contains(where: { $0.id == bookID }) ?? true
        if shouldHaveManagedCopy && !FileManager.default.fileExists(atPath: managedURL.path) {
          try FileManager.default.createDirectory(
            at: managedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
          )
          try assetAudio.write(to: managedURL, options: .atomic)
        }
        let asset = AudioAsset(
          id: assetID,
          originalFilename: "library-book-audio.m4b",
          managedRelativePath: relativePath,
          checksumSHA256: assetChecksum,
          byteCount: Int64(assetAudio.count),
          durationSeconds: Double(descriptor.audio.logicalBookDurationMilliseconds) / 1_000,
          container: "M4B"
        )
        let author = Contributor(
          id: fixtureBook.author.id,
          displayName: fixtureBook.author.name
        )
        let narrator = Contributor(
          id: fixtureBook.narrator.id,
          displayName: fixtureBook.narrator.name
        )
        let memberships = fixtureBook.series.map {
          [SeriesMembership(seriesID: $0.id, name: $0.name, position: $0.position)]
        } ?? []
        let metadata = AudiobookMetadata(
          title: fixtureBook.title,
          authors: [author],
          narrators: [narrator],
          seriesMemberships: memberships,
          cover: CoverArtwork(originalData: cover, mediaType: "image/png", source: .embedded)
        )
        let position = fixtureBook.positionMilliseconds
        let listeningState = BookListeningState(
          status: fixtureBook.finished ? .finished : (position > 0 ? .inProgress : .unplayed),
          positionMilliseconds: position,
          lastListenedAt: position > 0 ? clock.addingTimeInterval(Double(-10 - index * 10)) : nil,
          finishedAt: fixtureBook.finished ? clock.addingTimeInterval(-100) : nil
        )
        books.append(
          Book(
            id: bookID,
            title: fixtureBook.title,
            authors: [fixtureBook.author.name],
            durationSeconds: asset.durationSeconds,
            artworkData: cover,
            assets: [asset],
            dateAdded: clock.addingTimeInterval(Double(fixtureBook.addedOrder)),
            narrators: [fixtureBook.narrator.name],
            seriesName: fixtureBook.series?.name,
            seriesPosition: fixtureBook.series?.position,
            artworkMediaType: "image/png",
            chapters: [
              Chapter(
                id: "file-\(assetID.uuidString.lowercased())",
                title: "Full Book",
                startSeconds: 0,
                durationSeconds: asset.durationSeconds,
                source: .file,
                assetID: assetID
              )
            ],
            metadata: metadata,
            listeningState: listeningState
          )
        )
      }

      let currentBookID = validated.currentBookID
      guard
        let currentBook = books.first(where: { $0.id == currentBookID }),
        let seedEventID = UUID(uuidString: "90000000-0000-0000-0000-000000000701")
      else {
        throw PlayerCoreError.fileOperation("The synthetic populated-library identity map is invalid.")
      }
      let collectionID = validated.collectionID
      let trashID = validated.trashTransactionID
      let seedEvent = PositionEvent.acknowledged(
        id: seedEventID,
        bookID: currentBookID,
        positionMilliseconds: currentBook.listeningState.positionMilliseconds,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: clock,
        previousEventID: nil
      )
      var seed = LibrarySnapshot(
        books: books,
        importJobs: [],
        currentBookID: currentBookID,
        playbackPosition: PlaybackPosition(
          bookID: currentBookID,
          positionMilliseconds: seedEvent.positionMilliseconds,
          sequence: seedEvent.sequence,
          sourceEventID: seedEvent.id,
          updatedAt: clock
        ),
        positionJournal: [seedEvent],
        upNextBookIDs: validated.upNextBookIDs,
        allBooksViewStyle: validated.viewPreference
      )
      if permanentTrashScenario, persistedLibrary == nil {
        let siblingID = UUID(uuidString: "90000000-0000-0000-0000-000000000601")!
        let siblingBookID = validated.bookIDs[4]
        let siblingBook = seed.books.remove(at: 4)
        let siblingBookComponent = siblingBookID.uuidString.lowercased()
        let siblingTransactionComponent = siblingID.uuidString.lowercased()
        let siblingOriginalDirectory = "Media/\(siblingBookComponent)"
        let siblingTrashDirectory = "Trash/\(siblingTransactionComponent)"
        let siblingTrashMediaDirectory = "\(siblingTrashDirectory)/Media/\(siblingBookComponent)"
        let siblingOriginalURL = root.appending(path: siblingOriginalDirectory)
        let siblingTrashURL = root.appending(path: siblingTrashDirectory)
        let siblingTrashMediaURL = root.appending(path: siblingTrashMediaDirectory)
        let siblingManifest = TrashedMediaManifest(
          transactionID: siblingID,
          bookID: siblingBookID,
          originalDirectoryRelativePath: siblingOriginalDirectory,
          trashDirectoryRelativePath: siblingTrashMediaDirectory,
          byteCount: Int64(descriptor.audio.byteCount)
        )
        try FileManager.default.createDirectory(
          at: siblingTrashMediaURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        let siblingManifestEncoder = JSONEncoder()
        siblingManifestEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try siblingManifestEncoder.encode(siblingManifest).write(
          to: siblingTrashURL.appending(path: "manifest.json"),
          options: [.atomic, .completeFileProtectionUnlessOpen]
        )
        try FileManager.default.moveItem(at: siblingOriginalURL, to: siblingTrashMediaURL)
        let upNextIndex = seed.upNextBookIDs.firstIndex(of: siblingBookID)
        seed.upNextBookIDs.removeAll { $0 == siblingBookID }
        seed.trashTransactions = [LibraryTrashTransaction(
          id: siblingID,
          book: siblingBook,
          originalBookIndex: 4,
          mediaPolicy: .moveManagedMediaToTrash,
          mediaManifest: siblingManifest,
          upNextIndex: upNextIndex,
          collectionPlacements: [],
          wasCurrentBook: false,
          playbackPosition: nil,
          positionEvents: [],
          metadataTransactions: [],
          removedAt: clock,
          status: .recoverable,
          restoredAt: nil
        )]
      }
      E2ELibraryOrganizationBridge.shared.configure(
        rootURL: root,
        trackedBookID: descriptor.books[4].id,
        expectedChecksum: descriptor.audio.sha256,
        purgeTargetExpectedChecksum: purgeTargetChecksum,
        purgeTargetBookID: descriptor.currentBookID,
        purgeTransactionID: "90000000-0000-0000-0000-000000000602",
        siblingTrashBookID: descriptor.books[4].id,
        siblingTrashTransactionID: "90000000-0000-0000-0000-000000000601",
        expectedOtherManagedFileCount: permanentTrashScenario
          ? descriptor.books.count - 2 : descriptor.books.count - 1,
        expectedManagedByteCount: descriptor.audio.byteCount,
        libraryURL: libraryFileURL,
        sourceURL: sourceURL
      )
      if permanentTrashScenario {
        E2EMultifileAcquisition.shared.configure(
          selectionURLs: [sourceURL],
          storageRootURL: root,
          entryPoint: .explicitFileChoice
        )
      }
      let generatedIDs: [UUID]
      if permanentTrashScenario {
        let firstImportSuffix = try E2EPersistedIDSequence.nextSuffix(
          in: libraryFileURL,
          prefix: "90000000",
          initialSuffix: 702,
          requiredCount: 40
        )
        let importIDs = (firstImportSuffix..<(firstImportSuffix + 40)).map {
          UUID(uuidString: String(format: "90000000-0000-0000-0000-%012d", $0))!
        }
        generatedIDs = persistedLibrary == nil
          ? [UUID(uuidString: "90000000-0000-0000-0000-000000000602")!] + importIDs
          : importIDs
      } else if persistedLibrary?.collections.contains(where: { $0.id == collectionID }) == true {
        if persistedLibrary?.trashTransactions.contains(where: { $0.id == trashID }) == true {
          generatedIDs = [
            UUID(uuidString: "90000000-0000-0000-0000-000000000602")!
          ]
        } else {
          generatedIDs = [trashID]
        }
      } else {
        generatedIDs = [collectionID, trashID]
      }
      return PlayerEnvironment(
        persistence: E2ESeededLibraryStore(
          base: CodableLibraryStore(fileURL: libraryFileURL),
          seed: seed
        ),
        media: media,
        inspector: permanentTrashScenario
          ? DeterministicAudioInspector(result: .success(InspectedAudio(
            title: "Reimported Source",
            authors: ["Fixture Author"],
            durationSeconds: Double(descriptor.audio.logicalBookDurationMilliseconds) / 1_000,
            artworkData: covers[0],
            container: "M4B"
          )))
          : DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: clock),
        ids: DeterministicPlayerIDGenerator(values: generatedIDs)
      )
    }

    private static func offlineRecoveryEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EOfflineRecovery",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let date = Date(timeIntervalSince1970: 1_750_000_000)
      let bookID = UUID(uuidString: "d1000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "d1000000-0000-0000-0000-000000000002")!
      let forbidden = [
        "Private Recovery Book",
        "Private Recovery Author",
        "private-recovery-source.m4b",
        "private-recovery-checksum",
        "Private recovery note",
        "private-pairing-secret",
      ]
      let mediaPath =
        "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let mediaURL = root.appending(path: mediaPath)
      try FileManager.default.createDirectory(
        at: mediaURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("deterministic recovered audio".utf8).write(to: mediaURL)
      let asset = AudioAsset(
        id: assetID,
        originalFilename: forbidden[2],
        managedRelativePath: mediaPath,
        checksumSHA256: forbidden[3],
        byteCount: 29,
        durationSeconds: 180,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: forbidden[0],
        authors: [forbidden[1]],
        durationSeconds: 180,
        artworkData: nil,
        assets: [asset],
        dateAdded: date
      )
      let snapshot = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: nil,
        bookmarks: [Bookmark(
          id: UUID(uuidString: "d1000000-0000-0000-0000-000000000003")!,
          bookID: bookID,
          bookPositionMilliseconds: 48_000,
          assetID: assetID,
          assetPositionMilliseconds: 48_000,
          chapterID: nil,
          chapterTitleSnapshot: nil,
          label: "Private recovery bookmark",
          note: forbidden[4],
          createdAt: date,
          updatedAt: date
        )]
      )
      let backupDirectory = root.appending(
        path: "AutomaticBackups",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: backupDirectory,
        withIntermediateDirectories: true
      )
      let envelope = E2EOfflineRecoveryEnvelope(
        schemaVersion: CodableLibraryStore.currentSchemaVersion,
        library: snapshot
      )
      try JSONEncoder.playerEncoder.encode(envelope).write(
        to: backupDirectory.appending(path: "library-safe-copy.json"),
        options: .atomic
      )
      try Data("corrupt primary with private catalog bytes".utf8).write(
        to: root.appending(path: "Library.json"),
        options: .atomic
      )
      let orphans: [(String, String)] = [
        ("Media/d2000000-0000-0000-0000-000000000001/private-orphan.m4b", "media"),
        ("Staging/d2000000-0000-0000-0000-000000000002/private.partial", "staging"),
        ("Trash/d2000000-0000-0000-0000-000000000003/private-trash.m4b", "trash"),
      ]
      for (path, contents) in orphans {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
      }
      E2EOfflineRecoveryBridge.shared.configure(forbiddenValues: forbidden)
      return PlayerEnvironment(
        persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        diagnostics: FileSystemSupportDiagnosticsManager(
          rootURL: root,
          clock: FixedPlayerClock(value: date),
          appVersion: "0.1.0",
          appBuild: "17"
        )
      )
    }

    private static func portableBackupEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EPortableBackup",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let bookID = UUID(uuidString: "a1000000-0000-0000-0000-000000000001")!
      let assetID = UUID(uuidString: "a1000000-0000-0000-0000-000000000002")!
      let eventID = UUID(uuidString: "a1000000-0000-0000-0000-000000000003")!
      let bookmarkID = UUID(uuidString: "a1000000-0000-0000-0000-000000000004")!
      let date = Date(timeIntervalSince1970: 1_750_000_000)
      let audio = Data("player deterministic portable backup audio".utf8)
      let managedPath = "Media/\(bookID.uuidString.lowercased())/\(assetID.uuidString.lowercased()).m4b"
      let managedURL = root.appending(path: managedPath)
      try FileManager.default.createDirectory(
        at: managedURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try audio.write(to: managedURL)
      let checksum = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
      let asset = AudioAsset(
        id: assetID,
        originalFilename: "portable-lighthouse.m4b",
        managedRelativePath: managedPath,
        checksumSHA256: checksum,
        byteCount: Int64(audio.count),
        durationSeconds: 300,
        container: "M4B"
      )
      let book = Book(
        id: bookID,
        title: "The Portable Lighthouse",
        authors: ["Mara Vale"],
        durationSeconds: 300,
        artworkData: Data([0x89, 0x50, 0x4e, 0x47]),
        assets: [asset],
        dateAdded: date,
        narrators: ["Nora Reed"],
        seriesName: "Signal Stories",
        seriesPosition: "1",
        artworkMediaType: "image/png",
        chapters: [Chapter(
          id: "opening", title: "Opening", startSeconds: 0,
          durationSeconds: 300, source: .embedded, assetID: assetID
        )],
        listeningState: BookListeningState(
          status: .inProgress,
          positionMilliseconds: 42_000,
          lastListenedAt: date,
          finishedAt: nil
        )
      )
      let event = PositionEvent.acknowledged(
        id: eventID,
        bookID: bookID,
        positionMilliseconds: 42_000,
        sequence: 1,
        reason: .pause,
        acknowledgedAt: date,
        previousEventID: nil
      )
      let snapshot = LibrarySnapshot(
        books: [book],
        importJobs: [],
        currentBookID: bookID,
        playbackPosition: PlaybackPosition(
          bookID: bookID,
          positionMilliseconds: 42_000,
          sequence: 1,
          sourceEventID: eventID,
          updatedAt: date
        ),
        positionJournal: [event],
        upNextBookIDs: [bookID],
        allBooksViewStyle: .list,
        bookmarks: [Bookmark(
          id: bookmarkID,
          bookID: bookID,
          bookPositionMilliseconds: 42_000,
          assetID: assetID,
          assetPositionMilliseconds: 42_000,
          chapterID: "opening",
          chapterTitleSnapshot: "Opening",
          label: "Important signal",
          note: "Return here",
          createdAt: date,
          updatedAt: date
        )]
      )
      E2EBackupBridge.shared.configure(
        rootURL: root,
        expectedLibrary: snapshot,
        expectedAudio: audio,
        managedRelativePath: managedPath
      )
      return PlayerEnvironment(
        persistence: InMemoryLibraryStore(snapshot: snapshot),
        media: FileSystemMediaManager(rootURL: root),
        inspector: DeterministicAudioInspector(result: .failure(.unreadableAudio("unused"))),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: date),
        backups: FileSystemLibraryBackupManager(
          rootURL: root,
          clock: FixedPlayerClock(value: date)
        )
      )
    }

    private static func messyMultifileEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2EMessyMultifile",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      let inputRoot = root.appending(path: "Input", directoryHint: .isDirectory)
      let folder = inputRoot.appending(
        path: "Signal Δ — Folder",
        directoryHint: .isDirectory
      )
      let loose = inputRoot.appending(path: "Loose Files", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)

      let folderFiles = [
        "Signal Δ — Part 1.m4a",
        "Signal Δ — Part 2.m4a",
        "Signal Δ — Part 10.m4a",
        "Prélude – été.m4a",
      ]
      let looseFiles = [
        "L’Écho — piste 3.m4a",
        "L’Écho — piste 4 – café.m4a",
        "L’Écho — piste 5.m4a",
        "L’Écho — piste 6 – fin.m4a",
      ]
      for (index, name) in folderFiles.enumerated() {
        let url = folder.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) {
          try Data("player synthetic folder audio \(index)".utf8).write(to: url)
        }
      }
      for (index, name) in looseFiles.enumerated() {
        let url = loose.appending(path: name)
        if !FileManager.default.fileExists(atPath: url.path) {
          try Data("player synthetic loose audio \(index)".utf8).write(to: url)
        }
      }

      let selection = [folder] + looseFiles.map { loose.appending(path: $0) }
      let playerDataRoot = root.appending(path: "PlayerData", directoryHint: .isDirectory)
      E2EMultifileAcquisition.shared.configure(
        selectionURLs: selection,
        storageRootURL: playerDataRoot
      )
      let ids = [
        "30000000-0000-0000-0000-000000000001",
        "30000000-0000-0000-0000-000000000101",
        "30000000-0000-0000-0000-000000000102",
        "30000000-0000-0000-0000-000000000110",
        "30000000-0000-0000-0000-000000000111",
        "30000000-0000-0000-0000-000000000203",
        "30000000-0000-0000-0000-000000000204",
        "30000000-0000-0000-0000-000000000205",
        "30000000-0000-0000-0000-000000000206",
        "30000000-0000-0000-0000-000000000010",
        "30000000-0000-0000-0000-000000000100",
        "30000000-0000-0000-0000-000000000020",
        "30000000-0000-0000-0000-000000000200",
        "30000000-0000-0000-0000-000000000030",
        "30000000-0000-0000-0000-000000000300",
      ].compactMap(UUID.init(uuidString:))
      return PlayerEnvironment(
        persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
        media: FileSystemMediaManager(rootURL: playerDataRoot),
        inspector: DeterministicAudioInspector(
          result: .success(
            InspectedAudio(
              title: nil,
              authors: [],
              durationSeconds: 60,
              artworkData: nil,
              container: "M4A"
            )
          )
        ),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids)
      )
    }

    private static func safeZipEnvironment(reset: Bool) throws -> PlayerEnvironment {
      let arguments = ProcessInfo.processInfo.arguments
      let options = try E2ESafeZIPArguments.parse(arguments: arguments)
      let bytes = try E2EZIPFixturePayload.parse(
        environment: ProcessInfo.processInfo.environment
      )
      let root = FileManager.default.temporaryDirectory.appending(
        path: "PlayerE2ESafeZIP",
        directoryHint: .isDirectory
      )
      if reset { try resetE2EFixtureRoot(root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

      let sourceURL = root.appending(path: "selected-audiobook.zip")
      try bytes.write(to: sourceURL, options: .atomic)
      try E2EZipAcquisition.shared.configure(
        zipCase: options.archiveCase.rawValue,
        sourceURL: sourceURL,
        sourceBytes: bytes
      )

      var policy = ZipExtractionPolicy.audiobook
      policy.maximumEntryCount = options.limits.maximumEntryCount
      policy.maximumEntryBytes = options.limits.maximumEntryBytes
      policy.maximumEntryExpansionRatio = options.limits.maximumEntryExpansionRatio
      let result = InspectedAudio(
        title: nil,
        authors: [],
        durationSeconds: 60,
        artworkData: nil,
        container: "M4A"
      )
      let ids = (1...12).compactMap {
        UUID(uuidString: String(format: "60000000-0000-0000-0000-%012d", $0))
      }
      return PlayerEnvironment(
        persistence: CodableLibraryStore(fileURL: root.appending(path: "Library.json")),
        media: FileSystemMediaManager(rootURL: root.appending(path: "PlayerData")),
        inspector: E2EZipAudioInspector(result: result, failOnce: options.failOnce == .inspection),
        playback: DeterministicPlaybackController(),
        clock: FixedPlayerClock(value: Date(timeIntervalSince1970: 1_700_000_000)),
        ids: DeterministicPlayerIDGenerator(values: ids),
        zipExtractor: SafeZipExtractor(policy: policy)
      )
    }

    private static func metadataRichArtwork(override: Data?) -> Data {
      if let override { return override }

      let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 240))
      return renderer.pngData { context in
        UIColor(red: 0.08, green: 0.16, blue: 0.21, alpha: 1).setFill()
        context.fill(CGRect(x: 0, y: 0, width: 240, height: 240))

        UIColor(red: 0.82, green: 0.34, blue: 0.20, alpha: 1).setFill()
        context.cgContext.fillEllipse(in: CGRect(x: 78, y: 48, width: 84, height: 84))

        context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
        context.cgContext.setLineWidth(9)
        context.cgContext.setLineCap(.round)
        for offset in stride(from: 0, through: 54, by: 18) {
          context.cgContext.move(to: CGPoint(x: 36, y: 158 + offset))
          context.cgContext.addCurve(
            to: CGPoint(x: 204, y: 158 + offset),
            control1: CGPoint(x: 78, y: 134 + offset),
            control2: CGPoint(x: 156, y: 182 + offset)
          )
        }
        context.cgContext.strokePath()
      }
    }
  #endif
}

#if E2E
  struct E2EPopulatedLibraryDescriptor: Decodable {
    struct Audio: Decodable {
      var byteCount: Int
      var sha256: String
      var logicalBookDurationMilliseconds: Int64
    }

    struct Identity: Decodable {
      var id: String
      var name: String
    }

    struct Series: Decodable {
      var id: String
      var name: String
      var position: String
    }

    struct FixtureBook: Decodable {
      var id: String
      var assetID: String
      var title: String
      var author: Identity
      var narrator: Identity
      var series: Series?
      var positionMilliseconds: Int64
      var finished: Bool
      var addedOrder: Int
    }

    struct GeneratedIDs: Decodable {
      var collection: String
      var trashTransaction: String
    }

    var schemaVersion: Int
    var clock: String
    var audio: Audio
    var books: [FixtureBook]
    var currentBookID: String
    var upNext: [String]
    var viewPreference: String
    var generatedIDs: GeneratedIDs

    struct Validated {
      let descriptor: E2EPopulatedLibraryDescriptor
      let clock: Date
      let bookIDs: [UUID]
      let assetIDs: [UUID]
      let currentBookID: UUID
      let upNextBookIDs: [UUID]
      let viewPreference: LibraryViewStyle
      let collectionID: UUID
      let trashTransactionID: UUID
    }

    static func validated(data: Data, audio: Data) throws -> Validated {
      let descriptor = try JSONDecoder().decode(Self.self, from: data)
      let checksum = SHA256.hash(data: audio).map { String(format: "%02x", $0) }.joined()
      let clockFormatter = ISO8601DateFormatter()
      guard
        descriptor.schemaVersion == 1,
        descriptor.books.count == 5,
        descriptor.audio.byteCount == audio.count,
        descriptor.audio.sha256 == checksum,
        let clock = clockFormatter.date(from: descriptor.clock),
        clockFormatter.string(from: clock) == descriptor.clock,
        let viewPreference = LibraryViewStyle(rawValue: descriptor.viewPreference),
        let currentBookID = UUID(uuidString: descriptor.currentBookID),
        let collectionID = UUID(uuidString: descriptor.generatedIDs.collection),
        let trashTransactionID = UUID(uuidString: descriptor.generatedIDs.trashTransaction)
      else {
        throw PlayerCoreError.fileOperation(
          "The synthetic populated-library fixture failed validation."
        )
      }

      let bookIDs = try decodedUUIDs(descriptor.books.map(\.id), field: "book")
      let assetIDs = try decodedUUIDs(descriptor.books.map(\.assetID), field: "asset")
      let upNextBookIDs = try decodedUUIDs(descriptor.upNext, field: "Up Next")
      guard bookIDs.contains(currentBookID) else {
        throw PlayerCoreError.fileOperation(
          "The synthetic populated-library current book is not in the fixture."
        )
      }

      return Validated(
        descriptor: descriptor,
        clock: clock,
        bookIDs: bookIDs,
        assetIDs: assetIDs,
        currentBookID: currentBookID,
        upNextBookIDs: upNextBookIDs,
        viewPreference: viewPreference,
        collectionID: collectionID,
        trashTransactionID: trashTransactionID
      )
    }

    private static func decodedUUIDs(_ encoded: [String], field: String) throws -> [UUID] {
      let decoded = encoded.compactMap(UUID.init(uuidString:))
      guard decoded.count == encoded.count else {
        throw PlayerCoreError.fileOperation(
          "The synthetic populated-library \(field) identity map is invalid."
        )
      }
      return decoded
    }
  }

  @MainActor
  final class E2ELibraryOrganizationBridge {
    static let shared = E2ELibraryOrganizationBridge()

    private var rootURL: URL?
    private var trackedBookID: String?
    private var expectedChecksum: String?
    private var purgeTargetExpectedChecksum: String?
    private var purgeTargetBookID: String?
    private var purgeTransactionID: UUID?
    private var siblingTrashBookID: String?
    private var siblingTrashTransactionID: UUID?
    private var expectedOtherManagedFileCount = 0
    private var expectedManagedByteCount = 0
    private var libraryURL: URL?
    private var sourceURL: URL?

    func configure(
      rootURL: URL,
      trackedBookID: String,
      expectedChecksum: String,
      purgeTargetExpectedChecksum: String,
      purgeTargetBookID: String,
      purgeTransactionID: String,
      siblingTrashBookID: String,
      siblingTrashTransactionID: String,
      expectedOtherManagedFileCount: Int,
      expectedManagedByteCount: Int,
      libraryURL: URL,
      sourceURL: URL
    ) {
      self.rootURL = rootURL
      self.trackedBookID = trackedBookID.lowercased()
      self.expectedChecksum = expectedChecksum
      self.purgeTargetExpectedChecksum = purgeTargetExpectedChecksum
      self.purgeTargetBookID = purgeTargetBookID.lowercased()
      self.purgeTransactionID = UUID(uuidString: purgeTransactionID)
      self.siblingTrashBookID = siblingTrashBookID.lowercased()
      self.siblingTrashTransactionID = UUID(uuidString: siblingTrashTransactionID)
      self.expectedOtherManagedFileCount = expectedOtherManagedFileCount
      self.expectedManagedByteCount = expectedManagedByteCount
      self.libraryURL = libraryURL
      self.sourceURL = sourceURL
    }

    var managedChecksumPreserved: Bool {
      guard let rootURL, let trackedBookID, let expectedChecksum else { return false }
      let fileManager = FileManager.default
      guard let enumerator = fileManager.enumerator(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { return false }
      let candidates = enumerator.compactMap { $0 as? URL }.filter { url in
        url.pathExtension.lowercased() == "m4b"
          && url.path.lowercased().contains(trackedBookID)
      }
      guard candidates.count == 1, let data = try? Data(contentsOf: candidates[0]) else { return false }
      let checksum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
      return checksum == expectedChecksum
    }

    var permanentDeletionEvidence: String {
      guard let rootURL, let purgeTargetBookID, let purgeTransactionID,
        let siblingTrashBookID, let siblingTrashTransactionID,
        let expectedChecksum, let purgeTargetExpectedChecksum, let libraryURL, let sourceURL
      else { return "purge:unconfigured" }
      let mediaRoot = rootURL.appending(path: "Media", directoryHint: .isDirectory)
      let trashRoot = rootURL.appending(path: "Trash", directoryHint: .isDirectory)
      let pendingRoot = rootURL.appending(
        path: "PendingTrashDeletion",
        directoryHint: .isDirectory
      )
      let files = regularM4BFiles(in: rootURL)
      let targetFiles = files.filter { $0.path.lowercased().contains(purgeTargetBookID) }
      let siblingTrashFiles = files.filter {
        $0.path.lowercased().contains(siblingTrashBookID)
          && $0.pathComponents.contains("Trash")
      }
      let otherFiles = files.filter {
        !$0.path.lowercased().contains(purgeTargetBookID)
          && !$0.path.lowercased().contains(siblingTrashBookID)
      }
      let otherChecksumsPreserved = otherFiles.count == expectedOtherManagedFileCount
        && otherFiles.allSatisfy { checksum(of: $0) == expectedChecksum }
      let siblingChecksumPreserved = siblingTrashFiles.count == 1
        && siblingTrashFiles.allSatisfy { checksum(of: $0) == expectedChecksum }
      let targetChecksumPreserved = targetFiles.isEmpty
        ? true
        : targetFiles.count == 1
          && targetFiles.allSatisfy { checksum(of: $0) == purgeTargetExpectedChecksum }
      let sourceChecksumPreserved = checksum(of: sourceURL) == purgeTargetExpectedChecksum
      let persistedLibrary = try? E2EPersistedLibrary.load(from: libraryURL)
      let targetTransaction = persistedLibrary?.snapshot.trashTransactions.first {
        $0.id == purgeTransactionID
      }
      let siblingTransaction = persistedLibrary?.snapshot.trashTransactions.first {
        $0.id == siblingTrashTransactionID
      }
      let status = targetTransaction?.status.rawValue ?? "missing"
      let siblingStatus = siblingTransaction?.status.rawValue ?? "missing"
      let manifests = persistedLibrary?.snapshot.storageManifests ?? []
      let managedManifests = manifests.filter {
        if case .managedBook = $0.scope { return true }
        return false
      }
      let trashManifests = manifests.filter {
        if case .trashTransaction = $0.scope { return true }
        return false
      }
      let managedFiles = regularFiles(in: mediaRoot)
      let trashFiles = regularFiles(in: trashRoot)
      let pendingFiles = regularFiles(in: pendingRoot)
      let managedSummaryBytes = managedManifests.reduce(Int64(0)) { $0 + $1.byteCount }
      let trashSummaryBytes = trashManifests.reduce(Int64(0)) { $0 + $1.byteCount }
      let managedDiskBytes = byteCount(managedFiles)
      let trashDiskBytes = byteCount(trashFiles)
      let targetManifestAgrees = manifestAgrees(
        transaction: targetTransaction,
        transactionID: purgeTransactionID,
        rootURL: rootURL
      )
      let siblingManifestAgrees = manifestAgrees(
        transaction: siblingTransaction,
        transactionID: siblingTrashTransactionID,
        rootURL: rootURL
      )
      let storageSummaryMatchesDisk = managedSummaryBytes == managedDiskBytes
        && trashSummaryBytes == trashDiskBytes
      return [
        "purge",
        "transaction=\(status)",
        "target-files=\(targetFiles.count)",
        "target-bytes=\(byteCount(targetFiles))",
        "target-checksum-preserved=\(targetChecksumPreserved)",
        "target-manifest-agrees=\(targetManifestAgrees)",
        "sibling-transaction=\(siblingStatus)",
        "sibling-trash-files=\(siblingTrashFiles.count)",
        "sibling-trash-bytes=\(byteCount(siblingTrashFiles))",
        "sibling-manifest-agrees=\(siblingManifestAgrees)",
        "sibling-checksum-preserved=\(siblingChecksumPreserved)",
        "other-managed-files=\(otherFiles.count)",
        "other-managed-bytes=\(byteCount(otherFiles))",
        "other-checksums-preserved=\(otherChecksumsPreserved)",
        "managed-summary-files=\(managedManifests.reduce(0) { $0 + $1.fileCount })",
        "managed-summary-bytes=\(managedSummaryBytes)",
        "managed-disk-files=\(managedFiles.count)",
        "managed-disk-bytes=\(managedDiskBytes)",
        "trash-summary-files=\(trashManifests.reduce(0) { $0 + $1.fileCount })",
        "trash-summary-bytes=\(trashSummaryBytes)",
        "trash-disk-files=\(trashFiles.count)",
        "trash-disk-bytes=\(trashDiskBytes)",
        "storage-summary-matches-disk=\(storageSummaryMatchesDisk)",
        "pending-deletion-files=\(pendingFiles.count)",
        "expected-file-bytes=\(expectedManagedByteCount)",
        "source-checksum-preserved=\(sourceChecksumPreserved)",
      ].joined(separator: ":")
    }

    private func manifestAgrees(
      transaction: LibraryTrashTransaction?,
      transactionID: UUID,
      rootURL: URL
    ) -> Bool {
      let manifestURL = rootURL.appending(
        path: "Trash/\(transactionID.uuidString.lowercased())/manifest.json"
      )
      guard let transaction else { return false }
      if transaction.status == .purged {
        return transaction.mediaManifest == nil
          && !FileManager.default.fileExists(atPath: manifestURL.path)
      }
      guard transaction.status == .recoverable,
        let expected = transaction.mediaManifest,
        let data = try? Data(contentsOf: manifestURL),
        let actual = try? JSONDecoder().decode(TrashedMediaManifest.self, from: data)
      else { return false }
      return actual == expected
    }

    private func regularM4BFiles(in root: URL) -> [URL] {
      regularFiles(in: root).filter { $0.pathExtension.lowercased() == "m4b" }
    }

    private func regularFiles(in root: URL) -> [URL] {
      guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
      ) else { return [] }
      return enumerator.compactMap { $0 as? URL }.filter { url in
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      }
    }

    private func checksum(of url: URL) -> String? {
      guard let data = try? Data(contentsOf: url) else { return nil }
      return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func byteCount(_ urls: [URL]) -> Int64 {
      urls.reduce(Int64(0)) { result, url in
        result + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
      }
    }
  }

  @MainActor
  final class E2EMetadataRepairBridge {
    static let shared = E2EMetadataRepairBridge()

    private var sourceURL: URL?
    private var sourceBytes: Data?
    private var managedURL: URL?
    private var libraryURL: URL?
    private var checksum: String?
    private(set) var replacementCoverData: Data?

    var isConfigured: Bool {
      sourceURL != nil
        && sourceBytes != nil
        && managedURL != nil
        && libraryURL != nil
        && replacementCoverData != nil
    }

    func configure(
      sourceURL: URL,
      sourceBytes: Data,
      managedURL: URL,
      libraryURL: URL,
      checksum: String,
      replacementCoverData: Data
    ) {
      self.sourceURL = sourceURL
      self.sourceBytes = sourceBytes
      self.managedURL = managedURL
      self.libraryURL = libraryURL
      self.checksum = checksum
      self.replacementCoverData = replacementCoverData
    }

    var integrityValue: String {
      guard
        let sourceURL, let sourceBytes, let managedURL, let checksum
      else { return "audio:unconfigured" }
      let sourceUnchanged = (try? Data(contentsOf: sourceURL)) == sourceBytes
      let managed: String
      if FileManager.default.fileExists(atPath: managedURL.path) {
        managed = (try? Data(contentsOf: managedURL)) == sourceBytes ? checksum : "changed"
      } else {
        managed = "none"
      }
      return "audio:source=\(checksum):managed=\(managed):source-unchanged=\(sourceUnchanged)"
    }

    var persistenceValue: String {
      guard let libraryURL else { return "persistence=unconfigured" }
      do {
        guard let persisted = try E2EPersistedLibrary.load(from: libraryURL) else {
          return "persistence=missing"
        }
        let titles = persisted.snapshot.books.map(\.title).sorted().joined(separator: ",")
        return "persistence=books:\(persisted.snapshot.books.count):titles:\(titles)"
      } catch {
        return "persistence=invalid"
      }
    }
  }

  @MainActor
  final class E2ECommittedMetadataBridge {
    static let shared = E2ECommittedMetadataBridge()

    private var libraryURL: URL?
    private var targetBookID: UUID?
    private var expectedTransactionID: UUID?
    private var originalMetadata: AudiobookMetadata?
    private var sourceURL: URL?
    private var expectedArtifacts: [(url: URL, data: Data)] = []

    var isConfigured: Bool {
      libraryURL != nil
        && targetBookID != nil
        && expectedTransactionID != nil
        && originalMetadata != nil
        && sourceURL != nil
        && expectedArtifacts.count == 4
    }

    func configure(
      libraryURL: URL,
      targetBookID: UUID,
      expectedTransactionID: UUID,
      originalMetadata: AudiobookMetadata,
      sourceURL: URL,
      expectedArtifacts: [(URL, Data)]
    ) {
      self.libraryURL = libraryURL
      self.targetBookID = targetBookID
      self.expectedTransactionID = expectedTransactionID
      self.originalMetadata = originalMetadata
      self.sourceURL = sourceURL
      self.expectedArtifacts = expectedArtifacts.map { (url: $0.0, data: $0.1) }
    }

    var evidenceValue: String {
      guard isConfigured, let libraryURL, let targetBookID, let expectedTransactionID,
        let originalMetadata, let sourceURL
      else { return "schema=1:state=unconfigured" }
      guard let persisted = try? E2EPersistedLibrary.load(from: libraryURL) else {
        return "schema=1:state=missing"
      }

      let snapshot = persisted.snapshot
      let book = snapshot.books.first { $0.id == targetBookID }
      let transactions = snapshot.metadataTransactions.filter {
        $0.target == .book(targetBookID)
      }
      let applied = transactions.filter { $0.status == .applied }.count
      let undone = transactions.filter { $0.status == .undone }.count
      let transaction = transactions.first
      let transactionExact: Bool
      if transactions.isEmpty {
        transactionExact = book?.metadata == originalMetadata
      } else if transactions.count == 1, let transaction {
        transactionExact = transaction.id == expectedTransactionID
          && transaction.before == originalMetadata
          && committedMetadataMatchesEdited(
            transaction.after,
            transactionID: expectedTransactionID
          )
          && Set(transaction.mutations.map(\.field)) == committedMetadataEditedFields
          && transaction.mutations.count == 15
      } else {
        transactionExact = false
      }

      let state: String
      let metadataExact: Bool
      switch (transaction?.status, book?.metadata) {
      case (nil, .some(let metadata)):
        metadataExact = metadata == originalMetadata
        state = metadataExact && transactionExact ? "original" : "unexpected"
      case (.applied, .some(let metadata)):
        metadataExact = committedMetadataMatchesEdited(
          metadata,
          transactionID: expectedTransactionID
        )
        state = metadataExact && transactionExact ? "edited" : "unexpected"
      case (.undone, .some(let metadata)):
        metadataExact = metadata == originalMetadata
        state = metadataExact && transactionExact ? "restored" : "unexpected"
      default:
        metadataExact = false
        state = "unexpected"
      }

      let sourceExact = expectedArtifacts.first(where: { $0.url == sourceURL }).map {
        (try? Data(contentsOf: $0.url)) == $0.data
      } ?? false
      let managedArtifacts = expectedArtifacts.filter { $0.url != sourceURL }
      let managedExact = managedArtifacts.allSatisfy {
        (try? Data(contentsOf: $0.url)) == $0.data
      }
      let managedRoot = libraryURL.deletingLastPathComponent().appending(
        path: "Media",
        directoryHint: .isDirectory
      )
      let managedFiles = regularFiles(in: managedRoot).filter {
        $0.pathExtension.lowercased() == "m4b"
      }
      let audioUnchanged = sourceExact && managedExact
        && managedFiles.count == managedArtifacts.count

      return [
        "schema=1",
        "state=\(state)",
        "books=\(snapshot.books.count)",
        "target=\(book == nil ? "missing" : "present")",
        "transactions=\(transactions.count)",
        "applied=\(applied)",
        "undone=\(undone)",
        "transaction-exact=\(transactionExact)",
        "metadata-exact=\(metadataExact)",
        "source=\(sourceExact ? "exact" : "changed")",
        "managed-files=\(managedFiles.count)",
        "managed=\(managedExact ? "exact" : "changed")",
        "audio-unchanged=\(audioUnchanged)",
      ].joined(separator: ":")
    }

    private var committedMetadataEditedFields: Set<MetadataField> {
      Set(MetadataField.allCases.filter { $0 != .cover })
    }

    private func committedMetadataMatchesEdited(
      _ metadata: AudiobookMetadata,
      transactionID: UUID
    ) -> Bool {
      guard metadata.title == "The Amber Archive",
        metadata.sortTitle == "Amber Archive, The",
        metadata.subtitle == nil,
        metadata.authors.map(\.displayName) == ["Leona Quill", "Marek Stone"],
        metadata.narrators.isEmpty,
        metadata.seriesMemberships == [
          SeriesMembership(name: "Copper Meridian", position: "3.5")
        ],
        metadata.description == "A revised archival journey.",
        metadata.genres == ["Adventure", "History"],
        metadata.tags == ["restored", "night"],
        metadata.language == "fr-CA",
        metadata.publicationYear == 2024,
        metadata.publisher == "Burnt Oak Audio",
        metadata.edition == "Second edition",
        metadata.abridgement == .unabridged,
        metadata.state(for: .cover)?.provenance == .embeddedTag,
        metadata.state(for: .cover)?.lastTransactionID == nil
      else { return false }

      for field in committedMetadataEditedFields {
        guard let state = metadata.state(for: field),
          state.provenance == .user,
          state.confidence == .high,
          state.lastTransactionID == transactionID
        else { return false }
      }
      guard metadata.state(for: .subtitle)?.isExplicitlyCleared == true,
        metadata.state(for: .narrators)?.isExplicitlyCleared == true,
        metadata.state(for: .title)?.isLocked == true,
        metadata.state(for: .seriesName)?.isLocked == true,
        metadata.state(for: .genres)?.isLocked == true
      else { return false }
      return committedMetadataEditedFields.subtracting([.subtitle, .narrators]).allSatisfy {
        metadata.state(for: $0)?.isExplicitlyCleared == false
      }
    }

    private func regularFiles(in root: URL) -> [URL] {
      guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else { return [] }
      return enumerator.compactMap { $0 as? URL }.filter { url in
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      }
    }
  }

  @MainActor
  struct E2EMultifileFilesystemEvidence: Equatable {
    let stagingFileCount: Int
    let managedFileCount: Int
    let managedFileSetExact: Bool
    let managedPathsExact: Bool
    let managedPresenceExact: Bool
    let managedByteCountsExact: Bool
    let managedChecksumsExact: Bool

    var probeFields: String {
      [
        "staging-files=\(stagingFileCount)",
        "managed-files=\(managedFileCount)",
        "managed-file-set=\(managedFileSetExact ? "exact" : "mismatch")",
        "managed-paths=\(managedPathsExact ? "exact" : "mismatch")",
        "managed-presence=\(managedPresenceExact ? "exact" : "missing")",
        "managed-bytes=\(managedByteCountsExact ? "exact" : "mismatch")",
        "managed-checksums=\(managedChecksumsExact ? "exact" : "mismatch")",
      ].joined(separator: ":")
    }

    static func inspect(
      storageRootURL: URL,
      library: LibrarySnapshot,
      fileManager: FileManager = .default
    ) throws -> E2EMultifileFilesystemEvidence {
      let root = storageRootURL.standardizedFileURL
      let stagingRoot = root.appending(path: "Staging", directoryHint: .isDirectory)
      let mediaRoot = root.appending(path: "Media", directoryHint: .isDirectory)
      let staging = try inventory(beneath: stagingRoot, relativeTo: root, fileManager: fileManager)
      let managed = try inventory(beneath: mediaRoot, relativeTo: root, fileManager: fileManager)
      let managedByPath = Dictionary(grouping: managed, by: \.relativePath)

      var expectedPaths: Set<String> = []
      var pathsExact = true
      var presenceExact = true
      var byteCountsExact = true
      var checksumsExact = true
      var hasDuplicateExpectedPath = false

      for book in library.books {
        for asset in book.assets {
          let fileExtension = URL(filePath: asset.originalFilename).pathExtension.lowercased()
          guard !fileExtension.isEmpty else {
            pathsExact = false
            presenceExact = false
            byteCountsExact = false
            checksumsExact = false
            continue
          }
          let expectedPath = [
            "Media",
            book.id.uuidString.lowercased(),
            "\(asset.id.uuidString.lowercased()).\(fileExtension)",
          ].joined(separator: "/")
          if !expectedPaths.insert(expectedPath).inserted { hasDuplicateExpectedPath = true }
          if asset.managedRelativePath != expectedPath { pathsExact = false }

          guard let matches = managedByPath[expectedPath], matches.count == 1,
            let record = matches.first
          else {
            presenceExact = false
            byteCountsExact = false
            checksumsExact = false
            continue
          }
          if record.byteCount != asset.byteCount { byteCountsExact = false }
          if record.checksumSHA256.lowercased() != asset.checksumSHA256.lowercased() {
            checksumsExact = false
          }
        }
      }

      let actualPaths = Set(managed.map(\.relativePath))
      let fileSetExact = !hasDuplicateExpectedPath
        && managedByPath.values.allSatisfy { $0.count == 1 }
        && actualPaths == expectedPaths
      return E2EMultifileFilesystemEvidence(
        stagingFileCount: staging.count,
        managedFileCount: managed.count,
        managedFileSetExact: fileSetExact,
        managedPathsExact: pathsExact && !hasDuplicateExpectedPath,
        managedPresenceExact: presenceExact,
        managedByteCountsExact: byteCountsExact,
        managedChecksumsExact: checksumsExact
      )
    }

    private struct FileEvidence {
      let relativePath: String
      let byteCount: Int64
      let checksumSHA256: String
    }

    private static func inventory(
      beneath categoryRoot: URL,
      relativeTo storageRoot: URL,
      fileManager: FileManager
    ) throws -> [FileEvidence] {
      guard fileManager.fileExists(atPath: categoryRoot.path) else { return [] }
      let categoryValues = try categoryRoot.resourceValues(
        forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
      )
      guard categoryValues.isDirectory == true, categoryValues.isSymbolicLink != true else {
        throw PlayerCoreError.fileOperation("The E2E storage inventory root is unsafe.")
      }
      let rootPrefix = storageRoot.standardizedFileURL.path + "/"
      var enumerationError: Error?
      guard let enumerator = fileManager.enumerator(
        at: categoryRoot,
        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        errorHandler: { _, error in
          enumerationError = error
          return false
        }
      ) else {
        throw PlayerCoreError.fileOperation("The E2E storage inventory is unavailable.")
      }

      var evidence: [FileEvidence] = []
      for case let child as URL in enumerator {
        let values = try child.resourceValues(
          forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isSymbolicLink != true else {
          throw PlayerCoreError.fileOperation("The E2E storage inventory contains an unsafe entry.")
        }
        if values.isDirectory == true { continue }
        guard values.isRegularFile == true else {
          throw PlayerCoreError.fileOperation("The E2E storage inventory contains an unsafe entry.")
        }
        let standardized = child.standardizedFileURL
        guard standardized.path.hasPrefix(rootPrefix) else {
          throw PlayerCoreError.fileOperation("The E2E storage inventory escaped its root.")
        }
        evidence.append(FileEvidence(
          relativePath: String(standardized.path.dropFirst(rootPrefix.count)),
          byteCount: Int64(values.fileSize ?? 0),
          checksumSHA256: try checksum(of: standardized)
        ))
      }
      if enumerationError != nil {
        throw PlayerCoreError.fileOperation("The E2E storage inventory could not read every entry.")
      }
      return evidence.sorted { $0.relativePath < $1.relativePath }
    }

    private static func checksum(of url: URL) throws -> String {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      var hasher = SHA256()
      while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
        hasher.update(data: chunk)
      }
      return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
  }

  @MainActor
  final class E2EMultifileAcquisition {
    enum EntryPoint: Equatable {
      case directAdd
      case explicitFileChoice
    }

    static let shared = E2EMultifileAcquisition()

    private(set) var selectionURLs: [URL] = []
    private(set) var entryPoint = EntryPoint.directAdd
    private var sourceBytes: [String: Data] = [:]
    private var storageRootURL: URL?

    var isConfigured: Bool { !selectionURLs.isEmpty }

    func configure(
      selectionURLs: [URL],
      storageRootURL: URL,
      entryPoint: EntryPoint = .directAdd
    ) {
      self.selectionURLs = selectionURLs
      self.entryPoint = entryPoint
      self.storageRootURL = storageRootURL.standardizedFileURL
      sourceBytes = sourceFiles(in: selectionURLs).reduce(into: [:]) { result, url in
        result[url.path] = try? Data(contentsOf: url)
      }
    }

    func filesystemEvidence(
      library: LibrarySnapshot
    ) throws -> E2EMultifileFilesystemEvidence {
      guard let storageRootURL else {
        throw PlayerCoreError.fileOperation("The multifile E2E storage root is unavailable.")
      }
      return try E2EMultifileFilesystemEvidence.inspect(
        storageRootURL: storageRootURL,
        library: library
      )
    }

    var sourceIsUnchanged: Bool {
      let current = sourceFiles(in: selectionURLs)
      guard current.count == sourceBytes.count else { return false }
      return current.allSatisfy { url in
        guard let expected = sourceBytes[url.path] else { return false }
        return (try? Data(contentsOf: url)) == expected
      }
    }

    private func sourceFiles(in selectionURLs: [URL]) -> [URL] {
      var files: [URL] = []
      for url in selectionURLs {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        if isDirectory,
          let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
          )
        {
          for case let child as URL in enumerator where child.pathExtension.lowercased() == "m4a" {
            files.append(child)
          }
        } else {
          files.append(url)
        }
      }
      return files.sorted { $0.path < $1.path }
    }
  }

  @MainActor
  final class E2EZipAcquisition {
    static let shared = E2EZipAcquisition()

    private(set) var zipCase: String?
    private(set) var sourceURL: URL?
    private var sourceBytes: Data?
    private var fixtureRootURL: URL?
    private var baselineFiles: [String: String] = [:]

    var isConfigured: Bool { zipCase != nil && sourceURL != nil }

    func configure(zipCase: String, sourceURL: URL, sourceBytes: Data) throws {
      let root = sourceURL.deletingLastPathComponent().standardizedFileURL
      let sentinel = root.appending(
        path: "ContainmentSentinels/root-boundary.bin",
        directoryHint: .notDirectory
      )
      try FileManager.default.createDirectory(
        at: sentinel.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("player safe zip containment sentinel".utf8).write(to: sentinel, options: .atomic)

      self.zipCase = zipCase
      self.sourceURL = sourceURL
      self.sourceBytes = sourceBytes
      fixtureRootURL = root
      baselineFiles = try Self.regularFileInventory(beneath: root)
    }

    var sourceIsUnchanged: Bool {
      guard let sourceURL, let sourceBytes else { return false }
      return (try? Data(contentsOf: sourceURL)) == sourceBytes
    }

    func filesystemEvidence(jobID: UUID) -> E2EZipFilesystemEvidence {
      guard let fixtureRootURL,
        let currentFiles = try? Self.regularFileInventory(beneath: fixtureRootURL)
      else { return .unavailable }

      let jobRoot = "PlayerData/Staging/\(jobID.uuidString.lowercased())"
      let unexpectedAdditions = currentFiles.keys.filter { relativePath in
        baselineFiles[relativePath] == nil
          && !Self.isExpectedMutation(relativePath, jobRoot: jobRoot)
      }
      let changedOrRemovedBaselineFiles = baselineFiles.keys.filter {
        currentFiles[$0] != baselineFiles[$0]
      }
      let stagingPrefix = jobRoot + "/"
      let stagingFileCount = currentFiles.keys.filter { $0.hasPrefix(stagingPrefix) }.count
      let sentinelPath = "ContainmentSentinels/root-boundary.bin"

      return E2EZipFilesystemEvidence(
        outsideWriteCount: unexpectedAdditions.count + changedOrRemovedBaselineFiles.count,
        stagingFileCount: stagingFileCount,
        sentinelsPreserved: currentFiles[sentinelPath] == baselineFiles[sentinelPath]
      )
    }

    private static func isExpectedMutation(_ relativePath: String, jobRoot: String) -> Bool {
      if relativePath == "Library.json" || relativePath.hasPrefix("AutomaticBackups/") {
        return true
      }
      if relativePath == "\(jobRoot)/archive.zip"
        || relativePath == "\(jobRoot)/zip-checkpoint.json"
      {
        return true
      }
      return relativePath.hasPrefix("\(jobRoot)/Extracted/")
    }

    private static func regularFileInventory(beneath root: URL) throws -> [String: String] {
      guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) else {
        throw PlayerCoreError.fileOperation("The Safe ZIP E2E root could not be inventoried.")
      }
      var files: [String: String] = [:]
      let prefix = root.standardizedFileURL.path + "/"
      for case let url as URL in enumerator {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(prefix) else {
          throw PlayerCoreError.fileOperation("The Safe ZIP E2E inventory escaped its root.")
        }
        let relativePath = String(path.dropFirst(prefix.count))
        guard !relativePath.isEmpty, files[relativePath] == nil else {
          throw PlayerCoreError.fileOperation("The Safe ZIP E2E inventory is ambiguous.")
        }
        let values: URLResourceValues
        do {
          values = try url.resourceValues(forKeys: [.isRegularFileKey])
        } catch {
          // Retry cleanup removes the old extraction tree while this evidence view
          // can be walking it. A child that vanished after enumeration is absent
          // from the resulting snapshot; it does not make the whole root unreadable.
          guard FileManager.default.fileExists(atPath: path) else { continue }
          values = try url.resourceValues(forKeys: [.isRegularFileKey])
        }
        guard values.isRegularFile == true else { continue }

        let data: Data
        do {
          data = try Data(contentsOf: url)
        } catch {
          guard FileManager.default.fileExists(atPath: path) else { continue }
          data = try Data(contentsOf: url)
        }
        let digest = SHA256.hash(data: data)
          .map { String(format: "%02x", $0) }
          .joined()
        files[relativePath] = digest
      }
      return files
    }
  }

  struct E2EZipFilesystemEvidence: Equatable {
    var outsideWriteCount: Int?
    var stagingFileCount: Int?
    var sentinelsPreserved: Bool

    static let unavailable = E2EZipFilesystemEvidence(
      outsideWriteCount: nil,
      stagingFileCount: nil,
      sentinelsPreserved: false
    )
  }

  @MainActor
  final class E2EBackupBridge {
    static let shared = E2EBackupBridge()

    private var rootURL: URL?
    private var expectedLibrary: LibrarySnapshot?
    private var expectedAudio: Data?
    private var managedRelativePath: String?
    private var preparedBackup: PreparedLibraryBackup?

    var isConfigured: Bool { rootURL != nil }

    func configure(
      rootURL: URL,
      expectedLibrary: LibrarySnapshot,
      expectedAudio: Data,
      managedRelativePath: String
    ) {
      self.rootURL = rootURL
      self.expectedLibrary = expectedLibrary
      self.expectedAudio = expectedAudio
      self.managedRelativePath = managedRelativePath
      preparedBackup = nil
    }

    func export(using model: PlayerModel) async throws {
      preparedBackup = try await model.prepareLibraryBackup(kind: .includingMedia)
    }

    func clear(using model: PlayerModel) async throws {
      guard let rootURL else { return }
      let mediaRoot = rootURL.appending(path: "Media")
      if FileManager.default.fileExists(atPath: mediaRoot.path) {
        try FileManager.default.removeItem(at: mediaRoot)
      }
      try await model.replaceLibraryForBackupE2E(with: .empty)
    }

    func restore(using model: PlayerModel) async throws {
      guard let preparedBackup else {
        throw PlayerCoreError.fileOperation("The deterministic backup has not been exported.")
      }
      try await model.restoreLibraryBackup(from: preparedBackup.url)
      await model.discardPreparedLibraryBackup(preparedBackup)
      self.preparedBackup = nil
    }

    func value(for model: PlayerModel) -> String {
      guard let rootURL, let expectedLibrary, let expectedAudio, let managedRelativePath else {
        return "backup:unconfigured"
      }
      let mediaURL = rootURL.appending(path: managedRelativePath)
      let audioMatches = (try? Data(contentsOf: mediaURL)) == expectedAudio
      let mediaFiles: Int
      if let enumerator = FileManager.default.enumerator(
        at: rootURL.appending(path: "Media"),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      ) {
        mediaFiles = enumerator.compactMap { $0 as? URL }.filter {
          (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.count
      } else {
        mediaFiles = 0
      }
      let state: String
      if equivalentCatalog(model.library, expectedLibrary), audioMatches, preparedBackup != nil {
        state = "exported"
      } else if model.library == .empty, mediaFiles == 0, preparedBackup != nil {
        state = "cleared"
      } else if equivalentCatalog(model.library, expectedLibrary), audioMatches,
        preparedBackup == nil
      {
        state = "restored"
      } else {
        state = "unexpected"
      }
      return "backup:\(state):books=\(model.library.books.count):bookmarks=\(model.library.bookmarks.count):position=\(model.library.playbackPosition?.positionMilliseconds ?? -1):media=\(mediaFiles):audio=\(audioMatches)"
    }

    private func equivalentCatalog(
      _ actual: LibrarySnapshot,
      _ expected: LibrarySnapshot
    ) -> Bool {
      var actual = actual
      var expected = expected
      actual.storageManifests = []
      expected.storageManifests = []
      return actual == expected
    }
  }

  private actor E2EZipAudioInspector: AudioInspecting {
    let result: InspectedAudio
    var shouldFail: Bool

    init(result: InspectedAudio, failOnce: Bool) {
      self.result = result
      self.shouldFail = failOnce
    }

    func inspect(url: URL) async throws -> InspectedAudio {
      if shouldFail {
        shouldFail = false
        throw PlayerCoreError.fileOperation("Audio inspection was interrupted. Try again.")
      }
      return result
    }
  }

  actor E2ESeededLibraryStore: LibraryPersisting {
    let base: CodableLibraryStore
    let seed: LibrarySnapshot

    init(base: CodableLibraryStore, seed: LibrarySnapshot) {
      self.base = base
      self.seed = seed
    }

    func load() async throws -> LibrarySnapshot {
      if let existing = try await base.loadIfPresent() { return existing }
      try await base.save(seed)
      return seed
    }

    func save(_ snapshot: LibrarySnapshot) async throws {
      try await base.save(snapshot)
    }
  }

  private struct E2EOfflineRecoveryEnvelope: Codable {
    var schemaVersion: Int
    var library: LibrarySnapshot
  }
#endif
