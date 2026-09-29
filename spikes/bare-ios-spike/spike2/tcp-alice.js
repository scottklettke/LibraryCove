const { Server } = require('bare-tcp')
const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')

const store = new Corestore('/tmp/hd-test/tcp-a')
const drive = new Hyperdrive(store)

async function main() {
  await drive.ready()
  await drive.put('/books/book-1.json', JSON.stringify({ title: 'Dune', via: 'tcp' }))
  console.log('alice key:', drive.key.toString('hex'))

  const server = new Server((socket) => {
    console.log('alice: bob connected via tcp')
    socket.pipe(drive.replicate(true, { keepAlive: true })).pipe(socket)
  })
  server.listen(8787, '127.0.0.1', () => console.log('alice listening on 8787'))
}
main()
