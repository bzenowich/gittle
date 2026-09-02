# Phase 7 — merge

The seventh phase of the build order in [plan.md](plan.md) §7: `merge-file`,
then the structural tree merge, then `merge`, `cherry-pick`, `revert`,
`rebase` and `stash`.

**Status: complete (2026-09-01).** `tests/oracle.sh --full` passes 170 checks
across seven phases. See [Results](#results).

---

## Environment

Unchanged from [phase 6](phase-6.md). One addition to the list of options the
oracle must pass git so that it selects the behavior gittle implements:
**`--diff-algorithm=minimal` for `merge-file`**, and `-Xdiff-algorithm=minimal`
would be its equivalent for `merge`. It is the same deliberate cut as
`--minimal` for `diff` — gittle implements git's `need_min` path and nothing
else (R4) — and it now reaches the merge, because a three-way merge is two
diffs.

## What this phase actually is

One algorithm, wearing five hats.

Every command here reduces to *merge three trees and do something with the
result*, and they differ only in which three trees they hand it and what they
write afterwards:

| | base | ours | theirs | afterwards |
|---|---|---|---|---|
| `merge C` | the merge base of HEAD and C | HEAD | C | a commit with two parents |
| `cherry-pick C` | C's parent | HEAD | C | a commit with C's author |
| `revert C` | C | HEAD | C's parent | a commit saying `Revert "…"` |
| `rebase` | each commit's parent, in turn | HEAD | that commit | the branch label moves |
| `stash apply` | the tree the stash was made against | the index now | the stashed tree | the index is put back |

So the phase is three new modules and five thin commands over them, which is
why the algorithm came in *under* budget and the command layer did not.

The three modules:

* **`mergefile.nim`** — `xdiff/xmerge.c`. Three texts in, one text with
  conflict markers out. This is where every `<<<<<<<` gittle will ever print
  comes from.
* **`mergetree.nim`** — `merge-ort.c`, minus renames. Three trees in, a
  decision per path out: take one side, merge the contents, or record three
  index stages and say why.
* **`sequencer.nim`** — the in-progress state on disk. A conflicted merge is
  not a state in a running program; the program has exited. It is
  `MERGE_HEAD`, `MERGE_MSG` and their siblings, and `--continue` and
  `--abort` are nothing but "read them and finish" and "read them and undo".

## A three-way merge is two diffs

Not a comparison of three files. `mergefile.nim`'s header spells it out, and
it is the one idea that makes the rest of the phase readable:

```
base -> ours     a script of edits
base -> theirs   another script of edits
```

Walk the two scripts together over the *base's* line numbers. An edit that no
edit on the other side comes near is taken — the other side had no opinion
about those lines. Two edits that touch overlapping base lines conflict,
unless they turn out to be the same edit.

That is why conflict markers delimit what they do. They are not "the lines
that differ": they are *a region of the base that both sides rewrote*, which
is why a one-line disagreement inside a hundred-line rewrite still marks the
whole hundred lines — until git's two refinements shrink it, and gittle
implements both:

* **refine** — diff the two conflicting sides against *each other* and keep
  only what genuinely differs, splitting one conflict into several;
* **simplify** — and then swallow any gap of three lines or fewer between two
  of them back into one, because two conflicts separated by one common line
  take more room on screen than one conflict does.

## What a conflict is, on disk

Three index entries for one path, at stages 1, 2 and 3 — base, ours, theirs.
A resolved path has one entry, at stage 0. Everything else follows from that:

* `commit` refuses while any stage-nonzero entry exists;
* `status` reports them under `Unmerged paths:`, with a two-letter code that
  is a *bitmask of which stages exist* — `DU` is stages 1 and 2 with no 3,
  "deleted by us";
* `add`ing the path replaces all three with one, which is what "resolving"
  means;
* `checkout --ours` writes stage 2's content into the working tree and leaves
  the index alone, because the conflict is not resolved by looking at it.

The conflict-marked file in the working tree is a *convenience*. The index is
the state.

## The bug the merge found in the diff engine

The first thing `merge-file` disagreed with git about was not a merge at all.

gittle's diff splits a file into lines with the newline **excluded**, and gave
two lines the same equivalence class when their text matched. git's records
**include** the terminator, so `"b\n"` and `"b"` are different records. The
consequence was that gittle's `diff` reported *no change at all* between a
file and the same file with its final newline added:

```
$ printf 'a\nb'  > f; git add f; git commit -m x
$ printf 'a\nb\n' > f
$ gittle diff
diff --git a/f b/f
index 0a207c0..422c2b7 100644          <- and nothing else
```

The blob IDs differ, which is why the header was right and the patch was
empty. It survived phase 5's 268-file-pair sweep because the reference
repository has almost no such pairs, and it survived every hunk comparison
because there was no hunk.

The fix is one line in `classify` and it is git's own rule: the terminator is
part of the record under an exact comparison, and is whitespace like any other
under `-w`, `-b` and the two `--ignore-*-at-eol` modes (`xutils.c:xdl_recmatch`
skips it in all four). With that, all 400 random three-way merges agreed with
git immediately.

## Task list

All nine complete.

1. **The file merge.** `mergefile.nim`: `xdl_merge`, both refinements, the
   CRLF-aware marker lines. *Oracle: 400 random three-way cases against
   `git merge-file --diff-algorithm=minimal`.*
2. **`merge-file`.** The command, whose exit status is the conflict count.
3. **The tree merge.** `mergetree.nim`: the per-path rule, index stages,
   the recursive virtual merge base, D/F conflicts.
4. **The in-progress state.** `sequencer.nim`, and `status`, `commit`,
   `branch` and `checkout` taught to read it.
5. **`merge`.** Fast-forward, real merge, `--abort`/`--quit`/`--continue`,
   and `fmt-merge-msg`'s default message.
6. **`cherry-pick` and `revert`.** One file: the same machinery with the
   trees swapped, plus the sequencer's todo list.
7. **`rebase`.** The merge backend: detach, replay, move the branch.
8. **`stash`.** The two-or-three-parent commit, the reflog as a stack, and
   apply-as-merge.
9. **`read-tree -m`, `--reset`, `-u`.** Phase 3 deferred these here: the
   one-, two- and three-tree forms are the same three rules as plumbing.

## What earlier phases deferred here

| | |
|---|---|
| unmerged paths in `status` — the `U` letters and `Unmerged paths:` | done |
| `checkout --ours`/`--theirs`, `restore --ours`/`--theirs` | done |
| `branch`'s in-progress description (`(no branch, rebasing topic)`) | done |
| `checkout -m`, `--conflict=<style>` | **out of scope after all** — docs/06 and docs/08 mark both `[ ]`, and the inventory is what decides. Phase 6 listed them here from the *reason* they were deferred rather than from the scope table. |
| `read-tree -m`, `--reset`, `-u` — deferred by **phase 3** | done |

## Why the merge base is sometimes not a commit

Two branches can have several equally good common ancestors — merge one into
the other and back, and they will. Picking one arbitrarily gives an answer
that depends on which, which is how the old `resolve` strategy produced
spurious conflicts.

git's `ort` merges the merge bases *with each other*, recursively, and uses
the resulting tree as the base (`merge-ort.c:merge_ort_internal`). gittle does
the same, and the surprising part is what happens to a conflict inside that
inner merge: it is not reported. The markers simply become part of the virtual
base's content, where they match neither side and so widen the real conflict —
which is exactly the signal the user needs.

`cherry-pick` and `rebase` deliberately do *not* do this: the change being
replayed is exactly `parent -> commit`, so the parent **is** the base and
there is no ancestry question to ask. git calls `merge_incore_nonrecursive`
there for the same reason.

## What the oracle caught that reading would not have

Thirteen, and they cluster: nine are about *which* of several
almost-identical code paths git actually took.

1. **The trailing-newline bug above**, which was a phase-5 bug the merge
   surfaced.
2. **`isRegular` is not "is it a blob".** A symlink is stored as a blob and an
   absent path has mode zero, and `modeType(mode) == otBlob` is true for both.
   The test git uses is `S_ISREG`, on the format bits. gittle read a null
   object ID on the first conflicting merge it was given.
3. **`CHERRY_PICK_HEAD` and `REVERT_HEAD` are not symmetric.** `-n` on a clean
   pick writes *neither*, `-n` on a clean revert writes `REVERT_HEAD`, and a
   conflict writes both. `sequencer.c:do_pick_commit` says why: the pick's file
   exists for the benefit of a later `commit`, and `-n` has already decided
   not to commit.
4. **`git commit` names the operation in the reflog only for the two it
   recognises.** Concluding a cherry-pick by hand records
   `commit (cherry-pick):`; concluding a *revert* by hand records plain
   `commit:` — because `determine_whence` looks at `MERGE_HEAD` and
   `CHERRY_PICK_HEAD` and at nothing else. The same rule silences the
   `restore --staged` hint in `status` during a merge and a pick but not
   during a revert or a rebase.
5. **`commit` after a conflicted cherry-pick keeps the picked commit's
   author** — and prints a `Date:` line for exactly that reason
   (`author_date_is_interesting`).
6. **A refused merge exits 2, not 1**, and adds `Merge with strategy ort
   failed.` A merge that ran and conflicted exits 1. The distinction is
   "could not start" against "started and disagreed", and a script can tell
   them apart.
7. **`refresh_index` reports unmerged paths on standard output before the
   error appears on standard error.** `git commit` in a conflicted tree
   prints `U<TAB>path` lines, and because stdout is block-buffered they land
   *after* the error when both streams go to one place. gittle flushed, and
   got the order backwards.
8. **`checkout <paths>` reports how much it did; `checkout -- <paths>` does
   not.** `count_checkout_paths = !quiet && !has_dash_dash`. The separator
   changes the output, which is not a thing one would guess.
9. **…and the count is of files actually *written*.** `checkout_entry`
   returns without writing when the file already matches its index entry, so
   `checkout --ours .` in a two-file conflict says `Updated 2 paths`, not 8.
   Finding this out found a second bug: gittle's index was smudging the stat
   data of every file it had just written itself, because its racy-clean check
   lacks git's `!ce_uptodate(ce)` guard. Comparing content instead of trusting
   the smudged size fixes both.
10. **A stash's three commit messages do not agree about trailing newlines.**
    `index on …` and `untracked files on …` end in one; `WIP on …` does not.
    An object ID is the hash of exact bytes (R1), so this is the difference
    between a stash git recognises and one it does not.
11. **`stash drop` has to rewrite a reflog.** The stack *is* `refs/stash`'s
    reflog, so dropping `stash@{1}` means deleting a line and re-chaining the
    old-value column — and moving the ref must not itself append an entry, or
    the drop becomes `stash@{0}`.
12. **`a` sorts before `a/b`.** A directory/file conflict renames the file to
    `a~HEAD`, and gittle removed the old `a` in the same pass that wrote the
    new paths — so it tried to create the directory `a` while the file `a` was
    still there. The removals are their own pass now.
13. **…and the failure was invisible.** `writeFile` into a path whose parent
    is a file raises `IOError`, and `main` was catching every `IOError` as "a
    closed pipe" and exiting **0**. `gittle merge` printed nothing, changed
    nothing and reported success. The guard now checks `errno == EPIPE`, which
    is the case it was for.

The last two are the ones the harness did *not* find: a D/F conflict is rare
enough that it was not in any fixture, and it took probing the case by hand
against git to see it. Both fixtures are in the sweep now.

## Deliberate divergences, and why each is acceptable

| | |
|---|---|
| **rename detection** | v2 backlog (plan.md §8). git carries an edit across a rename; gittle sees a delete and an add and reports modify/delete. This is the single largest behavioral gap in the phase, and it is also most of why `merge-ort.c` is 5,600 lines. |
| **patch-id equivalence in `rebase`** | git's todo list drops commits already upstream as clean cherry-picks (`--cherry-mark`, cut in docs/04). gittle replays them — and then drops them at commit time with git's own `dropping … -- patch contents already upstream`, because such a commit replays to the tree it was replayed onto. What differs is the count in `Rebasing (n/m)` and the todo list `status` shows. |
| `git diff` against an unmerged index | a *combined* diff, cut in phase 5 (docs/03). `diff --cached` is implemented and prints `* Unmerged path <p>` as git does; plain `diff` prints nothing for those paths. |
| a third and later merge base | folded against the last real base rather than against a virtual commit git would have written to the object store. Exactly git for the two-base case, which is the one that occurs. |
| `-s`/`-X`, `--squash`, `--log`, `--autostash`, `--allow-unrelated-histories` | docs/05 and docs/07 |
| `-m <parent>` for picking or reverting a merge; the octopus strategy | docs/05, docs/06 |
| `rebase -i`, `--exec`, `--autosquash`, `--rebase-merges`, `--keep-base`, `--root`, `--fork-point` | docs/08 |
| `stash save`, `branch`, `create`, `store`, `export`/`import`, `-p`, `--index` | docs/08 |
| `--diff3`/`--zdiff3`, `--ours`/`--theirs`/`--union` in `merge-file` | docs/10 |
| rerere | cut in docs/05 |
| no hook fires | plan.md decision 1: `pre-commit` and `commit-msg` run for `commit` and nothing else, so `pre-merge-commit` and `post-merge` do not run |
| `AUTO_MERGE` is not written | the two things that read it — `--remerge-diff` and `checkout --merge` — are both cut |

## Results

`tests/oracle.sh --full`, 170 checks across seven phases, all passing.

| Check | Coverage |
|---|---|
| `merge-file` | 400 random three-way cases, seeded and reproducible: small repetitive edits, so the two sides genuinely overlap, and a tenth of the files missing their final newline |
| `merge` | 36 merges over seven fixtures — every conflict shape, a fast-forward, a criss-cross with two merge bases, an annotated tag, unrelated histories, a directory/file collision both ways round — each concluded, aborted, quit and continued |
| `checkout --ours`/`--theirs` | 17 ways to resolve a conflict by hand, including the ones that must fail |
| `cherry-pick` and `revert` | 31 replays: single, several, a range, `-x`, `-s`, `-n`, and every sequencer verb from a state gittle itself created |
| `rebase` | 17 rebases, stopped and resumed, including `--skip` and `--onto` |
| `stash` | 26 pushes, pops, applies and drops, with an untracked file, a pathspec, `-k`, and a two-deep stack |
| `read-tree -m` | 15 one-, two- and three-tree reads, with and without `-u`, against clean, dirty, staged and untracked-in-the-way starting states |
| `status` during all of it | every check above also compares **both tools' own `status`, `status --porcelain=v2`, `ls-files -u` and `branch -a`** on the resulting repository |
| `git fsck --strict` | clean in seven repositories gittle merged, picked, reverted, rebased and stashed in — the question an output comparison cannot ask: is what gittle *wrote* a repository git considers sound? |

### How the state is tested

Phase 6's rule — run the command in two identical copies and compare
everything either tool could have written — is necessary here but no longer
sufficient, because half of what these commands write is *state to be
continued from*. Two changes:

* **`p6state` grew the in-progress markers**: `MERGE_HEAD`, `MERGE_MSG`,
  `MERGE_MODE`, `ORIG_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`,
  `REBASE_HEAD`, the `sequencer/` files and the nine `rebase-merge/` ones.
  A `merge` that leaves the right working tree and the wrong `MERGE_MSG` is a
  merge `commit` will conclude with the wrong message.
* **`p6mut` grew `p6own`**: after each command, *each tool's own view* of the
  resulting repository is compared — `status` long and porcelain,
  `ls-files -u`, `branch -a`. A neutral observer cannot catch a `status` that
  describes a state both tools agree on differently, and four of this phase's
  bugs were exactly that.

And one addition that matters more than either: a test's `PREP` now runs with
`$GITX` bound to *the tool under test in that copy*. So
`PREP='$GITX cherry-pick topic' p6mut cherry-pick --continue` asks gittle to
continue a state **gittle itself created**, and git to continue git's — which
is the only way to test that the two states are interchangeable.

## Layout as built

```
src/
  mergefile.nim   the three-way file merge: xdl_merge and both refinements   166
  mergetree.nim   the structural merge: per-path rule, stages, virtual base  171
  sequencer.nim   the in-progress state, and the shared commit-and-report    149
  status.nim      + unmerged paths and the in-progress block    404 (was 249)
  cmd/
    merge.nim                                                                193
    mergefile.nim                                                             48
    cherrypick.nim  cherry-pick and revert                                   189
    rebase.nim                                                               253
    stash.nim                                                                259
    readtree.nim    + -m, --reset and -u                            79 (was 32)
```

The minimisation pass moved three things, each because another caller
appeared, and found one bug by reading:

* **`commitOnHead` and `finalMessage` came out of the five commands.** "Write
  the index out as a tree, commit it, move HEAD, write the index" was written
  three times with three sets of arguments; the message dance — write
  `COMMIT_EDITMSG`, maybe open an editor, read it back, clean it up — twice.
  Both are in `sequencer.nim` now, and the callers are down to the two things
  that genuinely differ: the parents and the reflog line.
* **`applyThreeWay` came out of `cherry-pick`.** `rebase` wanted the same
  three lines.
* **`upToDate` came out of `applyMerge` and `checkoutPaths`.** "Is this path
  already exactly this version, in both the index and the working tree" was
  written twice and *wrong* the second time — see bug 9.

And the bug: `stash apply` puts the index back to what it was for every path
that was already in it, and was leaving the **stat data** of the file the
merge had just written attached to the restored entry. An entry whose stat
matches a file it no longer describes is exactly what `status` trusts, so the
path would have been reported unmodified. It passed the sweep only because
the index write smudges a just-written entry's size to zero and the next
reader therefore compares content anyway — which is luck, not a design. The
entry is rebuilt without stat data now, the way `resetIndexTo` does it.

`summarizeCommit` is the other shared piece and it is shared with phase 4:
`commit`, `cherry-pick`, `revert`, `rebase --continue` and `merge --continue`
all print `[branch abc1234] subject` with the same four optional lines under
it.

## Budget

```
                                          budgeted   actual
merge: file 3-way + structural tree merge      600      486   mergefile 166 + mergetree 171 + sequencer 149
argument parsing, the phase's 7 commands       ---      989   cmd/merge, mergefile, cherrypick, rebase, stash, readtree
unmerged paths and in-progress reporting       ---      155   status.nim
everything else                                ---      165   diffcore, worktree, index, refs, checkout, commit, add, branch, diff, the driver
                                                    -------
phase 7                                                1,795
```

Total: **10,756 lines of code** (15,788 including comments), against the
~12,300 plan.md §5.1 projects for v1 with phases 8 and 10 still to build.
The static binary is 2.8 MB.

The algorithm came in **114 lines under** its 600, and that is not luck: a
three-way merge is two diffs and the diff engine already existed, so
`mergefile.nim` is 166 lines rather than the several hundred a from-scratch
merge would be. `mergetree.nim` is small for a worse reason — it is
`merge-ort.c` with rename detection removed, and rename detection is most of
that file.

The command layer cost 989 for seven commands, which is 141 apiece against
the 106 phase 6 averaged. The over-run is entirely the **state machines**:
`stash` (257) and `rebase` (253) are the two largest command files in the
project, and neither has a large option surface. What they have is a
directory of files to write, read back and remove correctly under four verbs.
That is a cost §5 does not model at all — it counts option combinations — and
phase 8's `clone`/`fetch`/`push` have the same shape.

Against §5.1's revised estimate of 1,200 for "the remaining 23 commands"
across phases 7, 8 and 10: seven of them have now cost 989. The remaining 16 are
mostly small (`gc`, `clean`, `check-ignore`, `mv`, `rm`), but `clone`,
`fetch` and `push` are state machines too. **Revised again: 1,000 more for the
command layer, putting v1 near 13,000.** The number is recorded here rather
than cut against, for the reason §5 gives — it is a measurement.

## What was left undone, and where it belongs

| | |
|---|---|
| rename detection, and with it `merge -X find-renames`, `rename/rename` and `rename/delete` conflicts | **v2 backlog** (plan.md §8). The largest gap in the phase, and stated as one. |
| patch-id equivalence — `rebase`'s todo list dropping commits already upstream, and the `cherry` command | v2, with rename detection: both want a `patch-id`, which nothing else in v1 needs |
| combined diffs, so that plain `git diff` against a conflicted index shows something | v2; cut in phase 5 (docs/03) and unchanged by this phase |
| `merge --squash`, `--log`, `--autostash`, `--allow-unrelated-histories` | docs/05 and docs/07 cut them; nothing here needs them |
| `rebase -i` and the todo verbs beyond `pick` | docs/08 cuts it. The `rebase-merge` directory gittle writes is the interactive machinery's, so the ground is prepared. |
| `stash branch`, `create`, `store`, `export`/`import`, `--index` | docs/08 |
| `pull` — which is `fetch` and then this phase's `merge` or `rebase` | **phase 8**, where `fetch` arrives |
| `am` and `apply` | v2 backlog |
| `worktree`, `gc`, `clean`, `check-ignore` | phase 10 |
