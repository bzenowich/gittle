# gittle — project plan

A minimal git in Nim: small enough to read in an afternoon, compatible enough to
share a repository with real git, and plausible in a busybox-class environment.

Status: **scoping.** No code yet. This document records the goals, the design
rules that follow from them, and a recommended starting scope. The per-command
selections live in `01`–`15`; this file explains *why* they are what they are.

---

## 1. Goals

1. **Cover typical usage — for both humans and agents.** Not a teaching toy, not
   a subset chosen for implementation convenience. The daily loop has to work.
2. **Stay under ~10 kloc of Nim.** The scope must fit in one person's head.
3. **Full on-disk compatibility.** A gittle repository *is* a git repository.
   Real git and gittle must be able to operate on the same working tree, in any
   order, without either noticing.
4. **ssh-only remotes**, speaking enough of the git wire protocol to talk to an
   ordinary git server — GitHub, gitolite, a plain `sshd` with git installed.
5. **Single static binary**, no runtime interpreter, no external tooling.

### Non-goals

Rewriting history beyond `rebase`/`revert`, email
workflows, foreign SCM interop, GUIs, partial/shallow clone, submodules,
signing, and every accelerator git maintains for repositories far larger than
the ones gittle targets.

---

## 2. Where git's bulk actually is

Measured from the git tree beside this directory (`v2.55.0-782-g1630431f32`):

| | lines of C |
|---|---:|
| `builtin/*.c` — the command layer | 97,704 |
| everything else | ~215,000 |
| Apply a delta (`patch-delta.c`) | **94** |
| Create a delta (`diff-delta.c`) | 510 |
| File-level 3-way merge (`merge-ll.c`) | 526 |
| Tree-level 3-way merge (`merge-ort.c`) | 5,608 |
| Myers core (`xdiffi.c`) | 1,123 |
| patience + histogram | 741 |

Two conclusions drive everything below. **First, a third of git is the command
layer** — options and output formatting — which is exactly what the selection
files control. **Second, the irreducible algorithms are small.** The bulk around
them is option surface, caches, and backward compatibility, all of which are
optional for us.

---

## 3. Design rules

These are the rules that make the budget work. Each one is a decision that costs
capability and buys a large amount of code.

**R1 — Read liberally, write minimally, write byte-exactly.**
The read side must tolerate everything real git produces. The write side emits
one format per artifact and must be byte-perfect: object IDs are hashes of exact
bytes, so a commit header formatted even slightly differently produces a
different OID and silently forks the repository. This is the one place where
ruthlessness stops.

**R2 — Never *search* for deltas; always *reuse* the ones you already have.**
Measured on this repository (420,113 objects, §3.1 below): git's pack is 304 MiB,
the same objects with no deltas at all are **3,122 MiB**, and the same objects
with existing deltas copied through but no similarity search are **309 MiB,
produced in 2.4 seconds**. Delta *search* — the window/depth machinery, ~7k
lines of C — buys almost nothing over delta *reuse*, which is a few hundred
lines: read a delta object's bytes and its base reference, and copy them
through. gittle therefore creates no deltas and discards none.

The one subtlety is that `ofs-delta` encodes its base as a *relative* offset, so
copying into a pack with a different layout invalidates it. Rewrite reused
deltas as `ref-delta` (a 20-byte base OID, position-independent) rather than
trying to preserve ordering.

Reuse is near-perfect when packing everything and degrades when packing a
subset, because a delta whose base falls outside the pack must be expanded. Both
regimes are quantified in §3.1.

**R3 — All caches are optional; ignore them.**
commit-graph, multi-pack-index, pack bitmaps, `.rev`, untracked cache,
fsmonitor, split index — every one is an accelerator. v1 never reads and never
writes any of them. Their presence in a repository must not confuse us, which
costs nothing because they live in files we simply don't open.

**R4 — One of everything.**
One diff algorithm (Myers). One hash (SHA-1). One ref backend (`files`). One
index version on write (v2, or v3 when extended flags are needed — matching
git's own rule). One merge strategy. One transport (ssh, plus a direct
object-store copy for local paths).

**R5 — A tree merge that refuses rather than resolves.**
The 526 → 5,608 line jump between file-level and tree-level merging is almost
entirely rename detection, directory renames, and D/F conflict handling. v1 does
content merges and declares a conflict on any structural ambiguity. Refusing to
guess is a defensible behavior for a small tool.

**R6 — No subsystem that exists to serve one option.**
Interactive add (`-p`/`-i`), rename detection (`-M`/`-C`), line-history (`-L`),
approxidate (`--since="2 weeks ago"`), textconv, gitattributes filters. Each is
a self-contained engine behind a single flag.

---

### 3.1 What R2 costs, measured

All figures from the git repository beside this one, `v2.55.0-782-g1630431f32`,
420,113 objects. "raw" is uncompressed object bytes; every pack representation
below is additionally zlib-deflated.

| Representation | Size | vs. raw |
|---|---:|---:|
| Raw uncompressed objects | 7,902.7 MiB | 1.0x |
| zlib only, no deltas anywhere | 3,122.0 MiB | 2.5x |
| Existing deltas reused, no search (**R2**) | 309.1 MiB | 25.6x |
| git's actual pack, full delta search | 303.9 MiB | 26.0x |

The delta layer is worth ~10x on top of zlib, and **reuse captures all but 1.7%
of it**. By object type, trees are the extreme: 2,462.9 MiB raw compresses to
55.4 MiB of tree deltas, because each tree differs from its parent by one entry.

Producing them, same object set: reuse 2.4s, no-deltas 3m54s (it must re-deflate
7.7 GiB), full search several minutes. R2 is *faster* than storing full objects.

**Where reuse does not help: pushing new work.** Objects you just created have
no delta to reuse, and git would build a thin pack against what the server
already has. Non-thin, undeltified, versus what git actually sends:

| Push size | git (thin) | gittle (R2) | Ratio |
|---|---:|---:|---:|
| 1 commit | 1.5 KB | 50 KB | 32x |
| 10 commits | 120 KB | 3.2 MB | 27x |
| 100 commits | 1.1 MB | 26 MB | 24x |
| 1000 commits | 11 MB | 224 MB | 21x |

The ratio is worst when the absolute cost is trivial. Ordinary pushes are
unaffected in any way a user would notice; the case to watch is a first push of
imported history, where a 20x multiplier on hundreds of megabytes is real.

**Reproducing these figures.** Run from a checkout of git with a single
packfile; `$G` is the repository under measurement.

```sh
G="git -C /home/bz/code/git"
$G rev-list --objects --all | awk '{print $1}' > objlist.txt   # 420,113 oids

# raw uncompressed total (NB: verify-pack's size column reports DELTA sizes
# for deltified objects, so it cannot be summed for this -- use cat-file)
awk '{print $1}' objlist.txt \
  | $G cat-file --batch-check='%(objectsize)' \
  | awk '{s+=$1} END{printf "%.1f MiB\n", s/1048576}'

$G pack-objects --stdout --window=0 --no-reuse-delta < objlist.txt | wc -c  # no deltas
$G pack-objects --stdout --window=0                  < objlist.txt | wc -c  # reuse only
ls -l .git/objects/pack/*.pack                                              # git's own

# push sizes: thin (what git sends) vs undeltified (what gittle sends)
printf 'HEAD\n^HEAD~100\n' | $G pack-objects --stdout --thin --revs | wc -c
printf 'HEAD\n^HEAD~100\n' | $G pack-objects --stdout --revs --window=0 --no-reuse-delta | wc -c
```

`--window=0` disables delta *search* while leaving reuse on; adding
`--no-reuse-delta` disables reuse as well. That pair is what separates the two
middle rows of the table above, and it is the whole of R2 in one flag.

**Unaffected entirely:** `clone` and `fetch` as a client. The server builds
those packs, gittle only applies the deltas — 94 lines.

**R2a — `gc` must be additive.** Never repack everything. Pack loose objects
into a new pack and leave inherited packs alone. The pack a server sent at clone
time is optimally deltified; rewriting it is the one action that would turn a
304 MiB repository into a 3 GiB one. Real `git gc`, if ever run in the same
repository, restores full optimality — gittle must never undo it.

**R2b — serving a full clone should reuse whole packs.** When `upload-pack` is
asked for everything a pack contains, stream that pack's bytes rather than
re-emitting objects. This is what git's `pack.allowPackReuse` does, and without
it a clone from a gittle host costs 10x.

## 4. Recommended v1 scope

**56 of 161 commands; 450 of 2,341 option entries (19%).** The option figure
includes positional arguments (`<pathspec>`, `<commit>`), so the true "flag"
fraction is nearer 12%.

### Commands in v1

| Group | Commands |
|---|---|
| Create | `init` `clone` |
| Inspect | `status` `log` `show` `diff` `grep` |
| Modify | `add` `stage` `rm` `mv` `restore` `reset` `clean` |
| Commit | `commit` `tag` `stash` |
| Branch | `branch` `checkout` `switch` `merge` `cherry-pick` `revert` `rebase` `worktree` |
| Remote (client) | `fetch` `push` `pull` `remote` `ls-remote` |
| Remote (server) | `upload-pack` `receive-pack` `shell` |
| Config/admin | `config` `gc` `reflog` `help` `version` |
| Plumbing (read) | `cat-file` `ls-files` `ls-tree` `rev-parse` `rev-list` `merge-base` `for-each-ref` `check-ignore` |
| Plumbing (write) | `hash-object` `update-ref` `symbolic-ref` `update-index` `read-tree` `write-tree` `commit-tree` `merge-file` `index-pack` `pack-objects` |

The plumbing set is nearly free — each command is 20–40 lines of argument
parsing over an engine that must exist anyway — and it makes the whole thing
testable from a shell script without a test harness.

### The big cuts, and what each buys

| Cut | Buys | Cost to the user |
|---|---|---|
| `apply` / `am` / `format-patch` | ~5.3k C | No patch-file workflow. **Largest deferred item.** |
| `blame` / `annotate` | ~2.9k C | Line archaeology. Most likely to be missed. |
| `rebase -i`, `--exec`, `--autosquash` | ~7.3k C | Non-interactive `rebase` stays. |
| `add -p` / `add -i` | ~3.3k C | No hunk-level staging. |
| Rename detection (`-M`/`-C`) | ~2.0k C | Renames show as delete+add; merges conflict more often. |
| `log --graph` | ~1.6k C | No ASCII history graph. |
| reftable backend | ~7.1k C | Cannot open a reftable repo at all — see §6. |
| Delta *search* (R2) | ~7.0k C | Pushes of new work are ~20x larger; everything else within 2% of git. |
| Submodules | ~3.8k C | Nested repositories unsupported. |
| Foreign SCM + email (`14`) | — | All Perl/Python upstream; impossible anyway. |
| Hooks other than `pre-commit`/`commit-msg` | small, but wide | `pre-push`, `post-*`, `update`, `prepare-commit-msg` never fire. |

### Evidence check

Of the 177 option entries observed in the agent tool-call logs, **v1 covers
169**. The eight it does not are `apply`, `merge-tree --write-tree`,
`submodule status`, and `log -L` — findable with:

```sh
grep -n '^- \[ \].*`\[log\]`' *.md
```

That the recommended scope covers 95% of two projects' real usage without being
fitted to it is the strongest evidence available that the cut is in the right
place. It is also a weak sample: two repositories, one operator, agent-heavy,
with no `bisect`, no `add -p`, and one `cherry-pick`. Treat it as a floor.

---

## 5. Budget

A sketch, not an estimate. Each figure is Nim, simplified per §3.

```
object store: loose r/w, pack + idx read, delta apply         800
index v2/v3 read/write                                        400
refs: loose + packed-refs                                     300
config: flat INI subset                                       150
object parse/format: commit, tree, tag                        300
revision walk                                                 250
diff: Myers + unified emit                                    500
pathspec + ignore matching                                    400
working tree: checkout, status                                600
merge: file 3-way + structural tree merge                     600
wire protocol v2 over ssh: ls-refs, fetch, push               700
pack write + delta reuse                                      500
regex engine (ERE subset)                                     500
command dispatch, arg parsing, 53 commands                  2,000
support: sha1, zlib glue, paths, errors, tempfiles            400
hooks: pre-commit + commit-msg                                 60
serving: upload-pack + receive-pack                           400
git-shell + argv[0] dispatch                                   80
index v4 read                                                  30
repository extension gate + worktree config                    60
                                                          -------
                                                            9,030
```

The line that will blow the budget is the second-to-last. Every algorithm above
it is bounded; the command layer scales with how many option combinations are
accepted, which is why it is 28% of git. **Guard that number above all others.**

---

## 6. Decisions

All resolved (2026-09-01). Nothing in the scope is still open.

| # | Question | Decision |
|---|---|---|
| 1 | Hooks | **Run `pre-commit` and `commit-msg`.** ~60 lines of fork/exec; `commit --no-verify` bypasses. No other hook fires. |
| 2 | Serving repositories | **In scope for v1.** Ship `upload-pack` and `receive-pack`. |
| 3 | Regex engine | **Vendor a ~500-line ERE engine.** No PCRE; `grep -P` and `log -P` stay cut. |
| 4 | zlib | **Link the system zlib.** The one external dependency. |
| 5 | SHA-1 | **Plain SHA-1**, ~150 lines. Not sha1dc — see the risk note below. |
| 6 | CRLF / gitattributes | **Linux only.** No `core.autocrlf`, no `text=auto`, no filters. |
| 7 | reftable | **Refuse with a clear message.** Detected through a general repository-extension gate — see §6.1. |
| 8 | `index.version=4` | **Read support in v1.** ~30 lines, reusing the ofs-delta varint. Writing stays v2/v3. |
| 9 | Binary dispatch | **`argv[0]` dispatch**, busybox-style, with `git-*` symlinks. |
| 10 | `git-shell` | **In scope for v1.** Restricted login shell permitting only `upload-pack` and `receive-pack`. |

### Consequences worth stating

**Serving.** The client sends the literal command `git-upload-pack '<path>'` over
ssh, so the serving host needs binaries by those names on `PATH`. gittle should
dispatch on `argv[0]` and install `git-upload-pack` and `git-receive-pack` as
symlinks, busybox-style. Two follow-ons worth deciding:

* `git-shell` ships. Set it as the git user's login shell; it permits exactly
  `git-upload-pack` and `git-receive-pack` and rejects everything else,
  including interactive login. gittle's whitelist is shorter than git's, which
  also permits `git-upload-archive` — `archive` is cut, so that verb is refused.
* `receive-pack` is the one place gittle accepts a packfile from an untrusted
  peer. `index-pack` must validate the pack checksum, every object's own hash,
  and connectivity of the resulting refs before any ref is updated. This is the
  main security surface of the project.

**Plain SHA-1.** Sufficient for compatibility: object IDs will match git's for
identical content. The loss is git's sha1dc hardening, which detects the
known collision-attack patterns and refuses. gittle will happily store a
collision pair that git rejects. Acceptable for a local tool; note it if gittle
ever serves untrusted pushes on a public network.

**No gitattributes.** Beyond CRLF, this also means no `export-ignore`, no
`diff=<driver>`, no `merge=<driver>`, and no `binary` marking — binary detection
falls back to scanning for NUL bytes, which is what git does absent attributes.

### 6.1 reftable — decided: refuse, via a general extension gate

**Background.** Git 3.0 will make reftable the default for newly created
repositories (`Documentation/BreakingChanges.adoc`). No release date is set, and
git's own stated prerequisite is that JGit, libgit2 and Gitoxide support it
first — that ecosystem readiness is the early-warning signal to watch. Existing
`files` repositories are not affected and reftable is not the default today.

**Decision.** v1 refuses. Reading reftable is 600–800 lines of Nim (a
`tables.list` stack read newest-first, block-structured files with
prefix-compressed keys, restart offsets for binary search, and its own varint —
the same one gittle already needs for ofs-delta); writing, with geometric
compaction, is substantially more. That does not fit the budget for a format
nothing yet defaults to.

**Do not special-case it.** `Documentation/technical/repository-version.adoc` is
explicit: with `core.repositoryFormatVersion = 1`, an implementation that does
not understand a listed extension key *or its value* **MUST NOT** operate on the
repository. Refusing is the specified behavior, and implementing the general
rule costs about the same as hard-coding reftable while also handling SHA-256,
partial clone, and every extension git adds later.

The gate:

1. Read `core.repositoryFormatVersion`. Greater than 1 → refuse.
2. Honor `noop` and `preciousObjects` at any version — the spec says both are
   respected regardless of format version.
3. At version 1, walk every `extensions.*` key and refuse on anything not in the
   table below, or on a known key with an unknown value.

| Extension | v1 handling |
|---|---|
| `noop` | accept — no behavior change by definition |
| `preciousObjects` | accept, and make `gc` skip all deletion |
| `objectFormat` | accept `sha1`; refuse `sha256` |
| `compatObjectFormat` | refuse — dual-hash repositories |
| `refStorage` | accept `files`; refuse `reftable` |
| `worktreeConfig` | **accept** — read `$GIT_DIR/config.worktree` |
| `relativeWorktrees` | **accept** — resolve worktree gitdir paths relative |
| `partialClone` | refuse — no promisor remotes |
| `submodulePathConfig` | refuse — submodules are cut |

The two marked **accept** matter more than they look. A naive "refuse any
extension" gate would reject a perfectly ordinary repository merely because
someone once ran `git config --worktree` or
`git worktree add --relative-paths`. Both are a handful of lines to support and
neither changes any on-disk format.

**The message.** Refusal has to say what is wrong and what to do about it:

```
gittle: cannot operate on this repository
  extensions.refStorage = reftable
  gittle supports only the 'files' ref backend.
  Convert with real git:  git refs migrate --ref-format=files
  (that command cannot migrate a repository that has worktrees)
```

Never partially operate. The refusal belongs in repository discovery, before any
command runs, so there is no path on which gittle writes to a repository it
does not fully understand.

### 6.2 `index.version=4` — decided: read support in v1

Cheaper than previously estimated. v4 changes exactly two things: entry paths
are prefix-compressed against the previous entry (a varint count of bytes to
strip from the previous path, then a NUL-terminated suffix), and the 8-byte
entry padding disappears. The varint is again the ofs-delta encoding gittle
already implements.

**Read support is ~30 lines; write support ~30 more.** It is turned on by
`index.version=4` or by `feature.manyFiles`.

**Decided:** v1 reads v2, v3, and v4; it writes v2, or v3 when extended flags
require it. Refusing to open a colleague's repository over a 30-line format
variant would have been a poor trade.

**Related trap found while checking this.** `feature.manyFiles` also sets
`index.skipHash=true`, which makes git write an index whose trailing checksum is
all zeroes. If gittle validates that hash it will report a perfectly good index
as corrupt. **v1 must tolerate a zeroed index trailer** regardless of what it
decides about v4.

### 6.3 Binary layout and `argv[0]` dispatch

One binary, busybox-style. `main` inspects `basename(argv[0])`; if it matches a
known `git-<verb>` name it dispatches straight to that verb, otherwise it parses
a subcommand normally.

```
gittle                     the real binary
git-upload-pack   -> gittle    required: ssh clients send this exact command
git-receive-pack  -> gittle    required: ssh clients send this exact command
git-shell         -> gittle    optional: set as the git user's login shell
git               -> gittle    optional: drop-in replacement on PATH
```

The first two are not a convenience. A git client connecting over ssh runs the
literal command `git-upload-pack '<path>'` on the remote host, so those names
must resolve on the serving host's `PATH` or nothing can clone from gittle. The
`git` symlink is the opt-in that makes gittle a drop-in; without it, gittle
never shadows a real git that may also be installed.

Dispatch costs roughly 30 lines and removes the need for any separate
executables, which is what makes the single-static-binary goal survive contact
with the transport protocol.

## 7. Build order

Each phase should end somewhere useful, with real git available as the oracle:
create state with one tool, verify with the other, in both directions.

1. **Object store.** `hash-object`, `cat-file`. Read loose and packed objects,
   apply deltas, write loose. *Oracle: hashes match git's byte for byte.*
2. **Refs and config.** `update-ref`, `symbolic-ref`, `for-each-ref`, `config`.
   Loose refs plus `packed-refs`.
3. **Index and trees.** `update-index`, `ls-files`, `write-tree`, `read-tree`,
   `ls-tree`. *Oracle: `git fsck` and `git status` are clean after gittle writes.*
4. **First commit.** `init`, `add`, `commit`, `log`, `show`. The vertical slice
   that proves the format work.
5. **Diff.** Myers plus unified output; `diff`, `status` in all forms, `grep`.
6. **History.** `rev-list`, `rev-parse`, `merge-base`, `branch`, `tag`,
   `checkout`/`switch`/`restore`, `reset`, `reflog`.
7. **Merge.** `merge-file`, then the structural tree merge, then `merge`,
   `cherry-pick`, `revert`, `rebase`, `stash`.
8. **Transport.** pkt-line, protocol v2 `ls-refs` and `fetch`, `index-pack`,
   then `clone`/`fetch`/`pull`; then `pack-objects` and `push`.
9. **Serving.** `argv[0]` dispatch and the `git-*` symlinks, then `upload-pack`,
   `receive-pack`, and `git-shell`. *Oracle: real `git clone ssh://…` and
   `git push` against a gittle host, with `git-shell` as the login shell.*
10. **Housekeeping.** `gc`, `worktree`, `clean`, `check-ignore`.

Phases 1–4 are the risky ones: everything after depends on the on-disk formats
being exactly right, and format bugs found late are expensive.

## 8. v2 backlog

In the order I would restore them: `apply` (unlocks patch workflows and
`am`), `blame`, `log --graph`, `bisect`, `add -p`, rename detection,
`describe`, `shortlog`, reftable read support.
