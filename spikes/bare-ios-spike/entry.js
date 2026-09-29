// Spike entry: proves the Bare runtime boots on-device, loads the P2P stack
// (Hypercore/Hyperswarm), and can talk to Swift over the IPC pipe.
//
// IPC: iOS bare-kit injects a global `BareKit` with `.IPC` (a duplex over
// the worklet bridge) — process.stdout does NOT reach Swift. The host
// fallback uses bare-process stdio. Both sides speak newline-delimited JSON.
//   Swift → JS: {"cmd":"ping","n":1}   → {"pong":n}
//               {"cmd":"net-start"}     → {"net":"ready"}
//   JS → Swift: {"evt":"boot"|"log"|...}

const { stdin, stdout } = require('bare-process')

const onDevice = typeof BareKit !== 'undefined' && !!BareKit.IPC
const ipc = onDevice
  ? BareKit.IPC
  : { out: stdout, in: stdin }

let version
try {
  version = require('bare-os')
} catch {}

function send(obj) {
  try {
    if (onDevice) ipc.write(Buffer.from(JSON.stringify(obj) + '\n'))
    else ipc.out.write(JSON.stringify(obj) + '\n')
  } catch (e) {
    // Swallow — a dead pipe must not kill the worklet.
  }
}

let buffer = ''
function attachReader() {
  const feed = (chunk) => {
    buffer += chunk.toString()
    let idx
    while ((idx = buffer.indexOf('\n')) >= 0) {
      const line = buffer.slice(0, idx)
      buffer = buffer.slice(idx + 1)
      if (!line.trim()) continue
      let msg
      try { msg = JSON.parse(line) } catch { continue }
      if (msg.cmd === 'ping') {
        send({ pong: msg.n ?? 0, platform: onDevice ? 'bare-ios' : 'bare-host', os: version?.platform ?? 'unknown' })
      } else if (msg.cmd === 'net-start') {
        startNet()
      }
    }
  }
  if (onDevice) ipc.on('data', feed)
  else ipc.in.on('data', feed)
}
attachReader()

console.log('[spike-entry] boot event firing')
send({ evt: 'boot' })

// Hyperswarm: prove raw sockets + DHT wire up.
function startNet() {
  try {
    const Hyperswarm = require('hyperswarm')
    const crypto = require('bare-crypto')
    const swarm = new Hyperswarm()
    const topic = crypto.createHash('sha256').update('librarycove-spike').digest()
    swarm.join(topic, { server: true, client: false })
    swarm.on('connection', (conn) => {
      send({ evt: 'peer', info: conn.publicKey?.toString?.('hex')?.slice(0, 12) ?? 'unknown' })
      conn.on('data', () => {})
    })
    send({ evt: 'net', state: 'ready', topic: topic.toString('hex').slice(0, 12) })
  } catch (e) {
    send({ evt: 'net', state: 'error', msg: String(e && e.message ? e.message : e) })
  }
}
