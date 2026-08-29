import XCTest
@testable import Player

@MainActor
final class LibrarySearchTests: XCTestCase {
  func testNormalizedIndexSearchesMetadataFilesChaptersCollectionsAndBookmarkText() {
    let book = makeBook(
      id: uuid(1),
      title: "L’Écho du Matin",
      author: Contributor(displayName: "Zoë Faure", sortName: "Faure, Zoë"),
      narrator: Contributor(displayName: "Ivo Chen"),
      series: SeriesMembership(name: "Night Signals", position: "4"),
      filename: "piste finale.m4b",
      chapter: "Départ pour Québec"
    )
    let collection = BookCollection(
      id: uuid(50),
      name: "Quiet Evenings",
      orderedBookIDs: [book.id],
      createdAt: .distantPast,
      updatedAt: .distantPast
    )
    let library = LibrarySnapshot(
      books: [book],
      importJobs: [],
      currentBookID: nil,
      collections: [collection]
    )
    let index = LibrarySearchIndex(
      library: library,
      bookmarkNotesByBookID: [book.id: ["Return to the café clue"]]
    )

    for query in [
      "echo matin", "zoe faure", "ivo", "night signals 4", "piste finale",
      "depart quebec", "quiet evenings", "cafe clue",
    ] {
      XCTAssertEqual(index.search(query: query, preferences: .default).books.map(\.id), [book.id])
    }
    XCTAssertTrue(index.search(query: "unrelated", preferences: .default).books.isEmpty)
  }

  func testEverySearchSortUsesBothDirectionsAndStableIdentityTieBreaks() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let alpha = makeBook(
      id: uuid(1), title: "Alpha", author: Contributor(displayName: "Zed Author"),
      series: SeriesMembership(name: "Signals", position: "10"),
      dateAdded: now, duration: 90, position: 45_000, status: .inProgress
    )
    let beta = makeBook(
      id: uuid(2), title: "Beta", author: Contributor(displayName: "Ana Author"),
      series: SeriesMembership(name: "Signals", position: "2"),
      filename: "beta.mp3", dateAdded: now.addingTimeInterval(20), duration: 120,
      position: 0, status: .unplayed, container: "MP3"
    )
    let gamma = makeBook(
      id: uuid(3), title: "Gamma", author: Contributor(displayName: "Moe Author"),
      dateAdded: now.addingTimeInterval(10), duration: 60, position: 60_000, status: .finished
    )
    let index = LibrarySearchIndex(library: LibrarySnapshot(
      books: [gamma, alpha, beta], importJobs: [], currentBookID: nil
    ))

    let ascending: [(sort: LibrarySearchSort, order: [UUID])] = [
      (.title, [alpha.id, beta.id, gamma.id]),
      (.author, [beta.id, gamma.id, alpha.id]),
      (.series, [gamma.id, beta.id, alpha.id]),
      (.recentlyAdded, [alpha.id, gamma.id, beta.id]),
      (.duration, [gamma.id, alpha.id, beta.id]),
      (.progress, [beta.id, alpha.id, gamma.id]),
    ]
    for (sort, order) in ascending {
      var preferences = LibrarySearchPreferences.default
      preferences.sort = sort
      XCTAssertEqual(
        index.search(query: "", preferences: preferences).books.map(\.id),
        order,
        "\(sort.rawValue) must implement its ascending production order"
      )
      preferences.direction = .descending
      XCTAssertEqual(
        index.search(query: "", preferences: preferences).books.map(\.id),
        Array(order.reversed()),
        "\(sort.rawValue) must reverse every comparison, including identity ties"
      )
    }

    let lowerID = makeBook(
      id: uuid(10), title: "Same", author: Contributor(displayName: "Same"),
      series: SeriesMembership(name: "Same", position: "1"), dateAdded: now,
      duration: 10, position: 1_000
    )
    let higherID = makeBook(
      id: uuid(11), title: "Same", author: Contributor(displayName: "Same"),
      series: SeriesMembership(name: "Same", position: "1"), dateAdded: now,
      duration: 10, position: 1_000
    )
    let tiedIndex = LibrarySearchIndex(library: LibrarySnapshot(
      books: [higherID, lowerID], importJobs: [], currentBookID: nil
    ))
    for sort in LibrarySearchSort.allCases {
      var preferences = LibrarySearchPreferences.default
      preferences.sort = sort
      XCTAssertEqual(
        tiedIndex.search(query: "", preferences: preferences).books.map(\.id),
        [lowerID.id, higherID.id]
      )
      preferences.direction = .descending
      XCTAssertEqual(
        tiedIndex.search(query: "", preferences: preferences).books.map(\.id),
        [higherID.id, lowerID.id]
      )
    }
  }

  func testEverySearchFilterWorksIndependentlyAndInRepresentativeCombinations() {
    let completeM4B = makeBook(
      id: uuid(1), title: "Complete M4B", author: Contributor(displayName: "Author"),
      position: 40_000, status: .inProgress
    )
    let unplayedMP3 = makeBook(
      id: uuid(2), title: "Unplayed MP3", author: Contributor(displayName: "Author"),
      filename: "unplayed.mp3", status: .unplayed, container: "MP3"
    )
    let missingNarratorM4B = makeBook(
      id: uuid(3), title: "Missing Narrator", author: Contributor(displayName: "Author"),
      hasNarrator: false, position: 120_000, status: .finished
    )
    let missingAuthorMP3 = makeBook(
      id: uuid(4), title: "Missing Author", author: Contributor(displayName: ""),
      hasAuthor: false, filename: "missing.mp3", status: .unplayed, container: "MP3"
    )
    let books = [completeM4B, unplayedMP3, missingNarratorM4B, missingAuthorMP3]
    let index = LibrarySearchIndex(library: LibrarySnapshot(
      books: books, importJobs: [], currentBookID: nil
    ))

    func result(_ update: (inout LibrarySearchPreferences) -> Void) -> [UUID] {
      var preferences = LibrarySearchPreferences.default
      update(&preferences)
      return index.search(query: "", preferences: preferences).books.map(\.id)
    }

    XCTAssertEqual(result { $0.status = nil }, books.sorted(by: { $0.title < $1.title }).map(\.id))
    XCTAssertEqual(result { $0.status = .unplayed }, [missingAuthorMP3.id, unplayedMP3.id])
    XCTAssertEqual(result { $0.status = .inProgress }, [completeM4B.id])
    XCTAssertEqual(result { $0.status = .finished }, [missingNarratorM4B.id])
    XCTAssertEqual(result { $0.formats = ["m4b"] }, [completeM4B.id, missingNarratorM4B.id])
    XCTAssertEqual(result { $0.missingMetadataOnly = true }, [missingAuthorMP3.id, missingNarratorM4B.id])
    XCTAssertEqual(result {
      $0.status = .finished
      $0.formats = ["M4B"]
      $0.missingMetadataOnly = true
    }, [missingNarratorM4B.id])
    XCTAssertTrue(result {
      $0.status = .inProgress
      $0.formats = ["MP3"]
      $0.missingMetadataOnly = true
    }.isEmpty)

    var combined = LibrarySearchPreferences.default
    combined.status = .unplayed
    combined.formats = ["MP3"]
    combined.missingMetadataOnly = true
    combined.sort = .author
    combined.direction = .descending
    XCTAssertEqual(
      index.search(query: "missing", preferences: combined).books.map(\.id),
      [missingAuthorMP3.id],
      "Query, listening state, format, metadata, sort, and direction compose deterministically"
    )
  }

  func testSearchPreferenceSummaryDescribesEveryFilterAndSort() {
    let expectedSortTokens: [(sort: LibrarySearchSort, token: String)] = [
      (.title, "Title"), (.author, "Author"), (.series, "Series order"),
      (.recentlyAdded, "Recently added"), (.duration, "Duration"), (.progress, "Progress"),
    ]
    for (sort, token) in expectedSortTokens {
      var preferences = LibrarySearchPreferences.default
      preferences.sort = sort
      XCTAssertEqual(preferences.summaryTokens, [token])
    }

    var preferences = LibrarySearchPreferences.default
    preferences.status = .inProgress
    preferences.formats = ["MP3", "M4B"]
    preferences.missingMetadataOnly = true
    preferences.sort = .series
    XCTAssertEqual(
      preferences.summaryTokens,
      ["In progress", "M4B, MP3", "Missing metadata", "Series order"]
    )
  }

  func testSearchPreferencesPersistAndClearAtomically() async {
    let store = InMemoryLibraryStore(snapshot: .empty)
    let model = PlayerModel(environment: PlayerEnvironment(
      persistence: store,
      media: SearchUnusedMediaManager(),
      inspector: SearchUnusedInspector(),
      playback: SearchPlaybackController()
    ))
    await model.restore()
    var preferences = LibrarySearchPreferences.default
    preferences.sort = .progress
    preferences.direction = .descending
    preferences.status = .inProgress
    preferences.formats = ["M4B"]

    let didSet = await model.setLibrarySearchPreferences(preferences)
    let storedPreferences = await store.load().searchPreferences
    XCTAssertTrue(didSet)
    XCTAssertEqual(storedPreferences, preferences)
    let didClear = await model.clearLibrarySearchPreferences()
    let clearedPreferences = await store.load().searchPreferences
    XCTAssertTrue(didClear)
    XCTAssertEqual(clearedPreferences, .default)
  }

  func testSchemaEightMigratesSearchPreferencesToDefaults() async throws {
    struct SchemaEightEnvelope: Encodable {
      let schemaVersion = 8
      let library: LibrarySnapshot
    }
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "PlayerSchemaEightSearch-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appending(path: "Library.json")
    var nonDefault = LibrarySearchPreferences.default
    nonDefault.sort = .progress
    nonDefault.status = .finished
    let legacy = LibrarySnapshot(
      books: [], importJobs: [], currentBookID: nil, searchPreferences: nonDefault
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(SchemaEightEnvelope(library: legacy)).write(to: fileURL)

    let migrated = try await CodableLibraryStore(fileURL: fileURL).load()
    XCTAssertEqual(migrated.searchPreferences, .default)
  }

  func testTenThousandBookIndexReturnsResultsWithinOneHundredMilliseconds() {
    let books = (0..<10_000).map { index in
      makeBook(
        id: uuid(index + 1),
        title: "Synthetic Volume \(index)",
        author: Contributor(displayName: "Author \(index % 250)"),
        chapter: index == 9_876 ? "Needle Chapter" : "Ordinary Chapter"
      )
    }
    let index = LibrarySearchIndex(library: LibrarySnapshot(
      books: books, importJobs: [], currentBookID: nil
    ))
    let start = ContinuousClock.now
    let result = index.search(query: "needle chapter", preferences: .default)
    let elapsed = start.duration(to: .now)

    XCTAssertEqual(result.books.map(\.id), [books[9_876].id])
    XCTAssertLessThan(elapsed, .milliseconds(100), "A 10,000-book indexed query must meet the MVP budget")
  }

  func testActorIndexerProducesStableWindowsForTenThousandScrollableResults() async {
    let books = (0..<10_000).map { index in
      makeBook(
        id: uuid(index + 1),
        title: String(format: "Volume %05d", index),
        author: Contributor(displayName: "Author")
      )
    }
    let builder = LibrarySearchIndexBuilder()
    let index = await builder.build(library: LibrarySnapshot(
      books: books.reversed(), importJobs: [], currentBookID: nil
    ))
    let result = index.search(query: "volume", preferences: .default)
    let completedBuildCount = await builder.completedBuildCount

    XCTAssertEqual(completedBuildCount, 1)
    XCTAssertEqual(result.window(offset: 0, limit: 3).map(\.id), books[0..<3].map(\.id))
    XCTAssertEqual(
      result.window(offset: 4_998, limit: 5).map(\.id),
      books[4_998..<5_003].map(\.id)
    )
    XCTAssertEqual(result.window(offset: 9_998, limit: 10).map(\.id), books[9_998...].map(\.id))
    XCTAssertTrue(result.window(offset: 10_000, limit: 1).isEmpty)
  }

  private func makeBook(
    id: UUID,
    title: String,
    author: Contributor,
    narrator: Contributor = Contributor(displayName: "Reader"),
    hasAuthor: Bool = true,
    hasNarrator: Bool = true,
    series: SeriesMembership? = nil,
    filename: String = "book.m4b",
    chapter: String = "Full Book",
    dateAdded: Date = .distantPast,
    duration: Double = 120,
    position: Int64 = 0,
    status: BookListeningStatus = .unplayed,
    container: String = "M4B"
  ) -> Book {
    let asset = AudioAsset(
      id: UUID(),
      originalFilename: filename,
      managedRelativePath: "Media/fixture/audio",
      checksumSHA256: "fixture",
      byteCount: 1,
      durationSeconds: duration,
      container: container
    )
    let metadata = AudiobookMetadata(
      title: title,
      authors: hasAuthor ? [author] : [],
      narrators: hasNarrator ? [narrator] : [],
      seriesMemberships: series.map { [$0] } ?? []
    )
    return Book(
      id: id,
      title: title,
      authors: hasAuthor ? [author.displayName] : [],
      durationSeconds: duration,
      artworkData: nil,
      assets: [asset],
      dateAdded: dateAdded,
      narrators: hasNarrator ? [narrator.displayName] : [],
      seriesName: series?.name,
      seriesPosition: series?.position,
      chapters: [Chapter(
        id: "chapter-\(id.uuidString)",
        title: chapter,
        startSeconds: 0,
        durationSeconds: duration,
        source: .file,
        assetID: asset.id
      )],
      metadata: metadata,
      listeningState: BookListeningState(
        status: status,
        positionMilliseconds: position,
        lastListenedAt: position > 0 ? dateAdded : nil,
        finishedAt: status == .finished ? dateAdded : nil
      )
    )
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "b0000000-0000-0000-0000-%012d", value))!
  }
}

private actor SearchUnusedMediaManager: MediaManaging {
  func stage(sourceURL: URL, jobID: UUID) throws -> StagedAudio { throw PlayerCoreError.fileOperation("unused") }
  func stagedURL(for relativePath: String) throws -> URL { URL(filePath: "/tmp/unused") }
  func commit(_ staged: StagedAudio, bookID: UUID, assetID: UUID) throws -> ManagedAudio { throw PlayerCoreError.fileOperation("unused") }
  func rollback(_ managed: ManagedAudio) {}
  func managedURL(for relativePath: String) throws -> URL { URL(filePath: "/tmp/unused") }
  func discardStaging(for jobID: UUID) {}
}

private struct SearchUnusedInspector: AudioInspecting {
  func inspect(url: URL) async throws -> InspectedAudio { throw PlayerCoreError.unreadableAudio("unused") }
}

@MainActor
private final class SearchPlaybackController: AudioPlaybackControlling {
  private(set) var state = PlaybackState.unloaded
  private(set) var currentPositionSeconds = 0.0
  func load(url: URL, bookID: UUID, at seconds: Double) async throws {
    currentPositionSeconds = seconds
    state = PlaybackState(status: .paused, loadedBookID: bookID, elapsedSeconds: seconds)
  }
  func play() { state.status = .playing }
  func pause() { state.status = .paused }
  func seek(to seconds: Double) async {
    currentPositionSeconds = seconds
    state.elapsedSeconds = seconds
  }
}
