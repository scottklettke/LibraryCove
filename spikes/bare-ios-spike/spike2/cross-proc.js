const { spawn } = require('bare-subprocess')
const fs = require('bare-fs')

// write the bob script
const bobScript = `
const { createConnection } = require('bare-tcp')
const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')
const { stdout } = require('bare-process')

const key = process.argv ? null : null
`
console.log('skip — testing in-process cross-store first with delay')

async function main() {
  const Corestore = require('corestore')
  const Hyperdrive = require('hyperdrive')

  const storeA = new Corestore('/tmp/hd-test/cp-a')
  const driveA = new Hyperdrive(storeA)
  await driveA.ready()
  await driveA.put('/books/b1.json', JSON.stringify({ title: 'CrossProc' }))
  console.log('A wrote:', driveA.key.toString('hex').slice(0, 12))

  const storeB = new Corestore('/tmp/hd-test/cp-b')
  const driveB = new Hyperdrive(storeB, driveA.key)
  await driveB.ready()

  const stream = driveA.replicate(true, { keepAlive: true })
  stream.pipe(driveB.replicate(false, { keepAlive: true })).pipe(stream)

  // wait for sync to settle
  await new Promise(r => setTimeout(r, 2000))
  const buf = await driveB.get('/books/b1.json', { wait: false, timeout: 3000 }).catch(() => null)
  console.log('B read:', buf ? buf.toString() : 'NULL')
  process.exit && require('bare-process').exit(buf ? 0 : 1)
}
main()
