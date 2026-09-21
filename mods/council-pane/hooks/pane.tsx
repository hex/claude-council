// ABOUTME: Hooks module that draws a council run's progress and answers in a Claude Code pane
// ABOUTME: Polls the watch dir run-council.sh writes when COUNCIL_MOD_PANE_DIR is exported
import type { EngineInterface, Register } from 'claude-code'
import { parseStatus } from './status'
import { fitTables } from './tables'
import { markdownBlocks, paneMarkdown, unseenRun, type RunView } from './view'

const PANE_ID = 'council'
const POLL_MS = 500

type PaneState = {
  root: string
  runDir?: string
  view?: RunView
  drawn: string
  blocks: string[]
  blocksFor: string
  isPolling: boolean
  shown: Set<string>
  lastError: string
}

async function readText($: EngineInterface, path: string): Promise<string> {
  return (await $.fs.exists(path)) ? await $.fs.read(path) : ''
}

async function readFolder($: EngineInterface, dir: string, suffix: string): Promise<Record<string, string>> {
  const texts: Record<string, string> = {}
  if (!(await $.fs.exists(dir))) return texts
  for (const entry of await $.fs.list(dir)) {
    if (entry.kind !== 'file' || entry.name.startsWith('.') || !entry.name.endsWith(suffix)) continue
    texts[entry.name.slice(0, -suffix.length)] = await $.fs.read(`${dir}/${entry.name}`)
  }
  return texts
}

async function poll($: EngineInterface, state: PaneState): Promise<void> {
  // Temp cleaners remove the root under a long session; runs find it again
  // only if it exists, so it is put back rather than reported.
  if (!(await $.fs.exists(state.root))) {
    await $.fs.write(`${state.root}/.keep`, '')
    state.runDir = undefined
    return
  }
  if (!state.runDir) {
    const name = unseenRun(await $.fs.list(state.root), state.shown)
    if (!name) return
    state.shown.add(name)
    state.runDir = `${state.root}/${name}`
    await $.ui.open({ id: PANE_ID, title: 'Council' })
  }
  const runDir = state.runDir
  state.view = {
    providers: parseStatus(await readText($, `${runDir}/status`)),
    responses: await readFolder($, `${runDir}/responses`, '.md'),
    errors: await readFolder($, `${runDir}/errors`, '.txt'),
    isDone: await $.fs.exists(`${runDir}/.done`),
  }
  const text = paneMarkdown(state.view)
  if (text !== state.drawn) {
    state.drawn = text
    $.ui.invalidate('ui.render')
  }
  // The run is over once .done lands: its dir is removed so the next run is
  // picked up, and the pane keeps the last view until the person closes it.
  if (state.view.isDone) {
    await $.process.run(['rm', '-rf', runDir])
    state.runDir = undefined
  }
}

async function pollOnce($: EngineInterface, state: PaneState): Promise<void> {
  if (state.isPolling) return
  state.isPolling = true
  try {
    await poll($, state)
    state.lastError = ''
  } catch (error) {
    // The poll repeats twice a second: a failure that persists is logged once.
    const message = String(error)
    if (message !== state.lastError) $.ui.log(message)
    state.lastError = message
  } finally {
    state.isPolling = false
  }
}

export const register: Register = on => {
  const state: PaneState = { root: '', drawn: '', blocks: [], blocksFor: '', isPolling: false, shown: new Set(), lastError: '' }

  on('session.start', async ($, e, next) => {
    const tmp = ((await $.env.get('TMPDIR')) ?? '/tmp').replace(/\/+$/, '')
    state.root = `${tmp}/council-mod.${await $.session.id()}`
    await $.fs.write(`${state.root}/.keep`, '')
    await $.env.set('COUNCIL_MOD_PANE_DIR', state.root)
    // Nothing in the pane answers the retry offer, so the run must not wait on it.
    await $.env.set('COUNCIL_RETRY_WAIT', '0')
    $.clock.every(POLL_MS, () => { void pollOnce($, state) })
    return next(e)
  })

  on('ui.render', { component: 'Pane' }, ($, e, next) => {
    if (e.requestId !== PANE_ID || !state.view) return next(e)
    // Tables are fitted to the pane's width, which only a render knows; the
    // blocks are rebuilt when the text or that width changes.
    const fittedFor = `${e.props.bodyColumns}:${state.drawn}`
    if (fittedFor !== state.blocksFor) {
      state.blocks = markdownBlocks(fitTables(state.drawn, e.props.bodyColumns))
      state.blocksFor = fittedFor
    }
    const { Box, Markdown } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {state.blocks.map((block, index) => <Markdown key={`block-${index}`} text={block} />)}
      </Box>
    )
  })
}
