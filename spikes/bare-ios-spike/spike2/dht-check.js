const Hyperswarm = require('hyperswarm')
const swarm = new Hyperswarm()
console.log('bootstrapping...')
setTimeout(() => {
  console.log('dht status: holepunchable =', swarm.dht.holepunchable, 'bootstrapped =', swarm.dht.bootstrapped)
  const nodes = []
  swarm.dht.on('nat-update', (firewalled, remote) => console.log('nat-update:', firewalled, remote))
  process.exit && setTimeout(() => { require('bare-process').exit(0) }, 100)
}, 6000)
swarm.on('error', e => console.log('swarm error:', e.message))
