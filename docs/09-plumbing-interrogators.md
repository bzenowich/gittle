# 09 — Low-level plumbing: interrogators

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


Read-only commands that expose the object database, index, and refs. These are
the layer a reimplementation is actually built on: most of gittle's porcelain
is a composition of what is listed here plus the manipulators in `10`.

---

## `cat-file` — inspect objects

- [x] `<object>` — *(core)* The object to inspect.  `[log]`
- [x] `<type>` — Assert or dereference to a type (`blob`, `tree`, `commit`, `tag`).
- [x] `-t` — *(core)* Print the object's type.  `[log]`
- [x] `-s` — *(core)* Print the object's size.
- [x] `-e` — Exit zero if the object exists and is valid, printing nothing.
- [x] `-p` — *(core)* Pretty-print the object according to its type.
- [x] `--batch` / `--batch=<format>` — *(core)* Read object names on stdin and print info plus content for each.
- [x] `--batch-check` / `--batch-check=<format>` — Read object names on stdin and print only their metadata.
- [ ] `--batch-command` / `--batch-command=<format>` — Read a command stream on stdin: `contents`, `info`, `remote-object-info`, `flush`, `mailmap (<bool>)`.
- [ ] `--batch-all-objects` — Operate on every object in the database instead of reading stdin.
- [ ] `--buffer` — Buffer batch output until a `flush` instead of flushing per object.
- [ ] `--unordered` — With `--batch-all-objects`, visit objects in storage order for speed.
- [ ] `--follow-symlinks` — Follow in-repository symlinks when resolving `<tree-ish>:<path>`.
- [ ] `-z` — NUL-delimit batch input.
- [ ] `-Z` — NUL-delimit both batch input and output.
- [ ] `--textconv` — Print the content transformed by the configured textconv filter.
- [ ] `--filters` — Print the content as the working-tree (smudge) filters would produce it.
- [ ] `--path=<path>` — Supply the path separately for `--textconv`/`--filters`.
- [ ] `--filter=<filter-spec>` / `--no-filter` — Omit objects matching a filter from `--batch-all-objects`.
- [ ] `--mailmap` / `--no-mailmap` (aliases `--use-mailmap` / `--no-use-mailmap`) — Rewrite identities through `.mailmap`.

## `cherry` — find commits not yet upstream

> **CUT from v1** — patch-ID equivalence, needed only for mail-based workflows.

- [ ] `<upstream>` — Branch to compare against; defaults to the upstream of HEAD.
- [ ] `<head>` — Branch whose commits are examined; defaults to HEAD.
- [ ] `<limit>` — Ignore commits up to and including this one.
- [ ] `-v` — Print the commit subject alongside each object name.

## `diff-files` — working tree versus index

> **CUT from v1** — `git diff` covers this; the plumbing spelling adds a second entry point to the same engine.

- [ ] `-1` / `--base`, `-2` / `--ours`, `-3` / `--theirs`, `-0` — Compare against a particular merge stage.
- [ ] `-c` / `--cc` — Produce a combined diff of stages 2, 3, and the working-tree file.
- [ ] `-q` — Stay silent about nonexistent files.
- [ ] *diff options*, *raw diff format* — see `03`.

## `diff-index` — tree versus index or working tree

> **CUT from v1** — covered by `git diff --cached`.

- [ ] `<tree-ish>` — *(core)* The tree to compare against.
- [ ] `--cached` — *(core)* Compare against the index only, ignoring the working tree.
- [ ] `--merge-base` — Compare against the merge base of `<tree-ish>` and HEAD.
- [ ] `-m` — Report index entries missing from the working tree as unchanged rather than deleted.
- [ ] *diff options*, *raw diff format* — see `03`.

## `diff-tree` — tree versus tree

> **CUT from v1** — covered by `git diff <tree> <tree>`.

- [ ] `<tree-ish>` — *(core)* One or two trees to compare.
- [ ] `<path>…` — Limit the comparison to matching paths.
- [ ] `-r` — *(core)* Recurse into subtrees.
- [ ] `-t` — Also show the tree entries themselves (implies `-r`).
- [ ] `--root` — Show the initial commit as a full creation event.
- [ ] `--merge-base` — Use the merge base of the two trees as the "before" side.
- [ ] `--stdin` — Read commits (or tree pairs) from standard input.
- [ ] `-m` — With `--stdin`, also show differences for merge commits.
- [ ] `-s` — With `--stdin`, suppress the diff output.
- [ ] `-v` — With `--stdin`, also print the commit message.
- [ ] `--no-commit-id` — Suppress the commit ID header line.
- [ ] `-c` — Show a combined diff for merge commits.
- [ ] `--cc` — Show a dense combined diff for merge commits.
- [ ] `--combined-all-paths` — List the filename from every parent in combined diffs.
- [ ] `--always` — Show the commit and message even when the diff is empty.
- [ ] *diff options*, *pretty options*, *pretty formats*, *raw diff format* — see `03` and `04`.

## `diff-pairs` — diff explicitly supplied blob pairs

> **CUT from v1** — niche.

- [ ] `-z` — Required: read NUL-delimited raw-format records on stdin and emit NUL-delimited output.
- [ ] *diff options* — see `03`.

## `for-each-ref` — iterate over refs

- [ ] *for-each-ref options* — the entire list in `05`.

The `%(fieldname)` vocabulary (`refname`, `objectname`, `objecttype`,
`objectsize`, `upstream`, `push`, `HEAD`, `symref`, `committerdate`,
`contents:subject`, `align:`, `if:`/`then:`/`end`, …) is documented in
`Documentation/git-for-each-ref.adoc` under FIELD NAMES, and is shared with
`git branch --format`, `git tag --format`, and `git ls-tree --format`.

## `for-each-repo` — run a command across many repositories

> **CUT from v1** — a shell `for` loop.

- [ ] `--config=<config>` — Read the repository path list from a multi-valued config variable.
- [ ] `--keep-going` — Continue after a failure in one repository.

## `format-rev` — pretty-print revisions on demand `[experimental]`

> **CUT from v1** — experimental upstream.

- [ ] `--stdin-mode=<mode>` — How to interpret each stdin record.
- [ ] `--format=<pretty>` — Pretty format string to apply.
- [ ] `--notes=<ref>` / `--no-notes` — Notes ref used for the `%N` placeholder.
- [ ] `-z` / `--null` — NUL-terminate both input and output.
- [ ] `--null-input` / `--no-null-input` — NUL-terminate input only.
- [ ] `--null-output` / `--no-null-output` — NUL-terminate output only.

## `get-tar-commit-id` — read the commit ID from a `git archive` tar

> **CUT from v1** — `archive` is cut.

No options; reads a tar stream on stdin and prints the embedded commit ID.

## `last-modified` — when each path was last changed `[experimental]`

> **CUT from v1** — experimental upstream.

- [ ] `<revision-range>` — Commits to consider; defaults to HEAD.
- [ ] `[--] <pathspec>…` — Paths to report on.
- [ ] `-r` / `--recursive` — Recurse into subtrees.
- [ ] `-t` / `--show-trees` — Show tree entries as well when recursing.
- [ ] `--max-depth=<depth>` — Limit subtree traversal depth.
- [ ] `-z` — NUL-terminate output records.

## `ls-files` — list index and working-tree files

### What to list

- [x] `<file>` — Restrict the listing to matching paths.
- [x] `-c` / `--cached` — *(core)* List tracked files (the default).
- [x] `-d` / `--deleted` — List files deleted from the working tree.
- [x] `-m` / `--modified` — List files modified in the working tree.
- [x] `-o` / `--others` — *(core)* List untracked files.
- [x] `-i` / `--ignored` — List only ignored files (requires `-c` or `-o`).
- [x] `-s` / `--stage` — *(core)* Show mode, object name, and stage number.  `[log]`
- [x] `-u` / `--unmerged` — List only unmerged entries with their stages.
- [ ] `-k` / `--killed` — List untracked files that conflict with tracked paths.
- [ ] `--resolve-undo` — Show resolve-undo information stored in the index.
- [ ] `--directory` — Collapse wholly untracked directories to a single entry.
- [ ] `--no-empty-directory` — Omit empty directories from `--directory` output.
- [ ] `--deduplicate` — Suppress duplicate names arising from multiple stages.
- [x] `--error-unmatch` — Exit non-zero if a named path is not in the index.  `[log]`
- [ ] `--with-tree=<tree-ish>` — Also consider paths from a tree when matching.
- [ ] `--recurse-submodules` — Recurse into active submodules.
- [ ] `--sparse` — Show sparse directories without expanding them.
- [x] `--` — End option parsing.

### Exclude handling

- [ ] `-x <pattern>` / `--exclude=<pattern>` — Skip untracked files matching a pattern.
- [ ] `-X <file>` / `--exclude-from=<file>` — Read exclude patterns from a file.
- [ ] `--exclude-per-directory=<file>` — Read per-directory exclude files (i.e. `.gitignore`).
- [x] `--exclude-standard` — *(core)* Apply git's standard exclude sources.

### Output

- [x] `-z` — *(core)* NUL-terminate records and do not quote paths.
- [ ] `-t` — Prefix each path with a status tag.
- [ ] `-v` — As `-t`, lowercasing tags for assume-unchanged entries.
- [ ] `-f` — As `-t`, lowercasing tags for fsmonitor-valid entries.
- [ ] `--full-name` — Print paths relative to the repository root.
- [ ] `--abbrev[=<n>]` — Abbreviate object names in `--stage` output.
- [ ] `--eol` — Show detected and configured end-of-line information per file.
- [ ] `--format=<format>` — Format each entry using `%(fieldname)` placeholders.
- [ ] `--debug` — Dump the full cache entry after each path.

## `ls-remote` — list refs advertised by a remote

- [x] `<repository>` — *(core)* Remote name or URL to query.
- [x] `<patterns>…` — Show only refs matching these patterns.
- [x] `-b` / `--branches` — Limit output to `refs/heads/`.
- [x] `-t` / `--tags` — Limit output to `refs/tags/`.
- [x] `--refs` — Suppress peeled tag entries and pseudorefs.
- [ ] `--symref` — Also show what symbolic refs (such as HEAD) point at.
- [ ] `--sort=<key>` — Sort the output by a ref field.
- [ ] `--exit-code` — Exit 2 when no ref matched.
- [ ] `--get-url` — Print the expanded URL for the remote and exit.
- [x] `--upload-pack=<exec>` — Override the remote `git-upload-pack` path.
- [ ] `-o <option>` / `--server-option=<option>` — Send a server option (protocol v2 only).
- [x] `-q` / `--quiet` — Do not echo the remote URL to stderr.

## `ls-tree` — list a tree object's entries

- [x] `<tree-ish>` — *(core)* The tree to list.  `[log]`
- [x] `[<path>…]` — Limit output to matching entries.  `[log]`
- [x] `-d` — List only the named tree entries, not their children.
- [x] `-r` — *(core)* Recurse into subtrees.  `[log]`
- [x] `-t` — Show tree entries as well as their contents when recursing.
- [x] `-l` / `--long` — Include blob sizes in the output.
- [x] `-z` — NUL-terminate records and do not quote paths.
- [x] `--name-only` / `--name-status` — Print only path names.  `[log]`
- [ ] `--object-only` — Print only object names.
- [x] `--abbrev[=<n>]` — Abbreviate object names.
- [ ] `--full-name` — Print paths relative to the repository root.
- [ ] `--full-tree` — List from the repository root regardless of the current directory.
- [ ] `--format=<format>` — Format entries using `%(fieldname)` placeholders.

## `merge-base` — find common ancestors

- [x] `-a` / `--all` — Print every best common ancestor rather than one.  `[log]`
- [ ] `--octopus` — Compute the best common ancestor of more than two commits.
- [ ] `--independent` — Print the subset of the given commits that no other reaches.
- [x] `--is-ancestor` — *(core)* Exit zero if the first commit is an ancestor of the second.  `[log]`
- [ ] `--fork-point` — Find where a branch diverged, consulting the reflog.

## `name-rev` — name commits from reachable refs

> **CUT from v1** — needed only by `describe` and `log --source`, both cut.

- [ ] `--tags` — Use only tags, not branch names.
- [ ] `--refs=<pattern>` — Only use refs matching a pattern; repeatable.
- [ ] `--exclude=<pattern>` — Never use refs matching a pattern; repeatable.
- [ ] `--all` — Name every commit reachable from any ref.
- [ ] `--annotate-stdin` — Rewrite object names found on stdin into `<hex> (<name>)`.
- [ ] `--name-only` — Print only the derived name.
- [ ] `--no-undefined` — Exit non-zero rather than printing `undefined`.
- [ ] `--always` — Fall back to an abbreviated object name.

## `pack-redundant` — find fully-covered packfiles (deprecated)

> **CUT from v1** — deprecated upstream.

- [ ] `--all` — Consider every pack in the repository.
- [ ] `--alt-odb` — Also count objects available from alternate object stores.
- [ ] `--verbose` — Print statistics to stderr.

## `repo` — report repository facts

> **CUT from v1** — introspection covered by `rev-parse`.

- [ ] `info [--all | <key>…]` — Print selected repository metadata as key/value pairs.
- [ ] `info --keys` — List the available metadata keys.
- [ ] `structure` — Print statistics about the repository's structure.
- [ ] `--format=(lines|nul|table)` — Choose the output format (`table` only for `structure`).
- [ ] `-z` — Shorthand for `--format=nul`.

## `rev-list` — walk history and list objects

- [x] `<commit>…` / `[--] <path>…` — *(core)* Starting points and optional path limits.  `[log]`
- [ ] *rev-list options*, *pretty options*, *pretty formats* — the entire lists in `04`.

`rev-list` has no options of its own beyond the shared group: it *is* the
shared group. It is the single most important plumbing command for a git
reimplementation, because `pack-objects`, `fetch`, `push`, `gc`, and `log` all
route through the same traversal.

## `rev-parse` — parse revision and path arguments

### Object name resolution

- [x] `<arg>…` — *(core)* Flags and parameters to parse.  `[log]`
- [x] `--verify` — *(core)* Require exactly one argument that resolves to a single object.
- [x] `-q` / `--quiet` — With `--verify`, fail silently.
- [x] `--short[=<length>]` — Print an abbreviated object name.  `[log]`
- [ ] `--default <arg>` — Substitute a default when the user gave no parameter.
- [ ] `--not` — Toggle the `^` prefix on printed object names.
- [ ] `--symbolic` — Print names in their symbolic form where possible.
- [x] `--symbolic-full-name` — Print full ref names, omitting arguments that are not refs.  `[log]`
- [x] `--abbrev-ref[=(strict|loose)]` — Print the shortest unambiguous ref name.  `[log]`
- [ ] `--disambiguate=<prefix>` — List every object whose name begins with a prefix.
- [ ] `--output-object-format=(sha1|sha256|storage)` — Convert printed object IDs to another hash format.
- [ ] `--revs-only` / `--no-revs` — Print only, or never, arguments meaningful to `rev-list`.
- [ ] `--flags` / `--no-flags` — Print only, or never, flag arguments.
- [ ] `--all` — Print every ref under `refs/`.
- [ ] `--branches[=<pattern>]` / `--tags[=<pattern>]` / `--remotes[=<pattern>]` — Print refs from one namespace.
- [ ] `--glob=<pattern>` — Print refs matching a glob.
- [ ] `--exclude=<glob-pattern>` — Exclude refs from the following pseudo-ref expansion.
- [ ] `--exclude-hidden=(fetch|receive|uploadpack)` — Exclude refs the named transport would hide.
- [ ] `--since=<datestring>` / `--after=<datestring>` — Convert a date into a `--max-age=` argument.
- [ ] `--until=<datestring>` / `--before=<datestring>` — Convert a date into a `--min-age=` argument.

### Repository layout queries

- [x] `--git-dir` — *(core)* Print the repository directory.
- [ ] `--absolute-git-dir` — Print the canonical absolute repository directory.
- [ ] `--git-common-dir` — Print the common directory shared by linked worktrees.
- [ ] `--git-path <path>` — Resolve a path inside the repository, honoring relocation variables.
- [ ] `--resolve-git-dir <path>` — Validate a path as a repository or gitfile and print the real location.
- [x] `--show-toplevel` — *(core)* Print the working tree root.  `[log]`
- [x] `--show-cdup` — Print the relative path up to the working tree root.
- [x] `--show-prefix` — Print the current directory relative to the working tree root.
- [ ] `--show-superproject-working-tree` — Print the superproject's working tree root.
- [ ] `--shared-index-path` — Print the shared index path in split-index mode.
- [x] `--is-inside-git-dir` — Print whether the cwd is inside the repository directory.
- [x] `--is-inside-work-tree` — Print whether the cwd is inside the working tree.  `[log]`
- [x] `--is-bare-repository` — Print whether the repository is bare.
- [ ] `--is-shallow-repository` — Print whether the repository is shallow.
- [ ] `--show-object-format[=(storage|input|output|compat)]` — Print the repository's hash algorithm.
- [ ] `--show-ref-format` — Print the repository's ref storage format.
- [ ] `--path-format=(absolute|relative)` — Control whether subsequent path queries print absolute or relative paths.
- [ ] `--local-env-vars` — List the `GIT_*` variables that are repository-local.

### Script-support modes

- [ ] `--parseopt` — Act as an option parser for shell scripts.
- [ ] `--keep-dashdash` — In `--parseopt` mode, echo the first `--` rather than consuming it.
- [ ] `--stop-at-non-option` — In `--parseopt` mode, stop at the first non-option argument.
- [ ] `--stuck-long` — In `--parseopt` mode, emit long options with stuck arguments.
- [ ] `--sq-quote` — Shell-quote the arguments and print them.
- [ ] `--sq` — Print the normal output as a single shell-quoted line.
- [ ] *revision syntax* — `rev-parse` also documents the whole `<rev>` grammar (`HEAD@{2}`, `A^`, `A~3`, `A..B`, `A...B`, `:/text`, `:<n>:<path>`, …) via `gitrevisions`.

## `show-index` — dump a packfile index

> **CUT from v1** — debugging aid.

- [ ] `--object-format=<hash-algorithm>` — Interpret the index using the given hash algorithm.

## `show-ref` — list local refs

> **CUT from v1** — superseded by `for-each-ref`, which v1 keeps.

- [ ] `<pattern>…` — Show only refs matching these patterns.
- [ ] `--head` — Include HEAD in the output.
- [ ] `--branches` / `--tags` — Limit the output to one namespace.
- [ ] `-d` / `--dereference` — Also show what annotated tags point at, suffixed `^{}`.
- [ ] `-s` / `--hash[=<n>]` — Print only object names.
- [ ] `--verify` — Require an exact, existing ref path.
- [ ] `--exists` — Exit 0/2/1 depending on whether a ref exists, is missing, or errored.
- [ ] `--abbrev[=<n>]` — Abbreviate printed object names.
- [ ] `-q` / `--quiet` — Print nothing, leaving only the exit status.
- [ ] `--exclude-existing[=<pattern>]` — Filter stdin, printing only refs that do not exist locally.

## `unpack-file` — write a blob to a temporary file

> **CUT from v1** — `cat-file -p` covers it.

- [ ] `<blob>` — The blob to materialize; the temporary file's name is printed.

## `var` — print a logical variable

> **CUT from v1** — introspection convenience.

- [ ] `<variable>` — The logical variable to print (`GIT_AUTHOR_IDENT`, `GIT_COMMITTER_IDENT`, `GIT_EDITOR`, `GIT_PAGER`, `GIT_DEFAULT_BRANCH`, `GIT_SHELL_PATH`, …).
- [ ] `-l` — List all logical variables plus the configuration.

## `verify-pack` — validate a packfile

> **CUT from v1** — validation tool; `index-pack` already verifies checksums on receipt.

- [ ] `-v` / `--verbose` — List the pack's objects and a delta-chain histogram.
- [ ] `-s` / `--stat-only` — Print only the delta-chain histogram, skipping verification.
- [ ] `--` — End option parsing.
