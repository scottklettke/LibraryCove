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
  // Control channel: a SECOND hyperswarm connection per joiner carries
  // the token-redemption handshake (NDJSON, magic first line). The
  // replication connection stays untouched. The admin answers control
  // lines only if it holds the primary key (is the bootstrap writer).
  const ctrlTopic = crypto.createHash('sha256').update(Buffer.concat([keyBuf, b4a.from(':control')])).digest()
  const ctrlSwarm = new Hyperswarm()
  swarms.push(ctrlSwarm)
  ctrlSwarm.join(ctrlTopic, { server: role === 'writer', client: true })
  ctrlSwarm.on('connection', (conn) => {
    conn.on('error', (e) => send({ evt: 'log', msg: 'ctrl: ' + (e.code || e.message) }))
    if (role === 'writer') serveControl(conn)
    // Joiner-side control replies arrive here too (see redeem()).
    controlFeed(conn)
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
  // Admin (this device created the library): reopen from the local
  // primary-key credential.
  if (fs.existsSync(PK_STORE_PATH())) return restoreAdmin()
  // Member: restore the redeemed session (no wipe — local writes).
  const meta = loadLibraryMeta()
  if (!meta || !meta.key || !meta.primaryKey) return
  log('restoring member session for ' + (meta.name || meta.key.slice(0, 12)))
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
  // The primary key NEVER leaves this device via IPC — redemption
  // dispenses it over the encrypted control channel. Persist LOCALLY
  // (admin credential); the admin UI gets invites from generateJoinKey.
  fs.writeFileSync(PK_STORE_PATH(), store.primaryKey.toString('hex'))
  const topic = announce(key)
  send({ evt: 'created', key: key.toString('hex'), name, port: listenPort })
  log('library created: ' + name)
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

// --- Single-use join tokens (redemption handshake) ---
//
// The ADMIN holds the primary key and NEVER broadcasts it. The invite
// string lc1.<driveKey>.<token> carries only the discovery topic and a
// one-time token. The joiner:
//   1. opens the drive READ-ONLY (public key) — replication starts,
//      content flows, but nothing can be written
//   2. dials the control topic (driveKey+':control' hashed) and sends
//      {cmd:'redeem', token, memberName}
//   3. the ADMIN validates the token against its keys store:
//        pending → mark used {usedBy, usedAt}, reply {ok:true,
//        primaryKey} — the joiner re-opens its store WRITABLE and
//        announces /members/<token>.json
//        used/revoked/unknown → reply {ok:false, why} — joiner stays
//        read-only (that IS the guest state) and the event surfaces
//        in the admin UI
// Revocation = the admin marks the token revoked; redemption refuses.
// (True cryptographic revocation of an ALREADY-redeemed writer is the
// primary-key rotation story, documented for v2.)
//
// Keys store: LOCAL file on the admin device (keys.json in storageRoot)
// — the admin device is the single writer until redemption, so no
// replication race. Members list is PUBLISHED to /meta/members.json in
// the drive so the admin UI on other devices stays consistent.

const KEY_STORE_PATH = () => path.join(storageRoot, 'keys.json')
const CTRL_MAGIC = 'lc1-ctrl'

function loadKeys() {
  try { return JSON.parse(fs.readFileSync(KEY_STORE_PATH(), 'utf8')) } catch { return [] }
}

function saveKeys(keys) {
  fs.writeFileSync(KEY_STORE_PATH(), JSON.stringify(keys, null, 2))
  // Mirror the (sanitized) list into the drive for cross-device admin UI.
  if (drive && role === 'writer') {
    const publicList = keys.map(k => ({ token: k.token, role: k.role, state: k.state, usedBy: k.usedBy, usedAt: k.usedAt, createdAt: k.createdAt }))
    drive.put('/meta/keys.json', b4a.from(JSON.stringify(publicList))).catch(() => {})
  }
}

function generateJoinKey(role) {
  const keys = loadKeys()
  const token = crypto.randomBytes(16).toString('hex')
  keys.push({ token, role: role || 'editor', createdAt: Date.now(), state: 'pending', usedBy: null, usedAt: null })
  saveKeys(keys)
  send({ evt: 'joinKeyGenerated', token })
  return keys[keys.length - 1]
}

function listJoinKeys() {
  send({ evt: 'joinKeys', keys: loadKeys() })
}

function revokeJoinKey(token) {
  const keys = loadKeys()
  const k = keys.find(x => x.token === token)
  if (k) { k.state = 'revoked'; saveKeys(keys) }
  send({ evt: 'joinKeyRevoked', token })
}

// --- Control channel ---

function controlSend(conn, obj) {
  conn.write(b4a.from(JSON.stringify(obj) + '\n'))
}

// Admin side: answer redeem requests. NDJSON lines after a magic line.
function serveControl(conn) {
  let buf = ''
  conn.on('data', (chunk) => {
    buf += chunk.toString()
    let idx
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx)
      buf = buf.slice(idx + 1)
      let msg
      try { msg = JSON.parse(line) } catch { continue }
      if (msg.magic !== CTRL_MAGIC) continue
      if (msg.cmd === 'redeem') {
        const keys = loadKeys()
        const k = keys.find(x => x.token === msg.token)
        if (!k) { controlSend(conn, { magic: CTRL_MAGIC, cmd: 'redeemResult', ok: false, why: 'unknown' }); continue }
        if (k.state === 'revoked') { controlSend(conn, { magic: CTRL_MAGIC, cmd: 'redeemResult', ok: false, why: 'revoked' }); continue }
        if (k.state === 'used') { controlSend(conn, { magic: CTRL_MAGIC, cmd: 'redeemResult', ok: false, why: 'already-used' }); continue }
        k.state = 'used'
        k.usedBy = msg.memberName || 'Unknown'
        k.usedAt = Date.now()
        saveKeys(keys)
        send({ evt: 'memberJoined', token: k.token, name: k.usedBy, role: k.role })
        controlSend(conn, { magic: CTRL_MAGIC, cmd: 'redeemResult', ok: true, primaryKey: store.primaryKey.toString('hex'), role: k.role })
      } else if (msg.cmd === 'ping') {
        controlSend(conn, { magic: CTRL_MAGIC, cmd: 'pong' })
      }
    }
  })
}

// Joiner side: collect control replies.
const controlWaiters = []
function controlFeed(conn) {
  let buf = ''
  conn.on('data', (chunk) => {
    buf += chunk.toString()
    let idx
    while ((idx = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, idx)
      buf = buf.slice(idx + 1)
      let msg
      try { msg = JSON.parse(line) } catch { continue }
      if (msg.magic !== CTRL_MAGIC) continue
      if (msg.cmd === 'redeemResult') {
        const waiter = controlWaiters.shift()
        if (waiter) waiter(msg)
      }
    }
  })
}

// Joiner: dial the control topic, present the token, await the result.
async function redeemToken(driveKeyHex, token, memberName) {
  const ctrlTopic = crypto.createHash('sha256').update(Buffer.concat([b4a.from(driveKeyHex, 'hex'), b4a.from(':control')])).digest()
  const ctrlSwarm = new Hyperswarm()
  swarms.push(ctrlSwarm)
  ctrlSwarm.on('connection', (conn) => {
    conn.on('error', (e) => send({ evt: 'log', msg: 'ctrl: ' + (e.code || e.message) }))
    controlFeed(conn)
    controlSend(conn, { magic: CTRL_MAGIC, cmd: 'redeem', token, memberName })
  })
  ctrlSwarm.join(ctrlTopic, { server: false, client: true })
  const result = await new Promise((resolve) => {
    const timeout = setTimeout(() => resolve({ ok: false, why: 'timeout — is the owner online?' }), 20000)
    controlWaiters.push((msg) => { clearTimeout(timeout); resolve(msg) })
  })
  await ctrlSwarm.flush().catch(() => {})
  return result
}


// --- Admin restore + joiner v2 ---

const PK_STORE_PATH = () => path.join(storageRoot, 'primary-key.hex')

// Admin: reopen the WRITER store from the locally persisted primary key.
// The primary key file never leaves this device.
async function restoreAdmin() {
  if (drive) return
  let pkHex
  try { pkHex = fs.readFileSync(PK_STORE_PATH(), 'utf8').trim() } catch { return }
  if (pkHex.length !== 64) return
  store = new Corestore(path.join(storageRoot, 'store'), { primaryKey: b4a.from(pkHex, 'hex'), unsafe: true })
  drive = new Hyperdrive(store)
  await drive.ready()
  role = 'writer'
  announce(drive.key)
  send({ evt: 'restored', key: drive.key.toString('hex'), writable: true })
  log('restored admin library ' + drive.key.toString('hex').slice(0, 12))
  startPolling()
}

// Joiner: open READ-ONLY by public key, then redeem the token over the
// control channel. On success, re-open WRITABLE with the dispensed
// primary key and announce membership.
async function joinV2(keyHex, token, memberName) {
  if (drive) return send({ evt: 'error', msg: 'already have a library' })
  const storePath = path.join(storageRoot, 'store')
  fs.rmSync(storePath, { recursive: true, force: true })   // fresh join
  store = new Corestore(storePath)
  const keyBuf = b4a.from(keyHex, 'hex')
  drive = new Hyperdrive(store, keyBuf)
  await drive.ready()
  role = 'reader'
  announce(keyBuf)
  send({ evt: 'joined', key: keyHex, writable: false })
  log('joined read-only, redeeming token…')

  const result = await redeemToken(keyHex, token, memberName)
  if (!result.ok) {
    // Stays read-only — the guest state. Admin sees nothing new.
    send({ evt: 'redeemFailed', why: result.why })
    log('token redeem failed: ' + result.why)
    startPolling()
    return
  }
  // Success: mark used admin-side already happened; re-open writable.
  const pkHex = result.primaryKey
  drive = null
  store = null
  fs.rmSync(storePath, { recursive: true, force: true })
  store = new Corestore(storePath, { primaryKey: b4a.from(pkHex, 'hex'), unsafe: true })
  drive = new Hyperdrive(store)
  await drive.ready()
  role = 'writer'
  announce(keyBuf)
  send({ evt: 'joined', key: keyHex, writable: true, role: result.role || 'editor' })
  log('redeemed — writable as ' + (result.role || 'editor'))
  await drive.put('/members/' + token + '.json', b4a.from(JSON.stringify({ memberName, joinedAt: Date.now() })))
  saveLibraryMeta({ key: keyHex, primaryKey: pkHex })
  startPolling()
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
      // Admin restore: reopen the writer store from the LOCAL primary
      // key file (never sent over IPC by the worklet itself).
      case 'restore': restoreAdmin().catch(e => send({ evt: 'error', msg: 'restore failed: ' + e.message })); break
      // Joiner: read-only open + token redemption handshake.
      case 'joinV2': joinV2(msg.key, msg.token, msg.memberName).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'listen': listenTcp(msg.port || 8787); break
      case 'connect': connectTcp(msg.host, msg.port || 8787); break
      case 'putRaw': putRaw(msg.path, msg.data).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'readRaw': readRaw(msg.path).catch(e => send({ evt: 'error', msg: e.message })); break
      case 'generateJoinKey': generateJoinKey(msg.role); break
      case 'listJoinKeys': listJoinKeys(); break
      case 'revokeJoinKey': revokeJoinKey(msg.token); break
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
