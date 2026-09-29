// Spike 2 entry: a hyperdrive per library over the BareKit.IPC bridge.
//
// Wire protocol (newline-delimited JSON over BareKit.IPC):
//   Swift → JS:
//     {"cmd":"create","library":"My Library"}     → {"evt":"created","key":"<hex>"}
//     {"cmd":"join","key":"<hex>"}                → {"evt":"joined","key":"<hex>"}
//     {"cmd":"put","path":"books/x.json","data":{…}} → {"evt":"written","path":…}
//     {"cmd":"list"}                              → {"evt":"list","paths":[…]}
//     {"cmd":"read","path":"books/x.json"}        → {"evt":"data","path":…,"data":{…}}
//   JS → Swift (progress):
//     {"evt":"boot"} | {"evt":"log","msg":…} | {"evt":"peer"} | {"evt":"sync","count":n}
//
// Transport: one topic per LIBRARY (sha256 of the drive key) so two devices
// only meet when they share a library. Both sides join as server+client —
// on a LAN, Hyperswarm's local discovery connects them without the DHT.

const b4a = require('b4a')
const crypto = require('bare-crypto')
const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')
const Hyperswarm = require('hyperswarm')
const fs = require('bare-fs')
const path = require('bare-path')

const { stdin, stdout } = require('bare-process')
const onDevice = typeof BareKit !== 'undefined' && !!BareKit.IPC

// Storage root: Swift passes it at init (Documents); tmp on host.
let storageRoot = onDevice ? '.' : '/tmp/spike2-store'

let store = null
let drive = null        // the library we created OR joined
let swarm = null
let role = null         // 'writer' | 'reader'

function send(obj) {
  try {
    if (onDevice) BareKit.IPC.write(b4a.from(JSON.stringify(obj) + '\n'))
    else stdout.write(JSON.stringify(obj) + '\n')
  } catch {}
}

function log(msg) { send({ evt: 'log', msg }) }

const swarms = []
const { Server, createConnection } = require('bare-tcp')
const servers = []
const sockets = []

function wireReplication(socket, isInitiator) {
  send({ evt: 'peer' })
  const stream = drive.replicate(isInitiator, { keepAlive: true, onerror: (e) => send({ evt: 'log', msg: 'repl err: ' + e.message }) })
  stream.on('error', (e) => send({ evt: 'log', msg: 'repl err2: ' + e.message }))
  socket.pipe(stream).pipe(socket)
}

function listenTcp(port) {
  const server = new Server((socket) => {
    send({ evt: 'peer', via: 'tcp' })
    wireReplication(socket, false)
  })
  servers.push(server)
  server.listen(port, '0.0.0.0', () => send({ evt: 'listening', port }))
}

function connectTcp(host, port) {
  const socket = createConnection({ host, port }, () => {
    send({ evt: 'peer', via: 'tcp' })
    wireReplication(socket, true)
  })
  sockets.push(socket)
  return socket
}

function announce(keyBuf) {
  // Hyperswarm discovery: join the topic (works when DHT/multicast is
  // reachable). TCP direct-connect is the fallback used by the spike UI.
  const topic = crypto.createHash('sha256').update(keyBuf).digest()
  const swarm = new Hyperswarm()
  swarms.push(swarm)
  swarm.join(topic, { server: true, client: true })
  swarm.on('connection', (conn) => {
    send({ evt: 'peer', via: 'hyperswarm' })
    conn.pipe(drive.replicate(true, { keepAlive: true })).pipe(conn)
  })
  return topic
}

async function createLibrary(name) {
  if (drive) return send({ evt: 'error', msg: 'already have a library' })
  store = new Corestore(path.join(storageRoot, 'store'))
  drive = new Hyperdrive(store)
  await drive.ready()
  role = 'writer'
  const key = drive.key
  const meta = { name, createdAt: Date.now() }
  await drive.put('/library.json', JSON.stringify(meta))
  const topic = announce(key)
  listenTcp(8787)
  send({ evt: 'created', key: key.toString('hex'), name })
  log('library created: ' + name + ' key ' + key.toString('hex').slice(0, 12))
}

async function joinLibrary(keyHex) {
  if (drive) return send({ evt: 'error', msg: 'already have a library' })
  store = new Corestore(path.join(storageRoot, 'store'))
  const keyBuf = b4a.from(keyHex, 'hex')
  drive = new Hyperdrive(store, keyBuf)
  await drive.ready()
  role = 'reader'
  announce(keyBuf)
  send({ evt: 'joined', key: keyHex })
  log('joined library ' + keyHex.slice(0, 12))

  // Watch for incoming content
  const check = async () => {
    try {
      const metaBuf = await drive.get('/library.json', { wait: false, timeout: 5000 })
      if (metaBuf) {
        const meta = JSON.parse(metaBuf.toString())
        send({ evt: 'library', name: meta.name })
        let count = 0
        for await (const entry of drive.list('/books')) count++
        send({ evt: 'sync', count })
      }
    } catch {}
  }
  check()
  const poll = setInterval(check, 1500)
  setTimeout(() => clearInterval(poll), 120000) // stop after 2 min
}

async function putDoc(p, data) {
  if (!drive || role !== 'writer') return send({ evt: 'error', msg: 'not a writer' })
  await drive.put(p, b4a.from(JSON.stringify(data)))
  send({ evt: 'written', path: p })
}

async function listAll() {
  if (!drive) return send({ evt: 'error', msg: 'no library' })
  const paths = []
  for await (const entry of drive.list()) paths.push(entry.key)
  send({ evt: 'list', paths })
}

async function readDoc(p) {
  if (!drive) return send({ evt: 'error', msg: 'no library' })
  const buf = await drive.get(p).catch(() => null)
  send({ evt: 'data', path: p, data: buf ? JSON.parse(buf.toString()) : null })
}

// ── IPC plumbing ────────────────────────────────────────────────────────────
let buffer = ''
function feed(chunk) {
  buffer += chunk.toString()
  let idx
  while ((idx = buffer.indexOf('\n')) >= 0) {
    const line = buffer.slice(0, idx)
    buffer = buffer.slice(idx + 1)
    if (!line.trim()) continue
    let msg
    try { msg = JSON.parse(line) } catch { continue }
    switch (msg.cmd) {
      case 'init': storageRoot = msg.storageRoot || storageRoot; send({ evt: 'ready', storageRoot }); break
      case 'create': createLibrary(msg.library).catch(e => send({ evt: 'error', msg: e.message })) ; break
      case 'join': joinLibrary(msg.key).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'put': putDoc(msg.path, msg.data).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'list': listAll().catch(e => send({ evt: 'error', msg: e.message })); break
      case 'read': readDoc(msg.path).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'listen': listenTcp(msg.port || 8787); break
      case 'connect': connectTcp(msg.host, msg.port || 8787); break
    }
  }
}

if (onDevice) {
  BareKit.IPC.on('data', feed)
} else {
  require('bare-process').stdin.on('data', feed)
}

send({ evt: 'boot' })
log('spike2 ready — storage: ' + storageRoot)
