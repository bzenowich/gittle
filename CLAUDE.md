# gittle — working notes for an agent session

A minimal git in Nim. **Read [`docs/plan.md`](docs/plan.md) first** — goals,
the design rules, the scope cuts, the budget, and the build order. Then the
current phase document in `docs/`.

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
| Comparing a diff | Four more of the same kind, all deliberate cuts (`docs/phase-5.md`): `--no-renames` (gittle detects none), `--minimal` (gittle's Myers always is), `--diff-merges=off` (combined diffs are cut — note `show` defaults to `--cc` where `log` does not), and, on the reference repository only, `-c diff.cpp.xfuncname=...` because its `.gitattributes` sets `diff=cpp` and a userdiff driver changes the name on a `@@` line. `tests/oracle.sh` has all four as `$NOREN`, `$NOCC` and `$NOATTR`. |
| Comparing a **merge** | The same kind again: git's merge asks its diff for the default algorithm and gittle only has `--minimal`, so `merge-file` gets `--diff-algorithm=minimal` and `merge` would get `-Xdiff-algorithm=minimal`. |
| Testing a command that **writes** | Comparing stdout is not enough: a `checkout` that prints the right thing and leaves the wrong index is the failure worth catching. `oracle.sh`'s `p6mut` runs the command in two identical copies of a fixture and compares every ref, HEAD, the config, every reflog, every working-tree file, the whole index, **every in-progress marker** (`MERGE_HEAD`, `rebase-merge/…`) and **each tool's own `status` and `branch`** (`p6own`). Nine of phase 6's eleven bugs and four of phase 7's were found in those comparisons and not in the output. |
| Testing a command that **resumes** | `$GITX` inside a `PREP` is the tool under test in that copy, so `PREP='$GITX cherry-pick topic' p6mut cherry-pick --continue` asks gittle to continue a state gittle created. Continuing git's state with git's tool proves nothing about interoperability; the two states being interchangeable is the claim. |
| Naming | gittle says `gittle` where git says `git`, in messages and in hints. The oracle normalises that away (`p6norm`) rather than testing it. |

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
explain the over-runs. §5.1 and §5.2 have the running total (10,756 after phase 7,
~13,000 projected for v1) and the reason the command layer costs what it
does — which after phase 7 is *state machines*, not option surface.

An optimisation and refactoring pass is planned once v1 is feature-complete, so
prefer the clear version now over the clever one.

**The server is cut** (plan.md §6 decision 2): no `upload-pack`, no
`receive-pack`, no `git-shell`, and phase 9 is empty. gittle is a transport
client. `index-pack`'s validation still matters — a *fetch* takes a packfile
from the other end too.
