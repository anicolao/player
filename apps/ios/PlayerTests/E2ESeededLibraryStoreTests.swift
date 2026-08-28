#if E2E
  import XCTest

  @testable import Player

  final class E2ESeededLibraryStoreTests: XCTestCase {
    func testMissingStoreIsSeeded() async throws {
      let root = temporaryDirectory("missing")
      defer { try? FileManager.default.removeItem(at: root) }
      let libraryURL = root.appending(path: "Library.json")
      let seed = snapshot(named: "seed", idSuffix: 1)

      let store = E2ESeededLibraryStore(
        base: CodableLibraryStore(fileURL: libraryURL),
        seed: seed
      )
      let loaded = try await store.load()
      XCTAssertEqual(loaded, seed)
      XCTAssertTrue(FileManager.default.fileExists(atPath: libraryURL.path))
      let durable = try await CodableLibraryStore(fileURL: libraryURL).load()
      XCTAssertEqual(durable, seed)
    }

    func testDurableSeedSurvivesWrapperRecreationWithADifferentSeed() async throws {
      let root = temporaryDirectory("recreation")
      defer { try? FileManager.default.removeItem(at: root) }
      let libraryURL = root.appending(path: "Library.json")
      let originalSeed = snapshot(named: "original-seed", idSuffix: 2)
      let first = E2ESeededLibraryStore(
        base: CodableLibraryStore(fileURL: libraryURL),
        seed: originalSeed
      )
      _ = try await first.load()

      let recreated = E2ESeededLibraryStore(
        base: CodableLibraryStore(fileURL: libraryURL),
        seed: snapshot(named: "replacement-seed", idSuffix: 3)
      )
      let durable = try await recreated.load()
      XCTAssertEqual(
        durable,
        originalSeed,
        "An existing durable fixture must win over a different launch seed."
      )
    }

    func testDeliberatelySavedEmptyStoreRemainsEmptyAcrossWrapperRecreation() async throws {
      let root = temporaryDirectory("saved-empty")
      defer { try? FileManager.default.removeItem(at: root) }
      let libraryURL = root.appending(path: "Library.json")
      let first = E2ESeededLibraryStore(
        base: CodableLibraryStore(fileURL: libraryURL),
        seed: snapshot(named: "seed", idSuffix: 4)
      )
      _ = try await first.load()
      try await first.save(.empty)

      let recreated = E2ESeededLibraryStore(
        base: CodableLibraryStore(fileURL: libraryURL),
        seed: snapshot(named: "must-not-return", idSuffix: 5)
      )
      let recreatedSnapshot = try await recreated.load()
      let durableSnapshot = try await CodableLibraryStore(fileURL: libraryURL).load()
      XCTAssertEqual(recreatedSnapshot, .empty)
      XCTAssertEqual(durableSnapshot, .empty)
    }

    func testCorruptExistingStoreThrowsInsteadOfReplacingItWithSeed() async throws {
      let root = temporaryDirectory("corrupt")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let libraryURL = root.appending(path: "Library.json")
      let corruptBytes = Data("corrupt durable fixture".utf8)
      try corruptBytes.write(to: libraryURL)
      let store = E2ESeededLibraryStore(
        base: CodableLibraryStore(fileURL: libraryURL),
        seed: snapshot(named: "must-not-mask-corruption", idSuffix: 6)
      )

      do {
        _ = try await store.load()
        XCTFail("An existing corrupt fixture must fail rather than being reseeded.")
      } catch let error as PlayerCoreError {
        XCTAssertEqual(error, .invalidStore)
      }
      XCTAssertEqual(try Data(contentsOf: libraryURL), corruptBytes)
    }

    private func snapshot(named name: String, idSuffix: Int) -> LibrarySnapshot {
      LibrarySnapshot(
        books: [],
        importJobs: [],
        currentBookID: nil,
        collections: [
          BookCollection(
            id: uuid(idSuffix),
            name: name,
            orderedBookIDs: [],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
          )
        ]
      )
    }

    private func temporaryDirectory(_ name: String) -> URL {
      FileManager.default.temporaryDirectory.appending(
        path: "E2ESeededLibraryStoreTests-\(name)-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    }

    private func uuid(_ suffix: Int) -> UUID {
      UUID(uuidString: String(format: "e2000000-0000-0000-0000-%012d", suffix))!
    }
  }

  final class E2EBookmarkClockTests: XCTestCase {
    private let initialValue = Date(timeIntervalSince1970: 1_700_030_000)

    func testMissingClockStateIsSeededAndAdvanceSurvivesReconstruction() throws {
      let root = temporaryDirectory("reconstruction")
      defer { try? FileManager.default.removeItem(at: root) }
      let stateURL = root.appending(path: "BookmarkClock.json")

      let first = try E2EBookmarkClock(value: initialValue, stateURL: stateURL)
      XCTAssertEqual(first.now(), initialValue)
      XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
      try first.advance(by: 60)
      XCTAssertEqual(first.now(), initialValue.addingTimeInterval(60))

      let reconstructed = try E2EBookmarkClock(value: initialValue, stateURL: stateURL)
      XCTAssertEqual(reconstructed.now(), initialValue.addingTimeInterval(60))

      try FileManager.default.removeItem(at: root)
      let reset = try E2EBookmarkClock(value: initialValue, stateURL: stateURL)
      XCTAssertEqual(reset.now(), initialValue)
    }

    func testInvalidAdvanceCannotMoveClockOrPersistedStateBackward() throws {
      let root = temporaryDirectory("invalid-advance")
      defer { try? FileManager.default.removeItem(at: root) }
      let stateURL = root.appending(path: "BookmarkClock.json")
      let clock = try E2EBookmarkClock(value: initialValue, stateURL: stateURL)

      XCTAssertThrowsError(try clock.advance(by: -1)) { error in
        XCTAssertEqual(error as? E2EBookmarkClockError, .invalidAdvance)
      }
      XCTAssertEqual(clock.now(), initialValue)
      let reconstructed = try E2EBookmarkClock(value: initialValue, stateURL: stateURL)
      XCTAssertEqual(reconstructed.now(), initialValue)
    }

    func testFailedPersistenceDoesNotPublishAdvancedTime() throws {
      let root = temporaryDirectory("failed-persistence")
      defer { try? FileManager.default.removeItem(at: root) }
      let stateURL = root.appending(path: "BookmarkClock.json")
      let clock = try E2EBookmarkClock(value: initialValue, stateURL: stateURL)
      try FileManager.default.removeItem(at: stateURL)
      try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)

      XCTAssertThrowsError(try clock.advance(by: 60))
      XCTAssertEqual(clock.now(), initialValue)
    }

    func testExistingInvalidClockStateFailsClosed() throws {
      let root = temporaryDirectory("invalid-state")
      defer { try? FileManager.default.removeItem(at: root) }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let stateURL = root.appending(path: "BookmarkClock.json")
      let invalidStates = [
        Data("not-json".utf8),
        Data(#"{"schemaVersion":2,"secondsSince1970":1700030060}"#.utf8),
        Data(#"{"schemaVersion":1,"secondsSince1970":1700029999}"#.utf8),
        Data(#"{"schemaVersion":1,"secondsSince1970":1700030060,"unknown":true}"#.utf8),
      ]

      for invalidState in invalidStates {
        try invalidState.write(to: stateURL, options: .atomic)
        XCTAssertThrowsError(try E2EBookmarkClock(value: initialValue, stateURL: stateURL)) {
          error in
          XCTAssertEqual(error as? E2EBookmarkClockError, .invalidState)
        }
        XCTAssertEqual(try Data(contentsOf: stateURL), invalidState)
      }
    }

    private func temporaryDirectory(_ name: String) -> URL {
      FileManager.default.temporaryDirectory.appending(
        path: "E2EBookmarkClockTests-\(name)-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    }
  }

  final class E2EFixtureContractTests: XCTestCase {
    func testEveryCanonicalFixtureIsAcceptedInE2EMode() throws {
      for fixture in E2EFixture.allCases {
        let parsed = try E2EFixture.parseForLaunch(arguments: [
          "Player", "-AppleLanguages", "(en)", "-e2e", "-e2e-fixture", fixture.rawValue,
          "-e2e-reset",
        ])
        XCTAssertEqual(parsed, fixture)
      }
    }

    func testLaunchWithoutE2EModePreservesProductionSelection() throws {
      XCTAssertNil(try E2EFixture.parseForLaunch(arguments: ["Player"]))
      XCTAssertNil(try E2EFixture.parseForLaunch(arguments: [
        "Player", "-e2e-fixture", E2EFixture.bookmarks.rawValue,
      ]))
    }

    func testE2EModeRequiresExactlyOneFixtureMarkerAndValue() {
      let invalidArguments = [
        ["Player", "-e2e"],
        ["Player", "-e2e", "-e2e-fixture"],
        ["Player", "-e2e", "-e2e-fixture", "-e2e-reset"],
        ["Player", "-e2e", "-e2e-fixture", ""],
        ["Player", "-e2e", "-e2e-fixture", "unknown-fixture"],
        [
          "Player", "-e2e", "-e2e-fixture", E2EFixture.bookmarks.rawValue,
          "-e2e-fixture", E2EFixture.sleepTimer.rawValue,
        ],
      ]

      for arguments in invalidArguments {
        XCTAssertThrowsError(try E2EFixture.parseForLaunch(arguments: arguments), "\(arguments)")
      }
    }
  }

  final class E2ESafeZIPArgumentsTests: XCTestCase {
    func testCanonicalCasesAndOptionalInspectionFailureParseExactly() throws {
      for archiveCase in E2ESafeZIPArguments.ArchiveCase.allCases {
        let parsed = try E2ESafeZIPArguments.parse(arguments: canonicalArguments(
          archiveCase: archiveCase
        ))
        XCTAssertEqual(parsed.archiveCase, archiveCase)
        XCTAssertEqual(
          parsed.limits,
          E2ESafeZIPArguments.Limits(
            maximumEntryCount: 32,
            maximumEntryBytes: 131_072,
            maximumEntryExpansionRatio: 20
          )
        )
        XCTAssertNil(parsed.failOnce)
      }

      let retry = try E2ESafeZIPArguments.parse(arguments: canonicalArguments(
        archiveCase: .valid,
        suffix: ["-e2e-zip-fail-once", "inspection"]
      ))
      XCTAssertEqual(retry.failOnce, .inspection)
    }

    func testCaseAndLimitsAreRequiredExactlyOnceWithNonOptionValues() {
      let invalidArguments = [
        ["Player", "-e2e-zip-limits", "32,131072,20"],
        ["Player", "-e2e-zip-case", "-e2e-zip-limits", "32,131072,20"],
        ["Player", "-e2e-zip-case", "", "-e2e-zip-limits", "32,131072,20"],
        ["Player", "-e2e-zip-case", "unknown", "-e2e-zip-limits", "32,131072,20"],
        [
          "Player", "-e2e-zip-case", "valid", "-e2e-zip-case", "size",
          "-e2e-zip-limits", "32,131072,20",
        ],
        ["Player", "-e2e-zip-case", "valid"],
        ["Player", "-e2e-zip-case", "valid", "-e2e-zip-limits"],
        ["Player", "-e2e-zip-case", "valid", "-e2e-zip-limits", "-e2e-reset"],
        ["Player", "-e2e-zip-case", "valid", "-e2e-zip-limits", ""],
        [
          "Player", "-e2e-zip-case", "valid", "-e2e-zip-limits", "32,131072,20",
          "-e2e-zip-limits", "16,65536,10",
        ],
      ]

      for arguments in invalidArguments {
        XCTAssertThrowsError(
          try E2ESafeZIPArguments.parse(arguments: arguments),
          "Expected invalid Safe ZIP arguments to be rejected: \(arguments)"
        )
      }
    }

    func testLimitsRejectMalformedNonFiniteFractionalAndNonPositiveValues() {
      let invalidLimits = [
        "32,131072",
        "32,131072,20,1",
        "32,,20",
        ",131072,20",
        "32,131072,",
        "thirty,131072,20",
        "32, 131072,20",
        "32.5,131072,20",
        "32,131072.5,20",
        "0,131072,20",
        "32,0,20",
        "32,131072,0",
        "-1,131072,20",
        "32,-1,20",
        "32,131072,-1",
        "32,131072,nan",
        "32,131072,inf",
        "32,131072,2e1",
        "999999999999999999999999999999999999,131072,20",
        "32,999999999999999999999999999999999999,20",
      ]

      for limits in invalidLimits {
        XCTAssertThrowsError(
          try E2ESafeZIPArguments.parse(arguments: [
            "Player", "-e2e-zip-case", "valid", "-e2e-zip-limits", limits,
          ]),
          "Expected invalid Safe ZIP limits to be rejected: \(limits)"
        )
      }
    }

    func testFailOnceIsOptionalButStrictAndOnlyValidForTheValidArchive() throws {
      XCTAssertNil(
        try E2ESafeZIPArguments.parse(arguments: canonicalArguments(archiveCase: .valid)).failOnce
      )

      let invalidSuffixes = [
        ["-e2e-zip-fail-once"],
        ["-e2e-zip-fail-once", "-e2e-reset"],
        ["-e2e-zip-fail-once", ""],
        ["-e2e-zip-fail-once", "unknown"],
        [
          "-e2e-zip-fail-once", "inspection",
          "-e2e-zip-fail-once", "inspection",
        ],
      ]
      for suffix in invalidSuffixes {
        XCTAssertThrowsError(
          try E2ESafeZIPArguments.parse(arguments: canonicalArguments(
            archiveCase: .valid,
            suffix: suffix
          )),
          "Expected invalid fail-once arguments to be rejected: \(suffix)"
        )
      }

      XCTAssertThrowsError(
        try E2ESafeZIPArguments.parse(arguments: canonicalArguments(
          archiveCase: .traversal,
          suffix: ["-e2e-zip-fail-once", "inspection"]
        ))
      )
    }

    private func canonicalArguments(
      archiveCase: E2ESafeZIPArguments.ArchiveCase,
      suffix: [String] = []
    ) -> [String] {
      [
        "Player", "-e2e", "-e2e-fixture", "safe-zip-import",
        "-e2e-zip-case", archiveCase.rawValue,
        "-e2e-zip-limits", "32,131072,20",
        "-AppleLanguages", "(en)",
      ] + suffix
    }
  }

  final class E2EMetadataRichBookNamespaceTests: XCTestCase {
    func testDefaultNamespacePreservesTheCanonicalRoot() throws {
      let support = URL(fileURLWithPath: "/fixture-support", isDirectory: true)
      let namespace = try E2EMetadataRichBookNamespace.parse(arguments: ["-e2e"])
      let root = E2EMetadataRichBookNamespace.root(in: support, namespace: namespace)

      XCTAssertEqual(namespace, "default")
      XCTAssertEqual(root.path, "/fixture-support/PlayerE2EMetadataRichBook")
    }

    func testValidDedicatedNamespaceProducesOneConfinedChildRoot() throws {
      let support = URL(fileURLWithPath: "/fixture-support", isDirectory: true)
      let namespace = try E2EMetadataRichBookNamespace.parse(arguments: [
        "-e2e", "-e2e-metadata-rich-namespace", "accessibility-preferences-persistence",
      ])
      let root = E2EMetadataRichBookNamespace.root(in: support, namespace: namespace)

      XCTAssertEqual(namespace, "accessibility-preferences-persistence")
      XCTAssertEqual(root.deletingLastPathComponent(), support)
      XCTAssertEqual(
        root.lastPathComponent,
        "PlayerE2EMetadataRichBook-accessibility-preferences-persistence"
      )
    }

    func testMalformedMissingAndDuplicateNamespacesAreRejected() {
      let invalidArguments = [
        ["-e2e-metadata-rich-namespace"],
        ["-e2e-metadata-rich-namespace", "UPPERCASE"],
        ["-e2e-metadata-rich-namespace", "-leading"],
        ["-e2e-metadata-rich-namespace", "trailing-"],
        ["-e2e-metadata-rich-namespace", "path/traversal"],
        ["-e2e-metadata-rich-namespace", "contains.dot"],
        ["-e2e-metadata-rich-namespace", "line\nbreak"],
        ["-e2e-metadata-rich-namespace", String(repeating: "a", count: 65)],
        [
          "-e2e-metadata-rich-namespace", "first",
          "-e2e-metadata-rich-namespace", "second",
        ],
      ]

      for arguments in invalidArguments {
        XCTAssertThrowsError(
          try E2EMetadataRichBookNamespace.parse(arguments: arguments),
          "Expected invalid namespace arguments to be rejected: \(arguments)"
        )
      }
    }
  }
#endif
