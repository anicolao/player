import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MetadataEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel
  let target: MetadataTarget

  @State private var initial = MetadataEditorDraft.empty
  @State private var draft = MetadataEditorDraft.empty
  @State private var loaded = false
  @State private var touchedFields: Set<MetadataField> = []
  @State private var explicitlyCleared: Set<MetadataField> = []
  @State private var coverWasRemoved = false
  @State private var lockOverrides: [MetadataField: Bool] = [:]
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var isChoosingCoverFile = false
  @State private var isChoosingCoverSource = false
  @State private var isCroppingCover = false
  @State private var cropZoom = 1.0
  @State private var cropX = 0.5
  @State private var cropY = 0.5
  @State private var errorMessage: String?

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 20) {
            coverEditor
            identityFields
              .id("metadata-identity")
            contributorFields
            seriesFields
            descriptiveFields
            publicationFields
            lockSummary
          }
          .padding(20)
        }
        #if E2E
          .overlay(alignment: .topLeading) {
            Button {
              proxy.scrollTo("metadata-identity", anchor: .top)
            } label: {
              Color.white.opacity(0.001)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Align Metadata identity fields")
            .accessibilityIdentifier("e2e-align-metadata-identity")
          }
        #endif
      }
    }
    .navigationTitle("Edit Details")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(!isDirty || draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("save-metadata-repair")
      }
    }
    .alert("Couldn’t save details", isPresented: Binding(
      get: { errorMessage != nil },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("OK", role: .cancel) { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "Try again.")
    }
    .confirmationDialog("Change Cover", isPresented: $isChoosingCoverSource) {
      PhotosPicker(selection: $selectedPhoto, matching: .images) {
        Text("Choose Photo")
      }
      Button("Choose File") { isChoosingCoverFile = true }
      if draft.cover != nil { Button("Crop") { isCroppingCover = true } }
      Button("Remove", role: .destructive) { removeCover() }
    }
    .fileImporter(
      isPresented: $isChoosingCoverFile,
      allowedContentTypes: [.image],
      allowsMultipleSelection: false
    ) { result in
      guard case .success(let urls) = result, let url = urls.first else { return }
      replaceCover(from: url)
    }
    .sheet(isPresented: $isCroppingCover) { cropSheet }
    .task(id: selectedPhoto) {
      guard let selectedPhoto else { return }
      do {
        guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else { return }
        setCover(data: data, mediaType: imageMediaType(data), source: .photoLibrary)
      } catch {
        errorMessage = "The selected photo could not be read."
      }
    }
    .onAppear { loadIfNeeded() }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("metadata-editor-screen")
    .accessibilityValue(screenAccessibilityValue)
  }

  private var coverEditor: some View {
    VStack(spacing: 14) {
      adaptiveCoverLayout {
        ArtworkView(data: draft.cover?.originalData, size: 126, isEssential: true)
        VStack(alignment: .leading, spacing: 10) {
          Text("Cover").font(.headline)
          Text(fieldSource(.cover))
            .font(.caption)
            .foregroundStyle(PlayerColor.secondary)
          Button("Replace Cover") {
            #if E2E
              if let data = E2EMetadataReplacementCover.data {
                setCover(data: data, mediaType: "image/png", source: .file)
                return
              }
            #endif
            isChoosingCoverSource = true
          }
          .buttonStyle(.bordered)
          .tint(PlayerColor.accent)
          .accessibilityIdentifier("metadata-replace-cover")
          if draft.cover != nil {
            Button("Remove Cover", role: .destructive) { removeCover() }
              .accessibilityIdentifier("metadata-remove-cover")
          }
        }
        Spacer(minLength: 0)
      }
      metadataStateProbe(
        id: "metadata-cover-state",
        value: "cover=\(coverToken)|source=\(sourceToken(.cover))|locked=\(isLocked(.cover))"
      )
    }
    .padding(16)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18))
  }

  private var identityFields: some View {
    metadataSection("Identity") {
      editorRow("Title", field: .title) {
        HStack {
          TextField(
            "Title",
            text: $draft.title,
            axis: dynamicTypeSize.isAccessibilitySize ? .vertical : .horizontal
          )
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            .textInputAutocapitalization(.words)
            .accessibilityIdentifier("metadata-title-input")
          Button("Apply") {
            touchedFields.insert(.title)
            lockOverrides[.title] = true
          }
            .font(.caption.weight(.semibold))
            .accessibilityIdentifier("metadata-apply-title")
        }
      }
      editorRow("Sort title", field: .sortTitle) {
        TextField("Sort title", text: $draft.sortTitle)
      }
      editorRow("Subtitle", field: .subtitle) {
        TextField("Subtitle", text: $draft.subtitle)
      }
    }
  }

  private var contributorFields: some View {
    metadataSection("Contributors") {
      editorRow("Authors", field: .authors) {
        TextField("Comma-separated authors", text: $draft.authors)
          .accessibilityIdentifier("metadata-authors-input")
      }
      editorRow("Narrators", field: .narrators) {
        VStack(alignment: .trailing, spacing: 6) {
          TextField("Comma-separated narrators", text: $draft.narrators)
            .accessibilityIdentifier("metadata-narrators-input")
          Button("Clear narrators", role: .destructive) {
            draft.narrators = ""
            explicitlyCleared.insert(.narrators)
            lockOverrides[.narrators] = true
          }
          .font(.caption.weight(.semibold))
          .accessibilityIdentifier("metadata-clear-narrators")
        }
      }
    }
  }

  private var seriesFields: some View {
    metadataSection("Series") {
      editorRow("Series", field: .seriesName) {
        TextField("Series name", text: $draft.seriesName)
          .accessibilityIdentifier("metadata-series-input")
      }
      editorRow("Position", field: .seriesPosition) {
        TextField("Book number", text: $draft.seriesPosition)
          .disabled(draft.seriesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("metadata-series-position-input")
      }
      Button {
        let locked = !isLocked(.seriesName)
        lockOverrides[.seriesName] = locked
      } label: {
        Label(
          isLocked(.seriesName) ? "Unlock series" : "Lock series",
          systemImage: isLocked(.seriesName) ? "lock.fill" : "lock.open"
        )
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.plain)
      .foregroundStyle(PlayerColor.accent)
      .accessibilityIdentifier("metadata-lock-series")
    }
  }

  private var descriptiveFields: some View {
    metadataSection("Description and classification") {
      editorRow("Description", field: .description) {
        TextField("Description", text: $draft.description, axis: .vertical)
          .lineLimit(3...7)
      }
      editorRow("Genres", field: .genres) {
        TextField("Comma-separated genres", text: $draft.genres)
      }
      editorRow("Tags", field: .tags) {
        TextField("Comma-separated tags", text: $draft.tags)
      }
      editorRow("Language", field: .language) {
        TextField("Language", text: $draft.language)
      }
    }
  }

  private var publicationFields: some View {
    metadataSection("Publication") {
      editorRow("Year", field: .publicationYear) {
        TextField("Year", text: $draft.publicationYear)
          .keyboardType(.numberPad)
      }
      editorRow("Publisher", field: .publisher) {
        TextField("Publisher", text: $draft.publisher)
      }
      editorRow("Edition", field: .edition) {
        TextField("Edition", text: $draft.edition)
      }
      editorRow("Abridgement", field: .abridgement) {
        Picker("Abridgement", selection: $draft.abridgement) {
          Text("Not specified").tag("")
          Text("Unabridged").tag(AbridgementStatus.unabridged.rawValue)
          Text("Abridged").tag(AbridgementStatus.abridged.rawValue)
          Text("Unknown").tag(AbridgementStatus.unknown.rawValue)
        }
        .labelsHidden()
      }
    }
  }

  private var lockSummary: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Curated fields stay locked", systemImage: "lock.shield")
        .font(.headline)
      Text("Player will not replace a locked value during a future rescan. Clear is saved as an intentional choice.")
        .font(.caption)
        .foregroundStyle(PlayerColor.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18))
  }

  private var cropSheet: some View {
    NavigationStack {
      VStack(spacing: 22) {
        ArtworkView(data: draft.cover?.originalData, size: 230, isEssential: true)
        LabeledContent("Zoom") { Slider(value: $cropZoom, in: 1...2) }
        LabeledContent("Horizontal") { Slider(value: $cropX, in: 0...1) }
        LabeledContent("Vertical") { Slider(value: $cropY, in: 0...1) }
        Text("Player retains the original cover, so this crop can be changed later.")
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
        Spacer()
      }
      .padding(24)
      .navigationTitle("Crop Cover")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { isCroppingCover = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Apply") { applyCrop() }
        }
      }
    }
  }

  @ViewBuilder
  private func metadataSection<Content: View>(
    _ title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Text(title)
        .font(.headline)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      content()
    }
    .background(PlayerColor.card, in: RoundedRectangle(cornerRadius: 18))
  }

  @ViewBuilder
  private func editorRow<Content: View>(
    _ title: String,
    field: MetadataField,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(spacing: 8) {
      Divider().padding(.leading, 16)
      adaptiveRowLayout {
        VStack(alignment: .leading, spacing: 4) {
          Text(title).font(.subheadline.weight(.semibold))
          Text(fieldSource(field))
            .font(.caption2)
            .foregroundStyle(PlayerColor.secondary)
        }
        .frame(width: dynamicTypeSize.isAccessibilitySize ? nil : 88, alignment: .leading)
        VStack(alignment: .trailing, spacing: 6) {
          content()
          Button {
            lockOverrides[field] = !isLocked(field)
          } label: {
            Label(
              isLocked(field) ? "Locked" : "Unlocked",
              systemImage: isLocked(field) ? "lock.fill" : "lock.open"
            )
          }
          .font(.caption2.weight(.semibold))
          .buttonStyle(.plain)
          .foregroundStyle(PlayerColor.secondary)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
      metadataStateProbe(id: "metadata-field-\(fieldProbeName(field))", value: fieldProbeValue(field))
    }
  }

  private func metadataStateProbe(id: String, value: String) -> some View {
    Color.clear
      .frame(width: 1, height: 1)
      .id(value)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(id)
      .accessibilityIdentifier(id)
      .accessibilityValue(value)
  }

  private var adaptiveRowLayout: AnyLayout {
    if dynamicTypeSize.isAccessibilitySize {
      AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
    } else {
      AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }
  }

  private var adaptiveCoverLayout: AnyLayout {
    if dynamicTypeSize.isAccessibilitySize {
      AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
    } else {
      AnyLayout(HStackLayout(spacing: 18))
    }
  }

  private func loadIfNeeded() {
    guard !loaded, let metadata = currentMetadata else { return }
    initial = MetadataEditorDraft(metadata: metadata)
    draft = initial
    loaded = true
  }

  private func save() {
    let mutations = makeMutations()
    guard !mutations.isEmpty else { dismiss(); return }
    Task {
      guard await model.repairMetadata(target: target, mutations: mutations) != nil else {
        errorMessage = model.lastErrorMessage ?? "The metadata transaction could not be saved."
        return
      }
      UIAccessibility.post(notification: .announcement, argument: "Audiobook details saved")
      dismiss()
    }
  }

  private func makeMutations() -> [MetadataMutation] {
    var mutations: [MetadataMutation] = []
    appendTextMutation(.title, initial: initial.title, current: draft.title, to: &mutations)
    appendTextMutation(.sortTitle, initial: initial.sortTitle, current: draft.sortTitle, to: &mutations)
    appendTextMutation(.subtitle, initial: initial.subtitle, current: draft.subtitle, to: &mutations)
    appendContributorsMutation(.authors, initial: initial.authors, current: draft.authors, to: &mutations)
    appendContributorsMutation(.narrators, initial: initial.narrators, current: draft.narrators, to: &mutations)

    if initial.seriesName != draft.seriesName || initial.seriesPosition != draft.seriesPosition {
      let name = normalized(draft.seriesName)
      if name.isEmpty {
        mutations.append(.clear(.seriesName, lock: isLocked(.seriesName)))
      } else {
        mutations.append(.set(
          .seriesName,
          value: .seriesMemberships([
            SeriesMembership(name: name, position: normalized(draft.seriesPosition).nonEmpty)
          ]),
          lock: isLocked(.seriesName)
        ))
        mutations.append(.setLocked(.seriesPosition, locked: isLocked(.seriesPosition)))
      }
    }

    appendTextMutation(.description, initial: initial.description, current: draft.description, to: &mutations)
    appendListMutation(.genres, initial: initial.genres, current: draft.genres, to: &mutations)
    appendListMutation(.tags, initial: initial.tags, current: draft.tags, to: &mutations)
    appendTextMutation(.language, initial: initial.language, current: draft.language, to: &mutations)
    if initial.publicationYear != draft.publicationYear {
      if let year = Int(normalized(draft.publicationYear)) {
        mutations.append(.set(.publicationYear, value: .publicationYear(year), lock: isLocked(.publicationYear)))
      } else {
        mutations.append(.clear(.publicationYear, lock: isLocked(.publicationYear)))
      }
    }
    appendTextMutation(.publisher, initial: initial.publisher, current: draft.publisher, to: &mutations)
    appendTextMutation(.edition, initial: initial.edition, current: draft.edition, to: &mutations)
    if initial.abridgement != draft.abridgement {
      if let value = AbridgementStatus(rawValue: draft.abridgement) {
        mutations.append(.set(.abridgement, value: .abridgement(value), lock: isLocked(.abridgement)))
      } else {
        mutations.append(.clear(.abridgement, lock: isLocked(.abridgement)))
      }
    }
    if coverWasRemoved {
      mutations.append(.clear(.cover, lock: true))
    }
    if initial.cover != draft.cover {
      if let cover = draft.cover {
        mutations.append(.set(.cover, value: .cover(cover), lock: isLocked(.cover)))
      } else {
        mutations.append(.clear(.cover, lock: isLocked(.cover)))
      }
    }

    for (field, locked) in lockOverrides where !mutations.contains(where: { $0.field == field }) {
      mutations.append(.setLocked(field, locked: locked))
    }
    return mutations
  }

  private func appendTextMutation(
    _ field: MetadataField,
    initial: String,
    current: String,
    to mutations: inout [MetadataMutation]
  ) {
    guard initial != current || explicitlyCleared.contains(field) else { return }
    let value = normalized(current)
    mutations.append(value.isEmpty
      ? .clear(field, lock: isLocked(field))
      : .set(field, value: .text(value), lock: isLocked(field)))
  }

  private func appendContributorsMutation(
    _ field: MetadataField,
    initial: String,
    current: String,
    to mutations: inout [MetadataMutation]
  ) {
    guard initial != current || explicitlyCleared.contains(field) else { return }
    let contributors = list(current).map { Contributor(displayName: $0) }
    mutations.append(contributors.isEmpty
      ? .clear(field, lock: isLocked(field))
      : .set(field, value: .contributors(contributors), lock: isLocked(field)))
  }

  private func appendListMutation(
    _ field: MetadataField,
    initial: String,
    current: String,
    to mutations: inout [MetadataMutation]
  ) {
    guard initial != current else { return }
    let values = list(current)
    mutations.append(values.isEmpty
      ? .clear(field, lock: isLocked(field))
      : .set(field, value: .textList(values), lock: isLocked(field)))
  }

  private func replaceCover(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Data(contentsOf: url)
      setCover(data: data, mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? imageMediaType(data), source: .file)
    } catch {
      errorMessage = "The selected cover file could not be read."
    }
  }

  private func setCover(data: Data, mediaType: String, source: CoverSource) {
    guard !data.isEmpty else { return }
    draft.cover = CoverArtwork(originalData: data, mediaType: mediaType, source: source)
    explicitlyCleared.remove(.cover)
    touchedFields.insert(.cover)
    lockOverrides[.cover] = true
  }

  private func removeCover() {
    draft.cover = nil
    coverWasRemoved = true
    explicitlyCleared.insert(.cover)
    lockOverrides[.cover] = true
  }

  private func applyCrop() {
    guard var cover = draft.cover else { return }
    let side = 1 / cropZoom
    let x = min(max(cropX - side / 2, 0), 1 - side)
    let y = min(max(cropY - side / 2, 0), 1 - side)
    cover.crop = CoverCrop(x: x, y: y, width: side, height: side)
    cover.source = .userCrop
    draft.cover = cover
    touchedFields.insert(.cover)
    lockOverrides[.cover] = true
    isCroppingCover = false
  }

  private var currentMetadata: AudiobookMetadata? {
    switch target {
    case .book(let id):
      model.library.books.first(where: { $0.id == id })?.metadata
    case .proposal(let jobID, let proposalID):
      model.library.importJobs.first(where: { $0.id == jobID })?
        .proposals.first(where: { $0.id == proposalID })?.metadata
    }
  }

  private var isDirty: Bool {
    loaded && (
      draft != initial || coverWasRemoved || !touchedFields.isEmpty
        || !explicitlyCleared.isEmpty || !lockOverrides.isEmpty
    )
  }

  private var screenAccessibilityValue: String {
    let kind: String
    let revision: Int
    switch target {
    case .book:
      kind = "book"
      revision = 0
    case .proposal(let jobID, _):
      kind = "proposal"
      revision = model.library.importJobs.first(where: { $0.id == jobID })?.reviewRevision ?? 0
    }
    return "metadata:\(kind):revision=\(revision):dirty=\(isDirty)"
  }

  private func fieldProbeValue(_ field: MetadataField) -> String {
    let value: String
    switch field {
    case .title: value = draft.title
    case .authors: value = list(draft.authors).joined(separator: ", ")
    case .narrators: value = list(draft.narrators).joined(separator: ", ")
    case .seriesName:
      let name = normalized(draft.seriesName)
      let position = normalized(draft.seriesPosition)
      value = position.isEmpty ? name : "\(name) #\(position)"
    default: value = draft.displayValue(for: field)
    }
    let cleared = value.isEmpty && explicitlyCleared.contains(field)
      || (currentMetadata?.state(for: field)?.isExplicitlyCleared == true && !isDirty)
    return "value=\(value.isEmpty ? "empty" : value)|source=\(cleared ? "user-clear" : sourceToken(field))|confidence=\(confidenceToken(field))|locked=\(isLocked(field))|cleared=\(cleared)"
  }

  private func fieldProbeName(_ field: MetadataField) -> String {
    switch field {
    case .seriesName: "series"
    default: field.rawValue.replacingOccurrences(of: "Name", with: "").lowercased()
    }
  }

  private func fieldSource(_ field: MetadataField) -> String {
    switch sourceToken(field) {
    case "embedded-tag": "Embedded tag · \(confidenceToken(field).capitalized) confidence"
    case "embedded-artwork": "Embedded artwork · \(confidenceToken(field).capitalized) confidence"
    case "user-clear": "Cleared by you"
    case "user": "You"
    case "filename": "Filename"
    case "folder-name": "Folder name"
    default: "Library record"
    }
  }

  private func sourceToken(_ field: MetadataField) -> String {
    if explicitlyCleared.contains(field) { return "user-clear" }
    if touchedFields.contains(field) || fieldChanged(field) { return "user" }
    guard let state = currentMetadata?.state(for: field) else { return "legacy-library" }
    if state.isExplicitlyCleared { return "user-clear" }
    switch state.provenance {
    case .embeddedTag: return field == .cover ? "embedded-artwork" : "embedded-tag"
    case .filename: return "filename"
    case .folderName: return "folder-name"
    case .fileOrder: return "file-order"
    case .legacyLibrary: return "legacy-library"
    case .user: return "user"
    }
  }

  private func confidenceToken(_ field: MetadataField) -> String {
    if sourceToken(field) == "user" || sourceToken(field) == "user-clear" { return "user" }
    return currentMetadata?.state(for: field)?.confidence.rawValue ?? "medium"
  }

  private func isLocked(_ field: MetadataField) -> Bool {
    lockOverrides[field] ?? currentMetadata?.state(for: field)?.isLocked ?? false
  }

  private func fieldChanged(_ field: MetadataField) -> Bool {
    draft.displayValue(for: field) != initial.displayValue(for: field)
  }

  private var coverToken: String {
    guard let cover = draft.cover else { return "none" }
    return cover.originalData == initial.cover?.originalData ? "original" : "replacement"
  }

  private func normalized(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func list(_ value: String) -> [String] {
    value.split(separator: ",").map { normalized(String($0)) }.filter { !$0.isEmpty }
  }

  private func imageMediaType(_ data: Data) -> String {
    if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
    if data.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
    return "application/octet-stream"
  }
}

private struct MetadataEditorDraft: Equatable {
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

  static let empty = MetadataEditorDraft(metadata: AudiobookMetadata(title: ""))

  init(metadata: AudiobookMetadata) {
    title = metadata.title
    sortTitle = metadata.sortTitle ?? ""
    subtitle = metadata.subtitle ?? ""
    authors = metadata.authors.map(\.displayName).joined(separator: ", ")
    narrators = metadata.narrators.map(\.displayName).joined(separator: ", ")
    seriesName = metadata.seriesMemberships.first?.name ?? ""
    seriesPosition = metadata.seriesMemberships.first?.position ?? ""
    description = metadata.description ?? ""
    genres = metadata.genres.joined(separator: ", ")
    tags = metadata.tags.joined(separator: ", ")
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
    case .seriesName: seriesPosition.isEmpty ? seriesName : "\(seriesName) #\(seriesPosition)"
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

#if E2E
  private enum E2EMetadataReplacementCover {
    static var data: Data? {
      ProcessInfo.processInfo.environment["PLAYER_E2E_METADATA_REPLACEMENT_COVER_BASE64"]
        .flatMap { Data(base64Encoded: $0) }
    }
  }
#endif

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
