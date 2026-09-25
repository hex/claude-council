// ABOUTME: Tests for the specialist skills logic: finding skills, reading SKILL.md, the opening they give a task
// ABOUTME: Pure functions only; the pane does the file reads
import { test, expect } from 'bun:test'
import { skillIndex, skillBody, skillsOpening, skillNames, missingSkills } from '../hooks/skills'

test('a skill name found in an earlier folder shadows the same name in a later one', () => {
  const index = skillIndex([
    { dir: '/home/u/.claude/skills', names: ['test-audit', 'rotate'] },
    { dir: '/home/u/.codex/skills', names: ['visual-plan'] },
    { dir: '/plugin/mods/council-pane/specialists', names: ['test-audit', 'bug-fixer'] },
  ])
  expect(index.get('test-audit')).toEqual({ name: 'test-audit', dir: '/home/u/.claude/skills/test-audit' })
  expect(index.get('bug-fixer')).toEqual({ name: 'bug-fixer', dir: '/plugin/mods/council-pane/specialists/bug-fixer' })
  expect([...index.keys()]).toEqual(['test-audit', 'rotate', 'visual-plan', 'bug-fixer'])
})

test('the frontmatter is dropped and the body kept as written', () => {
  expect(skillBody('---\nname: x\ndescription: "a: b"\n---\n\n# X\n\nDo it.\n')).toBe('# X\n\nDo it.')
  expect(skillBody('# No frontmatter\n\nBody.\n')).toBe('# No frontmatter\n\nBody.')
  // An opening fence that never closes is not frontmatter; the text stays whole.
  expect(skillBody('---\nname: x\n# Body')).toBe('---\nname: x\n# Body')
})

test('each skill opens the task under its name and folder, in the order listed', () => {
  expect(skillsOpening([
    { name: 'test-audit', dir: '/s/test-audit', body: '# Test Audit\n\nRecord evidence.' },
    { name: 'bug-fixer', dir: '/p/bug-fixer', body: 'Reproduce first.' },
  ])).toBe(
    'Follow these skills for this task. Each one\'s folder holds any file it mentions.\n\n' +
    '## Skill: test-audit (folder: /s/test-audit)\n\n# Test Audit\n\nRecord evidence.\n\n' +
    '## Skill: bug-fixer (folder: /p/bug-fixer)\n\nReproduce first.\n\n',
  )
  expect(skillsOpening([])).toBe('')
})

test('the form\'s skills text is a comma list; blanks and spaces fall away', () => {
  expect(skillNames(' test-audit, bug-fixer ,, ')).toEqual(['test-audit', 'bug-fixer'])
  expect(skillNames('   ')).toEqual([])
})

test('skills nobody has installed are named in the order given', () => {
  const index = skillIndex([{ dir: '/s', names: ['test-audit'] }])
  expect(missingSkills(['test-audit', 'gone', 'also-gone'], index)).toEqual(['gone', 'also-gone'])
  expect(missingSkills(['test-audit'], index)).toEqual([])
})
