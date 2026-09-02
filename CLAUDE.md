# gittle — working notes for an agent session

A minimal git in Nim. **Read [`docs/plan.md`](docs/plan.md) first** — goals,
the design rules, the scope cuts, the budget, and the build order. Then the
current phase document in `docs/`.

**v1 is feature-complete and minimised (2026-09-02).** 44 commands,
11,724 lines of code, every function documented, `tests/oracle.sh` green.
[`docs/minimize.md`](docs/minimize.md) is the record of the minimisation
pass: what was cut, why, and what it cost. What is next is the v2 backlog in
plan.md §8 and the leftovers in minimize.md §9 -- not more scope.

This file is the short version of what a fresh session needs to know before
touching anything.

## The rules that bind

`plan.md` §3 has all eight with their reasoning. The four that get violated
first, by anyone, in every phase:

- **R1 — Read liberally, write byte-exactly.** Object IDs are hashes of exact
  bytes. A header formatted slightly differently is a different object and a
  silently forked repository.
- **R4 — One of everything.** One hash, one ref backend, one diff algorithm,
  one transport. When a second is tempting, it is scope, not a refactor.
- **R7 — Write the wire, not the API.** Implement the bytes, not the shape of
  git's interfaces. A family of cases that differs only in constants is a
  table. Do not build what you immediately consume.
  [`docs/msgpack-coap-example.c`](docs/msgpack-coap-example.c) is the worked
  example.
- **R8 — The oracle decides, not the documentation.** Settle behavior by
  running the same input through git and through gittle and diffing exit
  status, stdout, and the state on disk.

## Environment

| | |
|---|---|
| Oracle binary | `../git` — **built from the reference tree**, matching the checkout it reads. Prefer it over `git` on `PATH`, which may be years older. `tests/oracle.sh` already does. |
| Rebuilding it | `make -j8 NO_GETTEXT=1 NO_TCLTK=1 NO_OPENSSL=1 NO_CURL=1 NO_EXPAT=1 NO_RUST=1` — `NO_RUST` matters, git 2.55 wants cargo otherwise. |
| Reference source | `../` — the git checkout this repository sits inside. Cite files and functions from it in comments; that is what makes a decision checkable later. |
| libgit2, for reference | `../libgit2` |
| Build | `nim c -d:release --out:build/gittle src/gittle.nim`; add `-d:static` for the single static binary. `nimble` cannot write `~/.nimble` here, so use `nim c` directly. |
| Test | `tests/oracle.sh`, or `--full` to sweep every object in the reference repository and every commit and tag in it (~4 min). Needs bash, not just a POSIX shell. |
| Comparing `log` | git applies `.mailmap` to `log` and `show` by **default** (`log.mailmap`, true since 2.34) and gittle does not — 18,512 of the reference repository's 82,130 commits display a different identity. Pass `--no-use-mailmap` to git or you are diffing that and nothing else. |
| Comparing a diff | The engine is `diff(1)` (`docs/minimize.md` §5), so hunks may sit elsewhere than git's: compare a patch by **applying it**, and compare `--numstat` counts, which a minimal script fixes. The oracle's engine test does exactly that. For the headers, four cuts still apply: `--no-renames`, `--minimal`, `--diff-merges=off` (note `show` defaults to `--cc`), and `-c diff.cpp.xfuncname=...` on the reference repository. |
| Comparing a **merge** | The same kind again: git's merge asks its diff for the default algorithm and gittle only has `--minimal`, so `merge-file` gets `--diff-algorithm=minimal` and `merge` would get `-Xdiff-algorithm=minimal`. |
| Comparing a **rename** | And again, from the other side: gittle detects none, so git's `status` says `renamed:` where gittle says a delete and an add. `status.renames=false` goes in the *fixture*, so both copies read the same file — `mv` is the one command that makes a rename on purpose. |
| Comparing `gc` | gittle's `gc` is a fetch from the remote with chosen haves (`docs/minimize.md` §3.4): it needs a remote, packs only pushed history, and never prunes. Compare what a later command reads, that the pushed history's loose objects are gone, that unpushed ones are not, and `git fsck --strict` after. |
| Testing a command that **writes** | Comparing stdout is not enough: a `checkout` that prints the right thing and leaves the wrong index is the failure worth catching. `oracle.sh`'s `p6mut` runs the command in two identical copies of a fixture and compares every ref, HEAD, the config, every reflog, every working-tree file, the whole index, **every in-progress marker** (`MERGE_HEAD`, `rebase-merge/…`) and **each tool's own `status` and `branch`** (`p6own`). Nine of phase 6's eleven bugs and four of phase 7's were found in those comparisons and not in the output. |
| Testing a command that writes **under `.git`** | `p6state` looks at refs, reflogs, config, the index and the working tree — and `worktree` writes almost nothing there. `p10` compares both repositories *whole*, contents included, skipping only the packfiles and the index. It is also why `p6state` prints a `.git` **file**'s content rather than its hash: a linked worktree's holds an absolute path, so two copies differ for no reason but their own names. |
| Testing a command that **resumes** | `$GITX` inside a `PREP` is the tool under test in that copy, so `PREP='$GITX cherry-pick topic' p6mut cherry-pick --continue` asks gittle to continue a state gittle created. Continuing git's state with git's tool proves nothing about interoperability; the two states being interchangeable is the claim. |
| Testing a command that **talks to a remote** | `p8mut` keeps **two servers as well as two clients** — a bare copy of the source per tool, each client pointed at its own — and compares all four afterwards. A push that prints the right thing and leaves the wrong ref on the far side is caught by the far side and nowhere else. The tests need `$REFREPO` on `PATH` so that `git-upload-pack` and `git-receive-pack` resolve; `oracle.sh` puts it there. |
| Reaching a remote at all | One transport: **a program with a pipe on each end**. `ssh host "git-upload-pack '<path>'"` and `git-upload-pack <path>` are the same thing with a prefix, so `clone file:///path` exercises every line of the protocol with no server and no network. A local path is *not* an object-store copy — plan.md §6, "A local path is not a second transport". |
| Naming, hints | gittle says `gittle` where git says `git`; git prints `hint:` paragraphs and `(use "git …")` status advice that gittle does not. The oracle normalises the name away and drops hint lines (`p6norm`), and compares `status` against `git -c advice.statusHints=false`. |
| Adding an option | A row in the command's `options` table (`src/cli.nim` says how); the usage text comes from the row. Refuse a cut option with an `okRefused` row rather than ignoring it. |

## Documentation

Comments do not count against the line budget, and a goal of the project is
that the result is *readable* — a minimal git someone can learn from. So:

- Every module opens with what the thing **is**, what its on-disk or on-wire
  format looks like, and **why** it is built the way it is.
- Every non-obvious proc says what it does and what it is defending against.
- Prefer explaining the format over explaining the code. A reader who
  understands the packfile header does not need the loop narrated.
- Cite the git source when a behavior is not obvious
  (`refs.c:check_refname_format`), and say when gittle deliberately differs.

## Finishing a phase

None of these is optional; `plan.md` §7 has the detail.

1. `tests/oracle.sh --full` passes, with the new commands **enumerated**
   against git rather than spot-checked.
2. A minimization pass over the phase's code against R7.
3. The budget recorded in the phase document against `plan.md` §5, with
   over-runs explained.
4. What was left undone written down, with the phase it belongs to.

## Watch this number

`plan.md` §5 is **a measurement, not a limit** — that was settled after phase 6,
along with cutting the server. Do not cram to hit a figure, and do not let it
drift unremarked either: record the line count at the end of every phase and
explain the over-runs. §5.1–§5.4 have the running total; the final figure is
**13,872 for v1**, 60% over the original 8,680 sketch.

Across four phases the sketch missed for four different reasons, and **none of
them is option surface, which is what §5 models**: phase 6 *shared output
formatting* (it belongs to no one command), phase 7 *state machines* (a
directory of files to write, read back and remove correctly), phase 8
*compatibility surface* (rules reproduced because someone else's output
already defines them), phase 10 *a second copy of the repository abstraction*
(a linked worktree is a `Repository` with a different `gitDir`). Those four
are the list to argue with before adding a fifth.

An optimisation and refactoring pass is planned once v1 is feature-complete, so
prefer the clear version now over the clever one.

**The server is cut** (plan.md §6 decision 2): no `upload-pack`, no
`receive-pack`, no `git-shell`, and phase 9 is empty. gittle is a transport
client. `index-pack`'s validation still matters — a *fetch* takes a packfile
from the other end too — and it is now built: pack checksum, every object's
own hash, then connectivity, and no ref moves until all three pass
(`docs/phase-8.md`).

**Phase 10 was the last phase, and the minimisation pass came after it.** `gc`, `worktree`, `clean`,
`check-ignore`, `mv`, `rm` and `stage` — no new engine, every one of them a
command over something an earlier phase built. Two rules worth carrying
forward: **`clean -x` means "there are no ignore files"**, not "delete ignored
files too" (read the other way, `clean -fdx -e '*.log'` deletes the logs it
was told to keep), and **`gc` is additive** — R2a, tested by packing with git,
committing with gittle, running `gittle gc` and asserting the inherited pack
is still there.

One invariant now runs through four commands: **a branch is checked out in at
most one worktree.** `worktree add`, `checkout`, `switch` and `branch` all
ask `checkedOutAt` (`src/worktrees.nim`); a fifth command that moves a branch
has to ask it too.
