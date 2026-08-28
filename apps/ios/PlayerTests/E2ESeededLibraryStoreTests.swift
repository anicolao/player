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
