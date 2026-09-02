# Phase 6 — history

The sixth phase of the build order in [plan.md](plan.md) §7:
`rev-list`, `rev-parse`, `merge-base`, `branch`, `tag`,
`checkout`/`switch`/`restore`, `reset`, `reflog`.

**Status: complete (2026-09-01).** All ten tasks done; `tests/oracle.sh
--full` passes 162 checks across six phases. See [Results](#results).

---

## Environment

Unchanged from [phase 5](phase-5.md). The oracle is `../git`, built from the
reference tree; `tests/oracle.sh` prefers it over `PATH` automatically.

## What this phase actually is

Phases 1–5 could name a commit only by a full object ID or a ref. Everything
in this phase is downstream of removing that limit, and the phase divides into
four pieces that are much less independent than the command list suggests:

* **The revision grammar** (`revision.nim`) — `HEAD~3`, `A..B`, `v1.0^{}`,
  `HEAD@{2}`, `:0:file`, `--all`, `--not`. Eight commands take it, `rev-parse`
  *is* it, and phase 5 deferred four of its own gaps here for want of it.
* **The walk, completed** (`revwalk.nim`) — exclusions, the two orderings,
  the date and parent-count limits, parent rewriting.
* **Reachability** (`merge-base`) — one algorithm behind `merge-base`,
  `--is-ancestor`, `branch --merged`, `branch -d`'s safety check, and the
  ahead/behind counts phase 5 left `status` and `branch -v` waiting for.
* **The working tree, written** — `checkout`, `switch`, `restore` and
  `reset` are the first commands that *change* tracked files. Everything
  before them either appended to the object store or rewrote the index.

The last is the risk. A checkout that is wrong about which files are dirty
destroys work, and it is the one place in gittle where that is true.

## The rule the working-tree commands share

git's answer is `unpack-trees.c`, 2,800 lines, and almost all of it is the
n-way merge that phase 7 needs. What this phase needs is the **two-way**
case — "move from tree A to tree B, refusing rather than overwriting" — which
is one rule applied per path:

> For each path in `union(A, B, index)`: if the index and the working tree
> agree with A, take B. If they already agree with B, do nothing. Otherwise
> the path is *dirty*, and the whole operation aborts before touching
> anything, naming every such path.

Aborting before the first write is what makes it safe, and it is why the
walk happens twice: once to decide, once to apply.

`--force` (`checkout -f`, `switch -f`, `reset --hard`) skips the check and
takes B unconditionally. `reset --mixed` writes the index and stops; `reset
--soft` writes neither.

## Task list

All ten complete.

1. **The revision grammar.** `revision.nim`: the `<rev>` suffix operators,
   the three range forms, the pseudo-ref expansions, and the
   revision-versus-path disambiguation the commands all share.
   *Oracle: an enumerated table of revision expressions through
   `git rev-parse`.*
2. **`rev-parse`.** Object-name resolution and the repository-layout queries.
3. **The walk.** Exclusions and boundary handling, `--topo-order`,
   `--date-order`, `--reverse`, `--no-walk`, `--since`/`--until`,
   `--merges`/`--no-merges`/`--min-parents`/`--max-parents`, `--left-right`,
   `--parents` with parent rewriting.
4. **`rev-list`.** The command over that walk, plus `--count` and `--objects`.
   `log` loses its deferral table and gains the same surface.
5. **`merge-base`.** The paint-down-to-common-ancestors algorithm, `--all`,
   `--is-ancestor`, and the ahead/behind count.
6. **`branch`.** List, create, delete, rename, `-v`/`-vv`, `--contains`,
   `--merged`, upstream configuration, and the `--format`/`--sort` surface
   shared with `for-each-ref`.
7. **`tag`.** Lightweight and annotated creation, deletion, listing with
   `-n<num>`, and the same filter and format surface.
8. **`checkout` / `switch` / `restore`.** The two-way update, path-restoring
   mode, branch creation, and detached HEAD with its messages.
9. **`reset`.** `--soft`, `--mixed`, `--hard` and the pathspec form.
10. **`reflog show`**, and `HEAD@{n}` reading the same file.

## What phase 5 deferred here

| | |
|---|---|
| revision ranges (`A..B`, `^A`, `HEAD~3`, `--all`) in `diff`, `show` and `log` | task 1 |
| `--topo-order`, `--date-order`, `--since`, `--until` | task 3 |
| the ahead/behind count `status` and `branch -v` need | task 5 |

---

## The revision grammar, and why it is one module

`gitrevisions(7)` is taken by eight commands, and every one of them wants a
slightly different subset: `cat-file` any object, `merge-base` a commit,
`ls-tree` a tree, `rev-list` a *set* of commits marked interesting or not.
Written per command it is eight subsets that disagree at the edges; written
once it is three layers, and the layering is what the commands select from:

| layer | what it resolves | who calls it |
|---|---|---|
| `resolveName` | a name: object ID, ref, `@`, `<ref>@{n}`, `@{-n}` | inside layer 2 only |
| `resolveRevish` | a `<rev>`: the suffix operators and `:path` | 12 commands |
| `addRevArg` | a revision *argument*: `^A`, `A..B`, `A...B`, `A^!` | `rev-list`, `log`, `rev-parse` |

Layer 3 is why `rev-list` and `log` never see a range: by the time the walk
starts, every argument has become commits, each flagged. That is also what
made `rev-parse` cheap — it is the same three layers with a printer.

**The order inside layer 2 is not obvious and is load-bearing.** git tries
each step on the *whole* string before taking the string apart, so a ref whose
name contains `^` or `:` still wins over the operator reading. The operator
scan runs from the right, which is what makes `a^b~2` mean `(a^b)~2`.

## What the oracle caught that reading would not have

Nine, and the pattern is the same as phase 5's: every one is a case where the
documentation describes the intent and the wire does something else.

1. **`rev-parse` does not dereference the sides of a range.** `v1..main`
   prints the *tag object* on the `^` side, not the commit — because
   `get_oid_committish` picks among ambiguous abbreviations and does not peel.
   The walk peels; the grammar must not.
2. **`--short` implies `--verify`.** An abbreviation is only meaningful for
   one object, so `rev-parse --short main..side` prints both revisions and
   *then* dies. Two behaviors from one option, and neither is in its
   description.
3. **A no-op ref update writes no reflog entry — but HEAD's does.** Setting a
   ref to the value it already holds is not a change and is not logged
   (`lock_ref_for_update`); yet `reset --soft HEAD` still appears in
   `reflog show`, because HEAD is updated *through* the branch and the
   split-off HEAD update is log-only. Three of gittle's commands had a
   spurious entry until this was measured.
4. **`--first-parent` does not change what a commit is.** It stops the
   traversal at the first parent; `commit->parents` is untouched, so a merge
   still prints `Merge: a b`. gittle had been truncating the list it printed.
5. **Parent rewriting happens after the sort, not before.** `--topo-order
   --parents -- <path>` sorts on the *real* ancestry and rewrites at output.
   Rewriting first changes the in-degrees and reorders the output — one commit
   out of thirty, on `diff.c`.
6. **`checkout` ends with a name-status diff.** After a successful switch git
   prints what is *still* modified, so a local change carried across is
   announced rather than discovered later. It goes to stdout while
   "Switched to branch" goes to stderr, and the buffering puts them in that
   order.
7. **`switch` says "checkout" when it refuses.** The message is built with
   the word hardcoded, and the advice line then says "before you switch
   branches" for both commands.
8. **`%(refname:short)` is the DWIM rules run backwards.** It has to ask what
   *else* exists: `refs/remotes/origin/HEAD` shortens to `origin`, not to
   `origin/HEAD`, and a branch and tag sharing a name leave the branch spelled
   `heads/x`. A prefix strip gets 999 of the reference repository's 1,018 refs
   right, which is exactly the sort of near miss a spot check passes.
9. **`branch` and `tag` match patterns against the short name; `for-each-ref`
   matches the full name as a path.** Same option, same-looking argument, two
   rules — which is why `tag -l 'v*'` works and `for-each-ref 'v*'` does not.

And one that is not a behavior but a shape: **`%(contents)` includes a signed
tag's signature and every other message atom excludes it.** Reading the tag
message without knowing where the signature starts makes the subject of every
signed tag in the git repository a line of base64.

## Deliberate divergences, and why each is acceptable

| | |
|---|---|
| `--since`/`--until` take a seconds count or an ISO-8601 date, not `"2 weeks ago"` | approxidate is a parser of English behind one option (R6). Refused by name with the reason. |
| `:/text` and `<rev>^{/text}` search commit messages | a search engine behind one syntax (R6) |
| `<ref>@{<date>}` | approxidate again |
| `@{push}` | needs push refspecs; phase 8 |
| `branch -c`, `--edit-description`, `--column`, `--color` | docs/06 cuts them |
| `tag -s`/`-v` and every signing option | plan.md decision 5: gittle neither makes nor checks signatures. It does know where one *starts*, which is all reading a signed tag needs. |
| `checkout -p`, `-m`, `--conflict`, `--orphan`, `--overlay` | docs/06; `-m` and `--conflict` need the merge machinery (phase 7) |
| `checkout --ours`/`--theirs` | needs unmerged index entries; phase 7 |
| `reset --merge`, `--keep`, `-N`, `-p` | docs/08 |
| `reflog expire`/`delete`/`drop` | docs/11: the pruning half. A repository whose reflogs are never pruned is merely larger. |
| `git`'s `hint:` advice lines, except where they are part of a message being reproduced | gittle has no advice system, and one exists to be configurable |

## Results

`tests/oracle.sh --full`, 162 checks across six phases, all passing.

| Check | Coverage |
|---|---|
| revision grammar | 87 expressions and `rev-parse` forms, including the ones that must **not** resolve, and the same table from a subdirectory where `:path` and `:./path` differ |
| `merge-base` | 33 forms plus **200 random commit pairs** from the reference repository, `--all` on every one |
| `rev-list` | 50 option forms over real history — both orderings, both range spellings, path limiting, `--objects` on both sides of a range |
| `log` | 16 forms through the identical parser, which is the check that it *is* identical |
| `for-each-ref` | 25 atoms and filters over the reference repository's 1,018 refs |
| `branch` | 21 listing forms including a detached HEAD, and 25 creates, deletes, renames and upstream changes |
| `tag` | 13 listing forms and 12 creates and deletes, annotated and lightweight |
| `checkout`/`switch`/`restore` | 26 switches and restores, **each against a dirty starting state as well as a clean one** |
| `reset` | 21 resets across the three modes and the pathspec form |
| `reflog` | 7 listings |
| `git fsck --strict` | clean after gittle writes a tag object, a branch, a commit and a `reset --hard`, and git reads all four back |
| upstream tracking | 21 `status` forms, all four output formats |

### How the mutating commands are tested

Read-only commands are compared on stdout, stderr and exit status. That is
not enough for anything in the second half of this phase: a `checkout` that
prints the right message and leaves the wrong index is exactly the failure
worth catching, and it is invisible to a stdout comparison.

So every mutating check runs the same command in **two identical copies** of a
fixture and then compares *everything either tool could have written*: every
ref and its symbolic target, HEAD, the config file, every reflog byte for
byte, every working-tree file by content hash, and the whole index. Nine of
the eleven bugs the sweep found were found in that second comparison and not
in the first — the reflog ones in particular, which no amount of reading the
output would have shown.

The fixture is small but has one of everything the phase touches: a merge, a
side branch, an annotated tag and a lightweight one, a subdirectory, a
remote-tracking ref and a configured upstream — and, on the side branch only,
an executable and a symlink, so that switching has to create and remove both.
The state comparison reads a symlink as a link rather than following it: a
checkout that wrote the target as a regular file would otherwise pass every
check that prints a name.

## Performance, and what R3 costs here

Two of this phase's operations are the first where discarding git's
accelerators (R3) is *visible*:

| | git | gittle |
|---|---|---|
| `rev-list HEAD` (82,130 commits) | 0.67s | 3.1s |
| `rev-list -n 200 --topo-order HEAD` | 0.65s | 2.3s |
| `rev-list -n 60 --topo-order HEAD -- t/` | 3.8s | 31s |
| `branch --contains` over 1,018 tags | ~1s | ~8s |

The asymptotics match — `--topo-order` without a commit-graph makes git read
the whole history too, and its memory here is within 20% of gittle's. The
constant is inflating every commit object where git has a commit-graph and a
parsed-object cache. Two things were worth fixing and both were algorithmic
rather than constant:

* the walk asks for the same commit three or four times — to date it for the
  queue, when it is popped, as some child's parent, and again if the excluded
  side reaches it. Caching the three fields it actually needs (tree, parents,
  date) took `log --parents -- Makefile` from 13.5s to 0.8s;
* `--contains` over a thousand tags is a thousand walks over the same history
  unless the answer is memoised across refs, which is why `ref-filter.c` has
  `contains_tag_algo` and why `reffilter.nim` now does the same.

## Layout as built

```
src/
  revision.nim    the <rev> grammar, ranges, and the shared docs/04 parser   395
  reffilter.nim   the ref listing engine: atoms, filters, sort               243
  worktree.nim    the two-way update, and the index refresh                  179
  revwalk.nim     + exclusions, orderings, reachability          298 (was 120)
  cmd/
    revparse.nim                                                             106
    revlist.nim                                                              138
    mergebase.nim                                                             29
    branch.nim                                                               280
    tag.nim                                                                  134
    checkout.nim  checkout, switch and restore                               203
    reset.nim                                                                 76
    reflog.nim                                                                47
```

Three things moved during the minimisation pass, each because a second caller
appeared:

* **`ref-filter` came out of `cmd/foreachref.nim`.** git's is one engine
  behind four commands and gittle's now is too; `for-each-ref` shrank from 299
  lines to 53.
* **`canonMode` and the mode constants moved to `objects.nim`.** They were in
  `diffcore.nim` and `index.nim` respectively, and the working-tree update
  needs both — "what mode is this really" is a fact about objects.
* **`optionValue` replaced nine copies of `valueFor`.** Three spellings of an
  option argument, one of them with an optional value, written nine slightly
  different ways. It is a template rather than a proc because it has to
  advance the caller's own index — the value and the loop position are the
  same state, and separating them is how a parser comes to consume one
  argument twice.

`upstreamRef` moved to `repository.nim` for the same reason, and gained the
check that found a real bug: an upstream needs the remote's **fetch refspec**,
not just `branch.<name>.merge`. Without it a half-configured repository shows
tracking information that is not there.

## Budget

```
                                          budgeted   actual
revision walk                                  250      298   revwalk.nim
working tree: checkout, status                 600      428   worktree 179 + status 249
argument parsing, 30 commands                2,000    3,186   cmd/ + the driver
shared output formatting                       ---    1,418   pretty, diffcore, status, reffilter
the revision grammar                           ---      395   revision.nim (unbudgeted)
```

Total: **8,960 lines of code** (14,237 including comments) against the ~9,000
of plan.md §5, with **four of ten phases still to build**. The static binary
is 2.6 MB.

That is the headline and it needs saying plainly: **the budget is spent, and
merge, transport, serving and housekeeping have not started.** plan.md §5
budgets 1,800 lines for the three remaining algorithm blocks alone (merge 600,
transport 700, pack write 500), so the project will land somewhere near
11,000 rather than 9,000 unless something is cut.

Phase 5 recommended re-planning §5 before this phase started, and the two
numbers it predicted are both worse than it thought:

* the command layer is **3,186 for 30 of 56 commands** — 106 a command, where
  phase 5 projected 40. The projection was made before this phase spent
  docs/04, which is the second-largest shared option group in git;
* "shared output formatting" is **1,418** and still has `rev-list --objects`
  formatting and the transport progress output to come.

**What the evidence now supports.** The command layer does not scale with
commands and it does not scale with option surface either; it scales with
**shared option surface that has not yet been spent**. docs/03 (diff options)
and docs/04 (revision options) were the two large ones and both are now paid
for. What is left is 26 commands with option lists in the ten-to-twenty range
and one more shared group of any size (docs/05's fetch options, phase 8).
Extrapolating from the last two phases would over-predict; extrapolating from
the *unspent* surface gives roughly 1,200 more for the command layer.

A revised §5, for phases 7–10:

```
merge: file 3-way + structural tree merge                     600
wire protocol v2 over ssh: ls-refs, fetch, push               700
pack write + delta reuse                                      500
serving: upload-pack + receive-pack                           400
argument parsing, the remaining 26 commands                 1,200
git-shell, gc, worktree, clean, check-ignore                  300
                                                          -------
                                                            3,700
```

which puts v1 at about **12,700 lines of code**. The honest options are to
accept that, or to cut a phase — and the cheapest cut by far is phase 9
(serving), which is 400 lines of command plus the `git-shell` and `argv[0]`
work and buys nothing for a client-only tool. That is a decision for the plan,
not for this document, but it is the one worth taking before phase 7 starts
rather than after.

**Resolved (2026-09-01), both ways.** The server is cut — `upload-pack`,
`receive-pack` and `git-shell` are out and phase 9 is empty — and the line
budget is now a measurement rather than a limit, with an optimisation and
refactoring pass planned once v1 is feature-complete. `plan.md` §5.1 carries
the running figure (~12,300 for v1 with the server gone) and §6 decision 2 the
reasoning. `argv[0]` dispatch stays, no longer because anything requires it.

## What was left undone, and where it belongs

| | |
|---|---|
| unmerged (stage > 0) paths: `checkout --ours`/`--theirs`, `restore --ours`, `status`'s `U` letter and `Unmerged paths:` | phase 7, with the merge machinery that creates them |
| `checkout -m`, `--conflict=<style>` | phase 7 |
| the in-progress states in `branch`'s detached description (`HEAD detached at` becomes `rebasing` mid-rebase) | phase 7 |
| `branch -c`/`-C` (copy) | v2; it is `-m` without the delete, and nothing observed in the logs used it |
| `%(upstream:track)` as a `for-each-ref` atom | it exists inside `branch -v`; exposing it is phase 8's job when the atom list is revisited |
| a custom fetch refspec — `upstreamRef` assumes `+refs/heads/*:refs/remotes/<remote>/*` | phase 8, which is where a refspec is parsed at all |
| `rev-list --objects-edge`, `--filter` | phase 8 if `pack-objects` turns out to want them; cut otherwise |
| `worktree`, `gc`, `clean`, `check-ignore` | phase 10 |
| `upload-pack`, `receive-pack`, `git-shell` | **cut, not deferred** — v2 backlog, as a piece |
