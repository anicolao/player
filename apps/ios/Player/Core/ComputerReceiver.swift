import Foundation
import Network
import OSLog

struct DirectImportOutcome: Sendable, Equatable {
  enum State: String, Sendable {
    case completed
    case needsReview
    case failed
  }

  var state: State
  var message: String
  var addedBookCount: Int
  var cleanupIncomingFiles: Bool
}

enum ComputerReceiverEvent: Sendable, Equatable {
  case ready(address: String, pairingCode: String)
  case connected(clientName: String)
  case receiving(name: String, completedBytes: Int64, totalBytes: Int64)
  case importing(name: String)
  case completed(message: String, addedBookCount: Int)
  case needsReview(message: String)
  case failed(message: String)
  case stopped
}

struct ComputerReceiverReady: Sendable, Equatable {
  var address: String
  var pairingCode: String
}

actor ComputerImportStore {
  struct Entry: Codable, Sendable, Equatable {
    var path: String
    var byteCount: Int64
  }

  struct CreateRequest: Codable, Sendable {
    var entries: [Entry]
    var selectionKind: String?
    var selectionName: String?
  }

  struct Created: Sendable {
    var id: UUID
    var displayName: String
    var totalBytes: Int64
  }

  struct WriteTarget: Sendable {
    var partialURL: URL
    var finalURL: URL
    var expectedBytes: Int64
    var displayName: String
    var completedBefore: Int64
    var totalBytes: Int64
  }

  struct Status: Sendable {
    var state: String
    var message: String
    var displayName: String
    var addedBookCount: Int
    var completedBytes: Int64
    var totalBytes: Int64
  }

  private struct StoredEntry: Sendable {
    var manifest: Entry
    var finalURL: URL
    var isComplete: Bool
  }

  private struct Session: Sendable {
    var id: UUID
    var rootURL: URL
    var selectionURL: URL
    var selectionKind: String
    var displayName: String
    var entries: [StoredEntry]
    var state: String
    var message: String
    var addedBookCount: Int
    var receivedBytes: Int64
  }

  static let maximumEntries = 20_000
  static let maximumManifestBytes = 2 * 1_024 * 1_024
  private static let supportedExtensions: Set<String> = ["m4a", "m4b", "mp3", "zip"]

  private let rootURL: URL
  private let fileManager: FileManager
  private var sessions: [UUID: Session] = [:]

  init(rootURL: URL, fileManager: FileManager = .default) {
    self.rootURL = rootURL.standardizedFileURL
    self.fileManager = fileManager
    try? fileManager.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
  }

  func create(_ request: CreateRequest) throws -> Created {
    guard !request.entries.isEmpty else {
      throw ComputerReceiverError.invalidSelection("No supported audiobook files were found.")
    }
    guard request.entries.count <= Self.maximumEntries else {
      throw ComputerReceiverError.invalidSelection("This selection contains too many files.")
    }
    let paths = request.entries.map(\.path)
    guard Set(paths).count == paths.count else {
      throw ComputerReceiverError.invalidSelection("The selection contains duplicate file paths.")
    }
    let zipCount = request.entries.filter {
      URL(filePath: $0.path).pathExtension.lowercased() == "zip"
    }.count
    guard zipCount == 0 || (zipCount == 1 && request.entries.count == 1) else {
      throw ComputerReceiverError.invalidSelection("Send one ZIP archive at a time.")
    }

    let kind = request.selectionKind == "folder" ? "folder" : "files"
    let requestedName = sanitizedDisplayName(request.selectionName)
    let displayName = requestedName
      ?? (request.entries.count == 1
        ? URL(filePath: request.entries[0].path).deletingPathExtension().lastPathComponent
        : "\(request.entries.count) audio files")
    let id = UUID()
    let sessionRoot = rootURL.appending(path: id.uuidString.lowercased(), directoryHint: .isDirectory)
    let payloadRoot = sessionRoot.appending(path: "Payload", directoryHint: .isDirectory)
    let selectionURL = kind == "folder"
      ? payloadRoot.appending(path: sanitizedPathComponent(displayName), directoryHint: .isDirectory)
      : payloadRoot
    try fileManager.createDirectory(at: selectionURL, withIntermediateDirectories: true)

    var totalBytes: Int64 = 0
    var storedEntries: [StoredEntry] = []
    var canonicalPaths = Set<String>()
    do {
      for entry in request.entries {
        guard entry.byteCount >= 0 else {
          throw ComputerReceiverError.invalidSelection("A file has an invalid size.")
        }
        let relativePath = try validatedRelativePath(entry.path)
        let canonicalPath = relativePath
          .precomposedStringWithCanonicalMapping
          .folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
          )
        guard canonicalPaths.insert(canonicalPath).inserted else {
          throw ComputerReceiverError.invalidSelection(
            "Two files would have the same name on this iPhone."
          )
        }
        let fileExtension = URL(filePath: relativePath).pathExtension.lowercased()
        guard Self.supportedExtensions.contains(fileExtension) else {
          throw ComputerReceiverError.invalidSelection(
            "\(URL(filePath: relativePath).lastPathComponent) is not a supported audiobook file."
          )
        }
        let (sum, overflow) = totalBytes.addingReportingOverflow(entry.byteCount)
        guard !overflow else {
          throw ComputerReceiverError.invalidSelection("The selection is too large.")
        }
        totalBytes = sum
        let finalURL = selectionURL.appending(path: relativePath)
        guard finalURL.standardizedFileURL.path.hasPrefix(selectionURL.standardizedFileURL.path + "/") else {
          throw ComputerReceiverError.invalidSelection("A file path leaves the import folder.")
        }
        storedEntries.append(StoredEntry(
          manifest: Entry(path: relativePath, byteCount: entry.byteCount),
          finalURL: finalURL,
          isComplete: false
        ))
      }
      if let available = try rootURL.resourceValues(
        forKeys: [.volumeAvailableCapacityForImportantUsageKey]
      ).volumeAvailableCapacityForImportantUsage {
        let reserve: Int64 = 256 * 1_024 * 1_024
        // Receiver files are adopted into durable staging with same-volume hard
        // links. Only the incoming bytes plus a safety reserve are required.
        let required = totalBytes.addingReportingOverflow(reserve)
        guard !required.overflow, required.partialValue <= available else {
          throw ComputerReceiverError.invalidSelection(
            "This iPhone does not have enough free space for that selection."
          )
        }
      }
    } catch {
      try? fileManager.removeItem(at: sessionRoot)
      throw error
    }

    sessions[id] = Session(
      id: id,
      rootURL: sessionRoot,
      selectionURL: selectionURL,
      selectionKind: kind,
      displayName: displayName,
      entries: storedEntries,
      state: "receiving",
      message: "Waiting for files…",
      addedBookCount: 0,
      receivedBytes: 0
    )
    return Created(id: id, displayName: displayName, totalBytes: totalBytes)
  }

  func writeTarget(sessionID: UUID, index: Int) throws -> WriteTarget {
    guard let session = sessions[sessionID] else { throw ComputerReceiverError.importNotFound }
    guard session.state == "receiving" else { throw ComputerReceiverError.importAlreadySealed }
    guard session.entries.indices.contains(index) else { throw ComputerReceiverError.fileNotFound }
    let entry = session.entries[index]
    guard !entry.isComplete else { throw ComputerReceiverError.fileAlreadyReceived }
    let partialURL = entry.finalURL.appendingPathExtension("partial")
    try fileManager.createDirectory(
      at: entry.finalURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if fileManager.fileExists(atPath: partialURL.path) { try fileManager.removeItem(at: partialURL) }
    let completedBefore = session.entries.reduce(Int64(0)) {
      $0 + ($1.isComplete ? $1.manifest.byteCount : 0)
    }
    let totalBytes = session.entries.reduce(Int64(0)) { $0 + $1.manifest.byteCount }
    return WriteTarget(
      partialURL: partialURL,
      finalURL: entry.finalURL,
      expectedBytes: entry.manifest.byteCount,
      displayName: session.displayName,
      completedBefore: completedBefore,
      totalBytes: totalBytes
    )
  }

  func finishWrite(sessionID: UUID, index: Int, receivedBytes: Int64) throws {
    guard var session = sessions[sessionID] else { throw ComputerReceiverError.importNotFound }
    guard session.entries.indices.contains(index) else { throw ComputerReceiverError.fileNotFound }
    var entry = session.entries[index]
    let partialURL = entry.finalURL.appendingPathExtension("partial")
    guard receivedBytes == entry.manifest.byteCount else {
      try? fileManager.removeItem(at: partialURL)
      throw ComputerReceiverError.byteCountMismatch(
        expected: entry.manifest.byteCount,
        received: receivedBytes
      )
    }
    if fileManager.fileExists(atPath: entry.finalURL.path) { try fileManager.removeItem(at: entry.finalURL) }
    try fileManager.moveItem(at: partialURL, to: entry.finalURL)
    entry.isComplete = true
    session.entries[index] = entry
    let completedCount = session.entries.filter(\.isComplete).count
    session.receivedBytes = session.entries.reduce(Int64(0)) {
      $0 + ($1.isComplete ? $1.manifest.byteCount : 0)
    }
    session.message = "Received \(completedCount) of \(session.entries.count) files"
    sessions[sessionID] = session
  }

  func updateProgress(sessionID: UUID, fileBytes: Int64, completedBefore: Int64) {
    guard var session = sessions[sessionID], session.state == "receiving" else { return }
    let total = session.entries.reduce(Int64(0)) { $0 + $1.manifest.byteCount }
    session.receivedBytes = min(total, max(0, completedBefore + fileBytes))
    sessions[sessionID] = session
  }

  func seal(sessionID: UUID) throws -> (urls: [URL], displayName: String) {
    guard var session = sessions[sessionID] else { throw ComputerReceiverError.importNotFound }
    guard session.state == "receiving" else { throw ComputerReceiverError.importAlreadySealed }
    guard session.entries.allSatisfy(\.isComplete) else {
      throw ComputerReceiverError.invalidSelection("Some files have not finished uploading.")
    }
    session.state = "importing"
    session.message = "Player is checking your files…"
    sessions[sessionID] = session
    let urls = session.selectionKind == "folder"
      ? [session.selectionURL]
      : session.entries.map(\.finalURL)
    return (urls, session.displayName)
  }

  func finish(sessionID: UUID, outcome: DirectImportOutcome) {
    guard var session = sessions[sessionID] else { return }
    session.state = outcome.state.rawValue
    session.message = outcome.message
    session.addedBookCount = outcome.addedBookCount
    sessions[sessionID] = session
    if outcome.cleanupIncomingFiles {
      try? fileManager.removeItem(at: session.rootURL)
    }
  }

  func status(sessionID: UUID) throws -> Status {
    guard let session = sessions[sessionID] else { throw ComputerReceiverError.importNotFound }
    return Status(
      state: session.state,
      message: session.message,
      displayName: session.displayName,
      addedBookCount: session.addedBookCount,
      completedBytes: session.receivedBytes,
      totalBytes: session.entries.reduce(Int64(0)) { $0 + $1.manifest.byteCount }
    )
  }

  func cancel(sessionID: UUID) throws {
    guard let session = sessions[sessionID] else { throw ComputerReceiverError.importNotFound }
    guard session.state != "importing" else { throw ComputerReceiverError.importAlreadySealed }
    sessions[sessionID] = nil
    try? fileManager.removeItem(at: session.rootURL)
  }

  func cleanupReceivingSessions() {
    let receiving = sessions.values.filter { $0.state == "receiving" }
    for session in receiving {
      try? fileManager.removeItem(at: session.rootURL)
      sessions[session.id] = nil
    }
  }

  private func validatedRelativePath(_ path: String) throws -> String {
    guard !path.isEmpty, path.utf8.count <= 2_048, !path.hasPrefix("/"), !path.hasPrefix("\\") else {
      throw ComputerReceiverError.invalidSelection("A file has an invalid path.")
    }
    let normalized = path.replacingOccurrences(of: "\\", with: "/")
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard !components.isEmpty, components.allSatisfy({ component in
      !component.isEmpty
        && component != "."
        && component != ".."
        && !component.unicodeScalars.contains(where: { $0.value < 32 })
    }) else {
      throw ComputerReceiverError.invalidSelection("A file path could leave the import folder.")
    }
    return components.joined(separator: "/")
  }

  private func sanitizedDisplayName(_ name: String?) -> String? {
    guard let name else { return nil }
    let last = URL(filePath: name).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return last.isEmpty ? nil : String(last.prefix(180))
  }

  private func sanitizedPathComponent(_ value: String) -> String {
    let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.controlCharacters)
    let cleaned = value.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
    let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed != ".", trimmed != ".." else { return "Computer Import" }
    return String(trimmed.prefix(180))
  }
}

actor ComputerReceiverServer {
  typealias ImportHandler = @MainActor @Sendable ([URL]) async -> DirectImportOutcome
  typealias EventHandler = @MainActor @Sendable (ComputerReceiverEvent) -> Void

  private let queue = DispatchQueue(label: "com.spnss.player.computer-receiver")
  private let logger = Logger(subsystem: "com.spnss.player", category: "ComputerReceiver")
  private let store: ComputerImportStore
  private let bundle: Bundle
  private var listener: NWListener?
  private var pairingCode = ""
  private var bearerToken = ""
  private var importHandler: ImportHandler?
  private var eventHandler: EventHandler?
  private var startContinuation: CheckedContinuation<UInt16, any Error>?
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  private var activeImports: [UUID: Task<Void, Never>] = [:]
  private var failedPairingAttempts = 0
  private var pairedClientName = "Computer"

  init(rootURL: URL, bundle: Bundle = .main) {
    store = ComputerImportStore(rootURL: rootURL)
    self.bundle = bundle
  }

  func start(importHandler: @escaping ImportHandler, eventHandler: @escaping EventHandler) async throws -> ComputerReceiverReady {
    if listener != nil { throw ComputerReceiverError.alreadyRunning }
    self.importHandler = importHandler
    self.eventHandler = eventHandler
    pairingCode = String(format: "%06d", Int.random(in: 0...999_999))
    bearerToken = Self.randomToken()
    failedPairingAttempts = 0

    let listener = try NWListener(using: .tcp, on: .any)
    listener.service = NWListener.Service(name: "Player", type: "_player-import._tcp")
    listener.newConnectionHandler = { [weak self] connection in
      Task { await self?.accept(connection) }
    }
    listener.stateUpdateHandler = { [weak self, weak listener] state in
      switch state {
      case .ready:
        guard let port = listener?.port?.rawValue else { return }
        Task { await self?.listenerReady(port: port) }
      case .failed(let error):
        Task { await self?.listenerFailed(message: error.localizedDescription) }
      default:
        break
      }
    }
    self.listener = listener
    let port = try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<UInt16, any Error>) in
      startContinuation = continuation
      listener.start(queue: queue)
    }
    let host = Self.localAddress() ?? ProcessInfo.processInfo.hostName
    let formattedHost = host.contains(":") ? "[\(host)]" : host
    let address = "http://\(formattedHost):\(port)"
    let ready = ComputerReceiverReady(address: address, pairingCode: pairingCode)
    await eventHandler(.ready(address: address, pairingCode: pairingCode))
    return ready
  }

  func stop() async {
    listener?.cancel()
    listener = nil
    for connection in connections.values { connection.cancel() }
    connections.removeAll()
    await store.cleanupReceivingSessions()
    importHandler = nil
    startContinuation = nil
    await eventHandler?(.stopped)
    eventHandler = nil
  }

  private func listenerReady(port: UInt16) {
    startContinuation?.resume(returning: port)
    startContinuation = nil
  }

  private func listenerFailed(message: String) {
    listener = nil
    startContinuation?.resume(throwing: ComputerReceiverError.listenerFailed(message))
    startContinuation = nil
  }

  private func accept(_ connection: NWConnection) async {
    guard connections.count < 8 else {
      connection.cancel()
      return
    }
    let id = ObjectIdentifier(connection)
    connections[id] = connection
    connection.start(queue: queue)
    await handle(connection)
    connections[id] = nil
  }

  private func handle(_ connection: NWConnection) async {
    do {
      let request = try await HTTPRequest.read(from: connection)
      let response = try await route(request, connection: connection)
      try await response.send(to: connection)
    } catch {
      let response = HTTPResponse.json(
        status: error.httpStatus,
        object: ["message": error.localizedDescription]
      )
      try? await response.send(to: connection)
    }
    connection.cancel()
  }

  private func route(_ request: HTTPRequest, connection: NWConnection) async throws -> HTTPResponse {
    if request.method == "GET", !request.path.hasPrefix("/api/") {
      return try staticResponse(path: request.path)
    }
    if request.method == "POST", request.path == "/api/pair" {
      let body = try await request.bodyData(from: connection, maximumBytes: 4_096)
      let supplied = try JSONDecoder().decode(PairRequest.self, from: body).code
      guard failedPairingAttempts < 5, supplied == pairingCode else {
        failedPairingAttempts += 1
        throw ComputerReceiverError.invalidPairingCode
      }
      let clientName = request.headers["x-player-client-name"] ?? "Computer"
      pairedClientName = String(clientName.prefix(80))
      await eventHandler?(.connected(clientName: pairedClientName))
      return .json(status: 200, object: [
        "token": bearerToken,
        "deviceName": "iPhone",
      ])
    }
    try authorize(request)

    if request.method == "POST", request.path == "/api/imports" {
      let body = try await request.bodyData(
        from: connection,
        maximumBytes: ComputerImportStore.maximumManifestBytes
      )
      let created = try await store.create(JSONDecoder().decode(
        ComputerImportStore.CreateRequest.self,
        from: body
      ))
      return .json(status: 201, object: ["id": created.id.uuidString.lowercased()])
    }

    let components = request.path.split(separator: "/").map(String.init)
    guard components.count >= 3, components[0] == "api", components[1] == "imports",
      let sessionID = UUID(uuidString: components[2])
    else { throw ComputerReceiverError.routeNotFound }

    if request.method == "PUT", components.count == 5, components[3] == "files",
      let index = Int(components[4])
    {
      let target = try await store.writeTarget(sessionID: sessionID, index: index)
      guard request.contentLength == target.expectedBytes else {
        throw ComputerReceiverError.byteCountMismatch(
          expected: target.expectedBytes,
          received: request.contentLength
        )
      }
      let received = try await request.streamBody(
        from: connection,
        to: target.partialURL,
        progress: { [weak self] fileBytes in
          guard let self else { return }
          let completed = target.completedBefore + fileBytes
          await self.store.updateProgress(
            sessionID: sessionID,
            fileBytes: fileBytes,
            completedBefore: target.completedBefore
          )
          await self.publish(.receiving(
            name: target.displayName,
            completedBytes: completed,
            totalBytes: target.totalBytes
          ))
        }
      )
      try await store.finishWrite(sessionID: sessionID, index: index, receivedBytes: received)
      return .json(status: 200, object: ["received": received])
    }

    if request.method == "POST", components.count == 4, components[3] == "complete" {
      let sealed = try await store.seal(sessionID: sessionID)
      await eventHandler?(.importing(name: sealed.displayName))
      guard let importHandler else { throw ComputerReceiverError.listenerStopped }
      logger.info("Starting durable import for receiver session \(sessionID.uuidString, privacy: .public)")
      let task = Task.detached(priority: .userInitiated) { [self] in
        let outcome = await importHandler(sealed.urls)
        await finishImport(sessionID: sessionID, outcome: outcome)
      }
      activeImports[sessionID] = task
      return .json(status: 202, object: ["state": "importing"])
    }

    if request.method == "GET", components.count == 3 {
      let status = try await store.status(sessionID: sessionID)
      return .json(status: 200, object: [
        "state": status.state,
        "message": status.message,
        "displayName": status.displayName,
        "addedBookCount": status.addedBookCount,
        "completedBytes": status.completedBytes,
        "totalBytes": status.totalBytes,
      ])
    }

    if request.method == "DELETE", components.count == 3 {
      try await store.cancel(sessionID: sessionID)
      return .json(status: 200, object: ["state": "cancelled"])
    }
    throw ComputerReceiverError.routeNotFound
  }

  private func finishImport(sessionID: UUID, outcome: DirectImportOutcome) async {
    activeImports[sessionID] = nil
    logger.info(
      "Finished receiver session \(sessionID.uuidString, privacy: .public) with state \(outcome.state.rawValue, privacy: .public)"
    )
    await store.finish(sessionID: sessionID, outcome: outcome)
    switch outcome.state {
    case .completed:
      await eventHandler?(.completed(
        message: outcome.message,
        addedBookCount: outcome.addedBookCount
      ))
    case .needsReview:
      await eventHandler?(.needsReview(message: outcome.message))
    case .failed:
      await eventHandler?(.failed(message: outcome.message))
    }
  }

  private func publish(_ event: ComputerReceiverEvent) async {
    await eventHandler?(event)
  }

  private func authorize(_ request: HTTPRequest) throws {
    guard request.headers["authorization"] == "Bearer \(bearerToken)" else {
      throw ComputerReceiverError.unauthorized
    }
  }

  private func staticResponse(path: String) throws -> HTTPResponse {
    let relative = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
    guard !relative.contains(".."), !relative.contains("\\"),
      let resourceRoot = bundle.resourceURL?.appending(path: "ReceiverWeb", directoryHint: .isDirectory)
    else { throw ComputerReceiverError.routeNotFound }
    let fileURL = resourceRoot.appending(path: relative).standardizedFileURL
    guard fileURL.path.hasPrefix(resourceRoot.standardizedFileURL.path + "/"),
      FileManager.default.fileExists(atPath: fileURL.path)
    else { throw ComputerReceiverError.routeNotFound }
    return HTTPResponse(
      status: 200,
      contentType: Self.contentType(for: fileURL.pathExtension),
      body: try Data(contentsOf: fileURL)
    )
  }

  private static func contentType(for extensionName: String) -> String {
    switch extensionName.lowercased() {
    case "html": "text/html; charset=utf-8"
    case "css": "text/css; charset=utf-8"
    case "js": "text/javascript; charset=utf-8"
    case "svg": "image/svg+xml"
    case "png": "image/png"
    default: "application/octet-stream"
    }
  }

  private static func randomToken() -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
    return Data(bytes).base64EncodedString()
      .replacingOccurrences(of: "+", with: "-")
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "=", with: "")
  }

  private static func localAddress() -> String? {
    var pointer: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
    defer { freeifaddrs(pointer) }
    var current: UnsafeMutablePointer<ifaddrs>? = first
    while let interface = current?.pointee {
      defer { current = interface.ifa_next }
      guard String(cString: interface.ifa_name) == "en0",
        let address = interface.ifa_addr,
        address.pointee.sa_family == UInt8(AF_INET)
      else { continue }
      var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      let result = getnameinfo(
        address,
        socklen_t(address.pointee.sa_len),
        &hostname,
        socklen_t(hostname.count),
        nil,
        0,
        NI_NUMERICHOST
      )
      if result == 0 {
        let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
      }
    }
    return nil
  }
}

private struct PairRequest: Decodable {
  var code: String
}

private struct HTTPRequest {
  var method: String
  var path: String
  var headers: [String: String]
  var contentLength: Int64
  var initialBody: Data

  static func read(from connection: NWConnection) async throws -> HTTPRequest {
    var accumulated = Data()
    let separator = Data("\r\n\r\n".utf8)
    while accumulated.range(of: separator) == nil {
      guard let chunk = try await connection.receiveData(maximumLength: 64 * 1_024) else {
        throw ComputerReceiverError.invalidRequest
      }
      accumulated.append(chunk)
      guard accumulated.count <= 64 * 1_024 else { throw ComputerReceiverError.headerTooLarge }
    }
    guard let range = accumulated.range(of: separator),
      let headerText = String(data: accumulated[..<range.lowerBound], encoding: .utf8)
    else { throw ComputerReceiverError.invalidRequest }
    let lines = headerText.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { throw ComputerReceiverError.invalidRequest }
    let requestParts = requestLine.split(separator: " ")
    guard requestParts.count == 3 else { throw ComputerReceiverError.invalidRequest }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      guard let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers[key] = value
    }
    let contentLength = Int64(headers["content-length"] ?? "0") ?? 0
    guard contentLength >= 0 else { throw ComputerReceiverError.invalidRequest }
    return HTTPRequest(
      method: String(requestParts[0]),
      path: String(requestParts[1]).components(separatedBy: "?")[0],
      headers: headers,
      contentLength: contentLength,
      initialBody: Data(accumulated[range.upperBound...])
    )
  }

  func bodyData(from connection: NWConnection, maximumBytes: Int) async throws -> Data {
    guard contentLength <= Int64(maximumBytes) else { throw ComputerReceiverError.bodyTooLarge }
    var body = initialBody.prefix(Int(contentLength))
    while body.count < contentLength {
      guard let chunk = try await connection.receiveData(
        maximumLength: min(64 * 1_024, Int(contentLength) - body.count)
      ) else { throw ComputerReceiverError.connectionInterrupted }
      body.append(chunk)
    }
    return Data(body)
  }

  func streamBody(
    from connection: NWConnection,
    to url: URL,
    progress: @escaping @Sendable (Int64) async -> Void
  ) async throws -> Int64 {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var received: Int64 = 0
    if !initialBody.isEmpty {
      let prefix = initialBody.prefix(Int(min(Int64(initialBody.count), contentLength)))
      try handle.write(contentsOf: prefix)
      received += Int64(prefix.count)
      await progress(received)
    }
    while received < contentLength {
      let remaining = contentLength - received
      guard let chunk = try await connection.receiveData(maximumLength: Int(min(1_024 * 1_024, remaining))) else {
        throw ComputerReceiverError.connectionInterrupted
      }
      try handle.write(contentsOf: chunk)
      received += Int64(chunk.count)
      await progress(received)
    }
    try handle.synchronize()
    return received
  }
}

private struct HTTPResponse {
  var status: Int
  var contentType: String
  var body: Data

  static func json(status: Int, object: [String: Any]) -> HTTPResponse {
    let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    return HTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: body)
  }

  func send(to connection: NWConnection) async throws {
    let reason: String = switch status {
    case 200: "OK"
    case 201: "Created"
    case 202: "Accepted"
    case 400: "Bad Request"
    case 401: "Unauthorized"
    case 404: "Not Found"
    case 409: "Conflict"
    case 413: "Payload Too Large"
    default: "Internal Server Error"
    }
    let header = """
      HTTP/1.1 \(status) \(reason)\r
      Content-Type: \(contentType)\r
      Content-Length: \(body.count)\r
      Cache-Control: no-store\r
      Content-Security-Policy: default-src 'self'; connect-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; frame-ancestors 'none'\r
      X-Content-Type-Options: nosniff\r
      Connection: close\r
      \r

      """
    var payload = Data(header.utf8)
    payload.append(body)
    try await connection.sendData(payload)
  }
}

private extension NWConnection {
  func receiveData(maximumLength: Int) async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      receive(minimumIncompleteLength: 1, maximumLength: maximumLength) {
        data, _, isComplete, error in
        if let error { continuation.resume(throwing: error) }
        else if let data, !data.isEmpty { continuation.resume(returning: data) }
        else if isComplete { continuation.resume(returning: nil) }
        else { continuation.resume(returning: nil) }
      }
    }
  }

  func sendData(_ data: Data) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      send(content: data, completion: .contentProcessed { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      })
    }
  }
}

enum ComputerReceiverError: LocalizedError {
  case alreadyRunning
  case listenerStopped
  case listenerFailed(String)
  case invalidRequest
  case headerTooLarge
  case bodyTooLarge
  case invalidPairingCode
  case unauthorized
  case routeNotFound
  case invalidSelection(String)
  case importNotFound
  case importAlreadySealed
  case fileNotFound
  case fileAlreadyReceived
  case byteCountMismatch(expected: Int64, received: Int64)
  case connectionInterrupted

  var errorDescription: String? {
    switch self {
    case .alreadyRunning: "The computer receiver is already running."
    case .listenerStopped: "The computer receiver stopped."
    case .listenerFailed(let message): "Player could not start receiving: \(message)"
    case .invalidRequest: "The computer sent an invalid request."
    case .headerTooLarge: "The request headers are too large."
    case .bodyTooLarge: "The request is too large."
    case .invalidPairingCode: "That code did not match. Check Player and try again."
    case .unauthorized: "This computer is not paired with Player."
    case .routeNotFound: "The requested receiver page was not found."
    case .invalidSelection(let message): message
    case .importNotFound: "Player no longer has this transfer."
    case .importAlreadySealed: "This transfer has already been sent to Player."
    case .fileNotFound: "Player could not match this uploaded file."
    case .fileAlreadyReceived: "Player already received this file."
    case .byteCountMismatch(let expected, let received):
      "The file was incomplete (expected \(expected) bytes, received \(received))."
    case .connectionInterrupted: "The connection ended before the file finished."
    }
  }

  var httpStatus: Int {
    switch self {
    case .invalidPairingCode, .unauthorized: 401
    case .routeNotFound, .importNotFound, .fileNotFound: 404
    case .alreadyRunning, .listenerStopped, .importAlreadySealed, .fileAlreadyReceived: 409
    case .headerTooLarge, .bodyTooLarge: 413
    case .listenerFailed: 500
    default: 400
    }
  }
}

private extension Error {
  var httpStatus: Int { (self as? ComputerReceiverError)?.httpStatus ?? 500 }
}
