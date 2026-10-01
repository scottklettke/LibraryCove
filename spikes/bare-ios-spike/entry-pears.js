// Pears entry: spike3 opaque-payload transport + single-use join keys.
//
// GOAL (A1): byte-for-byte round-trip fidelity for SharedBook payloads.
// Swift JSONEncodes SharedBook/SharedNote/... with the EXACT settings of
// SharedLibraryRecord.setPayload (millisecondsSince1970 dates, sortedKeys)
// and sends the payload as BASE64 over IPC. The worklet treats bodies as
// OPAQUE BYTES — it NEVER JSON.parse/stringifies them. Any re-encoding
// would rewrite Date formats and break fidelity.
//
// Drive layout (1:1 with the CKRecord mapping):
//   books/<id>.json  — SharedBook payload bytes
//   notes/<id>.json  — SharedNote payload bytes
//   lists/<id>.json  — SharedReadingList payload bytes
//   items/<id>.json  — SharedReadingListItem payload bytes
//   covers/<id>      — cover image bytes (the CKAsset equivalent), keyed
//                      by book id; coverFingerprint in the DTO detects
//                      cover-only changes
//
// Wire protocol (extends spike2; NDJSON over BareKit.IPC):
//   {"cmd":"putRaw","path":"books/x.json","data":"<base64>"} → written
//   {"cmd":"readRaw","path":"books/x.json"} → {"evt":"data","path":…,"data":"<base64>"}
//   create/join/listen/connect/put/list/read — unchanged from spike2
//
// Transport: Hyperswarm (DHT discovery + holepunch — proven LAN AND
// cellular internet) + LAN TCP fallback, identical wiring to spike2.

const b4a = require('b4a')
const crypto = require('bare-crypto')
const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')
const Hyperswarm = require('hyperswarm')
const fs = require('bare-fs')
const path = require('bare-path')
// bare-process module IS the process object (bare has no global process)
const _process = require('bare-process')
const { stdin, stdout } = _process
const { Server, createConnection } = require('bare-tcp')

_process.on('unhandledRejection', (e) => send({ evt: 'log', msg: 'unhandled: ' + (e && e.message ? e.message : e) }))
_process.on('uncaughtException', (e) => send({ evt: 'log', msg: 'uncaught: ' + (e && e.message ? e.message : e) }))

const onDevice = typeof BareKit !== 'undefined' && !!BareKit.IPC
let storageRoot = onDevice ? '.' : '/tmp/spike3-store'

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

// Same wiring as spike2: replicate(conn) wires the noise-encrypted
// connection directly — piping conn into the stream again double-wraps
// ("Can only pipe to one destination") and kills the session.
function wireReplication(socket, isInitiator) {
  send({ evt: 'peer' })
  socket.on('error', (e) => send({ evt: 'log', msg: 'sock: ' + (e.code || e.message) }))
  const stream = drive.replicate(isInitiator, { keepAlive: true })
  stream.on('error', (e) => send({ evt: 'log', msg: 'repl: ' + (e.code || e.message) }))
  socket.pipe(stream).pipe(socket)
}

function announce(keyBuf) {
  const topic = crypto.createHash('sha256').update(keyBuf).digest()
  const swarm = new Hyperswarm()
  swarms.push(swarm)
  swarm.join(topic, { server: true, client: true })
  const dht = swarm.dht
  dht.on('boot', () => send({ evt: 'log', msg: 'dht: bootstrapped' }))
  dht.on('nat-update', (...args) => {
    send({ evt: 'log', msg: 'dht: nat-update ' + JSON.stringify(args).slice(0, 200) })
  })
  dht.on('error', (e) => send({ evt: 'log', msg: 'dht error: ' + (e.code || e.message) }))
  swarm.on('connection', (conn, peerInfo) => {
    const dialRole = peerInfo && peerInfo.client === true ? 'client(out)' : peerInfo && peerInfo.client === false ? 'server(in)' : 'unknown'
    let remote = '?'
    try { remote = conn.rawStream ? (conn.rawStream.remoteHost + ':' + conn.rawStream.remotePort) : conn.remoteAddress } catch {}
    send({ evt: 'peer', via: 'hyperswarm', role: dialRole, remote })
    const stream = drive.replicate(conn)
    stream.on('error', (e) => send({ evt: 'log', msg: 'repl: ' + (e.code || e.message) }))
    conn.on('error', (e) => send({ evt: 'log', msg: 'conn: ' + (e.code || e.message) }))
    stream.on('close', () => { swarm.flush().catch(() => {}) })
  })
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

// --- Library identity persistence (same rules as spike2) ---

function saveLibraryMeta(meta) {
  try {
    fs.writeFileSync(path.join(storageRoot, 'library-meta.json'), JSON.stringify(meta))
  } catch (e) {
    send({ evt: 'log', msg: 'meta save failed: ' + (e.code || e.message) })
  }
}

function loadLibraryMeta() {
  try {
    return JSON.parse(fs.readFileSync(path.join(storageRoot, 'library-meta.json'), 'utf8'))
  } catch { return null }
}

async function restoreLibrary() {
  if (drive) return
  const meta = loadLibraryMeta()
  if (!meta || !meta.key) return
  log('restoring library ' + (meta.name || '') + ' from previous run')
  // NEVER wipe on restore: the stored seed is already correct — wiping
  // would destroy local writes.
  await joinLibrary(meta.key, meta.primaryKey, { wipe: false })
}

async function createLibrary(name) {
  if (drive) return send({ evt: 'error', msg: 'already have a library' })
  const withTimeout = (p, ms, what) => Promise.race([
    p,
    new Promise((_, rej) => setTimeout(() => rej(new Error(what + ' timed out after ' + ms + 'ms — stale lock? delete the app and reinstall')), ms))
  ])
  // Fresh create wipes any stale store (a RocksDB LOCK from a killed
  // prior instance hangs open() forever, silently).
  fs.rmSync(path.join(storageRoot, 'store'), { recursive: true, force: true })
  store = new Corestore(path.join(storageRoot, 'store'))
  drive = new Hyperdrive(store)
  await withTimeout(drive.ready(), 5000, 'store open')
  role = 'writer'
  const key = drive.key
  const meta = { name, createdAt: Date.now() }
  // library.json holds ONLY plain metadata the worklet itself reads —
  // NOT a SharedBook payload; written as worklet-owned JSON.
  await drive.put('/library.json', b4a.from(JSON.stringify(meta)))
  const topic = announce(key)
  send({ evt: 'created', key: key.toString('hex'), primaryKey: store.primaryKey.toString('hex'), name, port: listenPort })
  log('library created: ' + name)
  saveLibraryMeta({ key: key.toString('hex'), primaryKey: store.primaryKey.toString('hex'), name })
  startPolling()
}

async function joinLibrary(keyHex, primaryKeyHex, opts = {}) {
  if (drive) return send({ evt: 'error', msg: 'already have a library' })
  const wipe = opts.wipe !== false
  const writable = !!primaryKeyHex
  const storePath = path.join(storageRoot, 'store')
  if (writable && wipe) {
    // setSeed is first-write-wins: a stale store from a read-only era
    // derives the WRONG keypair (SESSION_NOT_WRITABLE). Wipe only on the
    // explicit join — restore passes wipe:false.
    fs.rmSync(path.join(storageRoot, 'store'), { recursive: true, force: true })
  }
  store = writable
    ? new Corestore(storePath, { primaryKey: b4a.from(primaryKeyHex, 'hex'), unsafe: true })
    : new Corestore(storePath)
  const keyBuf = b4a.from(keyHex, 'hex')
  drive = writable
    ? new Hyperdrive(store)
    : new Hyperdrive(store, keyBuf)
  await drive.ready()
  role = writable ? 'writer' : 'reader'
  announce(keyBuf)
  send({ evt: 'joined', key: keyHex, writable })
  log('joined library ' + keyHex.slice(0, 12) + (writable ? ' (writable)' : ' (read-only)'))
  saveLibraryMeta({ key: keyHex, primaryKey: primaryKeyHex || null })

  startPolling()
}

// --- Single-use join keys (Pears membership model) ---
//
// The ADMIN owns keys.json in the drive root — the canonical list, so
// every writer validates against the same state (v1: the admin device
// is the sole writer until a member accepts; members' writes arrive
// through the shared-keypair path and the admin's poll merges).
// Record shape: { code, role, createdAt, state: 'pending'|'used'|'revoked',
// usedBy, usedAt }.
//
// Handoff: the admin app shows the FULL join string
//   lc1.<driveKey>.<primaryKey>.<code>
// The joiner pastes it (or opens librarycove://join?key=…). The joiner's
// worklet sends {cmd:'joinV2', key, primaryKey, code, memberName} to the
// ADMIN's worklet? NO — v1 has no pre-replication channel. Instead:
// the ADMIN pre-authorizes the code (it's in keys.json), and the
// JOINER validates nothing at the worklet layer — the ADMIN sees the
// join event (peer connected + joinV2 announce via a control file) and
// marks the code used. The pragmatic v1: the joiner writes its
// memberName into the drive at /members/<code>.json (it has write
// access via the shared primaryKey); the ADMIN's poll sees the member
// file appear, marks the corresponding code used with that name, and
// surfaces it in the admin list. Revocation marks the code revoked —
// the admin then deletes /members/<code>.json and (v2) rotates the
// primary key; v1 audit-only.
//
// Admin-side handlers:

function keysPath() { return path.join(storageRoot, 'keys.json') }

function loadKeys() {
  try { return JSON.parse(fs.readFileSync(keysPath(), 'utf8')) } catch { return [] }
}

function saveKeys(keys) {
  fs.writeFileSync(keysPath(), JSON.stringify(keys, null, 2))
  // Publish to the drive so the admin's list is visible cross-device.
  if (drive) drive.put('/meta/keys.json', b4a.from(JSON.stringify(keys))).catch(() => {})
}

function generateJoinKey(role) {
  const keys = loadKeys()
  const code = crypto.randomBytes(16).toString('hex')
  keys.push({ code, role: role || 'editor', createdAt: Date.now(), state: 'pending', usedBy: null, usedAt: null })
  saveKeys(keys)
  return { code, key: keys[keys.length - 1] }
}

function listJoinKeys() {
  send({ evt: 'joinKeys', keys: loadKeys() })
}

function revokeJoinKey(code) {
  const keys = loadKeys()
  const k = keys.find(x => x.code === code)
  if (k) { k.state = 'revoked'; saveKeys(keys) }
  send({ evt: 'joinKeyRevoked', code })
}

// Member side: after a writable join, announce identity by writing the
// member file the admin's poll watches.
async function announceMembership(code, memberName) {
  if (!drive || role !== 'writer') return send({ evt: 'error', msg: 'cannot announce membership (not writable)' })
  const p = '/members/' + code + '.json'
  await drive.put(p, b4a.from(JSON.stringify({ memberName, joinedAt: Date.now() })))
  send({ evt: 'membershipAnnounced', path: p })
}

// Admin-side poll hook: a pending code whose member file appeared is now
// used. Called from startPolling's check.
async function reconcileMembers() {
  if (!drive) return
  const keys = loadKeys()
  let changed = false
  for (const k of keys) {
    if (k.state !== 'pending') continue
    const buf = await drive.get('/members/' + k.code + '.json').catch(() => null)
    if (!buf) continue
    try {
      const m = JSON.parse(buf.toString())
      k.state = 'used'
      k.usedBy = m.memberName || 'Unknown'
      k.usedAt = Date.now()
      changed = true
      send({ evt: 'memberJoined', code: k.code, name: k.usedBy, role: k.role })
    } catch {}
  }
  if (changed) saveKeys(keys)
}

// Poll drives for changes — same shape as spike2, but reports per-type
// counts so real payload sync is visible.
let poll = null
let lastCounts = null

function startPolling() {
  const check = async () => {
    try {
      await drive.core.update({ force: true })   // writable sessions no-op without force
      const counts = {}
      for (const dir of ['books', 'notes', 'lists', 'items', 'covers', 'members']) {
        let n = 0
        for await (const entry of drive.list('/' + dir)) n++
        counts[dir] = n
      }
      const sig = JSON.stringify(counts)
      if (sig !== lastCounts) {
        lastCounts = sig
        send({ evt: 'counts', counts })
      }
      await reconcileMembers()
    } catch {}
  }
  check()
  poll = setInterval(check, 1500)
}

// --- Opaque-bytes payload I/O (the A1 core) ---

async function putRaw(p, dataB64) {
  if (!drive) return send({ evt: 'error', msg: 'no library' })
  try {
    // Base64 → raw bytes, stored VERBATIM. No JSON.parse, no re-encode:
    // the Swift encoder already produced the canonical bytes
    // (millisecondsSince1970 + sortedKeys) and they must survive
    // byte-for-byte.
    await drive.put(p, b4a.from(dataB64, 'base64'))
    send({ evt: 'written', path: p })
  } catch (e) {
    send({ evt: 'error', msg: 'putRaw failed: ' + e.message })
  }
}

async function readRaw(p) {
  if (!drive) return send({ evt: 'error', msg: 'no library' })
  try {
    const buf = await drive.get(p)
    if (!buf) return send({ evt: 'error', msg: 'not found: ' + p })
    send({ evt: 'data', path: p, data: buf.toString('base64') })
  } catch (e) {
    send({ evt: 'error', msg: 'readRaw failed: ' + e.message })
  }
}

// Legacy JSON helpers retained for UI compatibility (spike2-style puts);
// NOT used for SharedBook payloads.
async function putDoc(p, data) {
  if (!drive) return send({ evt: 'error', msg: 'no library' })
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
  for await (const entry of drive.list('/')) {
    paths.push(entry.key)
  }
  send({ evt: 'paths', paths })
}

async function readDoc(p) {
  if (!drive) return send({ evt: 'error', msg: 'no library' })
  const buf = await drive.get(p).catch(() => null)
  if (!buf) return send({ evt: 'error', msg: 'not found: ' + p })
  try { send({ evt: 'data', path: p, json: JSON.parse(buf.toString()) }) }
  catch { send({ evt: 'data', path: p, raw: buf.toString('base64') }) }
}

// Library identity persists across relaunches (same rules as spike2):
// the SAME join key, no wipe on restore, re-announce on init.

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
        restoreLibrary().catch(e => send({ evt: 'error', msg: 'restore failed: ' + e.message }))
        break
      case 'create': createLibrary(msg.library).catch(e => send({ evt: 'error', msg: 'create failed: ' + e.message })); break
      case 'join': joinLibrary(msg.key, msg.primaryKey).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'listen': listenTcp(msg.port || 8787); break
      case 'connect': connectTcp(msg.host, msg.port || 8787); break
      case 'putRaw': putRaw(msg.path, msg.data).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'readRaw': readRaw(msg.path).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'generateJoinKey': generateJoinKey(msg.role); break
      case 'listJoinKeys': listJoinKeys(); break
      case 'revokeJoinKey': revokeJoinKey(msg.code); break
      case 'announceMembership': announceMembership(msg.code, msg.memberName).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'put': putDoc(msg.path, msg.data).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'list': listAll().catch(e => send({ evt: 'error', msg: e.message })); break
      case 'read': readDoc(msg.path).catch(e => send({ evt: 'error', msg: e.message })); break
    }
  }
}

let buffer = ''
if (onDevice) BareKit.IPC.on('data', feed)
else stdin.on('data', feed)

send({ evt: 'boot' })
log('pears ready — storage: ' + storageRoot)
