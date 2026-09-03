# 08 — Main porcelain options, part 3 (`pull` … `worktree`, plus `gitk` and `scalar`)

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


---

## `pull` — fetch and integrate

- [x] `<repository>` — Remote to pull from.
- [x] `<refspec>` — Which refs to fetch and integrate.
- [x] `-r` / `--rebase[=(true|merges|false|interactive)]` — *(core)* Rebase the current branch onto the fetched upstream instead of merging.
- [x] `--no-rebase` — Shorthand for `--rebase=false`.
- [x] `-q` / `--quiet` — Pass `--quiet` to both `fetch` and the integration step.
- [x] `-v` / `--verbose` — Pass `--verbose` to both `fetch` and the integration step.
- [ ] `--recurse-submodules[=(yes|on-demand|no)]` / `--no-recurse-submodules` — Also update submodules after integrating.
- [ ] *fetch options*, *merge options*, *positional parameters* — see `05`.

`pull` is entirely a composition of `fetch` plus `merge`/`rebase`; if gittle
ships those two, `pull` is thin glue plus argument routing.

## `push` — send refs and objects to a remote

### What to push

- [x] `<repository>` — *(core)* Remote to push to.  `[log]`
- [x] `<refspec>…` — *(core)* Which local object updates which remote ref, as `[+]<src>:<dst>`.  `[log]`
- [ ] `--all` / `--branches` — Push every branch under `refs/heads/`.
- [x] `--tags` — Push every tag in addition to any listed refspecs.
- [ ] `--follow-tags` — Also push annotated tags reachable from the pushed refs.
- [ ] `--mirror` — Push every ref under `refs/`, deleting remote refs that are gone locally.
- [ ] `--prune` — Delete remote refs that have no local counterpart.
- [x] `-d` / `--delete` — Delete the named refs on the remote.
- [ ] `--repo=<repository>` — Alternative spelling of the `<repository>` argument.

### Safety and force

- [x] `-f` / `--force` — *(core)* Allow non-fast-forward updates.
- [x] `--force-with-lease[=<refname>[:<expect>]]` / `--no-force-with-lease` — Force only if the remote ref still has the expected value.
- [ ] `--force-if-includes` / `--no-force-if-includes` — Force only if the remote tip is already integrated locally.
- [ ] `--atomic` / `--no-atomic` — Update all refs in a single remote transaction, or none.
- [ ] `--signed` / `--no-signed` / `--signed=(true|false|if-asked)` — Sign the push certificate.
- [ ] `--verify` / `--no-verify` — Run or bypass the `pre-push` hook.
- [x] `-n` / `--dry-run` — Do everything except sending the updates.

### Transport and reporting

- [ ] `-o <option>` / `--push-option=<option>` — Send an arbitrary option to the receiving side's hooks.
- [x] `--receive-pack=<git-receive-pack>` / `--exec=<git-receive-pack>` — Override the remote receiver path.
- [ ] `--thin` / `--no-thin` — Send a thin pack that assumes the receiver already has base objects.
- [x] `-u` / `--set-upstream` — Record upstream tracking for the pushed branches.  `[log]`
- [ ] `--porcelain` — Emit machine-readable per-ref status.
- [x] `-q` / `--quiet` — Suppress all output except errors.
- [x] `-v` / `--verbose` — Report more detail.
- [ ] `--progress` — Force progress reporting.
- [ ] `-4` / `--ipv4` — Connect over IPv4 only.
- [ ] `-6` / `--ipv6` — Connect over IPv6 only.
- [ ] `--recurse-submodules=(check|on-demand|only|no)` / `--no-recurse-submodules` — Verify or push submodule commits alongside the superproject.

## `range-diff` — compare two versions of a patch series

> **CUT from v1** — patch-series review tool that depends on `format-patch`.

- [ ] `<range1> <range2>` — Compare two commit ranges, treating the first as the older version.
- [ ] `<rev1>...<rev2>` — Shorthand for the two ranges either side of a symmetric difference.
- [ ] `<base> <rev1> <rev2>` — Shorthand for `<base>..<rev1>` and `<base>..<rev2>`.
- [ ] `--no-dual-color` — Use plain diff coloring rather than nested inner/outer coloring.
- [ ] `--creation-factor=<percent>` — Tune the heuristic matching commits between the two ranges.
- [ ] `--left-only` — Show only commits missing from the second range.
- [ ] `--right-only` — Show only commits missing from the first range.
- [ ] `--diff-merges=<format>` — Diff merge commits instead of ignoring them.
- [ ] `--remerge-diff` — Shorthand for `--diff-merges=remerge`.
- [ ] `--notes[=<ref>]` / `--no-notes` — Include notes in the compared patches.

## `rebase` — reapply commits on a new base

### Mode

- [x] `--continue` — *(core)* Resume after resolving a conflict.
- [x] `--skip` — Drop the current patch and continue.
- [x] `--abort` — *(core)* Abort and restore the original branch.
- [x] `--quit` — Abort without restoring the original branch.
- [ ] `--edit-todo` — Edit the remaining todo list during an interactive rebase.
- [ ] `--show-current-patch` — Show the patch the rebase stopped on.

### What to rebase

- [x] `<upstream>` — Branch or commit to rebase against.
- [x] `<branch>` — Branch to rebase; defaults to HEAD.
- [x] `--onto <newbase>` — *(core)* Place the rebased commits onto a different base than `<upstream>`.
- [ ] `--keep-base` — Rebase onto the merge base of `<upstream>` and `<branch>`.
- [ ] `--root` — Rebase all commits including the root, with no `<upstream>`.
- [ ] `--fork-point` / `--no-fork-point` — Use the reflog to find a better common ancestor.

### Backend and strategy

- [ ] `-m` / `--merge` — Use the merge backend (the default).
- [ ] `--apply` — Use the `am`-based apply backend.
- [ ] `-s <strategy>` / `--strategy=<strategy>` — Choose the merge strategy (implies `--merge`).
- [ ] `-X <strategy-option>` / `--strategy-option=<strategy-option>` — Pass an option to the merge strategy.
- [ ] `-C<n>` — Require `<n>` lines of matching context when applying (apply backend).
- [ ] `--ignore-whitespace` — Ignore whitespace differences while reconciling.
- [ ] `--whitespace=<option>` — Pass a whitespace policy to `apply` (implies `--apply`).
- [ ] *rerere options* — `--rerere-autoupdate` / `--no-rerere-autoupdate`.

### Which commits survive

- [ ] `--empty=(drop|keep|stop)` — Handle commits that become empty during the rebase.
- [ ] `--no-keep-empty` / `--keep-empty` — Handle commits that were already empty before the rebase.
- [ ] `--reapply-cherry-picks` / `--no-reapply-cherry-picks` — Keep or drop commits already upstream as clean cherry-picks.
- [ ] `--allow-empty-message` — No-op retained for compatibility.
- [ ] `--no-ff` / `--force-rebase` / `-f` — Replay every commit rather than fast-forwarding unchanged ones.

### Interactive and scripted rebases

- [ ] `-i` / `--interactive` — *(core for a full rebase)* Edit the todo list before replaying.
- [ ] `-r` / `--rebase-merges[=(rebase-cousins|no-rebase-cousins)]` / `--no-rebase-merges` — Recreate merge commits instead of flattening them.
- [ ] `-x <cmd>` / `--exec <cmd>` — Run a command after each replayed commit.
- [ ] `--reschedule-failed-exec` / `--no-reschedule-failed-exec` — Re-queue an `exec` that failed.
- [ ] `--autosquash` / `--no-autosquash` — Reorder and squash `fixup!`/`squash!` commits automatically.
- [ ] `--autostash` / `--no-autostash` — Stash and restore local changes around the rebase.
- [ ] `--update-refs` / `--no-update-refs` — Move other branches that pointed at rebased commits.

### Commit metadata and output

- [ ] `--committer-date-is-author-date` — Use each commit's author date as its committer date.
- [ ] `--ignore-date` / `--reset-author-date` — Set the author date to now.
- [ ] `--signoff` — Add a `Signed-off-by` trailer to each rebased commit.
- [ ] `--trailer=<trailer>` — Append a trailer to every rebased commit message.
- [ ] `-S[<keyid>]` / `--gpg-sign[=<keyid>]` / `--no-gpg-sign` — Sign the rebased commits.
- [ ] `--verify` / `--no-verify` — Run or bypass the `pre-rebase` hook.
- [x] `-q` / `--quiet` — Be quiet (implies `--no-stat`).
- [x] `-v` / `--verbose` — Be verbose (implies `--stat`).
- [ ] `--stat` / `-n` / `--no-stat` — Show or suppress a diffstat of what changed upstream.

The manual page also has an INCOMPATIBLE OPTIONS section listing which of the
above cannot be combined — worth reading before designing gittle's argument
validation.

## `reset` — move HEAD, index, and optionally the working tree

- [x] `<commit>` — The commit to reset to; defaults to HEAD.
- [x] `<tree-ish>` — Tree to restore index entries from in the pathspec form.
- [x] `<pathspec>…` — Reset only these paths in the index, leaving HEAD alone.
- [x] `--soft` — *(core)* Move HEAD only, leaving index and working tree untouched.  `[log]`
- [x] `--mixed` — *(core, default)* Move HEAD and reset the index, leaving the working tree untouched.
- [x] `--hard` — *(core)* Move HEAD and reset both the index and the working tree.
- [ ] `--merge` — Reset the index and update working-tree files that differ, refusing if that would lose local changes.
- [ ] `--keep` — Reset the index and update differing files, aborting if any of them have local changes.
- [ ] `-N` — With `--mixed`, mark removed paths as intent-to-add.
- [ ] `-p` / `--patch` — Interactively choose hunks to unstage.
- [x] `-q` / `--quiet` — Report only errors.  `[log]`
- [ ] `--refresh` / `--no-refresh` — Refresh the index after a mixed reset.
- [ ] `--pathspec-from-file=<file>` — Read the pathspec from a file or stdin.
- [ ] `--pathspec-file-nul` — Treat that file as NUL-separated and literal.
- [x] `--` — End option parsing.
- [ ] *diff-context options* — `-U<n>`, `--inter-hunk-context` for `--patch` mode.

## `restore` — restore working-tree and index files

- [x] `<pathspec>…` — *(core)* Paths to restore.  `[log]`
- [x] `-s <tree>` / `--source=<tree>` — Restore from a tree rather than the index.
- [x] `-W` / `--worktree` — Restore into the working tree (the default).
- [x] `-S` / `--staged` — Restore into the index.  `[log]`
- [ ] `-p` / `--patch` — Interactively choose hunks to restore.
- [x] `--ours` / `--theirs` — For unmerged paths, restore stage 2 or stage 3.
- [ ] `-m` / `--merge` — Recreate the conflicted merge in unmerged paths.
- [ ] `--conflict=<style>` — As `--merge`, choosing the conflict marker style.
- [ ] `--ignore-unmerged` — Do not abort when unmerged entries are present.
- [ ] `--ignore-skip-worktree-bits` — Ignore sparse-checkout restrictions.
- [ ] `--overlay` / `--no-overlay` — In no-overlay mode, delete paths absent from the source.
- [ ] `--recurse-submodules` / `--no-recurse-submodules` — Also restore submodule working trees.
- [x] `-q` / `--quiet` — Suppress feedback messages.
- [ ] `--progress` / `--no-progress` — Force progress reporting on or off.
- [ ] `--pathspec-from-file=<file>` — Read the pathspec from a file or stdin.
- [ ] `--pathspec-file-nul` — Treat that file as NUL-separated and literal.
- [x] `--` — End option parsing.
- [ ] *diff-context options* — `-U<n>`, `--inter-hunk-context` for `--patch` mode.

## `revert` — undo commits with new commits

- [x] `<commit>…` — *(core)* The commits to revert.
- [x] `-e` / `--edit` — Edit the revert commit message (the default when interactive).
- [x] `--no-edit` — Do not open the message editor.
- [ ] `--cleanup=<mode>` — Choose how the message is cleaned up.
- [ ] `-m <parent-number>` / `--mainline <parent-number>` — Revert a merge relative to the given parent.
- [x] `-n` / `--no-commit` — Apply the reversal to index and working tree without committing.
- [x] `-s` / `--signoff` — Add a `Signed-off-by` trailer.
- [ ] `-S[<keyid>]` / `--gpg-sign[=<keyid>]` / `--no-gpg-sign` — Sign the created commits.
- [ ] `--strategy=<strategy>` — Choose the merge strategy used to apply the reversal.
- [ ] `-X<option>` / `--strategy-option=<option>` — Pass an option to the merge strategy.
- [ ] `--reference` — Refer to the reverted commit in `reference` format rather than by full object name.
- [ ] *sequencer options* — `--continue`, `--skip`, `--quit`, `--abort`.
- [ ] *rerere options* — `--rerere-autoupdate` / `--no-rerere-autoupdate`.

## `rm` — remove tracked files

- [x] `<pathspec>…` — *(core)* Files to remove.  `[log]`
- [x] `-f` / `--force` — Remove even when the file differs from HEAD or the index.
- [x] `-n` / `--dry-run` — Report what would be removed without removing it.
- [x] `-r` — Recurse into directories.
- [x] `--cached` — *(core)* Remove from the index only, leaving the working-tree file.  `[log]`
- [ ] `--ignore-unmatch` — Exit zero even if no path matched.
- [ ] `--sparse` — Allow removing entries outside the sparse-checkout cone.
- [x] `-q` / `--quiet` — Suppress the per-file removal report.  `[log]`
- [ ] `--pathspec-from-file=<file>` — Read the pathspec from a file or stdin.
- [ ] `--pathspec-file-nul` — Treat that file as NUL-separated and literal.
- [x] `--` — End option parsing.

## `shortlog` — summarize history by author

> **CUT from v1** — thin, but it is `log` plus grouping and nothing depends on it. v2 if missed.

- [ ] `<revision-range>` — Range of commits to summarize.
- [ ] `[--] <path>…` — Restrict to commits touching these paths.
- [ ] `-n` / `--numbered` — Sort authors by commit count rather than alphabetically.
- [ ] `-s` / `--summary` — Print only counts, not commit subjects.
- [ ] `-e` / `--email` — Include each author's email address.
- [ ] `--format[=<format>]` — Describe each commit with a custom format instead of its subject.
- [ ] `--date=<format>` — Choose the date rendering used by the format string.
- [ ] `--group=<type>` — Group by `author`, `committer`, `trailer:<token>`, or `format:<string>`; repeatable.
- [ ] `-c` / `--committer` — Alias for `--group=committer`.
- [ ] `-w[<width>[,<indent1>[,<indent2>]]]` — Wrap output at a given width with the given indents.
- [ ] *rev-list options* — see `04`.

## `show` — display objects

- [x] `<object>…` — *(core)* Objects to display; defaults to HEAD.  `[log]`
- [ ] *pretty options*, *pretty formats*, *diff options* — see `03` and `04`.

`show` is `log -1` for commits, plus type-specific rendering for tags, trees,
and blobs.

## `sparse-checkout` — restrict the working tree to a subset of paths

> **CUT from v1** — requires skip-worktree handling throughout the index and checkout paths.

Subcommands: `list`, `set`, `add`, `reapply`, `clean`, `disable`, `init`
(deprecated), `check-rules`.

- [ ] `list` — Print the current sparse-checkout patterns.
- [ ] `set` — Replace the pattern set and update the working tree.
- [ ] `add` — Add directories or patterns to the existing set.
- [ ] `reapply` — Re-evaluate the patterns against the working tree.
- [ ] `clean` — Remove files that fall outside the current sparse definition.
- [ ] `disable` — Turn sparse checkout off and restore the full working tree.
- [ ] `init` — Deprecated; equivalent to `set` with no paths.
- [ ] `check-rules` — Test whether given paths match the sparsity rules.
- [ ] `--cone` / `--no-cone` — Use directory-prefix (cone) matching rather than full gitignore-style patterns.
- [ ] `--sparse-index` / `--no-sparse-index` — Enable the sparse index format.
- [ ] `--stdin` — Read the pattern or path list from standard input.

## `stash` — set aside dirty working-tree state

Subcommands: `push` (default), `save` (deprecated), `list`, `show`, `pop`,
`apply`, `branch`, `clear`, `drop`, `create`, `store`, `export`, `import`.

- [x] `push` — *(core)* Save working tree and index state and reset to HEAD.  `[log]`
- [ ] `save` — Older positional-message form of `push`.
- [x] `list [<log-options>]` — List existing stash entries.  `[log]`
- [x] `show [<diff-options>] [<stash>]` — Show a stash entry as a diff.
- [x] `pop [<stash>]` — *(core)* Apply a stash entry and drop it.  `[log]`
- [x] `apply [<stash>]` — Apply a stash entry without dropping it.
- [ ] `branch <branchname> [<stash>]` — Create a branch from the stash's base commit and apply the entry there.
- [x] `clear` — Delete every stash entry.
- [x] `drop [<stash>]` — Delete one stash entry.
- [ ] `create` — Build a stash commit and print its object name without storing a ref.
- [ ] `store` — Record a previously created stash commit in the stash ref.
- [ ] `export (--print | --to-ref <ref>)` — Export stash entries as a chain of commits.
- [ ] `import <commit>` — Import stash entries from a chain produced by `export`.
- [x] `<stash>` — Which entry to act on, e.g. `stash@{2}`.
- [ ] `-p` / `--patch` — Choose hunks to stash interactively.
- [ ] `-S` / `--staged` — Stash only the staged changes.
- [x] `-k` / `--keep-index` / `--no-keep-index` — Leave the index intact after stashing.  `[log]`
- [x] `-u` / `--include-untracked` / `--no-include-untracked` — Also stash untracked files.  `[log]`
- [ ] `-a` / `--all` — Also stash ignored files.
- [ ] `--only-untracked` — With `show`, display only the untracked part.
- [ ] `--index` — With `pop`/`apply`, restore the index state as well.
- [ ] `--label-ours=<label>` / `--label-theirs=<label>` / `--label-base=<label>` — Customize conflict marker labels when applying.
- [x] `-m <message>` / `--message <message>` — Give the stash entry a message.  `[log]`
- [ ] `--print` / `--to-ref <ref>` — Destination for `export`.
- [x] `-q` / `--quiet` — Operate quietly.  `[log]`
- [ ] `--pathspec-from-file=<file>` / `--pathspec-file-nul` — Read the pathspec for `push` from a file.
- [x] `--` / `<pathspec>…` — Restrict `push` to given paths.  `[log]`
- [ ] *diff-context options* — `-U<n>`, `--inter-hunk-context` for `--patch` mode.

## `status` — report working tree state

- [x] `<pathspec>…` — Restrict the report to matching paths.
- [x] `-s` / `--short` — *(core)* Use the two-column short format.  `[log]`
- [x] `--long` — Use the descriptive long format (the default).
- [x] `--porcelain[=<version>]` — *(core)* Use the stable machine-readable format (v1 or v2).  `[log]`
- [x] `-b` / `--branch` — Include branch and upstream information in short format.  `[log]`
- [ ] `--show-stash` — Report how many stash entries exist.
- [ ] `-v` / `--verbose` — Also show the staged diff (twice: the unstaged diff too).
- [x] `-u[<mode>]` / `--untracked-files[=<mode>]` — *(core)* Control untracked reporting: `no`, `normal`, `all`.  `[log]`
- [x] `--color[=<when>]` / `--no-color` — Colorize the long format: staged green, unmerged/unstaged/untracked red.  Machine formats are never colored.
- [ ] `--ignored[=<mode>]` — Also report ignored files (`traditional`, `matching`, `no`).
  Cutting this removes only the ability to *display* ignored files; `status` still
  applies ignore rules to suppress them from untracked output.
- [ ] `--ignore-submodules[=<when>]` — Ignore some or all submodule changes.
- [x] `-z` — NUL-terminate entries and imply porcelain v1.
- [ ] `--column[=<options>]` / `--no-column` — Print untracked files in columns.
- [ ] `--ahead-behind` / `--no-ahead-behind` — Compute or skip ahead/behind counts against the upstream.
- [ ] `--renames` / `--no-renames` — Force rename detection on or off.
- [ ] `--find-renames[=<n>]` — Enable rename detection with a similarity threshold.

## `submodule` — manage nested repositories

> **CUT from v1** — a whole second repository model; upstream implements it as a shell script for good reason.

Subcommands: `add`, `status`, `init`, `deinit`, `update`, `set-branch`,
`set-url`, `summary`, `foreach`, `sync`, `absorbgitdirs`.

- [ ] `add <repository> [<path>]` — Clone a repository and register it as a submodule.
- [ ] `status [<path>…]` — Report each submodule's recorded and checked-out commit.  `[log]`
- [ ] `init [<path>…]` — Copy submodule URLs from `.gitmodules` into the local config.
- [ ] `deinit (--all | <path>…)` — Unregister submodules and remove their working trees.
- [ ] `update [<path>…]` — Clone, fetch, and check out submodules to the recorded commits.
- [ ] `set-branch (-b <branch> | -d) <path>` — Set or clear a submodule's tracked branch.
- [ ] `set-url <path> <newurl>` — Change a submodule's URL in `.gitmodules`.
- [ ] `summary [<commit>] [<path>…]` — Summarize commits between recorded and current submodule states.
- [ ] `foreach [--recursive] <command>` — Run a shell command in each checked-out submodule.
- [ ] `sync [<path>…]` — Copy `.gitmodules` URLs into the submodules' remote configuration.
- [ ] `absorbgitdirs` — Move submodule git directories into the superproject's `.git/modules`.
- [ ] `-q` / `--quiet` — Print only errors.
- [ ] `--progress` — Force progress reporting.
- [ ] `--all` — With `deinit`, act on every submodule.
- [ ] `-b<branch>` / `--branch=<branch>` — Branch to record when adding or setting.
- [ ] `-f` / `--force` — Proceed despite conditions that would normally abort.
- [ ] `--cached` — Use the index rather than HEAD for `status` and `summary`.
- [ ] `--files` — Compare the index against the submodule's HEAD in `summary`.
- [ ] `-n<n>` / `--summary-limit=<n>` — Cap the number of commits shown by `summary`.
- [ ] `--remote` — Update to the submodule's remote-tracking branch instead of the recorded commit.
- [ ] `-N` / `--no-fetch` — Do not fetch during `update`.
- [ ] `--checkout` — Update by detaching at the recorded commit (the default).
- [ ] `--merge` — Update by merging the recorded commit into the submodule's branch.
- [ ] `--rebase` — Update by rebasing the submodule's branch onto the recorded commit.
- [ ] `--init` — Run `init` for uninitialized submodules before updating.
- [ ] `--name=<name>` — Set the submodule's config name when adding.
- [ ] `--reference=<repository>` — Borrow objects from a local repository when cloning.
- [ ] `--dissociate` — Copy borrowed objects and drop the alternates entry.
- [ ] `--recursive` — Recurse into nested submodules.
- [ ] `--depth=<depth>` — Shallow-clone submodules to a given depth.
- [ ] `--recommend-shallow` / `--no-recommend-shallow` — Honor or ignore the `.gitmodules` shallow recommendation.
- [ ] `--single-branch` / `--no-single-branch` — Clone only one branch during update.
- [ ] `-j<n>` / `--jobs=<n>` — Clone submodules in parallel.
- [ ] `--ref-format <format>` — Ref backend for newly cloned submodules.
- [ ] `<path>…` — Restrict the operation to given submodule paths.

## `switch` — change branches

- [x] `<branch>` — *(core)* Branch to switch to.
- [x] `<new-branch>` / `<start-point>` — New branch to create and where to start it.
- [x] `-c <new-branch>` / `--create <new-branch>` — *(core)* Create a branch and switch to it.
- [x] `-C <new-branch>` / `--force-create <new-branch>` — As `-c`, resetting the branch if it exists.
- [x] `-d` / `--detach` — Switch to a commit with HEAD detached.
- [ ] `--orphan <new-branch>` — Start an unborn branch with an empty working tree.
- [ ] `--guess` / `--no-guess` — Create a local branch from a uniquely matching remote-tracking branch.
- [x] `-f` / `--force` / `--discard-changes` — Discard local modifications while switching.
- [ ] `-m` / `--merge` — Carry local modifications across the switch by merging.
- [ ] `--conflict=<style>` — As `--merge`, choosing the conflict marker style.
- [x] `-t` / `--track[=(direct|inherit)]` — Set up upstream tracking for the new branch.
- [x] `--no-track` — Create the branch without upstream tracking.
- [ ] `--ignore-other-worktrees` — Switch to a ref already checked out in another worktree.
- [ ] `--recurse-submodules` / `--no-recurse-submodules` — Update submodule working trees on switch.
- [x] `-q` / `--quiet` — Suppress feedback messages.
- [ ] `--progress` / `--no-progress` — Force progress reporting on or off.

## `tag` — create, list, delete, and verify tags

- [x] `<tagname>` — *(core)* Name of the tag to create, delete, or describe.
- [x] `<commit>` / `<object>` — Object the new tag refers to; defaults to HEAD.
- [x] `-a` / `--annotate` — *(core)* Create an annotated tag object rather than a lightweight ref.
- [ ] `-s` / `--sign` — Create a signed tag using the default key.
- [ ] `--no-sign` — Override a configuration that forces signing.
- [ ] `-u <key-id>` / `--local-user=<key-id>` — Sign with a specific key.
- [x] `-f` / `--force` — Replace an existing tag of the same name.
- [x] `-d` / `--delete` — *(core)* Delete the named tags.
- [ ] `-v` / `--verify` — Verify the tags' signatures.
- [x] `-l` / `--list` — *(core)* List tags, optionally filtered by pattern.  `[log]`
- [x] `-n<num>` — Print `<num>` lines of each tag's annotation when listing.
- [x] `-m <msg>` / `--message=<msg>` — Supply the tag message; implies `-a`.
- [x] `-F <file>` / `--file=<file>` — Read the tag message from a file or stdin.
- [ ] `-e` / `--edit` — Edit the supplied message in an editor.
- [ ] `--cleanup=<mode>` — Clean up the tag message (`verbatim`, `whitespace`, `strip`).
- [ ] `--trailer <token>[(=|:)<value>]` — Add a trailer to the tag message.
- [ ] `--create-reflog` — Create a reflog for the tag ref.
- [x] `--sort=<key>` — Sort the listing by a ref field.
- [x] `--format=<format>` — Format each listed tag with `%(fieldname)` placeholders.
- [ ] `--color[=<when>]` — Honor color directives in the format.
- [ ] `-i` / `--ignore-case` — Sort and filter case-insensitively.
- [ ] `--omit-empty` — Suppress newlines for formats that expand to nothing.
- [ ] `--column[=<options>]` / `--no-column` — Print the listing in columns.
- [x] `--contains [<commit>]` / `--no-contains [<commit>]` — Filter by whether the tag's commit contains a commit.
- [x] `--merged [<commit>]` / `--no-merged [<commit>]` — Filter by reachability from a commit.
- [x] `--points-at [<object>]` — List only tags pointing at an object.

## `worktree` — manage additional working trees

Subcommands: `add`, `list`, `lock`, `move`, `prune`, `remove`, `repair`,
`unlock`.

- [x] `add <path> [<commit-ish>]` — Create a linked working tree at a path.  `[log]`
- [x] `list` — List the main and linked working trees.  `[log]`
- [ ] `lock` — Mark a worktree locked so it is not pruned.
- [ ] `unlock` — Remove a worktree's lock.
- [x] `move` — Relocate a linked worktree.  `[log]`
- [x] `prune` — Clean up administrative files for worktrees whose directories are gone.  `[log]`
- [x] `remove` — Delete a clean linked worktree and its administrative files.  `[log]`
- [ ] `repair [<path>…]` — Fix administrative files broken by external moves.
- [x] `<worktree>` — Identify a worktree by path.  `[log]`
- [x] `-f` / `--force` — Proceed despite an already-checked-out branch or a dirty worktree.  `[log]`
- [x] `-b <new-branch>` / `-B <new-branch>` — Create (or reset) a branch for the new worktree.  `[log]`
- [x] `-d` / `--detach` — Create the worktree with HEAD detached.  `[log]`
- [ ] `--checkout` / `--no-checkout` — Populate or leave empty the new worktree.
- [ ] `--orphan` — Create the worktree on a new unborn branch with an empty index.
- [ ] `--guess-remote` / `--no-guess-remote` — Base a new worktree on a matching remote-tracking branch.
- [ ] `--track` / `--no-track` — Set up upstream tracking for a newly created branch.
- [ ] `--relative-paths` / `--no-relative-paths` — Link worktrees using relative rather than absolute paths.
- [ ] `--lock` — Create the worktree already locked.
- [ ] `--reason <string>` — Record why a worktree is locked.
- [ ] `-n` / `--dry-run` — With `prune`, report without removing.
- [ ] `--expire <time>` — With `prune`, only remove entries older than a time.
- [ ] `--porcelain` — With `list`, emit stable machine-readable output.
- [ ] `-z` — NUL-terminate porcelain `list` records.
- [x] `-q` / `--quiet` — Suppress feedback from `add`.  `[log]`
- [ ] `-v` / `--verbose` — Report every removal from `prune`.

---

## `gitk` — Tcl/Tk history browser

> **CUT from v1** — Tcl/Tk GUI.

Accepts most `rev-list`/`log` arguments; documented options of its own:

- [ ] `--all`, `--branches[=<pattern>]`, `--tags[=<pattern>]`, `--remotes[=<pattern>]` — Which refs to show.
- [ ] `--since=<date>` / `--until=<date>` — Date limits.
- [ ] `--date-order` — Sort commits by date where possible.
- [ ] `--merge` — Show the commits involved in the current conflicted merge.
- [ ] `--left-right` — Mark which side of a symmetric difference each commit comes from.
- [ ] `--full-history` / `--simplify-merges` / `--ancestry-path` — History simplification controls.
- [ ] `-L<start>,<end>:<file>` — Trace a line range.
- [ ] `<revision range>` / `<path>…` — What to show.
- [ ] `--argscmd=<command>` — Run a command to compute the revision range on each refresh.
- [ ] `--select-commit=<ref>` — Select a commit once the graph has loaded.

Out of scope for a CLI-only gittle; listed for completeness.

## `scalar` — large-repository wrapper

> **CUT from v1** — large-repo wrapper built on partial clone and sparse checkout, both cut.

Subcommands: `clone`, `list`, `register`, `unregister`, `run`, `reconfigure`,
`diagnose`, `delete`.

- [ ] `clone <url> [<enlistment>]` — Clone with partial clone, sparse checkout, and maintenance preconfigured.
- [ ] `list` — List registered enlistments.
- [ ] `register [<enlistment>]` — Register a repository for background maintenance.
- [ ] `unregister [<enlistment>]` — Stop maintaining a repository.
- [ ] `run (all|config|commit-graph|fetch|loose-objects|pack-files)` — Run one maintenance task.
- [ ] `reconfigure` — Reapply Scalar's recommended configuration.
- [ ] `diagnose [<enlistment>]` — Collect diagnostic information.
- [ ] `delete <enlistment>` — Unregister and delete an enlistment.
- [ ] `-b <name>` / `--branch <name>` — Branch to check out when cloning.
- [ ] `--single-branch` / `--no-single-branch` — Limit the clone to one branch's history.
- [ ] `--src` / `--no-src` — Place the repository in an `src/` subdirectory or directly in the enlistment.
- [ ] `--tags` / `--no-tags` — Fetch tags during clone and subsequent fetches.
- [ ] `--full-clone` / `--no-full-clone` — Skip the default sparse-checkout setup.
- [ ] `--maintenance` / `--no-maintenance` — Enable or skip background maintenance registration.
- [ ] `--all` — With `reconfigure`, act on every registered enlistment.
- [ ] `--maintenance=(enable|disable|keep)` — Control maintenance during `reconfigure`.
