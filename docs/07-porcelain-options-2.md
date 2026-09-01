# 07 — Main porcelain options, part 2 (`describe` … `notes`)

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


---

## `describe` — name a commit after the nearest tag

> **CUT from v1** — needs a tag-reachability walk for a naming convenience. v2.

- [ ] `<commit-ish>…` — Objects to describe; defaults to HEAD.
- [ ] `--dirty[=<mark>]` / `--broken[=<mark>]` — Append a marker when the working tree is modified (or unreadable).
- [ ] `--all` — Consider any ref under `refs/`, not just annotated tags.
- [ ] `--tags` — Consider lightweight tags as well as annotated ones.
- [ ] `--contains` — Name the commit after a tag that contains it rather than one that precedes it.
- [ ] `--abbrev=<n>` — Set the length of the abbreviated object name in the output.
- [ ] `--candidates=<n>` — Consider up to `<n>` candidate tags instead of 10.
- [ ] `--exact-match` — Only succeed when a tag points directly at the commit.
- [ ] `--long` — Always print the `<tag>-<n>-g<hash>` long form.
- [ ] `--match <pattern>` — Only consider tags matching a glob; repeatable.
- [ ] `--exclude <pattern>` — Never consider tags matching a glob; repeatable.
- [ ] `--always` — Fall back to an abbreviated object name when no tag is found.
- [ ] `--first-parent` — Follow only first parents when searching for a tag.
- [ ] `--debug` — Report the search strategy on stderr.

## `diff` — show changes between trees, index, and working tree

- [x] `<path>…` — Limit the diff to the given paths.  `[log]`
- [x] `--cached` / `--staged` — Diff the index against a commit (HEAD by default) instead of the working tree.  `[log]`
- [ ] `--merge-base` — Use the merge base of the named commit and HEAD as the "before" side.
- [x] `--no-index` — Diff two paths as plain files, ignoring the repository entirely.
- [ ] `-0` — Suppress diff output for unmerged entries, printing only `Unmerged`.
- [ ] `-1` / `--base`, `-2` / `--ours`, `-3` / `--theirs` — Diff the working tree against a specific merge stage.
- [ ] *diff options* — the entire `03-shared-diff-options.md` list.
- [ ] *raw format* — see the `diff-format` note in `03`.

Invocation forms that must be distinguished: no argument (worktree vs index),
`--cached`/`--staged` (index vs HEAD), one commit, two commits, `A...B`,
`--no-index <a> <b>`.

## `fetch` — download objects and refs from a remote

- [ ] `--stdin` — Read additional refspecs from standard input, one per line.
- [ ] *fetch options* — the entire `fetch-options` list in `05`.
- [ ] *positional parameters* — `<repository>`, `<group>`, `<refspec>` (see `05`).

## `format-patch` — turn commits into mail-formatted patch files

> **CUT from v1** — email workflow; pairs with `am` and `send-email`, all cut.

### Selecting and naming output

- [ ] `-<n>` — Format the topmost `<n>` commits.
- [ ] `--root` — Treat a single commit argument as a range starting from the root.
- [ ] `-o <dir>` / `--output-directory=<dir>` — Write the patches into a directory.
- [ ] `--stdout` — Write all patches to stdout in mbox format instead of files.
- [ ] `-n` / `--numbered` — Use `[PATCH n/m]` subjects even for a single patch.
- [ ] `-N` / `--no-numbered` — Use plain `[PATCH]` subjects.
- [ ] `--start-number <n>` — Begin numbering at `<n>`.
- [ ] `--numbered-files` — Name output files by number only, without the subject.
- [ ] `--suffix=.<sfx>` — Use a different filename suffix than `.patch`.
- [ ] `--filename-max-length=<n>` — Truncate generated filenames to about `<n>` bytes.
- [ ] `-q` / `--quiet` — Do not print the generated filenames.
- [ ] `--progress` — Report progress on stderr.

### Subject and headers

- [ ] `-k` / `--keep-subject` — Leave the subject line exactly as in the commit.
- [ ] `--subject-prefix=<subject-prefix>` — Replace `PATCH` in the bracketed subject prefix.
- [ ] `--rfc[=<rfc>]` — Prepend `RFC` (or another string) to the subject prefix.
- [ ] `-v <n>` / `--reroll-count=<n>` — Mark the series as iteration `<n>` and prefix filenames with `v<n>`.
- [ ] `--to=<email>` — Add a `To:` header; repeatable.
- [ ] `--cc=<email>` — Add a `Cc:` header; repeatable.
- [ ] `--from` / `--from=<ident>` — Set the `From:` header, moving the real author into an in-body `From:`.
- [ ] `--force-in-body-from` / `--no-force-in-body-from` — Always or never emit the in-body `From:` line.
- [ ] `--add-header=<header>` — Add an arbitrary header; repeatable.
- [ ] `--encode-email-headers` / `--no-encode-email-headers` — Q-encode non-ASCII header values.
- [ ] `--thread[=<style>]` / `--no-thread` — Add `In-Reply-To`/`References` headers (`shallow` or `deep`).
- [ ] `--in-reply-to=<message-id>` — Make the series a reply to an existing message.
- [ ] `--attach[=<boundary>]` — Send the patch as a MIME attachment.
- [ ] `--no-attach` — Never attach, overriding configuration.
- [ ] `--inline[=<boundary>]` — Send the patch as an inline MIME part.

### Cover letter and reviewer aids

- [ ] `--cover-letter` / `--no-cover-letter` — Generate a `0000-cover-letter` file for the series.
- [ ] `--cover-from-description=<mode>` — Choose which parts of the cover letter come from the branch description.
- [ ] `--description-file=<file>` — Use a file instead of the branch description for the cover letter.
- [ ] `--commit-list-format=<format-spec>` — Choose the format of the shortlog in the cover letter.
- [ ] `--interdiff=<previous>` — Insert an interdiff against a previous version of the series.
- [ ] `--range-diff=<previous>` — Insert a range-diff against a previous version of the series.
- [ ] `--creation-factor=<percent>` — Tune commit matching for `--range-diff`.
- [ ] `--notes[=<ref>]` / `--no-notes` — Append notes after the three-dash line.
- [ ] `--signature=<signature>` / `--no-signature` — Set or suppress the trailing signature.
- [ ] `--signature-file=<file>` — Read the signature from a file.
- [ ] `--no-base` / `--base[=<commit>]` — Record `base-commit` and prerequisite information for the series.

### Content

- [ ] `-s` / `--signoff` — Add a `Signed-off-by` trailer to each patch.
- [ ] `--ignore-if-in-upstream` — Skip patches already present upstream.
- [ ] `--always` — Include commits whose diff is empty.
- [ ] `--no-binary` — Note that binary files changed instead of emitting their content.
- [ ] `--zero-commit` — Write an all-zero hash in the `From` line.
- [ ] *diff options* — the entire `03-shared-diff-options.md` list.

## `gc` — repository housekeeping

- [ ] `--aggressive` — Repack more thoroughly at much higher cost.
- [ ] `--auto` — Do nothing unless housekeeping thresholds are exceeded.
- [ ] `--detach` / `--no-detach` — Run in the background when supported.
- [ ] `--cruft` / `--no-cruft` — Store unreachable objects in a cruft pack rather than loose.
- [ ] `--max-cruft-size=<n>` — Cap the size of newly written cruft packs.
- [ ] `--expire-to=<dir>` — Write pruned objects into a cruft pack in another directory.
- [x] `--prune=<date>` — Prune loose unreachable objects older than a date.
- [x] `--no-prune` — Do not prune loose objects at all.
- [ ] `--keep-largest-pack` — Treat all but the largest pack as loose and repack them.
- [ ] `--force` — Run even if another `gc` appears to be in progress.
- [x] `--quiet` — Suppress progress output.

## `grep` — search tracked content

### Where to search

- [x] `<pathspec>…` — Limit the search to matching paths.  `[log]`
- [x] `<tree>…` — Search blobs in the given trees instead of the working tree.  `[log]`
- [x] `--cached` — Search blobs registered in the index.
- [ ] `--untracked` — Also search untracked files.
- [x] `--no-index` — Search the current directory as plain files, ignoring git entirely.
- [ ] `--exclude-standard` — Honor the standard ignore rules.
- [ ] `--no-exclude-standard` — Also search ignored files.
- [ ] `--recurse-submodules` — Search active, checked-out submodules too.
- [ ] `--max-depth <depth>` — Descend at most `<depth>` directory levels per pathspec.
- [ ] `-r` / `--recursive` — Unlimited depth (the default).
- [ ] `--no-recursive` — Equivalent to `--max-depth=0`.
- [x] `--` — End option parsing.  `[log]`

### Pattern matching

- [x] `-e` — Treat the next argument as a pattern, even if it starts with `-`.
- [ ] `-f <file>` — Read patterns from a file, one per line.
- [x] `-i` / `--ignore-case` — Match case-insensitively.  `[log]`
- [x] `-w` / `--word-regexp` — Match only at word boundaries.
- [x] `-v` / `--invert-match` — Select lines that do not match.
- [x] `-E` / `--extended-regexp` — Use POSIX extended regular expressions.
- [ ] `-G` / `--basic-regexp` — Use POSIX basic regular expressions (the default).
- [ ] `-P` / `--perl-regexp` — Use PCRE.
- [x] `-F` / `--fixed-strings` — Treat the pattern as a literal string.  `[log]`
- [ ] `--and` / `--or` / `--not` / `( … )` — Combine multiple patterns with boolean operators.
- [ ] `--all-match` — Require every `--or`-combined pattern to match somewhere in the file.
- [ ] `-a` / `--text` — Treat binary files as text.
- [ ] `-I` — Never match inside binary files.
- [ ] `--textconv` / `--no-textconv` — Honor or ignore textconv filters when searching.

### Output

- [x] `-n` / `--line-number` — Prefix matches with their line number.  `[log]`
- [ ] `--column` — Prefix matches with the byte offset of the first match on the line.
- [x] `-h` / `-H` — Suppress or force the filename prefix.
- [ ] `--full-name` — Print paths relative to the repository root rather than the cwd.
- [x] `-l` / `--files-with-matches` / `--name-only` — List only the names of files containing matches.  `[log]`
- [x] `-L` / `--files-without-match` — List only the names of files with no match.
- [ ] `-o` / `--only-matching` — Print only the matching portion of each line.
- [x] `-c` / `--count` — Print only the number of matching lines per file.
- [x] `-q` / `--quiet` — Print nothing and signal the result through the exit status.  `[log]`
- [x] `-z` / `--null` — NUL-terminate path names and print them verbatim.
- [x] `--color[=<when>]` — Highlight matches in color.
- [x] `--no-color` — Disable match highlighting.
- [ ] `--break` — Print a blank line between files.
- [ ] `--heading` — Print the filename once above its matches.
- [ ] `-p` / `--show-function` — Print the enclosing function's declaration line.
- [x] `-<num>` / `-C <num>` / `--context <num>` — Show `<num>` lines of context around matches.
- [x] `-A <num>` / `--after-context <num>` — Show `<num>` trailing context lines.
- [x] `-B <num>` / `--before-context <num>` — Show `<num>` leading context lines.
- [ ] `-W` / `--function-context` — Show the whole enclosing function as context.
- [ ] `-m <num>` / `--max-count <num>` — Stop after `<num>` matches per file.
- [ ] `-O[<pager>]` / `--open-files-in-pager[=<pager>]` — Open the matching files in a pager.
- [ ] `--threads <num>` — Number of worker threads to use.

## `history` — declarative history rewriting `[experimental]`

> **CUT from v1** — experimental upstream.

Subcommands: `drop`, `fixup`, `reword`, `split`.

- [ ] `drop <commit>` — Remove a commit, replaying its descendants onto its parent.
- [ ] `fixup <commit>` — Fold the staged changes into an earlier commit.
- [ ] `reword <commit>` — Change an earlier commit's message only.
- [ ] `split <commit> [--] [<pathspec>…]` — Interactively split a commit into two.
- [ ] `--dry-run` — Print the ref updates that would be made, in `update-ref --stdin` form.
- [ ] `--reedit-message` — Open an editor on the target commit's message.
- [ ] `--empty=(drop|keep|abort)` — Decide what happens when a rewritten commit becomes empty.
- [ ] `--update-refs=(branches|head)` — Choose which refs the rewrite updates.

## `init` — create a repository

- [x] `-q` / `--quiet` — Print only errors and warnings.
- [x] `--bare` — Create a bare repository with no working tree.
- [x] `-b <branch-name>` / `--initial-branch=<branch-name>` — Name the initial branch.
- [ ] `--object-format=<format>` — *(core)* Choose the hash algorithm: `sha1` or `sha256`.
- [ ] `--ref-format=<format>` — Choose the ref backend: `files` or `reftable`.
- [ ] `--template=<template-directory>` — Copy an initial hook/info/description skeleton from a directory.
- [ ] `--separate-git-dir=<git-dir>` — Store the repository elsewhere, leaving a `.git` file behind.
- [ ] `--shared[=(false|true|umask|group|all|world|everybody|<perm>)]` — Set repository permissions for shared access.

## `log` — show commit history

- [x] `<revision-range>` — *(core)* Which commits to show; defaults to HEAD.  `[log]`
- [x] `[--] <path>…` — Show only commits touching these paths.  `[log]`
- [ ] `--follow` — Continue following a single file across renames.
- [x] `--decorate[=(short|full|auto|no)]` / `--no-decorate` — Annotate commits with the refs pointing at them.  `[log]`
- [ ] `--decorate-refs=<pattern>` / `--decorate-refs-exclude=<pattern>` — Restrict which refs may decorate output.
- [ ] `--clear-decorations` — Discard previous decoration filters.
- [ ] `--source` — Show which command-line ref each commit was reached through.
- [ ] `--mailmap` / `--no-mailmap` (aliases `--use-mailmap` / `--no-use-mailmap`) — Apply `.mailmap` identity rewriting.
- [ ] `--full-diff` — With a path limit, show the full diff of each shown commit.
- [ ] `--log-size` — Print the byte length of each commit message.
- [ ] `-L<start>,<end>:<file>` / `-L:<funcname>:<file>` — Trace the history of a line range or function.  `[log]`
- [ ] *rev-list options*, *pretty options*, *pretty formats*, *diff options* — see `03` and `04`.

## `maintenance` — run or schedule optimization tasks

> **CUT from v1** — scheduling wrapper around `gc`; the OS cron does this.

Subcommands: `run`, `start`, `stop`, `register`, `unregister`, `is-needed`.

- [ ] `run` — Run the selected maintenance tasks now.
- [ ] `start` — Register the repository and install a background schedule.
- [ ] `stop` — Remove the background schedule.
- [ ] `register` — Add the repository to the maintained list.
- [ ] `unregister` — Remove the repository from the maintained list.
- [ ] `is-needed` — Exit 0 if maintenance is currently warranted.
- [ ] `--auto` — Run tasks only when their thresholds are met.
- [ ] `--schedule` — Run tasks only when their time conditions are met.
- [ ] `--task=<task>` — Run only the named tasks, in order (`gc`, `commit-graph`, `prefetch`, `loose-objects`, `incremental-repack`, `pack-refs`, `reflog-expire`, `worktree-prune`, `rerere-gc`).
- [ ] `--scheduler=(auto|crontab|systemd-timer|launchctl|schtasks)` — Choose the OS scheduler used by `start`.
- [ ] `--quiet` — Suppress progress output.

## `merge` — join development histories

- [x] `<commit>…` — *(core)* The heads to merge into the current branch.  `[log]`
- [x] `-m <msg>` — Set the merge commit message.
- [ ] `-F <file>` / `--file=<file>` — Read the merge commit message from a file.
- [ ] `--into-name <branch>` — Compose the default message as if merging into a different branch name.
- [ ] `--overwrite-ignore` / `--no-overwrite-ignore` — Control whether ignored files may be overwritten by the merge result.
- [x] `--abort` — *(core)* Abandon the merge and restore the pre-merge state.  `[log]`
- [x] `--quit` — Forget the in-progress merge, leaving index and working tree alone.
- [x] `--continue` — Conclude a merge after conflicts have been resolved.
- [ ] *merge options*, *merge strategies*, *rerere options* — see `05`.

## `mv` — move or rename tracked paths

- [x] `-f` / `--force` — Overwrite an existing destination.
- [ ] `-k` — Skip moves that would error rather than failing the command.
- [x] `-n` / `--dry-run` — Report what would move without moving anything.
- [x] `-v` / `--verbose` — Print each path as it is moved.

## `notes` — attach notes to objects

> **CUT from v1** — a second object graph layered on commits, for a feature few use.

Subcommands: `list`, `add`, `copy`, `append`, `edit`, `show`, `merge`,
`remove`, `prune`, `get-ref`.

- [ ] `list` — List note objects, or the note attached to one object.
- [ ] `add` — Attach a new note to an object.
- [ ] `copy` — Copy one object's notes onto another object.
- [ ] `append` — Append text to an existing note.
- [ ] `edit` — Edit an object's note in an editor.
- [ ] `show` — Print an object's note.
- [ ] `merge` — Merge another notes ref into the current one.
- [ ] `remove` — Delete an object's notes.
- [ ] `prune` — Delete notes attached to objects that no longer exist.
- [ ] `get-ref` — Print the notes ref currently in use.
- [ ] `--ref=<ref>` — Operate on a specific notes ref instead of the default.
- [ ] `-f` / `--force` — Overwrite existing notes instead of aborting.
- [ ] `-m <msg>` / `--message=<msg>` — Supply the note text; repeatable.
- [ ] `-F <file>` / `--file=<file>` — Read the note text from a file or stdin.
- [ ] `-C <object>` / `--reuse-message=<object>` — Reuse an existing blob as the note text.
- [ ] `-c <object>` / `--reedit-message=<object>` — As `-C`, but edit it first.
- [ ] `--allow-empty` — Store an empty note rather than removing it.
- [ ] `--separator=<paragraph-break>` / `--separator` / `--no-separator` — Set the separator inserted between appended paragraphs.
- [ ] `--stripspace` / `--no-stripspace` — Normalize whitespace in the note text.
- [ ] `--ignore-missing` — Do not error when removing notes from an object that has none.
- [ ] `--stdin` — Read object names from stdin (`remove` and `copy` only).
- [ ] `-n` / `--dry-run` — Report what would be removed without removing it.
- [ ] `-s <strategy>` / `--strategy=<strategy>` — Conflict strategy for `merge` (`manual`, `ours`, `theirs`, `union`, `cat_sort_uniq`).
- [ ] `--commit` — Finalize an in-progress notes merge after resolving conflicts.
- [ ] `--abort` — Abandon an in-progress notes merge.
- [ ] `-q` / `--quiet` — Operate quietly while merging.
- [ ] `-v` / `--verbose` — Report more detail while merging or pruning.
