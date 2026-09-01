# Phase 5 — diff, status and grep

The fifth phase of the build order in [plan.md](plan.md) §7. Ends when
`gittle diff` in all its forms, `status` in all four output formats, and
`grep` agree with real git; when `log` and `show` print the patches they have
been promising since phase 4; and when `commit` prints the diffstat under its
summary line.

**Status: complete (2026-09-01).** All eight tasks done; `tests/oracle.sh
--full` passes 149 checks across five phases. See [Results](#results).

---

## Environment

Unchanged from [phase 4](phase-4.md). The oracle is `../git`, built from the
reference tree; `tests/oracle.sh` prefers it over `PATH` automatically.

## What this phase actually is

Phases 1–4 built the on-disk formats and the vertical slice that writes them.
Everything so far could be checked by *reading back what gittle wrote*. This
phase is the first that has to reproduce a **judgement**: given two versions
of a file, git chooses one of many correct patches, and which one it chooses
is not in any specification. A diff that is valid but laid out differently
disagrees with git on every file it touches.

So the phase divides into one hard problem and a lot of formatting:

* **The engine** (`diff.nim`) — Myers, plus the three post-processing layers
  that decide *which* minimal diff gets printed. This is the part that had to
  be written from git's source rather than from the paper.
* **The plumbing** (`diffcore.nim`) — what gets compared with what, and the
  seven output formats the `diff-options` family defines.
* **The presentation** (`status.nim`, `cmd/grep.nim`) — `status` in four
  formats, and `grep` over three sources.

Two engines arrive with it, and one of them turned out not to be an engine at
all — see the regex decision below.

## The regex engine — decision, with the spike that settled it

plan.md decision 3 budgeted **~500 lines for a vendored ERE engine**, and §6.4
asked that the libc route (candidate **B**) be spiked first at this phase,
because it is what git itself does: `compat/regex/` is compiled only when
`NO_REGEX` is defined for a libc lacking `REG_STARTEND`.

**The spike was run and candidate B wins outright.** A 22-pattern table was
put through `git grep -E` and through a Nim binding to `regcomp`/`regexec`,
including every case plan.md §6.4 nominated as a place the flavors might
disagree:

| pattern | why it was chosen | agreed |
|---|---|---|
| `a+b`, `a?`, `a{2,3}`, `a**` | ERE quantifiers | yes |
| `\(x\)` | BRE grouping written into an ERE | yes |
| `[[:alpha:]]+` | POSIX character classes | yes |
| `)`, `(a`, `[a-` | malformed patterns — **error text identical**, not merely both-failing | yes |
| `a\|`, `(\|x)b` | empty alternation branches | yes |
| `^ab$`, `b$`, `^`, `$` | anchors at a slice boundary | yes |
| an embedded NUL | `REG_STARTEND` handling | yes |
| `-i` with `A+B`, `ALPHA` | case folding | yes |

Two things beyond agreement: `gcc -static` links it, so the single-binary goal
survives; and the compile-error strings come out **byte-identical to git's**,
because git calls the same `regerror` on the same libc. There is nothing to
paraphrase and nothing to keep in sync.

**Cost: 45 lines of binding against a 500-line budget.** The 455 lines go back
to the project.

**The one trap**, which cost the spike its only wrong turn and is now the
longest comment in `regex.nim`: under `REG_STARTEND`, `^` anchors to the
**true start of the buffer**, not to `rm_so`. Confining a match to one line by
setting `rm_so`/`rm_eo` therefore makes `^` match only on a file's first line.
git avoids it by passing a pointer to the line itself with offsets `0 .. len`
— so the buffer *begins* at the line — and `REG_STARTEND` is what makes that
safe when the bytes after it are not a terminator.

**The divergence this leaves.** git's `grep` and `log --grep` default to
**BRE**; docs/07 keeps `-E` and cuts `-G` and `-P`, so gittle's patterns are
ERE always and `-E` is a no-op. `gittle grep 'a+b'` reads `+` as a quantifier
where `git grep 'a+b'` reads it as a literal. `-G` and `-P` are refused by
name rather than silently treated as ERE.

## The diff engine — how faithful, and the measurement that decided it

git's `xdiff/` is 3,907 lines of C. Reproducing its *output* is not the same
problem as reproducing Myers, and the difference is three layers:

1. **`xdl_change_compact`** — slides every run of changed lines as far as it
   will go and then chooses where it lands, including the **indent
   heuristic**, a weighted score over blank lines and indentation around the
   two split points.
2. **The non-minimal search heuristics** in `xdl_split` — a "good enough"
   snake past a cost threshold, and a hard cost ceiling.
3. **`xdl_cleanup_records`**'s `INVESTIGATE` path — discards lines that occur
   *too often* to be worth matching.

Layer 1 is cosmetic in intent and layers 2 and 3 are accelerators, but all
three change which patch is printed. So the question was measured rather than
argued, over 400 commits of the repository next door:

| | commits whose output changes |
|---|---:|
| the indent heuristic (layer 1) | **15 of 400** (3.7%) |
| the non-minimal heuristics (layers 2–3) | **10 of 400** (2.5%) |

**Decision: implement layer 1 in full, and cut layers 2 and 3.**

Layer 1 is bounded, well-specified, and improves *readability* — a
user-visible quality — so its weights are copied verbatim rather than
invented. Layers 2 and 3 exist to bound CPU on inputs far larger than gittle's
targets, which is R3's definition of an accelerator, and cutting them is
exactly what `git diff --minimal` selects.

**The consequence is stated rather than hidden:** gittle's `diff` is git's
`diff --minimal`. Both are correct patches for the same change. The oracle
compares against `--minimal` for that reason, the way it passes
`--no-use-mailmap` for `log` — which makes the difference *tested* rather than
merely absent.

One piece of layer 2 is implemented anyway, because it is not a heuristic:
`trim_common_tail` runs only at `-U0`, where no context is printed and a
shared tail cannot appear in the output. Without it, `-U0` disagreed on one
file pair in 2,756.

### What the sweep found

Every file pair from 900 real commits — 2,756 pairs — run through both engines
at five context widths and four whitespace modes. It ended at **0 differences**,
but not before finding four bugs that no amount of reading would have:

| symptom | cause |
|---|---|
| a hunk placed one line off, on 2 pairs in 168 | `xdl_cleanup_records` counts a line's occurrences over the **whole file**, not over the region left after trimming. Counting the trimmed region discards a line that also appears in the common head, and the search then settles on a different — still minimal — diff. |
| a hunk header ending in half a UTF-8 character, on 4 pairs in 2,154 | git truncates the funcname to 80 bytes (`xemit.c:def_ff`) and then truncates the **whole header line** at the first invalid UTF-8 sequence (`diff.c:fn_out_consume` → `sane_truncate_line`). Six probe cases were needed to separate "is byte 79 whitespace?" from "is the sequence complete?", because the two hypotheses agree on every natural input. |
| `-U0` disagreeing on 1 pair in 2,756 | `trim_common_tail`, above. |
| `new file mode 100664` where git says `100644` | every mode is normalised through `canon_mode` before it reaches the diff. git's own root commit records `100664`. |

## What a diff is made of

`git diff` looks like several commands and is one, parameterised by which two
of three things it compares. Each side is a sorted list of `(path, mode, oid)`
and the pairing is **one merge join** (R7):

| invocation | old side | new side |
|---|---|---|
| `diff` | the index | the working tree |
| `diff --cached [<commit>]` | a tree, `HEAD` by default | the index |
| `diff <commit>` | a tree | the working tree |
| `diff <a> <b>` | a tree | a tree |
| `diff --no-index <p1> <p2>` | a file | a file |
| a commit, for `log`/`show` | the first parent's tree, or the empty tree | its own tree |

The one asymmetry is the working tree, which has no object IDs of its own: an
entry whose `stat` still matches the index borrows the index's, and one that
does not is hashed — but **only when something needs the number**. `--raw`
does not, and prints the null OID; `-p` does, for the `index` line. Both
behaviors are git's and both are reproduced.

## Deliberate divergences, and why each is acceptable

Every one of these is a *documented* cut rather than an oversight, and each is
tested by pointing the oracle at the option that selects git's matching
behavior.

| | what gittle does | oracle flag |
|---|---|---|
| **rename detection** (`-M`/`-C`) | never detects one; a rename is a delete plus a create. plan.md §4 cuts it at ~2,000 lines of C, and git turns it **on by default** for `diff` and `log -p` | `--no-renames` |
| **non-minimal Myers** | always minimal — see above | `--minimal` |
| **combined merge diffs** (`-c`/`--cc`) | a merge commit gets no patch. docs/03 cuts the family, leaving `--diff-merges=off`, which is what git did by default before 1.5. Note `show` defaults to `--cc` where `log` does not, so the difference is visible on `show <merge>` | `--diff-merges=off` |
| **`.mailmap`** | inherited from phase 4 | `--no-use-mailmap` |
| **whitespace-error painting** under `--color` | the escape-code *structure* is byte-exact, but a `+` line with trailing whitespace is not repainted red. The machinery serves `--check`, `--ws-error-highlight` and `apply --whitespace`, all three cut — R6 exactly | — |
| **`utf8_strwidth`** in the `--stat` bar | counts characters, not display columns, so a path with East Asian characters can leave the bar one column out. The wcwidth tables are several hundred lines and the bar is decoration | — |

## Task list

1. **The regex binding.** `REG_STARTEND` line matching, `-i`, `-F`, and the
   word-boundary retry loop. *Oracle: a pattern table through `git grep -E`.*
2. **The diff engine.** Split, classify, trim, discard; Myers over the reduced
   index space; change compaction with the indent heuristic; hunks with
   context and the enclosing-definition line. *Oracle: every file pair of 900
   commits, enumerated.*
3. **The shared diff options** (docs/03) and the seven output formats: patch,
   raw, stat, shortstat, numstat, name-only, name-status.
4. **`diff`.** The five invocation forms, `--diff-filter`, `-S`, `-R`, `-z`,
   `--color`, `--exit-code`.
5. **`log` and `show`.** The diff under each commit, the `---` separator when
   a stat and a patch are both asked for, and `--grep`/`--author`/
   `--committer` with their combining rules.
6. **`commit`.** The shortstat and the create/delete/mode-change lines, and
   the full `status` output on "nothing to commit".
7. **`status`.** The model, then the long, short, porcelain v1 and porcelain
   v2 formats, `-b`, `-u<mode>`, `-z` and pathspecs.
8. **`grep`.** The working tree, the index, a tree, and `--no-index`; the
   pattern and output options docs/07 keeps.

## What is deliberately deferred, and to where

| | |
|---|---|
| revision ranges (`A..B`, `^A`, `HEAD~3`, `--all`) — so `diff HEAD~1` and `show HEAD~1` still fail | phase 6, with `rev-parse` |
| `--topo-order`, `--date-order`, `--since`, `--until` | phase 6 |
| unmerged (stage > 0) paths in `status` and `diff` — the `U` letter and `Unmerged paths:` | phase 7, with the merge machinery |
| the in-progress states: merge, rebase, cherry-pick, revert, bisect | phase 7 |
| `status --ignored`, `grep --untracked` | docs cut them; the engine is here |
| upstream tracking, in all three formats: `Your branch is up to date with 'origin/main'.` (long), `## main...origin/main [ahead 1]` (short), `# branch.upstream` and `# branch.ab` (porcelain v2) | phase 8 for the remote, phase 6 for the ahead/behind count |

## The oracle procedure

Two additions to the phase-4 discipline.

**Enumerate the file pairs, not the commits.** A commit-level comparison
reports "these two commits differ" and leaves the reason to be found by hand.
Comparing every *blob pair* through both engines directly, with the four
header lines stripped, points at the file — and that is how all four engine
bugs above were located.

```sh
# the engine alone, against git's, over real history
for c in $(git rev-list --no-merges -n 900 HEAD); do
  for f in $(git diff-tree -r --no-renames --name-only "$c^" "$c"); do
    git cat-file blob "$c^:$f" > a; git cat-file blob "$c:$f" > b
    diff <(git diff --no-index --minimal $FLAGS -- a b | tail -n +5) \
         <(selftest diff $FLAGS a b)
  done
done
```

**Run from somewhere other than the root.** Two of the ten bugs above were
invisible to every sweep in the file because all of them ran from a
repository root, and the prefix is exactly the kind of thing a reimplementation
gets wrong once and never notices.

**Sweep `status` over repository states, not over options.** The four formats
are cheap to enumerate; what is expensive to get right is the *state* they
describe. The suite walks a repository through eleven of them — empty, no
commits, staged before the first commit, clean, unstaged, staged, both,
deleted, typechanged, mode-changed, with ignore rules — and runs all fourteen
option combinations at each.

## Layout as built

```
src/
  regex.nim       the libc ERE binding, and the two options around it        85
  diff.nim        Myers, compaction, the indent heuristic, hunks            499
  diffcore.nim    the shared options, the four pair sources, seven formats  537
  status.nim      the model, and the long/short/porcelain formats          185
  cmd/
    diff.nim                                                                 92
    status.nim                                                               79
    grep.nim                                                                254
```

`grep`'s search engine is inside `cmd/grep.nim` rather than beside it. Nothing
else consumes it — R6 and R7 both say not to make a module for one caller —
and the line-slicing it does is not the diff engine's, because a grep line is
a byte range in a buffer that must not be copied.

`isBinary` moved to `objects.nim` during the minimization pass, having been
written identically in `diffcore.nim` and `cmd/grep.nim`. It belongs there:
"is this blob binary" is a fact about object content, and with no
gitattributes it is the same four lines for every consumer.

---

## Results

`tests/oracle.sh --full`, 149 checks across five phases, all passing.

| Check | Coverage |
|---|---|
| diff engine | **2,756 file pairs** from 900 real commits, hunk for hunk, across five context widths and four whitespace modes |
| `diff` | 60 option and invocation forms, including `-z` compared as bytes, both `--quiet` exit statuses, `-s`'s order-sensitivity against every other format, and `--no-index` outside a repository |
| `log` and `show` diffs | 93 format combinations, over a commit, a merge, a root commit, a tag and a tag of a tag |
| `log --grep`/`--author` | 12 pattern combinations, including the AND/OR rules and `--invert-grep` |
| `status` | **176 combinations over 11 repository states** — empty, no commits, staged before the first commit, clean, unstaged, staged, both, deleted, typechanged, mode-changed, and with ignore rules |
| `commit` | the diffstat, the create/delete/mode-change lines, and the whole of `status` on "nothing to commit" |
| `grep` | 121 combinations over the whole reference repository — binary files, empty files, gitlinks and symlinks included |
| `status`, on the real repository | two nested repositories, a submodule gitlink and a configured upstream — none of which a constructed fixture has |
| from a subdirectory | 20 `status`, `diff` and `grep` forms, where the three commands resolve paths three different ways |
| ERE engine | 20 patterns, error text included |

### What the oracle caught that reading would not have

Eight bugs, and not one was visible in any documentation.

**In the engine** — all four found by comparing *file pairs* rather than
commits, which is what points at the file:

1. **Occurrence counting.** `xdl_cleanup_records` counts a line's occurrences
   over the whole file; counting the post-trim region instead discards a line
   that also appears in the common head, and the search settles on a
   different, still minimal, diff. 2 pairs in 168.
2. **UTF-8 in a hunk header.** git truncates the name to 80 bytes and then
   truncates the whole header line at the first invalid UTF-8 sequence. Six
   probe cases were needed to tell "is byte 79 whitespace?" from "is the
   sequence complete?" — the two hypotheses agree on every natural input and
   disagree only on a deliberately constructed one.
3. **`trim_common_tail`.** git trims a shared 1 KiB-block tail before diffing,
   but only at `-U0`. 1 pair in 2,756.
4. **`canon_mode`.** Every mode is normalised before it reaches the diff;
   git's own root commit records `100664` and git prints `100644`.

**In the command layer**, all four found by the option sweep:

5. **`splitTypeChange` dropped a flag.** Splitting a type change into a
   deletion and a creation lost "read this side from the working tree", so
   `diff -R` on a repository containing a typechange tried to read the null
   object.
6. **Formats are not additive.** `--raw --name-only` prints names *only*:
   `diff_setup_done` clears every other output bit as soon as a name format is
   selected. gittle had been printing both.
7. **`--` did not settle the ambiguity.** `diff HEAD -- a.txt` treated `HEAD`
   as a path, because the "is this a revision or a path" test asked whether
   any paths had been seen yet — and `--` had already filled that list. The
   same bug was in `log`, inherited from phase 4.
8. **`--abbrev=<n>` reached only half of what it names.** git has one
   `--abbrev`, shared by the commit header and the diff's `index` line;
   gittle's `log` consumed it before the diff options saw it.

**Two more the sweep did *not* catch**, and that is the more useful lesson.
Every sweep in `tests/oracle.sh` ran from a repository root, so nothing
exercised the prefix — and three commands print paths three different ways:

9. **`status` and `grep` printed root-relative paths.** git prints both
   relative to the directory you are standing in (`status.relativePaths`,
   default true, and `grep`'s `--full-name` is the opt-out docs/07 cuts).
   `diff` is the odd one out and is *always* root-relative, because a patch
   has to apply from the root.
10. **Porcelain v1 is the only format that ignores the prefix.**
    `wt-status.c:wt_porcelain_print` clears `relative_paths` for v1 and the v2
    printer does not — so `--porcelain=v2` from a subdirectory says
    `../top.txt` where `--porcelain` says `top.txt`. That is surprising enough
    that it would never have been written from the documentation, and it is
    the wire.

Both were found by running the commands from a subdirectory by hand. The suite
now sweeps 20 forms from one, which is the check that should have existed
first.

Two more were phase-4 bugs that this phase's wider sweep exposed: `show`
printed a tag's `Tagger:`/`Date:` lines under `--oneline`, where git prints
neither, and under `--format=fuller`, where git pads the label and writes
`TaggerDate:`; and `show` separated two tag objects with the format's
separator, where git always separates them with a bare newline.

### One phase-4 behavior changed

The working-tree walk used to print a warning and skip a directory containing
its own `.git`. That was decided in phase 4 for `add`, and it was wrong for
everything else: git reports such a directory as one untracked entry --
`?? gittle/` from `status`, `gittle/` from `ls-files -o`, under every
untracked mode -- and never descends. On the reference repository, which has
two nested repositories and a real submodule, gittle's `status` was missing
both entries and inventing a type change for the gitlink.

The refusal moved to where it belongs: the walk reports the directory, and
`add` refuses to stage it. Staging is the only operation that would need the
160000 gitlink gittle cannot write.

### The four flags the oracle now passes git

Each corresponds to a cut this project made deliberately, and passing the flag
is what makes the divergence *tested* rather than merely absent:

```
--no-renames        gittle detects no renames (plan.md §4)
--minimal           gittle's Myers is always minimal (above)
--diff-merges=off   combined merge diffs are cut (docs/03)
-c diff.cpp.xfuncname=…   the reference repository's own .gitattributes sets
                    diff=cpp, and a userdiff driver changes the name on a
                    `@@` line (decision 6 cuts gitattributes)
```

## Budget

```
                                       budgeted   actual  cumulative
diff: Myers + unified emit                  500      499   diff.nim
regex engine (ERE subset)                   500       85   regex.nim
working tree: checkout, status              600      185   status.nim (checkout is phase 6)
command dispatch, arg parsing, 53 cmds    2,000    2,393   20 commands + driver
```

Total: **6,940 lines of code** (10,963 including comments) of the ~9,000
budgeted, with phases 1–5 of 10 complete. The static single binary still
links: 2.2 MB, and libc's regex is the only thing the phase added to it.

**The regex line is the phase's happiest number: 85 against 500.** Decision 3
assumed a vendored engine; §6.4 asked for the libc route to be spiked first,
and it won on every axis at once — fewer lines, no new dependency, identical
error text, and static linking intact. The 415 lines go back to the project,
which matters given the next paragraph.

### The command layer, and phase 4's recommendation

phase-4.md recommended revising §5's 2,000-line command-layer budget to
**2,600** and re-scoping the line as "commands *and output formatting*", so
that moving code out of `cmd/` stops looking like a saving. It also asked
specifically what `status` would cost. Both answers are worse than predicted:

* `cmd/` plus the driver is **2,393** for 20 of 56 commands.
* Counted as phase 4 proposed — adding `pretty.nim` (394), `diffcore.nim`
  (537) and `status.nim` (185) — it is **3,509**, already 35% past the
  revised 2,600 with 36 commands still to write.
* `status` itself is cheap (79 + 185 = 264). The expensive one was `diff`:
  92 lines of command over 537 of shared formatting, because the
  `diff-options` family is shared by eight commands and every one of its seven
  output formats is a separate emitter.

The prediction failed for a reason worth naming: phase 4 extrapolated from
*commands*, and the command layer does not scale with commands. It scales with
**shared option surface**, and phase 5 landed the largest shared group in git
(docs/03 calls it "the single highest-leverage list in the whole inventory").
There is no comparable group left — docs/04's revision options are the only
other large one, and phase 6 spends it.

**Recommendation: stop budgeting the command layer as one number.** Split §5's
line into "argument parsing, 56 commands" (which is tracking near 40 lines a
command and will land around 2,300) and "shared output formatting" (`pretty`,
`diffcore`, `status`: 1,106 so far, with `rev-list`/`for-each-ref` formatting
still to come). The total is what matters, and the total is 6,915 of 9,000
with the three remaining algorithm blocks — merge 600, transport 700, pack
write 500 — budgeted at 1,800. That leaves roughly 300 lines of slack for
everything else in phases 6–10, which is not enough. **§5 needs re-planning
before phase 6 starts, not after it.**

## Notes carried forward

- **`--color` does not paint whitespace errors.** The escape-code structure is
  byte-exact for every line without one, but a `+` line with trailing
  whitespace is not repainted. The machinery serves `--check`,
  `--ws-error-highlight` and `apply --whitespace` — all three cut — which is
  R6's case exactly. It is the one place where gittle's coloured output
  differs from git's, and the oracle does not test it.
- **The `--stat` bar counts characters, not display columns.** git uses
  `utf8_strwidth`, which consults a wcwidth table so an East Asian character
  counts two. A path with such characters can leave the bar one column out.
  Several hundred lines of table for a decoration.
- **`show <merge>` prints no patch**, where git defaults to `--cc`. `log`
  agrees with gittle here and only `show` diverges, which makes it the most
  visible of the four documented cuts.
- **`grep`'s patterns are ERE, always**, where git's default is BRE. `-G` and
  `-P` are refused by name.
- **Unmerged paths are absent from `status` and `diff`.** A path at stage 1, 2
  or 3 is skipped rather than reported as `U`, and the long format has no
  `Unmerged paths:` section. Phase 7, with the merge machinery that creates
  them.
- **`status` says nothing about the upstream branch**, and this is the one
  phase-5 gap visible on an ordinary *cloned* repository rather than only on a
  constructed one. Measured against the reference repository: with those three
  forms filtered out, every other byte of all four formats agrees. It needs
  two things gittle does not have yet — `branch.<name>.remote`/`.merge` and the
  remote-tracking ref (phase 8), and a range count for ahead/behind (phase 6)
  — so it cannot land here without pulling both phases forward.
- **`log -z` sets the record terminator for the whole command**, not only for
  the diff records, which is git's behavior and was easy to get wrong: the
  separator between two commits becomes a NUL too.
