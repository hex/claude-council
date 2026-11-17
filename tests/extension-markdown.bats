#!/usr/bin/env bats
# ABOUTME: The answers panel's markdown reader, run in node on the markdown models write
# ABOUTME: Checks the blocks and styled runs the page builds its DOM nodes from

# Failure modes covered:
#   - a heading, paragraph, list, fenced code block or rule read as the wrong block
#   - markers inside inline code or a code block treated as styling
#   - bold, italic and inline code not split into their own runs
#   - an underscore inside a word (snake_case) read as italic
#   - an ordered list straight after a bulleted one merged into it
#   - a list item's indented continuation line lost, or nesting depth wrong
#   - paragraph line breaks lost, so lines the reader draws as text run together
#   - a pipe table (header row, delimiter row, body rows) left as its raw pipe lines
#     instead of a table block whose cells are styled runs
#   - a column's alignment, from the colons in the delimiter row, lost
#   - a table straight after a paragraph line merged into the paragraph, or a line
#     with no pipe after the table taken as one of its rows
#   - lines that only look like a table drawn as one: pipes with no delimiter row, a
#     delimiter row with a different number of cells, a table inside a code block
#   - a pipe inside a code span, or written as \|, splitting its cell
#   - a backslash before a run of backticks, on a line with a pipe, stops the reader
#     with an error, and the panel then draws no seat's answer
#   - a body row with fewer or more cells than the header cut, so the reader drops
#     text the model wrote, or padded, which grows with the square of the input
#   - a code fence never closed: the rest of the answer is code, not dropped
#   - CRLF line ends left in the text
#   - blank lines between list items split one list into several
#   - an answer shaped to make the reader backtrack takes time quadratic in its length,
#     a table with a very wide header over very many short rows included

load test_helper
bats_require_minimum_version 1.5.0

blocks() {
    node -e 'const { markdownBlocks } = require(process.argv[1]); process.stdout.write(JSON.stringify(markdownBlocks(process.argv[2])))' \
        "${PROJECT_ROOT}/extension/server/markdown.js" "$1"
}

setup() {
    case "$(uname -s)" in
        MINGW* | MSYS* | CYGWIN*) skip "the Desktop extension supports macOS and Linux only" ;;
    esac
}

@test "extension markdown: headings, paragraphs with their line breaks, and rules" {
    assert_eq "$(blocks $'## Use Postgres\n\nFirst line\nsecond line\n\n---\n#### Small')" \
        '[{"type":"heading","level":2,"runs":[{"style":"text","text":"Use Postgres"}]},{"type":"paragraph","runs":[{"style":"text","text":"First line\nsecond line"}]},{"type":"rule"},{"type":"heading","level":4,"runs":[{"style":"text","text":"Small"}]}]'
}

@test "extension markdown: bold, italic and inline code become their own runs" {
    assert_eq "$(blocks 'It has `jsonb`, **real** joins and *fast* or _cheap_ __writes__.')" \
        '[{"type":"paragraph","runs":[{"style":"text","text":"It has "},{"style":"code","text":"jsonb"},{"style":"text","text":", "},{"style":"strong","text":"real"},{"style":"text","text":" joins and "},{"style":"em","text":"fast"},{"style":"text","text":" or "},{"style":"em","text":"cheap"},{"style":"text","text":" "},{"style":"strong","text":"writes"},{"style":"text","text":"."}]}]'
}

@test "extension markdown: markers inside code stay literal, and snake_case is not italic" {
    assert_eq "$(blocks $'Call `a *b* c` on max_retry_count or file_v2_ here.\n\n```python\n**not bold**\n# not a heading\n```')" \
        '[{"type":"paragraph","runs":[{"style":"text","text":"Call "},{"style":"code","text":"a *b* c"},{"style":"text","text":" on max_retry_count or file_v2_ here."}]},{"type":"code","text":"**not bold**\n# not a heading"}]'
}

@test "extension markdown: lists keep depth, continuation lines, and split by kind" {
    assert_eq "$(blocks $'- one\n  carried on\n  - nested **x**\n1. first\n2) second')" \
        '[{"type":"list","ordered":false,"items":[{"depth":0,"runs":[{"style":"text","text":"one carried on"}]},{"depth":1,"runs":[{"style":"text","text":"nested "},{"style":"strong","text":"x"}]}]},{"type":"list","ordered":true,"items":[{"depth":0,"runs":[{"style":"text","text":"first"}]},{"depth":0,"runs":[{"style":"text","text":"second"}]}]}]'
}

@test "extension markdown: an unclosed fence runs to the end, and CRLF line ends are read as LF" {
    assert_eq "$(blocks $'Intro\r\n```\r\nleft open\r\nstill code')" \
        '[{"type":"paragraph","runs":[{"style":"text","text":"Intro"}]},{"type":"code","text":"left open\nstill code"}]'
}

@test "extension markdown: items separated by blank lines stay one list, and an indented paragraph stays in its item" {
    assert_eq "$(blocks $'1. a\n\n2. b\n\n   more of b\n\n3. c\n\n- x\n\n- y\n\nAfter.')" \
        '[{"type":"list","ordered":true,"items":[{"depth":0,"runs":[{"style":"text","text":"a"}]},{"depth":0,"runs":[{"style":"text","text":"b more of b"}]},{"depth":0,"runs":[{"style":"text","text":"c"}]}]},{"type":"list","ordered":false,"items":[{"depth":0,"runs":[{"style":"text","text":"x"}]},{"depth":0,"runs":[{"style":"text","text":"y"}]}]},{"type":"paragraph","runs":[{"style":"text","text":"After."}]}]'
}

@test "extension markdown: a pipe table becomes a table block whose cells are styled runs" {
    assert_eq "$(blocks $'| Option | Cost |\n|---|---|\n| **Postgres** | low |\n| Redis | `high` |')" \
        '[{"type":"table","align":[null,null],"header":[[{"style":"text","text":"Option"}],[{"style":"text","text":"Cost"}]],"rows":[[[{"style":"strong","text":"Postgres"}],[{"style":"text","text":"low"}]],[[{"style":"text","text":"Redis"}],[{"style":"code","text":"high"}]]]}]'
}

@test "extension markdown: a table column takes its alignment from the colons in the delimiter row" {
    assert_eq "$(blocks $'| a | b | c | d |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |')" \
        '[{"type":"table","align":["left","center","right",null],"header":[[{"style":"text","text":"a"}],[{"style":"text","text":"b"}],[{"style":"text","text":"c"}],[{"style":"text","text":"d"}]],"rows":[[[{"style":"text","text":"1"}],[{"style":"text","text":"2"}],[{"style":"text","text":"3"}],[{"style":"text","text":"4"}]]]}]'
}

@test "extension markdown: a table straight after a paragraph line stands apart, and a line with no pipe ends it" {
    assert_eq "$(blocks $'Compared:\nname | cost\n--- | ---\npg | low\nThat is all.')" \
        '[{"type":"paragraph","runs":[{"style":"text","text":"Compared:"}]},{"type":"table","align":[null,null],"header":[[{"style":"text","text":"name"}],[{"style":"text","text":"cost"}]],"rows":[[[{"style":"text","text":"pg"}],[{"style":"text","text":"low"}]]]},{"type":"paragraph","runs":[{"style":"text","text":"That is all."}]}]'
}

@test "extension markdown: lines that only look like a table stay text, and a table in a code block stays code" {
    assert_eq "$(blocks $'a | b\nc | d\n\n| x | y |\n|---|\n| 1 | 2 |\n\n```\n| p | q |\n|---|---|\n```')" \
        '[{"type":"paragraph","runs":[{"style":"text","text":"a | b\nc | d"}]},{"type":"paragraph","runs":[{"style":"text","text":"| x | y |\n|---|\n| 1 | 2 |"}]},{"type":"code","text":"| p | q |\n|---|---|"}]'
}

@test "extension markdown: a pipe inside a code span, or written as \\|, stays in its cell" {
    assert_eq "$(blocks $'| op | means |\n|---|---|\n| `a || b` | either |\n| `x \\| y` | a \\| b |')" \
        '[{"type":"table","align":[null,null],"header":[[{"style":"text","text":"op"}],[{"style":"text","text":"means"}]],"rows":[[[{"style":"code","text":"a || b"}],[{"style":"text","text":"either"}]],[[{"style":"code","text":"x | y"}],[{"style":"text","text":"a | b"}]]]}]'
}

@test "extension markdown: a body row keeps the cells it has, fewer or more than the header" {
    assert_eq "$(blocks $'| a | b |\n|---|---|\n| 1 |\n| 2 | 3 | 4 |')" \
        '[{"type":"table","align":[null,null],"header":[[{"style":"text","text":"a"}],[{"style":"text","text":"b"}]],"rows":[[[{"style":"text","text":"1"}]],[[{"style":"text","text":"2"}],[{"style":"text","text":"3"}],[{"style":"text","text":"4"}]]]}]'
}

@test "extension markdown: a backslash before a run of backticks, on a line with a pipe, is read as text" {
    local prose=$'Use \\`` or | here'
    local table=$'| Marker | Meaning |\n|---|---|\n| \\``` | opens a fence |'
    assert_eq "$(blocks "$prose")" \
        '[{"type":"paragraph","runs":[{"style":"text","text":"Use \\`` or | here"}]}]'
    assert_eq "$(blocks "$table")" \
        '[{"type":"table","align":[null,null],"header":[[{"style":"text","text":"Marker"}],[{"style":"text","text":"Meaning"}]],"rows":[[[{"style":"text","text":"\\```"}],[{"style":"text","text":"opens a fence"}]]]}]'
}

# Every line of up to six characters drawn from the ones the reader acts on.
@test "extension markdown: no short line of backslashes, backticks, pipes and styling markers throws" {
    run --separate-stderr node -e '
        const { markdownBlocks } = require(process.argv[1])
        const alphabet = ["\\", "`", "|", "*", "_", " ", "a"]
        const thrown = []
        let lines = [""]
        for (let length = 0; length <= 6; length++) {
          for (const line of lines) {
            try { markdownBlocks(line) } catch (error) { thrown.push(JSON.stringify(line)) }
          }
          lines = lines.flatMap(line => alphabet.map(char => line + char))
        }
        process.stdout.write(thrown.length === 0 ? "" : `${thrown.length} lines throw, the first ${thrown[0]}`)
    ' "${PROJECT_ROOT}/extension/server/markdown.js"
    [ "$status" -eq 0 ]
    assert_eq "$output" ''
}

# A seat's answer is untrusted and unbounded, and the panel parses it on the
# page's one thread: each of these 200 KB shapes, built to make a backtracking
# reader rescan the rest of the line for every marker, must parse in under
# half a second, timed inside node.
@test "extension markdown: hostile 200 KB answers parse in linear time" {
    run --separate-stderr node -e '
        const { markdownBlocks } = require(process.argv[1])
        const size = 200000
        const fill = (unit, share = 1) => unit.repeat(Math.ceil(size * share / unit.length))
        let ticks = ""
        for (let length = 1; ticks.length < size; length++) ticks += "`".repeat(length) + "a "
        const shapes = {
          strong: fill("**a "), underscores: fill("__a "), star: fill("*a "), underscore: fill(" _a"),
          ticks, heading: "# " + fill("# ") + "x", mixed: fill("**a `b *c _d __e "),
          table: fill("|a", 1 / 3) + "\n" + fill("|-", 1 / 3) + "\n" + fill("|b\n", 1 / 3), pipes: ticks.replaceAll(" ", "|"), escapes: fill("\\|`") + "\n|-|",
        }
        const slow = []
        for (const [name, text] of Object.entries(shapes)) {
          const started = process.hrtime.bigint()
          markdownBlocks(text)
          const ms = Number(process.hrtime.bigint() - started) / 1e6
          if (ms >= 500) slow.push(`${name} ${Math.round(ms)} ms`)
        }
        process.stdout.write(slow.join(", "))
    ' "${PROJECT_ROOT}/extension/server/markdown.js"
    [ "$status" -eq 0 ]
    assert_eq "$output" ''
}
