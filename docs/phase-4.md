# Phase 4 — the first commit

The fourth phase of the build order in [plan.md](plan.md) §7, and the last of
the three risky ones: everything after this depends on the on-disk formats
being exactly right. Ends when `init`, `add`, `commit`, `log` and `show` work,
a repository gittle created from nothing is one real git is happy to continue
in, and the ignore engine keeps `add` from staging build output.

**Status: complete (2026-09-01).** All twelve tasks done; `tests/oracle.sh
--full` passes 139 checks across four phases. See [Results](#results).

---

## Environment

Unchanged from [phase 3](phase-3.md). The oracle is `../git`, built from the
reference tree; `tests/oracle.sh` prefers it over `PATH` automatically.

## What this phase actually is

Phases 1–3 built the three on-disk formats — objects, refs, the index — and
eleven plumbing commands that each touch one of them. Nothing yet connects
them. Phase 4 is the vertical slice that does: a directory becomes a
repository, files become an index, the index becomes a tree, the tree becomes
a commit, and the commit becomes a branch tip with a reflog entry. Every layer
below is exercised in the one order a user actually drives it.

Two engines arrive with it, neither of which is a command:

* **The ignore and pathspec matcher.** `add` is unusable without it — `git add
  .` in any real project would stage the build directory — and `status` in
  phase 5 is unusable without it twice over. plan.md §4 has the specification;
  it understates the thing badly, calling it a scattering of flags when it is a
  shared engine five commands depend on.
* **The revision walk.** `log` needs it now; `rev-list`, `merge-base`,
  `branch --merged` and the whole of phase 6 need it later.

## The commit object

    commit <size>\0
    tree <40 hex>\n
    parent <40 hex>\n        (zero or more, in order; a merge has several)
    author <ident>\n
    committer <ident>\n
    <optional further headers>\n
    \n
    <message bytes, verbatim>

Byte-exactness (R1) is the whole game here, and it is *easy to get wrong in a
way nothing catches*: an extra trailing newline, a missing one, or a message
whose blank lines were cleaned up differently all produce a valid commit with
the wrong object ID. That commit is then a permanently forked history, and no
test that only reads back what gittle wrote will notice.

So the message pipeline is specified rather than improvised
(`strbuf.c:strbuf_stripspace`, `sequencer.c:get_cleanup_mode`):

| | |
|---|---|
| `-m` given twice | joined so the paragraphs are separated by one blank line |
| no editor involved | *whitespace* cleanup: strip trailing whitespace per line, drop leading and trailing blank lines, collapse runs of blank lines to one |
| an editor was opened | *strip* cleanup: the same, **plus** remove every line beginning with the comment character |
| either way | the message ends with exactly one newline |
| an empty result | refused, because an empty message is almost always an editor the user quit out of |

`--cleanup=<mode>` itself is out of scope (docs/06); the two modes above are
the ones its default selects, and gittle implements the default.

## The ignore engine

plan.md §4 specifies it in full — sources, precedence, pattern syntax, and the
two traps. Restating only what shapes the code:

**Four sources, and the deepest match wins.** For a path, the `.gitignore` in
its own directory is consulted first, then each parent's up to the working-tree
root, then `$GIT_COMMON_DIR/info/exclude`, then `core.excludesFile`. The first
*file* with any matching pattern decides; within a file, the *last* matching
pattern decides. Those are two different rules and both matter.

**A pattern with no slash matches a basename** (`dir.c`'s `PATTERN_FLAG_NODIR`
and `match_basename`); one with a slash is anchored to its own file's
directory. The documentation's phrasing — "checked against the pathname
relative to the location of the .gitignore file" — describes only the second
case, and an implementation written from it excludes far too little.

**You cannot re-include a file whose parent directory is excluded.** git never
descends into an excluded directory, so `!sub/keep.txt` after `sub/` does
nothing. In the *walk* that falls out for free: a pruned directory is not
entered. For a path named directly on the command line there is no walk, so
`isIgnored` has to test every ancestor directory itself before testing the
path. Implementing negation without this rule produces a matcher that looks
correct on small cases and diverges on real repositories.

**Ignore rules apply only to untracked files.** A tracked file stays tracked
whatever any `.gitignore` says, which is why `add` runs two passes (below) and
only the second one consults the matcher at all.

## What `add` is

Not one operation but two, over the same pathspec:

1. **The index pass.** Every entry already in the index that the pathspec
   matches is re-staged from the working tree, and *removed* if its file is
   gone. Ignore rules are not consulted. This is `-u`.
2. **The walk pass.** The working tree is walked, `.git` and every ignored
   directory pruned, and untracked files matching the pathspec are staged.

Plain `git add <pathspec>` does both — since git 2.0 it records removals too,
so it is `-A` restricted to the pathspec. `-u` is pass 1 alone; `-A` is both
with the pathspec defaulting to the whole tree.

A path named *explicitly* that ignore rules exclude is an error listing the
paths and pointing at `-f`, exit status 1 — not a silent skip, and not a fatal
128.

## The revision walk

A priority queue of commits ordered by committer date, newest first, seeded
with the starting commits and popping each commit's parents in. That is git's
default order for `log`; `--topo-order` and `--date-order` are phase 6 with
the rest of the `rev-list` option surface.

**Path limiting** is history simplification, and it is in scope now because
both halves already exist: the tree walk from phase 3 and the pathspec matcher
from this one. The default rule: a commit whose tree, restricted to the
pathspec, is identical to some parent's is not shown, and the walk follows
that parent only; otherwise the commit is shown and every parent is followed.
Comparing two trees under a pathspec short-circuits wherever two subtree object
IDs are equal, which is what makes it cheap on a real repository.

Note what this is *not*: it is a tree comparison, not a diff. No hunks, no
Myers, nothing from phase 5.

## Layout as built

As proposed. `pretty.nim` came out four times the size of anything else in
it, which is the phase's main budget finding (below).

```
src/
  pathspec.nim    parse and match pathspecs, over the phase-2 glob engine   129
  ignore.nim      exclude patterns, the per-directory stack, ancestors      103
  dir.nim         the working-tree walk, and staging one path                54
  commitobj.nim   the commit object: parse, build, and message cleanup      130
  revwalk.nim     the date-ordered walk, and path limiting                   85
  pretty.nim      date formats, pretty formats, decoration                  392
  hooks.nim       pre-commit, commit-msg, and the editor                     38
  cmd/
    init.nim                                                                 62
    committree.nim                                                           45
    add.nim                                                                  89
    commit.nim                                                              205
    log.nim                                                                 151
    show.nim                                                                 83
```

Two things moved rather than being written twice. `stageWorkingPath` is in
`dir.nim` because `add`, `commit -a`, the partial-commit scratch index and
`update-index` all stage a working-tree file the same way -- `update-index`
kept only its refusals. `Pathspec.firstUnmatched` is in `pathspec.nim` because
`add`, `commit` and `ls-files --error-unmatch` all ask "did every item match
something", and only what they do about the answer differs.

`commit-tree` is not in the phase list in plan.md §7, but it is the engine
under `commit` with an argument parser in front of it — twenty lines that make
the commit format testable without the index, the hooks or the editor in the
way — which is exactly how the message-cleanup rules were settled. It is in
the v1 scope (docs/10) either way.

## Task list

1. **`init`.** The directory skeleton, byte-identical to git's minus the
   template: `HEAD`, `config`, `objects/{info,pack}`, `refs/{heads,tags}`.
   `-q`, `--bare`, `-b`/`--initial-branch`, `init.defaultBranch`, and
   re-initialising an existing repository without damaging it.
2. **The commit object.** Parse and format, and `commit-tree`. *Oracle:
   identical object IDs to git's for the same tree, parents and identities.*
3. **Message cleanup.** The `strbuf_stripspace` rules above, `-m` joining,
   `-F`, `-s`, and the editor path. *Oracle: enumerate messages — blank runs,
   trailing space, comment lines, a bare newline — through both tools and
   compare object IDs, not text.*
4. **Pathspec matching.** The magic gittle accepts (`:(literal)`, `:(glob)`,
   `:(icase)`, `:(top)`, `:!` exclusion) and the default semantics `ls-files`
   already relies on. Replaces the local matcher in `cmd/lsfiles.nim`.
5. **The ignore engine.** Sources, precedence, the pattern forms in plan.md
   §4, the ancestor rule. *Oracle: `git check-ignore -v` over a generated
   pattern/path matrix — it reports which file and line decided, so a
   disagreement says where.*
6. **The working-tree walk.** Prune `.git` and ignored directories; classify
   tracked, untracked, ignored. Unblocks `ls-files -o`, `-i` and
   `--exclude-standard`, deferred from phase 3.
7. **`add`.** The two passes, `-n`, `-v`, `-f`, `-u`, `-A`, `--`, and the
   refusal for an explicitly named ignored path.
8. **`commit`.** `-m`, `-F`, `-a`, `<pathspec>`, `--amend`, `--allow-empty`,
   `--author`, `--date`, `-s`, `-q`, `-e`/`--no-edit`, `-n`/`--no-verify`.
   The reflog messages git writes, and `ORIG_HEAD` where git writes it.
9. **Hooks.** `pre-commit` and `commit-msg` only (decision 1): fork, exec,
   inherit stdio, non-zero aborts. `--no-verify` bypasses both.
10. **The revision walk**, and path limiting.
11. **`log`.** The walk plus `-n`/`--max-count`, `--skip`, `--reverse`,
    `--parents`, `--count`, `--no-walk`, `--first-parent`, `--decorate`,
    `--abbrev-commit`, the pretty formats, `--date=<format>`, and `[--]
    <path>…`.
12. **`show`.** `log -1` for a commit; type-specific rendering for a tag, a
    tree and a blob.

## What is deliberately deferred, and to where

| | |
|---|---|
| the diff `log` and `show` print for a commit | phase 5 — this is the visible gap in `show` |
| `log --grep`, `--author`, `--committer` | phase 5, with the regex engine (plan.md §6.4) |
| revision *ranges*: `A..B`, `^A`, `--all`, `--branches`, `--tags` | phase 6, with `rev-list` and `rev-parse` |
| `--topo-order`, `--date-order`, `--since`, `--until` | phase 6 |
| `commit` on a repository mid-merge (`MERGE_HEAD`) | phase 7 |
| `check-ignore` the *command* (the engine lands here) | phase 10 |

## The oracle procedure

The phase-3 discipline, with one addition. Where the previous phases could
compare *output*, this one must compare **object IDs**, because that is what a
byte-exact writer is for: a commit whose message differs by one trailing
newline prints identically under `log` and is a different object.

```sh
# the same inputs to both tools must produce the same commit
a=$(git commit-tree "$T" -p "$P" -m "$MSG")
b=$(gittle commit-tree "$T" -p "$P" -m "$MSG")
[ "$a" = "$b" ]

# a repository gittle built from nothing, continued by git
gittle init r && cd r && gittle add . && gittle commit -m one
git fsck --strict && git status --porcelain && git log --format=%H

# and the reverse
git init r2 && cd r2 && git add . && git commit -m one
gittle log --format=%H
```

And, per R8, enumerate rather than assert: the message-cleanup matrix, the
ignore matrix against `check-ignore -v`, the pretty-format and date-format
vocabularies, and the `add` option matrix all have an enumerable shape.

## Watch this number

phase-3.md ends by asking for a decision at the end of *this* phase: the
command layer is 1,199 lines of the 2,000 plan.md §5 budgets for all 53
commands, and phase 4 lands six more. Either the remaining commands are
genuinely much smaller, or the figure needs revisiting with evidence. The
answer belongs in this document's Results section, with the number.

---

## Results

`tests/oracle.sh --full`, 139 checks across four phases, all passing.

| Check | Coverage |
|---|---|
| `init` | the directory tree, `config` and `HEAD` **byte-identical** to git's for both a working and a bare repository, `-b`, and a re-init that leaves HEAD and every ref alone |
| `commit-tree` | **15 object IDs** over a matrix of trees, parents, duplicate parents and message shapes, plus repeated `-m` and `-F` |
| message cleanup | **10 message shapes** — leading and trailing blank runs, trailing whitespace, tabs, a comment line, non-ASCII — each compared as an **object ID**, plus `-F` and the empty-message refusal |
| ignore and pathspec | **20 listings** of a generated tree against `ls-files -o`, `-o -i` and bare `-o`, with a nine-pattern `.gitignore`, two nested ones, and the same queries run from four subdirectories |
| ignored-path decisions | **15 paths** cross-checked against `git check-ignore`, through `add` (the command itself is phase 10) |
| `add` | **28 option and pathspec combinations**, each compared on the resulting index and exit status; the `-u`/`-A`/plain matrix against a tree that is modified, deleted and extended at once; `-n` writes nothing; a pathspec that climbs out of a subdirectory |
| `commit` | a **nine-commit history built twice**, identical objects, reflogs, index and `git status`; then git and gittle each add a commit to the other's repository and `fsck --strict` stays clean |
| hooks | `pre-commit` refuses, `--no-verify` bypasses, `commit-msg` rewrites the message, `$GIT_EDITOR` runs as a shell command line, and a `pre-commit` hook under `-a` sees the same staged state git shows it |
| `log` formats | **37 format, date and option vocabularies** over **20,000 commits** of the reference repository |
| `log` path limiting | **12 pathspecs**, history simplification included, plus the bare-path form and one from a subdirectory |
| `log` deferrals | 7 later-phase options refuse by name rather than being ignored |
| `show` | **all 1,008 tags** in the reference repository — annotated, signed, one nested tag-of-a-tag, one pointing at a blob — plus a tree, a blob and five commit formats |

### What the oracle caught that reading would not have

**`%s` and `%f` are two different subjects.** `%s` folds a wrapped first
paragraph onto one line; `%f` sanitises only the **first line**
(`pretty.c`: `strchrnul(msg, '\n')` before `format_sanitized_subject`). One
commit in 20,000 has a two-line subject, and it is the only place the two
differ. Found by sweeping, not by reading — the manual describes `%f` as "the
sanitized subject line".

**Tab expansion is a default, not an option.** `--expand-tabs` is out of scope
(docs/04), which reads like "emit the tab". It is the opposite: `medium`,
`full` and `fuller` expand tabs to a stop of 8 by default and `--no-expand-tabs`
is the option — and `raw` does not, from a per-format column in
`pretty.c:builtin_formats`. The tab stop is counted from the start of the
*message* line, so the four-space indent does not shift it.

**`format:` separates, `tformat:` terminates — unconditionally.**
`--pretty=format:%h` leaves a file with no trailing newline; `tformat:%B` ends
with *two*, one from the message and one from the format. An implementation
that adds the terminator only when the entry does not already end in a newline
is right in every case except that one.

**git rtrims the whole rendered commit.** `pretty_print_commit` ends with
`strbuf_rtrim` then one `\n`. That is what stops a message's trailing blank
line from leaving a four-space line in the output — invisible in every commit
whose message is already clean, which is nearly all of them.

**`--abbrev=<n>` does not abbreviate the `commit` line.** It sets the length
abbreviations *use*; `--abbrev-commit` turns the header abbreviation on. So
`log --abbrev=12` changes `%h` and the `Merge:` line and nothing else.

**`:(top).` is the literal path `.` and matches nothing**, where a bare `.` is
the whole tree — because git normalises only the items it applies a prefix to.
Collapsing both to "the whole tree" makes `:(top).` list every file.

**`log --count` is silently ignored by git.** It is a `rev-list` option that
`log` parses and never acts on. gittle refuses it instead, with the phase that
brings `rev-list`; that is a deliberate divergence, on the grounds that
printing a full log when asked for a count is worse than an error.

**`ls-files` in a subdirectory lists that subdirectory**, named relative to it,
because an empty pathspec becomes the current directory
(git's `PATHSPEC_PREFER_CWD`). Phase 3's `ls-files` did not do this — the bug
was invisible until there was a pathspec layer to compare against.

### Three bugs of our own

**`%b` invented a newline.** A commit message that does not end in a newline
exists in real history (one in the 20,000 swept), and `%b` printed it with one
because `body()` "completed the line". A formatter that edits the data is a
formatter that cannot be trusted with a byte-exact writer next to it.

**The partial commit left the index stale.** `commit <pathspec>` built the
right tree but never staged those paths in the *real* index, so `git status`
showed the committed file as modified. It only surfaced because the test
builds nine commits in sequence and every later commit inherited the wrong
tree.

**Author and committer read the clock twice.** Two `getIdent` calls straddling
a second boundary produce a commit whose author and committer dates differ by
one second, at random. The clock is now read once per process, which is what
git does (`ident.c:ident_default_date`) and for the same reason.

## Budget

```
                                       budgeted   actual  cumulative
pathspec + ignore matching (shared)         500      286   pathspec+ignore+dir
object parse/format (commit third)          300      130   commitobj.nim
revision walk                               250       85   revwalk.nim
hooks: pre-commit + commit-msg               60       38   hooks.nim, incl. the editor
command dispatch, arg parsing, 53 cmds    2,000    1,861   17 commands + driver
```

Total: **5,087 lines of code** (8,090 including comments) of the ~9,000
budgeted, with phases 1–4 of 10 complete. The three engines came in at
roughly half their budgets. `pretty.nim` — 392 lines of date and commit
formatting — has no line of its own in plan.md §5 at all, which is the finding
below.

### The command-layer decision phase 3 asked for

phase-3.md ended by asking for a decision here, with the number. It is
**1,861 of the 2,000 budgeted, for 17 of 53 commands** — 93% of the budget for
32% of the commands. Phase 3 was 1,199 for 11.

The trend did not continue linearly, and the reason is worth recording: the six
commands added here average 109 lines against phase 3's 109, but **the growth
moved out of `cmd/` and into `pretty.nim`**. Formatting a commit is command-layer
work by plan.md §2's own definition — "a third of git is the command layer,
options and output formatting" — and putting it in a shared module made it
*smaller*, not cheaper. Counting it where it belongs, the command layer is
2,253 lines and the 2,000-line budget is already spent.

Three things follow, and the third is the recommendation:

1. **The remaining commands really are thinner.** `branch`, `tag`, `init`-like
   creation, `merge-base`, `symbolic-ref`-like plumbing and the seven
   `rev-list`-family readers are argument parsing over engines that exist.
   `status` and `diff` are not: both are output formatting over the phase-5
   engine, and both will want to live outside `cmd/` for the same reason
   `pretty.nim` does.
2. **The figure was a sketch, not an estimate** (plan.md §5 says so). What it
   was guarding against is a command layer that grows with accepted option
   combinations. That has not happened: every phase-4 command refuses a named
   list rather than half-implementing it, and those refusal tables are 40 of
   the 626 lines.
3. **Revise it to 2,600 and re-scope the line as "commands and output
   formatting"**, so that moving code out of `cmd/` stops looking like a
   saving. On the remaining evidence — 36 commands left, most of them thin,
   two of them (`status`, `diff`) genuinely large — that lands near 2,500 with
   the whole of §5 still inside 9,000. The number to watch after phase 5 is
   what `status` costs.

## Notes carried forward

- **`.mailmap` is not implemented, and git applies it by default.**
  `log.mailmap` has defaulted to true since git 2.34, so `git log` and
  `git show` rewrite author and committer identities through `.mailmap` and
  gittle does not. docs/07 cuts `--mailmap`, so this is in-scope behavior — but
  it is the one place where gittle's `log` disagrees with git's on an ordinary
  repository. **Measured: 18,512 of the 82,130 commits in the reference
  repository display a different identity with it on.** The suite passes
  `--no-use-mailmap` to every comparison, which is honest but means the
  difference is untested rather than absent. The engine is a ~90-line file
  (parse four line shapes, look up by email then by name); the decision to add
  it belongs in plan.md, not here. Related: `%aN`/`%aE`/`%cN`/`%cE` are the
  mailmap-aware placeholders and gittle currently treats them as `%an`/`%ae`,
  which is correct only while there is no mailmap.
- **`commit` prints no diffstat.** `[master abc1234] subject` is there; the
  ` 1 file changed, 1 insertion(+)` and `create mode 100644 f` lines under it
  are a diff. Phase 5.
- **`show <commit>` prints no patch**, for the same reason — it is `git show -s`.
  Phase 5.
- **`nothing to commit` is reported without the `status` output** git prints
  with it. Phase 5, with `status`.
- **`log` revision ranges are absent**: `A..B`, `^A`, `HEAD~3`, `--all`,
  `--branches`, `--tags`. `resolveOid` handles a full or abbreviated object
  name and a ref; the `~`, `^`, `@{…}` and `<tree-ish>:<path>` operators are
  phase 6 with `rev-parse`, and `show HEAD~1` fails until then.
- **`--topo-order`, `--date-order`, `--since` and `--until`** are phase 6.
  Only commit-date order exists.
- **`--grep`, `--author`, `--committer`, `-i`, `-E`, `-F`** are phase 5, with
  the regex engine (plan.md §6.4).
- **`--decorate=full` is refused**; `short`, `auto` and `no` work. Decoration
  defaults to `auto`, so it is off when stdout is not a terminal — which is
  also why the oracle rarely exercises it.
- **`check-ignore` is phase 10.** The engine is here and is tested through
  `add` and `ls-files`; the `-v` output needs the source file and line number
  that `ignore.nim` deliberately does not carry yet (R7).

### Added during phase 4

- **A nested repository is skipped with a warning**, not recorded as a
  gitlink. git's `add` stages a `160000` entry; submodules are cut (plan.md
  §4), so staging one would produce a repository gittle could not then read.
- **`init` writes no template.** No `hooks/*.sample`, no `description`, no
  `info/exclude`. None is read by anything — an absent `info/exclude` is an
  empty one — so a gittle-created repository is still one git operates on
  without noticing, but `find .git` does not match git's output.
- **`core.commentChar` is not configurable**, only its default `#`. The editor
  template gittle writes uses the same character, so the two always agree.
- **The `Signed-off-by` trailer block is approximate.** git has a trailer
  parser; gittle adds a blank line before the signoff unless the last paragraph
  is already all `Token: value` lines. It gets the case that matters — not
  separating a `Signed-off-by` from one already there — and nothing else.
- **`tests/oracle.sh` says `#!/bin/bash`.** It said `#!/bin/sh` and used
  process substitution throughout, so it had never actually run under a POSIX
  shell; on a system where `/bin/sh` is dash it died at line 270. The suite
  also pins `GIT_AUTHOR_DATE` and `GIT_COMMITTER_DATE` now, because two tools
  can only agree on a commit's object ID if they are told the same instant.
