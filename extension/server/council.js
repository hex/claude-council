// ABOUTME: The council as the Desktop extension runs it: providers, keys, saved model choices, script runs
// ABOUTME: Keys come only from Desktop's settings form, models only from the choices saved in the panel
'use strict'
const { spawn } = require('node:child_process')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const models = require('./models.js')

// The providers the settings form and panel cover. `keyVariable` is the field
// Desktop fills, `modelVariable` what the council scripts read; the router is
// the one provider that takes a roster of models, one council seat each.
const PROVIDERS = [
  { name: 'gemini', title: 'Gemini', keyVariable: 'GEMINI_API_KEY', modelVariable: 'GEMINI_MODEL' },
  { name: 'openai', title: 'OpenAI', keyVariable: 'OPENAI_API_KEY', modelVariable: 'OPENAI_MODEL' },
  { name: 'grok', title: 'Grok', keyVariable: 'XAI_API_KEY', modelVariable: 'GROK_MODEL' },
  { name: 'perplexity', title: 'Perplexity', keyVariable: 'PERPLEXITY_API_KEY', modelVariable: 'PERPLEXITY_MODEL' },
  { name: 'kimi', title: 'Kimi', keyVariable: 'KIMI_API_KEY', modelVariable: 'KIMI_MODEL' },
  { name: 'openrouter', title: 'OpenRouter', keyVariable: 'OPENROUTER_API_KEY', modelVariable: 'OPENROUTER_MODELS', roster: true },
]
const ROSTER_MAX = 12
const VERBOSITIES = ['brief', 'standard', 'detailed']
const ASK_TIMEOUT_MS = 10 * 60 * 1000
const STATUS_TIMEOUT_MS = 3 * 60 * 1000
const SCRIPT_TIMEOUT_MS = 30 * 1000

// Names the scripts also read a key from. Only the form's fields may supply one.
const ALIAS_KEY_VARIABLES = ['GROK_API_KEY', 'MOONSHOT_API_KEY']

// Every variable that picks a model for one of the providers above, including
// the router's single-model and per-seat overrides, which beat the roster.
function isModelVariable(name) {
  return PROVIDERS.some(provider => provider.modelVariable === name) || name === 'OPENROUTER_MODEL' || /^OPENROUTER_[0-9]+_MODEL$/.test(name)
}

function isKeyVariable(name) {
  return PROVIDERS.some(provider => provider.keyVariable === name) || ALIAS_KEY_VARIABLES.includes(name)
}

// A field left empty in Desktop's form arrives as an empty string or as its
// unsubstituted placeholder, `${user_config.x}`. Neither is a key.
function readKeys(env) {
  const keys = new Map()
  for (const provider of PROVIDERS) {
    const value = (env[provider.keyVariable] ?? '').trim()
    if (value !== '' && !value.startsWith('${')) keys.set(provider.name, value)
  }
  return keys
}

// Packed, the scripts ride along under plugin/; in a checkout, extension/ sits
// beside them.
function findPluginRoot(extensionRoot) {
  const packed = path.join(extensionRoot, 'plugin')
  if (fs.existsSync(path.join(packed, 'scripts', 'run-council.sh'))) return packed
  return path.join(extensionRoot, '..')
}

function stateDirectory() {
  const configured = process.env.XDG_CONFIG_HOME ?? ''
  const base = path.isAbsolute(configured) ? configured : path.join(os.homedir(), '.config')
  return path.join(base, 'council-extension')
}

// Council transcripts hold the whole question, so they live where only the
// user can read them, however the directory was left before.
function privateDirectory(dir) {
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
  fs.chmodSync(dir, 0o700)
  return dir
}

function noChoices() {
  return Object.fromEntries(PROVIDERS.map(provider => [provider.name, provider.roster ? [] : '']))
}

function shown(value) {
  return JSON.stringify(value)?.slice(0, 80) ?? String(value)
}

function choiceProblem(provider, choice) {
  if (provider.roster) {
    if (!Array.isArray(choice)) return `${provider.title}: expected a list of model ids, got ${shown(choice)}`
    if (choice.length > ROSTER_MAX) return `${provider.title}: ${choice.length} models chosen, at most ${ROSTER_MAX} seats`
    const bad = choice.find(id => typeof id !== 'string' || !models.MODEL_ID.test(id))
    if (bad !== undefined) return `${provider.title}: ${shown(bad)} is not a model id`
    if (new Set(choice).size !== choice.length) return `${provider.title}: a model is chosen twice`
    return ''
  }
  if (choice !== '' && (typeof choice !== 'string' || !models.MODEL_ID.test(choice))) return `${provider.title}: ${shown(choice)} is not a model id`
  return ''
}

// Saved choices are parsed whole: every value ends up in the scripts'
// environment, so one bad value rejects the set rather than being repaired.
function parseChoices(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return { problem: 'expected an object of provider names' }
  const choices = noChoices()
  for (const [name, choice] of Object.entries(value)) {
    const provider = PROVIDERS.find(candidate => candidate.name === name)
    if (!provider) return { problem: `${shown(name)} is not a provider the settings cover` }
    const problem = choiceProblem(provider, choice)
    if (problem) return { problem }
    choices[name] = choice
  }
  return { choices }
}

function choicesFile() {
  return path.join(stateDirectory(), 'models.json')
}

// The saved choices, or why the file was ignored.
function readChoices() {
  let text
  try {
    text = fs.readFileSync(choicesFile(), 'utf8')
  } catch (err) {
    if (err.code === 'ENOENT') return { choices: noChoices() }
    return { choices: noChoices(), problem: `could not read it (${err.code})` }
  }
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    return { choices: noChoices(), problem: 'it is not JSON' }
  }
  const result = parseChoices(parsed)
  return result.problem ? { choices: noChoices(), problem: result.problem } : result
}

// Written to a private temporary file and renamed over the old one, so a
// reader never sees half a file and the result is never more than 0600.
function writeChoices(choices) {
  const file = choicesFile()
  privateDirectory(path.dirname(file))
  const scratch = `${file}.${process.pid}.tmp`
  fs.rmSync(scratch, { force: true })
  fs.writeFileSync(scratch, `${JSON.stringify(choices, null, 2)}\n`, { mode: 0o600, flag: 'wx' })
  fs.renameSync(scratch, file)
}

function modelEnvironment(choices) {
  const env = {}
  for (const provider of PROVIDERS) {
    const choice = choices[provider.name]
    if (provider.roster ? choice.length > 0 : choice !== '') env[provider.modelVariable] = provider.roster ? choice.join(',') : choice
  }
  return env
}

// Desktop starts the server with a minimal PATH; CLI seats live in these.
// The user's own directories come first, as in a login shell.
function searchPath(inherited) {
  const home = os.homedir()
  return [inherited, `${home}/.local/bin`, `${home}/bin`, '/opt/homebrew/bin', '/usr/local/bin'].filter(Boolean).join(':')
}

function scriptEnvironment(keys, choices) {
  const env = {}
  for (const [name, value] of Object.entries(process.env)) {
    if (!isKeyVariable(name) && !isModelVariable(name)) env[name] = value
  }
  for (const provider of PROVIDERS) {
    if (keys.has(provider.name)) env[provider.keyVariable] = keys.get(provider.name)
  }
  return { ...env, ...modelEnvironment(choices), NO_COLOR: '1', TERM: 'dumb', PATH: searchPath(process.env.PATH) }
}

const stripAnsi = text => text.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '')

// Each seat's answer or error from query-council.sh's JSON, in the order the
// council ran them, for the answers panel.
function seatsOf(answers) {
  return Object.entries(answers.round1).map(([provider, seat]) => {
    const model = stripAnsi(String(seat.model))
    if (seat.status === 'success') return { provider, model, answer: stripAnsi(String(seat.response)) }
    if (seat.status === 'error') return { provider, model, error: stripAnsi(String(seat.error)) }
    return { provider, model, error: `the seat returned status ${JSON.stringify(seat.status)} with no answer` }
  })
}

function seatIndex(name) {
  const match = /^openrouter-([1-9][0-9]*)$/.exec(name)
  return match ? Number(match[1]) : 0
}

function refused(text) {
  return { text, isError: true }
}

// The council as one object over a plugin root and the keys Desktop gave.
function openCouncil({ root, keys }) {
  const running = new Set()
  let asking = Promise.resolve()

  function runScript(script, args, options) {
    return runBash([path.join(root, 'scripts', script), ...args], options)
  }

  // Each run gets its own process group so stopping it reaches the provider
  // scripts and CLIs it started, not just the bash at the top.
  function runBash(args, options) {
    return new Promise(resolve => {
      const child = spawn('bash', args, {
        cwd: options.cwd, env: options.env, detached: true, stdio: [options.input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'],
      })
      running.add(child)
      let stdout = ''
      let stderr = ''
      let timedOut = false
      const timer = setTimeout(() => {
        timedOut = true
        stopGroup(child)
      }, options.timeoutMs)
      if (options.input !== undefined) {
        child.stdin.on('error', err => { stderr += `could not write the script's input: ${err.message}\n` })
        child.stdin.end(options.input)
      }
      child.stdout.on('data', chunk => { stdout += chunk })
      child.stderr.on('data', chunk => { stderr += chunk })
      child.on('error', err => {
        clearTimeout(timer)
        running.delete(child)
        resolve({ exitCode: 127, stdout, stderr: `could not start bash: ${err.message}`, timedOut })
      })
      child.on('close', code => {
        clearTimeout(timer)
        running.delete(child)
        resolve({ exitCode: code ?? 1, stdout, stderr, timedOut })
      })
    })
  }

  function stopGroup(child) {
    try {
      process.kill(-child.pid, 'SIGTERM')
    } catch (err) {
      if (err.code !== 'ESRCH') throw err
    }
  }

  function stopRuns() {
    for (const child of running) stopGroup(child)
  }

  function runDirectory() {
    return privateDirectory(path.join(privateDirectory(stateDirectory()), 'runs'))
  }

  // What each provider uses with nothing chosen, asked of the scripts so the
  // panel can never disagree with a run.
  async function defaultModels() {
    const names = PROVIDERS.map(provider => provider.name)
    const lookup = 'source "$1"; shift; for name in "$@"; do get_model "$name"; done'
    const library = path.join(root, 'scripts', 'lib', 'providers.sh')
    const result = await runBash(['-c', lookup, 'defaults', library, ...names], {
      cwd: runDirectory(), env: scriptEnvironment(keys, noChoices()), timeoutMs: SCRIPT_TIMEOUT_MS,
    })
    const lines = result.stdout.trim().split('\n')
    if (result.exitCode !== 0 || lines.length !== names.length) throw new Error(`could not read the default models: ${result.stderr.trim()}`)
    return Object.fromEntries(names.map((name, index) => [name, lines[index]]))
  }

  async function knownProviders() {
    const entries = await fs.promises.readdir(path.join(root, 'scripts', 'providers'))
    return entries.filter(entry => entry.endsWith('.sh')).map(entry => entry.slice(0, -3)).sort()
  }

  async function parseAsk(input) {
    if (input === null || typeof input !== 'object' || Array.isArray(input)) return { refusal: 'council_ask takes an object with a question' }
    const unknown = Object.keys(input).find(name => !['question', 'providers', 'verbosity'].includes(name))
    if (unknown !== undefined) return { refusal: `council_ask has no argument ${shown(unknown)}; it takes question, providers and verbosity` }
    const { question, providers, verbosity } = input
    if (typeof question !== 'string' || question.trim() === '') return { refusal: 'The question is empty. Ask a self-contained question: the council sees nothing else.' }
    if (providers !== undefined) {
      if (!Array.isArray(providers) || providers.length === 0) return { refusal: 'providers must list at least one provider name, or be left out to ask every configured provider' }
      const known = await knownProviders()
      const bad = providers.find(name => typeof name !== 'string' || !(known.includes(name) || seatIndex(name) > 0))
      if (bad !== undefined) return { refusal: `${shown(bad)} is not a council provider. Known providers: ${known.join(', ')}, and openrouter-1 to openrouter-${ROSTER_MAX} for saved OpenRouter seats.` }
    }
    if (verbosity !== undefined && !VERBOSITIES.includes(verbosity)) return { refusal: `verbosity must be brief, standard or detailed, not ${shown(verbosity)}` }
    return { question, providers, verbosity }
  }

  async function ask(input) {
    const request = await parseAsk(input)
    if (request.refusal) return refused(request.refusal)
    const { choices } = readChoices()
    const roster = choices.openrouter
    const pastRoster = (request.providers ?? []).find(name => seatIndex(name) > roster.length)
    if (pastRoster !== undefined) {
      const saved = roster.length === 0 ? 'no OpenRouter seats are saved' : `the saved OpenRouter roster has ${roster.length} model${roster.length === 1 ? '' : 's'}`
      return refused(`${pastRoster} is not a seat: ${saved}. Choose OpenRouter models with the council_settings tool.`)
    }
    // One run at a time, as the plugin runs them in Claude Code: the scripts
    // were not written for two runs sharing one working directory and cache.
    const run = asking.then(() => runAsk(request, choices))
    asking = run.catch(() => {})
    return run
  }

  // Asks the seats through query-council.sh, whose JSON gives each seat's
  // answer or error apart, then renders that JSON as text with the same
  // format-output.sh the plugin's transcripts come from.
  async function runAsk({ question, providers, verbosity }, choices) {
    const flags = ['--no-pane']
    if (providers) flags.push(`--providers=${providers.join(',')}`)
    if (verbosity) flags.push(`--verbosity=${verbosity}`)
    const cwd = runDirectory()
    const env = scriptEnvironment(keys, choices)
    const result = await runScript('query-council.sh', [...flags, '--', question], { cwd, env, timeoutMs: ASK_TIMEOUT_MS })
    if (result.timedOut) return refused(`The council run took longer than ${ASK_TIMEOUT_MS / 60000} minutes and was stopped.`)
    const tail = stripAnsi(result.stderr).trim().split('\n').slice(-20).join('\n')
    if (result.exitCode !== 0) return refused(`Council query failed:\n${tail || `the script exited ${result.exitCode} with no output.`}`)
    let answers
    try {
      answers = JSON.parse(result.stdout)
    } catch (err) {
      return refused(`The council run printed no result (${err.message}):\n${tail}`)
    }
    const rendered = await runScript('format-output.sh', [], { cwd, env, input: result.stdout, timeoutMs: SCRIPT_TIMEOUT_MS })
    if (rendered.exitCode !== 0) return refused(`The council's answers could not be formatted:\n${stripAnsi(rendered.stderr).trim()}`)
    return { text: stripAnsi(rendered.stdout).trim(), structured: { question, seats: seatsOf(answers) } }
  }

  async function status() {
    const result = await runScript('check-status.sh', [], { cwd: runDirectory(), env: scriptEnvironment(keys, readChoices().choices), timeoutMs: STATUS_TIMEOUT_MS })
    const report = stripAnsi(`${result.stdout}\n${result.stderr}`).trim() || `The status check exited ${result.exitCode} with no output.`
    const where = 'In Claude Desktop, API keys go in Settings, Extensions, Claude Council, Configure, not in exported variables. Models are chosen with the council_settings tool.'
    return { text: `${report}\n\n${where}`, isError: result.exitCode !== 0 }
  }

  async function settingsText(drawsPanel) {
    const defaults = await defaultModels()
    const { choices, problem } = readChoices()
    const lines = PROVIDERS.map(provider => {
      const choice = choices[provider.name]
      const key = keys.has(provider.name) ? '' : ', no key'
      if (provider.roster && choice.length > 0) return `${provider.title}: ${choice.length} seat${choice.length === 1 ? '' : 's'}${key}: ${choice.join(', ')}`
      if (!provider.roster && choice !== '') return `${provider.title}: ${choice}${key}`
      return `${provider.title}: ${defaults[provider.name]} (default${key})`
    })
    const notes = []
    if (problem) notes.push(`The saved choices in ${choicesFile()} were ignored because ${problem}; the defaults apply.`)
    notes.push(drawsPanel
      ? 'Change them in the panel shown with this result; a change applies to the next council question.'
      : 'This app does not show the settings panel, so these models cannot be changed here.')
    return { text: `Council models:\n${lines.join('\n')}\n\n${notes.join('\n')}` }
  }

  async function panelData() {
    const defaults = await defaultModels()
    const { choices, problem } = readChoices()
    const rows = await Promise.all(PROVIDERS.map(async provider => {
      const row = {
        name: provider.name,
        title: provider.title,
        roster: Boolean(provider.roster),
        hasKey: keys.has(provider.name),
        defaultModel: defaults[provider.name],
        selected: choices[provider.name],
        models: [],
        listError: '',
      }
      if (!row.hasKey) return row
      try {
        row.models = await models.listModels(provider.name, keys.get(provider.name))
      } catch (err) {
        row.listError = `Could not load the model list (${String(err?.message ?? err).slice(0, 120)})`
      }
      return row
    }))
    return { text: JSON.stringify({ providers: rows, rosterMax: ROSTER_MAX, problem: problem ? `The saved choices were ignored because ${problem}.` : '' }) }
  }

  function saveFromPanel(input) {
    const result = parseChoices(input?.selections)
    if (result.problem) return refused(`Not saved: ${result.problem}.`)
    writeChoices(result.choices)
    return { text: JSON.stringify({ saved: true }) }
  }

  return { ask, status, settingsText, panelData, saveFromPanel, stopRuns }
}

module.exports = { PROVIDERS, VERBOSITIES, findPluginRoot, openCouncil, readKeys }
