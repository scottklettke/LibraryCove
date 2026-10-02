// Pears E2E pipeline proof: the exact semantics PearsSyncEngine runs —
// encode (msSince1970+sortedKeys bytes) → put → replicate → read →
// byte-compare, both directions, with the pull-before-write ordering
// and rebridge-on-stall the engine encodes. Run: node spike2/pears-e2e.js
const crypto = require('crypto')
const fs = require('fs')
const Corestore = require(__dirname + '/../node_modules/corestore')
const Hyperdrive = require(__dirname + '/../node_modules/hyperdrive')
async function main() {
  fs.rmSync('/tmp/pears-e2e', { recursive: true, force: true })
  const storeA = new Corestore('/tmp/pears-e2e/a')
  const driveA = new Hyperdrive(storeA)
  await driveA.ready()
  const book = { id: 'E2E-1', title: 'A1 Book', status: 'reading', createdAt: 1727654400000, updatedAt: 1727654400000 }
  const canonical = Buffer.from(JSON.stringify(Object.fromEntries(Object.entries(book).sort(([a],[b]) => a < b ? -1 : 1))))
  const cover = crypto.randomBytes(2048)
  await driveA.put('/books/' + book.id + '.json', canonical)
  await driveA.put('/covers/' + book.id, cover)
  let sA = driveA.replicate(true, { keepAlive: false })
  const storeB = new Corestore('/tmp/pears-e2e/b', { primaryKey: storeA.primaryKey, unsafe: true })
  const driveB = new Hyperdrive(storeB)
  await driveB.ready()
  let sB = driveB.replicate(false, { keepAlive: false })
  sA.pipe(sB).pipe(sB)
  function rebridge() { try { sA.destroy(); sB.destroy() } catch {}; sA = driveA.replicate(true, { keepAlive: false }); sB = driveB.replicate(false, { keepAlive: false }); sA.pipe(sB).pipe(sA) }
  async function waitFor(path, check) {
    for (let i = 0; i < 50; i++) {
      await driveB.core.update({ force: true }).catch(() => {})
      const buf = await driveB.get(path).catch(() => null)
      if (buf && (!check || check(buf))) return buf
      if (i % 10 === 9) rebridge()
      await new Promise(r => setTimeout(r, 100))
    }
    return null
  }
  const payload = await waitFor('/books/' + book.id + '.json', b => b.equals(canonical))
  console.log('A→B payload:', payload ? 'BYTE-IDENTICAL' : 'FAIL')
  const coverBack = await waitFor('/covers/' + book.id, b => b.equals(cover))
  console.log('cover:', coverBack ? 'BYTE-IDENTICAL' : 'FAIL')
  const book2 = { id: 'E2E-2', title: 'From B', status: 'to-read', createdAt: 1727740800000, updatedAt: 1727740800000 }
  const canonical2 = Buffer.from(JSON.stringify(Object.fromEntries(Object.entries(book2).sort(([a],[b]) => a < b ? -1 : 1))))
  await driveB.put('/books/' + book2.id + '.json', canonical2)
  let fromA = null
  for (let i = 0; i < 50 && !fromA; i++) {
    await driveA.core.update({ force: true })
    fromA = await driveA.get('/books/' + book2.id + '.json').catch(() => null)
    if (!fromA && i % 10 === 9) rebridge()
    if (!fromA) await new Promise(r => setTimeout(r, 100))
  }
  const reverseOk = fromA && Buffer.compare(canonical2, fromA) === 0
  console.log('B→A:', reverseOk ? 'BYTE-IDENTICAL' : 'FAIL')
  const pass = !!payload && !!coverBack && reverseOk
  console.log(pass ? '✅ E2E PIPELINE: PASS' : '❌ FAIL')
  process.exit(pass ? 0 : 1)
}
main().catch(e => { console.error('FAIL', e.message); process.exit(1) })
