#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="${script_dir}/../verify-e2e-hygiene.sh"
ui_test_root="${script_dir}/../../PlayerUITests"
temporary_root="$(mktemp -d /tmp/player-capture-readiness-test.XXXXXX)"
trap 'rm -rf "${temporary_root}"' EXIT

valid_root="${temporary_root}/valid"
invalid_root="${temporary_root}/invalid"
mkdir -p "${valid_root}" "${invalid_root}"

cat > "${valid_root}/ValidUITests.swift" <<'SWIFT'
final class ValidUITests {
  func testValidCaptures() throws {
    try tester.step(
      "first",
      description: "captureReadiness: in a string is irrelevant",
      verifications: [
        StepVerification(specification: "nested") { true },
      ],
      captureReadiness: CaptureReadiness(specification: "ready", anchor: anchor) {
        true
      }
    )
    try tester.step("second", description: "ready", verifications: [], captureReadiness: gate)
  }
}
SWIFT

cat > "${invalid_root}/MissingCaptureUITests.swift" <<'SWIFT'
final class MissingCaptureUITests {
  func testMissingGate() throws {
    try tester.step(
      "missing",
      description: "captureReadiness: text must not satisfy hygiene",
      verifications: [
        StepVerification(specification: "nested") {
          let captureReadiness: Bool = true
          return captureReadiness
        },
      ]
    )
  }
}
SWIFT

"${checker}" --check-capture-readiness-root "${valid_root}" \
  > "${temporary_root}/valid.log"
rg -q 'Capture readiness hygiene passed for 2 tester.step calls' \
  "${temporary_root}/valid.log"

if "${checker}" --check-capture-readiness-root "${invalid_root}" \
  > "${temporary_root}/invalid.log" 2>&1; then
  echo "capture-readiness hygiene accepted a tester.step call without a gate" >&2
  exit 1
fi
rg -q 'MissingCaptureUITests.swift:3: tester.step screenshot is missing top-level captureReadiness:' \
  "${temporary_root}/invalid.log"

"${checker}" --check-capture-readiness-root "${ui_test_root}" \
  > "${temporary_root}/current.log"
rg -q 'Capture readiness hygiene passed for [1-9][0-9]* tester.step calls' \
  "${temporary_root}/current.log"

echo "Capture-readiness source hygiene tests passed."
