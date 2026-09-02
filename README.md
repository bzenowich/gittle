# gittle

A minimal git in Nim: small enough to read in an afternoon, compatible enough to
share a repository with real git, and plausible in a busybox-class environment.

- **On-disk compatible.** A gittle repository *is* a git repository. Real git and
  gittle can operate on the same working tree, in any order.
- **ssh-only remotes**, speaking protocol v2 against an ordinary git server.
- **A transport client**, not a server: gittle clones from, fetches from and
  pushes to a git host, and does not host one.
- **One static binary**, busybox-style `argv[0]` dispatch. Only external
  dependency is the system zlib.
- **Small enough to read in an afternoon** — 11.7 kloc of Nim, every
  function documented.
- **Two runtime dependencies**: the system zlib, and `diff(1)` — the edit
  script comes from the `diff` every Unix has, gittle does the rest.

## Status

**v1 is feature-complete, and minimised.** 44 commands work and agree with
real git, checked by differential tests that compare not only output but
every ref, reflog, index entry, object and in-progress marker either tool
wrote. `gittle init`, `gittle add .`, `gittle commit` produces a repository
real git continues in without noticing; a merge gittle stopped is concluded
by `git commit`, and a cherry-pick git stopped is continued by `gittle
cherry-pick --continue`.

The scope is what an agent-driven daily loop uses, measured from real
tool-call logs (`docs/git-tool-calls-*.md`), plus `clone`, `fetch` and
`push` over one transport — a program with a pipe on each end — and the
plumbing that makes the rest testable from a shell. Ten plumbing wrappers
nothing called, and the options nothing used, came out in the minimisation
pass; [`docs/minimize.md`](docs/minimize.md) is the record of what was cut,
why, and what each cut cost.

Three design choices carry the code count:

- **Options are a table.** Every command declares its options as data —
  spelling, kind, help — and one parser in `cli.nim` reads them and writes
  the usage text.
- **The diff is `diff(1)`.** gittle asks the system `diff` for a minimal
  edit script and adds the context, the headers and the counts itself. The
  three-way merge that `merge`, `cherry-pick`, `rebase` and `stash` share
  is still gittle's own, byte-identical to git's over 400 random merges,
  conflict markers included.
- **`gc` is the server's job.** The remote runs full git, so `gittle gc` is
  a fetch with chosen haves: the server's `pack-objects` sends the
  repository's own history back as one properly deltified pack, and
  gittle deletes only what that pack now covers. It runs by hand, and on
  its own at the end of a push once `gc.auto` loose objects have piled up.

Three things are deliberately not git's: `diff` hunks may sit elsewhere than
git's on a few percent of files (both are correct patches), `status` prints
no `(use "git …")` hints, and `--date=relative` is gone. What a script reads
— `--short`, `--porcelain`, `--name-only`, `--numstat`, `--format` — is
byte-exact.

## Building

Nim 2.x, the system zlib, and a `diff` on `PATH` at run time (busybox's is
enough); no other dependency, and no package manager.

```sh
nim c -d:release --out:build/gittle src/gittle.nim            # links libz
nim c -d:release -d:static --out:build/gittle src/gittle.nim  # one static binary
tests/oracle.sh          # differential tests against real git, sampled
tests/oracle.sh --full   # ... over every object in the reference repository
```

The transport tests need `git-upload-pack` and `git-receive-pack` to be
findable by name, so they put the reference build on `PATH`; nothing else is
required, and no test contacts a network.

The tests prefer a `git` built from the reference checkout above this one over
whatever is on `PATH`, because the installed one may be years older than the
tree it is being asked to explain. They also pass git the options that select
the behavior gittle deliberately does not implement — `--no-renames`,
`--minimal`, `--diff-merges=off`, `--no-use-mailmap`, and
`--diff-algorithm=minimal` for `merge-file` — so that each divergence is
*tested* rather than merely absent. [`docs/phase-5.md`](docs/phase-5.md) and
[`docs/phase-7.md`](docs/phase-7.md) list them with the reasoning.

## Layout

```
docs/     scope inventory, plan, phase notes
src/      Nim sources
tests/    oracle scripts against real git
```
