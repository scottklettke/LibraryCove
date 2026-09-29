const { stdin, stdout } = require('bare-process')
stdout.write(JSON.stringify({ evt: 'boot', minimal: true }) + '\n')
stdin.on('data', () => {})
