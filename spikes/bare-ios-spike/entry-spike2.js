// Spike 2 entry: a hyperdrive per library over the BareKit.IPC bridge.
//
// Wire protocol (newline-delimited JSON over BareKit.IPC):
//   Swift → JS:
//     {"cmd":"init","storageRoot":"…"}
//     {"cmd":"create","library":"My Library"}      → {"evt":"created","key":…,"port":…}
//     {"cmd":"join","key":"<hex>"}                 → {"evt":"joined","key":…}
//     {"cmd":"listen","port":8787}                 → {"evt":"listening","port":…}
//     {"cmd":"connect","host":…,"port":…}          → {"evt":"peer","via":"tcp"}
//     {"cmd":"put","path":"books/x.json","data":{…}} → {"evt":"written","path":…}
//     {"cmd":"list"} / {"cmd":"read","path":…}
//   JS → Swift: {"evt":"boot"|"log"|"peer"|"sync"|"library"|"error"}
//
// Transport: LAN TCP (writer listens, reader connects). Hyperswarm topic
// discovery joins in parallel and takes over when the DHT is reachable.
// listenTcp walks up ports on EADDRINUSE — a crashed prior instance must
// not wedge the next run (this bit us: EADDRINUSE aborted the worklet
// before the writer could write).

const b4a = require('b4a')
const crypto = require('bare-crypto')
const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')
const Hyperswarm = require('hyperswarm')
const fs = require('bare-fs')
const path = require('bare-path')
const { stdin, stdout } = require('bare-process')
const { Server, createConnection } = require('bare-tcp')

const onDevice = typeof BareKit !== 'undefined' && !!BareKit.IPC
let storageRoot = onDevice ? '.' : '/tmp/spike2-store'

let store = null
let drive = null
let role = null
let listenPort = 8787

const swarms = []
const servers = []
const sockets = []

function send(obj) {
  try {
    if (onDevice) BareKit.IPC.write(b4a.from(JSON.stringify(obj) + '\n'))
    else stdout.write(JSON.stringify(obj) + '\n')
  } catch {}
}

function log(msg) { send({ evt: 'log', msg }) }

function wireReplication(socket, isInitiator) {
  send({ evt: 'peer' })
  // Probe tools (nc) and dead peers reset mid-handshake — swallow socket
  // errors or the unhandled error aborts the whole worklet.
  socket.on('error', (e) => send({ evt: 'log', msg: 'sock: ' + (e.code || e.message) }))
  const stream = drive.replicate(isInitiator, { keepAlive: true })
  stream.on('error', (e) => send({ evt: 'log', msg: 'repl: ' + (e.code || e.message) }))
  socket.pipe(stream).pipe(socket)
}

// Hyperswarm topic discovery — joins the library's topic so peers on the
// same network (or via DHT) find each other without a known address.
function announce(keyBuf) {
  const topic = crypto.createHash('sha256').update(keyBuf).digest()
  const swarm = new Hyperswarm()
  swarms.push(swarm)
  swarm.join(topic, { server: true, client: true })
  // Discovery diagnostics: bare hosts log nothing by default, so surface
  // the DHT lifecycle — if bootstrap never completes or holepunching
  // fails, the next log paste shows exactly where discovery stalls.
  const dht = swarm.dht
  dht.on('boot', () => send({ evt: 'log', msg: 'dht: bootstrapped' }))
  dht.on('nat-update', (...args) => {
    send({ evt: 'log', msg: 'dht: nat-update ' + JSON.stringify(args).slice(0, 200) })
  })
  dht.on('error', (e) => send({ evt: 'log', msg: 'dht error: ' + (e.code || e.message) }))
  swarm.on('connection', (conn) => {
    send({ evt: 'peer', via: 'hyperswarm' })
    const stream = drive.replicate(true, { keepAlive: true })
    stream.on('error', (e) => send({ evt: 'log', msg: 'repl: ' + (e.code || e.message) }))
    conn.pipe(stream).pipe(conn)
  })
  // Periodic peer-count heartbeat so a silent stall is visible in logs.
  let beats = 0
  const beat = setInterval(() => {
    beats++
    let peers = 0
    for (const c of swarm.connections) peers++
    send({ evt: 'log', msg: 'discovery beat ' + beats + ': peers=' + peers })
    if (beats >= 10) clearInterval(beat)
  }, 10000)
  return topic
}

// LAN TCP listener — the writer's meet point. Walks up ports on
// EADDRINUSE (a crashed prior instance wedges the port for a while).
function listenTcp(port) {
  const attempt = (p, tries) => {
    const server = new Server((socket) => {
      send({ evt: 'peer', via: 'tcp' })
      wireReplication(socket, true)
    })
    servers.push(server)
    server.on('close', () => send({ evt: 'log', msg: 'SERVER CLOSED ' + p }))
    server.on('error', (e) => {
      send({ evt: 'log', msg: 'listen ' + p + ' failed: ' + (e.code || e.message) })
      const idx = servers.indexOf(server)
      if (idx >= 0) servers.splice(idx, 1)
      if (e.code === 'EADDRINUSE' && tries < 5) {
        setTimeout(() => attempt(p + 1, tries + 1), 300)
      }
    })
    server.listen(p, '0.0.0.0', () => {
      listenPort = p
      send({ evt: 'listening', port: p })
    })
  }
  attempt(port, 0)
}

function connectTcp(host, port) {
  const socket = createConnection({ host, port }, () => {
    send({ evt: 'peer', via: 'tcp' })
    wireReplication(socket, false)
  })
  socket.on('error', (e) => send({ evt: 'log', msg: 'connect: ' + (e.code || e.message) }))
  sockets.push(socket)
}

async function createLibrary(name) {
  if (drive) return send({ evt: 'error', msg: 'already have a library' })
  store = new Corestore(path.join(storageRoot, 'store'))
  drive = new Hyperdrive(store)
  await drive.ready()
  role = 'writer'
  const key = drive.key
  const meta = { name, createdAt: Date.now() }
  await drive.put('/library.json', b4a.from(JSON.stringify(meta)))
  const topic = announce(key)
  send({ evt: 'created', key: key.toString('hex'), name, port: listenPort })
  log('library created: ' + name)
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

  const check = async () => {
    try {
      await drive.core.update()   // pull metadata from the connected peer
      const metaBuf = await drive.get('/library.json').catch(() => null)
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
  setTimeout(() => clearInterval(poll), 120000)
}

async function putDoc(p, data) {
  if (!drive || role !== 'writer') return send({ evt: 'error', msg: 'not a writer' })
  try {
    await drive.put(p, b4a.from(JSON.stringify(data)))
    send({ evt: 'written', path: p })
  } catch (e) {
    send({ evt: 'error', msg: 'put failed: ' + e.message })
  }
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
      case 'init':
        storageRoot = msg.storageRoot || storageRoot
        send({ evt: 'ready', storageRoot })
        break
      case 'create': createLibrary(msg.library).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'join': joinLibrary(msg.key).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'listen': listenTcp(msg.port || 8787); break
      case 'connect': connectTcp(msg.host, msg.port || 8787); break
      case 'put': putDoc(msg.path, msg.data).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'list': listAll().catch(e => send({ evt: 'error', msg: e.message })); break
      case 'read': readDoc(msg.path).catch(e => send({ evt: 'error', msg: e.message })); break
    }
  }
}

if (onDevice) BareKit.IPC.on('data', feed)
else stdin.on('data', feed)

send({ evt: 'boot' })
log('spike2 ready — storage: ' + storageRoot)
