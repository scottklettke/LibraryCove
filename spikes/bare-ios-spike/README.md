# Bare iOS Spike — proven working

Embeds the Holepunch Bare runtime in a native SwiftUI app and proves the
full chain: **packed bundle → JS boots → Swift⇄JS IPC round-trip →
Hyperswarm DHT live**.

Verified on iOS simulator (2026-09-29), commit history has the full
debugging trail. The integration contract lives in the skill
`barekit-ios-integration` and the Swift source comments.

## Layout

| Path | What |
|---|---|
| `BareSpikeApp.swift` | Complete working integration (the contract in code) |
| `entry.js` | JS entry: `BareKit.IPC` ping/pong + Hyperswarm join |
| `project.yml` | XcodeGen spec — BareKit + all addon xcframeworks embedded |
| `link-addons.mjs` | Builds addon xcframeworks from node_modules via bare-link |
| `bundle-copy.sh` | Copies built bundles into the .app before install |
| `package.json` | Pinned dependency set (PearCal-compatible versions) |
| `BareKit.xcframework/` | **Committed** — bare-kit v2.5.5 prebuilds (ios slices only) |
| `addons-flat/` | **Committed** — 29 addon xcframeworks the bundle links against |
| `*.bundle` | Built artifacts (some committed for reference) |

## Reproduce from scratch

```bash
# 1. JS deps (versions pinned to match the framework's embedded runtime)
npm install

# 2. Build the iOS addons from node_modules (27 xcframeworks)
npm install --no-save bare-link
node link-addons.mjs          # writes ./addons/*.xcframework

# 3. Flatten into addons-flat/ (xcodegen dedupes same-named frameworks —
#    two bare-buffer versions MUST be separately named) + ad-hoc sign:
mkdir -p addons-flat
for fw in addons/*.xcframework; do
  name=$(basename "$fw" .xcframework)
  cp -R "$fw" "addons-flat/$name.xcframework"
done
for fw in addons-flat/*.xcframework; do
  for slice in "$fw"/*; do
    inner=$(find "$slice" -maxdepth 2 -name "*.framework" -type d 2>/dev/null | head -1)
    [ -n "$inner" ] && codesign --force --sign - "$inner"
  done
done

# 4. Bundle the JS (per-platform; --linked resolves the addons)
npx bare-pack entry.js --host ios-arm64-simulator --linked --defer fs --defer path -o bare-ios-sim.bundle
npx bare-pack entry.js --host ios-arm64 --linked --defer fs --defer path -o bare-ios.bundle

# 5. Generate + build the app
xcodegen generate
xcodebuild -project BareSpike.xcodeproj -scheme BareSpike \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

# 6. Install + run (spike.log lands in the app container Documents/)
APP=$(find ~/Library/Developer/Xcode/DerivedData/BareSpike-*/Build/Products/Debug-iphonesimulator -name "BareSpike.app" | head -1)
./bundle-copy.sh "$APP"
xcrun simctl install booted "$APP" && xcrun simctl launch booted com.librarycove.spike.bare
CONTAINER=$(xcrun simctl get_app_container booted com.librarycove.spike.bare data)
tail -20 "$CONTAINER/Documents/spike.log"
```

Expected log: `bundle loaded` → `← {"evt":"boot"}` → `← {"pong":…}` →
`← {"evt":"net","state":"ready","topic":"…"}`.

## Framework provenance

`BareKit.xcframework` = `bare-prebuilds/ios/` from
https://github.com/holepunchto/bare-kit/releases/tag/v2.5.5 (official
prebuilds.zip). Pure ObjC (`BareWorklet`/`BareIPC`) — zero React Native
coupling (verified: no JSI/TurboModule symbols).

## The integration contract (short form)

1. `BareWorklet(configuration: nil)` — **nil**; assets trigger a broken unpack path.
2. `start("/name.bundle", source: Data, arguments: [])` — filename MUST end `.bundle`; UTF8/source overload only.
3. `BareIPC(worklet:)` created **after** start.
4. Reads via completion API, **serialized** — concurrent `read()` segfaults.
5. JS uses the injected `BareKit.IPC` global — `process.stdout` never reaches Swift.
6. Bundle toolchain pinned: `bare-bundle@1.10.0`, `bare-module-traverse@2.0.1`.
