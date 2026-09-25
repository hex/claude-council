// ABOUTME: Pure decisions for the skills a specialist follows: where each is found, its body, the task's opening
// ABOUTME: The pane lists the folders and reads SKILL.md; everything here runs under bun test

export type Skill = { name: string; dir: string }
export type LoadedSkill = Skill & { body: string }

// folders: each skills folder with the names in it that hold a SKILL.md, in
// order; a name in an earlier folder shadows the same one later.
export function skillIndex(folders: { dir: string; names: string[] }[]): Map<string, Skill> {
  const index = new Map<string, Skill>()
  for (const { dir, names } of folders) {
    for (const name of names) if (!index.has(name)) index.set(name, { name, dir: `${dir}/${name}` })
  }
  return index
}

// SKILL.md without its frontmatter: the name and description are for whoever
// picks the skill, not for the one following it.
export function skillBody(text: string): string {
  const match = /^---\r?\n[\s\S]*?\r?\n---\r?\n/.exec(text)
  return (match ? text.slice(match[0].length) : text).trim()
}

// The folder rides along because a skill may point at files beside it.
export function skillsOpening(skills: LoadedSkill[]): string {
  if (skills.length === 0) return ''
  const blocks = skills.map(s => `## Skill: ${s.name} (folder: ${s.dir})\n\n${s.body}\n\n`).join('')
  return `Follow these skills for this task. Each one's folder holds any file it mentions.\n\n${blocks}`
}

export function skillNames(text: string): string[] {
  return text.split(',').map(name => name.trim()).filter(name => name !== '')
}

export function missingSkills(names: string[], index: Map<string, Skill>): string[] {
  return names.filter(name => !index.has(name))
}
