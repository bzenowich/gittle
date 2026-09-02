# gittle

A minimal git in Nim: small enough to read in an afternoon, compatible enough to
share a repository with real git, and plausible in a busybox-class environment.

- **On-disk compatible.** A gittle repository *is* a git repository. Real git and
  gittle can operate on the same working tree, in any order.
- **ssh-only remotes**, speaking protocol v2 against an ordinary git server.
- **Client and server.** Ships `upload-pack`, `receive-pack`, and `git-shell`.
- **One static binary**, busybox-style `argv[0]` dispatch. Only external
  dependency is the system zlib.
- **Target: ~9 kloc.**

## Status

**Phases 1–6 complete: the object store, refs and config, the index and
trees, the first commit, diff, and history.** Thirty commands work and agree
with real git. `gittle init`, `gittle add .`, `gittle commit` produces a
repository real git continues in without noticing — identical commit objects,
reflogs and index — and `gittle log` reproduces git's output over 20,000
commits of the repository next door. `git fsck --strict` is clean after
everything gittle writes.

The diff engine is a reimplementation of git's `xdiff/` in the configuration
`--minimal` selects, including the indent heuristic that decides where a hunk
sits: **every file pair of 900 real commits comes out hunk for hunk identical**.
`diff`, `status` in all four output formats, and `grep` are in, `log -p` and
`show` print their patches, and `commit` prints its diffstat.

Phase 6 added the revision grammar — `HEAD~3`, `v1.0^{}`, `A..B`, `HEAD@{2}`,
`:0:file` — and with it `rev-list`, `rev-parse`, `merge-base`, `branch`,
`tag`, `reflog`, and the four commands that are the first to *change* tracked
files: `checkout`, `switch`, `restore` and `reset`. `rev-list --topo-order`
reproduces git's choice of topological order over the reference repository,
and every mutating command is tested by running it in two copies of a
repository and comparing every ref, reflog, config line, index entry and file
either tool wrote.

`grep` and `log --grep` use libc's POSIX regex rather than a vendored engine —
which is what git itself does, and what turned a 500-line budget line into 45.

8,960 lines of the ~9,000 budgeted — which is the whole budget with four
phases to go. [`docs/phase-6.md`](docs/phase-6.md) has the numbers and a
revised estimate.

- [`docs/plan.md`](docs/plan.md) — goals, the eight design rules, scope,
  budget, the ten decisions, build order. **Read this first.**
- [`CLAUDE.md`](CLAUDE.md) — the short version: the rules that bind, the
  environment, and what finishing a phase requires.
- [`docs/phase-1.md`](docs/phase-1.md), [`docs/phase-2.md`](docs/phase-2.md),
  [`docs/phase-3.md`](docs/phase-3.md), [`docs/phase-4.md`](docs/phase-4.md),
  [`docs/phase-5.md`](docs/phase-5.md), [`docs/phase-6.md`](docs/phase-6.md) —
  the finished phases: what was built, what it was verified against, what was
  left for later, and where the budget stands.
- [`docs/README.md`](docs/README.md) — index to the feature inventory
  (`01`–`15`), where every git command and option is marked in or out of scope.

## Building

Nim 2.x and the system zlib; no other dependency, and no package manager.

```sh
nim c -d:release --out:build/gittle src/gittle.nim            # links libz
nim c -d:release -d:static --out:build/gittle src/gittle.nim  # one static binary
tests/oracle.sh          # differential tests against real git, sampled
tests/oracle.sh --full   # ... over every object in the reference repository
```

The tests prefer a `git` built from the reference checkout above this one over
whatever is on `PATH`, because the installed one may be years older than the
tree it is being asked to explain. They also pass git the four options that
select the behavior gittle deliberately does not implement — `--no-renames`,
`--minimal`, `--diff-merges=off` and `--no-use-mailmap` — so that each
divergence is *tested* rather than merely absent. [`docs/phase-5.md`](docs/phase-5.md)
lists them with the reasoning.

## Layout

```
docs/     scope inventory, plan, phase notes
src/      Nim sources
tests/    oracle scripts against real git
```
