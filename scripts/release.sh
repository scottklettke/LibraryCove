#!/bin/bash
# LibraryCove release helper: one command bumps the version everywhere it
# lives, so the changelog, Info.plist, and Xcode can never disagree.
#
#   scripts/release.sh 0.5.3        # minor dot release (build number auto-increments)
#   scripts/release.sh 0.6 42      # major release with an explicit build number
#
# Steps: rewrite CFBundleShortVersionString/CFBundleVersion in project.yml,
# regenerate the project (xcodegen), date the CHANGELOG.md "## Unreleased"
# section (or the top section if it's already dated), and verify everything
# agrees. It does NOT commit — review the diff, then commit and push.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: scripts/release.sh <version> [build-number]" >&2
  exit 2
fi

version="$1"
build="${2:-}"

# Version shape guard: dot releases (0.5.1) and majors (0.6), nothing else.
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
  echo "error: version '$version' is not <major>.<minor>[.<patch>]" >&2
  exit 2
fi

# Build number: explicit argument, else current + 1.
if [[ -z "$build" ]]; then
  current=$(grep -m1 'CFBundleVersion:' project.yml | grep -oE '[0-9]+')
  build=$((current + 1))
fi

echo "→ project.yml: CFBundleShortVersionString $version, CFBundleVersion $build"
python3 - "$version" "$build" <<'EOF'
import re, sys
version, build = sys.argv[1], sys.argv[2]
path = "project.yml"
text = open(path).read()
text, n1 = re.subn(r'(CFBundleShortVersionString:\s*)"[^"]+"', rf'\g<1>"{version}"', text)
text, n2 = re.subn(r'(CFBundleVersion:\s*)"[^"]+"', rf'\g<1>"{build}"', text)
if n1 != 1 or n2 != 1:
    sys.exit("error: project.yml version keys not found/unique")
open(path, "w").write(text)
EOF

echo "→ xcodegen"
xcodegen

echo "→ CHANGELOG.md"
today=$(date +%F)
python3 - "$version" "$today" <<'EOF'
import re, sys
version, today = sys.argv[1], sys.argv[2]
path = "CHANGELOG.md"
text = open(path).read()
heading = f"## {version} ({today})"
# Already dated with the target version → nothing to do (idempotent rerun).
if re.search(rf'^## {re.escape(version)} \(\d{{4}}-\d{{2}}-\d{{2}}\)', text, re.M):
    print("  top section already dated as", heading)
else:
    if "## Unreleased" in text:
        # Date the pending section...
        text = text.replace("## Unreleased", heading, 1)
    else:
        # ...or start a new one above the previous release.
        m = re.search(r'^## \d', text, re.M)
        if not m:
            sys.exit("error: CHANGELOG.md has no release sections")
        text = text[:m.start()] + heading + "\n\n### Changed\n\n- (fill in)\n" + text[m.start():]
    open(path, "w").write(text)
    print("  dated top section as", heading)
EOF

# Verify all three agree before handing back to the user.
echo "→ verify"
plist_check=$(plutil -extract CFBundleShortVersionString raw LibraryCove/Info.plist)
[[ "$plist_check" == "$version" ]] || { echo "MISMATCH: Info.plist says $plist_check, wanted $version" >&2; exit 1; }
build_check=$(plutil -extract CFBundleVersion raw LibraryCove/Info.plist)
[[ "$build_check" == "$build" ]] || { echo "MISMATCH: Info.plist build says $build_check, wanted $build" >&2; exit 1; }
head1=$(grep -m1 '^## ' CHANGELOG.md)
case "$head1" in
  "## $version "*) ;;
  *) echo "MISMATCH: CHANGELOG.md top section '$head1' ≠ $version" >&2; exit 1 ;;
esac

echo
echo "Release $version (build $build) staged:"
echo "  project.yml, LibraryCove.xcodeproj, LibraryCove/Info.plist, CHANGELOG.md"
echo "Fill in the changelog section, then commit and push."
