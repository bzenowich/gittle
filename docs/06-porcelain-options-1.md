# 06 — Main porcelain options, part 1 (`add` … `commit`)

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


Shared option groups are referenced, not repeated; see `03`–`05`.

---

## `add` — stage content into the index

- [x] `<pathspec>…` — *(core)* Paths, globs, or directories whose content to stage.  `[log]`
- [x] `-n` / `--dry-run` — Report what would be staged without changing the index.
- [x] `-v` / `--verbose` — List each path as it is staged.
- [x] `-f` / `--force` — Stage files that ignore rules would otherwise exclude.
- [ ] `--sparse` — Allow staging paths outside the sparse-checkout cone.
- [ ] `-i` / `--interactive` — Enter the interactive staging menu.
- [ ] `-p` / `--patch` — Interactively choose hunks to stage.
- [ ] `-e` / `--edit` — Open the diff against the index in an editor and stage the edited result.
- [x] `-u` / `--update` — *(core)* Stage modifications and deletions of already-tracked paths only.  `[log]`
- [x] `-A` / `--all` / `--no-ignore-removal` — *(core)* Stage additions, modifications, and deletions.  `[log]`
- [ ] `--no-all` / `--ignore-removal` — Stage additions and modifications but not deletions.
- [ ] `-N` / `--intent-to-add` — Record that a path will be added later, without staging its content.
- [ ] `--refresh` — Only refresh stat information in the index; stage nothing.
- [ ] `--ignore-errors` — Continue past files that cannot be indexed.
- [ ] `--ignore-missing` — With `--dry-run`, report on paths that do not exist.
- [ ] `--no-warn-embedded-repo` — Suppress the warning when adding a nested repository as a gitlink.
- [ ] `--renormalize` — Re-run the clean filter on all tracked files and restage them.
- [ ] `--resolved` — Stage unmerged paths that no longer contain conflict markers.
- [ ] `--chmod=(+|-)x` — Force the executable bit of the staged entries.
- [ ] `--pathspec-from-file=<file>` — Read the pathspec from a file (or stdin) instead of the argument list.
- [ ] `--pathspec-file-nul` — Treat the pathspec file as NUL-separated and literal.
- [x] `--` — End option parsing so remaining arguments are paths.
- [ ] *diff-context options* — `-U<n>`, `--inter-hunk-context` for `--patch` mode.

## `am` — apply a mailbox of patches

> **CUT from v1** — needs the mailbox parser plus `apply`'s 3-way fallback — ~5.3k lines of C in git. Top candidate for v2.

- [ ] `(<mbox>|<Maildir>)…` — Mailboxes to read patches from; defaults to stdin.
- [ ] `-s` / `--signoff` — Add a `Signed-off-by` trailer to each created commit.
- [ ] `-k` / `--keep` — Keep the subject line verbatim, without stripping `[PATCH]`.
- [ ] `--keep-non-patch` — Strip only `[PATCH]`, keeping other bracketed prefixes.
- [ ] `--keep-cr` / `--no-keep-cr` — Keep or strip a CR at the end of mail body lines.
- [ ] `-c` / `--scissors` — Discard everything before a scissors (`>8`) line.
- [ ] `--no-scissors` — Ignore scissors lines.
- [ ] `--quoted-cr=<action>` — Choose how quoted-printable CRLF endings are handled.
- [ ] `-m` / `--message-id` — Append the mail's `Message-ID` to the commit message.
- [ ] `--no-message-id` — Do not append the `Message-ID`.
- [ ] `-u` / `--utf8` — Re-encode the commit message to UTF-8 (the default).
- [ ] `--no-utf8` — Leave the commit message in its original encoding.
- [ ] `-q` / `--quiet` — Print only errors.
- [ ] `-3` / `--3way` / `--no-3way` — Fall back to a three-way merge when the patch does not apply cleanly.
- [ ] `--patch-format` — Force the patch format instead of auto-detecting (`mbox`, `stgit`, `hg`, …).
- [ ] `-i` / `--interactive` — Confirm each patch before applying it.
- [ ] `--verify` / `-n` / `--no-verify` — Run or skip the `pre-applypatch` and `applypatch-msg` hooks.
- [ ] `--committer-date-is-author-date` — Use the author date as the committer date.
- [ ] `--ignore-date` — Use the current time as the author date instead of the mail date.
- [ ] `--empty=(drop|keep|stop)` — How to treat a mail with no patch in it.
- [ ] `--allow-empty` — Turn the current patchless message into an empty commit.
- [ ] `-S[<key-id>]` / `--gpg-sign[=<key-id>]` / `--no-gpg-sign` — Sign the created commits.
- [ ] `--continue` / `-r` / `--resolved` — *(core)* Resume after the user resolved a failed patch by hand.
- [ ] `--skip` — Skip the current patch and continue.
- [ ] `--abort` — Restore the original branch and abandon the whole operation.
- [ ] `--quit` — Abandon the operation but leave HEAD and the index as they are.
- [ ] `--retry` — Retry applying the last conflicting patch.
- [ ] `--show-current-patch[=(diff|raw)]` — Print the patch that `am` stopped on.
- [ ] `--resolvemsg=<msg>` — Override the message printed when a patch fails.
- [ ] *`apply` pass-through options* — `--ignore-space-change`, `--ignore-whitespace`, `--whitespace=<action>`, `-C<n>`, `-p<n>`, `--directory=<dir>`, `--exclude=<pattern>`, `--include=<pattern>`, `--reject`.
- [ ] *rerere options* — `--rerere-autoupdate` / `--no-rerere-autoupdate`.

## `archive` — export a tree as a tar or zip archive

> **CUT from v1** — requires a tar and zip writer for a workflow better served by the system `tar`.

- [ ] `<tree-ish>` — The tree or commit to archive.
- [ ] `<path>` — Restrict the archive to the given paths.
- [ ] `--format=<fmt>` — Choose the archive format (`tar`, `zip`, `tar.gz`, `tgz`, or a configured one).
- [ ] `-l` / `--list` — List the available archive formats.
- [ ] `-v` / `--verbose` — Report progress on stderr.
- [ ] `--prefix=<prefix>/` — Prepend a directory prefix to every archived path.
- [ ] `-o <file>` / `--output=<file>` — Write to a file instead of stdout.
- [ ] `--add-file=<file>` — Add an untracked file to the archive; repeatable.
- [ ] `--add-virtual-file=<path>:<content>` — Add a file with inline content to the archive.
- [ ] `--worktree-attributes` — Also honor `.gitattributes` found in the working tree.
- [ ] `--mtime=<time>` — Set the modification time recorded for archive entries.
- [ ] `--remote=<repo>` — Ask a remote repository to produce the archive.
- [ ] `--exec=<git-upload-archive>` — Override the remote helper path used with `--remote`.
- [ ] `-<digit>` / `-<number>` — Backend compression level passed to the tar or zip writer.
- [ ] `<extra>` — Any further options understood by the selected archiver backend.

## `backfill` — download objects omitted by a partial clone

> **CUT from v1** — partial clone is out of scope.

- [ ] `<revision-range>` — Backfill only blobs reachable from the given range.
- [ ] `--min-batch-size=<n>` — Minimum number of missing objects to request per round trip.
- [ ] `--sparse` / `--no-sparse` — Restrict backfill to paths inside the sparse-checkout.
- [ ] `--include-edges` / `--no-include-edges` — Also fetch blobs from boundary commits.

## `bisect` — binary-search history for a change in behavior

> **CUT from v1** — cheap to add later (`rev-list --bisect` plus a state file), but unused by agents and only occasional for humans. Deferred to v2.

Subcommands: `start`, `bad`/`new`, `good`/`old`, `terms`, `skip`, `reset`,
`visualize`/`view`, `replay`, `log`, `run`, `help`.

- [ ] `--no-checkout` — Update `BISECT_HEAD` instead of checking out each candidate.
- [ ] `--first-parent` — Bisect only along first-parent history.
- [ ] `--reset-when-found[=<where>]` — Clean up bisection state automatically once the first bad commit is identified.

## `branch` — list, create, rename, and delete branches

- [x] `<branch-name>` — Name of the branch to create or delete.  `[log]`
- [x] `<start-point>` — Commit the new branch should point at (defaults to HEAD).  `[log]`
- [x] `<old-branch>` / `<new-branch>` — Source and destination names for a rename or copy.  `[log]`
- [x] `-d` / `--delete` — *(core)* Delete a branch, refusing if it is not merged.  `[log]`
- [x] `-D` — Shorthand for `--delete --force`.
- [x] `-f` / `--force` — Overwrite an existing branch or force an unsafe delete.  `[log]`
- [x] `-m` / `--move` — Rename a branch along with its config and reflog.  `[log]`
- [x] `-M` — Shorthand for `--move --force`.
- [ ] `-c` / `--copy` — Copy a branch along with its config and reflog.
- [ ] `-C` — Shorthand for `--copy --force`.
- [ ] `--create-reflog` — Create a reflog for the branch even when reflogs are off.
- [x] `-l` / `--list` — *(core)* List branches, optionally filtered by pattern.  `[log]`
- [x] `-r` / `--remotes` — Act on remote-tracking branches instead of local ones.  `[log]`
- [x] `-a` / `--all` — List both local and remote-tracking branches.  `[log]`
- [x] `--show-current` — Print just the name of the current branch.  `[log]`
- [x] `-v` / `-vv` / `--verbose` — Include object ID, subject, and upstream relationship in listings.  `[log]`
- [x] `-q` / `--quiet` — Suppress non-error messages when creating or deleting.
- [ ] `--abbrev=<n>` — Set the abbreviation length for object names in listings.
- [ ] `--no-abbrev` — Print full object names in listings.
- [ ] `--color[=<when>]` — Colorize the branch listing.
- [ ] `--no-color` — Disable coloring of the listing.
- [ ] `-i` / `--ignore-case` — Sort and filter case-insensitively.
- [ ] `--omit-empty` — Suppress the newline for formats that expand to nothing.
- [ ] `--column[=<options>]` / `--no-column` — Display the listing in columns.
- [x] `--sort=<key>` — Sort the listing by a ref field; repeatable.  `[log]`
- [x] `--format <format>` — Format each listed branch with `%(fieldname)` placeholders.
- [x] `-t` / `--track[=(direct|inherit)]` — Set up upstream tracking for a new branch.
- [x] `--no-track` — Create the branch without upstream tracking.
- [x] `-u <upstream>` / `--set-upstream-to=<upstream>` — Set the upstream of an existing branch.
- [x] `--unset-upstream` — Remove upstream tracking information.
- [ ] `--set-upstream` — Removed; kept only to produce an error pointing at `--track`.
- [ ] `--edit-description` — Edit the branch's long description in an editor.
- [x] `--contains [<commit>]` — List only branches containing a commit.  `[log]`
- [x] `--no-contains [<commit>]` — List only branches not containing a commit.
- [x] `--merged [<commit>]` — List only branches reachable from a commit.
- [x] `--no-merged [<commit>]` — List only branches not reachable from a commit.
- [ ] `--forked <branch>` — List only branches whose configured upstream matches a branch.
- [ ] `--points-at <object>` — List only branches pointing directly at an object.
- [ ] `--delete-merged <pattern>` — Bulk-delete local branches whose upstream matches a pattern and whose tips are merged.
- [ ] `--dry-run` — With `--delete-merged`, report which branches would be deleted.
- [ ] `--recurse-submodules` — Experimental: propagate branch creation into submodules.

## `bundle` — package objects and refs into a transportable file

> **CUT from v1** — offline transport; rare enough to defer.

Subcommands: `create`, `verify`, `list-heads`, `unbundle`.

- [ ] `create <file> <rev-list-args>` — Write a bundle containing the objects and refs the rev-list arguments select.
- [ ] `verify <file>` — Check that a bundle is well formed and applies to this repository.
- [ ] `list-heads <file>` — List the refs a bundle defines.
- [ ] `unbundle <file>` — Feed a bundle's objects into the repository and print its refs.
- [ ] `<rev-list-args>` — Revision arguments selecting what goes into the bundle.
- [ ] `[<refname>…]` — Restrict which of the bundle's refs are reported.
- [ ] `--version=<version>` — Choose the bundle format version (2 for SHA-1 only, 3 for capabilities such as SHA-256).
- [ ] `--progress` — Force progress reporting on stderr.
- [ ] `-q` / `--quiet` — Suppress progress reporting.

## `checkout` — switch branches and/or restore paths

- [x] `<branch>` — Branch to switch to, or commit to detach at.  `[log]`
- [x] `<new-branch>` / `<start-point>` / `<tree-ish>` — Branch to create, its starting commit, and the tree to restore paths from.  `[log]`
- [x] `<pathspec>…` — Restore only these paths instead of switching branches.  `[log]`
- [x] `-b <new-branch>` — *(core)* Create a branch at `<start-point>` and switch to it.  `[log]`
- [x] `-B <new-branch>` — As `-b`, resetting the branch if it already exists.  `[log]`
- [x] `-d` / `--detach` — Check out a commit directly, leaving HEAD detached.
- [ ] `--orphan <new-branch>` — Start a new branch with no history.
- [x] `-f` / `--force` — Discard local modifications and unmerged entries while switching.  `[log]`
- [x] `-q` / `--quiet` — Suppress feedback messages.  `[log]`
- [ ] `--progress` / `--no-progress` — Force progress reporting on or off.
- [x] `--ours` / `--theirs` — When restoring unmerged paths, take stage 2 or stage 3.  `[log]`
- [ ] `-m` / `--merge` — Carry local modifications across the switch by merging them.
- [ ] `--conflict=<style>` — Choose the conflict marker style (`merge`, `diff3`, `zdiff3`) when merging.
- [ ] `-p` / `--patch` — Interactively select hunks to restore.
- [x] `-t` / `--track[=(direct|inherit)]` — Set up upstream tracking for a newly created branch.
- [x] `--no-track` — Create the new branch without upstream tracking.
- [ ] `--guess` / `--no-guess` — Create a local branch from a uniquely matching remote-tracking branch.
- [ ] `-l` — Create a reflog for the new branch.
- [ ] `--ignore-skip-worktree-bits` — Ignore sparse-checkout when restoring paths.
- [ ] `--ignore-other-worktrees` — Check out a branch already checked out in another worktree.
- [ ] `--overwrite-ignore` / `--no-overwrite-ignore` — Control whether ignored files may be overwritten while switching.
- [ ] `--recurse-submodules` / `--no-recurse-submodules` — Update submodule working trees to match the new commit.
- [ ] `--overlay` / `--no-overlay` — In no-overlay mode, remove paths absent from the source tree.
- [ ] `--pathspec-from-file=<file>` — Read the pathspec from a file or stdin.
- [ ] `--pathspec-file-nul` — Treat that file as NUL-separated and literal.
- [x] `--` — End option parsing.  `[log]`
- [ ] *diff-context options* — `-U<n>`, `--inter-hunk-context` for `--patch` mode.

## `cherry-pick` — replay existing commits onto the current branch

- [x] `<commit>…` — *(core)* The commits (or ranges) to replay.  `[log]`
- [x] `-e` / `--edit` — Edit the commit message before committing.
- [ ] `--cleanup=<mode>` — Choose how the message is cleaned up before committing.
- [x] `-x` — Append a `(cherry picked from commit …)` line to the message.  `[log]`
- [ ] `-r` — Obsolete no-op; `-x` is no longer the default.
- [ ] `-m <parent-number>` / `--mainline <parent-number>` — Pick a merge commit relative to the given parent.
- [x] `-n` / `--no-commit` — Apply the changes to the index and working tree without committing.
- [x] `-s` / `--signoff` — Add a `Signed-off-by` trailer.
- [ ] `-S[<keyid>]` / `--gpg-sign[=<keyid>]` / `--no-gpg-sign` — Sign the created commits.
- [ ] `--ff` — Fast-forward instead of creating a new commit when possible.
- [ ] `--allow-empty` — Permit picking a commit whose diff is empty.
- [ ] `--allow-empty-message` — Permit picking a commit with an empty message.
- [ ] `--empty=(drop|keep|stop)` — How to handle picks that become redundant.
- [ ] `--keep-redundant-commits` — Deprecated synonym for `--empty=keep`.
- [ ] `--strategy=<strategy>` — Select the merge strategy used to apply each commit.
- [ ] `-X<option>` / `--strategy-option=<option>` — Pass an option to the merge strategy.
- [ ] *sequencer options* — `--continue`, `--skip`, `--quit`, `--abort`.
- [ ] *rerere options* — `--rerere-autoupdate` / `--no-rerere-autoupdate`.

## `citool` — Tcl/Tk commit tool

> **CUT from v1** — Tcl/Tk GUI — impossible in a single static binary.

No options of its own; it is `git gui citool`. Out of scope for a CLI-only
gittle.

## `clean` — delete untracked files

- [x] `<pathspec>…` — Limit cleaning to the given paths.
- [x] `-d` — *(core)* Recurse into untracked directories.
- [x] `-f` / `--force` — Actually delete (required unless `clean.requireForce` is false).
- [ ] `-i` / `--interactive` — Choose interactively what to delete (menu: `clean`, `filter by pattern`, `select by numbers`, `ask each`, `quit`, `help`).
- [x] `-n` / `--dry-run` — Report what would be deleted without deleting it.
- [x] `-q` / `--quiet` — Report only errors.
- [x] `-e <pattern>` / `--exclude=<pattern>` — Add an extra exclude pattern; repeatable.
- [x] `-x` — Also delete files ignored by the standard ignore rules.
- [x] `-X` — Delete *only* ignored files.

## `clone` — create a new repository from an existing one

- [x] `<repository>` — *(core)* URL or path of the source repository.  `[log]`
- [x] `<directory>` — Directory to create; defaults to the repository's basename.  `[log]`
- [x] `-o<name>` / `--origin=<name>` — Name the remote something other than `origin`.
- [x] `-b<name>` / `--branch=<name>` — Check out a specific branch (or tag) instead of the remote's HEAD.
- [ ] `--revision=<rev>` — Fetch only the history leading to one revision, leaving HEAD detached.
- [x] `-n` / `--no-checkout` — Do not check out a working tree after cloning.
- [x] `--bare` — Create a bare repository with no working tree.
- [ ] `--mirror` — Create a bare mirror that maps all remote refs one-to-one.
- [ ] `--sparse` — Initialize a sparse checkout containing only top-level files.
- [ ] `--separate-git-dir=<git-dir>` — Put the repository elsewhere and leave a `.git` file pointing at it.
- [ ] `--template=<template-directory>` — Seed the new repository from a template directory.
- [ ] `-c<key>=<value>` / `--config=<key>=<value>` — Set configuration in the new repository before fetching.
- [ ] `--ref-format=<ref-format>` — Choose the ref storage backend (`files` or `reftable`).
- [x] `-q` / `--quiet` — Suppress progress and informational output.  `[log]`
- [x] `-v` / `--verbose` — Report more detail.
- [ ] `--progress` — Force progress reporting.
- [ ] `--server-option=<option>` — Send a server option (protocol v2 only).
- [x] `-u<upload-pack>` / `--upload-pack=<upload-pack>` — Override the remote `git-upload-pack` path.
- [ ] `-l` / `--local` — For local paths, copy or hardlink the object store instead of using the transport.
- [ ] `--no-hardlinks` — Copy object files rather than hardlinking them.
- [ ] `-s` / `--shared` — Share the source repository's object store via `alternates` (unsafe if the source is pruned).
- [ ] `--reference=<repository>` / `--reference-if-able=<repository>` — Borrow objects from a local repository to reduce transfer.
- [ ] `--dissociate` — Copy borrowed objects into the new repository and drop the alternates entry.
- [ ] `--depth=<depth>` — *(core, shallow)* Truncate history to a number of commits.
- [ ] `--shallow-since=<date>` — Truncate history to commits after a date.
- [ ] `--shallow-exclude=<ref>` — Truncate history excluding commits reachable from a ref.
- [ ] `--no-reject-shallow` / `--reject-shallow` — Accept or refuse cloning from a shallow source.
- [ ] `--single-branch` / `--no-single-branch` — Fetch only the history of one branch.
- [ ] `--tags` / `--no-tags` — Control whether tags are cloned and followed thereafter.
- [ ] `--filter=<filter-spec>` — Create a partial clone omitting objects matching a filter.
- [ ] `--also-filter-submodules` — Apply the partial clone filter to submodules too.
- [ ] `--bundle-uri=<uri>` — Seed the clone from a bundle before contacting the remote.
- [ ] `--recurse-submodules[=<pathspec>]` — Initialize and clone submodules after the main clone.
- [ ] `--shallow-submodules` / `--no-shallow-submodules` — Clone submodules with depth 1.
- [ ] `--remote-submodules` / `--no-remote-submodules` — Update submodules from their remote-tracking branch rather than the recorded commit.
- [ ] `-j<n>` / `--jobs=<n>` — Number of submodules to fetch in parallel.

## `commit` — record the staged content as a new commit

### What to commit

- [x] `<pathspec>…` — Commit the given paths' working-tree content, bypassing the index.  `[log]`
- [x] `-a` / `--all` — *(core)* Automatically stage modifications and deletions of tracked files.  `[log]`
- [ ] `-p` / `--patch` — Choose hunks to commit interactively.
- [ ] `-i` / `--include` — Also commit the named paths on top of what is already staged.
- [ ] `-o` / `--only` — Commit only the named paths, ignoring other staged changes.
- [ ] `--pathspec-from-file=<file>` — Read the pathspec from a file or stdin.
- [ ] `--pathspec-file-nul` — Treat that file as NUL-separated and literal.
- [x] `--` — End option parsing.

### Message

- [x] `-m <msg>` / `--message=<msg>` — *(core)* Use the given text as the commit message; repeatable for paragraphs.  `[log]`
- [x] `-F <file>` / `--file=<file>` — Read the commit message from a file or stdin.  `[log]`
- [ ] `-t <file>` / `--template=<file>` — Preload the editor with a template file.
- [ ] `-C <commit>` / `--reuse-message=<commit>` — Reuse another commit's message and authorship.
- [ ] `-c <commit>` / `--reedit-message=<commit>` — As `-C`, but open the message in an editor first.
- [ ] `--fixup=[(amend|reword):]<commit>` — Create a `fixup!`/`amend!` commit for later autosquashing.
- [ ] `--squash=<commit>` — Create a `squash!` commit for later autosquashing.
- [x] `-e` / `--edit` — Force the editor open even when a message was supplied.
- [x] `--no-edit` — Use the message as-is without opening an editor.  `[log]`
- [ ] `--cleanup=<mode>` — Clean up the message: `strip`, `whitespace`, `verbatim`, `scissors`, or `default`.
- [ ] `--trailer <token>[(=|:)<value>]` — Add a trailer to the message; repeatable.
- [x] `-s` / `--signoff` / `--no-signoff` — Add a `Signed-off-by` trailer.
- [ ] `--allow-empty-message` — Permit creating a commit with an empty message.
- [ ] `--status` / `--no-status` — Include or omit `git status` output in the editor template.
- [ ] `-v` / `--verbose` — Append the staged diff to the editor template (twice also appends the unstaged diff).

### Identity, amending, and signing

- [x] `--author=<author>` — Override the author identity.
- [x] `--date=<date>` — Override the author date.
- [ ] `--reset-author` — Reset author name, email, and date to the committer's.
- [x] `--amend` — *(core)* Replace the tip commit instead of adding a new one.  `[log]`
- [x] `--allow-empty` — Permit a commit whose tree matches its parent.
- [ ] `-S[<key-id>]` / `--gpg-sign[=<key-id>]` / `--no-gpg-sign` — Sign the commit.
- [x] `-n` / `--verify` / `--no-verify` — Run or bypass the `pre-commit` and `commit-msg` hooks.
- [ ] `--no-post-rewrite` — Skip the `post-rewrite` hook after amending.

### Output

- [ ] `--dry-run` — Report what would be committed without committing.
- [x] `-q` / `--quiet` — Suppress the commit summary.  `[log]`
- [ ] `--short` — With `--dry-run`, print short-format status (implies `--dry-run`).
- [ ] `--long` — With `--dry-run`, print long-format status.
- [ ] `--porcelain` — With `--dry-run`, print machine-readable status.
- [ ] `--branch` — Include branch and tracking info in short-format output.
- [ ] `-z` / `--null` — NUL-terminate short/porcelain records and print paths verbatim.
- [ ] `-u[<mode>]` / `--untracked-files[=<mode>]` — Control untracked file reporting (`no`, `normal`, `all`).
- [ ] *diff-context options* — `-U<n>`, `--inter-hunk-context` for `--patch` mode.
