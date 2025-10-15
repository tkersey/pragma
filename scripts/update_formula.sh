#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  cat <<USAGE >&2
Usage: scripts/update_formula.sh <version> <macos_url> <sha256>

Updates Formula/pragma.json with release metadata. For source-only installs, set
all fields to null (the default).
USAGE
  exit 1
fi

version="$1"
url="$2"
sha256="$3"

cat > Formula/pragma.json <<JSON
{
  "version": "${version}",
  "macos": {
    "url": "${url}",
    "sha256": "${sha256}"
  }
}
JSON

echo "Updated Formula/pragma.json"
