import Foundation

enum MetadataField: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case cover
  case title
  case sortTitle
  case subtitle
  case authors
  case narrators
  case seriesName
  case seriesPosition
  case description
  case genres
  case tags
  case language
  case publicationYear
  case publisher
  case edition
  case abridgement
}

enum MetadataProvenance: String, Codable, Equatable, Sendable {
  case embeddedTag
  case filename
  case folderName
  case fileOrder
  case legacyLibrary
  case user
}

enum MetadataConfidence: String, Codable, Equatable, Sendable {
  case low
  case medium
  case high
}

struct MetadataFieldState: Codable, Equatable, Sendable {
  var provenance: MetadataProvenance
  var confidence: MetadataConfidence
  var isLocked: Bool
  var isExplicitlyCleared: Bool
  var lastTransactionID: UUID?

  static func imported(
    provenance: MetadataProvenance,
    confidence: MetadataConfidence = .high
  ) -> MetadataFieldState {
    MetadataFieldState(
      provenance: provenance,
      confidence: confidence,
      isLocked: false,
      isExplicitlyCleared: false,
      lastTransactionID: nil
    )
  }
}

enum ContributorRole: String, Codable, Equatable, Sendable {
  case author
  case narrator
}

struct Contributor: Codable, Equatable, Hashable, Identifiable, Sendable {
  let id: String
  var displayName: String
  var sortName: String?

  init(id: String? = nil, displayName: String, sortName: String? = nil) {
    let normalizedName = Self.normalizedDisplayName(displayName)
    self.id = id ?? Self.stableID(for: normalizedName)
    self.displayName = normalizedName
    self.sortName = sortName?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
  }

  private static func normalizedDisplayName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func stableID(for value: String) -> String {
    let folded = value.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    return folded.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }
}

struct ContributorCredit: Codable, Equatable, Hashable, Identifiable, Sendable {
  var contributor: Contributor
  var role: ContributorRole
  var order: Int

  var id: String { "\(role.rawValue):\(contributor.id)" }
}

struct SeriesMembership: Codable, Equatable, Hashable, Identifiable, Sendable {
  let seriesID: String
  var name: String
  var position: String?

  var id: String { seriesID }

  init(seriesID: String? = nil, name: String, position: String? = nil) {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    self.seriesID = seriesID ?? normalizedName.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ).lowercased()
    self.name = normalizedName
    self.position = position?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
  }
}

enum AbridgementStatus: String, Codable, Equatable, Sendable {
  case abridged
  case unabridged
  case unknown
}

enum CoverSource: String, Codable, Equatable, Sendable {
  case embedded
  case photoLibrary
  case file
  case userCrop
}

/// Unit-space crop coordinates retain the original image bytes so repeated crops
/// never compound image loss. Rendering is intentionally an adapter/UI concern.
struct CoverCrop: Codable, Equatable, Sendable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var rotationDegrees: Double

  init(
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    rotationDegrees: Double = 0
  ) {
    self.x = min(max(x, 0), 1)
    self.y = min(max(y, 0), 1)
    self.width = min(max(width, 0), 1 - self.x)
    self.height = min(max(height, 0), 1 - self.y)
    self.rotationDegrees = rotationDegrees.truncatingRemainder(dividingBy: 360)
  }
}

struct CoverArtwork: Codable, Equatable, Sendable {
  var originalData: Data
  var mediaType: String
  var source: CoverSource
  var crop: CoverCrop?

  init(
    originalData: Data,
    mediaType: String,
    source: CoverSource,
    crop: CoverCrop? = nil
  ) {
    self.originalData = originalData
    self.mediaType = mediaType
    self.source = source
    self.crop = crop
  }
}

enum MetadataFieldValue: Codable, Equatable, Sendable {
  case text(String)
  case textList([String])
  case contributors([Contributor])
  case seriesMemberships([SeriesMembership])
  case publicationYear(Int)
  case abridgement(AbridgementStatus)
  case cover(CoverArtwork)
}

struct MetadataMutation: Codable, Equatable, Sendable {
  enum Operation: String, Codable, Equatable, Sendable {
    case set
    case clear
    case setLocked
  }

  var field: MetadataField
  var operation: Operation
  var value: MetadataFieldValue?
  var provenance: MetadataProvenance
  var confidence: MetadataConfidence
  var locked: Bool

  static func set(
    _ field: MetadataField,
    value: MetadataFieldValue,
    provenance: MetadataProvenance = .user,
    confidence: MetadataConfidence = .high,
    lock: Bool = true
  ) -> MetadataMutation {
    MetadataMutation(
      field: field,
      operation: .set,
      value: value,
      provenance: provenance,
      confidence: confidence,
      locked: lock
    )
  }

  static func clear(_ field: MetadataField, lock: Bool = true) -> MetadataMutation {
    MetadataMutation(
      field: field,
      operation: .clear,
      value: nil,
      provenance: .user,
      confidence: .high,
      locked: lock
    )
  }

  static func setLocked(_ field: MetadataField, locked: Bool) -> MetadataMutation {
    MetadataMutation(
      field: field,
      operation: .setLocked,
      value: nil,
      provenance: .user,
      confidence: .high,
      locked: locked
    )
  }
}

struct AudiobookMetadata: Codable, Equatable, Sendable {
  var title: String
  var sortTitle: String?
  var subtitle: String?
  var contributors: [ContributorCredit]
  var seriesMemberships: [SeriesMembership]
  var description: String?
  var genres: [String]
  var tags: [String]
  var language: String?
  var publicationYear: Int?
  var publisher: String?
  var edition: String?
  var abridgement: AbridgementStatus?
  var cover: CoverArtwork?
  private(set) var fieldStates: [MetadataField: MetadataFieldState]

  var authors: [Contributor] {
    contributors.filter { $0.role == .author }.sorted { $0.order < $1.order }.map(\.contributor)
  }

  var narrators: [Contributor] {
    contributors.filter { $0.role == .narrator }.sorted { $0.order < $1.order }.map(\.contributor)
  }

  init(
    title: String,
    sortTitle: String? = nil,
    subtitle: String? = nil,
    authors: [Contributor] = [],
    narrators: [Contributor] = [],
    seriesMemberships: [SeriesMembership] = [],
    description: String? = nil,
    genres: [String] = [],
    tags: [String] = [],
    language: String? = nil,
    publicationYear: Int? = nil,
    publisher: String? = nil,
    edition: String? = nil,
    abridgement: AbridgementStatus? = nil,
    cover: CoverArtwork? = nil,
    fieldStates: [MetadataField: MetadataFieldState] = [:]
  ) {
    self.title = title
    self.sortTitle = sortTitle
    self.subtitle = subtitle
    contributors = authors.enumerated().map {
      ContributorCredit(contributor: $0.element, role: .author, order: $0.offset)
    } + narrators.enumerated().map {
      ContributorCredit(contributor: $0.element, role: .narrator, order: $0.offset)
    }
    self.seriesMemberships = seriesMemberships
    self.description = description
    self.genres = genres
    self.tags = tags
    self.language = language
    self.publicationYear = publicationYear
    self.publisher = publisher
    self.edition = edition
    self.abridgement = abridgement
    self.cover = cover
    self.fieldStates = fieldStates
  }

  static func imported(
    title: String,
    authors: [String],
    narrators: [String],
    seriesName: String?,
    seriesPosition: String?,
    artworkData: Data?,
    artworkMediaType: String?,
    provenance: MetadataProvenance = .embeddedTag,
    confidence: MetadataConfidence = .high
  ) -> AudiobookMetadata {
    var metadata = AudiobookMetadata(
      title: title,
      authors: authors.map { Contributor(displayName: $0) },
      narrators: narrators.map { Contributor(displayName: $0) },
      seriesMemberships: seriesName.map {
        [SeriesMembership(name: $0, position: seriesPosition)]
      } ?? [],
      cover: artworkData.map {
        CoverArtwork(
          originalData: $0,
          mediaType: artworkMediaType ?? "application/octet-stream",
          source: .embedded
        )
      }
    )
    let state = MetadataFieldState.imported(provenance: provenance, confidence: confidence)
    metadata.fieldStates[.title] = state
    if !authors.isEmpty { metadata.fieldStates[.authors] = state }
    if !narrators.isEmpty { metadata.fieldStates[.narrators] = state }
    if seriesName != nil {
      metadata.fieldStates[.seriesName] = state
      if seriesPosition != nil { metadata.fieldStates[.seriesPosition] = state }
    }
    if artworkData != nil { metadata.fieldStates[.cover] = state }
    return metadata
  }

  func state(for field: MetadataField) -> MetadataFieldState? {
    fieldStates[field]
  }

  func value(for field: MetadataField) -> MetadataFieldValue? {
    switch field {
    case .cover: cover.map(MetadataFieldValue.cover)
    case .title: .text(title)
    case .sortTitle: sortTitle.map(MetadataFieldValue.text)
    case .subtitle: subtitle.map(MetadataFieldValue.text)
    case .authors: .contributors(authors)
    case .narrators: .contributors(narrators)
    case .seriesName: seriesMemberships.first.map { .text($0.name) }
    case .seriesPosition: seriesMemberships.first?.position.map(MetadataFieldValue.text)
    case .description: description.map(MetadataFieldValue.text)
    case .genres: .textList(genres)
    case .tags: .textList(tags)
    case .language: language.map(MetadataFieldValue.text)
    case .publicationYear: publicationYear.map(MetadataFieldValue.publicationYear)
    case .publisher: publisher.map(MetadataFieldValue.text)
    case .edition: edition.map(MetadataFieldValue.text)
    case .abridgement: abridgement.map(MetadataFieldValue.abridgement)
    }
  }

  func displayText(for field: MetadataField) -> String? {
    switch value(for: field) {
    case .text(let value): value
    case .textList(let values): values.joined(separator: ", ").nonEmpty
    case .contributors(let values): values.map(\.displayName).joined(separator: ", ").nonEmpty
    case .seriesMemberships(let values): values.map(\.name).joined(separator: ", ").nonEmpty
    case .publicationYear(let value): String(value)
    case .abridgement(let value): value.rawValue
    case .cover: "Cover selected"
    case nil: nil
    }
  }

  mutating func apply(_ mutation: MetadataMutation, transactionID: UUID) throws {
    switch mutation.operation {
    case .set:
      guard let value = mutation.value else { throw MetadataRepairError.valueRequired(mutation.field) }
      if fieldStates[mutation.field]?.isLocked == true,
        mutation.provenance != .user
      {
        throw MetadataRepairError.fieldLocked(mutation.field)
      }
      try set(mutation.field, to: value)
      fieldStates[mutation.field] = MetadataFieldState(
        provenance: mutation.provenance,
        confidence: mutation.confidence,
        isLocked: mutation.locked,
        isExplicitlyCleared: false,
        lastTransactionID: transactionID
      )
    case .clear:
      clear(mutation.field)
      fieldStates[mutation.field] = MetadataFieldState(
        provenance: .user,
        confidence: .high,
        isLocked: mutation.locked,
        isExplicitlyCleared: true,
        lastTransactionID: transactionID
      )
    case .setLocked:
      var state = fieldStates[mutation.field] ?? MetadataFieldState(
        provenance: .legacyLibrary,
        confidence: .medium,
        isLocked: false,
        isExplicitlyCleared: false,
        lastTransactionID: nil
      )
      state.isLocked = mutation.locked
      state.lastTransactionID = transactionID
      fieldStates[mutation.field] = state
    }
  }

  private mutating func set(_ field: MetadataField, to value: MetadataFieldValue) throws {
    switch (field, value) {
    case (.title, .text(let value)): title = normalized(value)
    case (.sortTitle, .text(let value)): sortTitle = normalized(value).nonEmpty
    case (.subtitle, .text(let value)): subtitle = normalized(value).nonEmpty
    case (.description, .text(let value)): description = normalized(value).nonEmpty
    case (.language, .text(let value)): language = normalized(value).nonEmpty
    case (.publisher, .text(let value)): publisher = normalized(value).nonEmpty
    case (.edition, .text(let value)): edition = normalized(value).nonEmpty
    case (.genres, .textList(let values)): genres = uniqueNormalized(values)
    case (.tags, .textList(let values)): tags = uniqueNormalized(values)
    case (.authors, .contributors(let values)): replaceContributors(values, role: .author)
    case (.narrators, .contributors(let values)): replaceContributors(values, role: .narrator)
    case (.seriesName, .text(let value)):
      let name = normalized(value)
      let position = seriesMemberships.first?.position
      seriesMemberships = name.isEmpty ? [] : [SeriesMembership(name: name, position: position)]
    case (.seriesPosition, .text(let value)):
      guard !seriesMemberships.isEmpty else { throw MetadataRepairError.seriesRequired }
      seriesMemberships[0].position = normalized(value).nonEmpty
    case (.seriesName, .seriesMemberships(let values)):
      seriesMemberships = values.filter { !$0.name.isEmpty }
    case (.publicationYear, .publicationYear(let year)):
      guard (0...9999).contains(year) else { throw MetadataRepairError.invalidPublicationYear(year) }
      publicationYear = year
    case (.abridgement, .abridgement(let value)): abridgement = value
    case (.cover, .cover(let value)):
      guard !value.originalData.isEmpty else { throw MetadataRepairError.emptyCover }
      cover = value
    default: throw MetadataRepairError.typeMismatch(field)
    }
  }

  private mutating func clear(_ field: MetadataField) {
    switch field {
    case .cover: cover = nil
    case .title: title = ""
    case .sortTitle: sortTitle = nil
    case .subtitle: subtitle = nil
    case .authors: replaceContributors([], role: .author)
    case .narrators: replaceContributors([], role: .narrator)
    case .seriesName: seriesMemberships = []
    case .seriesPosition:
      if !seriesMemberships.isEmpty { seriesMemberships[0].position = nil }
    case .description: description = nil
    case .genres: genres = []
    case .tags: tags = []
    case .language: language = nil
    case .publicationYear: publicationYear = nil
    case .publisher: publisher = nil
    case .edition: edition = nil
    case .abridgement: abridgement = nil
    }
  }

  private mutating func replaceContributors(_ values: [Contributor], role: ContributorRole) {
    let retained = contributors.filter { $0.role != role }
    let unique = values.reduce(into: [Contributor]()) { result, contributor in
      guard !contributor.displayName.isEmpty, !result.contains(where: { $0.id == contributor.id })
      else { return }
      result.append(contributor)
    }
    contributors = retained + unique.enumerated().map {
      ContributorCredit(contributor: $0.element, role: role, order: $0.offset)
    }
  }

  private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func uniqueNormalized(_ values: [String]) -> [String] {
    values.reduce(into: [String]()) { result, value in
      let candidate = normalized(value)
      guard !candidate.isEmpty,
        !result.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame })
      else { return }
      result.append(candidate)
    }
  }
}

enum MetadataTarget: Codable, Equatable, Hashable, Sendable {
  case book(UUID)
  case proposal(jobID: UUID, proposalID: UUID)
}

enum MetadataTransactionStatus: String, Codable, Equatable, Sendable {
  case applied
  case undone
}

struct MetadataTransaction: Codable, Equatable, Identifiable, Sendable {
  let id: UUID
  var target: MetadataTarget
  var before: AudiobookMetadata
  var after: AudiobookMetadata
  var mutations: [MetadataMutation]
  var createdAt: Date
  var status: MetadataTransactionStatus
  var undoneAt: Date?
}

enum MetadataRepairError: LocalizedError, Equatable, Sendable {
  case valueRequired(MetadataField)
  case typeMismatch(MetadataField)
  case invalidPublicationYear(Int)
  case seriesRequired
  case emptyCover
  case fieldLocked(MetadataField)
  case transactionNotApplied(UUID)

  var errorDescription: String? {
    switch self {
    case .valueRequired(let field): "A value is required for \(field.rawValue)."
    case .typeMismatch(let field): "The value does not match \(field.rawValue)."
    case .invalidPublicationYear(let year): "\(year) is not a valid publication year."
    case .seriesRequired: "Add a series before setting its position."
    case .emptyCover: "The selected cover contains no image data."
    case .fieldLocked(let field): "Unlock \(field.rawValue) before refreshing it."
    case .transactionNotApplied(let id): "Metadata transaction \(id.uuidString) cannot be undone."
    }
  }
}

extension Book {
  mutating func replaceMetadata(with value: AudiobookMetadata) {
    metadata = value
    title = value.title
    authors = value.authors.map(\.displayName)
    narrators = value.narrators.map(\.displayName)
    seriesName = value.seriesMemberships.first?.name
    seriesPosition = value.seriesMemberships.first?.position
    artworkData = value.cover?.originalData
    artworkMediaType = value.cover?.mediaType
  }
}

extension BookProposal {
  mutating func replaceMetadata(with value: AudiobookMetadata) {
    metadata = value
    title = value.title
    authors = value.authors.map(\.displayName)
    narrators = value.narrators.map(\.displayName)
    seriesName = value.seriesMemberships.first?.name
    seriesPosition = value.seriesMemberships.first?.position
    artworkData = value.cover?.originalData
    artworkMediaType = value.cover?.mediaType
  }
}

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
