// ABOUTME: The mod's design identity: every colour it draws, named by what it means
// ABOUTME: Theme keys follow the person's light, dark or colourblind theme; each fixed colour says why it is fixed

// Engine theme keys. Each resolves per theme, so text in them keeps its
// contrast on a light and a dark terminal (DESIGN.md has the measurements).
export const COLOR = {
  // Claude's orange: the progress bar and the heads-up mark. Under 4.5:1 on a
  // light theme, so never body text.
  accent: 'claude',
  success: 'success',
  danger: 'error',
  info: 'suggestion',
  // Secondary text that must stay readable; plain dimColor serves the rest.
  muted: 'inactive',
  // The heads-up note's seat line: lighter than dimColor on the user's own call, below 4.5:1 (DESIGN.md).
  hint: 'subtle',
  // Letters on a filled label.
  onFill: 'white',
} as const

// Fills carry white letters, and a theme key would turn light on a dark theme
// under them, so these are fixed and dark enough for 4.5:1 or better.
export const FILL = {
  // Claude's orange, the one fill: the SYNTHESIS header and the heads-up badge.
  // White on it is 3.1:1, a choice for the brand over 4.5:1; fixed so a dark
  // theme cannot lighten it under the white letters.
  orange: 'rgb(215,119,87)',
} as const
