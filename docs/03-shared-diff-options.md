# 03 — Shared option group: diff

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


The `diff-options` family is included verbatim by **`diff`, `diff-files`,
`diff-index`, `diff-tree`, `diff-pairs`, `log`, `show`, and `format-patch`**.
Selecting or rejecting an option here affects all eight commands at once, so
this is the single highest-leverage list in the whole inventory.

A much smaller subset, `diff-context-options` (`-U<n>`, `--inter-hunk-context`),
is also included by `add`, `checkout`, `commit`, `reset`, `restore`, and `stash`
for their `--patch` modes.

Roughly 110 options live here. A minimal implementation realistically needs the
~15 marked below as *core*.

---

## Output selection

- [x] `-p` / `-u` / `--patch` — *(core)* Produce a unified-diff patch; the default for `git diff`.  `[log]`
- [x] `-s` / `--no-patch` — *(core)* Suppress diff output entirely, useful to silence commands that patch by default.
- [x] `--raw` — *(core)* Emit the machine-readable raw format (modes, blob IDs, status letter, path).
- [ ] `--patch-with-raw` — Synonym for `-p --raw`.
- [ ] `--no-stat` — In `format-patch`, emit patches with no diffstat.
- [ ] `--patch-with-stat` — Synonym for `-p --stat`.
- [ ] `-t` — Include tree objects themselves in the diff output.
- [ ] `--output=<file>` — Write the diff to a file instead of stdout.
- [ ] `--line-prefix=<prefix>` — Prepend a fixed string to every output line.
- [x] `--exit-code` — *(core)* Exit 1 when differences were found, 0 when none, mimicking `diff(1)`.
- [x] `--quiet` — Produce no output at all and imply `--exit-code`.

## Merge commit handling

- [ ] `-m` — Show diffs for merge commits in the default format (needs `-p` to produce output).
- [ ] `-c` — Shorthand for `--diff-merges=combined -p`.
- [ ] `--cc` — Shorthand for `--diff-merges=dense-combined -p`.
- [ ] `--dd` — Shorthand for `--diff-merges=first-parent -p`.
- [ ] `--remerge-diff` — Shorthand for `--diff-merges=remerge -p`, diffing against a recreated merge.
- [ ] `--no-diff-merges` — Synonym for `--diff-merges=off`.
- [ ] `--diff-merges=<format>` — Choose how merge commits are diffed; values below.
  - `off` / `none` — No diff for merge commits.
  - `on` / `m` — Use the configured default merge-diff format.
  - `first-parent` / `1` — Diff against the first parent only.
  - `separate` — Emit one full diff per parent.
  - `combined` / `c` — Show a single diff against all parents simultaneously.
  - `dense-combined` / `cc` — As `combined`, dropping hunks uninteresting in all parents.
  - `remerge` / `r` — Re-merge the parents into a temporary tree and diff the result against the recorded merge.
- [ ] `--combined-all-paths` — In combined diffs, print the path as recorded in every parent.

## Diff formatting and context

- [x] `-U<n>` / `--unified=<n>` — *(core)* Emit `<n>` lines of context around each hunk (default 3).  `[log]`
- [ ] `--inter-hunk-context=<n>` — Fuse hunks separated by at most `<n>` lines.
- [ ] `-W` / `--function-context` — Extend each hunk to cover the whole enclosing function.
- [ ] `--output-indicator-new=<char>` / `--output-indicator-old=<char>` / `--output-indicator-context=<char>` — Replace the `+`, `-`, and space line markers.
- [ ] `--src-prefix=<prefix>` — Use a different prefix than `a/` for source paths.
- [ ] `--dst-prefix=<prefix>` — Use a different prefix than `b/` for destination paths.
- [x] `--no-prefix` — Drop path prefixes altogether.
- [ ] `--default-prefix` — Force the built-in `a/` and `b/` prefixes, ignoring configuration.
- [x] `--full-index` — *(core)* Print full object IDs on the `index` line rather than abbreviations.
- [ ] `--binary` — *(core)* Emit an applyable binary patch for binary files (implies `--full-index`).
- [x] `--abbrev[=<n>]` — Abbreviate object IDs in raw and header output to `<n>` hex digits.
- [x] `-a` / `--text` — Treat every file as text rather than detecting binary content.
- [ ] `--ita-invisible-in-index` — Show `git add -N` entries as new files rather than as empty existing files.

## Diff algorithms

- [ ] `--diff-algorithm=(patience|minimal|histogram|myers)` — *(core)* Select the diff algorithm explicitly.
- [ ] `--minimal` — Spend extra effort to produce the smallest possible diff.
- [ ] `--patience` — Use the patience diff algorithm.
- [ ] `--histogram` — Use the histogram diff algorithm.
- [ ] `--anchored=<text>` — Use the anchored algorithm, keeping lines containing `<text>` from moving.
- [ ] `--indent-heuristic` — Shift hunk boundaries to more readable positions (the default).
- [ ] `--no-indent-heuristic` — Disable the hunk-shifting heuristic.

## Summaries and statistics

- [x] `--stat[=<width>[,<name-width>[,<count>]]]` — *(core)* Print a diffstat histogram of changed files.  `[log]`
- [x] `--numstat` — *(core)* Print added/deleted line counts per file in machine-readable form.
- [x] `--shortstat` — Print only the summary line of `--stat`.
- [ ] `--compact-summary` — Add creation/deletion/mode information to the `--stat` output.
- [ ] `--summary` — Print extended header information (creations, renames, mode changes) only.
- [ ] `-X [<param>,…]` / `--dirstat[=<param>,…]` — Show the distribution of change across directories.
- [ ] `--cumulative` — Synonym for `--dirstat=cumulative`.
- [ ] `--dirstat-by-file[=<param>,…]` — Synonym for `--dirstat=files,<param>`.
- [x] `--name-only` — *(core)* Print only the names of changed files.  `[log]`
- [x] `--name-status` — *(core)* Print a status letter and name for each changed file.
- [x] `-z` — *(core)* NUL-terminate output records and disable path quoting.

## Rename and copy detection

- [ ] `-M[<n>]` / `--find-renames[=<n>]` — Detect renames, optionally with a similarity threshold.
- [ ] `-C[<n>]` / `--find-copies[=<n>]` — Detect copies as well as renames.
- [ ] `--find-copies-harder` — Consider unmodified files as copy sources, at significant cost.
- [ ] `--no-renames` — Disable rename detection even if configuration enables it.
- [ ] `--rename-empty` / `--no-rename-empty` — Allow or forbid empty blobs as rename sources.
- [ ] `-B[<n>][/<m>]` / `--break-rewrites[=[<n>][/<m>]]` — Split heavily rewritten files into a delete plus a create.
- [ ] `-l<num>` — Cap the size of the rename/copy detection matrix.
- [ ] `-D` / `--irreversible-delete` — Omit the preimage of deleted files, producing a smaller but unapplyable patch.

## Filtering which changes are shown

- [x] `--diff-filter=[(A|C|D|M|R|T|U|X|B)…[*]]` — *(core)* Include only files with the given change types (added, copied, deleted, modified, renamed, type-changed, unmerged, unknown, broken).  `[log]`
- [x] `-S<string>` — Show only commits where the number of occurrences of `<string>` changed (the "pickaxe").  `[log]`
- [ ] `-G<regex>` — Show only commits whose patch text adds or removes a line matching `<regex>`.
- [ ] `--find-object=<object-id>` — Show only changes that add or remove occurrences of a specific object.
- [ ] `--pickaxe-all` — When the pickaxe matches, show the whole changeset rather than just matching files.
- [ ] `--pickaxe-regex` — Interpret the `-S` argument as an extended regular expression.
- [ ] `-O<orderfile>` — Order output files according to glob patterns read from a file.
- [ ] `--skip-to=<file>` — Drop all output before the named file.
- [ ] `--rotate-to=<file>` — Move all output before the named file to the end.
- [ ] `--relative[=<path>]` / `--no-relative` — Restrict output to a subdirectory and print paths relative to it.
- [x] `-R` — Swap the two inputs, reversing the direction of the diff.
- [ ] `--max-depth=<depth>` — Limit pathspec descent to `<depth>` directory levels.

## Whitespace handling

- [x] `--ignore-cr-at-eol` — Ignore a carriage return at end of line.  `[log]`
- [x] `--ignore-space-at-eol` — Ignore whitespace changes at end of line.
- [x] `-b` / `--ignore-space-change` — Ignore changes in the amount of whitespace.
- [x] `-w` / `--ignore-all-space` — Ignore whitespace entirely when comparing lines.  `[log]`
- [ ] `--ignore-blank-lines` — Ignore hunks whose lines are all blank.
- [ ] `-I<regex>` / `--ignore-matching-lines=<regex>` — Ignore changes whose lines all match a regex; repeatable.
- [ ] `--check` — Report whitespace errors and conflict markers introduced by the diff, exiting non-zero.
- [ ] `--ws-error-highlight=<kind>` — Highlight whitespace errors in `old`, `new`, and/or `context` lines.

## Color and word-level diff

- [x] `--color[=<when>]` — Colorize the diff (`always`, `never`, `auto`).
- [x] `--no-color` — Equivalent to `--color=never`.
- [ ] `--color-moved[=<mode>]` — Color moved lines differently; modes `no`, `default`, `plain`, `blocks`, `zebra`, `dimmed-zebra`.
- [ ] `--no-color-moved` — Disable move detection.
- [ ] `--color-moved-ws=<mode>,…` — Control whitespace handling during move detection (`no`, `ignore-space-at-eol`, `ignore-space-change`, `ignore-all-space`, `allow-indentation-change`).
- [ ] `--no-color-moved-ws` — Do not ignore whitespace during move detection.
- [ ] `--word-diff[=<mode>]` — Diff by words instead of lines; modes `color`, `plain`, `porcelain`, `none`.
- [ ] `--word-diff-regex=<regex>` — Define what counts as a word.
- [ ] `--color-words[=<regex>]` — Shorthand for `--word-diff=color` with an optional word regex.

## External helpers and submodules

- [ ] `--ext-diff` — Permit external diff drivers configured via gitattributes to run.
- [ ] `--no-ext-diff` — Forbid external diff drivers.
- [ ] `--textconv` / `--no-textconv` — Allow or forbid textconv filters when diffing binary files.
- [ ] `--submodule[=<format>]` — Choose how submodule changes are displayed (`short`, `log`, `diff`).
- [ ] `--ignore-submodules[=(none|untracked|dirty|all)]` — Ignore some or all submodule changes.

---

## Related shared fragment: `diff-format`

`diff-format.adoc` documents the raw output format rather than options, and is
included by `diff-files`, `diff-index`, `diff-tree`, and `git-diff`. It defines
the `:<srcmode> <dstmode> <srcsha> <dstsha> <status>\t<path>` record that all
plumbing diff commands emit — required reading if gittle ships any `diff-*`
plumbing command.
