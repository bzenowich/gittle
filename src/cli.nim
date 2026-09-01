## What the `git` driver options set up, and the repository they name.
##
## Every command receives a `Ctx`: the directory to act as though we started
## in (`-C`), an explicit git directory or work tree if one was given, and any
## `-c name=value` overrides.
##
## The repository itself is opened **lazily**, on first use, and that is a
## deliberate choice rather than a micro-optimisation.  Opening it runs
## repository discovery and the extension gate, either of which can fail --
## and several commands must work where that would: `hash-object` without `-w`
## hashes a file that need not be in a repository at all, `config --global`
## edits a file outside any repository, and `version` must never go looking for
## one.  A command that genuinely needs a repository simply touches `c.repo`
## and gets the error for free.

import config, repository, util

type
  Ctx* = ref object
    startDir*: string
    gitDirOpt*, workTreeOpt*: string
    bare*: bool
    overrides*: Config
    cached: Repository

proc repo*(c: Ctx): Repository =
  if c.cached == nil:
    c.cached = openRepository(c.gitDirOpt, c.workTreeOpt, c.startDir,
                              c.bare, c.overrides)
  c.cached

proc usage*(msg: string) {.noreturn.} =
  fail(msg)
