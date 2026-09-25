// ABOUTME: The mod's design identity: every colour it draws, named by what it means
// ABOUTME: Theme keys follow the person's light, dark or colourblind theme; each fixed colour says why it is fixed

// Engine theme keys. Each resolves per theme, so text in them keeps its
// contrast on a light and a dark terminal (DESIGN.md has the measurements).
export const COLOR = {
  // Claude's orange: frames, rules and marks. Under 4.5:1 on a light theme, so
  // never body text.
  accent: 'claude',
  success: 'success',
  danger: 'error',
  // Running, live, a note.
  warning: 'warning',
  info: 'suggestion',
  // Secondary text that must stay readable; plain dimColor serves the rest.
  muted: 'inactive',
  // Table bars and rules: decoration only, 2:1.
  line: 'subtle',
  // The top of a scale, such as the highest effort.
  peak: 'merged',
  model: 'planMode',
  zebra: 'userMessageBackground',
  selected: 'selectionBg',
  // Letters on a filled label.
  onFill: 'white',
} as const

// Fills carry white letters, and a theme key would turn light on a dark theme
// under them, so these are fixed and dark enough for 4.5:1 or better.
export const FILL = {
  // A deeper Claude orange (4.9:1 under white); the plain accent is 3.1:1.
  chip: 'rgb(180,85,50)',
  // The chip's mark cell, a step darker again.
  chipMark: 'rgb(150,68,40)',
  header: 'rgb(88,88,88)',
  saved: 'rgb(46,120,72)',
  error: 'rgb(178,58,52)',
  note: 'rgb(150,100,20)',
} as const

// The chip's shimmer: warm light letters that pass over the chip fill.
export const SHIMMER = { peak: 'rgb(255,226,150)', near: 'rgb(255,242,208)' } as const

export type Style = { color: string; bold?: true }

// Warmer as the effort rises; max and ultra are bold as well. An effort Codex
// adds later has no style and draws as plain text.
export const EFFORT_STYLE: Record<string, Style> = {
  low: { color: COLOR.muted },
  medium: { color: COLOR.info },
  high: { color: COLOR.warning },
  xhigh: { color: COLOR.danger },
  max: { color: COLOR.danger, bold: true },
  ultra: { color: COLOR.peak, bold: true },
}

// Data colours tell things apart rather than say what they mean, and a theme
// has too few hues for that. Each is drawn as a glyph, which needs 3:1, and
// each reaches 3.4:1 or better on white and on rgb(30,30,30).
export const SWATCHES = ['rgb(70,130,180)', 'rgb(150,90,170)', 'rgb(60,140,90)', 'rgb(200,80,110)', 'rgb(160,120,20)', 'rgb(40,140,140)'] as const
