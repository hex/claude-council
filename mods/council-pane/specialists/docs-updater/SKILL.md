---
name: docs-updater
description: Docs must be updated or restructured to match code that already changed: README, reference pages, CLI help or config docs.
---

# Docs Updater

Bring documentation in line with the code as it is now. Every behaviour
claim must be checked against the code. No fact may disappear unless there is
proof it is obsolete.

## Scope

1. List the pages or files in scope and the code changes they must reflect.
   If the task names only the code change, find the docs that mention the
   affected commands, flags, config keys, endpoints or errors.
2. Read the project's docs conventions: style guide, frontmatter, link
   format, generated-docs tooling. If a page is generated, edit the generator
   or its source, never the output.
3. Change no production code. If the docs reveal a code bug, report it.

## Inventory before editing

For each page, list every fact it states before you rewrite it:
- commands, subcommands, flags, environment variables, config keys, defaults,
  allowed values, units;
- limits, timeouts, precedence rules, fallbacks, ordering, rate limits;
- permissions, auth, safety and destructive-action behaviour;
- setup requirements: versions, operating systems, dependencies, credentials;
- error messages, symptoms and recovery steps;
- examples, expected output, tables and links.

Give each fact one fate:
- keep: it stays on this page;
- move: name the destination page and section;
- delete: name the code, schema or --help output that proves it obsolete.

## Find the source of truth

Check every behaviour-sensitive claim against the nearest authority:
- config: the schema, type definitions or parsing code;
- CLI: the command definitions and the real --help output;
- runtime behaviour: the implementing code and its tests;
- APIs: the handler code, the schema or contract tests.

Existing docs are secondary evidence only. Never infer a default, permission
or timeout from a name or from the old text. Run the command or read the code.
A reference table missing a public field, default or limit is a correctness
bug, not a style issue.

## Rewrite

- Open with what the reader can do and why the page exists.
- Put the recommended path before alternatives.
- Keep the common case in the main flow. Move exhaustive tables and rare
  detail to a reference page and link to it where it is needed.
- Keep one canonical place for each fact. Link rather than duplicate.
- Update examples so they run against the current code. Run them where you
  can and record which ones you ran.
- Write troubleshooting from observable symptoms.
- Leave no placeholder such as TODO, TBD or "see docs".

## Compare old and new

After editing, go through the inventory:
- every fact is kept, moved (and present at its destination), or deleted
  with its proof;
- links resolve, including anchors to moved sections;
- the main page still covers the common task end to end;
- reference pages are complete for the scope they claim.

## Evidence to record

- The inventory with each fact's fate.
- The source you checked each changed claim against.
- Commands and examples you ran, with results.
- Broken links found and fixed.

## Stop conditions

Stop and report when the code and an existing test disagree about the
behaviour, when a claim cannot be verified from code or output, or when the
change needs a docs structure decision the task did not make.

## Handoff

Report the pages changed, the facts moved or deleted with their destination
or proof, the examples run, unverified claims left in place, and suspected
code bugs.

Fact inventory and source-of-truth steps adapted from openclaw's openclaw-refactor-docs skill (MIT, OpenClaw Foundation); see ../LICENSE-openclaw.
