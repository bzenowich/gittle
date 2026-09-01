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

**Phase 1 complete: the object store.** `hash-object` and `cat-file` work and
agree with real git. All 420,113 objects in the git repository next door read
back byte for byte, and the loose objects gittle writes are byte-identical to
git's. Phase 2 — refs and config — is next.

1,390 lines of the ~9,000 budgeted.

- [`docs/plan.md`](docs/plan.md) — goals, design rules, scope, budget, the ten
  decisions, build order. **Read this first.**
- [`docs/phase-1.md`](docs/phase-1.md) — the finished phase: what was built,
  what it was verified against, and what was left for later.
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

## Layout

```
docs/     scope inventory, plan, phase notes
src/      Nim sources
tests/    oracle scripts against real git
```
