# Council pane design

How the mod looks, and why. Every colour lives in `hooks/theme.ts`, and no other file holds a colour value, apart from the vendor colours the council's config supplies.

## Principles

- The council speaks inside Claude Code, so it borrows Claude's orange and the engine's own theme instead of bringing a palette of its own.
- Colour carries meaning, and each meaning has one colour. Text or a glyph always says the same thing, so no state depends on colour alone.
- Text a person reads meets 4.5:1 on a light and on a dark theme, with two exceptions: `info` is 4.4:1 on light, and the engine has no blue that does better; and the heads-up note's seat line, a seat row's model and the band's event use `hint` at 2.2:1 by choice, so they recede. Glyphs and lines meet 3:1.
- A screen fits the terminal. A pane taller than the terminal hands the keyboard back to the prompt, so text stays short. A text a person needs to read wraps and is shown whole.
- A folded section costs one line. A blank line is spent only around an open body. An open seat's row is drawn as a folded one is, with no fill: its name is bold, its provider's `▌` edge says whose it is, and its button reads `fold`.

## Colour

Most colours are engine theme keys. The engine resolves each one for the theme the person chose (light, dark, their colour-blind variants and the ANSI ones), so contrast holds without the mod knowing the theme. Contrast figures below are for the light and dark themes of Claude Code 2.1.282, against white and against `rgb(30,30,30)`.

| Token | Theme key | Light | Dark | Used for |
|---|---|---|---|---|
| `accent` | `claude` | 3.2 | 5.3 | Live: the `●` glyph, the `running` head, the sweeps; a seat that fell back. Never body text |
| `success` | `success` | 5.3 | 6.8 | A complete provider, a finished run |
| `danger` | `error` | 6.7 | 6.1 | Failed, errors |
| `info` | `suggestion` | 4.4 | 8.9 | A cached provider |
| `muted` | `inactive` | 5.7 | 5.9 | Secondary text that must stay readable; a seat the reader cancelled |
| `hint` | `subtle` | 2.2 | 2.1 | The heads-up note's seat line, a seat row's model and the band's event: a deliberate exception to 4.5:1, chosen so they recede |

Plain `dimColor` serves secondary text that is fine to fade: counts, times and hints.

### Fixed colours, and why

- **Fills under white letters** (`FILL`): the SYNTHESIS header and the heads-up badge. A theme key would turn light on a dark theme and lose the white letters, so these stay fixed.
  - `orange` `rgb(215,119,87)`, Claude's orange, the one fill: the SYNTHESIS header and the heads-up note's `!` or `?`. White on it is 3.1:1, a deliberate exception to 4.5:1 (Alex, 2026-10-23: the deeper brown is not used anywhere).
- **Data colours** tell things apart without meaning anything, and a theme has too few hues for that.
  - Vendor colours come from the council's config and draw the `▌` edge at the start of each seat row. Their contrast is the vendor palette's, not checked here.

## Type

- Bold uppercase is for two labels: the `COUNCIL` label at the head of a band and the `SYNTHESIS` header.
- Bold marks an identity: a provider's name in its own case (`openai`), the heads-up tag.
- Dim marks metadata: counts, labels, hints, times, model names.

## Glyphs

Each glyph has one meaning.

| Glyph | Meaning |
|---|---|
| `●` | Live, in `accent`: the band's head |
| `✓` | Done, in `success`: the finished band's head |
| `✗` | Failed, in `danger`: the failed and retry bands' head |
| `▌` | A seat's vendor, in the vendor colour, at the start of its row |
| `▾` `▸` | A fold, open and closed: the synthesis header |
| ` ! ` ` ? ` | A heads-up note: `!` for this session's work, `?` for a concept to know; one ASCII letter on the `orange` fill, so every terminal draws it one cell wide |
| `━` `·` | A bar over a `·` track, a line's height so it never stands taller than the text: a live seat's `━━━━` dash sweeps it left to right and enters again at the left; `━` fills a share (a settled seat full, the retry countdown by its time); a failed seat's `━━` stub sits at the left; a cancelled seat's track is bare |

## Components

- **Band head**: the run's state as a glyph and a word in the state's colour (`● running`, `✓ done`, `✗ failed`, `✗ retry`), then `COUNCIL` in bold. Plain text on the terminal's own background, so it draws alike everywhere.
- **Seat row**: one line per seat for the whole run: the `▌` edge, the seat's name in bold padded to the longest, the model in `hint`, lighter than the name (a cached or fallen-back seat adds `· cached` or `· fell back` in the state's colour), a 14-cell bar in the state's colour, which gives way first when narrow, down to 5 cells on every row, before the model is cut to end in `…`, and is not drawn at all, on any row, once the pane has no room for those 5 beside the widest note; the name, the time and the button are never cut, and the note gives way last, whole and never cut, with any model left on its row, on a row too narrow for it (a sweep while live, each row's out of step with the one above so they do not move in step; full once answered; a stub on an error; a bare track once cancelled), the time dim (running while live, final once settled), and at the right edge a fixed column with a bracketed button for what the row's key does now: `[ cancel ]`, `[ retry ]`, `[ open ]` or `[ fold ]`. Keys 1 to 9, then 0, press the rows in order; nothing on the row draws its number (Alex, 2026-10-23). No glyph or word names the state: the bar's shape and colour do. The row is the seat's fold header, and its answer or error text hangs under it when open; an open seat's row is drawn on its provider's colour at seven tenths (`headerFill`) with every part in white, the button label included. No seat appears twice.
- **Footer**: the pane's last line, a blank line above it and pushed to the right edge, the keys that apply now and no others, as bracketed buttons that draw no letter: `a` fold (with two or more sections to fold and one open) or `a` expand (with every one closed), `c` cancel all while a seat can be cancelled, `✕ close` for the pane's own close mark.
- **Pane order**: a live run lists its seats, each open answer under its row, then the synthesis, then the footer. A finished run leads with its summary line (`4 of 5 answered · 1 error · 14.2s`); with `collapse_when_done` on, the synthesis follows it open and the seats come folded below, and off, the live order follows the summary.
- **Band**: the one line above the prompt while a council run is live: the `● running` head, an 8-cell sweep in `accent`, the clock dim, then `N of M done · <latest event>` in `hint`, `cancel all` while a seat is querying, `open pane`. The bands' buttons (cancel all, open pane, dismiss, retry, skip) draw no letter: their keys answer only once the band holds the focus (ctrl+x tab), so a letter on them read as broken (Alex, 2026-10-23). The finished notice, the retry offer and a heads-up note take the line before it. Every band is indented two columns, where Claude Code's own footer lines start.

## Known limits

- **A narrow seat row loses its parts by two rules.** The bar, one width on every row, shortens from 14 cells to 5 before any model is cut, and is drawn only while those 5 fit beside the widest note on any row; without it the rows share the cells it held. Each row then cuts its own model to what is left beside its note, and drops the note whole, with the model, only when the note alone does not fit. With a 12-letter name, a 4-character time and a `fell back` seat the bar needs 50 columns and the note 43, so from 34 to 42 that row shows its name, time and button and nothing of its state. Under the 34 that the name, the time and the button take, the row runs past the pane's edge.
- **Widths count UTF-16 code units, not terminal cells.** A model id in wide characters (CJK) takes two cells a character and is counted as one, so its row can run past the pane's edge.
- **A council run is read from the command's words, not by a shell parser.** The command is split into words and segments with quotes honored, and a segment counts as a run when it reads `NAME=value` words, runners with their options, bash, then the script. A heredoc body is read as commands, and so is the rest of a comment after a `;` in it, so `bash <path>/run-council.sh` there opens the pane though nothing runs the script. A run goes unseen when bash carries an option (`bash -x <script>`), when it follows a shell keyword or a wrapper the list does not hold (`then`, `!`, `{`, `sudo`, `xargs`), when a redirection comes before bash, when the script is run without bash or through a variable, in backquotes, inside `bash -c "…"`, or behind an option whose value the runner table does not list (`env -S`, `time -o`). The table holds the value-taking options of `timeout`, `env`, `nice` and `exec` only.
- **The council tool's named-only seats are listed in the mod.** `claude-cli`, `copilot-cli` and `opencode` are named in `hooks/tool.ts` because discovery never lists them. A named-only seat added to the runner is refused by the tool until it is added there. The tool also cannot tell whether a named-only seat is logged in; the run reports that.
