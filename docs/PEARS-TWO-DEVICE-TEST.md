# Pears two-device verification (0.6.0)

Every layer is host/device-proven; this is the end-to-end app drive.

## Setup
1. Build + install the app on two devices (or simulators:
   3C330BD5-2E01-4771-9CC1-F1DC0D8848D3 / 82459CE1-4B37-4E21-9564-0A6043D540A8).
2. Both: Welcome → enter name + library name → Create My Library.

## Admin (device A)
3. Libraries → long-press your library → **P2P Sync** → **Create join link**
   (Editor) → **Copy**.
4. Keep LibraryCove open (the owner dispenses the write key at join time).

## Member (device B)
5. Open the invite link (`librarycove://join?key=…` — sent via the sheet's
   Send link, or paste manually): Libraries → the join sheet appears
   prefilled. On a simulator:
   `xcrun simctl openurl <udid> "librarycove://join?key=<invite>"`
   (iOS shows an "Open in LibraryCove?" confirmation once — tap Open.
   That single tap is standard custom-scheme behavior on real devices too.)
6. Enter your display name → **Join library**. Device A must be online
   (foregrounded) — redemption happens owner-to-member.

## Verify
- B's status flips to writable; `/members/<token>.json` lands in the drive.
- Add a book on either device → appears on the other within ~2s
  (both apps foregrounded).
- A's P2P sheet lists the link as **Used by <name>**.
- Re-sending the same invite → read-only + "already used" error.
- Revoke a pending link → redemption refused ("revoked").

## Known bounds
- Sync runs only while apps are foregrounded (no background sync in v1).
- The owner must be online at join time; afterwards members sync peer-to-peer.
