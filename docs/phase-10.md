# Phase 10 — housekeeping

The last phase of the build order in [plan.md](plan.md) §7: `gc`, `worktree`,
`clean`, `check-ignore`, plus the three commands phase 8 left with them —
`mv`, `rm`, and `stage` as an alias of `add`.

**Status: complete (2026-09-02).** `tests/oracle.sh --full` passes 187 checks
across nine phases. All 53 commands of the v1 scope are built. See
[Results](#results).

---

## What this phase actually is

Six commands and an alias, and no new subsystem. Every engine they need was
built earlier and is used here for the first time from a command of its own:

| command | the engine, and where it came from |
|---|---|
| `check-ignore` | the ignore matcher — **phase 4**, used by `add` and `status` ever since |
| `rm`, `mv` | the index and the pathspec matcher — **phases 3 and 4** |
| `clean` | the ignore matcher again, plus the working-tree walk — **phase 4** |
| `worktree` | the `gitDir`/`commonDir` split — **phase 2**, which has been *reading* linked worktrees since |
| `gc` | the packer (**phase 8**), the object walk (**phase 6**) and the ref store (**phase 2**) |

So the phase is a test of whether the earlier phases got their interfaces
right, and mostly they did: the four largest pieces of work here are the four
places where a command needs something the engine had no reason to expose.

* `check-ignore -v` prints **which pattern decided**, and the matcher
  returned a `bool`. It now returns the pattern, its file and its line
  number, and `isIgnored` is a wrapper over that (`ignore.nim`, +36).
* `rm` refuses a directory named without `-r`, and the pathspec matcher
  returned a `bool`. `gittle rm dir` and `gittle rm 'dir/*'` name the same
  files; what separates them is *how* the argument matched, so matching now
  reports a kind (`pathspec.nim`, +15).
* `gc` folds loose refs into `packed-refs`, and the ref store could only ever
  *remove* a line from that file (`refs.nim`, +29 — phase 2 wrote down that
  this was coming).
* `clean` needs an exclude list with **no files behind it**, which is what
  `-x` actually means. That is four lines and a flag, and getting it wrong
  is bug 2 below.

## `-x` does not mean "delete ignored files too"

It means **there are no ignore files**. The distinction is invisible until
`-e` is used with it:

```sh
gittle clean -fdx -e '*.log'      # deletes untracked files, but not *.log
```

`clean` has one exclude list — the `-e` patterns, plus the standard ignore
files unless `-x` said to leave them out — and `-x` and `-X` choose which
side of it to delete:

| | the exclude list is | deletable |
|---|---|---|
| (default) | `-e` + the ignore files | untracked, not excluded |
| `-x` | `-e` only | untracked, not excluded |
| `-X` | `-e` + the ignore files | untracked **and** excluded |

Read as "delete ignored files too", `-x` makes the `-e` pattern do nothing,
and `clean -fdx -e '*.log'` deletes the logs it was told to keep. That is the
one bug in this phase that would have destroyed work.

## The collapse rule is the whole of `clean`

Finding untracked files was phase 4's job. What `clean` adds is that it
reports and removes *directories*, so it has to decide, per directory,
whether to name it once or to name the files inside it:

> A directory collapses to one entry when everything below it is going to be
> deleted anyway. Anything below it that must survive — a tracked file, or
> an ignored one that `-x` was not given for — forces the walk to descend and
> name the deletable files one by one.

git spells the same rule as `DIR_SHOW_OTHER_DIRECTORIES` plus
`correct_untracked_entries`, arriving at it by building both answers and then
dropping the collapsed entries that contain an ignored path. Get it wrong in
one direction and `clean -fd` removes a directory holding `node_modules`;
wrong in the other and it leaves empty directories behind.

Three consequences that are not obvious from the rule:

* **A pathspec implies `-d`.** `clean -f sub/` recurses into untracked
  directories under `sub/`, because naming a path is the same statement `-d`
  makes.
* **Without `-d` the ignore half of the rule switches off.** git does not
  collect ignored paths at all then, so a wholly-untracked directory collapses
  regardless of what is inside it — and is then skipped, which is why nothing
  inside it is removed either.
* **A nested repository does not stop the collapse.** The directory above it
  still goes out as one entry; the removal walk meets the repository, reports
  `Skipping repository`, and then names the files it *did* remove. So the
  same run prints a directory that vanished and, separately, the individual
  files of one that did not.

## `worktree`: two directories that point at each other

```
.git/worktrees/<id>/
    gitdir      /abs/path/to/<worktree>/.git      and, in the worktree,
    commondir   ../..                             .git  ->  a *file*:
    HEAD        ref: refs/heads/topic                gitdir: /abs/.git/worktrees/<id>
    index
    refs/       logs/HEAD
```

Everything *about the history* — objects, `refs/heads`, `refs/tags` — is
shared; everything *about a checkout* — HEAD, the index, the in-progress
markers, `logs/HEAD` — is per worktree. gittle has had that division since
phase 2, because it has always had to read a repository somebody else had
made a worktree in. What this phase adds is *making* them.

`add` is three writes and a checkout. git literally runs `git reset --hard`
as a child process with `GIT_DIR` and `GIT_WORK_TREE` set; gittle opens a
second `Repository` on the new directory and calls the three procs `reset`
calls. Same result, no fork — and the difference showed up once, as bug 8.

**One invariant runs through four commands.** A branch is checked out in at
most one worktree: two would let a commit in either move the ref under the
other, and the second would find its own HEAD describing a tree it does not
have. So `worktree add`, `checkout`, `switch`, `branch -d` and `branch -f`
all ask `checkedOutAt`, and `branch -v` marks the answer with `+` where it
would otherwise print a space. Adding the check to `branch` and `checkout`
is fourteen lines; not adding it would have left two commands able to break
what a third refuses to.

## `gc` must be additive, and that is a rule not an optimisation

plan.md's **R2a**. git's `gc` runs `repack -a -d`, which rewrites every pack
in the repository — and rewriting a pack means re-deltifying it, which gittle
**cannot do**, because R2 says gittle never searches for a delta. A
repository whose 304 MiB pack came from a clone would come out of a naive
`gittle gc` at 3,122 MiB (plan.md §3.1, measured).

Phase 10 therefore shipped a `gc` that folded **loose objects** into a new
pack of its own — a copy of every object at full size — and left the packs
that were already there alone. **The refactoring pass replaced that packer
with the server** (docs/minimize.md §3.4): the remote always runs full git,
so `gittle gc` now opens it the way `fetch` does and runs one fetch whose
wants are every tip the remote advertises that is already here and whose
haves are the commits at the edge of the *largest existing pack*. The
server's `pack-objects` sends everything outside that pack — including what
gittle held loose — properly deltified, non-thin, through the same
`installPack` checks a fetch gets, and no ref moves. Then a delete pass with
one rule: a loose object or a smaller pack goes only when every object in it
exists in a pack being kept. `--full` offers no haves and leaves one pack;
what was never pushed stays loose until the first `gc` after a push; nothing
unreachable is ever pruned; `extensions.preciousObjects` skips the delete
pass; and the pack a clone received is still there afterwards, which the
oracle tests exactly (**R2a**). The reflog-as-root, index-as-root and
`--prune=<date>` machinery below went with the packer.

## What `gc` deliberately does not do

* **Expire reflogs.** git drops entries older than `gc.reflogExpire`
  (90 days) and unreachable ones older than `gc.reflogExpireUnreachable`
  (30 days). That wants approxidate parsing, which decision 3 cut; reflog
  growth is bounded and tiny. Comparisons against git set
  `gc.reflogExpire=never` **in the fixture**, so both tools read the same
  configuration file and the divergence is *tested* rather than merely
  absent — the same device `--no-renames` and `--minimal` serve for `diff`.
* **Write a commit-graph, a multi-pack-index or a `.rev` file.** R3: caches
  git writes and gittle declines to read.
* **Run in the background, lock against a concurrent `gc`, or write
  `gc.log`.** `--auto`, `--detach` and `--force` are all cut by docs/07.

## What the oracle found

Thirteen bugs, and the split is the same one phases 6, 7 and 8 reported: the
ones that mattered were found by comparing **what was on disk afterwards**,
not what was printed.

1. **`mv` refused every directory rename.** git checks that a destination's
   parent directory exists only for a path it will actually `rename(2)`; an
   entry carried along *inside* a directory move gets no rename of its own
   and skips the check (`needs_worktree_rename`). Checking it anyway made
   `mv sub newsub` fail on `newsub/deep/d.txt`, a path nothing was about to
   create.
2. **`clean -x` read as "delete ignored files too".** §"`-x` does not mean"
   above; it made `-e` a no-op.
3. **`clean -X` did not collapse a wholly-ignored directory.** A directory
   that is not itself ignored but whose contents all are goes out as one
   entry, and therefore is not removed at all without `-d`. gittle removed
   its contents.
4. **`clean` let a nested repository stop the collapse.** The directory above
   one still goes out whole; the report comes from the removal walk.
5. **`clean` printed a trailing slash on directories removed inside the
   removal walk.** git builds those names from the walk and the top-level
   ones from the directory lister, and only the lister adds a slash.
6. **`worktree add` checked the destination path too early.** git checks it
   after creating the branch, so a failed `add` leaves the branch behind —
   and the "Preparing worktree" line has already been printed. Two states
   differed, not one message.
7. **`worktree add -b <existing>` exited 128, not 255.** git runs `git branch`
   as a child process, so the branch command's failure is what the exit
   status reports.
8. **`worktree add` in a bare repository wrote a `logs/HEAD` entry git does
   not write.** The first HEAD write is made by the *parent* process, where a
   bare repository means `core.logAllRefUpdates` is off; everything after it
   is made by a child that has a working tree, and therefore does log. The
   two writes have different reflog policies and it is not obvious why until
   you notice one of them is a different process.
9. **`branch -d` and `checkout` ignored other worktrees.** Both refuse a
   branch this worktree has checked out and neither knew about any other.
10. **`branch -v` did not mark a branch checked out elsewhere**, and `-vv`
    did not name where.
11. **`worktree move` reported the destination as an absolute path.** git
    quotes back what was typed, and adds `strerror` when the rename fails.
12. **`gc` had to be told that a reflog is a root** before it would keep the
    commit a `reset --hard` moved off. Caught by the test that asks for
    `HEAD@{1}` after `gc --prune=now`.
13. **`gc` pruned annotated tag objects**, once. A late hardening pass made
    the reachability walk peel each root to a commit before starting — which
    is right for a tag naming a tree, and drops the tag *object* on the floor
    for every other tag. `git fsck` after the run said
    `missing object … for refs/tags/v1` within a minute of the change. A root
    is now kept as itself *and* walked from, which is two lines and the
    difference between a valid repository and a dangling ref.

Bugs 6 and 8 were found only by the state comparison, and both are
invisible in stdout entirely: one leaves a branch behind, the other a reflog
entry.

### The harness needed four changes

Three of them because a *path* had become part of the state being compared,
which had not happened before:

* **`p6state` prints a `.git` file's content rather than its hash.** It
  hashes every working-tree file, and a linked worktree's `.git` is a file
  whose content is an absolute path — so two copies of the same repository
  differ there for no reason but their own names.
* **`p6mut` normalises the copy directory out of the state**, the way it
  already did out of the output.
* **`worktree` got a comparison of its own** (`p10`), because almost
  everything it writes is *under* `.git`, where `p6state` does not look: the
  administrative directory, the `.git` file in the new checkout, and the pair
  of paths that point at each other. `p10` compares both repositories whole,
  contents included, skipping only the packfiles (R2: gittle's are not
  byte-identical to git's) and the index (compared through `ls-files -s`).

And one because a deliberate divergence surfaced for the first time:
`status.renames=false` in the `mv` fixture. gittle detects no renames
(phase 5's cut) and `mv` is the one command that makes one on purpose, so
git's `status` says `renamed:` where gittle says a delete and an add. It goes
in the fixture rather than on git's command line so that both copies read the
same configuration file — the same device `--no-renames` and
`--diff-algorithm=minimal` serve for `diff` and `merge`.

## Results

`tests/oracle.sh --full`, 187 checks across nine phases, all passing.

| Check | Coverage |
|---|---|
| `check-ignore` | 40 paths against four pattern sources — per-directory files at two depths, `info/exclude`, `core.excludesFile` — plain and `-v`, from the root and from a subdirectory, including the negation that `-v` reports and the plain form must not |
| `rm` | 23 removals, refusals and dry runs: `--cached`, `-n`, `-q`, a directory with and without `-r`, a wildcard that reaches the same files, and all three "you would lose work" refusals |
| `mv` | 33 renames and refusals, including every one of git's eleven checks that gittle implements, a symlink, an empty directory, a directory move that carries three index entries, and `-n`/`-v` |
| `clean` | 33 forms over a fixture built for the collapse rule — a directory with tracked content, one without, one holding an ignored file, one entirely ignored, an ignored directory, and a nested repository — in every combination of `-d`, `-x`, `-X`, `-e`, `-f`, `-ff` and `-n` |
| `worktree` | 51 forms with **both repositories compared whole**: `add` in six spellings, `list`, `move`, `remove`, `prune`, a dirty worktree, a worktree whose directory was deleted, two worktrees at once, a subdirectory, and the four commands that now refuse a branch another worktree has |
| `gc` | 11 runs comparing refs, reflogs, index, working tree and every reachable object, with and without a linked worktree, a staged blob and a dangling one |
| `gc`, what it claims | loose objects end in a pack and the fan-out directories go; `--prune=now` removes an unreachable object and **keeps** both one the reflog names and an annotated tag's own object; `packed-refs` written and no loose ref left beside it; the refs unchanged across the run; `git fsck --strict` clean; and an inherited pack still there afterwards (**R2a**) |

Every mutating command is compared the way phase 6 established: run in two
identical copies of a fixture, then diff every ref, HEAD, the config, every
reflog, every working-tree file, the whole index, every in-progress marker,
and each tool's own `status` and `branch`.

## Layout as built

```
src/worktrees.nim         90   the registry: what a linked worktree is on disk
src/cmd/checkignore.nim   45
src/cmd/rm.nim            90
src/cmd/mv.nim           125
src/cmd/clean.nim        168
src/cmd/worktree.nim     272   add, list, move, remove, prune
src/cmd/gc.nim           119
```

and, in files that already existed:

```
src/ignore.nim           +36   which pattern decided, and a file-less list for -x
src/refs.nim             +29   packRefs
src/gittle.nim           +17   seven verbs and their usage lines
src/pathspec.nim         +15   how an item matched, not merely whether
src/cmd/branch.nim        +8   the other-worktree refusals, and `+` in the listing
src/cmd/checkout.nim      +6   the same refusal, once
```

## Budget

```
                                             budgeted  actual  where
gc, worktree, clean, check-ignore                 300     694   gc 119, worktree 272 + its registry 90, clean 168, check-ignore 45
mv, rm, stage                                     ---     215   mv 125, rm 90, stage 0 (a second name in the dispatch)
what the engines had to expose                    ---     111   ignore +36, refs +29, pathspec +15, branch +8, checkout +6, the driver +17
                                                      -------
phase 10                                                 1,020
```

Total: **13,872 lines of code** (22,196 including comments), against the
~13,000 [plan.md](plan.md) §5.3 projected for v1. The static binary is
3.3 MB.

The 300 was wrong by a factor of two and a bit, and for a reason worth naming
because it is the **fourth** time §5's model has missed and the fourth
distinct cause:

* phase 6 over-ran on **shared output formatting** — it belongs to no one
  command, so no command's budget line carries it;
* phase 7, on **state machines** — a directory of files to write, read back
  and remove correctly under four verbs;
* phase 8, on **compatibility surface** — the rules a tool has to reproduce
  because someone else's output already defines them;
* phase 10, on none of those. `worktree` (362 lines with its registry) is
  more than half the miss, and what it is is **a second copy of the
  repository abstraction**: a linked worktree is a `Repository` with a
  different `gitDir`, and every verb has to construct one, validate the pair
  of files that make it real, and then ask the *other* repository a question
  about it. The rest came in at or under: `check-ignore` is 45 lines because
  the engine was already there, and `stage` is zero.

That is the honest reading of §5's premise. It models **option
combinations**, and none of the four causes measured across four phases is
option combinations — which says the model is not merely low, it is
measuring the wrong thing. §5 stays as written and as a *measurement*: v1 is
13,872 lines, 6.7% over the 13,000 projected after phase 8 and 60% over the
original 8,680 sketch, and the refactoring pass that plan.md defers to
feature-completeness now has a baseline and four named things to look at.

## What was left undone, and where it belongs

| | |
|---|---|
| `clean -i`/`--interactive` | docs/06, and plan.md R6 with every other interactive engine |
| `worktree lock`, `unlock`, `repair`, `--porcelain`, `-z`, `--expire`, `--orphan`, `--guess-remote`, `--track`, `--relative-paths` | docs/08. `--relative-paths` would also need `extensions.relativeWorktrees` *written*, where gittle only reads it |
| `worktree prune -n`, `--expire`, `-v` | docs/08. Without `--expire` there is no grace period: a worktree whose directory is gone is gone |
| `gc --aggressive`, `--auto`, `--detach`, `--cruft`, `--keep-largest-pack`, `--force`, `gc.log`, the lock file | docs/07. `--auto` is the one a daily loop would notice, and it needs the loose-object estimate and nothing else |
| reflog expiry in `gc` | v2. Needs approxidate (decision 3) or a narrower date form; the cost of not having it is a longer `logs/HEAD` |
| `rm --ignore-unmatch`, `--sparse`, `--pathspec-from-file` | docs/08 |
| `mv -k` | docs/07 |
| `check-ignore --stdin`, `-z`, `-n`, `--no-index` | docs/13 |
| `pack-refs` as a command | docs/05 cuts it; `gc` packs refs internally, which is where phase 2 said it would land |
| rename detection in `status` | phase 5's cut showing up in a new place: `mv` makes a rename on purpose, so `status.renames=false` is set in the `mv` fixture and the divergence is tested rather than absent |
| `prune`, `repack`, `fsck`, `count-objects` as commands | docs/11 cuts all four; `gc` does the parts of the first two that v1 needs |

This is the last phase, so it is also the last of these tables. What v1 leaves
undone *as a whole* — `apply`, `blame`, `log --graph`, `bisect`, `add -p`,
rename detection, reftable, and serving — is [plan.md](plan.md) §8, in the
order it would be restored.
