import Foundation
import UIKit

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

/// The original bytes and crop metadata are authoritative. Every presentation
/// surface asks this renderer for a projection, so edits never crop an already
/// cropped bitmap and legacy covers without crop metadata keep their exact
/// original bytes.
enum CoverArtworkRenderer {
  static func renderedData(for artwork: CoverArtwork?) -> Data? {
    guard let artwork else { return nil }
    guard let crop = validatedCrop(artwork.crop) else { return artwork.originalData }
    guard let source = UIImage(data: artwork.originalData), source.size.width > 0,
      source.size.height > 0
    else { return artwork.originalData }

    let normalized = normalizedImage(source)
    let rotated = rotatedImage(normalized, degrees: crop.rotationDegrees)
    guard let image = croppedImage(rotated, crop: crop), let data = image.pngData() else {
      return artwork.originalData
    }
    return data
  }

  private static func validatedCrop(_ crop: CoverCrop?) -> CoverCrop? {
    guard let crop, crop.x.isFinite, crop.y.isFinite, crop.width.isFinite,
      crop.height.isFinite, crop.rotationDegrees.isFinite,
      crop.width > 0, crop.height > 0
    else { return nil }
    let validated = CoverCrop(
      x: crop.x,
      y: crop.y,
      width: crop.width,
      height: crop.height,
      rotationDegrees: crop.rotationDegrees
    )
    guard validated.width > 0, validated.height > 0 else { return nil }
    let isFullFrame = validated.x == 0 && validated.y == 0
      && validated.width == 1 && validated.height == 1
      && validated.rotationDegrees == 0
    return isFullFrame ? nil : validated
  }

  private static func normalizedImage(_ image: UIImage) -> UIImage {
    guard image.imageOrientation != .up || image.scale != 1 else { return image }
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }

  private static func rotatedImage(_ image: UIImage, degrees: Double) -> UIImage {
    let normalizedDegrees = degrees.truncatingRemainder(dividingBy: 360)
    guard abs(normalizedDegrees) > .ulpOfOne else { return image }
    let radians = CGFloat(normalizedDegrees * .pi / 180)
    let sourceRect = CGRect(origin: .zero, size: image.size)
    let rotatedRect = sourceRect.applying(CGAffineTransform(rotationAngle: radians))
    let outputSize = CGSize(
      width: max(1, abs(rotatedRect.width).rounded(.up)),
      height: max(1, abs(rotatedRect.height).rounded(.up))
    )
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = false
    return UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
      context.cgContext.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
      context.cgContext.rotate(by: radians)
      image.draw(in: CGRect(
        x: -image.size.width / 2,
        y: -image.size.height / 2,
        width: image.size.width,
        height: image.size.height
      ))
    }
  }

  private static func croppedImage(_ image: UIImage, crop: CoverCrop) -> UIImage? {
    guard let source = image.cgImage else { return nil }
    let pixelWidth = CGFloat(source.width)
    let pixelHeight = CGFloat(source.height)
    let requested = CGRect(
      x: CGFloat(crop.x) * pixelWidth,
      y: CGFloat(crop.y) * pixelHeight,
      width: CGFloat(crop.width) * pixelWidth,
      height: CGFloat(crop.height) * pixelHeight
    ).integral.intersection(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    guard requested.width >= 1, requested.height >= 1,
      let cropped = source.cropping(to: requested)
    else { return nil }
    return UIImage(cgImage: cropped, scale: 1, orientation: .up)
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

/// A UI-independent snapshot of every editable metadata value. Keeping this
/// draft and its validation in Core makes Save a single, deterministic plan
/// rather than a collection of view callbacks.
struct MetadataEditDraft: Equatable, Sendable {
  var title: String
  var sortTitle: String
  var subtitle: String
  var authors: String
  var narrators: String
  var seriesName: String
  var seriesPosition: String
  var description: String
  var genres: String
  var tags: String
  var language: String
  var publicationYear: String
  var publisher: String
  var edition: String
  var abridgement: String
  var cover: CoverArtwork?

  static let empty = MetadataEditDraft(metadata: AudiobookMetadata(title: ""))

  init(metadata: AudiobookMetadata) {
    title = metadata.title
    sortTitle = metadata.sortTitle ?? ""
    subtitle = metadata.subtitle ?? ""
    authors = MetadataDelimitedText.serialize(metadata.authors.map(\.displayName))
    narrators = MetadataDelimitedText.serialize(metadata.narrators.map(\.displayName))
    seriesName = metadata.seriesMemberships.first?.name ?? ""
    seriesPosition = metadata.seriesMemberships.first?.position ?? ""
    description = metadata.description ?? ""
    genres = MetadataDelimitedText.serialize(metadata.genres)
    tags = MetadataDelimitedText.serialize(metadata.tags)
    language = metadata.language ?? ""
    publicationYear = metadata.publicationYear.map(String.init) ?? ""
    publisher = metadata.publisher ?? ""
    edition = metadata.edition ?? ""
    abridgement = metadata.abridgement?.rawValue ?? ""
    cover = metadata.cover
  }

  func displayValue(for field: MetadataField) -> String {
    switch field {
    case .cover: cover == nil ? "" : "cover"
    case .title: title
    case .sortTitle: sortTitle
    case .subtitle: subtitle
    case .authors: authors
    case .narrators: narrators
    case .seriesName: seriesName
    case .seriesPosition: seriesPosition
    case .description: description
    case .genres: genres
    case .tags: tags
    case .language: language
    case .publicationYear: publicationYear
    case .publisher: publisher
    case .edition: edition
    case .abridgement: abridgement
    }
  }
}

private enum MetadataDelimitedText {
  static func serialize(_ values: [String]) -> String {
    values.map { value in
      let requiresQuotes = value.contains(where: { character in
        character == "," || character == ";" || character == "\n" || character == "\""
      }) || value != value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard requiresQuotes else { return value }
      return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }.joined(separator: ", ")
  }
}

struct MetadataEditPlan: Equatable, Sendable {
  var mutations: [MetadataMutation]
  var explicitlyClearedFields: Set<MetadataField>
}

enum MetadataEditPlanner {
  static func plan(
    initial: AudiobookMetadata,
    draft: MetadataEditDraft,
    explicitClears: Set<MetadataField> = [],
    lockOverrides: [MetadataField: Bool] = [:]
  ) throws -> MetadataEditPlan {
    let original = MetadataEditDraft(metadata: initial)
    let title = normalized(draft.title)
    guard !title.isEmpty else { throw MetadataRepairError.titleRequired }

    var mutations: [MetadataMutation] = []
    var plannedClears = Set(MetadataField.allCases.filter {
      initial.state(for: $0)?.isExplicitlyCleared == true
    })
    plannedClears.formUnion(explicitClears)
    func locked(_ field: MetadataField) -> Bool {
      lockOverrides[field] ?? initial.state(for: field)?.isLocked ?? false
    }
    func appendText(_ field: MetadataField, _ before: String, _ after: String) {
      guard before != after || explicitClears.contains(field) else { return }
      let value = normalized(after)
      if value.isEmpty {
        plannedClears.insert(field)
        mutations.append(.clear(field, lock: locked(field)))
      } else {
        plannedClears.remove(field)
        mutations.append(.set(field, value: .text(value), lock: locked(field)))
      }
    }
    func appendList(_ field: MetadataField, _ before: String, _ after: String) throws {
      guard before != after || explicitClears.contains(field) else { return }
      let values = try parsedDelimitedValues(after, field: field)
      if values.isEmpty {
        plannedClears.insert(field)
        mutations.append(.clear(field, lock: locked(field)))
      } else {
        plannedClears.remove(field)
        mutations.append(.set(field, value: .textList(values), lock: locked(field)))
      }
    }
    func appendContributors(
      _ field: MetadataField,
      _ before: String,
      _ after: String,
      existing: [Contributor]
    ) throws {
      guard before != after || explicitClears.contains(field) else { return }
      let contributors = try parsedContributors(after, field: field, preserving: existing)
      if contributors.isEmpty {
        plannedClears.insert(field)
        mutations.append(.clear(field, lock: locked(field)))
      } else {
        plannedClears.remove(field)
        mutations.append(.set(field, value: .contributors(contributors), lock: locked(field)))
      }
    }

    appendText(.title, original.title, draft.title)
    appendText(.sortTitle, original.sortTitle, draft.sortTitle)
    appendText(.subtitle, original.subtitle, draft.subtitle)
    try appendContributors(.authors, original.authors, draft.authors, existing: initial.authors)
    try appendContributors(.narrators, original.narrators, draft.narrators, existing: initial.narrators)

    let seriesName = normalized(draft.seriesName)
    let seriesPosition = normalized(draft.seriesPosition)
    if seriesName.isEmpty {
      guard seriesPosition.isEmpty else { throw MetadataRepairError.seriesRequired }
      if !normalized(original.seriesPosition).isEmpty || explicitClears.contains(.seriesPosition) {
        plannedClears.insert(.seriesPosition)
        mutations.append(.clear(.seriesPosition, lock: locked(.seriesPosition)))
      }
      if !normalized(original.seriesName).isEmpty || explicitClears.contains(.seriesName) {
        plannedClears.insert(.seriesName)
        mutations.append(.clear(.seriesName, lock: locked(.seriesName)))
      }
    } else {
      appendText(.seriesName, original.seriesName, draft.seriesName)
      appendText(.seriesPosition, original.seriesPosition, draft.seriesPosition)
    }

    appendText(.description, original.description, draft.description)
    try appendList(.genres, original.genres, draft.genres)
    try appendList(.tags, original.tags, draft.tags)
    appendText(.language, original.language, draft.language)
    if original.publicationYear != draft.publicationYear || explicitClears.contains(.publicationYear) {
      let yearText = normalized(draft.publicationYear)
      if yearText.isEmpty {
        plannedClears.insert(.publicationYear)
        mutations.append(.clear(.publicationYear, lock: locked(.publicationYear)))
      } else {
        guard let year = Int(yearText), (1...9999).contains(year) else {
          throw MetadataRepairError.invalidPublicationYearText(yearText)
        }
        plannedClears.remove(.publicationYear)
        mutations.append(.set(
          .publicationYear,
          value: .publicationYear(year),
          lock: locked(.publicationYear)
        ))
      }
    }
    appendText(.publisher, original.publisher, draft.publisher)
    appendText(.edition, original.edition, draft.edition)
    if original.abridgement != draft.abridgement || explicitClears.contains(.abridgement) {
      if normalized(draft.abridgement).isEmpty {
        plannedClears.insert(.abridgement)
        mutations.append(.clear(.abridgement, lock: locked(.abridgement)))
      } else if let value = AbridgementStatus(rawValue: draft.abridgement) {
        plannedClears.remove(.abridgement)
        mutations.append(.set(.abridgement, value: .abridgement(value), lock: locked(.abridgement)))
      } else {
        throw MetadataRepairError.typeMismatch(.abridgement)
      }
    }
    if original.cover != draft.cover || explicitClears.contains(.cover) {
      if let cover = draft.cover {
        plannedClears.remove(.cover)
        mutations.append(.set(.cover, value: .cover(cover), lock: locked(.cover)))
      } else {
        plannedClears.insert(.cover)
        mutations.append(.clear(.cover, lock: locked(.cover)))
      }
    }

    for field in MetadataField.allCases where lockOverrides[field] != nil
      && !mutations.contains(where: { $0.field == field })
    {
      mutations.append(.setLocked(field, locked: locked(field)))
    }
    return MetadataEditPlan(mutations: mutations, explicitlyClearedFields: plannedClears)
  }

  static func validationError(
    initial: AudiobookMetadata,
    draft: MetadataEditDraft,
    explicitClears: Set<MetadataField> = [],
    lockOverrides: [MetadataField: Bool] = [:]
  ) -> MetadataRepairError? {
    do {
      _ = try plan(
        initial: initial,
        draft: draft,
        explicitClears: explicitClears,
        lockOverrides: lockOverrides
      )
      return nil
    } catch let error as MetadataRepairError {
      return error
    } catch {
      return .typeMismatch(.title)
    }
  }

  /// CSV-style parsing: comma, semicolon, and newline delimit unquoted values;
  /// quotes retain delimiters and doubled quotes represent a literal quote.
  /// Rejecting malformed quotes prevents a contributor name from being
  /// silently split into a different person.
  private static func parsedDelimitedValues(
    _ value: String,
    field: MetadataField
  ) throws -> [String] {
    let characters = Array(value)
    var values: [String] = []
    var current = ""
    var inQuotes = false
    var closedQuote = false
    var index = 0

    func appendCurrent() {
      let candidate = normalized(current)
      if !candidate.isEmpty { values.append(candidate) }
      current = ""
      closedQuote = false
    }

    while index < characters.count {
      let character = characters[index]
      if inQuotes {
        if character == "\"" {
          if index + 1 < characters.count, characters[index + 1] == "\"" {
            current.append("\"")
            index += 1
          } else {
            inQuotes = false
            closedQuote = true
          }
        } else {
          current.append(character)
        }
      } else if character == "," || character == ";" || character == "\n" {
        appendCurrent()
      } else if character == "\"" {
        guard normalized(current).isEmpty, !closedQuote else {
          throw MetadataRepairError.malformedDelimitedValue(field)
        }
        current = ""
        inQuotes = true
      } else {
        if closedQuote, !character.isWhitespace {
          throw MetadataRepairError.malformedDelimitedValue(field)
        }
        current.append(character)
      }
      index += 1
    }
    guard !inQuotes else { throw MetadataRepairError.malformedDelimitedValue(field) }
    appendCurrent()
    return values
  }

  private static func parsedContributors(
    _ value: String,
    field: MetadataField,
    preserving existing: [Contributor]
  ) throws -> [Contributor] {
    let byName = Dictionary(existing.map { (normalizedKey($0.displayName), $0) },
      uniquingKeysWith: { first, _ in first })
    return try parsedDelimitedValues(value, field: field).map { name in
      byName[normalizedKey(name)] ?? Contributor(displayName: name)
    }
  }

  private static func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func normalizedKey(_ value: String) -> String {
    normalized(value).folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    ).lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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

  func validateForCommit() throws {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw MetadataRepairError.titleRequired
    }
    if let publicationYear, !(1...9999).contains(publicationYear) {
      throw MetadataRepairError.invalidPublicationYear(publicationYear)
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
      try clear(mutation.field)
      fieldStates[mutation.field] = MetadataFieldState(
        provenance: .user,
        confidence: .high,
        isLocked: mutation.locked,
        isExplicitlyCleared: true,
        lastTransactionID: transactionID
      )
      if mutation.field == .seriesName {
        fieldStates[.seriesPosition] = MetadataFieldState(
          provenance: .user,
          confidence: .high,
          isLocked: fieldStates[.seriesPosition]?.isLocked ?? mutation.locked,
          isExplicitlyCleared: true,
          lastTransactionID: transactionID
        )
      }
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
    case (.title, .text(let value)):
      let title = normalized(value)
      guard !title.isEmpty else { throw MetadataRepairError.titleRequired }
      self.title = title
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
      guard (1...9999).contains(year) else { throw MetadataRepairError.invalidPublicationYear(year) }
      publicationYear = year
    case (.abridgement, .abridgement(let value)): abridgement = value
    case (.cover, .cover(let value)):
      guard !value.originalData.isEmpty else { throw MetadataRepairError.emptyCover }
      cover = value
    default: throw MetadataRepairError.typeMismatch(field)
    }
  }

  private mutating func clear(_ field: MetadataField) throws {
    switch field {
    case .cover: cover = nil
    case .title: throw MetadataRepairError.titleRequired
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

extension LibrarySnapshot {
  func metadataRevision(for target: MetadataTarget) -> String {
    let revisions = metadataTransactions.filter { $0.target == target }.map {
      "\($0.id.uuidString.lowercased()):\($0.status.rawValue)"
    }
    return revisions.isEmpty ? "0" : revisions.joined(separator: ",")
  }
}

enum MetadataRepairError: LocalizedError, Equatable, Sendable {
  case valueRequired(MetadataField)
  case typeMismatch(MetadataField)
  case invalidPublicationYear(Int)
  case invalidPublicationYearText(String)
  case titleRequired
  case transactionInProgress
  case malformedDelimitedValue(MetadataField)
  case seriesRequired
  case emptyCover
  case fieldLocked(MetadataField)
  case transactionNotApplied(UUID)

  var errorDescription: String? {
    switch self {
    case .valueRequired(let field): "A value is required for \(field.rawValue)."
    case .typeMismatch(let field): "The value does not match \(field.rawValue)."
    case .invalidPublicationYear(let year): "\(year) is not a valid publication year."
    case .invalidPublicationYearText(let value):
      "\(value.isEmpty ? "The publication year" : value) is not a valid publication year."
    case .titleRequired: "An audiobook title is required."
    case .transactionInProgress: "These audiobook details are already being saved."
    case .malformedDelimitedValue(let field):
      "Check the quotes in \(field.rawValue). Use doubled quotes inside a quoted value."
    case .seriesRequired: "Add a series before setting its position."
    case .emptyCover: "The selected cover contains no image data."
    case .fieldLocked(let field): "Unlock \(field.rawValue) before refreshing it."
    case .transactionNotApplied(let id): "Metadata transaction \(id.uuidString) cannot be undone."
    }
  }
}

extension Book {
  var renderedArtworkData: Data? {
    CoverArtworkRenderer.renderedData(for: metadata.cover)
      ?? artworkData
  }

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
  var renderedArtworkData: Data? {
    CoverArtworkRenderer.renderedData(for: metadata.cover)
      ?? artworkData
  }

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
