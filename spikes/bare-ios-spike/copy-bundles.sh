#!/bin/bash
# Build-phase script: copies the packed bare bundles into the app bundle.
# Inputs are built by `npm run bundle` (bare-pack). Run as a Run Script
# phase AFTER "Compile Sources" — or manually before installing.
#
#   copy-bundles.sh "$BUILT_PRODUCTS_DIR/$PRODUCT_NAME.app"
set -euo pipefail
APP="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"

for f in bare-ios-sim.bundle bare-ios.bundle bare-universal.bundle; do
  if [ -f "$DIR/$f" ]; then
    cp "$DIR/$f" "$APP/"
    echo "copied $f"
  fi
done
echo "bundle copy complete"
