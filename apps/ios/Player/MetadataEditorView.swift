import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct MetadataEditorView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.dynamicTypeSize) private var dynamicTypeSize
  @Bindable var model: PlayerModel
  let target: MetadataTarget

  @State private var initialMetadata = AudiobookMetadata(title: "")
  @State private var initial = MetadataEditDraft.empty
  @State private var draft = MetadataEditDraft.empty
  @State private var loaded = false
  @State private var touchedFields: Set<MetadataField> = []
  @State private var explicitlyCleared: Set<MetadataField> = []
  @State private var coverWasRemoved = false
  @State private var lockOverrides: [MetadataField: Bool] = [:]
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var isChoosingCoverPhoto = false
  @State private var isChoosingCoverFile = false
  @State private var isChoosingCoverSource = false
  @State private var isCroppingCover = false
  @State private var cropZoom = 1.0
  @State private var cropX = 0.5
  @State private var cropY = 0.5
  @State private var localError: PlayerPresentationError?
  @State private var isSaving = false

  var body: some View {
    ZStack {
      PlayerColor.background.ignoresSafeArea()
      ScrollViewReader { _ in
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
        .playerMiniPlayerScrollRunway()
        .accessibilityIdentifier("metadata-editor-scroll")
        .e2eScrollReadiness(
          id: "metadata-editor-scroll-readiness",
          containerID: "metadata-editor-scroll",
          axis: .vertical
        )
      }
      #if E2E
        StateProbe(
          id: "metadata-title-value-state",
          value: draft.title.isEmpty ? "empty" : "value=\(draft.title)"
        )
        StateProbe(
          id: "metadata-crop-state",
          value: draft.cover?.crop.map { cropValue($0) } ?? "crop=none"
        )
        StateProbe(
          id: "metadata-validation-state",
          value: validationError.map { "invalid=\($0.localizedDescription)" } ?? "valid"
        )
        StateProbe(id: "metadata-committed-state", value: committedMetadataProbeValue)
      #endif
    }
    .navigationTitle("Edit Details")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(true)
    .interactiveDismissDisabled(isSaving)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { cancel() }
          .disabled(isSaving)
          .accessibilityIdentifier("metadata-cancel")
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { save() }
          .disabled(!isDirty || validationError != nil || isSaving)
          .accessibilityIdentifier("metadata-save")
      }
      ToolbarItemGroup(placement: .keyboard) {
        Spacer()
        Button("Done") {
          UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
          )
        }
          .accessibilityIdentifier("metadata-keyboard-done")
      }
    }
    .alert(localError?.title ?? "Couldn’t Save Details", isPresented: Binding(
      get: { localError != nil },
      set: { if !$0 { dismissLocalError() } }
    )) {
      Button("OK", role: .cancel) { dismissLocalError() }
    } message: {
      Text(localError?.message ?? "Try again.")
    }
    .confirmationDialog("Change Cover", isPresented: $isChoosingCoverSource) {
      Button("Choose Photo") { chooseCoverPhoto() }
      Button("Choose File") { isChoosingCoverFile = true }
      if draft.cover != nil { Button("Crop") { openCrop() } }
      Button("Remove", role: .destructive) { removeCover() }
    }
    .photosPicker(
      isPresented: $isChoosingCoverPhoto,
      selection: $selectedPhoto,
      matching: .images
    )
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
      defer { self.selectedPhoto = nil }
      do {
        guard let data = try await selectedPhoto.loadTransferable(type: Data.self), !data.isEmpty else {
          presentLocalError(
            "The selected photo did not contain a readable image. Choose another photo."
          )
          return
        }
        setCover(data: data, mediaType: imageMediaType(data), source: .photoLibrary)
      } catch {
        presentLocalError(
          "The selected photo could not be read. Download it in Photos, then try again."
        )
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
        ArtworkView(
          data: CoverArtworkRenderer.renderedData(for: draft.cover),
          size: 126,
          isEssential: true
        )
        VStack(alignment: .leading, spacing: 10) {
          Text("Cover").font(.headline)
          Text(fieldSource(.cover))
            .font(.caption)
            .foregroundStyle(PlayerColor.secondary)
          Button("Replace Cover") {
            isChoosingCoverSource = true
          }
          .buttonStyle(.bordered)
          .tint(PlayerColor.accent)
          .accessibilityIdentifier("metadata-replace-cover")
          if draft.cover != nil {
            Button("Remove Cover", role: .destructive) { removeCover() }
              .accessibilityIdentifier("metadata-remove-cover")
          }
          Button {
            lockOverrides[.cover] = !isLocked(.cover)
          } label: {
            Label(
              isLocked(.cover) ? "Locked" : "Unlocked",
              systemImage: isLocked(.cover) ? "lock.fill" : "lock.open"
            )
          }
          .font(.caption2.weight(.semibold))
          .buttonStyle(.plain)
          .foregroundStyle(PlayerColor.secondary)
          .accessibilityIdentifier("metadata-lock-cover")
        }
        Spacer(minLength: 0)
      }
      metadataStateProbe(
        id: "metadata-cover-state",
        value: "cover=\(coverToken)|source=\(sourceToken(.cover))|locked=\(isLocked(.cover))"
      )
      metadataStateProbe(
        id: "metadata-provenance-cover",
        value: fieldProbeValue(.cover)
      )
      metadataStateProbe(
        id: "metadata-field-cover",
        value: coverToken
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
            .accessibilityIdentifier("metadata-field-title")
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
          .accessibilityIdentifier("metadata-field-sortTitle")
      }
      editorRow("Subtitle", field: .subtitle) {
        TextField("Subtitle", text: $draft.subtitle)
          .accessibilityIdentifier("metadata-field-subtitle")
      }
    }
  }

  private var contributorFields: some View {
    metadataSection("Contributors") {
      editorRow("Authors", field: .authors) {
        TextField("Authors; quote names containing commas", text: $draft.authors)
          .accessibilityIdentifier("metadata-field-authors")
      }
      editorRow("Narrators", field: .narrators) {
        VStack(alignment: .trailing, spacing: 6) {
          TextField("Narrators; quote names containing commas", text: $draft.narrators)
            .accessibilityIdentifier("metadata-field-narrators")
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
          .accessibilityIdentifier("metadata-field-seriesName")
      }
      editorRow("Position", field: .seriesPosition) {
        TextField("Book number", text: $draft.seriesPosition)
          .disabled(draft.seriesName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("metadata-field-seriesPosition")
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
          .accessibilityIdentifier("metadata-field-description")
      }
      editorRow("Genres", field: .genres) {
        TextField("Genres; quote values containing commas", text: $draft.genres)
          .accessibilityIdentifier("metadata-field-genres")
      }
      editorRow("Tags", field: .tags) {
        TextField("Tags; quote values containing commas", text: $draft.tags)
          .accessibilityIdentifier("metadata-field-tags")
      }
      editorRow("Language", field: .language) {
        TextField("Language", text: $draft.language)
          .accessibilityIdentifier("metadata-field-language")
      }
    }
  }

  private var publicationFields: some View {
    metadataSection("Publication") {
      editorRow("Year", field: .publicationYear) {
        TextField("Year", text: $draft.publicationYear)
          .keyboardType(.numberPad)
          .accessibilityIdentifier("metadata-field-publicationYear")
      }
      editorRow("Publisher", field: .publisher) {
        TextField("Publisher", text: $draft.publisher)
          .accessibilityIdentifier("metadata-field-publisher")
      }
      editorRow("Edition", field: .edition) {
        TextField("Edition", text: $draft.edition)
          .accessibilityIdentifier("metadata-field-edition")
      }
      editorRow("Abridgement", field: .abridgement) {
        Picker("Abridgement", selection: $draft.abridgement) {
          Text("Not specified").tag("")
          Text("Unabridged").tag(AbridgementStatus.unabridged.rawValue)
          Text("Abridged").tag(AbridgementStatus.abridged.rawValue)
          Text("Unknown").tag(AbridgementStatus.unknown.rawValue)
        }
        .labelsHidden()
        .accessibilityIdentifier("metadata-field-abridgement")
      }
    }
  }

  private var lockSummary: some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("Curated fields stay locked", systemImage: "lock.shield")
        .font(.headline)
      Text("Bookshelf will not replace a locked value during a future rescan. Clear is saved as an intentional choice.")
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
        ArtworkView(
          data: CoverArtworkRenderer.renderedData(for: cropPreviewCover),
          size: 230,
          isEssential: true,
          accessibilityIdentifierOverride: "metadata-crop-preview-artwork"
        )
        LabeledContent("Zoom") {
          Slider(value: $cropZoom, in: 1...2)
            .accessibilityIdentifier("metadata-crop-zoom")
        }
        LabeledContent("Horizontal") {
          Slider(value: $cropX, in: 0...1)
            .accessibilityIdentifier("metadata-crop-horizontal")
        }
        LabeledContent("Vertical") {
          Slider(value: $cropY, in: 0...1)
            .accessibilityIdentifier("metadata-crop-vertical")
        }
        Text("Bookshelf retains the original cover, so this crop can be changed later.")
          .font(.caption)
          .foregroundStyle(PlayerColor.secondary)
        #if E2E
          StateProbe(id: "metadata-crop-preview-state", value: cropPreviewStateValue)
        #endif
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
            .accessibilityIdentifier("metadata-apply-crop")
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
          .accessibilityIdentifier("metadata-lock-\(field.rawValue)")
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 12)
      metadataStateProbe(
        id: "metadata-provenance-\(fieldProbeName(field))",
        value: fieldProbeValue(field)
      )
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
    initialMetadata = metadata
    initial = MetadataEditDraft(metadata: metadata)
    draft = initial
    loaded = true
  }

  private func save() {
    guard !isSaving else { return }
    let plan: MetadataEditPlan
    do {
      plan = try MetadataEditPlanner.plan(
        initial: initialMetadata,
        draft: draft,
        explicitClears: explicitlyCleared,
        lockOverrides: lockOverrides
      )
    } catch {
      presentLocalError(error.localizedDescription)
      return
    }
    guard !plan.mutations.isEmpty else { dismiss(); return }
    isSaving = true
    Task {
      guard await model.repairMetadata(target: target, mutations: plan.mutations) != nil else {
        isSaving = false
        localError = model.presentationError(in: .metadata)
          ?? PlayerPresentationError.presenting(
            "The metadata transaction could not be saved. Try again.",
            in: .metadata
          )
        return
      }
      UIAccessibility.post(notification: .announcement, argument: "Audiobook details saved")
      dismiss()
    }
  }

  private func cancel() {
    guard !isSaving else { return }
    dismiss()
  }

  private func replaceCover(from url: URL) {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
    do {
      let data = try Data(contentsOf: url)
      setCover(data: data, mediaType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? imageMediaType(data), source: .file)
    } catch {
      presentLocalError("The selected cover file could not be read. Choose another image.")
    }
  }

  private func chooseCoverPhoto() {
    #if E2E
      guard let data = E2EMetadataRepairBridge.shared.replacementCoverData else {
        presentLocalError("The deterministic replacement photo is unavailable.")
        return
      }
      setCover(data: data, mediaType: "image/png", source: .photoLibrary)
    #else
      isChoosingCoverPhoto = true
    #endif
  }

  private func presentLocalError(_ message: String) {
    localError = PlayerPresentationError.presenting(message, in: .metadata)
  }

  private func dismissLocalError() {
    if let id = localError?.id {
      model.clearPresentedError(id: id)
    }
    localError = nil
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

  private func openCrop() {
    if let crop = draft.cover?.crop, crop.width > 0, crop.height > 0 {
      cropZoom = min(max(1 / min(crop.width, crop.height), 1), 2)
      cropX = min(max(crop.x + crop.width / 2, 0), 1)
      cropY = min(max(crop.y + crop.height / 2, 0), 1)
    } else {
      cropZoom = 1
      cropX = 0.5
      cropY = 0.5
    }
    isCroppingCover = true
  }

  private func applyCrop() {
    guard var cover = draft.cover else { return }
    cover.crop = pendingCrop
    cover.source = .userCrop
    draft.cover = cover
    touchedFields.insert(.cover)
    lockOverrides[.cover] = true
    isCroppingCover = false
  }

  private var pendingCrop: CoverCrop {
    let side = 1 / cropZoom
    let x = min(max(cropX - side / 2, 0), 1 - side)
    let y = min(max(cropY - side / 2, 0), 1 - side)
    return CoverCrop(x: x, y: y, width: side, height: side)
  }

  private var cropPreviewCover: CoverArtwork? {
    guard var cover = draft.cover else { return nil }
    cover.crop = pendingCrop
    return cover
  }

  private var cropPreviewStateValue: String {
    cropValue(pendingCrop, prefix: "preview")
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

  private var validationError: MetadataRepairError? {
    guard loaded else { return nil }
    return MetadataEditPlanner.validationError(
      initial: initialMetadata,
      draft: draft,
      explicitClears: explicitlyCleared,
      lockOverrides: lockOverrides
    )
  }

  private var screenAccessibilityValue: String {
    let kind: String
    let revision: String
    switch target {
    case .book:
      kind = "book"
      revision = model.library.metadataRevision(for: target)
    case .proposal(let jobID, _):
      kind = "proposal"
      revision = String(
        model.library.importJobs.first(where: { $0.id == jobID })?.reviewRevision ?? 0
      )
    }
    return "metadata:\(kind):revision=\(revision):dirty=\(isDirty):saving=\(isSaving):validation=\(validationError == nil ? "valid" : "invalid")"
  }

  private var committedMetadataProbeValue: String {
    guard let metadata = currentMetadata else { return "missing" }
    let fields = MetadataField.allCases.map { field in
      let state = metadata.state(for: field)
      return "\(field.rawValue){value=\(metadata.displayText(for: field) ?? "empty"),source=\(state?.provenance.rawValue ?? "none"),locked=\(state?.isLocked ?? false),cleared=\(state?.isExplicitlyCleared ?? false),transaction=\(state?.lastTransactionID?.uuidString.lowercased() ?? "none")}"
    }.joined(separator: "|")
    let transactionRevision = model.library.metadataTransactions.filter { $0.target == target }
      .map { "\($0.id.uuidString.lowercased()):\($0.status.rawValue)" }.joined(separator: ",")
    return "target=\(targetProbeValue)|transactions=\(transactionRevision.isEmpty ? "none" : transactionRevision)|\(fields)"
  }

  private var targetProbeValue: String {
    switch target {
    case .book(let id): return "book:\(id.uuidString.lowercased())"
    case .proposal(let jobID, let proposalID):
      return "proposal:\(jobID.uuidString.lowercased()):\(proposalID.uuidString.lowercased())"
    }
  }

  private func cropValue(_ crop: CoverCrop, prefix: String = "crop") -> String {
    String(
      format: "%@=x:%.3f:y:%.3f:width:%.3f:height:%.3f:rotation:%.1f",
      prefix,
      crop.x,
      crop.y,
      crop.width,
      crop.height,
      crop.rotationDegrees
    )
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
    let cleared = plannedExplicitClears.contains(field)
    return "value=\(value.isEmpty ? "empty" : value)|source=\(cleared ? "user-clear" : sourceToken(field))|confidence=\(confidenceToken(field))|locked=\(isLocked(field))|cleared=\(cleared)"
  }

  private func fieldProbeName(_ field: MetadataField) -> String {
    field.rawValue
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
    if plannedExplicitClears.contains(field) { return "user-clear" }
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

  private var plannedExplicitClears: Set<MetadataField> {
    if let plan = try? MetadataEditPlanner.plan(
      initial: initialMetadata,
      draft: draft,
      explicitClears: explicitlyCleared,
      lockOverrides: lockOverrides
    ) {
      return plan.explicitlyClearedFields
    }
    var fields = Set(MetadataField.allCases.filter {
      initialMetadata.state(for: $0)?.isExplicitlyCleared == true
    })
    fields.formUnion(explicitlyCleared)
    for field in MetadataField.allCases {
      let before = normalized(initial.displayValue(for: field))
      let current = normalized(draft.displayValue(for: field))
      if !current.isEmpty {
        fields.remove(field)
      } else if before != current {
        fields.insert(field)
      }
    }
    if normalized(draft.seriesName).isEmpty, normalized(initial.seriesName) != "" {
      fields.insert(.seriesName)
      fields.insert(.seriesPosition)
    }
    return fields
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

private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}
