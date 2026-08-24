import Foundation

#if E2E
  @MainActor
  final class E2EOfflineRecoveryBridge {
    static let shared = E2EOfflineRecoveryBridge()

    private(set) var isConfigured = false
    private(set) var diagnosticsValue = "diagnostics:pending"
    private var forbiddenValues: [String] = []

    private init() {}

    func configure(forbiddenValues: [String]) {
      isConfigured = true
      diagnosticsValue = "diagnostics:pending"
      self.forbiddenValues = forbiddenValues
    }

    func verify(_ bundle: PreparedSupportBundle) throws {
      let data = try Data(contentsOf: bundle.url)
      guard let text = String(data: data, encoding: .utf8) else {
        throw PlayerCoreError.fileOperation("The support report was not UTF-8 JSON.")
      }
      guard forbiddenValues.allSatisfy({ !text.localizedCaseInsensitiveContains($0) }) else {
        throw PlayerCoreError.fileOperation("The support report exposed forbidden fixture data.")
      }
      guard !text.contains("positionMilliseconds"), !text.contains("playbackPosition"),
        !text.contains("sleepTimer")
      else {
        throw PlayerCoreError.fileOperation("The support report exposed listening history.")
      }
      let report = try JSONDecoder.playerDecoder.decode(SanitizedSupportReport.self, from: data)
      guard report.bookCount == 1, report.audioAssetCount == 1,
        report.quarantinedManagedBookCount == 1,
        report.quarantinedStagingJobCount == 1,
        report.quarantinedTrashTransactionCount == 1,
        report.localFeaturesRequireInternet == false
      else {
        throw PlayerCoreError.fileOperation(
          "The support report did not contain expected safe facts.")
      }
      diagnosticsValue = "diagnostics:sanitized=true:forbidden=absent:offline=true:quarantined=3"
    }
  }
#endif
