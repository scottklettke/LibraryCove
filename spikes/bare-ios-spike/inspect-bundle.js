// Parses a bare-pack length-prefixed bundle: line 1 = manifest length,
// then manifest JSON, then concatenated file contents per the offsets map.
// Usage: node inspect-bundle.js <bundle> [substring-filter]
const fs = require('fs')

const [bundle, filter] = process.argv.slice(2)
const raw = fs.readFileSync(bundle, 'utf8')
const nl = raw.indexOf('\n')
const len = parseInt(raw.slice(0, nl).trim(), 10)
const rest = raw.slice(nl + 1)
// Manifest ends at its own last top-level close brace (files map closes it).
const manifest = JSON.parse(rest.slice(0, len - 1))

console.log('main:', manifest.main)
const files = manifest.files || {}
const names = Object.keys(files).filter(k => !filter || k.includes(filter))
console.log('matching files:', names.length)
for (const name of names.slice(0, 6)) {
  console.log(' ', name, JSON.stringify(files[name]).slice(0, 120))
}
