// ABOUTME: Hooks module that draws a council run's progress and answers in a Claude Code pane
// ABOUTME: Polls the watch dir run-council.sh writes when COUNCIL_MOD_PANE_DIR is exported
import type { EngineInterface, Register } from 'claude-code'
import { finishToast, statusLine, wakePrompt } from './notices'
import { paneOptions, type PaneOptions } from './options'
import { parseStatus } from './status'
import { fitTables } from './tables'
import { markdownBlocks, paneSections, parseColors, unseenRun, type RunView, type Section } from './view'

const PANE_ID = 'council'
const POLL_MS = 500

type PaneState = {
  root: string
  runDir?: string
  view?: RunView
  drawn: string
  isPolling: boolean
  shown: Set<string>
  lastError: string
  jobId: string
  statusShown?: string
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

async function poll($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
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
    state.jobId = (await readText($, `${state.runDir}/job-id`)).trim()
  }
  const runDir = state.runDir
  state.view = {
    providers: parseStatus(await readText($, `${runDir}/status`)),
    responses: await readFolder($, `${runDir}/responses`, '.md'),
    errors: await readFolder($, `${runDir}/errors`, '.txt'),
    colors: parseColors(await readText($, `${runDir}/colors`)),
    isDone: await $.fs.exists(`${runDir}/.done`),
  }
  const text = JSON.stringify(state.view)
  if (text !== state.drawn) {
    state.drawn = text
    $.ui.invalidate('ui.render')
  }
  // The run is over once .done lands: its dir is removed so the next run is
  // picked up, and the pane keeps the last view until the person closes it.
  const status = statusLine(state.view)
  if (status !== state.statusShown) {
    $.ui.status(status)
    state.statusShown = status
  }
  if (state.view.isDone) {
    $.ui.toast(finishToast(state.view, state.jobId))
    const wake = settings.wakesOnAsyncDone ? wakePrompt(state.jobId) : undefined
    if (wake) await $.prompt.submit({ text: wake })
    await $.process.run(['rm', '-rf', runDir])
    state.runDir = undefined
  }
}

async function pollOnce($: EngineInterface, state: PaneState, settings: PaneOptions): Promise<void> {
  if (state.isPolling) return
  state.isPolling = true
  try {
    await poll($, state, settings)
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

export const register: Register = (on, options) => {
  const settings = paneOptions(options)
  const state: PaneState = { root: '', drawn: '', isPolling: false, shown: new Set(), lastError: '', jobId: '' }

  on('session.start', async ($, e, next) => {
    // Off: nothing is exported, so runs keep the tmux pane.
    if (!settings.isEnabled) return next(e)
    const tmp = ((await $.env.get('TMPDIR')) ?? '/tmp').replace(/\/+$/, '')
    state.root = `${tmp}/council-mod.${await $.session.id()}`
    await $.fs.write(`${state.root}/.keep`, '')
    await $.env.set('COUNCIL_MOD_PANE_DIR', state.root)
    // Nothing in the pane answers the retry offer, so the run must not wait on it.
    await $.env.set('COUNCIL_RETRY_WAIT', '0')
    $.clock.every(POLL_MS, () => { void pollOnce($, state, settings) })
    return next(e)
  })

  on('ui.render', { component: 'Pane' }, ($, e, next) => {
    if (e.requestId !== PANE_ID || !state.view) return next(e)
    const { Box, Markdown, Text } = $.ui.resolve(e)
    const columns = e.props.bodyColumns
    const draw = (section: Section, index: number) => {
      const key = `section-${index}`
      switch (section.kind) {
        case 'note':
          return <Text key={key} dimColor>{section.text}</Text>
        case 'status':
          return (
            <Box key={key} flexDirection="row">
              <Text color={section.glyphColor}>{`${section.glyph} `}</Text>
              <Text bold>{`${section.name}  `}</Text>
              <Text color={section.stateColor}>{`${section.state}  `}</Text>
              <Text>{`${section.time}  `}</Text>
              <Text dimColor>{section.model}</Text>
            </Box>
          )
        case 'summary':
          return <Text key={key} bold>{section.text}</Text>
        case 'strip':
          return (
            <Box key={key} flexDirection="row" flexWrap="wrap">
              {section.items.map(item => (
                <Box key={`${key}-${item.name}`} flexDirection="row">
                  <Text color={item.color}>{`${item.glyph} `}</Text>
                  <Text>{`${item.name}  `}</Text>
                </Box>
              ))}
            </Box>
          )
        case 'banner':
          return (
            <Box key={key} flexDirection="row" marginTop={1} paddingX={1} width={columns} backgroundColor={section.background}>
              <Text bold color="white" backgroundColor={section.background}>{section.title}</Text>
              <Text italic color="white" backgroundColor={section.background}>{` ${section.subtitle}`}</Text>
            </Box>
          )
        case 'body':
          // Tables are fitted to the pane's width, which only a render knows.
          return (
            <Box key={key} flexDirection="column">
              {markdownBlocks(fitTables(section.text, columns)).map((block, part) => (
                <Markdown key={`${key}-${part}`} text={block} />
              ))}
            </Box>
          )
        case 'error':
          return (
            <Box key={key} flexDirection="column" marginTop={1}>
              <Text bold color="red">{`\u2717 ${section.title}`}</Text>
              <Text color="red" dimColor>{(markdownBlocks(section.text, 2000)[0] ?? '')}</Text>
            </Box>
          )
      }
    }
    return <Box flexDirection="column">{paneSections(state.view, settings).map(draw)}</Box>
  })
}
