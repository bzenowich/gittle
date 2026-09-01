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

**Phases 1 and 2 complete: the object store, refs and config.** `cat-file`,
`hash-object`, `update-ref`, `symbolic-ref`, `for-each-ref` and `config` work
and agree with real git — all 420,113 objects in the repository next door read
back byte for byte, the loose objects gittle writes are byte-identical to
git's, and so is a config file after nine edits. `git fsck --strict` is clean
after everything gittle writes. Phase 3 — the index and trees — is next.

2,753 lines of the ~9,000 budgeted.

- [`docs/plan.md`](docs/plan.md) — goals, the eight design rules, scope,
  budget, the ten decisions, build order. **Read this first.**
- [`CLAUDE.md`](CLAUDE.md) — the short version: the rules that bind, the
  environment, and what finishing a phase requires.
- [`docs/phase-1.md`](docs/phase-1.md), [`docs/phase-2.md`](docs/phase-2.md) —
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
