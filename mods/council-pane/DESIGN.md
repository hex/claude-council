# Council pane design

How the mod looks, and why. Every colour lives in `hooks/theme.ts`, and no other file holds a colour value, apart from the vendor colours the council's config supplies.

## Principles

- The council speaks inside Claude Code, so it borrows Claude's orange and the engine's own theme instead of bringing a palette of its own.
- Colour carries meaning, and each meaning has one colour. Text or a glyph always says the same thing, so no state depends on colour alone.
- Text a person reads meets 4.5:1 on a light and on a dark theme, with one exception: `info` is 4.4:1 on light, and the engine has no blue that does better. Glyphs and lines meet 3:1.
- A screen fits the terminal. A pane taller than the terminal hands the keyboard back to the prompt, so help text stays on one line and cuts off at the end.

## Colour

Most colours are engine theme keys. The engine resolves each one for the theme the person chose (light, dark, their colour-blind variants and the ANSI ones), so contrast holds without the mod knowing the theme. Contrast figures below are for the light and dark themes of Claude Code 2.1.282, against white and against `rgb(30,30,30)`.

| Token | Theme key | Light | Dark | Used for |
|---|---|---|---|---|
| `accent` | `claude` | 3.2 | 5.3 | Frames, rules, the progress bar, the `$` and `✎` marks. Never body text |
| `success` | `success` | 5.3 | 6.8 | Done, ended, a complete provider |
| `danger` | `error` | 6.7 | 6.1 | Failed, errors, a refused field |
| `warning` | `warning` | 4.7 | 10.2 | Running, live, querying, unsaved changes |
| `info` | `suggestion` | 4.4 | 8.9 | A cached provider, effort medium |
| `muted` | `inactive` | 5.7 | 5.9 | Secondary text that must stay readable, such as a branch or a worktree path |
| `line` | `subtle` | 2.2 | 2.1 | Table bars and rules: decoration only |
| `model` | `planMode` | 6.8 | 4.8 | Model names |
| `peak` | `merged` | 6.0 | 6.1 | The top of a scale (effort ultra) |
| `zebra` | `userMessageBackground` | | | Every other table row |
| `selected` | `selectionBg` | | | The row you are editing, and the row under the pointer |

Plain `dimColor` serves secondary text that is fine to fade: help rows, `when:` lines, counts and labels.

### Fixed colours, and why

- **Fills under white letters** (`FILL`): chips, the table header and status labels. A theme key would turn light on a dark theme and lose the white letters, so these stay fixed, each dark enough for white on both.
  - `chip` `rgb(180,85,50)`, 4.9:1: a deeper Claude orange, because white on the orange itself is 3.1:1.
  - `chipMark` `rgb(150,68,40)`, 6.7:1, the `✦` cell at the chip's start.
  - `header` `rgb(88,88,88)`, 7.1:1.
  - `saved` `rgb(46,120,72)` 5.4:1, `error` `rgb(178,58,52)` 5.9:1, `note` `rgb(150,100,20)` 5.1:1.
- **Data colours** tell things apart without meaning anything, and a theme has too few hues for that.
  - `SWATCHES`, one per specialist in list order, drawn as a `●`: each reaches 3.4:1 or better on both backgrounds.
  - Vendor colours come from the council's config and fill each provider's banner.
- **Shimmer** (`SHIMMER`): the warm letters that pass over a running chip, 3.9:1 and 4.4:1 on the chip fill. They move, and the label stays readable in white between passes.

### Effort

Effort grows warmer as it rises, and the two highest are bold as well: low `muted`, medium `info`, high `warning`, xhigh `danger`, max `danger` bold, ultra `peak` bold. `default` is dim. An effort Codex adds later draws as plain text.

## Type

- Bold uppercase labels name a thing: chips (`SPECIALISTS 2`, `EDIT sec`, `STEPS`, `SYNTHESIS`) and table headers.
- Bold marks an identity: a specialist's or provider's name, the program in a command.
- Dim marks metadata: counts, labels, help, times.
- Italic is Codex's thinking, and nothing else.

## Glyphs

Each glyph has one meaning.

| Glyph | Meaning |
|---|---|
| `●` | An identity (a specialist's swatch, a provider), or live when coloured `warning` |
| `✓` | Done |
| `✗` | Failed |
| `⋯` | Running |
| `▶` | The row you are editing |
| `↳` | A continuation of the row above |
| `✎` | A file edit |
| `$` | A command |
| `✦` | The council's mark |
| `≡` | The synthesis |
| `│` `─` `┼` | Table bars and rules |

## Components

- **Chip**: a bold uppercase label on the `chip` fill in `onFill` letters, one space of padding each side. It names the frame below it. A running chip shimmers.
- **Frame**: a rounded border in `accent` with one column of padding, under its chip.
- **Table**: a `header` fill with white bold labels, `line` bars between columns, a `line` rule between rows, `zebra` on every other row, `selected` on the row you are editing or the one under the pointer. Each column is as wide as its widest cell; only the last one gives way on a narrow pane. A row's second line starts with `↳` under the second column.
- **Status label**: `SAVED`, `ERROR` or `NOTE` on its fill, then the message in plain text.
- **Help row**: one dim line under the value it explains, indented to the values, cut at the end.
- **Band**: the one line above the prompt while a council run or a specialist round is live: chip, name, model, time, latest step.
