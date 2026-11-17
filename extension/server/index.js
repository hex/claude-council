// ABOUTME: Claude Desktop extension server: the council as MCP tools over stdio, plus the panels they draw
// ABOUTME: Tool results, errors and logs pass one chokepoint that removes the user's API keys from them
'use strict'
const crypto = require('node:crypto')
const fs = require('node:fs')
const path = require('node:path')
const council = require('./council.js')

const EXTENSION_ROOT = path.join(__dirname, '..')
const VERSION = JSON.parse(fs.readFileSync(path.join(EXTENSION_ROOT, 'manifest.json'), 'utf8')).version
const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']
const PANEL_MIME = 'text/html;profile=mcp-app'

// A panel's page with each `@include <file>` line replaced by that file, so
// the panels share one stylesheet and one host connection.
function panelPage(file) {
  const page = fs.readFileSync(path.join(__dirname, file), 'utf8')
  return page.replace(/^[ \t]*(?:\/\*|\/\/) @include ([a-z-]+\.(?:css|js))(?: \*\/)?$/gm,
    (line, included) => fs.readFileSync(path.join(__dirname, included), 'utf8').trimEnd())
}

// A panel as served, at an address that ends in a hash of its page. Desktop
// keeps a page by its address across an extension upgrade, so a page that
// changes must change its address too, or the old page is shown.
function panel(page, name) {
  const text = panelPage(`${page}.html`)
  const hash = crypto.createHash('sha256').update(text).digest('hex').slice(0, 12)
  return { uri: `ui://council/${page}/${hash}`, name, text }
}

const PANELS = [panel('settings', 'Council models'), panel('answers', 'Council answers'), panel('pick', 'Council picker')]
const [SETTINGS_PANEL, ANSWERS_PANEL, PICK_PANEL] = PANELS

const { keys, tooShort } = council.readKeys(process.env)
const theCouncil = council.openCouncil({ root: council.findPluginRoot(EXTENSION_ROOT), keys, tooShort, redact })
const KEY_MARK = '[key removed]'

// Whether the connected app said it draws a tool's panel inside the chat.
let drawsPanel = false

// Each key as it is written, and as it reads inside JSON text such as the
// panel data, where a quote or backslash in it would be escaped.
const KEY_SPELLINGS = [...new Set([...keys.values()].flatMap(key => [key, JSON.stringify(key).slice(1, -1)]))]

// Replaces every key value in every string of what the council's scripts and
// providers produced. Error text from a provider can quote the key it was
// sent; nothing here may pass it on. The server's own words (the envelope,
// tool names, schemas, panel pages) are left alone: they hold no key.
function redact(value) {
  if (typeof value === 'string') {
    let text = value
    for (const spelling of KEY_SPELLINGS) text = text.split(spelling).join(KEY_MARK)
    return text
  }
  if (Array.isArray(value)) return value.map(redact)
  if (value !== null && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, redact(item)]))
  return value
}

function send(message) {
  process.stdout.write(`${JSON.stringify({ jsonrpc: '2.0', ...message })}\n`)
}

function log(text) {
  process.stderr.write(`${redact(text)}\n`)
}

const NO_ARGUMENTS = { type: 'object', properties: {}, additionalProperties: false }

// The council should hear what the user asked. A model told only that the
// council sees nothing else rewrites the question and adds angles of its own.
const AS_ASKED = 'Pass the user\'s question as they asked it, adding context only when their message depends on earlier conversation the council cannot see.'
const QUESTION_AS_ASKED = 'The user\'s question, as they asked it.'
const RUNS_AT_ONCE = 'Use it when the user named the seats or a verbosity, or said to just ask everyone; it then runs at once with the seats and verbosity given, or with every default seat at standard. When the user asks without naming either, or asks to choose them, call council_pick instead.'

const TOOLS = [
  {
    name: 'council_ask',
    // Read when tools/list is answered, after initialize said whether the
    // app draws the answers panel.
    get description() {
      const about = `Ask the council, several other AI models, one question and get each one's answer. The question goes to third-party providers (Gemini, OpenAI, xAI, Perplexity, Kimi, OpenRouter, and any CLI agents installed) on the user's own API keys, and they see nothing but the question. ${AS_ASKED} ${RUNS_AT_ONCE} The result has one section per council seat.`
      const synthesis = 'where the seats agree, where they differ, and what you recommend. A run can take several minutes.'
      return drawsPanel
        ? `${about} Claude Desktop shows every seat's answer in a panel above your reply, so do not repeat the answers: write your synthesis of them, ${synthesis}`
        : `${about} Show the user each seat's answer as returned, then write your own synthesis after them: ${synthesis}`
    },
    _meta: { ui: { resourceUri: ANSWERS_PANEL.uri } },
    inputSchema: {
      type: 'object',
      properties: {
        question: { type: 'string', description: QUESTION_AS_ASKED },
        providers: { type: 'array', items: { type: 'string' }, description: 'Seat names, such as codex or openrouter-2. Leave out to ask every default seat.' },
        verbosity: { type: 'string', enum: council.VERBOSITIES, description: 'How long the answers should be. Defaults to standard.' },
      },
      required: ['question'],
      additionalProperties: false,
    },
    run: (args, signal) => theCouncil.ask(args, signal),
  },
  // The picker panel and the tool its Ask button calls.
  {
    name: 'council_pick',
    description: `Open the council picker: a panel in the chat with the question, each council seat with its model and a switch, a choice of verbosity and an Ask button. The council runs when the user presses Ask, and the answers appear in the panel. Its result names a council run: call council_result with it at once, in the same turn, and it gives you the answers when they are in. Use it when the user asks the council without naming the seats or a verbosity, or asks to choose them; when the user named them or said to just ask everyone, call council_ask instead. ${AS_ASKED} ${council.AFTER_PICK}`,
    inputSchema: { type: 'object', properties: { question: { type: 'string', description: QUESTION_AS_ASKED } }, required: ['question'], additionalProperties: false },
    _meta: { ui: { resourceUri: PICK_PANEL.uri } },
    run: (args, signal) => theCouncil.pick(args, drawsPanel, signal),
  },
  {
    name: 'council_pick_ask',
    description: 'Asks the council the question with the seats and verbosity chosen in the council picker. Used by the panel only.',
    inputSchema: { type: 'object', properties: { question: { type: 'string' }, providers: { type: 'array', items: { type: 'string' } }, verbosity: { type: 'string', enum: council.VERBOSITIES }, run: { type: 'string', pattern: '^[0-9a-f]{6}$' } }, required: ['question'], additionalProperties: false },
    _meta: { ui: { visibility: ['app'] } },
    // council_ask's own function underneath, so the panel's runs pass every
    // check a model's do.
    run: (args, signal) => theCouncil.pickAsk(args, signal),
  },
  {
    name: 'council_result',
    description: 'Get the answers of a council run made in the council picker panel. Right after council_pick, call it with the run council_pick named, in the same turn and before you write anything: it waits until the user presses Ask and the council answers. Also call it when the user asks for the synthesis of a council run, as in "Synthesise the council\'s answers (run 3f9a2c)", passing that run id, or with no run for the latest run held, which it gives at once without waiting. The picker shows the answers to the user; this tool gives them to you, so never say you cannot see them. The user has already read each seat\'s answer in the picker, so do not repeat them: write only your own synthesis, saying where the seats agree, where they differ, and what you recommend. The run holds only the seats the user chose in the picker, so the other seats of the council are not missing answers.',
    inputSchema: { type: 'object', properties: { run: { type: 'string', description: 'The run id the user\'s message names, such as 3f9a2c. Leave out for the latest run held, given at once.' } }, additionalProperties: false },
    run: (args, signal) => theCouncil.result(args, signal),
  },
  {
    name: 'council_status',
    description: 'Show which council providers are usable on this machine, the model each would use, and why the others are not.',
    inputSchema: NO_ARGUMENTS,
    run: (args, signal) => theCouncil.status(args, signal),
  },
  {
    name: 'council_settings',
    description: 'Show the model each council provider uses. In Claude Desktop this also opens a panel in the chat where the user picks models from each provider\'s live list. Use when the user wants to see or change the council\'s models.',
    inputSchema: NO_ARGUMENTS,
    _meta: { ui: { resourceUri: SETTINGS_PANEL.uri } },
    run: (args, signal) => theCouncil.settingsText(drawsPanel, signal),
  },
  {
    name: 'council_models_data',
    description: 'Loads the council settings panel: each provider\'s model list and saved choice. Used by the panel only.',
    inputSchema: NO_ARGUMENTS,
    _meta: { ui: { visibility: ['app'] } },
    run: (args, signal) => theCouncil.panelData(args, signal),
  },
  {
    name: 'council_models_save',
    description: 'Saves a change made in the council settings panel, the model of each provider named (selections) or one model added to or taken out of the OpenRouter roster (roster), or one seat\'s model chosen in the council picker (seat and model). Every other saved choice is kept. Used by the panels only.',
    inputSchema: { type: 'object', properties: { selections: { type: 'object' }, roster: { type: 'object' }, seat: { type: 'string' }, model: { type: 'string' } }, additionalProperties: false },
    _meta: { ui: { visibility: ['app'] } },
    run: (args, signal) => theCouncil.saveFromPanel(args, signal),
  },
]

// Each tool call still running, by request id, with the controller whose
// abort stops the runs it started and the promise of its outcome.
const callsInFlight = new Map()

async function callTool(id, params) {
  const tool = TOOLS.find(candidate => candidate.name === params?.name)
  if (!tool) return send({ id, error: { code: -32602, message: `unknown tool: ${String(params?.name)}` } })
  const controller = new AbortController()
  const outcomePromise = Promise.resolve().then(() => tool.run(params.arguments ?? {}, controller.signal))
  callsInFlight.set(id, { controller, outcome: outcomePromise })
  let outcome
  let failure
  try {
    outcome = await outcomePromise
  } catch (err) {
    if (err instanceof council.Refusal) outcome = { text: err.message, isError: true }
    else failure = err
  } finally {
    callsInFlight.delete(id)
  }
  // A cancelled request is never answered, and neither is one cut short by
  // the server's own exit, however its tool ended; a tool's failure is then
  // only logged.
  if (controller.signal.aborted || shuttingDown) {
    if (failure !== undefined) log(`council extension: ${tool.name} failed in a call that is never answered: ${failure?.stack ?? failure}`)
    return
  }
  if (failure !== undefined) throw failure
  const result = { content: [{ type: 'text', text: redact(outcome.text) }], isError: Boolean(outcome.isError) }
  if (outcome.structured) result.structuredContent = redact(outcome.structured)
  send({ id, result })
}

async function handle(message) {
  const { id, method, params } = message
  if (method === 'initialize') {
    drawsPanel = Boolean(params?.capabilities?.extensions?.['io.modelcontextprotocol/ui'])
    const protocolVersion = PROTOCOL_VERSIONS.includes(params?.protocolVersion) ? params.protocolVersion : PROTOCOL_VERSIONS[0]
    return send({ id, result: { protocolVersion, capabilities: { tools: {}, resources: {} }, serverInfo: { name: 'council', version: VERSION } } })
  }
  if (method === 'ping') return send({ id, result: {} })
  if (method === 'tools/list') return send({ id, result: { tools: TOOLS.map(({ run, ...definition }) => definition) } })
  if (method === 'tools/call') return callTool(id, params)
  if (method === 'resources/list') return send({ id, result: { resources: PANELS.map(({ uri, name }) => ({ uri, name, mimeType: PANEL_MIME })) } })
  if (method === 'resources/templates/list') return send({ id, result: { resourceTemplates: [] } })
  if (method === 'resources/read') {
    const panel = PANELS.find(candidate => candidate.uri === params?.uri)
    if (!panel) return send({ id, error: { code: -32002, message: `resource not found: ${String(params?.uri)}` } })
    return send({ id, result: { contents: [{ uri: panel.uri, mimeType: PANEL_MIME, text: panel.text }] } })
  }
  send({ id, error: { code: -32601, message: `method not found: ${method}` } })
}

function receive(line) {
  if (line.trim() === '') return
  let message
  try {
    message = JSON.parse(line)
  } catch {
    return send({ id: null, error: { code: -32700, message: 'parse error: the line is not JSON' } })
  }
  if (message === null || typeof message !== 'object' || Array.isArray(message) || typeof message.method !== 'string') {
    return send({ id: message?.id ?? null, error: { code: -32600, message: 'invalid request: expected a JSON-RPC request object' } })
  }
  // A notification is never answered, whether or not it is understood.
  if (message.id === undefined) {
    if (message.method === 'notifications/cancelled') callsInFlight.get(message.params?.requestId)?.controller.abort()
    return
  }
  handle(message).catch(err => {
    log(`council extension: ${message.method} failed: ${err?.stack ?? err}`)
    send({ id: message.id, error: { code: -32603, message: redact(`internal error: ${err?.message ?? err}`) } })
  })
}

// The longest request line read. The longest a real request needs is a
// question at its limit with every character escaped, well under this.
const MAX_LINE_BYTES = 1024 * 1024

// Splits the input into lines on the newline byte, which never occurs inside
// a UTF-8 character, so a line is decoded whole. A line past the limit is
// dropped as it arrives rather than held, and answered with one error.
function readLines(input, onLine, onEnd) {
  let pending = []
  let pendingBytes = 0
  let dropping = false
  const take = piece => {
    if (dropping) return
    if (pendingBytes + piece.length > MAX_LINE_BYTES) {
      dropping = true
      pending = []
      pendingBytes = 0
      send({ id: null, error: { code: -32600, message: `invalid request: a line over ${MAX_LINE_BYTES} bytes was dropped` } })
      return
    }
    pending.push(piece)
    pendingBytes += piece.length
  }
  const finishLine = () => {
    const line = dropping ? null : Buffer.concat(pending).toString('utf8')
    pending = []
    pendingBytes = 0
    dropping = false
    if (line !== null) onLine(line)
  }
  input.on('data', chunk => {
    let start = 0
    for (let newline = chunk.indexOf(10); newline !== -1; newline = chunk.indexOf(10, start)) {
      take(chunk.subarray(start, newline))
      finishLine()
      start = newline + 1
    }
    take(chunk.subarray(start))
  })
  input.on('end', () => {
    if (pendingBytes > 0) finishLine()
    onEnd()
  })
}

let shuttingDown = false

// How long the calls still going have, once their runs are stopped, to end:
// a picker's ask to write its outcome for a council_result waiting in another
// copy of the server, a waiting council_result to remove its marker.
const CALLS_END_MS = 1000

// Exits once every council run still going has been stopped, since a run is
// in a process group of its own and would otherwise outlive the server, and
// every call has ended or had its time to. Asked again while it is at work,
// it does nothing: the first exit goes on. It exits even when the stopping
// itself fails, since nothing else would end the server by then.
async function shutDown(exitCode) {
  if (shuttingDown) return
  shuttingDown = true
  try {
    await theCouncil.stopRuns()
    const calls = [...callsInFlight.values()]
    for (const call of calls) call.controller.abort()
    await Promise.race([Promise.allSettled(calls.map(call => call.outcome)), new Promise(done => setTimeout(done, CALLS_END_MS))])
  } catch (err) {
    log(`council extension: could not stop every run before exiting: ${err?.stack ?? err}`)
    process.exit(1)
  }
  process.exit(exitCode)
}

// Ends the server for an error nothing handled, by the same exit as any
// other, so no run outlives it.
function crash(err) {
  log(`council extension: exiting on an error: ${err?.stack ?? err}`)
  shutDown(1)
}

// An app that stops reading the server's output makes the next reply's write
// fail; with no reader left there is nothing to serve.
process.stdout.on('error', crash)
process.on('uncaughtException', crash)
// A log that cannot be written ends the server too, without a line about it:
// the log is what failed.
process.stderr.on('error', () => shutDown(1))

// Desktop ends the server by closing its input; a signal ends it as usual.
readLines(process.stdin, receive, () => shutDown(0))
process.on('SIGTERM', () => shutDown(128 + 15))
process.on('SIGINT', () => shutDown(128 + 2))
