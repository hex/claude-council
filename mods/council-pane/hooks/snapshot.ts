// ABOUTME: Reads one snapshot of a run's watch dir: statuses, answers, errors, colors, and whether it is done
// ABOUTME: Takes the engine's file access as a parameter so a scripted one can stand in

import { parseStatus } from './status'
import { parseColors, type RunView } from './view'

export type Files = {
  exists: (path: string) => Promise<boolean>
  read: (path: string) => Promise<string>
  list: (dir: string) => Promise<{ kind: string; name: string }[]>
}

export async function readText(fs: Files, path: string): Promise<string> {
  return (await fs.exists(path)) ? await fs.read(path) : ''
}

async function readFolder(fs: Files, dir: string, suffix: string): Promise<Record<string, string>> {
  const texts: Record<string, string> = {}
  if (!(await fs.exists(dir))) return texts
  for (const entry of await fs.list(dir)) {
    if (entry.kind !== 'file' || entry.name.startsWith('.') || !entry.name.endsWith(suffix)) continue
    texts[entry.name.slice(0, -suffix.length)] = await fs.read(`${dir}/${entry.name}`)
  }
  return texts
}

export async function readView(fs: Files, runDir: string): Promise<RunView> {
  // .done is the run's last write, so it is looked for first: files read
  // after it was seen are final, where a run ending mid-read would otherwise
  // be called done over a snapshot taken before its last answer.
  const isDone = await fs.exists(`${runDir}/.done`)
  return {
    providers: parseStatus(await readText(fs, `${runDir}/status`)),
    responses: await readFolder(fs, `${runDir}/responses`, '.md'),
    errors: await readFolder(fs, `${runDir}/errors`, '.txt'),
    colors: parseColors(await readText(fs, `${runDir}/colors`)),
    isDone,
  }
}
