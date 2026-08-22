#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
web_dir="$(cd "${script_dir}/../ReceiverWeb" && pwd)"

cd "${web_dir}"
npm ci --ignore-scripts --no-audit --no-fund
npm run check
npm run build
