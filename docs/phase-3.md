# Phase 3 — the index and trees

The third phase of the build order in [plan.md](plan.md) §7. Ends when
`update-index`, `ls-files`, `write-tree`, `read-tree` and `ls-tree` work, and
`git fsck` and `git status` are clean after gittle has written the index.

**Status: complete (2026-09-01).** All ten tasks done; `tests/oracle.sh
--full` passes 97 checks across three phases. See [Results](#results).

---

## Environment

Unchanged from [phase 2](phase-2.md). The oracle is `../git`, built from the
reference tree; `tests/oracle.sh` prefers it over `PATH` automatically.

## What the index is, and why it is the awkward one

The index is a flat, sorted list of *every path in the repository* with the
object ID it currently stages and a copy of the file's `stat` data. It is
three things at once, and phases 4 and 5 need all three:

* **The staging area.** `add` writes it, `commit` turns it into a tree.
* **A cache.** The `stat` data exists so `status` can answer "did this change?"
  for ten thousand files without reading ten thousand files. Whether that cache
  is *trusted correctly* is the whole difficulty (see "racily clean" below).
* **The merge scratchpad.** During a conflict one path has up to three entries,
  at stages 1, 2 and 3, which is why the sort key is (path, stage).

### The formats

A 12-byte header (`DIRC`, a version, an entry count), the entries, then
extensions, then a trailing checksum. Version 2 is the base; **v3** adds a
second flags word per entry, and **v4** prefix-compresses each path against the
previous one and drops the padding.

Decision 8: v1 **reads 2, 3 and 4** and **writes 2, or 3 when an entry needs
extended flags** — which is git's own rule. The v4 read is about thirty lines
and reuses the ofs-delta varint from phase 1; refusing to open a colleague's
repository over that would have been a poor trade.

### Extensions, and which may be ignored

An extension whose signature begins `A`-`Z` is *optional*; a lowercase one is
*required*, and an implementation that does not understand it must not proceed.

| | |
|---|---|
| `TREE` | the cache tree, which makes `write-tree` incremental — **a cache (R3)**, so it is not read, and it is **dropped rather than preserved** on write |
| `REUC` | resolve-undo, for recreating a conflict after `checkout -m` — dropped |
| `UNTR`, `FSMN`, `EOIE`, `IEOT` | untracked cache, fsmonitor, and two threading accelerators — all caches (R3), all dropped |
| `link` | split index — **required, and refused**: `git update-index --no-split-index` |
| `sdir` | sparse directory entries — **required, and refused** |

Dropping an optional extension is safe; git rebuilds it. *Preserving* one
across a write would not be, because a cache tree that no longer matches the
entries is a `write-tree` that produces the wrong tree.

### Racily clean entries

The one genuinely subtle thing here. If a file is modified in the same second
that the index is written, its recorded mtime equals the index's own, and
nothing in the stat data can distinguish "unchanged" from "changed after we
looked". git calls this *racily clean* and handles it on the write side: an
entry whose mtime is not older than the index gets its recorded **size set to
zero**, which forces the next reader to compare content instead of trusting the
stat (`read-cache.c:ce_smudge_racily_clean_entry`).

gittle does the same, conservatively: smudge on write whenever the entry's
mtime is not older than the index's. Over-smudging costs a hash on the next
`status`; under-smudging reports a modified file as clean, which is the kind of
bug that loses work.

### Why write-tree is a single pass

Index entries are sorted by path as raw bytes. Tree entries are sorted by name
with an implicit `/` appended to directory names — which is why `foo.txt` comes
before the tree `foo` (`.` is 0x2E, `/` is 0x2F). Those two orders agree: walk
the sorted index once, and every group of paths sharing a directory prefix
appears exactly where that directory's tree entry belongs. The index's sort
order *is* the tree-building algorithm, so no sorting or intermediate structure
is needed (R7: do not build what you immediately consume).

## Layout as built

As proposed. Two things moved into `repository.nim` because a second caller
appeared: `peelTo`, which turns a `<tree-ish>` into the tree it names (`ls-tree
HEAD` and `cat-file tree v1.0` are the same operation), and `uniqueAbbrev`.

```
src/
  index.nim         the DIRC format: read v2/v3/v4, write v2/v3, stat compare  264
  trees.nim         index -> tree, tree -> index, recursive tree walking        68
  cmd/
    lstree.nim                                                                  72
    updateindex.nim                                                            105
    lsfiles.nim                                                                 83
    readtree.nim                                                                32
    writetree.nim                                                               11
```

## Task list

1. **Index read, v2.** Header, entries, the flags word, the trailing checksum —
   **tolerating a zeroed one** (`index.skipHash`, noted in phase 1 and still
   not forgotten).
2. **Index read, v3 and v4.** The extended flags word; the path prefix
   compression and its varint.
3. **Extensions.** Skip optional ones by their length; refuse `link` and `sdir`
   by name with the command that fixes them.
4. **Index write, v2/v3.** Byte-exact framing (R1), the racy smudge, and an
   atomic `index.lock` plus rename — the same discipline as a ref update.
   *Oracle: git reads back what gittle wrote and `git status` agrees.*
5. **Stat comparison.** Does an entry match the file on disk? Mode, size, mtime,
   and the racy fallback to content.
6. **`ls-tree`.** `-d`, `-r`, `-t`, `-l`, `-z`, `--name-only`, `--abbrev`,
   paths. Needs recursive tree walking, which `write-tree` also uses.
7. **`update-index`.** `--add`, `--remove`, `--refresh`, `--cacheinfo`,
   `--stdin`, `-z`, `<file>…`.
8. **`ls-files`.** `-c`, `-s`, `-d`, `-m`, `-u`, `--error-unmatch`, paths.
9. **`write-tree`.** The single pass above. *Oracle: identical tree object IDs
   to git's for the same index, and `git fsck` clean.*
10. **`read-tree`.** A single tree, and `--empty`.

## The oracle procedure

The index is a *shared* file, so the test is interleaving, not round-tripping:

```sh
# gittle writes the index, git must agree about the working tree
gittle update-index --add f && git status --porcelain && git write-tree

# git writes the index, gittle must agree
git add f && gittle ls-files -s && gittle write-tree

# and the trees must be identical objects, not merely equivalent
[ "$(git write-tree)" = "$(gittle write-tree)" ]
```

Plus the same discipline as phase 2 (R8): where a command has an enumerable
shape, enumerate it against git rather than asserting what the manual says.

---

## Results

`tests/oracle.sh --full`, 97 checks across three phases, all passing.

| Check | Coverage |
|---|---|
| `ls-tree` | **143 option and path combinations** against the reference repository's own tree — 561 top-level entries, 4,850 recursive, every mode git stores including a gitlink |
| `ls-files` | git's own 4,850-entry index read without touching it, plus five pathspecs |
| `write-tree` | the **same tree object** as git from that same index, and from a hand-staged one |
| interleaving | gittle stages, `git status` shows exactly the right four paths, `git fsck --strict` is clean, and both tools agree on `ls-files -s` |
| `ls-files` selectors | 16 combinations against a working tree that is modified, deleted and `chmod`'d at once |
| `--refresh` | `git status` is empty afterwards |
| index versions | 2, 3 and 4 all read; a v3 index keeps its extended flags through a gittle rewrite |
| `index.skipHash` | an all-zero trailer is accepted |
| split index | refused **by name**, with the command that undoes it |
| path quoting | a quote, a space and a UTF-8 name, quoted identically to git, and unquoted under `-z` |
| `read-tree` | a tree and `--empty`; `git write-tree` afterwards gives `HEAD^{tree}` |
| unmerged | three stages read correctly, and `write-tree` refuses |

### What the oracle caught that reading would not have

Five behaviors where the documentation and the implementation disagree, each
found by running the same command through both tools (R8):

**`ls-tree` does no wildcard matching at all.** Its manual page calls the
arguments "a list of patterns to match", and `git ls-tree -r HEAD -- '*.c'`
lists **nothing** — where `git ls-files -- '*.c'` lists 641 files. ls-tree
permits only `literal` and `top` pathspec magic
(`builtin/ls-tree.c:420`); matching is exact paths and directory prefixes, and a
`*` is a literal asterisk. `ls-files`, by contrast, globs *across* `/` by
default: `*.c` finds 641, `:(glob)*.c` finds 244.

**`--abbrev=<n>` is a minimum, not a length.** git lengthens it until the
result names one object. Truncating instead produces output that looks right
and cannot be pasted back. Bare `--abbrev` is not 7 either — it scales with the
object count, and is 10 in a repository this size.

**`ls-tree -d` drops blobs, not non-trees**, so a gitlink still shows. And
`-d -r` together imply `-t`.

**`ls-tree` descends without `-r`** when a path argument names something below
a directory — and the *trailing slash matters*: `-- t/` descends into `t` where
`-- t` does not.

**`ls-files` runs its selectors in one pass with up to three emissions per
entry**, so a file that is cached, deleted *and* modified is printed three
times, interleaved. It is not three passes, and it is not deduplicated.

### Two bugs of our own

**`write-tree` would have littered the object store.** `writeObject` checked
only for a loose copy, not a packed one, so rewriting the git repository's own
trees would have created thousands of loose duplicates of objects already in
the pack. git makes the same check (`freshen_packed_object`).

**A missing import silently changed output.** `write-tree` printed
`(b: [179, 176, ...])` instead of an object ID, because `cmd/writetree.nim`
did not import `oid` — so Nim selected its generic `$` rather than failing to
compile. `repository.nim` now re-exports `oid` and `objects` for that reason.

## Budget

```
                                    budgeted   actual
index v2/v3 read/write                   400      264   and v4 read
object parse/format (tree half)          300       68   trees.nim
working tree: checkout, status            600      ~40   stat compare only, so far
command dispatch, arg parsing, 53 cmds  2,000    1,199   11 commands + driver
```

Total: 3,471 lines of code (5,425 including comments) of the ~9,000 budgeted,
with phases 1–3 of 10 complete.

**The command layer is the problem, and it is now visible.** 1,199 of 2,000
with 11 of 53 commands — 60% of the budget for 21% of the commands. The three
biggest are `update-ref` (281), `for-each-ref` (192) and `update-index` (105),
and phase 4 lands `add`, `commit` and `log` while phase 5 lands `diff`,
`status` and `grep`. On the current trend those six alone would exhaust what is
left. Either the remaining commands are genuinely much smaller than the ones
built so far — plausible, since `branch`, `tag` and `init` are thin — or the
2,000-line figure needs revisiting with evidence rather than being quietly
overrun. **Decide this at the end of phase 4, when `commit` and `log` give a
real data point.**

## Notes carried forward

- **`ls-files -o`, `-i` and `--exclude-standard`** are in scope (docs/09) but
  need the ignore engine, which plan.md §7 puts in phase 4. Until then they
  must fail with a message saying so rather than listing everything.
- **`read-tree -m`, `--reset` and `-u`** are in scope (docs/10) but two- and
  three-way tree merging is phase 7, and updating the working tree is the
  checkout machinery of phase 6. Phase 3 does the plain single-tree read.
- **Sparse checkout is cut**, so an index containing directory entries with
  `SKIP_WORKTREE` is not something gittle produces; the `sdir` refusal is what
  keeps it from half-reading one someone else produced.

### Added during phase 3

- **The `TREE` cache extension is dropped on every write.** git rebuilds it, so
  this costs a `write-tree` some time and costs nothing in correctness —
  preserving a cache tree that no longer matches the entries would produce the
  *wrong tree*, which is why it is dropped rather than carried across.
- **`core.quotePath` is not implemented**, only its default. gittle always
  quotes bytes above ASCII; git can be told not to.
- **`--refresh` does not honor `--really-refresh`, `-q` or `--unmerged`**
  (docs/10 cuts them), and reports `<path>: needs update` on stdout the way git
  does.
- **The racy-clean smudge is conservative.** git smudges only entries it has
  confirmed are clean-but-racy; gittle smudges any entry whose mtime is not
  older than the index. The cost is a hash on the next `status`; the risk it
  removes is reporting a modified file as clean.
