// ABOUTME: The council as the Desktop extension runs it: providers, keys, saved model choices, script runs
// ABOUTME: Keys come only from Desktop's settings form, models only from the choices saved in the panel
'use strict'
const { spawn } = require('node:child_process')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const models = require('./models.js')

// The providers the settings form and panel cover. `keyVariable` is the
// variable Desktop fills from the form field titled `field` (as in
// manifest.json), `modelVariable` what the council scripts read; the router
// is the one provider that takes a roster of models, one council seat each.
const PROVIDERS = [
  { name: 'gemini', title: 'Gemini', field: 'Gemini API key', keyVariable: 'GEMINI_API_KEY', modelVariable: 'GEMINI_MODEL' },
  { name: 'openai', title: 'OpenAI', field: 'OpenAI API key', keyVariable: 'OPENAI_API_KEY', modelVariable: 'OPENAI_MODEL' },
  { name: 'grok', title: 'Grok', field: 'xAI API key (Grok)', keyVariable: 'XAI_API_KEY', modelVariable: 'GROK_MODEL' },
  { name: 'perplexity', title: 'Perplexity', field: 'Perplexity API key', keyVariable: 'PERPLEXITY_API_KEY', modelVariable: 'PERPLEXITY_MODEL' },
  { name: 'kimi', title: 'Kimi', field: 'Kimi API key', keyVariable: 'KIMI_API_KEY', modelVariable: 'KIMI_MODEL' },
  { name: 'openrouter', title: 'OpenRouter', field: 'OpenRouter API key', keyVariable: 'OPENROUTER_API_KEY', modelVariable: 'OPENROUTER_MODELS', roster: true },
]
const ROSTER_MAX = 12
const VERBOSITIES = ['brief', 'standard', 'detailed']
// How long each kind of run may take before it is stopped.
const TIMEOUTS_MS = { ask: 10 * 60 * 1000, status: 3 * 60 * 1000, script: 30 * 1000 }
// What the model is told to do with the message the picker drafts once its
// answers are in. The panel cannot hand the answers to the model itself.
const AFTER_PICK = 'When the user then asks for the synthesis of a council run, as in "Synthesise the council\'s answers (run 3f9a2c)", call council_result with that run id: it gives you the answers the panel shows. Never say you cannot see them.'
// How many of the picker's runs council_result can give the model, newest
// kept. Each is the text of one run, which the run's stdout cap bounds.
const RUNS_KEPT = 5
// The question reaches query-council.sh as one argument, and Linux refuses an
// argument over 128 KiB; this leaves room under that.
const QUESTION_MAX_BYTES = 100000
// What a run may write before it is stopped: far past twelve long answers on
// stdout, and past any progress a run prints on stderr.
const STDOUT_MAX_BYTES = 8 * 1024 * 1024
const STDERR_MAX_BYTES = 1024 * 1024

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

// Every provider's key is far longer. A shorter value is a placeholder or a
// slip, and removing it from the server's output would also cut it out of
// ordinary words.
const KEY_MIN_LENGTH = 8

// The keys Desktop gave, by provider name, and the providers whose field held
// a value too short to be one. A field left empty arrives as an empty string
// or as its unsubstituted placeholder, `${user_config.x}`; neither is a key.
function readKeys(env) {
  const keys = new Map()
  const tooShort = []
  for (const provider of PROVIDERS) {
    const value = (env[provider.keyVariable] ?? '').trim()
    if (value === '' || value.startsWith('${')) continue
    if (value.length < KEY_MIN_LENGTH) tooShort.push(provider)
    else keys.set(provider.name, value)
  }
  return { keys, tooShort }
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

// A problem with the user's own files that a tool answers with, as its
// result, rather than as a fault of the server.
class Refusal extends Error {}

// Council transcripts hold the whole question, so they live where only the
// user can read them, however the directory was left before. A symbolic link
// in its place is refused: following it would tighten, and write into,
// whatever directory it points at.
function privateDirectory(dir) {
  const linked = new Refusal(`The council's state directory ${dir} is a symbolic link, which the extension does not follow. Remove the link and try again.`)
  try {
    if (fs.lstatSync(dir).isSymbolicLink()) throw linked
  } catch (err) {
    if (err.code !== 'ENOENT') throw err
  }
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 })
  // Opened without following a link, so the mode is set on this directory
  // even if a link took its place since the check above.
  let fd
  try {
    fd = fs.openSync(dir, fs.constants.O_RDONLY | fs.constants.O_DIRECTORY | fs.constants.O_NOFOLLOW)
  } catch (err) {
    if (err.code === 'ELOOP') throw linked
    throw err
  }
  try {
    fs.fchmodSync(fd, 0o700)
  } finally {
    fs.closeSync(fd)
  }
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
    const bad = choice.find(id => !models.isModelId(id))
    if (bad !== undefined) return `${provider.title}: ${shown(bad)} is not a model id`
    if (new Set(choice).size !== choice.length) return `${provider.title}: a model is chosen twice`
    return ''
  }
  if (choice !== '' && !models.isModelId(choice)) return `${provider.title}: ${shown(choice)} is not a model id`
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

// How the saved roster reads in a refusal.
function savedRoster(roster) {
  return roster.length === 0 ? 'no OpenRouter seats are saved' : `the saved OpenRouter roster has ${roster.length} model${roster.length === 1 ? '' : 's'}`
}

// The choices with one seat's model changed, as the council picker saves it:
// an API seat's provider gets the model ('' for its default), a router seat
// its position in the roster, every other choice and position kept. `seat` is
// the seat's name afterwards; it changes only when the first router model
// turns the single `openrouter` seat into the roster's openrouter-1, which is
// the only name a run gives that model.
function withSeatModel(choices, seat, model) {
  if (typeof seat !== 'string' || typeof model !== 'string') return { problem: `expected a seat name and a model id, got ${shown(seat)} and ${shown(model)}` }
  const single = PROVIDERS.find(provider => provider.name === seat && !provider.roster)
  if (single) {
    const problem = choiceProblem(single, model)
    return problem ? { problem } : { choices: { ...choices, [seat]: model }, seat }
  }
  const router = PROVIDERS.find(provider => provider.roster)
  const roster = choices.openrouter
  let next
  if (seat === 'openrouter') {
    if (roster.length > 0) return { problem: `openrouter is not a seat while ${savedRoster(roster)}` }
    if (model === '') return { choices, seat }
    next = [model]
    seat = 'openrouter-1'
  } else {
    const index = seatIndex(seat)
    if (index === 0) return { problem: `${shown(seat)} is not a seat whose model the council settings choose` }
    if (index > roster.length) return { problem: `${seat} is not a seat: ${savedRoster(roster)}` }
    if (model === '') return { problem: `${seat} needs a model; OpenRouter seats are removed in the council settings` }
    const taken = roster.indexOf(model)
    if (taken !== -1 && taken !== index - 1) return { problem: `${model} is already seat openrouter-${taken + 1}` }
    next = roster.map((id, at) => (at === index - 1 ? model : id))
  }
  const problem = choiceProblem(router, next)
  return problem ? { problem } : { choices: { ...choices, openrouter: next }, seat }
}

function choicesFile() {
  return path.join(stateDirectory(), 'models.json')
}

// The saved choices, or the defaults with a notice saying why the file was
// ignored: a run on defaults the user did not choose may cost more, so every
// tool that reads the choices passes the notice on. `problem` is why, for a
// save that must not replace the file.
function readChoices() {
  const ignored = problem => ({
    choices: noChoices(),
    problem,
    notice: `The saved model choices in ${choicesFile()} could not be read (${problem}), so every provider uses its default model.`,
  })
  let fd
  try {
    fd = fs.openSync(choicesFile(), fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW)
  } catch (err) {
    if (err.code === 'ENOENT') return { choices: noChoices(), notice: '' }
    if (err.code === 'ELOOP') return ignored('the file is a symbolic link, which is not followed')
    return ignored(`the file could not be opened: ${err.code}`)
  }
  let text
  try {
    text = fs.readFileSync(fd, 'utf8')
  } catch (err) {
    return ignored(`the file could not be read: ${err.code}`)
  } finally {
    fs.closeSync(fd)
  }
  let parsed
  try {
    parsed = JSON.parse(text)
  } catch {
    return ignored('the file is not JSON')
  }
  const result = parseChoices(parsed)
  return result.problem ? ignored(result.problem) : { choices: result.choices, notice: '' }
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

// What a run inherits from the server's own environment: what a process needs
// to start, find a login and reach the network, and the council's own settings.
// Everything else is left behind, because a seat keeps its vendor's whole
// family of variables: a key the form never held (an admin key a shell
// exported before starting Desktop) would otherwise reach that vendor's seats.
// COUNCIL_PASS_ENV is left behind too, since it names variables for a seat to keep.
const INHERITED = /^(PATH|HOME|USER|LOGNAME|SHELL|TMPDIR|LANG|LANGUAGE|TZ|LC_.*|XDG_.*|HTTP_PROXY|HTTPS_PROXY|NO_PROXY|ALL_PROXY|SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE|REQUESTS_CA_BUNDLE|NODE_EXTRA_CA_CERTS|COUNCIL_.*)$/i

function isInherited(name) {
  return INHERITED.test(name) && name.toUpperCase() !== 'COUNCIL_PASS_ENV' && !isKeyVariable(name) && !isModelVariable(name)
}

function scriptEnvironment(keys, choices) {
  const env = {}
  for (const [name, value] of Object.entries(process.env)) {
    if (isInherited(name)) env[name] = value
  }
  for (const provider of PROVIDERS) {
    if (keys.has(provider.name)) env[provider.keyVariable] = keys.get(provider.name)
  }
  return { ...env, ...modelEnvironment(choices), NO_COLOR: '1', TERM: 'dumb', PATH: searchPath(process.env.PATH) }
}

const stripAnsi = text => text.replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '')

// The most of one seat's answer or error the panel is given to draw. The
// model always gets the whole text; this bounds what the page has to lay out.
const PANEL_SEAT_CHARS = 100000

// The text as the panel gets it under `field`, with `shortenedFrom` set to
// its full length when it was cut.
function forPanel(field, text) {
  if (text.length <= PANEL_SEAT_CHARS) return { [field]: text }
  // Never between the two halves of a surrogate pair.
  const end = /[\uD800-\uDBFF]/.test(text[PANEL_SEAT_CHARS - 1]) ? PANEL_SEAT_CHARS - 1 : PANEL_SEAT_CHARS
  return { [field]: text.slice(0, end), shortenedFrom: text.length }
}

// Each seat's answer or error from query-council.sh's JSON, in the order the
// council ran them, for the answers panel.
function seatsOf(answers) {
  return Object.entries(answers.round1).map(([provider, seat]) => {
    const model = stripAnsi(String(seat.model))
    if (seat.status === 'success') return { provider, model, ...forPanel('answer', stripAnsi(String(seat.response))) }
    if (seat.status === 'error') return { provider, model, ...forPanel('error', stripAnsi(String(seat.error))) }
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

// The text with readChoices' notice, when there is one, as its first paragraph.
function withNotice(notice, text) {
  return notice ? `${notice}\n\n${text}` : text
}

// How long a stopped run's process group has to exit after SIGTERM before
// it is sent SIGKILL.
const STOP_GRACE_MS = 2000

function duration(ms) {
  return ms >= 60000 ? `${ms / 60000} minute${ms === 60000 ? '' : 's'}` : `${ms / 1000} seconds`
}

// Why runBash stopped a run, in words, for `what` it was (such as "council
// run") and the time it had. A cancelled run is never answered, nor is one
// stopped for the server's exit, but both still get words.
function stopText(what, stopped, timeoutMs) {
  switch (stopped) {
    case 'timeout': return `The ${what} took longer than ${duration(timeoutMs)} and was stopped.`
    case 'stdout': return `The ${what} wrote more than ${STDOUT_MAX_BYTES / 1024 / 1024} MiB, more than any set of answers needs, so it was stopped.`
    case 'stderr': return `The ${what} wrote more than ${STDERR_MAX_BYTES / 1024 / 1024} MiB of progress and errors, so it was stopped.`
    case 'cancelled': return `The ${what} was cancelled.`
    case 'shutdown': return `The ${what} was stopped because the extension is shutting down.`
  }
  throw new Error(`no words for a run stopped as ${JSON.stringify(stopped)}`)
}

// Sends a signal to a run's whole process group, which may have exited.
// ESRCH says no member is left. On macOS the call has also answered EPERM
// for a group whose processes had all exited, seen when SIGTERM ended every
// member before the SIGKILL. Every member runs as this user, who may signal
// it, so EPERM is taken to mean the same.
function signalGroup(child, signal) {
  try {
    process.kill(-child.pid, signal)
  } catch (err) {
    if (err.code !== 'ESRCH' && err.code !== 'EPERM') throw err
  }
}

// Collects a stream's bytes up to `limit`, calling `overflowed` once if it
// writes past that. Decoded as UTF-8 only at the end, so a character split
// across two chunks stays whole.
function capture(stream, limit, overflowed) {
  const chunks = []
  let bytes = 0
  stream.on('data', chunk => {
    if (bytes > limit) return
    bytes += chunk.length
    if (bytes > limit) overflowed()
    else chunks.push(chunk)
  })
  return { text: () => Buffer.concat(chunks).toString('utf8') }
}

// Why the question cannot be put to the council, or '' when it can.
function questionProblem(question) {
  if (typeof question !== 'string' || question.trim() === '') return 'The question is empty. Pass the question the user asked.'
  const questionBytes = Buffer.byteLength(question, 'utf8')
  if (questionBytes > QUESTION_MAX_BYTES) return `The question is ${questionBytes} bytes long; the council takes at most ${QUESTION_MAX_BYTES}. Shorten it, or say the rest in fewer words.`
  return ''
}

const NO_SEATS = 'No council seat is set up: no provider has a key and no CLI agent is installed. In Claude Desktop, API keys go in Settings, Extensions, Claude Council, Configure.'

// The council as one object over a plugin root and what readKeys made of
// the keys Desktop gave. Every tool function takes the call's AbortSignal
// last; aborting it stops the runs the call started.
function openCouncil({ root, keys, tooShort, redact, timeoutsMs = TIMEOUTS_MS }) {
  const running = new Set()

  function runScript(script, args, options) {
    return runBash([path.join(root, 'scripts', script), ...args], options)
  }

  // Runs bash with the arguments, in a process group of its own so stopping
  // it reaches the provider scripts and CLIs it started, not just the bash at
  // the top. Resolves once the run's output has closed, with `stopped`
  // naming why the run was stopped (a STOP_REASONS key), or null when it
  // ended on its own. `options.signal` aborting stops it as cancelled.
  function runBash(args, options) {
    if (options.signal?.aborted) return Promise.resolve({ exitCode: 1, stdout: '', stderr: '', stopped: 'cancelled' })
    return new Promise(resolve => {
      const child = spawn('bash', args, {
        cwd: options.cwd, env: options.env, detached: true, stdio: [options.input === undefined ? 'ignore' : 'pipe', 'pipe', 'pipe'],
      })
      let closed
      const run = { child, stopped: null, killed: null, closed: new Promise(done => { closed = done }) }
      running.add(run)
      const stdout = capture(child.stdout, STDOUT_MAX_BYTES, () => stopRun(run, 'stdout'))
      const stderr = capture(child.stderr, STDERR_MAX_BYTES, () => stopRun(run, 'stderr'))
      const timer = setTimeout(() => stopRun(run, 'timeout'), options.timeoutMs)
      const cancel = () => stopRun(run, 'cancelled')
      options.signal?.addEventListener('abort', cancel, { once: true })
      let inputError = ''
      if (options.input !== undefined) {
        child.stdin.on('error', err => { inputError = `could not write the script's input: ${err.message}\n` })
        child.stdin.end(options.input)
      }
      // A stopped run is done once its group has also been sent SIGKILL: the
      // bash at the top can close its output while a seat that ignored
      // SIGTERM is still running.
      const finish = async result => {
        clearTimeout(timer)
        options.signal?.removeEventListener('abort', cancel)
        await run.killed
        running.delete(run)
        closed()
        resolve({ ...result, stopped: run.stopped })
      }
      child.on('error', err => finish({ exitCode: 127, stdout: '', stderr: `could not start bash: ${err.message}` }))
      child.on('close', code => finish({ exitCode: code ?? 1, stdout: stdout.text(), stderr: `${inputError}${stderr.text()}` }))
    })
  }

  // Stops a run's whole process group: SIGTERM first so the scripts can clean
  // up, then SIGKILL after a grace period for anything that ignored it. The
  // SIGKILL is sent whatever the leader did, since a seat can outlive it.
  function stopRun(run, reason) {
    if (run.stopped) return
    run.stopped = reason
    signalGroup(run.child, 'SIGTERM')
    run.killed = new Promise(done => setTimeout(() => {
      signalGroup(run.child, 'SIGKILL')
      done()
    }, STOP_GRACE_MS))
  }

  // Stops every run, for the server's own exit: resolves once each has closed,
  // or the grace period is over and its group has been sent SIGKILL.
  async function stopRuns() {
    const runs = [...running]
    for (const run of runs) stopRun(run, 'shutdown')
    const graceOver = new Promise(done => setTimeout(done, STOP_GRACE_MS))
    await Promise.race([Promise.all(runs.map(run => run.closed)), graceOver])
    for (const run of runs) signalGroup(run.child, 'SIGKILL')
  }

  function runDirectory() {
    return privateDirectory(path.join(privateDirectory(stateDirectory()), 'runs'))
  }

  // The model each named seat uses under the given choices, asked of the
  // scripts so a panel can never disagree with a run.
  async function seatModels(names, choices, signal) {
    const lookup = 'source "$1"; shift; for name in "$@"; do get_model "$name"; done'
    const library = path.join(root, 'scripts', 'lib', 'providers.sh')
    const result = await runBash(['-c', lookup, 'models', library, ...names], {
      cwd: runDirectory(), env: scriptEnvironment(keys, choices), timeoutMs: timeoutsMs.script, signal,
    })
    if (result.stopped) throw new Refusal(stopText('model lookup', result.stopped, timeoutsMs.script))
    const lines = result.stdout.trim().split('\n')
    if (result.exitCode !== 0 || lines.length !== names.length) throw new Error(`could not read the models: ${result.stderr.trim()}`)
    return Object.fromEntries(names.map((name, index) => [name, lines[index]]))
  }

  // What each provider uses with nothing chosen.
  function defaultModels(signal) {
    return seatModels(PROVIDERS.map(provider => provider.name), noChoices(), signal)
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
    const problem = questionProblem(question)
    if (problem) return { refusal: problem }
    if (providers !== undefined) {
      if (!Array.isArray(providers) || providers.length === 0) return { refusal: 'providers must list at least one provider name, or be left out to ask every configured provider' }
      const known = await knownProviders()
      const bad = providers.find(name => typeof name !== 'string' || !(known.includes(name) || seatIndex(name) > 0))
      if (bad !== undefined) return { refusal: `${shown(bad)} is not a council provider. Known providers: ${known.join(', ')}, and openrouter-1 to openrouter-${ROSTER_MAX} for saved OpenRouter seats.` }
    }
    if (verbosity !== undefined && !VERBOSITIES.includes(verbosity)) return { refusal: `verbosity must be brief, standard or detailed, not ${shown(verbosity)}` }
    return { question, providers, verbosity }
  }

  async function ask(input, signal) {
    const request = await parseAsk(input)
    if (request.refusal) return refused(request.refusal)
    const { choices, notice } = readChoices()
    const roster = choices.openrouter
    const pastRoster = (request.providers ?? []).find(name => seatIndex(name) > roster.length)
    if (pastRoster !== undefined) {
      return refused(withNotice(notice, `${pastRoster} is not a seat: ${savedRoster(roster)}. Choose OpenRouter models with the council_settings tool.`))
    }
    const outcome = await runAsk(request, choices, signal)
    return { ...outcome, text: withNotice(notice, outcome.text) }
  }

  // Asks the seats through query-council.sh, whose JSON gives each seat's
  // answer or error apart, then renders that JSON as text with the same
  // format-output.sh the plugin's transcripts come from.
  async function runAsk({ question, providers, verbosity }, choices, signal) {
    const flags = ['--no-pane']
    if (providers) flags.push(`--providers=${providers.join(',')}`)
    if (verbosity) flags.push(`--verbosity=${verbosity}`)
    const cwd = runDirectory()
    const env = scriptEnvironment(keys, choices)
    const result = await runScript('query-council.sh', [...flags, '--', question], { cwd, env, timeoutMs: timeoutsMs.ask, signal })
    if (result.stopped) return refused(stopText('council run', result.stopped, timeoutsMs.ask))
    const tail = stripAnsi(result.stderr).trim().split('\n').slice(-20).join('\n')
    if (result.exitCode !== 0) return refused(`Council query failed:\n${tail || `the script exited ${result.exitCode} with no output.`}`)
    let answers
    try {
      answers = JSON.parse(result.stdout)
    } catch (err) {
      return refused(`The council run printed no result (${err.message}):\n${tail}`)
    }
    const rendered = await runScript('format-output.sh', [], { cwd, env, input: result.stdout, timeoutMs: timeoutsMs.script, signal })
    if (rendered.stopped) return refused(stopText('formatting of the answers', rendered.stopped, timeoutsMs.script))
    if (rendered.exitCode !== 0) return refused(`The council's answers could not be formatted:\n${stripAnsi(rendered.stderr).trim()}`)
    return { text: stripAnsi(rendered.stdout).trim(), structured: { question, seats: seatsOf(answers) } }
  }

  // The picker's runs in which a seat answered, each a file named by when it
  // was held and its run id: the text council_ask would have given the model,
  // held for council_result. On disk, not in memory: Claude Desktop starts the
  // extension twice, one copy for the panels' calls and one for the model's,
  // so the copy that ran the question is not the one asked for its answers.
  function heldDirectory() {
    return privateDirectory(path.join(privateDirectory(stateDirectory()), 'held'))
  }

  // The held runs, oldest first, as [file name, run id].
  function heldRuns(dir) {
    return fs.readdirSync(dir).sort().flatMap(name => {
      const run = /^[0-9]{15}-([0-9a-f]{6})\.txt$/.exec(name)?.[1]
      return run === undefined ? [] : [[name, run]]
    })
  }

  // council_ask for the picker's Ask button: a run in which a seat answered is
  // held under a run id the panel gets beside the answers. The id is random:
  // a count would start again after a restart, so an id still in the chat
  // would name a later run.
  async function pickAsk(input, signal) {
    const outcome = await ask(input, signal)
    // A cancelled run comes back as an error too, so it is never held.
    if (outcome.isError || !outcome.structured.seats.some(seat => seat.error === undefined)) return outcome
    const dir = heldDirectory()
    const held = heldRuns(dir)
    let run
    do run = crypto.randomBytes(3).toString('hex'); while (held.some(([, other]) => other === run))
    // Without the keys: a seat's error can quote the key it was sent, and no
    // key may reach a file. Written whole or not at all, as the choices are.
    const name = `${String(Date.now()).padStart(15, '0')}-${run}.txt`
    const scratch = path.join(dir, `.${name}.${process.pid}`)
    fs.writeFileSync(scratch, redact(outcome.text), { mode: 0o600, flag: 'wx' })
    fs.renameSync(scratch, path.join(dir, name))
    for (const [old] of held.slice(0, Math.max(0, held.length + 1 - RUNS_KEPT))) fs.rmSync(path.join(dir, old), { force: true })
    return { ...outcome, structured: { ...outcome.structured, run } }
  }

  // A picker run's text, by its id or the latest when none is given.
  function result(input) {
    if (input === null || typeof input !== 'object' || Array.isArray(input)) return refused('council_result takes an object, with a run id or none')
    const unknown = Object.keys(input).find(name => name !== 'run')
    if (unknown !== undefined) return refused(`council_result has no argument ${shown(unknown)}; it takes run`)
    if (input.run !== undefined && typeof input.run !== 'string') return refused(`run must be a run id such as 3f9a2c, not ${shown(input.run)}`)
    const kept = `The extension keeps the last ${RUNS_KEPT} picker runs in which a seat answered. Ask the council the question again.`
    const dir = heldDirectory()
    const held = heldRuns(dir)
    if (input.run === undefined && held.length === 0) return refused(`No council run from the picker is held. ${kept}`)
    // Matched against the names read from the directory, so the id the model
    // passes never becomes part of a path.
    const file = input.run === undefined ? held.at(-1)[0] : held.find(([, run]) => run === input.run)?.[0]
    if (file === undefined) return refused(`Council run ${shown(input.run)} is not held. ${kept}`)
    return { text: fs.readFileSync(path.join(dir, file), 'utf8') }
  }

  // The seats a question with no providers named would go to, each with the
  // model it would use, as query-council.sh resolves them under the saved
  // choices. Probes nothing: a status check starts every CLI agent.
  async function defaultSeats(signal) {
    const { choices, notice } = readChoices()
    const result = await runScript('query-council.sh', ['--list-default-models'], {
      cwd: runDirectory(), env: scriptEnvironment(keys, choices), timeoutMs: timeoutsMs.script, signal,
    })
    if (result.stopped) throw new Refusal(stopText('seat listing', result.stopped, timeoutsMs.script))
    if (result.exitCode !== 0) throw new Error(`could not list the default seats: ${stripAnsi(result.stderr).trim()}`)
    const seats = result.stdout.split('\n').filter(line => line !== '').map(line => {
      const fields = line.split('\t')
      if (fields.length !== 2) throw new Error(`query-council.sh --list-default-models printed ${shown(line)}, not "<provider>\\t<model>"`)
      return { provider: fields[0], model: fields[1] }
    })
    return { seats, notice }
  }

  function seatLines(seats) {
    return seats.map(seat => `${seat.provider}: ${seat.model}`).join('\n')
  }

  async function seatsText(input, signal) {
    const { seats, notice } = await defaultSeats(signal)
    if (seats.length === 0) {
      return refused(withNotice(notice, NO_SEATS))
    }
    return { text: withNotice(notice, `The council's seats, each with the model it uses:\n${seatLines(seats)}\n\nVerbosity: standard (the default), brief or detailed.`) }
  }

  // Trial variant B: the question and the seats for the picker panel, where
  // the user chooses and presses Ask, which runs council_pick_ask.
  async function pick(input, drawsPanel, signal) {
    if (input === null || typeof input !== 'object' || Array.isArray(input)) return refused('council_pick takes an object with a question')
    const unknown = Object.keys(input).find(name => name !== 'question')
    if (unknown !== undefined) return refused(`council_pick has no argument ${shown(unknown)}; it takes question`)
    const problem = questionProblem(input.question)
    if (problem) return refused(problem)
    const { seats, notice } = await defaultSeats(signal)
    if (seats.length === 0) return refused(withNotice(notice, NO_SEATS))
    const text = drawsPanel
      ? `The council picker is open in a panel with the question and ${seats.length} seat${seats.length === 1 ? '' : 's'}. The user picks the seats and the verbosity there and presses Ask, and the answers appear in the panel. Wait for the user: do not call council_ask for this question and do not answer it yourself. ${AFTER_PICK}`
      : `This app does not draw the council picker. Ask the user in one short message which of these seats to use and which verbosity (standard, brief or detailed), offering all seats at standard as the default, then call council_ask with their choice.\n${seatLines(seats)}`
    // How long the panel waits for its council_pick_ask: the run and its
    // formatting at their limits, and a minute for the stops and Desktop's
    // relay. A call the host never answers, such as a cancelled one, would
    // otherwise hold the panel for good.
    const answerWithinMs = timeoutsMs.ask + timeoutsMs.script + 60 * 1000
    return { text: withNotice(notice, text), structured: { question: input.question, seats, verbosities: VERBOSITIES, verbosity: 'standard', answerWithinMs } }
  }

  async function status(input, signal) {
    const { choices, notice } = readChoices()
    const result = await runScript('check-status.sh', [], { cwd: runDirectory(), env: scriptEnvironment(keys, choices), timeoutMs: timeoutsMs.status, signal })
    if (result.stopped) return refused(stopText('status check', result.stopped, timeoutsMs.status))
    const report = stripAnsi(`${result.stdout}\n${result.stderr}`).trim() || `The status check exited ${result.exitCode} with no output.`
    const short = tooShort.map(provider => `The ${provider.field} field holds under ${KEY_MIN_LENGTH} characters, too short to be a key, so ${provider.title} has no key.`)
    const where = 'In Claude Desktop, API keys go in Settings, Extensions, Claude Council, Configure, not in exported variables. Models are chosen with the council_settings tool.'
    const notes = [...short, notice, where].filter(Boolean)
    return { text: `${report}\n\n${notes.join('\n')}`, isError: result.exitCode !== 0 }
  }

  async function settingsText(drawsPanel, signal) {
    const defaults = await defaultModels(signal)
    const { choices, notice } = readChoices()
    const lines = PROVIDERS.map(provider => {
      const choice = choices[provider.name]
      // Every line says it, both ways: a model reading only the lines that
      // say "no key" has concluded that no provider has one.
      const key = keys.has(provider.name) ? 'key set' : 'no key'
      if (provider.roster && choice.length > 0) return `${provider.title}: ${choice.join(', ')} (${choice.length} seat${choice.length === 1 ? '' : 's'}, ${key})`
      if (!provider.roster && choice !== '') return `${provider.title}: ${choice} (${key})`
      return `${provider.title}: ${defaults[provider.name]} (default, ${key})`
    })
    const notes = []
    if (notice) notes.push(notice)
    notes.push(drawsPanel
      ? 'Change them in the panel shown with this result; a change applies to the next council question.'
      : 'This app does not show the settings panel, so these models cannot be changed here.')
    return { text: `Council models:\n${lines.join('\n')}\n\n${notes.join('\n')}` }
  }

  async function panelData(input, signal) {
    const defaults = await defaultModels(signal)
    const { choices, notice } = readChoices()
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
    return { text: JSON.stringify({ providers: rows, rosterMax: ROSTER_MAX, problem: notice }) }
  }

  // The settings panel saves every provider's choice at once (selections);
  // the picker saves one seat's model (seat and model), changed in the
  // choices as saved at that moment, and is told the model the seat now uses.
  async function saveFromPanel(input, signal) {
    if (input?.seat === undefined && input?.model === undefined) {
      const result = parseChoices(input?.selections)
      if (result.problem) return refused(`Not saved: ${result.problem}.`)
      writeChoices(result.choices)
      return { text: JSON.stringify({ saved: true }) }
    }
    if (input.selections !== undefined) return refused('Not saved: council_models_save takes either selections or a seat and its model, not both.')
    const change = () => {
      const saved = readChoices()
      if (saved.problem) return { problem: `the saved model choices in ${choicesFile()} could not be read (${saved.problem}). Save a fresh set in the council settings` }
      return withSeatModel(saved.choices, input.seat, input.model)
    }
    const planned = change()
    if (planned.problem) return refused(`Not saved: ${planned.problem}.`)
    // The model is looked up before anything is written, so a lookup that
    // fails leaves the file as it was. The change is then made again to the
    // file as it is after the wait, with no wait before the write, so a save
    // that landed meanwhile is kept.
    const model = (await seatModels([planned.seat], planned.choices, signal))[planned.seat]
    const result = change()
    if (result.problem) return refused(`Not saved: ${result.problem}.`)
    writeChoices(result.choices)
    return { text: JSON.stringify({ saved: true, seat: result.seat, model }) }
  }

  return { ask, pickAsk, result, seatsText, pick, status, settingsText, panelData, saveFromPanel, stopRuns }
}

module.exports = { AFTER_PICK, PROVIDERS, Refusal, VERBOSITIES, findPluginRoot, openCouncil, readKeys }
