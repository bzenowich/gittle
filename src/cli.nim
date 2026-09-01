## What the `git` driver options set up, and the repository they name.
##
## The repository is opened lazily: `hash-object` without `-w` works outside a
## repository, and `version` must never look for one.

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
