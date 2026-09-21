// ABOUTME: Hooks module that draws a council run's progress and answers in a Claude Code pane
// ABOUTME: Polls the watch dir run-council.sh writes when COUNCIL_MOD_PANE_DIR is exported
import type { Elements, EngineInterface, Register } from 'claude-code'
import { finishToast, reopenReply, statusLine, wakePrompt } from './notices'
import { paneOptions, type PaneOptions } from './options'
import { parseRetryOffer, retrySection, type RetryOffer, type RetrySection } from './retry'
import { parseStatus } from './status'
import { councilArgs, TOOL_DESCRIPTION, TOOL_NAME, TOOL_SCHEMA } from './tool'
import { extractSynthesis } from './synthesis'
import { fitTables } from './tables'
import { markdownBlocks, paneSections, parseColors, unseenRun, type RunView, type Section } from './view'

const PANE_ID = 'council'
const REOPEN_COMMAND = 'council-pane'
const RUN_TIMEOUT_MS = 600_000
// Claude's orange (#D97757): the council speaks inside Claude Code, and the
// synthesis is Claude's own text. No provider's banner uses it.
const COUNCIL_RGB = 'rgb(217,119,87)'
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
  retry?: { offer: RetryOffer; seenAtMs: number }
  retryShown?: RetrySection
  synthesis?: string
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
    state.synthesis = undefined
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
  if (state.synthesis) state.view.synthesis = state.synthesis
  // The run waits on its offer for a window of seconds; the offer file going
  // away (accepted, declined or expired) withdraws the buttons.
  const offer = parseRetryOffer(await readText($, `${runDir}/retry-offer`))
  if (!offer) state.retry = undefined
  else if (!state.retry) state.retry = { offer, seenAtMs: await $.clock.now() }
  state.retryShown = state.retry ? retrySection(state.retry.offer, state.retry.seenAtMs, await $.clock.now()) : undefined
  const text = JSON.stringify([state.view, state.retryShown])
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
    state.retry = undefined
    state.retryShown = undefined
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

// The offer's two buttons and its countdown. The keys work once the person has
// given the site the keyboard (a click, ctrl+x tab); a click works at any time.
function retryRow(
  ui: Pick<Elements['terminal'], 'Box' | 'Button' | 'Text'>,
  offer: RetrySection,
  press: { accept: () => void; skip: () => void },
) {
  return (
    <ui.Box key="retry" flexDirection="row">
      <ui.Box flexDirection="row" paddingX={1} backgroundColor={COUNCIL_RGB}>
        <ui.Text bold color="white" backgroundColor={COUNCIL_RGB}>{offer.badge}</ui.Text>
      </ui.Box>
      <ui.Text bold color="red">{` \u2717 ${offer.notice}  `}</ui.Text>
      <ui.Button key="retry:accept" hotkey="r" label={offer.label} onPress={press.accept} />
      <ui.Text>{' '}</ui.Text>
      <ui.Button key="retry:skip" hotkey="s" label={offer.skipLabel} onPress={press.skip} />
      <ui.Text dimColor>{`  ${offer.remaining}s  click, or ctrl+x tab then r / s`}</ui.Text>
    </ui.Box>
  )
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
    await $.command.register({ name: REOPEN_COMMAND, description: 'Reopen the council pane with the last run', immediate: true })
    if (settings.offersTool) await $.tool.register({ name: TOOL_NAME, description: TOOL_DESCRIPTION, inputSchema: TOOL_SCHEMA })
    $.clock.every(POLL_MS, () => { void pollOnce($, state, settings) })
    return next(e)
  })

  // The synthesis is written into the reply after the run ends; nothing on disk
  // holds it, so it is lifted from the main loop's final message.
  on('turn.complete', async ($, e, next) => {
    const result = await next(e)
    const view = state.view
    const synthesis = e.agentId === undefined && view ? extractSynthesis(e.answer) : undefined
    if (view && synthesis) {
      state.synthesis = synthesis
      state.view = { ...view, synthesis }
      state.drawn = JSON.stringify([state.view, state.retryShown])
      $.ui.invalidate('ui.render')
    }
    return result
  })

  // The generated types list the tools connected when they were written, so a
  // tool registered at run time is matched by pattern.
  on('tool.call', { tool: /^mcp__council-pane__ask$/ }, async ($, e) => {
    // `e` is flat: the tool's input fields sit beside `tool` and `tool_use_id`.
    // Its declared type is the union of the listed tools, none of them this one.
    const input = e as unknown as Record<string, unknown>
    const parsed = councilArgs(input)
    if ('deny' in parsed) return { deny: parsed.deny }
    // The mod sits in the council plugin's repo; the run script is two levels up.
    const script = `${$.plugin.root}/../../scripts/run-council.sh`
    if (!(await $.fs.exists(script))) return { deny: `council script not found at ${script}` }
    const run = await $.process.run(['bash', script, ...parsed.args], { timeoutMs: RUN_TIMEOUT_MS })
    const saved = run.stdout.trim().split('\n').pop() ?? ''
    if (run.exitCode !== 0 || !saved) return { result: run.stderr || 'council run failed', isError: true }
    return { result: await $.fs.read(saved) }
  })

  on('command.run', { command: REOPEN_COMMAND }, async $ => {
    if (state.view) await $.ui.open({ id: PANE_ID, title: 'Council' })
    return { text: reopenReply(state.view !== undefined) }
  })

  on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => {
    // The band sits on the prompt, so the offer stays in view however far the
    // pane has scrolled; a survey owns the band while it runs.
    const retry = state.retryShown
    const runDir = state.runDir
    if (!retry || !runDir || e.props.hasSurvey) return next(e)
    const accept = () => { void $.process.run(['mv', '-f', `${runDir}/retry-offer`, `${runDir}/.retry`]) }
    const skip = () => { void $.fs.write(`${runDir}/.retry-declined`, '') }
    return retryRow($.ui.resolve(e), retry, { accept, skip })
  })

  on('ui.render', { component: 'Pane' }, ($, e, next) => {
    if (e.requestId !== PANE_ID || !state.view) return next(e)
    const { Box, Button, Markdown, Text } = $.ui.resolve(e)
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
                  {item.target ? (
                    <Button
                      key={`press:${item.name}`}
                      plain
                      label={item.name}
                      {...(item.hotkey ? { hotkey: item.hotkey } : {})}
                      onPress={() => { void $.ui.scroll({ in: PANE_ID, to: { key: item.target ?? '' }, block: 'start' }) }}
                    />
                  ) : (
                    <Text dimColor>{item.name}</Text>
                  )}
                  <Text>{'  '}</Text>
                </Box>
              ))}
            </Box>
          )
        case 'banner':
          return (
            <Box key={section.key} flexDirection="row" marginTop={1} paddingX={1} width={columns} backgroundColor={section.background}>
              <Text bold color="white" backgroundColor={section.background}>{section.title}</Text>
              <Text italic color="white" backgroundColor={section.background}>{` ${section.subtitle}`}</Text>
            </Box>
          )
        case 'synthesis':
          return (
            <Box key={section.key} flexDirection="column" marginTop={1}>
              <Box flexDirection="row" paddingX={1} width={columns} backgroundColor={COUNCIL_RGB}>
                <Text bold color="white" backgroundColor={COUNCIL_RGB}>SYNTHESIS</Text>
              </Box>
              {markdownBlocks(fitTables(section.text, columns)).map((block, part) => (
                <Markdown key={`${key}-${part}`} text={block} />
              ))}
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
            <Box key={section.key} flexDirection="column" marginTop={1}>
              <Text bold color="red">{`\u2717 ${section.title}`}</Text>
              <Text color="red" dimColor>{(markdownBlocks(section.text, 2000)[0] ?? '')}</Text>
            </Box>
          )
      }
    }
    const retry = state.retryShown
    const runDir = state.runDir
    return (
      <Box flexDirection="column">
        {e.surface !== 'terminal' && retry && runDir ? [retryRow($.ui.resolve(e), retry, {
          accept: () => { void $.process.run(['mv', '-f', `${runDir}/retry-offer`, `${runDir}/.retry`]) },
          skip: () => { void $.fs.write(`${runDir}/.retry-declined`, '') },
        })] : []}
        {paneSections(state.view, settings).map(draw)}
      </Box>
    )
  })
}
