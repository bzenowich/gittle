# Phase 2 — refs and config

The second phase of the build order in [plan.md](plan.md) §7. Ends when
`update-ref`, `symbolic-ref`, `for-each-ref` and `config` work against loose
refs and `packed-refs`, and real git agrees with everything gittle writes.

**Status: complete (2026-09-01).** All twelve tasks done; `tests/oracle.sh
--full` passes 80 checks, phases 1 and 2 together. See [Results](#results).

---

## Environment

Changes since [phase 1](phase-1.md); everything else there still holds.

| | |
|---|---|
| **The oracle binary** | `/home/bz/code/git/git` — **built from the reference tree**, `2.55.0.782.g1630431f32`. The system `git` is 2.43.0, which predates `config get`/`set`/`list` (2.46) and so cannot check half of this phase. |
| How it was built | `make -j8 NO_GETTEXT=1 NO_TCLTK=1 NO_OPENSSL=1 NO_CURL=1 NO_EXPAT=1 NO_RUST=1`. The sandbox has no `cargo`, and git 2.55 builds `libgitcore.a` in Rust unless `NO_RUST=1`. |
| Build artifacts | git's own `.gitignore` covers them; the reference tree stays clean. |

`tests/oracle.sh` prefers `$REFREPO/git` over the one on `PATH`, so it uses the
matching binary automatically.

## Why refs are more than a file with a hash in it

The formats are trivial. What is not trivial is that a ref update has to be
*safe*: two processes updating the same branch must not interleave, a reader
must never see a half-written value, and a compare-and-swap must actually
compare. Everything in this phase exists to make that true.

Four things live behind the same name:

* a **loose ref**, `$GIT_DIR/refs/heads/main`, holding 40 hex digits and a
  newline;
* a **packed ref**, a line in `$GIT_DIR/packed-refs`, which is what a loose ref
  becomes after `git gc`. Loose wins when both exist;
* a **symbolic ref**, a file holding `ref: refs/heads/main`, which is what HEAD
  normally is;
* a **per-worktree ref**. `refs/worktree/`, `refs/bisect/`, `refs/rewritten/`
  and the pseudorefs (HEAD, ORIG_HEAD, …) live in the worktree's own git
  directory; every other ref lives in the common directory shared with the main
  worktree (`refs.c:is_per_worktree_ref`).

Deleting a ref is the awkward case: it may have to remove a loose file *and*
rewrite `packed-refs`, and it must not leave the ref visible through the other
if it fails in between.

## Layout as built

Reflog writing ended up inside `refs.nim` rather than in a module of its own:
a ref update is the only thing that ever appends to a reflog, and the entry has
to be written by the same code that knows what the old value was. `glob.nim`
was not planned for this phase and arrived early — `for-each-ref` patterns need
a matcher, and writing a throwaway one would have meant writing it twice.

```
src/
  refname.nim       ref name validation and shortening                43
  refs.nim          the ref store: read, resolve, iterate, update    458
  ident.nim         who is writing, and when                          57
  glob.nim          the shared glob engine (early, from phase 4)      87
  config.nim        the INI subset, now with a line editor           291
  repository.nim    + the ref store and ref-aware name resolution    235
  cmd/
    updateref.nim                                                    240
    symbolicref.nim                                                   55
    foreachref.nim                                                   231
    config.nim                                                        91
```

## Task list

Ordered so each step is verifiable before the next depends on it.

1. **Ref name validation.** `refs.c:check_refname_format`: no `..`, no `@{`, no
   ASCII control characters, none of `` : ? [ \ ^ ~ `` space or tab, no
   component starting with `.` or ending `.lock`, no trailing `.`, not a lone
   `@`, at least two components unless one level is allowed. *Verify against
   `git check-ref-format` on a table of good and bad names.*
2. **Loose ref read.** Direct and symbolic, with the per-worktree rule deciding
   between `gitDir` and `commonDir`.
3. **`packed-refs` read.** The header line, `<oid> <name>`, and `^<peeled>`
   continuation lines. Loose refs shadow packed ones.
4. **Ref resolution.** Follow symbolic refs (git's limit is 5), and the
   `refs.c:ref_rev_parse_rules` DWIM order: the name itself, then `refs/`,
   `refs/tags/`, `refs/heads/`, `refs/remotes/`, `refs/remotes/<name>/HEAD`.
   *This is what finally makes `cat-file -t HEAD` work.*
5. **Ref iteration.** Walk `refs/` and merge with `packed-refs`, loose winning,
   sorted by name.
6. **Identity and timestamps.** `GIT_COMMITTER_*`, then `user.name`/`user.email`,
   then a refusal that says what to set. Format `Name <email> <unix> <±hhmm>`.
   Phase 4 needs this for commits; the reflog needs it now.
7. **Reflog append.** `<old> <new> <ident>\t<message>\n`, with the tab and
   message omitted entirely when there is no message
   (`refs/files-backend.c:log_ref_write_fd`). Created automatically for
   `refs/heads/`, `refs/remotes/`, `refs/notes/` and HEAD unless the repository
   is bare (`refs.c:should_autocreate_reflog`), appended to otherwise only if
   the log already exists.
8. **Ref update.** `<ref>.lock` with `O_CREAT|O_EXCL`, verify the old value,
   write, `rename`. Deleting removes the loose file and rewrites `packed-refs`
   under its own lock.
9. **`update-ref`.** `<ref> <new> [<old>]`, `-d`, `-m`, `--stdin`, `-z`.
10. **`symbolic-ref`.** Read, write, `-d`, `--short`, `-q`.
11. **`for-each-ref`.** Patterns, `--count`, `--sort`, `--format`.
12. **`config`.** `list`, `get`, `set`, `unset`; `--local`, `--global`,
    `--file`, `--all`. Writing has to preserve the rest of the file — comments,
    indentation and all — so it is a line editor, not a re-serializer.

## The oracle procedure

Every ref gittle writes is read back by real git, and vice versa. The four
shapes that matter:

```sh
# gittle writes, git reads
gittle update-ref refs/heads/x $(git rev-parse HEAD)
git rev-parse refs/heads/x

# git writes, gittle reads -- including after `git gc` packs the refs
git update-ref refs/heads/y HEAD && git pack-refs --all
gittle for-each-ref

# git must not merely agree, it must be satisfied
git fsck --strict

# and the compare-and-swap has to actually swap
gittle update-ref refs/heads/x $new $wrong_old   # must fail, and change nothing
```

---

## Results

`tests/oracle.sh --full`, 80 checks across both phases, all passing.

| Check | Coverage |
|---|---|
| ref name validation | 22 names, every answer agreeing with `git check-ref-format --allow-onelevel` |
| `for-each-ref` | 8 option sets and 17 format strings, output identical to git's |
| `packed-refs` | refs read the same before and after `git pack-refs --all`, and a loose ref correctly shadows a packed one |
| `symbolic-ref` | read, write, `--short`, `-d`, `-q`; git reads back the symref gittle wrote and resolves it to the right object |
| `update-ref` | git reads what gittle wrote; the reflog line has git's exact shape; compare-and-swap fails and changes nothing; a nonexistent object and a tree-as-a-branch are both refused with git's own wording; `git fsck --strict` is clean afterwards |
| deletion | loose, packed, and the reflog with it; `fsck` clean after deleting a packed ref |
| HEAD dereference | `update-ref HEAD` moves the branch and leaves HEAD symbolic, and both reflogs record it |
| `update-ref --stdin` | a batch applies whole, a batch containing one failure leaves *nothing* behind, `verify` and `delete` work, and `-z` and `symref-update` parse |
| ref locking | a `.lock` left by another process stops the write instead of corrupting the ref |
| `config` set/unset | the resulting file is **byte-identical** to git's after nine operations, including subsections, quoting, and removing a section's last variable |
| `config` get/list | scopes, `--all`, and the exit statuses a script depends on (1 for unset, 5 for a refused multi-valued unset) |
| config parser | a hand-written file with comments, a subsection, a padded quoted value, an implicit boolean and a line continuation |
| glob engine | 27 cases covering `*` versus `**` in pathname mode, classes, ranges, negation, escaping and backtracking |

### Three things worth remembering

**The oracle was two years out of date.** The system `git` is 2.43.0 and could
not even parse `git config get`, which arrived in 2.46 — a whole subcommand
this phase implements. Building git from the reference tree fixed it, and
`tests/oracle.sh` now prefers `$REFREPO/git` automatically. It needed
`NO_RUST=1`: git 2.55 builds `libgitcore.a` with cargo, which the sandbox does
not have.

**An identity is resolved during `prepare`, not when the reflog is written.**
The first version wrote the ref, then discovered `user.email` was unset while
appending to the log — leaving the ref moved and the command reporting failure.
The identity is now demanded before anything is renamed, which is what makes
the transaction's promise true. It also surfaced a real gap: `Repository` was
never reading `~/.gitconfig` at all.

**A ref must name an object that exists.** `update-ref refs/heads/x
deadbeef…` is a well-formed object name, so nothing in the ref layer had
reason to reject it — and the result was a repository `git fsck` calls broken.
The check needs the object database, which `refs.nim` deliberately does not
depend on, so it arrives as a callback the way the identity does.

## The minimization pass

After both phases were passing, the code was reviewed against
`msgpack-coap-example.c`: twenty thousand lines of MessagePack and CoAP library
reduced to about a hundred, by writing code shaped like the bytes on the wire
rather than like the library's API, and by collapsing families of near-identical
cases into a table.

The line count went from 2,841 to 2,753 — but the reduction was about 125 lines,
because the same pass *added* 40 to `update-ref` by fixing what it found. That
is the real result: **six compatibility bugs, all in `update-ref --stdin`, all
of them things the documented grammar does not say.**

| What git actually does | What gittle did |
|---|---|
| `symref-update` **dereferences** — on a symbolic ref it rewrites what that ref points at, not the ref | rewrote the ref itself |
| `symref-delete` and `symref-verify` **require** a preceding `option no-deref` | accepted them without it |
| `start` with no `commit` **aborts** at end of input | committed |
| `start`, `prepare`, `commit` and `abort` each print `<verb>: ok` on stdout | printed nothing |
| An update to the null object ID is a **delete** | refused it as invalid |
| With `-z`, a *missing* old-value record is an error and an *empty* one means "unspecified"; without `-z` an empty one means "must not exist" | treated all three the same |

Every one of these was found the same way: by feeding an identical command
stream to git and to gittle and comparing exit status, stdout and the resulting
refs — not by re-reading the documentation. `tests/oracle.sh` now does that over
34 streams, which replaced five hand-written assertions that had agreed with a
misreading.

Two other defects fell out of the same review:

* **`ZlibError` was not a `GittleError`,** so a corrupt packfile would have
  produced a Nim traceback instead of `gittle: truncated zlib stream`. It is
  gone; `zlib.nim` uses the same `fail` as everything else.
* **`allRefs` was quadratic** — it kept the names it had seen in a `seq` and
  searched it linearly. Fine for ten refs, not for the ten thousand tags a
  large repository has.

What actually shrank, and why:

* **Three inflate loops became one** with two knobs (`limit`, `drain`). 55 lines
  to 30.
* **The repository extension gate became a table** of name, accepted value and
  refusal text. The nine-branch `case` is now a nine-line array and a six-line
  loop, and adding an extension git invents later is one row.
* **`update-ref`'s eight commands became a table** of what each takes and does.
  Reading the grammar no longer means reconstructing it from nested
  conditionals — and it is what made the `-z` record-counting bug visible.
* **`config.nim` scans lines once**, for both the reader and the writer. They
  had been two walks over the same syntax, which is exactly how a variable the
  reader sees and the writer misses turns into a silent duplicate.
* **`for-each-ref` implements `:short` once** per family of atom instead of four
  times, and the `%(…)` interpolation loop is shared with `cat-file --batch`.
* **`readRef` returns a `Ref`** whose empty name means "not found", rather than
  a `(found, Ref)` tuple.
* **11 exported symbols had no caller anywhere** and were deleted.

## Budget

```
                                    budgeted   actual
refs: loose + packed-refs                300      480   refs + refname
config: flat INI subset                  150      261   reader and writer, one scanner
pathspec + ignore (shared glob)          500       83   arrived early
support: sha1, zlib, paths, errors       400      219
object store                             800      473
extension gate + worktree config          60       28   now a table
command dispatch, arg parsing, 53 cmds  2,000      911   6 commands + driver
```

Two lines are over and one number is a warning.

**`refs` is 480 against 300.** The budget line said "loose + packed-refs" and
the phase delivered rather more: a two-phase transaction, lock files, reflog
writing, and the per-worktree path rule. Reflog writing has no budget line of
its own anywhere, and the transaction is what `fetch` and `receive-pack` are
defined in terms of, so phase 8 should get some of this back rather than
paying again.

**`config` is 261 against 150.** The budget line covered a parser. What is
there is a parser *and* a writer — a line editor rather than a serializer,
precisely so that `config set` does not destroy a hand-written file's comments
and layout — sharing a single pass over the lines.

**The command layer is 911 of 2,000 with 6 of 53 commands done.** plan.md says
to guard this number above all others, so: it is not yet a problem, but it is
not comfortable either. `update-ref` (240) and `for-each-ref` (231) are half of
it, and both are genuinely large — one implements a transaction language, the
other a format engine that git spends 3,000 lines on. Most of the remaining 47
commands are far smaller, but this is the number to watch in phase 4, where
`add`, `commit` and `log` all land at once.

Total: 2,753 lines of code (4,239 including comments) of the ~9,000 budgeted,
with phases 1 and 2 of 10 complete.

## Notes carried forward

- **`--merged`, `--no-merged`, `--contains`, `--no-contains`** on `for-each-ref`
  are in scope (docs/05) but need reachability, which needs the revision walk.
  They arrive in phase 6; until then they must fail with a message that says so
  rather than silently listing everything.
- **`pack-refs` is cut as a command** (docs/05) — `gc` packs refs internally in
  phase 10. gittle therefore *reads* `packed-refs` in this phase but only ever
  *rewrites* it to remove a ref.
- **Reflog is written here, read in phase 6.** The `reflog` command is phase 6,
  but the entries have to be written from the first ref update or every branch
  gittle touches has a hole in its history.

### Added during phase 2

- **`for-each-ref` implements the ref-shaped atoms only.** `%(refname)`,
  `%(objectname)`, `%(objecttype)`, `%(objectsize)`, `%(HEAD)`, `%(symref)`,
  `%(upstream)`, their `:short`/`:lstrip`/`:rstrip` modifiers, and the `*`
  dereference form. Dates, subjects, `%(align:)` and `%(if:)` need the revision
  walk and commit parsing; they are **refused by name**, so a caller gets "not
  implemented" rather than an empty column.
- **`--merged`, `--contains` and their negations refuse with a message naming
  phase 6**, rather than silently listing everything.
- **`option no-deref` in a `--stdin` stream is honored**, because git requires
  it before `symref-delete` and `symref-verify` and changes what every other
  command does. The `--no-deref` *command-line flag* stays out of scope
  (docs/10).
- **`config --system` is out of scope** (docs/11), so the merge is global,
  local, worktree, then `-c`. A single static binary with no install prefix has
  no system file to read.
- **Object names still resolve without `^`, `~` and `@{…}`.** Phase 2 added
  refs and the DWIM order, so `HEAD`, `main`, `v1.0` and `origin/main` all
  work; the ancestry operators arrive with the revision walk in phase 6.
