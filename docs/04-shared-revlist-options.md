# 04 — Shared option groups: revision walking and pretty printing

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


`rev-list-options` is included by **`log`, `rev-list`, `shortlog`, and
`replay`**; `pretty-options` and `pretty-formats` are included by **`log`,
`show`, `rev-list`, and `diff-tree`**. Together they define git's history
traversal engine — roughly 120 options.

Most of the walker (limiting, simplification, ordering) is shared machinery
that gittle would implement once. The `--objects` family is what `pack-objects`
and the fetch/push negotiation depend on, so it is not optional if gittle
supports remotes.

---

## Commit limiting

- [x] `-<number>` / `-n <number>` / `--max-count=<number>` — *(core)* Stop after showing `<number>` commits.  `[log]`
- [ ] `--max-count-oldest=<number>` — Show only the last `<number>` commits that would have been shown.
- [x] `--skip=<number>` — Skip the first `<number>` commits before showing output.
- [x] `--since=<date>` / `--after=<date>` — Show only commits newer than a date.
- [ ] `--since-as-filter=<date>` — Filter by date without stopping the walk at the first older commit.
- [x] `--until=<date>` / `--before=<date>` — Show only commits older than a date.
- [ ] `--max-age=<timestamp>` / `--min-age=<timestamp>` — Raw-timestamp forms of the date limits.
- [x] `--author=<pattern>` / `--committer=<pattern>` — Show only commits whose author/committer header matches a regex.
- [x] `--grep=<pattern>` — Show only commits whose message matches a regex; repeatable.  `[log]`
- [ ] `--grep-reflog=<pattern>` — Show only commits whose reflog entry matches a regex.
- [ ] `--all-match` — Require every `--grep` pattern to match rather than any.
- [ ] `--invert-grep` — Show commits whose message does *not* match the `--grep` patterns.
- [x] `-i` / `--regexp-ignore-case` — Match limiting patterns case-insensitively.  `[log]`
- [ ] `--basic-regexp` — Treat limiting patterns as basic regular expressions (the default).
- [x] `-E` / `--extended-regexp` — Treat limiting patterns as extended regular expressions.  `[log]`
- [x] `-F` / `--fixed-strings` — Treat limiting patterns as literal strings.
- [ ] `-P` / `--perl-regexp` — Treat limiting patterns as PCRE.
- [x] `--merges` — Show only merge commits (equivalent to `--min-parents=2`).
- [x] `--no-merges` — Skip merge commits (equivalent to `--max-parents=1`).
- [ ] `--min-parents=<n>` / `--max-parents=<n>` / `--no-min-parents` / `--no-max-parents` — Filter commits by parent count.
- [x] `--first-parent` — *(core)* Follow only the first parent when traversing merges.
- [ ] `--exclude-first-parent-only` — Apply first-parent-only traversal to the exclusion side of a range.
- [ ] `--maximal-only` — Show only commits unreachable from any other commit in the range.
- [x] `--not` — Invert the meaning of `^` for all following revision arguments.
- [ ] `--remove-empty` — Stop traversal when a followed path disappears from the tree.
- [ ] `--merge` — Show commits touching paths conflicted in the current merge/cherry-pick/rebase.
- [ ] `--boundary` — Also emit the excluded boundary commits, prefixed with `-`.
- [ ] `--ignore-missing` — Silently ignore invalid object names among the arguments.
- [x] `--stdin` — *(core)* Read additional revision arguments (and pseudo-options) from standard input.
- [ ] `--quiet` — Produce no output, leaving only the exit status meaningful.
- [ ] `--disk-usage` / `--disk-usage=human` — Print total on-disk size of the selected objects instead of listing them.

## Pseudo-refs: what to start the walk from

- [x] `--all` — *(core)* Start from every ref under `refs/` plus HEAD.  `[log]`
- [x] `--branches[=<pattern>]` — Start from every ref under `refs/heads`, optionally filtered by glob.
- [x] `--tags[=<pattern>]` — Start from every ref under `refs/tags`, optionally filtered by glob.
- [x] `--remotes[=<pattern>]` — Start from every ref under `refs/remotes`, optionally filtered by glob.
- [ ] `--glob=<glob-pattern>` — Start from every ref matching a glob.
- [ ] `--exclude=<glob-pattern>` — Exclude refs matching a glob from the *next* `--all`/`--branches`/`--tags`/`--remotes`/`--glob`.
- [ ] `--exclude-hidden=(fetch|receive|uploadpack)` — Exclude refs that the named transport would hide.
- [ ] `--reflog` — Start from every object mentioned in any reflog.
- [ ] `--alternate-refs` — Start from the ref tips of alternate object stores.
- [ ] `--indexed-objects` — Include all trees and blobs referenced by the index.
- [ ] `--single-worktree` — Consider only the current worktree when expanding the pseudo-refs above.
- [ ] `--bisect` — Start from `refs/bisect/bad` and exclude `refs/bisect/good-*`.

## Cherry-pick equivalence (patch identity)

- [ ] `--cherry-pick` — Omit commits that introduce the same change as one on the other side of a symmetric difference.
- [ ] `--cherry-mark` — As `--cherry-pick`, but mark equivalent commits `=` and others `+` instead of omitting.
- [ ] `--left-only` / `--right-only` — Show only one side of a symmetric difference.
- [ ] `--cherry` — Shorthand for `--right-only --cherry-mark --no-merges`.
- [x] `--left-right` — Prefix each commit with `<` or `>` indicating which side it came from.  `[log]`

## History simplification

- [x] `<paths>` — *(core)* Show only commits that modify the given paths.  `[log]`
- [ ] *(default mode)* — Prune side branches that do not contribute to the final tree state.
- [ ] `--full-history` — Do not prune side branches during path simplification.
- [ ] `--dense` — Show only the selected commits plus enough to keep history meaningful.
- [ ] `--sparse` — Show every commit walked, not just the selected ones.
- [ ] `--simplify-merges` — With `--full-history`, drop merges that add nothing to the simplified history.
- [ ] `--simplify-by-decoration` — Show only commits pointed at by some branch or tag.
- [ ] `--ancestry-path[=<commit>]` — Restrict to commits on the ancestry path through `<commit>`.
- [ ] `--show-pulls` — Additionally show merges that changed the result relative to their first parent.

## Bisection support

- [ ] `--bisect` — Print the single commit roughly halfway through the remaining suspect range.
- [ ] `--bisect-vars` — Print shell-evaluable variables describing the bisection state.
- [ ] `--bisect-all` — Print all candidate commits ordered by distance from the midpoint.

## Ordering

- [x] `--date-order` — Emit children before parents, otherwise ordered by commit timestamp.
- [ ] `--author-date-order` — As `--date-order`, but using author timestamps.
- [x] `--topo-order` — *(core)* Emit in topological order, avoiding interleaved lines of history.
- [x] `--reverse` — Reverse the final output order.  `[log]`
- [ ] `-g` / `--walk-reflogs` — Walk reflog entries instead of the commit ancestry chain.
- [x] `--no-walk[=(sorted|unsorted)]` — Show only the named commits without traversing their ancestors.
- [ ] `--do-walk` — Undo a previous `--no-walk`.

## Object traversal (what `pack-objects` and fetch/push need)

- [x] `--objects` — *(core)* Also print every tree and blob reachable from the listed commits.
- [ ] `--objects-edge` — As `--objects`, but also print excluded commits prefixed with `-` for delta base hints.
- [ ] `--objects-edge-aggressive` — As `--objects-edge`, working harder to find excluded commits.
- [ ] `--in-commit-order` — Print tree and blob IDs grouped by the commit that first references them.
- [ ] `--unpacked` — Print only objects that are not already in a pack.
- [ ] `--object-names` — Print the path name alongside each object ID (the default).
- [ ] `--no-object-names` — Suppress the path names, producing a plain ID list.
- [ ] `--use-bitmap-index` — Accelerate traversal using a pack bitmap index if one exists.
- [ ] `--progress=<header>` — Print progress to stderr while traversing.
- [ ] `-z` — NUL-delimit output records rather than newline-delimiting them.

## Partial clone / promisor filtering

- [ ] `--filter=<filter-spec>` — Omit objects matching a filter (`blob:none`, `blob:limit=<n>`, `tree:<depth>`, `sparse:oid=<oid>`, `object:type=<type>`, `combine:`).
- [ ] `--no-filter` — Cancel a previous `--filter`.
- [ ] `--filter-provided-objects` — Apply the filter to explicitly named objects too.
- [ ] `--filter-print-omitted` — Print the objects the filter omitted, prefixed with `~`.
- [ ] `--missing=<missing-action>` — Choose how missing objects are handled (`error`, `allow-any`, `allow-promisor`, `print`).
- [ ] `--exclude-promisor-objects` — Internal: stop traversal at the promisor boundary.

## Commit formatting (`pretty-options`)

- [x] `--pretty[=<format>]` / `--format=<format>` — *(core)* Choose the commit output format (see the format list below).  `[log]`
- [x] `--oneline` — *(core)* Shorthand for `--pretty=oneline --abbrev-commit`.  `[log]`
- [x] `--abbrev-commit` — Print abbreviated rather than full commit object names.
- [x] `--no-abbrev-commit` — Force full 40/64-hex commit names.
- [ ] `--encoding=<encoding>` — Re-encode log messages to the named character encoding.
- [ ] `--expand-tabs=<n>` / `--expand-tabs` / `--no-expand-tabs` — Expand tabs in the log message to a tab stop of `<n>`.
- [ ] `--notes[=<ref>]` — Append notes from the given notes ref to each commit shown.
- [ ] `--no-notes` — Suppress all notes output.
- [ ] `--show-notes-by-default` — Show the default notes ref unless a specific one was requested.
- [ ] `--show-notes[=<ref>]` / `--standard-notes` / `--no-standard-notes` — Deprecated spellings of the notes options.
- [ ] `--show-signature` — Verify and display the signature of signed commits.
- [x] `--relative-date` — Synonym for `--date=relative`.
- [x] `--date=<format>` — *(core)* Choose the date rendering (`relative`, `local`, `iso8601`, `iso8601-strict`, `rfc2822`, `short`, `raw`, `human`, `unix`, `format:<strftime>`, `default`).  `[log]`
- [x] `--parents` — Also print each commit's parents, enabling parent rewriting.
- [ ] `--children` — Also print each commit's children, enabling parent rewriting.
- [ ] `--timestamp` — Print the raw commit timestamp.
- [ ] `--header` — Print the raw commit object contents, NUL-separated.
- [ ] `--no-commit-header` / `--commit-header` — Suppress or restore the `commit <oid>` header line in `rev-list --format` output.
- [x] `--count` — Print only the number of commits that would have been listed.  `[log]`
- [ ] `--graph` — Draw an ASCII commit graph to the left of the output.
- [ ] `--graph-lane-limit=<n>` — Cap the number of graph lanes drawn.
- [ ] `--no-graph-indent` / `--graph-indent` — Control indenting of visual roots in the graph.
- [ ] `--show-linear-break[=<barrier>]` — Without `--graph`, insert a marker where consecutive commits are unrelated.

## Built-in pretty formats (`pretty-formats`)

- [x] `oneline` — `<oid> <subject>` on one line.
- [ ] `short` — Commit, author, and subject.
- [x] `medium` — Commit, author, date, and full message (the `git log` default).
- [x] `full` — Adds the committer to `medium`.
- [x] `fuller` — Adds separate author and commit dates to `full`.
- [ ] `reference` — `<abbrev-oid> (<subject>, <short-date>)`, the form used when citing commits in messages.
- [ ] `email` — RFC-822-style headers plus message, as produced by `format-patch`.
- [ ] `mboxrd` — As `email`, but with `>`-escaped lines that look like `From `.
- [x] `raw` — The commit object exactly as stored.
- [x] `format:<string>` — User-defined format built from `%`-placeholders.
- [x] `tformat:<string>` — As `format:`, but terminating rather than separating records.

The placeholder vocabulary for `format:` (`%H`, `%h`, `%T`, `%P`, `%an`, `%ae`,
`%ad`, `%cn`, `%s`, `%b`, `%d`, `%D`, `%(trailers…)`, `%(describe…)`, color and
padding directives, …) is a small language of its own; see
`Documentation/pretty-formats.adoc` if gittle implements `format:` at all.
