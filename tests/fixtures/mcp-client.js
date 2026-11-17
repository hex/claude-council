// ABOUTME: Drives the extension's stdio MCP server the way Claude Desktop does, one request at a time
// ABOUTME: Prints every line the server writes, then exits with the server's own exit code
'use strict'
// Usage: node mcp-client.js <server.js> <requests-file>
// Each line of the requests file is written to the server as is. A line that
// parses as an object with an id waits for the reply carrying that id before
// the next line goes; any other line is followed by a short pause, so a reply
// it provokes (a parse error) still lands in order. After the last line the
// server's input is closed, and the server must then exit on its own within
// CLIENT_EXIT_WAIT_MS, or this exits 124.
// A line may name a value from an earlier reply as {{<id>.<path>}}, such as
// {{2.result.resources.0.uri}}, for a value the server makes up at run time
// (a panel address, a run id); it is written in as a JSON string's content.
// CLIENT_CONCURRENT=1 writes every line at once and then waits for all the
// replies. CLIENT_CLOSE_WHEN=<path> writes every line at once and closes the
// input as soon as that file exists, without waiting for any reply.
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const readline = require('node:readline')

const [serverPath, requestsPath] = process.argv.slice(2)
const REPLY_WAIT_MS = Number(process.env.CLIENT_REPLY_WAIT_MS ?? 60000)
const EXIT_WAIT_MS = Number(process.env.CLIENT_EXIT_WAIT_MS ?? 10000)
const lines = fs.readFileSync(requestsPath, 'utf8').split('\n').filter(line => line !== '')

const server = spawn(process.execPath, [serverPath], { stdio: ['pipe', 'pipe', 'inherit'] })
const replies = new Map()
const waiting = new Map()
readline.createInterface({ input: server.stdout }).on('line', line => {
  process.stdout.write(`${line}\n`)
  let parsed
  try {
    parsed = JSON.parse(line)
  } catch {
    return
  }
  const id = parsed.id
  replies.set(id, parsed)
  waiting.get(id)?.()
})

function replyTo(id) {
  if (replies.has(id)) return Promise.resolve()
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`no reply to request ${id} within ${REPLY_WAIT_MS} ms`)), REPLY_WAIT_MS)
    waiting.set(id, () => { clearTimeout(timer); waiting.delete(id); resolve() })
  })
}

function filledIn(line) {
  return line.replace(/\{\{([0-9]+)((?:\.[A-Za-z0-9_]+)+)\}\}/g, (named, id, path) => {
    if (!replies.has(Number(id))) throw new Error(`${named} names request ${id}, which has had no reply`)
    const value = path.slice(1).split('.').reduce((at, step) => at?.[step], replies.get(Number(id)))
    if (typeof value !== 'string') throw new Error(`${named} is ${JSON.stringify(value)}, not a string`)
    return JSON.stringify(value).slice(1, -1)
  })
}

function idOf(line) {
  try {
    const parsed = JSON.parse(line)
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? parsed.id : undefined
  } catch {
    return undefined
  }
}

function fileAppears(file) {
  return new Promise((resolve, reject) => {
    const started = Date.now()
    const timer = setInterval(() => {
      if (fs.existsSync(file)) { clearInterval(timer); resolve() }
      else if (Date.now() - started > REPLY_WAIT_MS) { clearInterval(timer); reject(new Error(`${file} did not appear within ${REPLY_WAIT_MS} ms`)) }
    }, 50)
  })
}

async function send() {
  if (process.env.CLIENT_CLOSE_WHEN) {
    for (const line of lines) server.stdin.write(`${line}\n`)
    return fileAppears(process.env.CLIENT_CLOSE_WHEN)
  }
  if (process.env.CLIENT_CONCURRENT === '1') {
    for (const line of lines) server.stdin.write(`${line}\n`)
    for (const line of lines) {
      const id = idOf(line)
      if (id !== undefined) await replyTo(id)
    }
    return
  }
  for (const line of lines) {
    server.stdin.write(`${filledIn(line)}\n`)
    const id = idOf(line)
    if (id === undefined) await new Promise(resolve => setTimeout(resolve, 300))
    else await replyTo(id)
  }
}

async function main() {
  await send()
  server.stdin.end()
  const timer = setTimeout(() => {
    process.stderr.write(`server still running ${EXIT_WAIT_MS} ms after its input closed\n`)
    server.kill('SIGKILL')
    process.exit(124)
  }, EXIT_WAIT_MS)
  // Exits once everything printed has been read: on macOS a pipe takes 64 KB
  // at a time, and an exit before the reader caught up would cut a long reply.
  server.on('exit', code => {
    clearTimeout(timer)
    process.stdout.write('', () => process.exit(code ?? 1))
  })
}

main().catch(err => {
  process.stderr.write(`${err.message}\n`)
  server.kill('SIGKILL')
  process.exit(125)
})
