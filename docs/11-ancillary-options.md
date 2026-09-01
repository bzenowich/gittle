# 11 — Ancillary commands: manipulators and interrogators

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


Commands that are neither core porcelain nor primitive plumbing: configuration,
repository maintenance, and diagnostics.

---

# Ancillary manipulators

## `config` — read and write configuration

Subcommands: `list`, `get`, `set`, `unset`, `rename-section`, `remove-section`,
`edit`.

- [x] `list` — *(core)* Print every variable in the selected scope.  `[log]`
- [x] `get <key>` — *(core)* Print the value of a key (the last one if repeated).  `[log]`
- [x] `set <key> <value>` — *(core)* Set a key's value.
- [x] `unset <key>` — Remove a key.
- [ ] `rename-section <old> <new>` — Rename a configuration section.
- [ ] `remove-section <name>` — Delete a whole section.
- [ ] `edit` — Open the selected config file in an editor.

### Scope selection

- [x] `--local` — *(core)* Operate on `.git/config` (the default).
- [x] `--global` — *(core)* Operate on `~/.gitconfig` or the XDG config file.
- [ ] `--system` — Operate on the system-wide config file.
- [ ] `--worktree` — Operate on the per-worktree config file.
- [x] `-f <config-file>` / `--file <config-file>` — Operate on an arbitrary file.  `[log]`
- [ ] `--blob <blob>` — Read configuration out of a blob in the object database.
- [ ] `--includes` / `--no-includes` — Honor or ignore `include.*` directives.

### Matching and multi-valued keys

- [x] `--all` — With `get`, return every value of a multi-valued key.
- [ ] `--regexp` — Interpret the key name as a regular expression.
- [ ] `--value=<pattern>` / `--no-value` — Restrict the operation to values matching a pattern.
- [ ] `--fixed-value` — Treat `--value` as a literal string rather than a regex.
- [ ] `--replace-all` — With `set`, replace every matching line rather than one.
- [ ] `--append` — With `set`, add a value without touching existing ones.
- [ ] `--url=<URL>` — Look up a key using URL-matching semantics.
- [ ] `--default <value>` — With `get`, substitute a value when the key is missing.

### Types and output

- [ ] `--type <type>` — Validate and canonicalize as `bool`, `int`, `bool-or-int`, `path`, `expiry-date`, or `color`.
- [ ] `--bool` / `--int` / `--bool-or-int` / `--path` / `--expiry-date` — Historical spellings of `--type`.
- [ ] `--no-type` — Clear a previously set type constraint.
- [ ] `-z` / `--null` — NUL-terminate output values.
- [ ] `--name-only` — Print only key names.
- [ ] `--show-names` / `--no-show-names` — With `get`, include the key alongside the value.
- [ ] `--show-origin` — Annotate output with the file each value came from.
- [ ] `--show-scope` — Annotate output with the scope each value came from.
- [ ] `--get-colorbool <name> [<stdout-is-tty>]` — Resolve a color setting to `true`/`false`.
- [ ] `--comment <message>` — Append a comment to lines this invocation writes.

## `fast-export` — dump history as a fast-import stream

> **CUT from v1** — interchange format for repository surgery.

- [ ] `[<rev-list-args>…]` — Which history to export.
- [ ] `--progress=<n>` — Emit progress statements every `<n>` objects.
- [ ] `--signed-tags=(verbatim|warn-verbatim|warn-strip|strip|abort)` — How to handle signed tags.
- [ ] `--signed-commits=(verbatim|warn-verbatim|warn-strip|strip|abort)` — How to handle signed commits.
- [ ] `--tag-of-filtered-object=(abort|drop|rewrite)` — How to handle tags whose target was filtered out.
- [ ] `-M` / `-C` — Emit rename and copy commands based on detection.
- [ ] `--export-marks=<file>` — Write the mark table out for incremental exports.
- [ ] `--import-marks=<file>` — Load a mark table before exporting.
- [ ] `--mark-tags` — Also assign marks to tag objects.
- [ ] `--fake-missing-tagger` — Invent a tagger for old tags that lack one.
- [ ] `--use-done-feature` — Emit `feature done` and a terminating `done`.
- [ ] `--no-data` — Reference blobs by object name instead of emitting their content.
- [ ] `--full-tree` — Emit a `deleteall` plus a full file list for each commit.
- [ ] `--anonymize` — Replace names and content with generated tokens, preserving history shape.
- [ ] `--anonymize-map=<from>[:<to>]` — Pin a specific token mapping while anonymizing.
- [ ] `--reference-excluded-parents` — Reference excluded parents by object name rather than rewriting them away.
- [ ] `--show-original-ids` — Emit `original-oid` lines for commits and blobs.
- [ ] `--reencode=(yes|no|abort)` — How to handle commits with an `encoding` header.
- [ ] `--refspec <refspec>` — Rewrite exported ref names through a refspec.

## `fast-import` — build history from a command stream

> **CUT from v1** — interchange format for repository surgery.

- [ ] `--force` — Allow branch updates that discard existing commits.
- [ ] `--quiet` — Suppress the statistics output.
- [ ] `--stats` — Print object and packfile statistics on completion.
- [ ] `--allow-unsafe-features` — Permit stream-supplied options that touch the filesystem.
- [ ] `--signed-tags=<mode>` / `--signed-commits=<mode>` — How to handle signatures in the input stream.
- [ ] `--cat-blob-fd=<fd>` — Send `cat-blob`/`get-mark`/`ls` responses to a specific descriptor.
- [ ] `--date-format=<fmt>` — Date format the frontend will supply (`raw`, `raw-permissive`, `rfc2822`, `now`).
- [ ] `--done` — Require a terminating `done` command, catching truncated streams.
- [ ] `--export-marks=<file>` — Write the mark table on completion.
- [ ] `--import-marks=<file>` — Load a mark table before importing.
- [ ] `--import-marks-if-exists=<file>` — As `--import-marks`, tolerating a missing file.
- [ ] `--relative-marks` / `--no-relative-marks` — Interpret mark paths relative to the repository directory.
- [ ] `--rewrite-submodules-from=<name>:<file>` / `--rewrite-submodules-to=<name>:<file>` — Translate submodule object IDs through mark files.
- [ ] `--active-branches=<n>` — Number of branches kept in memory at once.
- [ ] `--big-file-threshold=<n>` — Size above which blobs are not deltified.
- [ ] `--depth=<n>` — Maximum delta depth for blobs and trees.
- [ ] `--export-pack-edges=<file>` — Record the pack boundaries of each created pack.
- [ ] `--max-pack-size=<n>` — Maximum size of each output packfile.

## `filter-branch` — rewrite history with shell filters (deprecated)

> **CUT from v1** — deprecated upstream; a shell script.

- [ ] `<rev-list options>…` — Which refs and commits to rewrite.
- [ ] `--setup <command>` — Run a one-time setup command before the rewrite loop.
- [ ] `--subdirectory-filter <directory>` — Keep only history touching a subdirectory and make it the new root.
- [ ] `--env-filter <command>` — Modify the environment (author/committer) for each commit.
- [ ] `--tree-filter <command>` — Rewrite each commit's tree with a checked-out working tree.
- [ ] `--index-filter <command>` — Rewrite each commit's index without a checkout (much faster).
- [ ] `--parent-filter <command>` — Rewrite each commit's parent list.
- [ ] `--msg-filter <command>` — Rewrite each commit message.
- [ ] `--commit-filter <command>` — Replace the commit-creation step entirely.
- [ ] `--tag-name-filter <command>` — Rewrite tag names for rewritten commits.
- [ ] `--prune-empty` — Drop commits that end up making no change.
- [ ] `--original <namespace>` — Namespace under which the original refs are saved.
- [ ] `-d <directory>` — Temporary directory used for tree filters.
- [ ] `-f` / `--force` — Proceed despite leftover state from a previous run.
- [ ] `--state-branch <branch>` — Persist the old-to-new object mapping across runs.

## `mergetool` — resolve conflicts with external tools

> **CUT from v1** — a shell script that shells out to external GUIs.

- [ ] `-t <tool>` / `--tool=<tool>` — Choose the merge tool.
- [ ] `--tool-help` — List the available merge tools.
- [ ] `-y` / `--no-prompt` — Do not prompt before launching the tool.
- [ ] `--prompt` — Prompt before each path.
- [ ] `-g` / `--gui` — Use the configured GUI merge tool.
- [ ] `--no-gui` — Use the terminal merge tool despite configuration.
- [ ] `-O<orderfile>` — Process conflicted paths in the order given by a file.

## `prune` — delete unreachable objects

> **CUT from v1** — `gc` prunes internally.

- [ ] `<head>…` — Additional tips to treat as reachable.
- [ ] `-n` / `--dry-run` — Report what would be deleted without deleting.
- [ ] `-v` / `--verbose` — Report every removed object.
- [ ] `--progress` — Show progress.
- [ ] `--expire <time>` — Only remove loose objects older than a time.
- [ ] `--` — End option parsing.

## `reflog` — manage per-ref logs

Subcommands: `show`, `list`, `exists`, `write`, `delete`, `drop`, `expire`.

- [x] `show [<ref>]` — *(core)* Print the reflog for a ref (an alias for `log -g`).  `[log]`
- [ ] `list` — List every ref that has a reflog.
- [ ] `expire` — Prune old reflog entries.
- [ ] `delete <ref>@{<n>}` — Delete individual reflog entries.
- [ ] `exists <ref>` — Exit zero if a ref has a reflog.
- [ ] `write <ref> <old-oid> <new-oid> <message>` — Append an entry to a ref's reflog directly.
- [ ] `drop [<ref>]` — Delete a ref's entire reflog.
- [ ] `--all` — Operate on the reflogs of every ref.
- [ ] `--single-worktree` — Limit `--all` to the current worktree's refs.
- [ ] `--expire=<time>` — Prune entries older than a time.
- [ ] `--expire-unreachable=<time>` — Prune unreachable entries older than a time.
- [ ] `--updateref` — Update the ref itself when its top entry is pruned.
- [ ] `--rewrite` — Rewrite predecessor object names so the log stays a chain.
- [ ] `--stale-fix` — Prune entries pointing at broken commits.
- [ ] `-n` / `--dry-run` — Report what would be pruned without pruning.
- [ ] `--verbose` — Print extra detail.

## `refs` — low-level ref-store access

> **CUT from v1** — reftable migration; v1 is files-backend only.

Subcommands: `migrate`, `verify`, `list`, `exists`, `optimize`, `create`,
`delete`, `update`, `rename`.

- [ ] `migrate` — Convert the ref store between the `files` and `reftable` formats.
- [ ] `verify` — Check ref database consistency.
- [ ] `list` — List refs (alias for `for-each-ref`).
- [ ] `exists <ref>` — Exit 0/2/1 depending on whether a ref exists.
- [ ] `optimize` — Compact the ref store (alias for `pack-refs`).
- [ ] `create <ref> <new-value>` — Create a ref that must not already exist.
- [ ] `delete <ref> [<old-value>]` — Delete a ref, optionally checking its current value.
- [ ] `update <ref> <new-value> [<old-value>]` — Update a ref, optionally checking its current value.
- [ ] `rename <oldref> <newref>` — Rename a ref.
- [ ] `--ref-format=<format>` — Target format for `migrate`.
- [ ] `--dry-run` — Perform a migration into a scratch directory without replacing the ref store.
- [ ] `--reflog` / `--no-reflog` — Migrate or discard reflog data.
- [ ] `--strict` — Treat verification warnings as errors.
- [ ] `--verbose` — Be chatty while verifying.
- [ ] `--create-reflog` — Create a reflog for an updated ref.
- [ ] `--message=<reason>` — Reflog message for the update.
- [ ] `--no-deref` — Operate on the symbolic ref itself.
- [ ] *for-each-ref options*, *pack-refs options* — see `05`.

## `remote` — manage named remotes

Subcommands: `add`, `rename`, `remove`/`rm`, `set-head`, `set-branches`,
`get-url`, `set-url`, `show`, `prune`, `update`.

- [x] `add <name> <URL>` — *(core)* Register a remote and its default fetch refspec.
- [ ] `rename <old> <new>` — Rename a remote and its tracking refs.
- [x] `remove <name>` / `rm <name>` — Delete a remote and its tracking refs.
- [ ] `set-head <name> (-a | -d | <branch>)` — Set or delete the remote's default branch pointer.
- [ ] `set-branches <name> <branch>…` — Change which branches the remote tracks.
- [x] `get-url <name>` — Print the remote's URL(s), expanding `insteadOf` rules.
- [x] `set-url <name> <newurl> [<oldurl>]` — Change the remote's URL.
- [ ] `show <name>` — Report the remote's URL, branches, and tracking state.
- [ ] `prune <name>` — Delete stale remote-tracking refs.
- [ ] `update [<group>]` — Fetch from a group of remotes.
- [x] `-v` / `--verbose` — Include URLs (and promisor filters) in the listing.  `[log]`

Per-subcommand flags: `add -t <branch>` (track only this branch),
`add -m <master>` (which branch the remote HEAD points at), `add -f` (fetch
immediately), `add --tags`/`--no-tags`, `add --mirror=(fetch|push)`,
`rename --progress`/`--no-progress`, `set-head -a`/`--auto` and `-d`/`--delete`,
`set-branches --add`, `get-url --push`/`--all`,
`set-url --push`/`--add`/`--delete`, `show -n` (skip contacting the remote),
`prune -n`/`--dry-run`, `update -p`/`--prune`.

## `repack` — rebuild packfiles

> **CUT from v1** — `gc` repacks internally.

### What to pack

- [ ] `-a` — *(core)* Pack everything reachable into one pack.
- [ ] `-A` — As `-a`, but with `-d` loosen unreachable objects instead of discarding them.
- [ ] `-d` — *(core)* Delete packs made redundant by the new one and run `prune-packed`.
- [ ] `-l` — Pass `--local` to `pack-objects`, skipping alternates' objects.
- [ ] `--pack-kept-objects` — Include objects from `.keep`-marked packs.
- [ ] `--keep-pack=<pack-name>` — Exclude a specific pack from repacking.
- [ ] `-k` / `--keep-unreachable` — Append unreachable objects from old packs to the new one.
- [ ] `--unpack-unreachable=<when>` — Do not loosen unreachable objects older than a time.
- [ ] `-g<factor>` / `--geometric=<factor>` — Maintain a geometric progression of pack sizes, repacking only what is needed.
- [ ] `-m` / `--write-midx[=<mode>]` — Write a multi-pack index for the resulting packs.
- [ ] `-n` — Skip updating `objects/info` server files.

### Cruft packs

- [ ] `--cruft` — Route unreachable objects into a cruft pack.
- [ ] `--cruft-expiration=<approxidate>` — Expire cruft objects older than a time.
- [ ] `--max-cruft-size=<n>` — Size cap specific to cruft packs.
- [ ] `--combine-cruft-below-size=<n>` — Only merge existing cruft packs below a size.
- [ ] `--expire-to=<dir>` — Write pruned objects into a cruft pack in another directory.

### Filtering (partial clone maintenance)

- [ ] `--filter=<filter-spec>` — Move filtered-out objects into a separate pack.
- [ ] `--filter-to=<dir>` — Where the filtered-out pack is written.
- [ ] `--drop-filtered` — Delete filtered-out objects rather than keeping them.
- [ ] `--dry-run` — With `--drop-filtered`, list the object IDs that would be dropped.

### Pass-through to `pack-objects`

- [ ] `-f` — Pass `--no-reuse-delta`.
- [ ] `-F` — Pass `--no-reuse-object`.
- [ ] `--window=<n>` / `--depth=<n>` — Delta search width and chain depth.
- [ ] `--window-memory=<n>` — Memory ceiling for the delta window.
- [ ] `--max-pack-size=<n>` — Split output into packs of at most this size.
- [ ] `--threads=<n>` — Delta-search thread count.
- [ ] `-b` / `--write-bitmap-index` — Write a reachability bitmap alongside the pack.
- [ ] `-i` / `--delta-islands` — Enable delta islands.
- [ ] `--name-hash-version=<n>` — Path-similarity hash version.
- [ ] `--path-walk` — Group objects by path before compressing.
- [ ] `-q` / `--quiet` — Suppress progress.

## `replace` — substitute one object for another

> **CUT from v1** — object substitution; v1 ignores `refs/replace/` entirely.

- [ ] `<object> <replacement>` — Create a replace ref mapping one object to another.
- [ ] `-f` / `--force` — Overwrite an existing replace ref.
- [ ] `-d` / `--delete` — Delete replace refs for the given objects.
- [ ] `--edit <object>` — Edit an object's content in an editor and replace it with the result.
- [ ] `--raw` — With `--edit`, present raw rather than pretty-printed content.
- [ ] `--graft <commit> [<parent>…]` — Create a replacement commit with a different parent list.
- [ ] `--convert-graft-file` — Convert a legacy `info/grafts` file into replace refs.
- [ ] `-l <pattern>` / `--list <pattern>` — List replace refs matching a pattern.
- [ ] `--format=<format>` — Listing format: `short`, `medium`, or `long`.

---

# Ancillary interrogators

## `blame` / `annotate` — attribute lines to commits

> **CUT from v1** — ~2.9k lines of C for line-origin tracking. Genuinely missed by humans — the strongest v2 candidate after `apply`.

`annotate` is `blame` with the older output style and no options of its own.

- [ ] `-c` — Use `annotate`-style output.
- [ ] `-f` / `--show-name` — Show the filename as recorded in the originating commit.
- [ ] `-n` / `--show-number` — Show the line number in the originating commit.
- [ ] `-s` — Suppress the author name and timestamp.
- [ ] `-e` / `--show-email` — Show author email instead of name.
- [ ] `-w` — Ignore whitespace when matching lines to their origin.
- [ ] `--abbrev=<n>` — Length of abbreviated object names in the output.
- [ ] `--score-debug` — Print debugging information about line movement detection.
- [ ] *blame options*, *diff algorithm option* — see `05`.

## `bugreport` — collect information for a bug report

> **CUT from v1** — diagnostics wrapper.

- [ ] `-o <path>` / `--output-directory <path>` — Where to write the report.
- [ ] `-s <format>` / `--suffix <format>` / `--no-suffix` — Filename suffix (a `strftime` format).
- [ ] `--diagnose[=<mode>]` / `--no-diagnose` — Also produce a diagnostics zip archive.

## `count-objects` — report loose object statistics

> **CUT from v1** — diagnostics.

- [ ] `-v` / `--verbose` — Report packed objects, garbage, and sizes as well.
- [ ] `-H` / `--human-readable` — Print sizes in human-readable units.

## `diagnose` — produce a diagnostics archive

> **CUT from v1** — diagnostics.

- [ ] `-o <path>` / `--output-directory <path>` — Where to write the archive.
- [ ] `-s <format>` / `--suffix <format>` — Filename suffix.
- [ ] `--mode=(stats|all)` — How much to collect; `all` includes object database contents.

## `difftool` — show diffs with an external tool

> **CUT from v1** — shells out to external GUIs.

- [ ] `-d` / `--dir-diff` — Diff whole directory snapshots rather than file by file.
- [ ] `-t <tool>` / `--tool=<tool>` — Choose the diff tool.
- [ ] `--tool-help` — List the available diff tools.
- [ ] `-y` / `--no-prompt` — Do not prompt before each invocation.
- [ ] `--prompt` — Prompt before each invocation (the default).
- [ ] `-g` / `--gui` / `--no-gui` — Use or ignore the configured GUI tool.
- [ ] `-x <command>` / `--extcmd=<command>` — Run an arbitrary command instead of a configured tool.
- [ ] `--symlinks` / `--no-symlinks` — In `--dir-diff`, symlink to working-tree files or copy them.
- [ ] `--trust-exit-code` / `--no-trust-exit-code` — Propagate the tool's exit status.
- [ ] `--rotate-to=<file>` / `--skip-to=<file>` — Reorder or skip ahead in the file list.
- [ ] *diff options* — `difftool` accepts everything `git diff` does.

## `fsck` — verify object database integrity

> **CUT from v1** — integrity checking; valuable but not needed to use a repository.

- [ ] `<object>` — Extra tips to treat as reachable roots.
- [ ] `--unreachable` — Report objects not reachable from any ref.
- [ ] `--dangling` / `--no-dangling` — Report (or not) objects that nothing points at.
- [ ] `--root` — Report root commits.
- [ ] `--tags` — Report tags.
- [ ] `--cache` — Treat index entries as reachability roots.
- [ ] `--no-reflogs` — Do not treat reflog entries as making objects reachable.
- [ ] `--full` — Check alternate object stores as well as the local one.
- [ ] `--connectivity-only` — Check links without parsing every object's content.
- [ ] `--strict` — Enable stricter checks, such as rejecting group-writable modes.
- [ ] `--verbose` — Be chatty about what is checked.
- [ ] `--lost-found` — Write dangling objects into `.git/lost-found/`.
- [ ] `--name-objects` — Print a human-readable path describing how each object is reached.
- [ ] `--progress` / `--no-progress` — Force progress reporting on or off.
- [ ] `--references` / `--no-references` — Also run `git refs verify`.
- [ ] *fsck message IDs* — `Documentation/fsck-msgids.adoc` lists ~76 individual checks whose severity can be tuned via `fsck.<msg-id>`; a minimal implementation would keep only a handful.

## `help` — show documentation

- [x] `<command>` — Show that command's manual page.
- [x] `-a` / `--all` — List every available command.
- [ ] `--no-external-commands` — Exclude `git-*` binaries found in `PATH` from `--all`.
- [ ] `--no-aliases` — Exclude configured aliases from `--all`.
- [ ] `--verbose` — Include descriptions in `--all` output (the default).
- [ ] `-c` / `--config` — List all configuration variables.
- [ ] `-g` / `--guides` — List the concept guides.
- [ ] `--user-interfaces` — List the file/interface documentation pages.
- [ ] `--developer-interfaces` — List the format and protocol documentation pages.
- [ ] `-i` / `--info` — Show the page in Info format.
- [ ] `-m` / `--man` — Show the page in man format.
- [ ] `-w` / `--web` — Show the page in a web browser.

## `instaweb` — browse the repository with gitweb

> **CUT from v1** — runs a web server.

- [ ] `start` / `--start`, `stop` / `--stop`, `restart` / `--restart` — Control the local web server.
- [ ] `-l` / `--local` — Bind only to 127.0.0.1.
- [ ] `-d` / `--httpd` — Which HTTP daemon to run.
- [ ] `-m` / `--module-path` — Apache module path.
- [ ] `-p` / `--port` — Port to listen on.
- [ ] `-b` / `--browser` — Browser used to open the page.

## `merge-tree` — merge two commits without index or working tree

> **CUT from v1** — server-side merge preview; `merge` covers the local case.

- [ ] `<branch1> <branch2>` — *(core)* The two commits to merge.  `[log]`
- [ ] `--write-tree` — Write the merged tree into the object database and print its ID (the modern mode; implied when a base is not given).  `[log]`
- [ ] `--trivial-merge <base-tree> <branch1> <branch2>` — Deprecated three-argument mode that only resolves trivial merges.
- [ ] `--stdin` — Read merge requests from standard input instead of arguments.
- [ ] `--merge-base=<tree-ish>` — Use an explicit merge base.
- [ ] `--allow-unrelated-histories` — Permit merging histories with no common ancestor.
- [ ] `-X<option>` / `--strategy-option=<option>` — Pass an option to the merge strategy.
- [ ] `--name-only` — Print only paths in the conflicted-file section.
- [ ] `--messages` / `--no-messages` — Include or omit informational conflict messages.
- [ ] `-z` — NUL-terminate filenames and do not quote them.
- [ ] `--quiet` — Produce no output, leaving only the exit status.

`merge-tree` is worth attention for gittle: it is the whole merge engine with
none of the working-tree machinery, and it is what server-side merges use.

## `rerere` — reuse recorded conflict resolutions

> **CUT from v1** — conflict-resolution memory.

Subcommands: `clear`, `forget <pathspec>`, `diff`, `status`, `remaining`, `gc`.

- [ ] `clear` — Discard the current rerere state.
- [ ] `forget <pathspec>` — Forget the recorded resolution for matching paths.
- [ ] `diff` — Show how the current resolution differs from the recorded conflict.
- [ ] `status` — List paths whose resolution will be recorded.
- [ ] `remaining` — List paths still unresolved.
- [ ] `gc` — Expire old recorded resolutions.

## `show-branch` — compare branch tips

> **CUT from v1** — superseded in practice by `log --graph`.

- [ ] `<rev>` / `<glob>` — Branches or patterns to display.
- [ ] `-r` / `--remotes` — Show remote-tracking branches.
- [ ] `-a` / `--all` — Show both local and remote-tracking branches.
- [ ] `--current` — Include the current branch in the display.
- [ ] `--topo-order` — Order commits topologically.
- [ ] `--date-order` — Order commits by date, still parents-after-children.
- [ ] `--sparse` — Include merges reachable from only one displayed tip.
- [ ] `--more=<n>` — Show `<n>` commits beyond the common ancestor.
- [ ] `--list` — Synonym for `--more=-1`.
- [ ] `--merge-base` — Print merge bases instead of the commit list.
- [ ] `--independent` — Print only the tips not reachable from other tips.
- [ ] `--no-name` — Omit the naming strings.
- [ ] `--sha1-name` — Name commits by abbreviated object name.
- [ ] `--topics` — Show only commits absent from the first branch given.
- [ ] `-g` / `--reflog[=<n>[,<base>]]` — Show reflog entries instead of branch tips.
- [ ] `--color[=<when>]` — Color the per-branch status signs.
- [ ] `--no-color` — Disable coloring.

## `verify-commit` / `verify-tag` — check signatures

> **CUT from v1** — v1 does not implement signing.

- [ ] `--raw` — Print the raw GPG status output to stderr.
- [ ] `-v` / `--verbose` — Print the object's contents before verifying.

## `version` — print the git version

- [ ] `--build-options` — Also print build configuration details.

## `whatchanged` — deprecated `log --raw`

> **CUT from v1** — deprecated alias for `log --raw`.

No options of its own; it is `log` with a different default diff format and a
deprecation warning.

## `gitweb` — CGI web frontend

> **CUT from v1** — CGI web frontend.

Configured through `gitweb.conf` rather than command-line options; entirely out
of scope for gittle.
