#!/usr/bin/env node
// Registers the vendored Pears frameworks + worklet bundles in project.yml.
// Reads the framework list from the filesystem — never from shell output.
const fs = require('fs')
const path = require('path')

const vendor = path.join(__dirname, '..', 'Vendor')
const frameworks = fs.readdirSync(vendor).filter(f => f.endsWith('.xcframework')).sort()
console.log('found', frameworks.length, 'xcframeworks')

const ymlPath = path.join(__dirname, '..', 'project.yml')
let s = fs.readFileSync(ymlPath, 'utf8')

// Edit 1: bundle resources after the CHANGELOG resource
const resAnchor = [
  '      - path: CHANGELOG.md',
  '        buildPhase: resources',
].join('\n')
const resAdd = [
  resAnchor,
  '      # Pears worklet bundles (Bare JS entry-pears.js packed per slice).',
  '      # PearsSyncEngine loads them by name at runtime.',
  '      - path: spikes/bare-ios-spike/pears-ios.bundle',
  '        buildPhase: resources',
  '      - path: spikes/bare-ios-spike/pears-sim.bundle',
  '        buildPhase: resources',
].join('\n')
if (!s.includes(resAnchor)) { console.error('res anchor missing'); process.exit(1) }
if (s.includes('pears-ios.bundle')) {
  console.log('resources already registered')
} else {
  s = s.replace(resAnchor, resAdd)
}

// Edit 2: frameworks after the MarkdownUI dependency
const depAnchor = [
  '    dependencies:',
  '      - package: MarkdownUI',
  '        product: MarkdownUI',
].join('\n')
const fwLines = frameworks.map(f => '      - framework: Vendor/' + f).join('\n')
const depAdd = [
  '    dependencies:',
  '      - package: MarkdownUI',
  '        product: MarkdownUI',
  '      # Pears (Bare runtime + Hypercore addons) — vendored xcframeworks.',
  '      # XcodeGen embeds + signs these for app targets automatically.',
  fwLines,
].join('\n')
if (!s.includes(depAnchor)) { console.error('dep anchor missing'); process.exit(1) }
if (s.includes('- framework: Vendor/')) {
  console.log('frameworks already registered — replacing block')
  const start = s.indexOf('      # Pears (Bare runtime')
  const end = s.indexOf('\n    settings:', start)
  if (start < 0 || end < 0) { console.error('block bounds missing'); process.exit(1) }
  s = s.slice(0, start) + '      # Pears (Bare runtime + Hypercore addons) — vendored xcframeworks.\n      # XcodeGen embeds + signs these for app targets automatically.\n' + fwLines + s.slice(end)
} else {
  s = s.replace(depAnchor, depAdd)
}

fs.writeFileSync(ymlPath, s)
console.log('edits applied')
