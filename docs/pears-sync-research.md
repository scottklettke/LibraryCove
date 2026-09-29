# Pears (Hypercore/Hyperdrive) sync — research verdict, 2026-09

Question: should LibraryCove add a second sync method built on the Pears /
Hypercore stack (Method 2), the way PearCal does it?

## What the stack actually is

- **Hyperdrive** is a distributed filesystem: metadata in a Hyperbee (B-tree
  over an append-only Hypercore log), file contents in Hyperblobs. Two peers
  holding the same drive key replicate block-by-block, encrypted end-to-end
  (Noise-style handshake between peers; keys ARE the access control).
- **Discovery** is Hyperswarm: a DHT on the public internet plus
  local-network multicast. A "topic" (hash of the drive key) finds peers;
  when direct connection fails, a relay can forward encrypted blocks.
- **Runtime**: there is no maintained native Swift implementation of
  Hypercore (the community Rust port, datrs/hypercore, is inactive).
  Everything production-grade runs on **Bare**, a small embedded JavaScript
  runtime.

## How PearCal does iOS

`peerloomllc/pearcal-native` is an Expo/React Native app (TypeScript UI,
`react-native-bare-kit` embedding the Bare runtime). The sync engine is
JavaScript — `corestore`, `hypercore`, `hyperbee`, `hyperswarm`, `hyperdht`,
`blind-peering`, `sodium-universal` — bundled with `bare-pack` into
`assets/bare-universal.bundle` and executed inside the Bare VM from native
bridge code (`ios/PearCal/BareBackgroundSync.swift` wires BGAppRefreshTask /
BGProcessingTask to JS sync callbacks; raw sockets via Hyperswarm work inside
the Bare runtime on iOS without the Network Extension).

LibraryCove is a pure-SwiftUI/SwiftData app. Adopting this stack means
embedding a JavaScript runtime + JS sync layer beside SwiftData and writing a
bridge (Swift model ⇄ JS records) — a second runtime, a JS toolchain in the
build, and a data-mapping layer where every schema change lands twice.

## Verdict: not now — revisit when cross-platform sync is the priority

| Factor | Assessment |
|---|---|
| Feasibility on iOS | Yes — proven by PearCal in production |
| Effort | High: new runtime/toolchain, Swift⇄JS bridge, duplicate schema mapping |
| App Store risk | Low-moderate (PearCal ships it; hardened-runtime/macOS local-network quirks exist on desktop) |
| Fit with SwiftData store | Poor: sync engine must map records both ways; conflicts resolved LWW |
| Background sync | 15-min BGAppRefresh windows; pushes depend on peers/seeder being online |

## Design notes for when it IS picked up

1. **One Hyperdrive per shared library**, mirroring the per-library CKShare
   model. The invite link encodes the drive key (`librarycove://join?drive=…`);
   roles can ride a small Hyperbee control doc; write access = holding the
   writer key, guests get read-only replication of a read key.
2. **Names**: the same participants-record pattern works — each member
   writes its chosen display name into a control document.
3. **Blind seeders**: PearCal's `seeder-launcher/` ships an Umbrel manifest
   and Start9 `.s9pk` build. Its blind-peering module (`blind-peering@2`)
   lets a self-hosted node replicate encrypted blocks without keys — counts
   only. Worth including at adoption time for always-on availability.
4. **iOS specifics**: BGAppRefreshTask (~25s, every ~15 min) +
   BGProcessingTask (charging+WiFi) exactly as PearCal's
   `BareBackgroundSync.swift` does; P2P sync is foreground-first on iOS.
5. Bundle strategy: replicate `bare-pack` → `assets/bare-universal.bundle`,
   driven by a small `src/bare.js` LibraryCove sync worker.
