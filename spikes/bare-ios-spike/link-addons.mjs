import path from 'path'
import { fileURLToPath } from 'url'
import link from 'bare-link'

const __filename = fileURLToPath(import.meta.url)

// From spikes/bare-ios-spike/: the spike's own node_modules holds the P2P
// deps (hyperswarm, hypercore, bare-crypto, ...); addons land in ./addons.
for await (const resource of link(path.join(__filename, '..'), {
  hosts: ['ios-arm64', 'ios-arm64-simulator'],
  out: path.join(__filename, '..', 'addons')
})) {
  console.log('Wrote', resource)
}
