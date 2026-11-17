// ABOUTME: Preloaded into the extension server under test: records and refuses every outbound request
// ABOUTME: and every attempt to open a listening socket, so a test can assert neither happened
'use strict'
// Loaded with NODE_OPTIONS=--require. It serves no responses: a request the
// server makes fails, and the attempt is appended to COUNCIL_FENCE_LOG as one
// JSON line, {"fetch": <url>, "authorized": <bool>, "redirect": <what the
// request does with a redirect, "follow" when it does not say>} or {"listen": true}.
const fs = require('node:fs')
const net = require('node:net')

const log = process.env.COUNCIL_FENCE_LOG
function record(entry) {
  fs.appendFileSync(log, `${JSON.stringify(entry)}\n`)
}

globalThis.fetch = async (url, init) => {
  const headers = new Headers(init?.headers)
  record({ fetch: String(url), authorized: headers.has('authorization') || headers.has('x-goog-api-key'), redirect: init?.redirect ?? 'follow' })
  throw new Error('network fenced off in tests')
}

net.Server.prototype.listen = function fencedListen() {
  record({ listen: true })
  throw new Error('listening fenced off in tests')
}
