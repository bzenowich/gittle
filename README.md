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

**Phases 1–4 complete: the object store, refs and config, the index and
trees, and the first commit.** Seventeen commands work and agree with real
git. `gittle init`, `gittle add .`, `gittle commit` produces a repository real
git continues in without noticing — identical commit objects, reflogs and
index — and `gittle log` reproduces git's output over 20,000 commits of the
repository next door across 37 format, date and option combinations, with
path limiting and history simplification. `gittle show` agrees on all 1,008
tags in it. `git fsck --strict` is clean after everything gittle writes.

The `.gitignore` and pathspec engines are in, so `add` refuses build output
and `ls-files -o --exclude-standard` works. Phase 5 — diff, `status` and
`grep` — is next; until then `commit` prints no diffstat and `show` no patch.

5,087 lines of the ~9,000 budgeted.

- [`docs/plan.md`](docs/plan.md) — goals, the eight design rules, scope,
  budget, the ten decisions, build order. **Read this first.**
- [`CLAUDE.md`](CLAUDE.md) — the short version: the rules that bind, the
  environment, and what finishing a phase requires.
- [`docs/phase-1.md`](docs/phase-1.md), [`docs/phase-2.md`](docs/phase-2.md),
  [`docs/phase-3.md`](docs/phase-3.md), [`docs/phase-4.md`](docs/phase-4.md) —
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
tree it is being asked to explain.

## Layout

```
docs/     scope inventory, plan, phase notes
src/      Nim sources
tests/    oracle scripts against real git
```
