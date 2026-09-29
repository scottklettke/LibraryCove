const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')
const Hyperswarm = require('hyperswarm')
const crypto = require('bare-crypto')
const { argv } = require('bare-process')

const keyHex = argv[2]
const store = new Corestore('/tmp/hd-test/bob-store')
const drive = new Hyperdrive(store, Buffer.from(keyHex, 'hex'))
drive.ready().then(async () => {
  console.log('bob topic:', crypto.createHash('sha256').update('librarycove-spike-2').digest().toString('hex'))
  console.log('bob opened drive:', drive.key.toString('hex'))
  const swarm = new Hyperswarm()
  const topic = crypto.createHash('sha256').update('librarycove-spike-2').digest()
  swarm.join(topic, { client: true, server: true })
  swarm.on('connection', (conn) => {
    console.log('bob: swarm connection opened')
    console.log('bob: connected to alice')
    conn.pipe(drive.replicate(conn, { keepAlive: true })).pipe(conn)
    // poll for the book
    const check = async () => {
      try {
        const buf = await drive.get('/books/book-1.json')
        if (buf) {
          console.log('bob GOT BOOK:', buf.toString())
          process.exit(0)
        }
      } catch {}
      setTimeout(check, 1000)
    }
    setTimeout(check, 1500)
  })
})
