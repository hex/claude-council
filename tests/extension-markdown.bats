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
#   - paragraph line breaks lost, so a table the reader does not draw runs together
#   - a code fence never closed: the rest of the answer is code, not dropped
#   - CRLF line ends left in the text

load test_helper

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
