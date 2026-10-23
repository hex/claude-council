# Council pane design

How the mod looks, and why. Every colour lives in `hooks/theme.ts`, and no other file holds a colour value, apart from the vendor colours the council's config supplies.

## Principles

- The council speaks inside Claude Code, so it borrows Claude's orange and the engine's own theme instead of bringing a palette of its own.
- Colour carries meaning, and each meaning has one colour. Text or a glyph always says the same thing, so no state depends on colour alone.
- Text a person reads meets 4.5:1 on a light and on a dark theme, with two exceptions: `info` is 4.4:1 on light, and the engine has no blue that does better; and the heads-up note's seat line uses `hint` at 2.2:1 by choice, so it recedes behind the choices. Glyphs and lines meet 3:1.
- A screen fits the terminal. A pane taller than the terminal hands the keyboard back to the prompt, so text stays short. A text a person needs to read wraps and is shown whole.
- A folded section costs one line. A blank line is spent only before an open body, and a dim rule closes it when a section follows.

## Colour

Most colours are engine theme keys. The engine resolves each one for the theme the person chose (light, dark, their colour-blind variants and the ANSI ones), so contrast holds without the mod knowing the theme. Contrast figures below are for the light and dark themes of Claude Code 2.1.282, against white and against `rgb(30,30,30)`.

| Token | Theme key | Light | Dark | Used for |
|---|---|---|---|---|
| `accent` | `claude` | 3.2 | 5.3 | The progress bar and the heads-up mark. Never body text |
| `success` | `success` | 5.3 | 6.8 | A complete provider, a finished run |
| `danger` | `error` | 6.7 | 6.1 | Failed, errors |
| `warning` | `warning` | 4.7 | 10.2 | Live, querying, retrying; a seat its API sibling answered |
| `info` | `suggestion` | 4.4 | 8.9 | A cached provider |
| `muted` | `inactive` | 5.7 | 5.9 | Secondary text that must stay readable; a seat the reader cancelled |
| `hint` | `subtle` | 2.2 | 2.1 | The heads-up note's seat line: a deliberate exception to 4.5:1, chosen so it recedes behind the choices |

Plain `dimColor` serves secondary text that is fine to fade: counts, times, model names, a seat's digit when it has no action, and hints.

### Fixed colours, and why

- **Fills under white letters** (`FILL`): chips. A theme key would turn light on a dark theme and lose the white letters, so these stay fixed, each dark enough for white on both.
  - `chip` `rgb(180,85,50)`, 4.9:1: a deeper Claude orange, because white on the orange itself is 3.1:1.
  - `chipMark` `rgb(150,68,40)`, 6.7:1, the `✦` cell at the chip's start and the heads-up note's `!` or `?` badge.
- **Data colours** tell things apart without meaning anything, and a theme has too few hues for that.
  - Vendor colours come from the council's config and draw the `▌` edge at the start of each seat row. No fill uses a vendor colour, so no text sits on one.
- **Shimmer** (`SHIMMER`): the warm letters that pass over a running chip, 3.9:1 and 4.4:1 on the chip fill. They move, and the label stays readable in white between passes.

## Type

- Bold uppercase is for two labels: the `COUNCIL` chip and the `SYNTHESIS` header.
- Bold marks an identity: a provider's name in its own case (`openai`), the heads-up tag.
- Dim marks metadata: counts, labels, hints, times, model names.

## Glyphs

Each glyph has one meaning.

| Glyph | Meaning |
|---|---|
| `●` | Live, in `warning`: a seat querying or retrying, the band's clock |
| `✓` | Done: answered in `success`, cached in `info`, fell back in `warning` |
| `✗` | Failed |
| `○` | Set aside by the person: a seat cancelled, or cancelling |
| `▌` | A seat's vendor, in the vendor colour, at the start of its row |
| `▾` `▸` | A fold, open and closed: the synthesis header |
| `✦` | The council's mark, on the chip |
| ` ! ` ` ? ` | A heads-up note: `!` for this session's work, `?` for a concept to know; one ASCII letter on the `chipMark` fill, so every terminal draws it one cell wide |
| `━` `─` | The progress bar, filled and empty; a dim `─` rule across the pane closes an open body |

## Components

- **Chip**: a bold uppercase label on the `chip` fill in `onFill` letters, one space of padding each side. A running chip shimmers.
- **Seat row**: one line per seat for the whole run: the `▌` edge, the seat's digit, its glyph, its name in bold padded to the longest, the model dim (it gives way first when narrow; a cached or fallen-back seat adds `· cached` or `· fell back` in the glyph's colour), the time dim (running while live, final once settled), and at the right edge a fixed column with what the digit does now: `cancel`, `retry`, `open` or `fold`, or the digit dim alone when it does nothing. No word names the state: the glyph and its colour do. The row is the seat's fold header, and its answer or error text hangs under it when open. No seat appears twice.
- **Footer**: the pane's last line, the keys that apply now and no others: `a` fold (with two or more sections to fold and one open) or `a` expand (with every one closed), `c` cancel all while a seat can be cancelled, `✕ close` for the pane's own close mark.
- **Pane order**: a live run lists its seats, each open answer under its row, then the synthesis, then the footer. A finished run leads with its summary line (`4 of 5 answered · 1 error · 14.2s`); with `collapse_when_done` on, the synthesis follows it open and the seats come folded below, and off, the live order follows the summary.
- **Band**: the one line above the prompt while a council run is live: chip, `N of M` finished, a fill bar, the clock, the latest event, `c · cancel all` while a seat is querying, `o · open pane`. The finished notice, the retry offer and a heads-up note take the line before it.
