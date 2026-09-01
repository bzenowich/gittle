# 10 — Low-level plumbing: manipulators

> **Marks** — `[x]` in scope for gittle v1 · `[ ]` out of scope · `` `[log]` `` seen in the
> agent tool-call logs (`git-tool-calls-*.md`). A section headed **CUT from v1** has every
> option out of scope; the reason follows inline. Rationale and budget: `plan.md`.


Commands that write to the object database, the index, or refs. Together with
`09` these define the storage layer gittle must implement to stay on-disk
compatible with git.

---

## `apply` — apply a patch to the index and/or working tree

> **CUT from v1** — standalone patch application is ~5.3k lines of C and a whole fuzzy-matching engine. The single biggest deferred item — see plan.md.

### Where to apply

- [ ] `<patch>…` — *(core)* Patch files to read; `-` reads stdin.  `[log]`
- [ ] `--index` — *(core)* Apply to both the index and the working tree.
- [ ] `--cached` — Apply to the index only.
- [ ] `-N` / `--intent-to-add` — Mark newly added files as intent-to-add in the index.
- [ ] `-R` / `--reverse` — Apply the patch in reverse.
- [ ] `--exclude=<path-pattern>` — Skip files matching a pattern.
- [ ] `--include=<path-pattern>` — Apply only to files matching a pattern.
- [ ] `--directory=<root>` — Prepend a directory to every path in the patch.
- [ ] `-p<n>` — *(core)* Strip `<n>` leading path components from patch paths.
- [ ] `--unsafe-paths` — Permit the patch to touch files outside the working area.

### How to apply

- [ ] `-3` / `--3way` — Fall back to a three-way merge using the blob IDs recorded in the patch.
- [ ] `--ours` / `--theirs` / `--union` — Auto-resolve three-way conflicts by favoring one side or both.
- [ ] `--build-fake-ancestor=<file>` — Reconstruct a temporary index of the patch's preimage blobs.
- [ ] `--reject` — Apply what applies and write `.rej` files for the rest.
- [ ] `-C<n>` — Require `<n>` lines of matching context around each hunk.
- [ ] `--unidiff-zero` — Accept a zero-context diff, disabling the usual safety check.
- [ ] `--recount` — Recompute hunk line counts rather than trusting the headers.
- [ ] `--no-add` — Ignore added lines, applying only removals.
- [ ] `--allow-binary-replacement` / `--binary` — Permit binary patches to be applied.
- [ ] `--inaccurate-eof` — Tolerate a missing trailing newline that the producing diff mis-detected.
- [ ] `--allow-empty` — Do not error on a patch containing no diff.
- [ ] `--ignore-space-change` / `--ignore-whitespace` — Ignore whitespace changes in context lines.
- [ ] `--whitespace=<action>` — Set the whitespace-error policy (`nowarn`, `warn`, `fix`, `error`, `error-all`).

### Inspection instead of application

- [ ] `--check` — Report whether the patch would apply, changing nothing.
- [ ] `--stat` — Print a diffstat of the patch instead of applying it.
- [ ] `--numstat` — Print machine-readable added/deleted counts instead of applying.
- [ ] `--summary` — Print the extended header summary instead of applying.
- [ ] `--apply` — Apply anyway despite one of the inspection options above.
- [ ] `-z` — Use NUL-terminated machine-readable paths with `--numstat`.
- [ ] `-v` / `--verbose` — Report progress on stderr.
- [ ] `-q` / `--quiet` — Suppress stderr output.

## `checkout-index` — write index content into the working tree

> **CUT from v1** — covered by `checkout`/`restore`.

- [ ] `<file>…` — Paths to check out.
- [ ] `-a` / `--all` — Check out every index entry.
- [ ] `-u` / `--index` — Update stat information in the index for what was written.
- [ ] `-f` / `--force` — Overwrite existing files.
- [ ] `-n` / `--no-create` — Refresh only files that already exist.
- [ ] `-q` / `--quiet` — Do not complain about existing or missing files.
- [ ] `--prefix=<string>` — Prepend a string (usually a directory) to output paths.
- [ ] `--stage=(<number>|all)` — Check out a specific merge stage instead of the merged entry.
- [ ] `--temp` — Write to temporary files and print their names.
- [ ] `--ignore-skip-worktree-bits` — Check out entries even when marked skip-worktree.
- [ ] `--stdin` — Read the path list from standard input.
- [ ] `-z` — Treat the `--stdin` list as NUL-separated.
- [ ] `--` — End option parsing.

## `commit-graph` — build and check the commit-graph

> **CUT from v1** — a pure accelerator; v1 neither reads nor writes it.

Subcommands: `write`, `verify`.

- [ ] `write` — Generate a commit-graph file from the commits found in packs.
- [ ] `verify` — Check an existing commit-graph against the object database.
- [ ] `--object-dir=<dir>` — Operate on a specific object directory.
- [ ] `--progress` / `--no-progress` — Force progress reporting on or off.
- [ ] `--reachable` — Build from all refs rather than from packs.
- [ ] `--stdin-commits` — Build from a list of commit OIDs read on stdin.
- [ ] `--stdin-packs` — Build from a list of pack index names read on stdin.
- [ ] `--append` — Include the commits already in the existing commit-graph.
- [ ] `--changed-paths` / `--no-changed-paths` — Compute and store Bloom filters of changed paths.
- [ ] `--max-new-filters=<n>` — Cap how many new Bloom filters are computed.
- [ ] `--split[=(no-merge|replace)]` — Write a chain of commit-graph layers instead of one file.
- [ ] `--size-multiple=<X>` — Merge condition controlling layer size ratios.
- [ ] `--max-commits=<M>` — Merge condition capping commits in the tip layer.
- [ ] `--expire-time=<datetime>` — Delete unreferenced graph layers older than a time.
- [ ] `--shallow` — With `verify`, check only the tip layer of a chain.

## `commit-tree` — create a commit object

- [x] `<tree>` — *(core)* The tree the commit records.
- [x] `-p <parent>` — *(core)* Add a parent; repeatable.
- [x] `-m <message>` — *(core)* Supply a paragraph of the commit message; repeatable.
- [x] `-F <file>` — Read the message from a file or stdin.
- [ ] `-S[<keyid>]` / `--gpg-sign[=<keyid>]` / `--no-gpg-sign` — Sign the commit.
- [ ] *date formats* — the `GIT_AUTHOR_DATE`/`GIT_COMMITTER_DATE` spellings described in `05`.

## `hash-object` — compute (and optionally store) an object ID

- [x] `<file>…` — Files whose content to hash.
- [x] `-t <type>` — Object type to record (`blob`, `tree`, `commit`, `tag`; default `blob`).
- [x] `-w` — *(core)* Actually write the object into the database.
- [x] `--stdin` — *(core)* Read the content from standard input.
- [ ] `--stdin-paths` — Read the list of file names from standard input.
- [ ] `--path=<path>` — Hash as if the content lived at a given path, for attribute lookup.
- [ ] `--no-filters` — Skip the clean filters that attributes would otherwise apply.
- [ ] `--literally` — Store the bytes without validating the object's structure.

## `index-pack` — build a `.idx` for a packfile

- [x] `<pack-file>` — *(core)* The pack to index.
- [x] `--stdin` — Read the pack from stdin and write a copy out.
- [x] `-o <index-file>` — Write the index to a specific path.
- [ ] `--rev-index` / `--no-rev-index` — Also write a `.rev` reverse index.
- [x] `--fix-thin` — *(core for fetch)* Complete a thin pack by appending the missing base objects.
- [ ] `--keep` — Create a `.keep` file so the pack is never repacked away.
- [ ] `--keep=<msg>` — As `--keep`, recording a reason in the file.
- [ ] `--promisor[=<message>]` — Mark the pack as coming from a promisor remote.
- [ ] `--strict[=<msg-id>=<severity>…]` — Fail on broken objects or links.
- [ ] `--fsck-objects[=<msg-id>=<severity>…]` — Fail on broken objects but tolerate broken links.
- [ ] `--check-self-contained-and-connected` — Internal: verify the pack has no dangling links.
- [ ] `--index-version=<version>[,<offset>]` — Test-only: force a pack index version.
- [ ] `--object-format=<hash-algorithm>` — Interpret the pack under a given hash algorithm.
- [ ] `--max-input-size=<size>` — Refuse packs larger than a size.
- [ ] `--threads=<n>` — Number of threads used to resolve deltas.
- [x] `-v` — Report progress and statistics.
- [ ] `--progress-title` — Internal: set the progress line's title.

## `merge-file` — three-way file merge

- [x] `<current> <base> <other>` — *(core)* The three inputs to merge.
- [ ] `--object-id` — Treat the arguments as blob object names rather than file paths.
- [x] `-L <label>` — Label for a conflict marker side; may be given up to three times.
- [x] `-p` — Write the result to stdout instead of overwriting `<current>`.
- [x] `-q` — Do not warn about conflicts.
- [ ] `--diff3` — Emit conflicts in diff3 style, including the base.
- [ ] `--zdiff3` — Emit conflicts in zealous diff3 style.
- [ ] `--ours` / `--theirs` / `--union` — Auto-resolve conflicts by favoring one side or both.
- [ ] `--diff-algorithm=(patience|minimal|histogram|myers)` — Diff algorithm used during the merge.

## `merge-index` — run a merge helper over unmerged index entries

> **CUT from v1** — the merge driver is internal to `merge`.

- [ ] `<merge-program>` — The per-path helper to invoke.
- [ ] `-a` — Run the helper for every unmerged entry.
- [ ] `-o` — Continue after a helper failure rather than stopping.
- [ ] `-q` — Do not complain when the helper fails.
- [ ] `--` — End option parsing.

## `mktag` — create a validated tag object

> **CUT from v1** — validation wrapper; `tag -a` covers creation.

- [ ] `--strict` / `--no-strict` — Enable (default) or disable `fsck --strict`-level validation of the tag.

## `mktree` — build a tree object from text

> **CUT from v1** — niche scripting tool.

- [ ] `-z` — Read NUL-terminated `ls-tree -z` format.
- [ ] `--missing` — Allow entries whose objects are not present.
- [ ] `--batch` — Build multiple trees, separated by blank lines.

## `multi-pack-index` — write and maintain multi-pack indexes

> **CUT from v1** — a pure accelerator.

Subcommands: `write`, `compact`, `verify`, `expire`, `repack`.

- [ ] `write` — Write a new MIDX covering the repository's packs.
- [ ] `compact <from> <to>` — Compact a range of MIDX layers into one.
- [ ] `verify` — Check a MIDX against the object database.
- [ ] `expire` — Delete packs the MIDX tracks but no longer references.
- [ ] `repack` — Combine small MIDX-referenced packs into a new pack.
- [ ] `--object-dir=<dir>` — Operate on a specific object directory.
- [ ] `--progress` / `--no-progress` — Force progress reporting on or off.
- [ ] `--preferred-pack=<pack>` — Prefer one pack when the same object appears in several.
- [ ] `--bitmap` / `--no-bitmap` — Control whether a multi-pack bitmap is written.
- [ ] `--stdin-packs` — Read the pack list from standard input.
- [ ] `--refs-snapshot=<path>` — Use a pre-taken refs snapshot when selecting bitmap tips.
- [ ] `--incremental` — Write into a MIDX chain rather than a stand-alone file.
- [ ] `--write-chain-file` / `--no-write-chain-file` — Write a new layer without updating the chain file.
- [ ] `--base=<checksum>` — Choose the base layer for a compaction (`none` for no base).
- [ ] `--batch-size=<size>` — With `repack`, target size for the newly created pack.

## `pack-objects` — create a packfile

### Input and output

- [x] `base-name` — *(core)* Write `.pack` and `.idx` files using this prefix.
- [x] `--stdout` — *(core for transport)* Write the pack to standard output.
- [x] `--revs` — *(core)* Read revision arguments on stdin instead of bare object names.
- [ ] `--unpacked` — Limit to objects not already packed (implies `--revs`).
- [ ] `--all` — Add every ref to the revision arguments (implies `--revs`).
- [ ] `--include-tag` — Include annotated tags whose targets made it into the pack.
- [ ] `--stdin-packs[=<mode>]` — Take pack basenames on stdin rather than object names.
- [ ] `--non-empty` — Write nothing if the pack would be empty.
- [ ] `--filter=<filter-spec>` — Omit objects matching a filter (partial clone).
- [ ] `--no-filter` — Cancel a previous filter.
- [ ] `--missing=<missing-action>` — Choose how missing objects are handled.
- [ ] `--exclude-promisor-objects` — Omit objects known to live on a promisor remote.

### Delta compression and size

- [ ] `--window=<n>` — Number of candidate objects considered for each delta base.
- [ ] `--depth=<n>` — Maximum delta chain depth.
- [ ] `--window-memory=<n>` — Memory ceiling that shrinks the delta window dynamically.
- [ ] `--max-pack-size=<n>` — Split output into multiple packs of at most this size.
- [ ] `--compression=<n>` — zlib compression level for newly compressed data.
- [ ] `--no-reuse-delta` — Recompute deltas rather than reusing those in existing packs.
- [ ] `--no-reuse-object` — Recompress every object from scratch.
- [ ] `--delta-base-offset` — *(core)* Use offset deltas rather than full object-name base references.
- [ ] `--threads=<n>` — Number of delta-search threads.
- [ ] `--sparse` / `--no-sparse` — Use the sparse object-selection algorithm.
- [ ] `--delta-islands` — Restrict delta bases to within configured islands.
- [ ] `--name-hash-version=<n>` — Choose the path-similarity hash used to group delta candidates.
- [ ] `--path-walk` — Group objects by path before delta compression.
- [ ] `--index-version=<version>[,<offset>]` — Test-only: force the pack index version.

### Transport-oriented options

- [ ] `--thin` — *(core for push/fetch)* Omit objects the receiver is known to have, producing a thin pack.
- [ ] `--shallow` — Optimize the pack for a client with a shallow history.
- [ ] `--incremental` — Skip objects already present in any local pack.
- [ ] `--local` — Skip objects borrowed from alternate object stores.
- [ ] `--honor-pack-keep` — Skip objects that live in a `.keep`-marked pack.
- [ ] `--keep-pack=<pack-name>` — Skip objects from a named pack; repeatable.
- [ ] `--keep-true-parents` — Pack parents hidden by grafts.

### Unreachable object handling (used by `gc`/`repack`)

- [ ] `--cruft` — Write unreachable objects into a cruft pack with an `.mtimes` file.
- [ ] `--cruft-expiration=<approxidate>` — Drop cruft objects older than a time.
- [ ] `--keep-unreachable` — Add unreachable objects to the pack rather than dropping them.
- [ ] `--pack-loose-unreachable` — Pack unreachable loose objects and remove the loose copies.
- [ ] `--unpack-unreachable` — Explode unreachable objects back to loose form.

### Progress

- [ ] `--progress` — Report progress on stderr.
- [ ] `--all-progress` — Also report progress during the write phase with `--stdout`.
- [ ] `--all-progress-implied` — Imply `--all-progress` whenever progress is shown.
- [x] `-q` — Suppress progress reporting.

## `prune-packed` — remove loose objects already in packs

> **CUT from v1** — `gc` does this internally.

- [ ] `-n` / `--dry-run` — Report what would be removed without removing it.
- [ ] `-q` / `--quiet` — Suppress the progress indicator.

## `read-tree` — load trees into the index

- [x] `<tree-ish>…` — *(core)* One, two, or three trees to read.
- [x] `-m` — *(core)* Perform a merge rather than a plain read.
- [x] `--reset` — As `-m`, discarding unmerged entries instead of failing.
- [x] `-u` — *(core)* Update the working tree to match the resulting index.
- [ ] `-i` — Merge without requiring the working tree to be up to date.
- [ ] `-n` / `--dry-run` — Check whether the operation would succeed, changing nothing.
- [ ] `--trivial` — Only resolve merges that require no file-level merging.
- [ ] `--aggressive` — Resolve more cases automatically than the default trivial rules.
- [ ] `--prefix=<prefix>` — Read the tree in under a subdirectory, keeping existing entries.
- [ ] `--index-output=<file>` — Write the resulting index to a different file.
- [ ] `--recurse-submodules` / `--no-recurse-submodules` — Update submodule working trees as well.
- [ ] `--no-sparse-checkout` — Ignore sparse-checkout patterns.
- [x] `--empty` — Empty the index instead of reading a tree.
- [ ] `-v` — Show progress while checking files out.
- [ ] `-q` / `--quiet` — Suppress feedback messages.

## `replay` — rebase in the object database `[experimental]`

> **CUT from v1** — experimental upstream.

- [ ] `<revision-range>` — *(core)* Commits to replay.
- [ ] `--onto=<newbase>` — Replay onto an arbitrary commit.
- [ ] `--advance=<branch>` — Replay onto a branch, advancing it.
- [ ] `--revert=<branch>` — Replay reversed commits onto a branch.
- [ ] `--contained` — Update every branch pointing into the replayed range (requires `--onto`).
- [ ] `--ref=<ref>` — Override which fully-qualified ref receives the result.
- [ ] `--ref-action[=<mode>]` — Choose how the resulting refs are updated.
- [ ] *rev-list options* — see `04`.

`replay` is notable for gittle: it performs a rebase with no index and no
working tree, which is the smallest possible implementation of history
rewriting.

## `symbolic-ref` — read and write symbolic refs

- [x] `<name> [<ref>]` — *(core)* The symbolic ref to read, or to point at `<ref>`.
- [x] `-d` / `--delete` — Delete the symbolic ref.
- [x] `--short` — Print the shortened form of the target ref.
- [ ] `--recurse` / `--no-recurse` — Follow chains of symbolic refs to the end.
- [ ] `-m <reason>` — Record a reflog entry for the update.
- [x] `-q` / `--quiet` — Do not error when the ref is not symbolic.

## `unpack-objects` — explode a packfile into loose objects

> **CUT from v1** — `index-pack` handles every received pack.

- [ ] `-n` — Dry run: verify the pack without writing objects.
- [ ] `-q` — Suppress the progress percentage.
- [ ] `-r` — Recover as much as possible from a corrupt pack instead of dying.
- [ ] `--strict` — Refuse to write objects with broken content or links.
- [ ] `--max-input-size=<size>` — Refuse packs larger than a size.

## `update-index` — modify the index

### Adding, removing, and refreshing

- [x] `<file>…` — *(core)* Paths to act on.
- [x] `--add` — *(core)* Add paths not already in the index.
- [x] `--remove` — *(core)* Remove index entries whose files are gone.
- [ ] `--force-remove` — Remove the entry even if the file still exists (implies `--remove`).
- [ ] `--replace` — Allow replacing a file entry with a directory entry and vice versa.
- [x] `--refresh` — *(core)* Re-stat tracked files and update cached stat information.
- [ ] `--really-refresh` — Re-stat unconditionally, ignoring assume-unchanged.
- [ ] `-g` / `--again` — Re-run over paths whose index entry differs from HEAD.
- [ ] `--unresolve` — Restore the unmerged state of a path.
- [x] `--cacheinfo <mode>,<object>,<path>` — *(core)* Insert an entry directly, without touching the working tree.
- [ ] `--index-info` — Read a stream of index entries from standard input.
- [ ] `--info-only` — Record object names without writing the objects.
- [ ] `--chmod=(+|-)x` — Set or clear the executable bit on the given entries.
- [x] `--stdin` — Read the path list from standard input.
- [x] `-z` — Treat `--stdin`/`--index-info` input as NUL-separated.
- [x] `--` — End option parsing.

### Per-entry flags

- [ ] `--assume-unchanged` / `--no-assume-unchanged` — Promise (or stop promising) that a path will not change.
- [ ] `--skip-worktree` / `--no-skip-worktree` — Mark entries as index-only, for sparse checkout.
- [ ] `--ignore-skip-worktree-entries` / `--no-ignore-skip-worktree-entries` — Control removal of skip-worktree entries.
- [ ] `--fsmonitor-valid` / `--no-fsmonitor-valid` — Set or clear the fsmonitor-valid bit.

### Refresh behavior and index format

- [ ] `-q` — With `--refresh`, do not error when the index needs updating.
- [ ] `--unmerged` — With `--refresh`, tolerate unmerged entries.
- [ ] `--ignore-missing` — With `--refresh`, ignore paths missing from the working tree.
- [ ] `--ignore-submodules` — Do not update submodule entries during `--refresh`.
- [ ] `--index-version <n>` — Write the index in on-disk format version 2, 3, or 4.
- [ ] `--show-index-version` — Print the current on-disk index format version.
- [ ] `--split-index` / `--no-split-index` — Enable or disable split-index mode.
- [ ] `--untracked-cache` / `--no-untracked-cache` — Enable or disable the untracked cache.
- [ ] `--test-untracked-cache` — Check whether the untracked cache would work here.
- [ ] `--force-untracked-cache` — Legacy synonym for `--untracked-cache`.
- [ ] `--fsmonitor` / `--no-fsmonitor` — Enable or disable the filesystem monitor extension.
- [ ] `--verbose` — Report each addition and removal.

## `update-ref` — create, update, and delete refs

Documented in prose rather than an OPTIONS section; the full surface is:

- [x] `<ref> <new-oid> [<old-oid>]` — *(core)* Set a ref, optionally requiring its current value.
- [x] `-d <ref> [<old-oid>]` — *(core)* Delete a ref, optionally requiring its current value.
- [x] `--stdin` — *(core)* Read a transaction of commands (`update`, `create`, `delete`, `verify`, `option`, `symref-*`, `start`, `prepare`, `commit`, `abort`) from standard input.
- [x] `-z` — Treat the `--stdin` command stream as NUL-separated.
- [ ] `--batch-updates` — Apply as many updates as possible instead of failing the whole batch.
- [ ] `--create-reflog` — Create a reflog for the ref even where reflogs are off by default.
- [ ] `--no-deref` — Update the symbolic ref itself rather than what it points at.
- [x] `-m <reason>` — Record a reason in the reflog entry.

## `write-tree` — write the index out as a tree

- [ ] `--missing-ok` — Do not verify that referenced objects exist.
- [ ] `--prefix=<prefix>/` — Write the tree for a subdirectory of the index.
