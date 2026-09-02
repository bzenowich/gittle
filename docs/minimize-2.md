# Minimising gittle, second pass — 11,724 to 8,000

Status: **proposed 2026-09-02, nothing decided.** §10 is empty on purpose;
it is the section this document exists to fill.

The brief: the first pass ([`minimize.md`](minimize.md)) took v1 from 13,872
to 11,724 lines. The target now is **about 8,000**.

Measured, as everywhere else in this project, in non-blank non-comment lines
(`grep -vE '^\s*(#|$)'`). Comments are free; they always were.

---

## 1. The arithmetic, before anything else

| | lines |
|---|---:|
| v1, before the first pass | 13,872 |
| after the first pass (2026-09-02) | 11,724 |
| target | 8,000 |
| **still to find** | **−3,724 (−32%)** |

The first pass found −2,148 (−15.5%) and it had five whole strategies to
spend: delete the plumbing wrappers, turn the options into a table, exec
`diff(1)`, drop the byte-exact output surface, fold the duplicated helpers.
Its own leftovers list (§9 of that document) totals **about 200 lines**.

So this is not the same job again. −32% off an already-minimised tree is a
decision about **what gittle is**, and the honest summary of everything
below is:

> Refactoring, in every form still available, is worth **−1,510** and lands
> at **10,214**. Deleting every command outside the daily loop — including
> `rebase` and `worktree`, which the first pass kept — is worth another
> −1,424 and lands at **8,790**. The last **790** is not in the command
> list either: the only item that size still standing is the three-way
> merge, and cutting it makes gittle fast-forward-only.

That is the finding, and it is worth stating before the tables: **8,000 is
not reachable while gittle can merge.** The rest of this document prices
each step of that sentence so the trade can be made deliberately.

---

## 2. Where the lines are now

| | lines | share |
|---|---:|---:|
| engine modules (`src/*.nim`, 40 files) | 7,558 | 64% |
| command files (`src/cmd/*.nim`, 40 files) | 4,166 | 36% |

The ten largest engine modules, and the ten largest commands:

| module | lines | | command | lines |
|---|---:|---|---|---:|
| `diffcore` | 511 | | `push` | 267 |
| `refs` | 481 | | `branch` | 265 |
| `revision` | 426 | | `worktree` | 262 |
| `revwalk` | 344 | | `rebase` | 243 |
| `remotes` | 338 | | `stash` | 234 |
| `status` | 329 | | `checkout` | 232 |
| `packfile` | 322 | | `commit` | 210 |
| `transport` | 318 | | `merge` | 196 |
| `pretty` | 288 | | `cherry-pick` | 180 |
| `repository` | 288 | | `grep` | 152 |

Three procs are large enough to be structural facts rather than functions:
`remotes.fetchFrom` (251), `cmd/push.cmdPush` (273) and
`cmd/commit.cmdCommit` (228). Each runs to the end of its file.

Three cross-cutting counts, because they turn up in several proposals below:

| | count |
|---|---:|
| `opt(...)` table rows (279 in `cmd/`, 49 in the shared tables) | 328 |
| `okRefused` rows | 46 |
| `failIf` / `fail(` call sites | 405 |
| physical lines that are a **continuation of a string literal** (169 in `cmd/`, 171 in `src/`) | 340 |

That last row is the one worth staring at: 2.9% of the codebase is wrapped
English prose in refusal messages, counted as code because it is not a `#`
comment.

---

## 3. What the logs still say

Re-measured against `git-tool-calls-p4gui.md` and `git-tool-calls-stm32.md`,
the same 509 invocations the original scope was drawn from:

| verb | uses | | syntax | uses |
|---|---:|---|---|---:|
| `worktree` | 39 | | `--since` / `--until` / `--after` / `--before` | **0** |
| `stash` | 36 | | `@{u}` | 1 |
| `merge-base` | 22 | | `@{<n>}`, `@{<date>}`, `@{-<n>}` | **0** |
| `ls-tree` | 18 | | `:/<text>`, `^{/<regex>}` | **0** |
| `grep` | 13 | | | |
| `ls-files` | 11 | | | |
| `rev-list` | 9 | | | |
| `check-ignore` | 4 | | | |
| `for-each-ref` | 3 | | | |
| `reflog` | 2 | | | |
| `rebase`, `gc`, `clean`, `mv` | **0** | | | |

Two of these change a recommendation the first pass made. `rebase` was kept
in 2026-09-02's decision 2 on the reasoning that "`pull --rebase` and
`rebase main` are the human daily loop" — that reasoning is still true and
still not evidence. And the date-revision machinery in `revision.nim`
serves a syntax that has never once been typed.

---

## 4. Tier A — mechanical, no scope change

Every item here is defensible on R4 or R7 alone, independent of any target.

### A1. Finish §7.1 of the first pass — **−200**

The tree-walk copies, the `revParseRules` builder, the ref-prefix strips,
`%xx`, the two ISO date parsers, the `-z` path field, `readIfExists`.
Already surveyed, already written down as "left, belongs to step 5". No
behaviour changes, and two of them fix live inconsistencies (the two date
parsers accept different dates; the two `%xx` expanders fail differently).

This is the only free money in the document.

### A2. One refusal, one line — **−250**

340 physical lines are string-literal continuations across 405 `failIf`
sites, because gittle reproduces git's wrapped multi-sentence prose:

```nim
  failIf(branch.len == 0,
         "You are not currently on a branch.\n" &
         "  To push the history leading to the current (detached HEAD)\n" &
         "  state now, use\n\n    gittle push " & name & " HEAD:<name-of-remote-branch>\n")
```

Tier 3 of the first pass already conceded that human-facing prose is checked
for content, not bytes. A rule of **one sentence naming the cause and the
flag that overrides it**, on one line, takes most of the continuations out.

Stated plainly because it is the one item here that could be gaming the
metric: this is only worth doing if the messages get *better*. A four-line
paragraph that says what one sentence says is worse prose, not more helpful
prose — but if a message genuinely needs two lines, it should keep them.

### A3. One pattern matcher — **−100**

`glob` (83) + `ignore` (139) + `pathspec` (146) + `refname` (43) = 411
lines, four wrappers over the same fnmatch semantics with four different
edge-case treatments. One matcher plus thin adapters. R7, exactly: a family
of cases that differs only in constants.

### A4. One ref-update report — **−100**

`remotes.nim` carries a `Display` object with `initDisplay` (22),
`emitRefUpdate` (14), `displayRefUpdate` (10), `flush` (6) and
`summaryColumn` (10) — the machinery that right-aligns

```
 * [new branch]      main       -> origin/main
```

into columns whose width is computed from the whole batch. `cmd/push.nim`
has its own report and its own six-entry `Reject` advice array beside it.
One shared `reportRefUpdate(code, summary, from, to)` printing one line per
ref, no column alignment.

The side effect matters as much as the lines: it breaks up the two largest
procs in the project, which the README's "read in an afternoon" claim wants
anyway.

### A5. One status renderer — **−60**

`status.shortLines` (86) and `status.longStatus` (84) render the same
`Status` object twice. A table of (heading, predicate, letter) driving both.

### A6. `diffcore`, audited — **nothing material (−0)**

Audited 2026-09-02. `diffcore` is the largest module (511) and the answer is
that **it is not where the lines are.** Every proc is small and load-bearing:

| | lines | verdict |
|---|---:|---|
| `writePatch` | 89 | the unified-diff format itself |
| `writeStat` | 72 | **already** the trimmed version — the 5/8 : 3/8 name fitting and `...` truncation went in the first pass; what is left is the binary row, the unmerged row, git's `scale_linear` bar, colour and the summary line |
| `applyDiffOpts` | 67 | one `case` arm per option, one line each — a dispatch, not a decision tree |
| `diffOptions` | 35 rows | the shared `-p`/`--stat`/`-U`/whitespace table; B4's business, not A6's |
| everything else | ≤ 46 each | |

The remaining candidate is dropping the `--stat` bar (`scale_linear` and the
`+`/`-` run, ~15 lines) as tier 3 originally proposed. **Recommend against**:
`--stat` has 124 uses in the logs, the count is already printed beside it, and
the bar is the entire reason a human runs `--stat` rather than `--numstat`.

The earlier suspicion that `status(p: DiffPair)` was a 49-line decision tree
was a measurement artifact — a per-proc script attributing a trailing `const`
table to the preceding proc. It is five lines under nine lines of comment
explaining why `T` exists, which is the ratio this project says it wants.

**Tier A total: −710.**

---

## 5. Tier B — structural, the accepted precedents extended

### B1. `grep` becomes `grep(1)` — **−190**

`regex.nim` (85) has exactly one consumer in the project: `cmd/grep.nim`
(152). Building the tracked-path list from the index and exec'ing
`grep -E` with it is about 45 lines.

This is the argument that already won for `diff` in the first pass
(decision 4), and here it is *stronger*, because it is a fidelity gain
rather than a stated loss: the user gets the POSIX ERE engine their shell
has, instead of gittle's approximation of it. busybox has `grep -E`.

What it costs: `--cached` and tree-argument search need the blobs spilled to
a temp directory before `grep` can see them (`$GIT_DIR` already has a
temp-file helper, used for lock files), or those two forms get cut. 13 uses
in the logs, and none of them is `--cached`.

### B2. One transport version — **−90**

`transport.nim` is the one place R4 is still openly violated: it speaks
protocol **v0 and v2**. `handshake` (65), `fetchV2` (31), `fetchV0` (30),
two advertisement shapes inside `lsRefs`, and the `GIT_PROTOCOL` /
`SendEnv` plumbing through `connect`.

`push` already runs v0 against `git-receive-pack`, and there is no v2 push.
`fetch` and `gc` are the only v2 callers, and `fetchV0` already does
everything they need. Drop v2.

What it costs: no `ls-refs` prefix filtering, so the server advertises every
ref it has. On a git.git-sized remote that is ~80,000 pkt-lines to read and
discard — milliseconds, once per fetch. In exchange the transport has one
code path for the first time.

### B3. Revision syntax down to what gets typed — **−120**

`revision.nim` (426) implements a revision grammar of which the logs use
`HEAD`, branch and tag names, `~`/`^`, `..`, and `@{u}` once. Unused, and
what it costs:

| | lines |
|---|---:|
| `parseTimestamp` and the `@{<date>}` / `--since` / `--until` path | 48 |
| `nthPriorCheckout` and `@{-<n>}`, plus the reflog scan it shares with `headDescription` | ~25 |
| `:/<text>` and `^{/<regex>}` message search inside `peelOnion` | ~15 |
| `failAmbiguous`'s near-miss diagnosis | 24 |

`@{u}` stays — it is used, and it is four lines. `--since`/`--until` go with
the date parser, which is the item to check hardest before cutting: zero
uses in these two logs is evidence about *these two agents*, and a human
runs `log --since=2.weeks` often enough to notice its absence.

### B4. The option surface, second pass — **−250**

328 `opt(...)` rows survive. §2.2 of the first pass measured that only 108
of 340 in-scope options ever appear in the logs, and the first pass cut the
obvious ones. What is left is less obviously dead, and each row costs a
table line **plus** the 1–5 lines that consume it — the table made the
declaration cheap, not the handling.

The candidates, by weight: `log`/`show` walk options beyond
`-n`/`--oneline`/`--stat`/`-p`/`--format`; `branch`'s remaining filters
(`--contains`, `--merged`, `-vv`); `checkout`'s legacy `--` forms;
`fetch`'s prune and tag variants; the whitespace family in `diffOptions`
(`-w`, `-b`, `--ignore-space-at-eol`, `--ignore-cr-at-eol` — four flags, and
a normaliser in `diff.nim` written to serve them).

### B5. Delete `reffilter.nim` — **−150**

223 lines serving three commands: `branch --list`, `tag -l`, `for-each-ref`
(3 uses in the logs, and the first pass already found the only atoms anyone
uses are `%(refname)`, `%(refname:short)` and `%(objectname)`). Keep those
atoms inline, move `--contains`/`--merged` to a three-line `isAncestor`
filter, drop `--sort` and the rest of the atom grammar.

**Tier B total: −800.**

---

## 6. Tier C — fewer commands (and why it is still not enough)

Tier A + B lands at **10,214**. Everything above is a refactor; nothing
above removes a verb. The remaining −2,214 has to come out of the 44
commands — and, as §6.1 shows, does not fit there either.

Priced, with the engine each one frees and its use count in the logs:

| drop | cmd | engine freed | uses |
|---|---:|---|---:|
| the ten remaining plumbing verbs — `rev-list` 92, `ls-tree` 62, `ls-files` 55, `check-ignore` 41, `for-each-ref` 38, `merge-file` 36, `reflog` 36, `update-ref` 30, `hash-object` 28, `merge-base` 24, `write-tree` 7 | **449** | `reffilter` 223 (if B5 has not already) | 22, 18, 11, 9, 4, 3, 2, … |
| `worktree` | **262** | `worktrees.nim` 90, and the `checkedOutAt` invariant in four other commands | 39 |
| `rebase` | **243** | ~60 in `sequencer` and `pull` | 0 |
| `grep` outright, instead of B1 | **152** | `regex` 85 | 13 |
| `gc` 72 + `clean` 59 + `mv` 42 | **173** | — | 0 |
| fold `show` into `log` (it is `log -1` plus object dispatch) | **~40** | — | many |
| `stash`, trimmed to `push`/`pop`/`list` | **~60** | — | 36 |

Two of these are decisions the first pass already took the other way, and
re-opening them is the substance of this proposal:

* **`rebase`** was kept because `pull --rebase` is the human daily loop and
  because `rebase-merge/` is the interoperability claim phase 7 makes. Zero
  uses in the logs. Cutting it is −300 and costs the strongest
  resume-a-state-git-made test in the oracle.
* **`worktree`** was kept as-is at 272 lines, with 39 uses — the third most
  used verb in the logs, and the one Claude Code itself creates for parallel
  sessions. Cutting it is −350 and would be felt immediately.

The plumbing row is the one with the best ratio: 449 command lines and 223
engine lines for verbs used between 0 and 22 times, all of which exist to
drive engines from a shell that the oracle already drives through `git` on
the other copy.

### 6.1 Tier C does not reach 8,000

Adding it up — every deletion in the table above, on top of Tier A and
Tier B:

| | lines |
|---|---:|
| after Tier A + B | 10,214 |
| the ten plumbing verbs | −449 |
| `gc`, `clean`, `mv` | −173 |
| `show` folded into `log` | −40 |
| `worktree` (262) and `worktrees.nim` (90) | −352 |
| `rebase` (243) and its share of `sequencer`/`pull` (60) | −303 |
| `stash` trimmed to `push`/`pop`/`list` | −60 |
| `grep` dropped outright rather than exec'd (B1 already took 190 of the 237) | −47 |
| | **8,790** |

**790 short**, with 25 verbs left and nothing plumbing-shaped remaining. The
commands still standing are `push` (267), `branch` (265), `checkout` (232),
`commit` (210), `merge` (196) and `cherry-pick` (180) — the daily loop
itself — and the engines are `refs` (481, the on-disk contract), `diffcore`
(511), `packfile` (322), `index` (269), `repository` (288). Shaving 790
across those is not a scope cut; it is a fidelity cut spread over the code
that makes gittle a git.

There is exactly one item of that size that can be removed as a *thing*
rather than sanded off:

### 6.2 Package D — fast-forward only

| | lines |
|---|---:|
| `mergetree.nim` — the three-way tree merge | 171 |
| `mergefile.nim` — the three-way file merge and the conflict markers | 166 |
| `sequencer.nim` — the pick/continue/abort state machine | 149 |
| `cherry-pick` and `revert` | 180 |
| `merge`, reduced to fast-forward-or-refuse (196 → ~40) | 156 |
| | **−822** |

Landing at **7,968**. gittle would then: fast-forward a branch, refuse
anything else with "not a fast-forward; merge with git", and have no
`cherry-pick`, no `revert`, no conflict markers, no `MERGE_HEAD`, no
`stash pop` onto a modified file.

What that spends is the single strongest claim the project makes.
`minimize.md` §5.3 kept `mergefile.nim` in Nim, against the Unix-tool
argument that took the diff, on exactly this reasoning: the 400 random
merges that come out **byte-identical to git's, conflict markers included**,
are "the interoperability claim that matters most — a user resolves those
markers with git's tools". Package D deletes the claim and the tests that
make it.

It is also the one cut that changes the README's first sentence.
"Compatible enough to share a repository with real git" survives a tool
that cannot merge; "the scope is what an agent-driven daily loop uses" does
not — `merge` and `cherry-pick` are in the logs.

---

## 7. Four packages

| package | what | lands at | vs. target |
|---|---|---:|---:|
| **A** — refactor only | Tier A + Tier B. All 44 commands survive. | **10,214** | +2,214 |
| **B** — refactor + plumbing | A, plus the ten plumbing verbs, `gc`/`clean`/`mv`, and `show` folded into `log` | **9,552** | +1,552 |
| **C** — the daily-loop core | B, plus `worktree`, `rebase`, the `stash` trim and `grep`; ~25 verbs | **8,790** | +790 |
| **D** — fast-forward only | C, plus the three-way merge, `cherry-pick`, `revert` and most of `merge` | **7,968** | −32 |

Package A is what the first pass's own §6 projected for itself and missed
("≈ 10,800"); it is justified line by line without reference to any target.
Package C deletes the third- and fourth-most-used verbs in the evidence
base. Only Package D reaches 8,000, and it reaches it by ceasing to be a
tool that can merge.

---

## 8. What the oracle becomes

R8 stands, and the compatibility claim is what is actually being spent here.
168 checks today. Every command cut takes its checks with it:

* Package A leaves the oracle **as it is** — same commands, same state
  comparisons, tighter code behind them. `p6mut`, `p8mut`, `p10` unchanged.
* Package B loses the plumbing checks, which the first pass already
  rewrote to read gittle's state *through* `git`. Survivable; the state
  comparisons are the real test and they do not go through gittle's
  plumbing.
* Package C loses `p7`'s rebase resume tests (`PREP='$GITX rebase …' p6mut
  rebase --continue`) and every `worktree` check in `p10`, which is the only
  place two repositories are compared *whole*. That is not a smaller oracle,
  it is a narrower claim: gittle would no longer demonstrate that a state it
  wrote can be continued by git in two of the hardest cases.
* Package D loses the 400-merge byte-identity test, the conflict-marker
  comparison, every `MERGE_HEAD` / `CHERRY_PICK_HEAD` in-progress check in
  `p6mut`, and the remaining half of `p7`. What is left is a strong test of
  a repository *reader and linear writer*, which is a fair description of
  what Package D ships.

Worth writing into whichever package is chosen: what the README is allowed
to say afterwards.

### 8.1 What the oracle costs to run (done 2026-09-02)

The suite is run after every change, so its wall-clock time is a tax on every
line of this document. It was **5m41** sampled. Measured per section, the
cost was concentrated and none of it was coverage:

| | before | after |
|---|---:|---:|
| `rev-list` (50 option forms) | 88.6s | 27s → fanned |
| `log path limiting` | 32.3s | 26.5s → fanned |
| `merge-base` | 24.2s | 8.6s → fanned |
| `grep` | 21.3s | 10.9s |
| `for-each-ref` | 18.6s | fanned |
| **whole suite, sampled** | **5m41** | **2m28** |

Two changes, and **no check was deleted** — the count is still 172:

1. **Scale moved into `--full`.** Two forms alone — `rev-list -n 60
   --topo-order HEAD -- t/` and the same over `diff.c` — were 45 of the 340
   seconds, because a pathspec walk diffs a tree per commit and a rarely
   touched path walks most of 82,000 commits to find its 60. Bounded to
   `v2.30.0..v2.31.0` they exercise the same three things (the tree diff, the
   topological order, parent rewriting) over real merges. Same treatment for
   `merge-base`'s random pairs, `grep`'s pattern count, `for-each-ref`'s
   ancestry filters over 800 tags, and the depth of the `log` limiting walks.
   `--full` still runs every one of them at full scale from `HEAD`.

2. **Fan-out across the cores.** The comparisons over the reference
   repository only *read* one repository, so they share nothing. `ro1` is the
   old `p6ro` body split so it prints instead of setting a flag, which lets it
   be called directly or on another core; `fanjob`/`fanwait` run them
   `$JOBS` at a time (default `nproc`) and collect the failures in queue
   order. The suite was using 1.1 of 8 cores and now uses most of them.

Verified by regression: a `gittle` wrapper that corrupts `rev-list`,
`merge-base`, `for-each-ref` and `log` makes exactly those sections **FAIL**,
so the fan-out still catches what the serial loop caught.

What was deliberately *not* touched: `clean` (15s), `worktree` (9s) and the
other `p6mut`/`p10` mutation comparisons. They are ~370ms per form because
each copies a fixture twice and compares two repositories whole — and they
are where nine of phase 6's eleven bugs and four of phase 7's were found.
They are also the ones that cannot be fanned out safely, since they write.

Left undone: gittle is **4–13× slower than git** on this repository, which is
now the floor under the suite. `rev-list --count HEAD~1..HEAD` — one commit —
takes 1,190ms against git's 21ms, because `revwalk.markUninteresting` paints a
whole ancestry eagerly (a deliberate, documented choice: it is what makes
`rev-list side ^main` correct when every commit shares a timestamp, where
git uses a date cutoff and `SLOP`). That is a note for the optimisation pass,
not for this one.

---

## 9. Two things to settle before cramming

**What the number counts.** Of the 11,724: ~340 lines are wrapped prose
strings, 328 are declarative `opt(...)` rows, 46 are `okRefused` rows. If
the budget models *how much logic a reader has to hold*, the tree is already
about 11,000 lines of logic and 700 of data-and-English. That is not a route
to 8,000 — a redefinition is not a cut, and pretending otherwise is exactly
what `CLAUDE.md` means by cramming to hit a figure — but it is worth
deciding what §5 of `plan.md` is measuring before spending the compatibility
claim to move it.

**8,000 is a target, not a constraint.** `plan.md` §5 says the figure is a
measurement, not a limit, and that was settled after phase 6. Package A is
justified line by line without reference to any target — every item in it
is an R4 or R7 argument that would be worth making if the number were
14,000. Packages C and D are justified only by the target.

The shape of the trade, stated once: the first 1,510 lines cost nothing but
work. The next 1,424 cost `rebase`, `worktree` and the plumbing. The last
790 cost merging. Each tranche buys fewer lines for more of the project,
which is what a well-minimised codebase is supposed to look like — the first
pass took the cheap 2,148, and this is the bill for the next ones.

---

## 10. Order of work

Only if a package is chosen. Each step ends with `tests/oracle.sh --full`
green and the count recorded, as every earlier step has.

| step | what | lines | running |
|---|---|---:|---:|
| 1 | A1, the §7.1 leftovers — smallest risk, and it makes every later diff smaller | −200 | 11,524 |
| 2 | The chosen package's **deletions**, all of them, first — every later step is smaller when there is less of it, and it settles which subsystems need refactoring at all | 0 to −2,246 | |
| 3 | B1 `grep` (if not deleted), B2 transport v0, B5 `reffilter` — the whole-subsystem removals | −430 | |
| 4 | A3 matcher, A4 ref-update report, A5 status renderer — the three folds | −260 | |
| 5 | B3 revision syntax, B4 options — the two surface trims | −370 | |
| 6 | A2 message prose, last, so each message is rewritten once against its final call site | −250 | |
| 7 | A6: read `diffcore` and decide | ? | |

Step 2 is where the package is actually chosen; steps 3–6 are the same work
in every package, over less code in the later ones.

---

## 11. Decisions

*Nothing decided. This section is what the document is for.*

1. **Package A, B, C or D** — §7. Only D reaches 8,000.
2. **Is 8,000 a target or a constraint?** — §9. If it is aspirational,
   Package A is the answer and this document is a refactoring plan; if it is
   real, question 1 is really "is gittle allowed to stop merging?"
3. `rebase`: keep (2026-09-02's decision 2) or cut on the zero-use
   evidence — §3, §6.
4. `worktree`: keep at 262 lines with 39 uses — the third most used verb in
   the logs — or cut — §6.
5. `--since` / `--until`: keep the 48-line date parser for a human who is
   not in the logs, or cut — §B3.
6. `grep`: exec `grep(1)` (B1, −190) or drop the verb (Tier C, −237).
7. Whether `opt(...)` rows and string-literal continuations count against
   `plan.md` §5 — §9.

Questions 3–6 are worth answering even under Package A: each is an
independent scope judgement, and three of the four were taken the other way
by a pass that had not yet re-measured the logs.
