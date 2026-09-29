const { createConnection } = require('bare-tcp')
const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')

const keyHex = require('bare-process').argv[2]
const store = new Corestore('/tmp/hd-test/tcp-b')
const drive = new Hyperdrive(store, Buffer.from(keyHex, 'hex'))

async function main() {
  await drive.ready()
  console.log('bob opening key:', drive.key.toString('hex').slice(0, 12))
  const socket = createConnection({ port: 8787, host: '127.0.0.1' }, () => {
    console.log('bob: connected to alice via tcp')
    socket.pipe(drive.replicate(false, { keepAlive: true })).pipe(socket)
    const check = async () => {
      const buf = await drive.get('/books/book-1.json').catch(() => null)
      if (buf) { console.log('bob GOT:', buf.toString()); require('bare-process').exit(0) }
      setTimeout(check, 500)
    }
    setTimeout(check, 800)
  })
}
main()
