# gittle

A minimal git in Nim: small enough to read in an afternoon, compatible enough to
share a repository with real git, and plausible in a busybox-class environment.

- **On-disk compatible.** A gittle repository *is* a git repository. Real git
  and gittle operate on the same working tree, in any order, without either
  noticing.
- **44 commands**, covering the daily loop for a human or an agent — from
  `init` and `add` through `merge`, `rebase`, `stash` and `worktree` to
  `clone`, `fetch` and `push`.
- **A transport client, not a server**: gittle clones from, fetches from and
  pushes to an ordinary git host over ssh; it does not host one.
- **One static binary**, busybox-style `argv[0]` dispatch, ~3.2 MB.
- **11,124 lines of Nim** across 79 files, every function documented — plus
  6,867 lines of comment, which do not count against the budget, because
  being readable was the point.
- **Two runtime dependencies**: zlib, linked, and `diff(1)` on `PATH` — the
  edit script comes from the `diff` every Unix has, gittle does the rest.

## Why

git is about 313,000 lines of C, and where that bulk sits is the whole
argument for this project. A third of it is the command layer — options and
output formatting. Most of the rest is caches, accelerators and twenty years
of backward compatibility. The *irreducible* algorithms are small: applying a
delta is 94 lines, a file-level three-way merge is 526, the Myers core is
1,123.

So a git that reads and writes the same bytes, over the same wire, is not a
313,000-line problem. It is a scope problem. gittle is the experiment of
choosing that scope deliberately, in the open, and writing down every cut:

1. **Cover typical usage — for humans and for agents.** Not a teaching toy and
   not a subset chosen for implementation convenience. The scope was drawn
   from 509 real `git` invocations in two projects' agent tool-call logs
   (`docs/git-tool-calls-*.md`), and re-measured against them during
   minimisation.
2. **Small enough to read in an afternoon.** ~10 kloc was the sketch. It is a
   *measurement*, not a cap: the point is that the whole scope fits in one
   person's head, and the line count is how that gets checked.
3. **Full on-disk compatibility.** Object IDs are hashes of exact bytes, so
   "read liberally, write byte-exactly" is the one place ruthlessness stops. A
   merge gittle stopped is concluded by `git commit`; a cherry-pick git
   stopped is continued by `gittle cherry-pick --continue`.
4. **One of everything.** One hash (SHA-1), one ref backend (`files`), one
   diff algorithm, one merge strategy, one transport, one wire protocol
   version. When a second is tempting, it is scope, not a refactor.
5. **A single static binary** for a small or embedded system, with no runtime
   interpreter and no package manager.

The design rules that follow from those goals, with their reasoning, are in
[`docs/plan.md`](docs/plan.md) §3; the per-command scope selections are in
`docs/01`–`docs/15`.

## Status

**v1 is feature-complete, and has been through two minimisation passes.**
`tests/oracle.sh` is green — **175 checks passed, 0 failed** — and those
checks are differential: the same input goes through real git and through
gittle, and the comparison is not only stdout but every ref, reflog, config
entry, index entry, object, packed state, in-progress marker and working-tree
file either tool wrote. A `checkout` that prints the right thing and leaves
the wrong index is the failure worth catching, and that is where nine of one
phase's eleven bugs were found.

| | |
|---|---:|
| commands | 44 |
| lines of code (non-blank, non-comment) | 11,124 |
| of which engine (`src/*.nim`, 39 files) | 6,996 |
| of which commands (`src/cmd/*.nim`, 40 files) | 4,128 |
| oracle checks | 175 |
| binary, dynamic / static | 2.3 MB / 3.2 MB |

The history: 13,872 lines at feature-complete, 11,724 after the first
minimisation pass ([`docs/minimize.md`](docs/minimize.md)), 11,124 after the
second ([`docs/minimize-2.md`](docs/minimize-2.md)). Both documents record
what was cut, why, and what each cut cost — including the estimates that were
wrong and the reason they were wrong.

## Installing

Nim 2.x and the system zlib to build; a `diff` on `PATH` at run time
(busybox's is enough). No package manager, no other dependency.

```sh
git clone <this repository>
cd gittle

nim c -d:release --out:build/gittle src/gittle.nim            # links libz
nim c -d:release -d:static --out:build/gittle src/gittle.nim  # one static binary
```

`nim c` is used directly rather than `nimble`; `gittle.nimble` is metadata,
and `nim.cfg` carries the build settings (`--path:src`, `-lz`, and `-static`
under `-d:static`).

Install by copying the binary anywhere on `PATH`:

```sh
install -m 755 build/gittle ~/.local/bin/gittle
```

`main` looks at `basename(argv[0])` first, busybox-style, so two other
spellings work:

```sh
ln -s gittle ~/.local/bin/git         # a drop-in `git` on PATH
ln -s gittle ~/.local/bin/git-log     # `git-<verb>` dispatches straight to <verb>
```

### Testing

```sh
tests/oracle.sh          # differential tests against real git, sampled
tests/oracle.sh --full   # ... plus every object, commit and tag in the reference repository
```

The tests want a `git` **built from the git checkout that sits above this
directory**, because the installed one may be years older than the tree it is
being asked to explain; `oracle.sh` finds it and puts it on `PATH`, which is
also how `git-upload-pack` and `git-receive-pack` resolve for the transport
tests. No test contacts a network.

They also hand git the options that select the behavior gittle deliberately
does not implement — `--no-renames`, `--minimal`, `--diff-merges=off`,
`--no-use-mailmap`, `--diff-algorithm=minimal`, `advice.statusHints=false` —
so each divergence below is *tested* rather than merely absent.

## What is supported

44 commands. Every option each one takes is in `gittle <command> -h`, which is
generated from the same table the parser reads, so a command cannot document
an option it does not have.

| Area | Commands | Notes |
|---|---|---|
| Repository | `init`, `clone`, `config` | `--bare`, `-b <branch>`; `config` in `list`/`get`/`set`/`unset` form, local, global or a named file |
| Staging | `add` (`stage`), `rm`, `mv`, `restore`, `reset` | pathspecs with `literal`, `glob`, `icase`, `top` and `exclude` magic; `reset --soft/--mixed/--hard` |
| Inspection | `status`, `diff`, `log`, `show`, `grep`, `reflog` | `status` in long, `-s`, `--porcelain=v1` and `v2` forms; `diff` as patch, `--stat`, `--numstat`, `--raw`, `--name-only`, `--name-status`, `-z`, `-U<n>`, `-S`, `--diff-filter`; `--color` on all of them |
| History | `rev-list`, `rev-parse`, `merge-base`, `for-each-ref`, `cat-file`, `ls-tree`, `ls-files`, `hash-object`, `write-tree` | `--topo-order`, `--date-order`, `--reverse`, `--first-parent`, `--left-right`, `--objects`, `--grep`/`--author`, `--since`/`--until` (ISO dates), `--pretty=<format>` including `format:<fmt>` |
| Branches | `branch`, `checkout`, `switch`, `tag`, `update-ref` | create, delete, rename, list, `--contains`; upstream tracking via `-t`, reported by `branch -vv` and `status` |
| Merging | `merge`, `merge-file`, `cherry-pick`, `revert`, `rebase`, `stash` | one three-way strategy, recursive over multiple merge bases, byte-identical conflict markers; `merge`, `cherry-pick`, `revert` and `rebase` stop, resume and abort through the same on-disk sequencer state, interchangeably with git's |
| Remotes | `remote`, `fetch`, `pull`, `push` | ssh and local-path URLs, protocol v0; refspecs, `--force`, `--force-with-lease`, `--prune`, `--tags`, `-u`, `--dry-run`, delete-by-refspec |
| Working trees | `worktree` | `add`, `list`, `move`, `remove`, `prune`; a branch is checked out in at most one worktree, enforced across `worktree`, `checkout`, `switch` and `branch` |
| Housekeeping | `gc`, `clean`, `check-ignore` | `clean -x` means "as if there were no ignore files", not "delete ignored files too"; `gc` is a fetch with chosen haves — the remote's `pack-objects` sends this repository's own history back as one properly deltified pack — so it is additive, never prunes, and runs by hand or on its own at the end of a push once `gc.auto` loose objects have piled up |

And the engine underneath them:

| | |
|---|---|
| Objects | loose and packed; packfile v2 read and write, thin packs resolved, OFS and REF deltas, full validation on receipt (pack checksum, then every object's own hash, then connectivity — no ref moves until all three pass) |
| Packing | deltas are **reused, never searched for**: on this repository, existing deltas copied through give 309 MiB against git's searched 304 MiB, in 2.4 seconds |
| Index | reads v2, v3 and v4; writes v2, or v3 when an entry needs extended flags — git's own rule. Handles racily-clean entries and `index.skipHash`'s zeroed checksum |
| Refs | the `files` backend: loose refs, `packed-refs`, symrefs, reflogs, `HEAD` in a linked worktree |
| Revisions | `HEAD~3`, `A^2`, `v1.0^{}`, `A..B`, `A...B`, `A^!`, `A^@`, `tree:path`, `:0:path`, `@{upstream}`, `stash@{2}` |
| Ignore | `.gitignore` at every level, `info/exclude`, `core.excludesFile`, with git's negation, anchoring, basename and precedence rules |
| Hooks | `pre-commit` and `commit-msg`, honoring `core.hooksPath`; `--no-verify` bypasses both |
| Config | the `.gitconfig` format, multi-valued keys included (`include.path` and `includeIf` are not); `core.bare`, `core.editor`, `core.excludesFile`, `core.hooksPath`, `core.logAllRefUpdates`, `user.name`, `user.email`, `init.defaultBranch`, `pull.rebase`, `branch.autoSetupMerge`, `remote.pushDefault`, `clean.requireForce`, `gc.auto`, `status.relativePaths`, `advice.*` |
| Extensions | a general gate: an unknown `extensions.*` key, or a value gittle cannot honor, refuses the repository by name rather than corrupting it, which is what the format specification requires |

## What is not supported

The large omissions, each a deliberate decision with its reasoning recorded.
An option that was cut **refuses by name** rather than being silently ignored,
and the oracle asserts that it does.

| Not supported | Why, and where it is written down |
|---|---|
| **Serving** — `upload-pack`, `receive-pack`, `git-shell` | Built through phase 6, then cut: without whole-pack reuse a clone from a gittle host is ~10× the bytes, and that is a piece of work that comes back whole or not at all. plan.md §6 decision 2 |
| **`http://`, `https://`, `git://`** | One transport: a program with a pipe on each end. ssh and a local path are the same code with the prefix removed. Refused by name |
| **Shallow and partial clone** — `--depth`, `--filter`, promisor remotes | Every object must be present; `extensions.partialClone` refuses the repository |
| **SHA-256, and the `reftable` backend** | One hash, one ref backend (plan.md R4). Both refuse at the extension gate, `reftable` with the `git refs migrate` command that fixes it |
| **Submodules** | Refused at the gate; a whole second repository model |
| **Rename and copy detection** — `-M`, `-C` | ~2,000 lines of C for a similarity matrix. A rename shows as a delete and an add; the tests pass git `--no-renames` so the difference is compared, not hidden |
| **Patch workflows** — `apply`, `am`, `format-patch`, `send-email` | First item of the v2 backlog: `apply` unlocks the rest |
| **`blame`, `bisect`, `describe`, `shortlog`, `log --graph`** | Each is an engine behind one command. v2 backlog |
| **Interactive anything** — `add -p`/`-i`, `rebase -i`, `difftool`, `mergetool`, GUIs | R6: no subsystem that exists to serve one option |
| **Combined diffs for merges** — `-c`, `--cc` | `log`/`show` print a merge with no diff, which is `--diff-merges=off` |
| **Other merge strategies** — octopus, `resolve`, `-X` options | One strategy, which refuses rather than guessing on any structural ambiguity (plan.md R5) |
| **gitattributes** — textconv, clean/smudge filters, merge drivers, `eol`/`autocrlf` | Bytes go in and out unchanged |
| **Signing and verification** — GPG, ssh signatures | Out of scope; `-s`/`--verify` refuse by name |
| **Sparse checkout, sparse index** | An accelerator for repositories larger than gittle targets |
| **All caches** — commit-graph, multi-pack-index, bitmaps, `.rev`, untracked cache, fsmonitor, split index | R3: every one is optional. gittle never reads and never writes them, and their presence must not confuse it — which costs nothing, since they live in files it does not open |
| **Delta search** — the window/depth machinery | R2: reuse the deltas that exist, never search for new ones. See the measurement above |
| **Most hooks** | Only `pre-commit` and `commit-msg` fire. A hook that never runs is safer than one that runs at the wrong moment |
| **Approxidate** — `--since="2 weeks ago"`, `main@{2 weeks ago}` | A parser of English behind one spelling. ISO-8601 dates only |
| **Revision spellings** `:/text`, `^{/regex}`, `@{-1}`, `@{push}` | Zero uses across the 509 logged invocations; each is a second walk or a second model. They refuse loudly rather than being reinterpreted as a path |
| **`--date=relative`** | Cut in the first minimisation pass |
| **Notes, replace, bundle, archive, filter-branch, maintenance** | Not in the daily loop |
| **Unshipped plumbing** — `update-index`, `read-tree`, `symbolic-ref`, `ls-remote`, `commit-tree`, `pack-objects`, `index-pack`, and never-in-scope `fsck`, `repack`, `prune`, `count-objects`, `show-ref`, `name-rev`, `verify-pack` | The first seven were command-line wrappers over engines that stayed; nothing called them, so ~706 lines came out in the first minimisation pass. `rev-parse`, `for-each-ref`, `cat-file`, `ls-tree`, `ls-files` and `write-tree` cover what the logs actually type |
| **Foreign SCM bridges** — `svn`, `p4`, `cvs*` | Not in scope at any point |
| **A pager, and credential helpers** | gittle never pages; ssh does the authentication |

### Three things that are deliberately not byte-identical

Everything a script reads — `--short`, `--porcelain`, `--name-only`,
`--numstat`, `--format` — is byte-exact. Three things a human reads are not:

1. **Diff hunks may sit elsewhere than git's** on a few percent of files. The
   edit script comes from `diff(1)` and is minimal; git additionally applies an
   indent heuristic that slides an ambiguous hunk. Both are correct patches for
   the same change, so the oracle compares them by *applying* them and by
   `--numstat` counts rather than byte-for-byte.
2. **`status` prints no `(use "git …")` advice**, and there are no `hint:`
   paragraphs anywhere.
3. **gittle says `gittle`** where git says `git`.

## Layout

```
docs/     the scope inventory (01-15), the plan, the phase notes, the
          minimisation records, and the raw tool-call logs the scope came from
src/      the engine (39 modules)
src/cmd/  one module per command (40)
tests/    oracle.sh, the differential suite; selftest.nim for the pure engines
```

Start with [`docs/plan.md`](docs/plan.md): the goals, the eight design rules
with their reasoning, the scope with its rationale, the budget, and a decision
record. [`docs/README.md`](docs/README.md) indexes the rest.

## What is next

The v2 backlog, in the order it would be restored (plan.md §8): `apply` — which
unlocks patch workflows and `am` — then `blame`, `log --graph`, `bisect`,
`add -p`, rename detection, `describe`, `shortlog`, and reftable read support.
And, from v1's own scope, **serving**: `upload-pack`, `receive-pack` and
`git-shell` with whole-pack reuse, as one piece.

## License

MIT, as declared in `gittle.nimble`.
