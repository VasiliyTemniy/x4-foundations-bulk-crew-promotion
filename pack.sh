#!/usr/bin/env bash
set -euo pipefail

MOD="vas_bulk_crew_promotion"
ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG="$ROOT/packages/$MOD"
TS="$(date +%d-%m-%Y_%H%M%S)"
ZIP="$ROOT/packages/${MOD}_${TS}.zip"

rm -rf "$PKG"
mkdir -p "$PKG"

cp -a "$ROOT/src/." "$PKG/"

(cd "$ROOT/packages" && zip -r -9 "$ZIP" "$MOD")

echo "Packed: $ZIP"
