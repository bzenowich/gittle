# Minimising gittle — the plan for the refactoring pass

Status: **landed 2026-09-02** -- §9 has what each step actually cost, against
the estimates below, and what was left. This is the
optimisation and refactoring pass that `plan.md` §5 defers to
feature-completeness, written up for review before anything is touched.

The brief it answers:

* minimise lines of code, aggressively, while keeping the result readable,
  clearly structured and well commented (comments are free);
* consider a Click-style table-and-decorator treatment of commands and
  options;
* compare the original scope — the commands in `git-tool-calls-*.md` plus
  `clone`, `fetch` and `push` — with what the code supports today, and say
  what is most reasonable to cut;
* keep **functional** compatibility with git paramount: gittle and git must
  be swappable on the same repository without breaking either. **stdout need
  not be byte-exact** any more; it needs to be clear and useful;
* consider replacing the diff/patch engine with the installed `diff` and
  `patch`, Unix-style, as long as version control still works and git is not
  broken.

Everything below is measured against the same count the phase documents use:
non-blank, non-comment lines (`grep -vE '^\s*(#|$)'`), **13,872** for v1.

---

## 1. Where the lines are

| | lines | share |
|---|---:|---:|
| engine modules (`src/*.nim`, 39 files) | 8,102 | 58% |
| command files (`src/cmd/*.nim`, 47 files) | 5,770 | 42% |

Inside the command files, measured line by line:

| | lines | share of `cmd/` |
|---|---:|---:|
| option-parsing loops | 1,221 | 21% |
| of which pure scaffolding (`var i`, `inc i`, `case a`, the `-h` clause, the `unknown option` clause, the "is it an option" test) | 405 | 7% |
| `usageText` constants | 241 | 4% |
| "out of scope for gittle v1" refusal lists | 85 | 1.5% |
| the driver's own usage list (`gittle.nim`) | 65 | — |
| everything else — the commands themselves | 4,293 | 74% |

Inside the engine modules, the five largest are the two halves of the diff
(`diffcore` 561, `diff` 516), `refs` (526), `revision` (435) and `status`
(404). The "shared output formatting" that phase 6 identified — `pretty`,
`diffcore`, `status`, `reffilter` — is 1,604 lines today.

---

## 2. Scope: what was asked for, what was built

### 2.1 Commands

The two tool-call logs contain 509 `git` invocations over 34 verbs. 31 of
them are in gittle; `apply`, `merge-tree --write-tree`, `submodule` and
`describe` are not, and stay out (plan.md §4, "Evidence check").

The 53 commands gittle ships, sorted by whether the original scope needed
them:

| group | commands | lines |
|---|---|---:|
| **in the logs** (31) | `show` `log` `diff` `status` `commit` `add` `branch` `worktree` `stash` `checkout` `merge-base` `ls-tree` `rev-parse` `grep` `ls-files` `rev-list` `merge` `rm` `config` `for-each-ref` `check-ignore` `tag` `cat-file` `cherry-pick` `reflog` `reset` `restore` `remote` `push` `fetch` `clone` | 4,053 |
| **needed anyway** (4) | `init`, `switch` and `revert` (aliases of `checkout` and `cherry-pick`, a few lines each), `help`/`version` | ~90 |
| **daily loop for a human, never in the logs** (5) | `pull` (76) `rebase` (256) `mv` (125) `clean` (168) `gc` (119) | 744 |
| **plumbing nobody called** (10) | `update-ref` (281) `update-index` (99) `read-tree` (79) `write-tree` (11) `commit-tree` (42) `symbolic-ref` (55) `hash-object` (46) `merge-file` (48) `pack-objects` (65) `index-pack` (68) `ls-remote` (67) | 861 |

So the code carries about **1,600 lines of commands the original scope never
asked for**, a bit under 12% of the total. The engines beneath them are a
different matter: `index-pack`'s validator is what `fetch` runs, `pack-objects`'
writer is what `push` runs, and the rebase state machine is what `pull
--rebase` runs. Cutting a *command* removes its argument parsing and usage
text; the engine only goes when nothing else needs it.

### 2.2 Options

Of the 340 option entries marked in scope in docs 06–11, **108 appear in the
logs**. Where the surplus sits:

| command | in scope | seen | the unused surface |
|---|---:|---:|---|
| `branch` | 24 | 13 | `--sort`, `--format`, `--points-at`, `--no-contains`, `--no-merged`, `-c`/`-C`, `--edit-description` |
| `grep` | 23 | 8 | `-A/-B/-C` context, `-c`, `-h/-H`, `-w`, `-v`, `--cached`, `--no-index`, `-e` repetition |
| `tag` | 14 | 1 | `--sort`, `--format`, `--contains`, `--merged`, `--points-at`, `-n<num>` |
| `rev-parse` | 13 | 6 | `--show-cdup`, `--show-prefix`, `--git-path`, `--sq`, `--verify` variants |
| `ls-files` | 12 | 2 | `-d`, `-m`, `-k`, `-i`, `--exclude-standard`, `-z` |
| `rebase`, `switch`, `clean`, `update-index`, `ls-remote`, `pull`, `revert` | 52 | 0 | all of it |

The reading of the logs that matters: what agents use is **`--stat`,
`--oneline`, `--short`, `--name-only`, `-q`, `-F`, `--show-current`,
`--is-ancestor`, `--count`, `--abbrev-ref`** — the *summary* forms. The long
formats and the format-string atoms are used for `%h %H %s %b %B %an %n` and
`%(refname:short)` and nothing else. That is the surface gittle has to keep
crisp; the rest is where the relaxed stdout rule buys the most.

---

## 3. The cuts, in three tiers

Each tier is a decision for review. Lines are what the command file costs;
"engine" is what would also go, if anything.

### Tier 1 — plumbing wrappers that only exist as command-line entry points

git can read everything gittle writes, so gittle's own plumbing is not needed
to *test* gittle: the oracle already compares state through `git` on the other
copy (`p6state`, `p10state`). What the wrappers buy is a way to drive the
engines from a shell, and nothing in the original scope did.

| cut | lines | engine kept for | notes |
|---|---:|---|---|
| `update-ref --stdin` grammar (keep the one-line `update-ref [-d] <ref> [<new>] [<old>]`) | ~220 | — | the largest plumbing file in the project is a transaction mini-language with `-z`, `start`/`prepare`/`commit`/`abort`, `option`; no caller anywhere |
| `update-index` | 99 | `add` | `--cacheinfo`, `--assume-unchanged`, `--chmod`, `--refresh` |
| `read-tree` | 79 | `checkout`, `reset` | `-m`/`--reset`/`-u`/`--prefix` |
| `commit-tree`, `write-tree` | 53 | `commit` | |
| `symbolic-ref` | 55 | `checkout`, `branch -m` | `rev-parse --symbolic-full-name HEAD` reads it; nothing in the logs writes one |
| `pack-objects`, `index-pack` (the commands) | 133 | `push`, `fetch` | the `.idx` byte-identity claim moves to a test that runs a `fetch` and lets `git verify-pack` judge the result |
| `ls-remote` | 67 | `fetch`, `push` | |
| **total** | **~706** | | |

Kept on purpose: `hash-object` (46) and `cat-file` (109) are the smallest
possible probes of the object store and `cat-file` is in the logs;
`merge-file` (48) is what the 400-merge oracle drives; `for-each-ref`,
`rev-list`, `rev-parse`, `merge-base`, `ls-tree`, `ls-files` are all in the
logs.

### Tier 2 — porcelain outside the original scope

| cut | lines | recommendation | cost |
|---|---:|---|---|
| `gc` | 119 → ~60 | **replace** with the server-assisted version in §3.4 | the local packer and `packRefs` go; the fetch engine does the work. Needs the remote to be reachable. `packwrite.nim` stays for `push`. |
| `mv` | 125 → ~30 | **rewrite** as rename(2) plus an index-entry rename — §3.5 (**decided 2026-09-02**) | two refusals kept: source must be tracked, destination must not exist without `-f`; git's other nine checks and `-n`/`-v` go |
| `pull` | 76 → ~25 | **rewrite** as `fetch` then `merge FETCH_HEAD` or `rebase FETCH_HEAD` — §3.5 (**decided 2026-09-02**) | the divergence guard stays at five lines; the fast-forward-instead-of-rebase case and the candidate scan of `FETCH_HEAD` go |
| `clean` | 168 → ~40 | **rewrite** over the untracked walk `stash -u` already uses — §3.5 (**decided 2026-09-02**) | `-f -d -x -n -q`; drop `-e`, `-X`, `-i`; the per-directory collapse logic goes, reporting is per file |
| `stash` | 259 → ~240 | **trim**: drop `--keep-index` and `show` (**decided 2026-09-02**) | `push`, `list`, `pop`, `apply`, `drop`, `clear`, `-u` stay; it is not a wrapper over `worktree` — §3.5 says why |
| `tag` | 127 → ~80 | **trim** to create (`-a -m -F -f`), list (`-l`, patterns), delete (`-d`) | drops the ref-filter options `tag` shares with `branch`; the `-n<num>` case that forbids short-option bundling goes with it |
| `branch` | 290 → ~240 | **trim**: drop `--sort`, `--format`, `--points-at`, `--no-contains`, `--no-merged`, `--edit-description` | keeps `--contains`, `--merged`, `-vv`, `--show-current`, everything the logs used |
| `grep` | 249 → ~170 | **trim**: drop `-A/-B/-C`, `-c`, `-w`, `--no-index`, `-h/-H` | keeps `-n -q -F -i -l -v -E`, `--cached`, tree arguments |
| `rev-parse` | 106 → ~80 | **trim**: drop `--show-cdup`, `--show-prefix`, `--git-path`, `--sq` | |
| `ls-files` | 92 → ~70 | **trim**: drop `-d`, `-m`, `-k`, `-i` | `-s`, `-o`, `-c`, `--error-unmatch`, `--exclude-standard` stay |
| `rebase` | 256 (+~60 in `sequencer`, `pull`) | **keep** (**decided 2026-09-02**) | never in the logs, yet `pull --rebase` and `rebase main` are the human daily loop and its `rebase-merge/` state is the interoperability claim phase 7 makes. Cutting it would have been worth ~320 lines. |
| `worktree` | 272 | **keep** as is | 37 uses in the logs — `add`, `list`, `remove`, `prune`, `move` — every sub-verb it has |
| **total if all recommended** | **~580** | | |

### 3.4 `gc`, done by the server

The remote always runs full git, so the delta search gittle refuses to
implement (R2) is available on the other end of every fetch. A fetch says
"I want these tips, I have these commits", and the server's `pack-objects`
sends the difference as one deltified pack. The haves do not have to be
honest: offer only the commits whose objects already sit in the pack worth
keeping, and the server sends everything newer — including what gittle
already holds loose — packed properly. gittle's fetch engine
(`remotes.receivePack`) takes wants and haves as parameters today, so `gc`
becomes a caller of it instead of a packer.

Three levels, by what crosses the wire:

| level | haves | what it sends | deletes afterwards |
|---|---|---|---|
| pack pushed history | walk back from each remote-tracking tip to the first commit in any existing pack | the commits since the last pack | loose objects the new pack covers |
| consolidate packs | the same walk, stopping only at the **largest** pack | everything outside that pack | every smaller pack, and loose objects, the new pack covers |
| full repack (`--full`) | none | the whole history, as a clone would | every old pack and loose object the new pack covers |

The second level is the one gittle cannot do today at all: it keeps one
pack per fetch (git unpacks fetches under 100 objects into loose files, so
its count grows slower), and consolidating means re-deltifying.

**The one safety rule.** A loose object or an old pack is deleted only when
every object in it exists in a pack being kept. Nothing else is ever
removed. That is what keeps it safe with a real git writing the same
repository, and it is what makes the limits below honest.

**What the server cannot cover, and what happens instead:**

* *unpushed work* — local branches not pushed, stashes, a staged blob,
  reflog-only objects. The server has never seen them; the rule keeps them
  loose until the first `gc` after a push;
* *unreachable objects* — a fetched-then-deleted branch pins its pack,
  because the server sends only what its tips reach. Pruning needs a grace
  period against in-flight writes, which is why git waits two weeks; it
  stays git's job;
* *reflog expiry and packed refs* — local files. Packing refs only speeds
  up repositories with thousands of them; `packRefs` (40 lines) goes;
* *being offline* — the gc needs the remote. A device that pushes already
  has that requirement.

**Wire detail.** gittle's fetch asks for thin packs and appends the missing
bases afterwards. The gc fetch asks for a non-thin pack, so the file the
server sends is self-contained and no base is duplicated from the pack
being kept.

The reverse direction does not exist: a push is the client's pack, and the
server cannot deltify what it has not received. `push` stays as it is and
so does `packwrite.nim`.

**Automatic, after a push (added 2026-09-02).** git runs its auto
maintenance after `commit`, `merge`, `rebase` and `fetch`; gittle runs this
gc at the end of a successful `push`, when the loose-object estimate
(`objects/17` × 256, git's own) exceeds `gc.auto` (6,700 by default, 0 to
disable). That is the one moment the server is known to hold the history
worth packing, and the download that follows is a fraction of the upload
that just happened: the push sent undeltified objects up, the gc brings
them back deltified. It is foreground, and it trips perhaps once in a few
hundred to a few thousand commits, or on the first push of an import.

Cost: about 60 lines — choose the haves, call the fetch path with thin off,
the delete pass — against 119 for `gc` plus 40 for `packRefs` today. The
`--prune=<date>` parser and the reachability set go with the old command.
`preciousObjects` in the extension gate stays accepted and now means the
delete pass is skipped.

### 3.5 Commands that are wrappers, and one that is not

Three of the tier-2 commands are, in git's own history, shell scripts over
other commands. The question for each is what the C version added and
whether gittle needs it.

**`mv` — rename(2), then rename the index entries.** The core is: rename
the path on disk, rewrite the path of every index entry equal to the source
or under it, write the index. That is exactly the index git ends up with.
It is deliberately *not* `mv` followed by `add -A`, for three reasons:

* `add -A` stages every unrelated change in the tree. Limited to the two
  paths, it still stages the unstaged edits of a moved file, where git
  keeps the old blob staged and the edit unstaged;
* moving a directory carries its untracked files along; `add` would stage
  them, git leaves them untracked, since the index has no directories;
* a tracked file moved into an ignored directory stays tracked in git;
  `add` refuses ignored paths without `-f`.

Renaming the entries never re-reads the working tree, so none of the three
arise. What the other 100 lines of today's file are is git's eleven refusal
checks in git's order with git's messages. Two protect data and stay: the
source must be tracked, and the destination must not exist unless `-f`.
The rest, and `-n`/`-v`, go. **About 30 lines.**

**`pull` — `fetch`, then `merge FETCH_HEAD`.** `git-pull.sh` was exactly
that until it was translated to C in 2015. The wrapper parses `-r`,
`--no-rebase` and `-q`, hands the rest to `fetch`, then runs `merge
FETCH_HEAD` or `rebase FETCH_HEAD`, with the reflog action set to `pull`.
What today's 76 lines have beyond that:

| item | fate |
|---|---|
| the divergence guard — refuse when `pull.rebase` is unset and the branches have diverged | **stays**, five lines and one sentence; it is git ≥ 2.27 behaviour, and losing it would only mean merging by default, as git did before |
| the fast-forward special case under `--rebase`, where git merges instead because a rebase of zero commits would detach and reattach HEAD | goes; the end state is identical, only two reflog lines differ |
| the scan of `FETCH_HEAD` for the first line not marked `not-for-merge` | goes; `FETCH_HEAD` as a revision already resolves to the first line, and `fetch` writes the merge candidate first |
| the twelve-line `hint:` paragraph | goes with tier 3 |

**About 25 lines.**

**`clean` — the untracked walk, then unlink.** `stash -u` already has the
list `clean` needs: `dir.walkWorkTree` returns every untracked, non-ignored
file under a pathspec, and marks a nested repository as `dir/`. `clean`
over that list is:

1. walk with the ignore files, or with an empty ignore list under `-x`
   (that is what `-x` means);
2. without `-d`, drop every file whose immediate parent directory has
   nothing tracked under it — that *is* an untracked directory, and git
   skips those without `-d`. The existing `anyTrackedUnder` answers it with
   one binary search;
3. skip `dir/` entries, the nested repositories, as git does without `-ff`;
4. `-n` prints the list; otherwise unlink each file, then `rmdir` each
   parent directory of a removed file, deepest first, ignoring failure.

Step 4 reproduces git's directory rule for free: a directory that held an
ignored file is not empty, so it survives, exactly as `clean -fd` leaves a
directory that has `.o` files in it. The 60-line collapse decision in
today's file — name the directory once, or name the files inside it — was
only ever about *reporting* (`Removing build/` versus one line per file)
and about removing by directory; per-file reporting is allowed now, so it
goes with `removeTree`. No callout to `rm` is needed: unlinking is one call
in Nim, the same system call `rm` makes, and there are no directories to
remove recursively. One loss, stated: an *empty* untracked directory is not
in the walk and so is not removed; a final pass that `rmdir`s empty
directories with nothing tracked under them is five lines if it matters.
**About 40 lines.**

**`stash` is not a wrapper over `worktree`.** They are different on-disk
things, and the swap rule settles it. A worktree is a second checkout
directory with its own HEAD and index. A stash is a commit with two or
three parents — the working tree as its tree, the index as its second
parent's tree, the untracked files as the third — stored as an entry in the
reflog of `refs/stash`. If gittle stashed by moving dirty files into a
worktree there would be no `refs/stash` entry for git to `stash pop`, and
git's stashes would have no worktree for gittle to find; both directions
break. Both commands are heavily used in the logs (34 and 37 calls), and
Claude Code creates worktrees for parallel sessions.

What they already share is the engine underneath: `stash apply` is the
three-way merge `cherry-pick` runs with different trees, `stash push` is
two `write-tree`s and two commit objects, and `-u` is the walk `clean`
uses. What the 259 lines are is the *stack* — `drop` rewrites a reflog and
re-chains its old-value column; `push` builds the untracked tree and honours
`--keep-index`; `apply` puts the index back afterwards except for paths that
did not exist before. `--keep-index` (one use in the logs) and `show` go,
about 20 lines; `-u` stays because an agent stashing to run a baseline
wants the untracked files out of the way too.

### Tier 3 — output surface that only existed to match git byte for byte

With byte-exact stdout no longer required, the reproductions of git's
presentation choices can go. This is the tier that turns the "shared output
formatting" over-run of phase 6 back into lines. The engine survey (§7)
measured each item; what follows is the list with what it costs and what a
reader loses.

| item | where | lines | what changes on screen |
|---|---|---:|---|
| the `--stat` histogram: 80-column fitting, the 5/8 : 3/8 name/bar split, `...` truncation back to a slash, bar scaling and its special cases | `diffcore.writeStat` + 3 helpers | 116 → ~25 | `--stat` stays (124 uses in the logs) as ` path \| +N -M`, one line per file, no bar |
| `--date=human`, `--date=relative` (and `%ar`/`%cr`), `--date=format:` and its 17-directive strftime, the full month/weekday tables | `pretty.nim` | −95 | `default`, `iso`, `iso-strict`, `rfc`, `short`, `raw`, `unix` stay; `short` is the only mode in the logs |
| `%f` (the `format-patch` filename sanitiser) | `pretty.nim` | −17 | gone; nothing produces patch files |
| the long-format advice layer: 26 verbatim `(use "git …")` strings, the two decision trees choosing which one, `advice.statusHints` through three signatures | `status.longStatus` | −70 | one fixed hint per section, three lines total |
| the rebase todo window in `status` ("Last commands done (2 commands done):", next-2, plural agreement) | `status.inProgressBlock` | −23 | `rebase in progress; onto <oid>` and the branch |
| `diagnoseIndexPath`, `diagnoseTreePath`, `failAmbiguous` — git's near-miss hints for `:<n>:<path>` | `revision.nim` | −40 | one `ambiguous argument '<x>'` message |
| `matchesPattern`'s two modes, `%(contents:lines=<n>)` indentation, `:lstrip`/`:rstrip`, `:short=<n>` | `reffilter.nim` | −30 | `for-each-ref --format` keeps every atom in the logs |
| the `hint:` paragraphs in `pull`, `cherry-pick`, `rebase`, `merge`, and `push`'s six refusal paragraphs | `cmd/` | −50 | one sentence naming the cause and the flag that overrides it |
| `--color` | `diffcore`, `grep`, `pretty` | **kept** (decided 2026-09-02) | its three parsers fold into one in step 5, but colour stays |
| **total** | | **≈ −415** | |

Two things this tier deliberately keeps: `pretty.nim`'s message indenting
and decoration order (`HEAD -> main, tag: v1`) — that *is* what makes `log`
readable — and every machine-readable format (`--short`, `--porcelain`,
`-z`, `--name-only`, `--numstat`, `--format`), which are what scripts and
agents actually consume.

---

## 4. Commands and options as a table (the Click question)

### 4.1 What the survey found

Every one of the 47 command files hand-writes the same loop: `var i = 0`,
`while i < args.len`, `let a = args[i]`, an "is it an option" test, a `case`
with a `-h` clause and an `unknown option` clause, `inc i`. That scaffolding
alone is **405 lines**, and the per-option clauses beneath it are one line
each in the common case and are not what a table removes.

The value-reading idiom exists in three versions — `valueFor` from `cli.nim`
(18 files), an inline `inc i; failIf(i >= args.len, ...)` (12 files) and a
per-command `template value()` in `push.nim` — and twelve files then also
hand-write the `--opt=value` form with `a["--opt=".len .. ^1]`. Sub-verbs
(`stash`, `remote`, `worktree`, `config`) are dispatched four different ways.

### 4.2 The design

Click's insight is that an option is data: a name, a kind, a destination, a
help line. Nim has no decorators, but it has `const` tables and templates,
and R7 says a family of cases that differs only in constants *is* a table.
The proposal is a table plus one parser, not a macro DSL — a macro that
generates typed option objects would be more elegant to use and harder to
read, and readability is a stated goal.

```nim
type
  OptKind = enum okFlag, okCount, okValue, okOptValue, okRefused
  Opt = object
    names: string    ## "-l|--list"
    kind: OptKind
    key: string      ## how the command asks for it; "" means key = long name
    help: string     ## one line, becomes the usage text
  Opts = object
    seen: Table[string, seq[string]]   ## key -> values ("" for a flag, once per occurrence)
    args: seq[string]                  ## positionals, in order, after `--` too

proc parse(spec: openArray[Opt], argv: openArray[string],
           bundle = true, numeric = false): Opts
proc has(o: Opts, k: string): bool
proc count(o: Opts, k: string): int
proc val(o: Opts, k: string, dflt = ""): string
proc usage(cmd: string, spec: openArray[Opt]): string
```

and a command becomes

```nim
const branchOpts = [
  opt("-l|--list",   okFlag,  help = "list branches (the default)"),
  opt("-a|--all",    okFlag,  help = "list local and remote-tracking branches"),
  opt("-v|--verbose", okCount, help = "show the tip commit; -vv the upstream"),
  opt("-D",          okFlag,  key = "delete-force"),
  opt("--set-upstream-to|-u", okValue, help = "..."),
  opt("--contains",  okOptValue, help = "..."),
  opt("-c|--copy|-C|--edit-description", okRefused),
]

proc cmdBranch*(c: Ctx, args: seq[string]): int =
  let o = parse(branchOpts & refFilterOpts, args)
  ...
  if o.has "delete" or o.has "delete-force": ...
```

Shared groups (`parseDiffOpt`, `parseWalkOpt`, `parseFilterOpt`) become
shared tables concatenated into the command's, and a post-parse fixup where
one option sets several fields (`--oneline`, `-s` versus `-p` ordering — the
one order-sensitive case, handled by `seen` keeping occurrences in order and
the fixup replaying them).

The `usageText` constants and the driver's 65-line command list are then
**generated** from the tables and one `(verb, entry, summary)` registration
table in `gittle.nim`, which also replaces the 50-line `case verb`.

### 4.3 What it saves, and what does not fit

| | lines |
|---|---:|
| scaffolding removed | −405 |
| refusal lists as `okRefused` rows | −40 |
| usage text generated | −120 (cmd) −65 (driver) |
| driver dispatch as a table | −40 |
| the parser, `Opts`, `usage`, registration | +100 |
| **net** | **≈ −570** |

Where a table is a bad fit and the loop stays, wrapped only in the shared
value reader:

* `rev-parse` — a streaming interpreter that prints as it goes and lets
  `--short` change how later arguments render;
* `-<n>` in `log`, `rev-list`, `grep -C<n>`, `tag -n<num>` — a `numeric`
  escape hatch in the parser covers these after the tier-2 trims;
* `cat-file`'s exclusive modes and `<type> <object>` positional form;
* the sub-verb commands — the fix is to pick **one** shape (verb is the
  first positional; the table parses everything around it) and use it in
  all four;
* `update-ref --stdin` — gone in tier 1.

### 4.4 Helpers written more than once

Found by the survey, folded during the same pass:

* "branch name from HEAD" — seven copies across `branch`, `checkout`,
  `push`, `rebase`; one `repo.currentBranch`;
* the delete loop with `Deleted … (was <abbrev>)` — `branch` and `tag`;
* commit message through a temp file — `sequencer.finalMessage` re-inlined
  in `commit` for the `commit-msg` hook; a callback parameter;
* `--color=` parsing — three copies (`diffcore`, `grep`, `pretty`);
  moot once colour goes in tier 3;
* attached-numeric and attached-value short options — eight copies;
* `expandShortOptions` re-implemented inline in `status` for `-uno`.

Roughly **−100** beyond the table.

---

## 5. Replacing the diff engine with `diff`

### 5.1 What the engine is for

`diff.nim` exports three things, and everything else in the project consumes
one of them:

| export | what it is | consumers |
|---|---|---|
| `diffText` | hunks with context and a function-name header | `diff`, `log -p`, `show`, `stash show` |
| `diffCounts` | added/deleted line counts | `--stat`, `--numstat`, `commit`'s summary |
| `diffRecords` | the ungrouped edit script | `mergefile.nim`, the three-way merge |

`status` does not use it: whether a file *changed* is a stat and hash
question, answered in `diffcore.changed`.

The file splits, in code lines, into six sections:

| section | lines | what |
|---|---:|---|
| 1 lines and whitespace classes | 69 | split, and the `-w`/`-b`/`--ignore-*` equivalence |
| 2 trim and discard | 20 | |
| 3 the search | 92 | Myers, both ends at once |
| 4 compaction and the indent heuristic | 160 | where a hunk sits; the copied slider weights |
| 5 the change script and hunks | 159 | grouping, context, `@@` headers, function names |
| 6 the ungrouped script | 15 | |

Sections 2–4, **272 lines**, are exactly what `diff` does. Section 5 is
mostly what `diff -U<n>` prints. Section 1's whitespace rules are three
flags on `diff`.

### 5.2 The design

One process per file pair, always the same invocation:

```
diff -d -U<n> <old> <new>
```

`-d` is GNU's "try hard for a smaller diff", which is `--minimal` — the one
configuration gittle already ships, so nothing changes in what a hunk
contains, only where an equal hunk is slid to. Its `@@ -i1,c1 +i2,c2 @@`
headers are, at `-U0`, precisely the `Edit` list `mergefile.nim` wants, and
at `-U3` precisely the hunks `diffText` returns. One header parser (~25
lines) serves both; the `\ No newline at end of file` marker and the
one-line `-i1` / `+i2` forms without a count are the only shapes it has to
know. Binary detection stays ours (a NUL in the first 8 KiB, as git does
without attributes) and runs before `diff` is asked. Whitespace modes are
applied by gittle *before* the call — normalise each line under the mode,
diff the normalised copies, print the originals by line number — so busybox's
`diff`, which has `-b` and `-w` but not `--ignore-cr-at-eol`, is enough.

Two blobs become two files in `$GIT_DIR` (there is already a temp-file helper
for lock files); a working-tree side is passed by path. The cost is one
`fork`+`exec` per pair — measured at about **1 ms** here — so `log -p` over
a thousand commits pays a second, and `diff` on a working tree pays nothing
anyone would notice.

What is lost, and stated rather than hidden:

* the **function-name context** on `@@` lines (git's `xfuncname`). Busybox
  `diff` has no `-p`; GNU's `-p` knows C only. The `@@` line loses its
  trailing `proc foo` — informational, and allowed now;
* **hunk placement**: git's indent heuristic and GNU's `diff` slide an
  ambiguous hunk differently on ~4% of real commits. Both are correct
  patches; `git apply` takes either;
* the **byte-exact diff oracle**. `tests/oracle.sh` compares 900 file pairs
  hunk for hunk against `git diff --minimal`. It becomes a *semantic*
  oracle, which is the stronger R8 test anyway: `gittle diff A B | git apply`
  must reproduce B, and `git diff A B | gittle`'s counts must match
  `--numstat`.

Savings: `diff.nim` 516 → about **110** (the whitespace normaliser, the
spawn, the header parser, the record splitter for the merge). **−400**.

### 5.3 `patch` has no role — and the merge stays in Nim

`patch` applies a unified diff to a file. Nothing in gittle's scope does
that: `apply` and `am` are cut, and `cherry-pick`, `revert`, `rebase` and
`stash pop` are **three-way merges**, not patch applications. Doing them
with `patch` would produce `.rej` files where git writes conflict markers
and index stages 1/2/3 — a state git cannot continue from, which is the
one thing the swap-either-way rule forbids. `patch` comes back only if
`apply` does (plan.md §8, first in the backlog).

The three-way merge itself, `mergefile.nim` (166 lines), keeps its algorithm
and is fed by `diffRecords` as before. The alternative, `diff3 -m`, was
rejected: busybox has no `diff3` (nor RCS `merge`), its conflict output is
not git's `<<<<<<< ours / ======= / >>>>>>> theirs` shape, and the 400
random merges that today come out **byte-identical to git's, markers
included**, are the interoperability claim that matters most — a user
resolves those markers with git's tools. Early git did run RCS `merge` for
this and replaced it; that is the history the Unix-philosophy argument runs
into here.

### 5.4 Busybox and the static binary

Goal 5 says "no external tooling". This change makes `diff` the second
runtime dependency after zlib. It is in busybox, on every Linux base image
that has `sh`, and in the same category as the `ssh` that `fetch` already
execs. The binary stays static; the environment gains a requirement worth
one line in the README.

---

## 6. Order of work

Each step ends with `tests/oracle.sh --full` green, and the count recorded.

| step | what | lines |
|---|---|---:|
| 1 | **Tier 1 and tier 2 cuts, and the server-assisted `gc`.** Delete first: every later step is smaller when there is less of it, and it settles which tables need writing. The oracle's uses of the cut plumbing move to `git`-side reads of gittle's state. Takes the `refs.nim` and `repository.nim` items of §7.2 with it, and the rewrites of §3.5. *Needs the decisions in §8 first.* | −1,380 |
| 2 | **The option table and driver registration.** Convert the 22 files that fit cleanly, then the shared groups, then the sub-verb commands onto one shape. `rev-parse` and `cat-file` keep their loops on the shared value reader. | −570 |
| 3 | **External `diff`.** Swap `diff.nim`'s sections 2–4 for the spawn, rewrite the diff-engine oracle as the round-trip test, re-run the 400 merges. | −400 |
| 4 | **Tier 3 output surface**, per the table in §3. The oracle's byte comparisons of `--stat`, `--date=`, `status` long format and the hint text become checks that the *state* matches and the summary lines say the right thing. | −415 |
| 5 | **Duplicate helpers** (§4.4 and §7.1) and the un-exports. | −270 |
| | **total** | **≈ −3,065** |

Projected landing: **≈ 10,800 lines** with `rebase` kept, about 10,450
without it — back at the ~10 kloc plan.md §1 called the shape being aimed
at, with 41 of the 53 commands and every command in the logs intact. The
estimates are each rounded down where the survey gave a range; the
refactoring passes of earlier phases found more than they were sent to find,
and this one is likely to as well.

### What the oracle becomes

R8 stands; what changes is what "the same" means. Today `oracle.sh` compares
stdout byte for byte in 187 checks. After this pass:

* **state on disk stays byte-exact** — every ref, reflog, index entry,
  object, config line and in-progress marker, in both copies, as now
  (`p6state`, `p8mut`, `p10state`, `git fsck --strict`);
* **machine-readable output stays byte-exact** — `--short`, `--porcelain`,
  `-z`, `--name-only`, `--numstat`, `--format`, `rev-parse`, `rev-list`,
  `ls-*`, `cat-file`, `merge-base`, `for-each-ref`;
* **a patch is checked by applying it** — `gittle diff A B | git apply`
  reproduces `B`, and the line counts match `git diff --numstat`;
* **human-facing prose is checked for content, not bytes** — `--stat` names
  the same files with the same counts; `status` lists the same paths under
  the same headings; a refusal exits non-zero and names the flag.

---

## 7. Engine modules

The survey of `src/*.nim` found no large dead subsystem — the engines are
lean where the algorithms are — but a steady seam of the same loop written
in several modules, and a set of exports that exist for one caller.

### 7.1 The same helper, written more than once

Every one of these is a behaviour-preserving fold, and two of them fix live
inconsistencies (two ISO-date parsers accept different dates; two `%xx`
expanders fail differently).

| helper | copies | where | lines |
|---|---:|---|---:|
| ancestry walk into a set with an explicit stack | 4 | `revwalk` ×3, `reffilter.reachableFrom` | 22 |
| recursive tree walk | 4 | `revwalk.collectTree/walkObjects/anyMatchingUnder` beside `trees.walkTree` | 25 |
| peel an annotated tag | 5 | `reffilter` ×2, `revision`, `indexpack`, beside `repository.peelTo` — one re-parses the `object` header by hand | 18 |
| expand a `revParseRules` rule | 4 | `refs.shortenRef/expandRefName/dwimRef`, `remotes.buildRefMap` | 14 |
| strip `refs/heads/`, `refs/tags/`, `refs/remotes/` | 5 | `remotes.prettify`, `reffilter`, `revision`, `pretty`, `refname.shortenRefname` | 12 |
| `%xx` and hex decoding | 3 | `util.interpolate`, `pretty.expandFormat`, `oid.hexVal` | 15 |
| ISO-8601 date parsing | 2 | `ident.parseDate`, `revision.parseTimestamp` | 13 |
| `-z` path field (NUL vs newline + quoting) | 6 | `diffcore`, `status`, `ls-files`, `ls-tree`, `update-index`, `update-ref` | 10 |
| reflog scan for `checkout: moving from` | 2 | `revision.nthPriorCheckout/headDescription` | 10 |
| `packed-refs` serialiser | 2 | `refs.rewritePackedRefsWithout/packRefs` | 5 |
| read a file if it exists | 10 | `if fileExists(p): …` guards before `readWholeFile` | 9 |
| trailing-whitespace trim | 3 | hand-rolled beside `strip(leading = false)` | 6 |
| dead: `oid.abbrev`; pass-through: `repository.findPackedAt` | | | 8 |
| **total** | | | **≈ 170** |

Added to the command-layer duplicates in §4.4: **≈ 270 lines**, none of it
visible from outside the process.

### 7.2 Generality with no caller

Read-side tolerance stays — R1 says read liberally, and config line
continuations, `\b` escapes, symref chains and the nine-row extension gate
are what make a repository *git* made openable. What goes is write-side or
option-side generality nothing reaches:

* `refs.nim`: the `ruVerify` / `oldTarget` symref-verification machinery
  exists only for `update-ref --stdin`'s `verify`, `symref-*` commands and
  goes with tier 1 (~25); `packRefs` exists only for the local `gc` and
  goes when §3.4 replaces it (~40); `lrAlways` is reachable only from a
  config value no command sets.
* `repository.nim`: `GIT_CEILING_DIRECTORIES`, `GIT_OBJECT_DIRECTORY`,
  `GIT_ALTERNATE_OBJECT_DIRECTORIES` and `objects/info/alternates` (~13) —
  no command creates an alternate and `clone --shared` is not in scope.
  *Keep* the alternates *read* if a git-made `--shared` clone should open;
  cut the two environment variables.
* 26 symbols exported and used only in their own module: drop the `*`.
* `pktline.nim` has one consumer (`transport.nim`) and three of its eight
  exports have one call site each; `mergetree.nim`'s four exports each have
  one. Merging `pktline` into `transport` costs nothing and removes a module
  a reader has to hold.

Also found, not a line-count item: `repository.autoAbbrev` rescans
`objects/17` and sums pack counts on **every call**, and there are 23 call
sites — `log --oneline` over a thousand commits does a thousand directory
scans. Cache it on the `Repository`.

### 7.3 What stays as it is

`refs.nim` (526) is locking, reflogs, packed-refs and the transaction
`prepare`/`commit` — that is the on-disk contract and every line of it is
load-bearing. `packfile`, `indexpack`, `index`, `objects`, `sha1`, `zlib`
are the formats. `mergefile` and `mergetree` are the merge, kept in Nim for
the reasons in §5.3. `transport` and `remotes` were measured in phase 8 at
under budget and are not where the lines went.

---

## 8. Decisions

All taken 2026-09-02.

1. **Tier 1** — cut all ten plumbing wrappers.
2. **Tier 2** — `gc` becomes the server-assisted version of §3.4. `mv`,
   `pull` and `clean` are rewritten as §3.5 says; `stash` is trimmed, not
   wrapped over `worktree`. `rebase` stays. `tag`, `branch`, `grep`,
   `rev-parse` and `ls-files` are trimmed as the table lists.
3. **Tier 3** — every item in the table **except `--color`**, which stays.
4. **External `diff`** — yes, accepting the `@@` function name, the 4%
   hunk-placement divergence, and `diff` as a runtime dependency.
5. **`patch`** — not used; `mergefile.nim` stays.
6. **The option table** — the plain `const` table and generic parser of
   §4.2, not a macro DSL.

When the pass lands, the phase documents and `README.md` get one paragraph
each saying what was cut and why, and `plan.md` §4 and §5 get the new
command list and the new count.

---

## 9. What landed

Measured the same way as everything above, on 2026-09-02, from the
13,872-line baseline:

| step | estimated | landed | notes |
|---|---:|---:|---|
| 1 tier 1 and tier 2, `gc` by the server, the three rewrites | −1,380 | **−1,290** | `update-ref` 281 → 30; `clean` 168 → 59; `mv` 125 → 42; `pull` 76 → 42; `gc` 119 → 69; the ten wrappers gone |
| 2 the option table | −570 | **−470** | `cli.nim` grew 38 → 148 (the parser, the usage generator); the 46 commands and the driver lost the rest. The long `okRefused` rows cost a line or two each, which the estimate did not count |
| 3 external `diff` | −400 | **−283** | `diff.nim` 516 → 233: the whitespace normaliser, the spawn, the hunk-header parser, and the grouping and function-name code kept, which the estimate had counted as gone |
| 4 tier 3 output surface | −415 | **−330** | `pretty` −108, `status` −75, the diffstat arithmetic −50, the diagnostics and hint paragraphs; the rebase todo window stayed, since it is git's own no-hints output |
| 5 duplicate helpers | −270 | **−60** so far | the ancestry walk, the tag peel, the pass-through and the dead helper; the rest of §7.1 is still there |
| **total** | **−3,065** | **−2,148** | **11,724 lines**, 15.5% below the baseline |

Two things the estimates got wrong in the same direction: every "delete
this" item also deletes the doc comments around it, which do not count, so
a 100-line item is rarely 100 code lines; and a table row is a line, so a
command with thirty refused options keeps thirty lines of table where the
estimate saw one `okRefused` entry.

**Every function is documented.** An audit at the end found 251 procs with
no doc comment -- most of them older than this pass -- and each now has
one, saying what it does and, where it is not obvious, what it defends
against. Comments do not count, and readability was the point.

**The oracle after the pass.** Still `tests/oracle.sh`, 168 checks
in the sampled run, changed as §6 said it would be: the plumbing tests read
gittle's state through `git`; the diff engine is checked by applying its
patches with `patch(1)` and comparing line counts with git's `--numstat`
(over 168 real pairs, 145 came out hunk-identical anyway); `log -p` and
`show` forms over real history compare everything but the hunk lines;
`status` is compared against `git -c advice.statusHints=false`; and
`hint:` lines are normalised away. Refs, reflogs, the index, objects,
packs, in-progress markers and both ends of every transport test are
compared exactly, as before.

**What was left, and where it belongs.**

| | |
|---|---|
| the rest of §7.1: the tree-walk copies, the `revParseRules` builder, the ref prefix strips, `%xx`, the two ISO parsers, the `-z` path field, `readIfExists` | step 5; ~200 lines, none of it behaviour |
| un-exporting the 26 symbols with no external caller, folding `pktline` into `transport` | §7.2; cosmetic |
| `autoAbbrev` recomputed on every call | §7.2; a cache on the `Repository`, not a line-count item |
| `rev-list --tags=<glob>` prints nothing where git lists the matching tags | pre-existing, found while checking the table conversion; the glob is not applied to the pseudo-ref |
| `commit --date=<iso with zone>` records the local zone rather than the given one | pre-existing, found the same way; `ident.parseDate` |
