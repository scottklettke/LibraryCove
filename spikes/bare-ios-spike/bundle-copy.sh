#!/bin/bash
# Copies the platform bundle into the built app bundle:
#   ./bundle-copy.sh <path-to-BareSpike.app>
set -euo pipefail
APP="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
cp "$DIR/bare-ios-sim.bundle" "$APP/" 2>/dev/null || true
cp "$DIR/bare-universal.bundle" "$APP/" 2>/dev/null || true
echo "copied bundles into $APP"
