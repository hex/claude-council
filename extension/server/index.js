// ABOUTME: Claude Desktop extension server: the council as MCP tools over stdio, plus its two panels
// ABOUTME: Every line it writes passes one chokepoint that removes the user's API keys from it
'use strict'
const fs = require('node:fs')
const path = require('node:path')
const readline = require('node:readline')
const council = require('./council.js')

const EXTENSION_ROOT = path.join(__dirname, '..')
const VERSION = JSON.parse(fs.readFileSync(path.join(EXTENSION_ROOT, 'manifest.json'), 'utf8')).version
const PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']
const PANEL_MIME = 'text/html;profile=mcp-app'

// A panel's page with each `@include <file>` line replaced by that file, so
// the two panels share one stylesheet and one host connection.
function panelPage(file) {
  const page = fs.readFileSync(path.join(__dirname, file), 'utf8')
  return page.replace(/^[ \t]*(?:\/\*|\/\/) @include ([a-z-]+\.(?:css|js))(?: \*\/)?$/gm,
    (line, included) => fs.readFileSync(path.join(__dirname, included), 'utf8').trimEnd())
}

const PANELS = [
  { uri: 'ui://council/settings', name: 'Council models', text: panelPage('settings.html') },
  { uri: 'ui://council/answers', name: 'Council answers', text: panelPage('answers.html') },
]
const [SETTINGS_PANEL, ANSWERS_PANEL] = PANELS

const keys = council.readKeys(process.env)
const theCouncil = council.openCouncil({ root: council.findPluginRoot(EXTENSION_ROOT), keys })
const KEY_MARK = '[key removed]'

// Whether the connected app said it draws a tool's panel inside the chat.
let drawsPanel = false

// Replaces every key value in every string of a message. Error text from a
// provider can quote the key it was sent; nothing here may pass it on.
function redact(value) {
  if (typeof value === 'string') {
    let text = value
    for (const key of keys.values()) text = text.split(key).join(KEY_MARK)
    return text
  }
  if (Array.isArray(value)) return value.map(redact)
  if (value !== null && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([name, item]) => [name, redact(item)]))
  return value
}

function send(message) {
  process.stdout.write(`${JSON.stringify(redact({ jsonrpc: '2.0', ...message }))}\n`)
}

function log(text) {
  process.stderr.write(`${redact(text)}\n`)
}

const NO_ARGUMENTS = { type: 'object', properties: {}, additionalProperties: false }

const TOOLS = [
  {
    name: 'council_ask',
    // Read when tools/list is answered, after initialize said whether the
    // app draws the answers panel.
    get description() {
      const about = 'Ask the council, several other AI models, one question and get each one\'s answer. The question goes to third-party providers (Gemini, OpenAI, xAI, Perplexity, Kimi, OpenRouter, and any CLI agents installed) on the user\'s own API keys, and they see nothing but the question, so make it self-contained. The result has one section per council seat.'
      const synthesis = 'where the seats agree, where they differ, and what you recommend. A run can take several minutes.'
      return drawsPanel
        ? `${about} Claude Desktop shows every seat's answer in a panel above your reply, so do not repeat the answers: write your synthesis of them, ${synthesis}`
        : `${about} Show the user each seat's answer as returned, then write your own synthesis after them: ${synthesis}`
    },
    _meta: { ui: { resourceUri: ANSWERS_PANEL.uri } },
    inputSchema: {
      type: 'object',
      properties: {
        question: { type: 'string', description: 'The question, self-contained: the council sees nothing else.' },
        providers: { type: 'array', items: { type: 'string' }, description: 'Provider names to ask, such as openai or openrouter-2. Leave out to ask every provider that has a key.' },
        verbosity: { type: 'string', enum: council.VERBOSITIES, description: 'How long the answers should be. Defaults to standard.' },
      },
      required: ['question'],
      additionalProperties: false,
    },
    run: args => theCouncil.ask(args),
  },
  {
    name: 'council_status',
    description: 'Show which council providers are usable on this machine, the model each would use, and why the others are not.',
    inputSchema: NO_ARGUMENTS,
    run: () => theCouncil.status(),
  },
  {
    name: 'council_settings',
    description: 'Show the model each council provider uses. In Claude Desktop this also opens a panel in the chat where the user picks models from each provider\'s live list. Use when the user wants to see or change the council\'s models.',
    inputSchema: NO_ARGUMENTS,
    _meta: { ui: { resourceUri: SETTINGS_PANEL.uri } },
    run: () => theCouncil.settingsText(drawsPanel),
  },
  {
    name: 'council_models_data',
    description: 'Loads the council settings panel: each provider\'s model list and saved choice. Used by the panel only.',
    inputSchema: NO_ARGUMENTS,
    _meta: { ui: { visibility: ['app'] } },
    run: () => theCouncil.panelData(),
  },
  {
    name: 'council_models_save',
    description: 'Saves the model choices made in the council settings panel. Used by the panel only.',
    inputSchema: { type: 'object', properties: { selections: { type: 'object' } }, required: ['selections'], additionalProperties: false },
    _meta: { ui: { visibility: ['app'] } },
    run: args => theCouncil.saveFromPanel(args),
  },
]

async function callTool(id, params) {
  const tool = TOOLS.find(candidate => candidate.name === params?.name)
  if (!tool) return send({ id, error: { code: -32602, message: `unknown tool: ${String(params?.name)}` } })
  const outcome = await tool.run(params.arguments ?? {})
  const result = { content: [{ type: 'text', text: outcome.text }], isError: Boolean(outcome.isError) }
  if (outcome.structured) result.structuredContent = outcome.structured
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
  if (message.id === undefined) return
  handle(message).catch(err => {
    log(`council extension: ${message.method} failed: ${err?.stack ?? err}`)
    send({ id: message.id, error: { code: -32603, message: `internal error: ${err?.message ?? err}` } })
  })
}

// Desktop ends the server by closing its input. A council run still going
// would otherwise outlive it, so it is stopped first.
readline.createInterface({ input: process.stdin }).on('line', receive).on('close', () => {
  theCouncil.stopRuns()
  process.exit(0)
})
