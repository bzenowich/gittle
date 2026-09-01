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

**Scoping complete. No code yet.** Phase 1 has not started.

- [`docs/plan.md`](docs/plan.md) — goals, design rules, scope, budget, the ten
  decisions, build order. **Read this first.**
- [`docs/phase-1.md`](docs/phase-1.md) — the current phase: task list,
  environment, and how to verify against real git.
- [`docs/README.md`](docs/README.md) — index to the feature inventory
  (`01`–`15`), where every git command and option is marked in or out of scope.

## Layout

```
docs/     scope inventory, plan, phase notes
src/      Nim sources                     (not yet created)
tests/    oracle scripts against real git (not yet created)
```
