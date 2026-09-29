const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')

async function main() {
  const storeA = new Corestore('/tmp/hd-test/local-a')
  const driveA = new Hyperdrive(storeA)
  await driveA.ready()
  await driveA.put('/books/book-1.json', JSON.stringify({ title: 'Dune' }))
  console.log('alice wrote, key:', driveA.key.toString('hex').slice(0, 12))

  const storeB = new Corestore('/tmp/hd-test/local-b')
  const driveB = new Hyperdrive(storeB, driveA.key)
  await driveB.ready()

  const stream = driveA.replicate(true, { keepAlive: true })
  stream.pipe(driveB.replicate(false, { keepAlive: true })).pipe(stream)

  // Wait for the metadata to arrive, then read
  for (let i = 0; i < 20; i++) {
    await new Promise(r => setTimeout(r, 250))
    const buf = await driveB.get('/books/book-1.json', { timeout: 500 }).catch(() => null)
    if (buf) {
      console.log('bob got:', buf.toString())
      process.exit(0)
    }
    if (i === 5) console.log('still waiting... entry?', await driveB.entry('/books/book-1.json').catch(() => 'err'))
  }
  console.log('FAILED: never received')
  process.exit(1)
}
main()
