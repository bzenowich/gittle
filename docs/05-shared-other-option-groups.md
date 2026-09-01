# 05 — Shared option groups: fetch, merge, blame, refs, sequencer

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


The remaining shared `include::` fragments. Each is listed once here and
referenced from the per-command files.

---

## `fetch-options` — included by `fetch` and `pull`

The wire-protocol surface gittle must support is largely decided by which of
these are kept.

### What to fetch

- [ ] `--all` / `--no-all` — Fetch from every configured remote.
- [ ] `--multiple` — Accept several repository or group arguments (and no refspecs).
- [x] `-t` / `--tags` — Also fetch all tags from the remote.
- [x] `--no-tags` — Do not auto-follow tags pointing at fetched objects.
- [ ] `--refmap=<refspec>` — Override the configured refspec used to map fetched refs into local ones.
- [ ] `--prefetch` — Rewrite the refspec to store everything under `refs/prefetch/`.
- [ ] `--refetch` — Skip negotiation and refetch everything, as for a fresh clone.
- [ ] `--filter=<filter-spec>` — *(partial clone)* Ask the server to omit objects matching a filter.

### Shallow and partial history

- [ ] `--depth=<depth>` — Limit history to `<depth>` commits from each remote branch tip.
- [ ] `--deepen=<depth>` — Extend an existing shallow history by `<depth>` more commits.
- [ ] `--shallow-since=<date>` — Reshape the shallow boundary to include everything after a date.
- [ ] `--shallow-exclude=<ref>` — Reshape the shallow boundary to exclude commits reachable from a ref.
- [ ] `--unshallow` — Convert a shallow repository into a complete one.
- [ ] `--update-shallow` — Accept refs that require updating `.git/shallow`.

### Negotiation

- [ ] `--negotiation-tip=(<commit>|<glob>)` / `--negotiation-restrict=…` — Restrict which local commits are advertised as `have` lines.
- [ ] `--negotiation-include=(<commit>|<glob>)` — Force particular tips to be advertised during negotiation.
- [ ] `--negotiate-only` — Run only the negotiation phase and print the resulting common commits.
- [ ] `-o <option>` / `--server-option=<option>` — Send an arbitrary server option (protocol v2 only).
- [x] `--upload-pack <upload-pack>` — Override the `git-upload-pack` path executed on the remote.

### Ref updating

- [x] `-f` / `--force` — Allow non-fast-forward updates of the local refs being fetched into.
- [ ] `-a` / `--append` — Append to `FETCH_HEAD` rather than overwriting it.
- [ ] `--atomic` — Update all local refs in one transaction, or none.
- [x] `-p` / `--prune` — Delete remote-tracking refs that no longer exist on the remote.
- [ ] `-P` / `--prune-tags` — Also delete local tags absent from the remote when pruning.
- [ ] `-u` / `--update-head-ok` — Permit updating the ref that HEAD points at.
- [ ] `--set-upstream` — Configure upstream tracking for the fetched branches.
- [ ] `--write-fetch-head` / `--no-write-fetch-head` — Control whether `FETCH_HEAD` is written at all.
- [ ] `--show-forced-updates` / `--no-show-forced-updates` — Control detection and reporting of forced updates.
- [ ] `-n` — In `fetch`, disable tag auto-following (see `--no-tags`).

### Housekeeping and submodules

- [ ] `-k` / `--keep` — Keep the downloaded packfile instead of exploding small ones.
- [ ] `--auto-maintenance` / `--no-auto-maintenance` (aliases `--auto-gc` / `--no-auto-gc`) — Run automatic maintenance afterwards.
- [ ] `--write-commit-graph` / `--no-write-commit-graph` — Update the commit-graph after fetching.
- [ ] `--recurse-submodules[=(yes|on-demand|no)]` — Fetch new commits in submodules too.
- [ ] `--no-recurse-submodules` — Disable submodule recursion.
- [ ] `--recurse-submodules-default=(yes|on-demand)` — Internal: supply a default for submodule recursion.
- [ ] `--submodule-prefix=<path>` — Internal: prefix used in progress messages for nested submodules.
- [ ] `-j <n>` / `--jobs=<n>` — Run up to `<n>` fetches in parallel.

### Reporting and transport

- [ ] `--dry-run` — Report what would be fetched without changing anything.
- [ ] `--porcelain` — Emit machine-readable output.
- [x] `-q` / `--quiet` — Suppress progress and informational output.  `[log]`
- [x] `-v` / `--verbose` — Report more detail.
- [ ] `--progress` — Force progress reporting even when stderr is not a terminal.
- [ ] `-4` / `--ipv4` — Connect over IPv4 only.
- [ ] `-6` / `--ipv6` — Connect over IPv6 only.

### `pull-fetch-param` — positional arguments shared by `fetch` and `pull`

- [x] `<repository>` — The remote to fetch from, given as a URL or a configured remote name.  `[log]`
- [ ] `<group>` — A name from `remotes.<group>` expanding to several repositories.
- [x] `<refspec>` — Which refs to fetch and which local refs to update, in `[+]<src>:<dst>` form.

---

## `merge-options` — included by `merge` and `pull`

- [x] `--commit` / `--no-commit` — Create (or suppress) the merge commit after a successful merge.  `[log]`
- [x] `-e` / `--edit` / `--no-edit` — Open an editor on the auto-generated merge message.
- [ ] `--cleanup=<mode>` — Choose how the merge message is cleaned up before committing.
- [x] `--ff` / `--no-ff` / `--ff-only` — *(core)* Control fast-forwarding: allow, always create a merge commit, or refuse anything but a fast-forward.  `[log]`
- [ ] `-s <strategy>` / `--strategy=<strategy>` — Select the merge strategy.
- [ ] `-X <option>` / `--strategy-option=<option>` — Pass an option through to the merge strategy.
- [ ] `--squash` / `--no-squash` — Produce the merged tree and index without recording a merge or committing.
- [ ] `--log[=<n>]` / `--no-log` — Include one-line summaries of the merged commits in the message.
- [ ] `--stat` / `-n` / `--no-stat` — Show or suppress a diffstat after the merge.
- [ ] `--compact-summary` — Show a compact summary after the merge.
- [ ] `--summary` / `--no-summary` — Deprecated synonyms for `--stat` / `--no-stat`.
- [ ] `-S[<key-id>]` / `--gpg-sign[=<key-id>]` / `--no-gpg-sign` — Sign the resulting merge commit.
- [ ] `--verify` / `--no-verify` — Run or bypass the pre-merge and commit-msg hooks.
- [ ] `--verify-signatures` / `--no-verify-signatures` — Require a valid signature on the tip being merged.
- [ ] `--autostash` / `--no-autostash` — Stash local changes before merging and reapply afterwards.
- [ ] `--allow-unrelated-histories` — Permit merging histories with no common ancestor.
- [x] `-q` / `--quiet` — Operate quietly.
- [x] `-v` / `--verbose` — Be verbose.
- [ ] `--progress` / `--no-progress` — Force progress reporting on or off.

### `merge-strategies` — included by `merge`, `pull`, and `rebase`

- [x] `ort` — *(core)* The default three-way recursive merge, handling renames and criss-cross merges via a virtual merge base.
- [ ] `recursive` — The older implementation of the same idea, now deprecated in favor of `ort`.
- [ ] `resolve` — Simple three-way merge that picks a single merge base.
- [ ] `octopus` — Merge more than two heads at once, refusing anything requiring conflict resolution.
- [ ] `ours` — Record a merge that discards all changes from the other branches.
- [ ] `subtree` — Adjust trees to a common prefix before merging a subtree-style history.

Strategy options passed via `-X`: `ours`, `theirs`, `ignore-space-change`,
`ignore-all-space`, `ignore-space-at-eol`, `ignore-cr-at-eol`, `renormalize`,
`no-renormalize`, `find-renames[=<n>]`, `no-renames`, `rename-threshold=<n>`,
`histogram`, `patience`, `diff-algorithm=<algo>`, `subtree[=<path>]`.

### `rerere-options` — included by `am`, `cherry-pick`, `merge`, `rebase`, `revert`

> **CUT from v1** — rerere is cut from v1.

- [ ] `--rerere-autoupdate` / `--no-rerere-autoupdate` — Stage paths that rerere resolved automatically.

### `signoff-option` — included by `commit` and `merge-options`

- [x] `-s` / `--signoff` / `--no-signoff` — Append a `Signed-off-by` trailer identifying the committer.

### `sequencer` — included by `cherry-pick` and `revert`

- [x] `--continue` — *(core)* Resume the in-progress sequence after conflicts are resolved.
- [x] `--skip` — Drop the current commit and continue the sequence.
- [x] `--quit` — Abandon the sequence, keeping the work done so far.
- [x] `--abort` — Abandon the sequence and restore the pre-sequence state.

---

## `blame-options` — included by `blame` and `annotate`

> **CUT from v1** — blame is cut from v1 — see 11-ancillary-options.md

- [ ] `-L <start>,<end>` / `-L :<funcname>` — Annotate only the given line range or function.
- [ ] `-b` — Print a blank object name for boundary commits.
- [ ] `--root` — Do not treat root commits as boundaries.
- [ ] `--show-stats` — Print traversal statistics after the annotation.
- [ ] `-l` — Print full rather than abbreviated object names.
- [ ] `-t` — Print raw timestamps.
- [ ] `-S <revs-file>` — Take the revision list from a file instead of running `rev-list`.
- [ ] `--reverse <start>..<end>` — Walk forward in time to find where each line was last present.
- [ ] `--first-parent` — Follow only first parents when traversing merges.
- [ ] `-p` / `--porcelain` — Emit the machine-readable porcelain format.
- [ ] `--line-porcelain` — Emit porcelain format with full commit information repeated for every line.
- [ ] `--incremental` — Stream results as they are computed, in machine-readable form.
- [ ] `--encoding=<encoding>` — Re-encode names and summaries, or `none` to pass bytes through.
- [ ] `--contents <file>` — Blame the contents of a file not necessarily in the repository.
- [ ] `--date <format>` — Choose the date format used in output.
- [ ] `--progress` / `--no-progress` — Force progress reporting on or off.
- [ ] `-M[<num>]` — Detect lines moved or copied within the same file.
- [ ] `-C[<num>]` — Also detect lines moved or copied from other files; repeatable for wider searches.
- [ ] `--ignore-rev <rev>` — Attribute lines past a revision as if that revision never happened.
- [ ] `--ignore-revs-file <file>` — Ignore every revision listed in a file.
- [ ] `--color-lines` — Color repeated annotations from the same commit differently.
- [ ] `--color-by-age` — Color annotations according to line age.
- [ ] `-h` — Show the command's help message.
- [ ] `--diff-algorithm=<algo>` — Choose the diff algorithm used to compute line attribution.

### `line-range-options` — included by `log` and `gitk`

> **CUT from v1** — `log -L` needs line-level history tracking; cut from v1.

- [ ] `-L<start>,<end>:<file>` / `-L:<funcname>:<file>` — Trace the evolution of a line range or function through history.

---

## `for-each-ref-options` — included by `for-each-ref` and `refs`

- [x] `<pattern>…` — Show only refs matching at least one pattern.
- [ ] `--stdin` — Read the patterns from standard input.
- [x] `--count=<count>` — Stop after `<count>` refs.
- [x] `--sort=<key>` — Sort by a field name, `-` prefixed for descending; repeatable.
- [x] `--format[=<format>]` — *(core)* Interpolate `%(fieldname)` placeholders to build each output line.  `[log]`
- [ ] `--color[=<when>]` — Honor color directives in the format string.
- [ ] `--shell` / `--perl` / `--python` / `--tcl` — Quote substituted values as literals for the named language.
- [ ] `--points-at=<object>` — Show only refs pointing directly at an object.
- [x] `--merged[=<object>]` — Show only refs reachable from an object.
- [x] `--no-merged[=<object>]` — Show only refs not reachable from an object.
- [x] `--contains[=<object>]` — Show only refs whose history contains an object.
- [x] `--no-contains[=<object>]` — Show only refs whose history does not contain an object.
- [ ] `--ignore-case` — Sort and filter case-insensitively.
- [ ] `--omit-empty` — Suppress the newline when a format expands to nothing.
- [ ] `--exclude=<excluded-pattern>` — Skip refs matching a pattern; repeatable.
- [ ] `--include-root-refs` — Also list HEAD and other pseudorefs.
- [ ] `--start-after=<marker>` — Resume listing after a given ref, for pagination.

### `pack-refs-options` — included by `pack-refs` and `refs`

> **CUT from v1** — `pack-refs` is cut as a command; `gc` packs refs internally.

- [ ] `--all` — Pack every ref, not just the already-packed ones and tags.
- [ ] `--no-prune` — Keep the loose ref files after packing them.
- [ ] `--auto` — Pack only if the ref database's current state warrants it.
- [ ] `--include <pattern>` — Pack refs matching a glob; repeatable.
- [ ] `--exclude <pattern>` — Never pack refs matching a glob; repeatable.

---

## `date-formats` — included by `commit`, `commit-tree`, and `tag`

Not options but the accepted spellings of a date argument: git's internal
`<unix-timestamp> <time-zone-offset>` format, RFC 2822, ISO 8601, and the
free-form "approxidate" parser (`yesterday`, `3 weeks ago`, `last Tuesday`).
The approxidate parser alone is several hundred lines in git — a good early
candidate to cut down to ISO 8601 plus raw timestamps.
