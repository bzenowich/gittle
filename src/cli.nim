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

import std/strutils
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

proc expandShortOptions*(args: openArray[string], withValue: set[char]): seq[string] =
  ## Split bundled short options so the command's own parser never has to.
  ##
  ## `-am msg` becomes `-a -m msg`, `-nv` becomes `-n -v`, and `-mfoo` becomes
  ## `-m foo` -- a flag in `withValue` takes the rest of its cluster as the
  ## value, which is the rule that makes those three spellings one thing.
  ##
  ## Nothing after `--` is touched, and neither is a bare `-`, which is a file
  ## name meaning standard input.  Commands with a `-<number>` option (`log`)
  ## do not use this, because `-5` is not a bundle of five flags.
  var done = false
  for a in args:
    if done or a.len < 2 or a[0] != '-' or a[1] == '-':
      result.add a
      if a == "--": done = true
      continue
    for k in 1 ..< a.len:
      result.add "-" & a[k]
      if a[k] in withValue:
        if k + 1 < a.len: result.add a[k + 1 .. ^1]
        break

template optionValue*(argv, idx: untyped): untyped =
  ## Define `valueFor`, the option-argument reader every command needs.
  ##
  ## git accepts three spellings and a command has to take all of them:
  ## `--opt=value`, `--opt value`, and -- for an option whose argument is
  ## *optional* -- nothing at all, in which case a default applies and the
  ## next argument must be left alone because it is another option.  That
  ## last rule is why `branch --contains` and `branch --contains v1` both
  ## work, and it is easy to write nine slightly different ways.
  ##
  ## A template, because it has to advance the caller's own index: the value
  ## and the loop position are the same state, and separating them is exactly
  ## how a parser comes to consume one argument twice.
  proc valueFor(a: string, dflt = ""): string {.used.} =
    let eq = a.find('=')
    if eq > 0: return a[eq + 1 .. ^1]
    if idx + 1 < argv.len and (dflt.len == 0 or argv[idx + 1][0] != '-'):
      inc idx
      return argv[idx]
    failIf(dflt.len == 0, "option '" & a & "' requires a value")
    dflt
