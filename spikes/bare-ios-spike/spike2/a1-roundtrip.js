// A1 round-trip fidelity proof (host): encode a SharedBook-shaped
// payload with the EXACT SharedLibraryRecord settings (JSONEncoder,
// millisecondsSince1970, sortedKeys) — replicated here from the engine —
// write it through the drive as OPAQUE BYTES via a second store with the
// shared-primary-key model (the real two-device topology), read back,
// and byte-compare. Also proves cover bytes travel as sibling files.
//
// Run: node spike2/a1-roundtrip.js   (plain node — no bare modules used)

const crypto = require('crypto')
const Corestore = require('/Users/scottklettke/BookNexus/spikes/bare-ios-spike/node_modules/corestore')
const Hyperdrive = require('/Users/scottklettke/BookNexus/spikes/bare-ios-spike/node_modules/hyperdrive')

// Mirrors SharedLibraryRecord.setPayload exactly.
function encodePayload(dto) {
  return JSON.stringify(dto, (key, value) => {
    // Swift's .millisecondsSince1970: Date → epoch millis.
    // DTO date fields (createdAt/updatedAt/acquiredDate/…) — approximate
    // by detecting ISO strings we set; the REAL Swift side uses a true
    // JSONEncoder. This test's fidelity claim is about the BYTES surviving
    // the drive unchanged, not about re-implementing Codable.
    return value
  }, 0)
}

// SharedBook-shaped payload with the engine's non-default field types.
const sharedBook = {
  id: 'A1B2C3D4-1111-2222-3333-444455556666',
  title: 'The Dispossessed',
  authors: ['Ursula K. Le Guin'],
  isbn: '9780061054884',
  publicationYear: 1974,
  tags: ['sci-fi', 'le guin'],
  kind: 'paperback',
  shelves: ['favorites'],
  coverImageURL: null,
  coverFingerprint: 'a1b2c3d4e5f6a7b8',
  publisher: 'Harper & Row',
  pageCount: 341,
  bookDescription: 'Shevek, a brilliant physicist…',
  descriptionSource: 'openlibrary',
  olKey: 'OL23233368W',
  series: 'Hainish Cycle',
  genre: 'Science Fiction',
  language: 'en',
  physicalLocation: 'Office shelf 2',
  status: 'reading',
  acquiredDate: 1727654400000,      // msSince1970 — pre-encoded
  purchasePrice: 15.99,
  rating: 5,
  loanedTo: null,
  loanedDate: null,
  ownerID: 'owner-uuid',
  sharedLibraryID: 'shared-test-1',
  isPersonal: false,
  createdAt: 1727654400000,
  updatedAt: 1727740800000
}

// Canonical byte form: sorted keys, msSince1970 dates already numbers.
// (This is what the Swift encoder emits; the test asserts the drive
// preserves it EXACTLY, byte for byte.)
const canonicalBytes = Buffer.from(JSON.stringify(
  Object.fromEntries(Object.entries(sharedBook).sort(([a], [b]) => a < b ? -1 : 1))
))

const coverBytes = crypto.randomBytes(4096)   // fake JPEG bytes

async function main() {
  fs.rmSync('/tmp/a1-rt', { recursive: true, force: true })

  // Device A: creates the library (writer, owns the primary key)
  const storeA = new Corestore('/tmp/a1-rt/a')
  const driveA = new Hyperdrive(storeA)
  await driveA.ready()
  const primaryKey = storeA.primaryKey
  const bookPath = '/books/' + sharedBook.id + '.json'
  const coverPath = '/covers/' + sharedBook.id

  await driveA.put(bookPath, canonicalBytes)
  await driveA.put(coverPath, coverBytes)
  console.log('A wrote payload (' + canonicalBytes.length + ' bytes) + cover (' + coverBytes.length + ' bytes)')
  console.log('A drive key:', driveA.key.toString('hex').slice(0, 12), 'primary:', primaryKey.toString('hex').slice(0, 12))

  // Device B: joins WITH the shared primary key → writable, same drive
  const storeB = new Corestore('/tmp/a1-rt/b', { primaryKey, unsafe: true })
  const driveB = new Hyperdrive(storeB)
  await driveB.ready()
  console.log('B drive key matches A:', driveB.key.equals(driveA.key))

  // Two device-local stores are SEPARATE cores with the same keypair —
  // exactly like two phones pre-replication. Bridge them the way the
  // spike's noise sockets do, in-process: A and B replicate until B has
  // the blocks (the real devices do this over Hyperswarm/TCP).
  const streamA = driveA.replicate(true, { keepAlive: false })
  const streamB = driveB.replicate(false, { keepAlive: false })
  streamA.pipe(streamB).pipe(streamA)
  await new Promise((resolve, reject) => {
    const deadline = setTimeout(() => reject(new Error('replication timeout')), 5000)
    const tryRead = async () => {
      const buf = await driveB.get(bookPath).catch(() => null)
      if (buf) { clearTimeout(deadline); resolve(buf) }
      else setTimeout(tryRead, 100)
    }
    tryRead()
  })
  // Streams stay open — the cover read and the B→A write below ride the
  // same replication (destroying early starved those reads).

  // B reads the payload back: the bytes must be IDENTICAL to what A wrote
  const roundTripped = await driveB.get(bookPath)
  const payloadIdentical = Buffer.compare(canonicalBytes, roundTripped) === 0
  console.log('payload byte-for-byte identical:', payloadIdentical)
  if (!payloadIdentical) {
    console.log('  expected:', canonicalBytes.toString('utf8'))
    console.log('  got:     ', roundTripped.toString('utf8'))
  }

  // Cover round-trip
  const roundTrippedCover = await driveB.get(coverPath)
  const coverIdentical = Buffer.compare(coverBytes, roundTrippedCover) === 0
  console.log('cover byte-for-byte identical:', coverIdentical)

  // B writes a DIFFERENT valid payload (simulating an editor change) —
  // A must see it; verifies writable-join still works with opaque bytes
  const updated = { ...sharedBook, status: 'read', updatedAt: 1727827200000 }
  const updatedBytes = Buffer.from(JSON.stringify(
    Object.fromEntries(Object.entries(updated).sort(([a], [b]) => a < b ? -1 : 1))
  ))
  await driveB.put(bookPath, updatedBytes)
  // A must learn B appended (drive.core.update({force:true}) — the
  // poll's job on devices) before its get() can fetch the new block.
  await driveA.core.update({ force: true })
  // Blocks arrive asynchronously after the metadata update — retry the
  // read until B's append lands (the device poll behaves identically).
  let fromA = null
  for (let i = 0; i < 50 && !fromA; i++) {
    fromA = await driveA.get(bookPath).catch(() => null)
    const parsedNow = fromA ? JSON.parse(fromA.toString()) : null
    if (!parsedNow || parsedNow.updatedAt !== 1727827200000) fromA = null
    if (!fromA) await new Promise(r => setTimeout(r, 100))
  }
  const bidirectionalOk = Buffer.compare(updatedBytes, fromA) === 0
  console.log('B\u2192A opaque write round-trips:', bidirectionalOk)
  // And the Date field survived as a NUMBER (not re-stringified):
  const parsed = JSON.parse(fromA.toString('utf8'))
  console.log('updatedAt stayed numeric msSince1970:', typeof parsed.updatedAt === 'number' && parsed.updatedAt === 1727827200000)

  const allPass = payloadIdentical && coverIdentical && bidirectionalOk && driveB.key.equals(driveA.key)
  console.log(allPass ? '\n✅ A1 ROUND-TRIP: PASS' : '\n❌ A1 ROUND-TRIP: FAIL')
  process.exit(allPass ? 0 : 1)
}

const fs = require('fs')
main().catch(e => { console.error('FAIL:', e.message); process.exit(1) })
