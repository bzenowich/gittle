## `config` -- read and write configuration.
##
## In scope (docs/11): the `list`, `get`, `set` and `unset` subcommands;
## `--local`, `--global`, `--file`; `--all`.
##
## ## Scopes
##
## git reads several files and merges them, later ones winning: system, then
## global (`~/.gitconfig`, or `$XDG_CONFIG_HOME/git/config`), then the
## repository's own `.git/config`, then per-worktree, then `-c` on the command
## line.  `--system` is out of scope for v1 -- a single static binary with no
## install prefix has no system file to speak of -- so gittle merges global,
## local, worktree and `-c`.
##
## Reading with no scope named uses that merged view.  *Writing* always needs
## exactly one file, and defaults to the repository's, which is why `set`
## without a scope can never touch a user's `~/.gitconfig` by accident.
##
## ## Exit status
##
## `get` exits 1 when the key is not set -- that is the whole point of the
## command in a shell script -- and `unset` exits 5 when it refuses to guess
## which of several values to remove.  Both match git.

import std/[os, strutils]
import ../cli, ../config, ../repository, ../util


type
  Scope = enum
    scDefault  ## merged for reading; the repository's file for writing
    scLocal
    scGlobal
    scFile

proc writeTarget(c: Ctx, scope: Scope, file: string): string =
  ## The file a `set` or `unset` edits under this scope.
  case scope
  of scFile: file
  of scGlobal: globalConfigPath()
  of scLocal, scDefault: c.repo.commonDir / "config"

proc readConfigFor(c: Ctx, scope: Scope, file: string): Config =
  ## The configuration a `get` or `list` reads under this scope.
  case scope
  of scFile: loadConfig(file)
  of scGlobal: loadConfig(globalConfigPath())
  of scLocal: loadConfig(c.repo.commonDir / "config")
  of scDefault: c.repo.cfg   # already merged, including any -c overrides

const
  synopsis = "list [--local | --global | --file <file>]\nget [--all] [<scope>] <key>\nset [<scope>] <key> <value>\nunset [--all] [<scope>] <key>"
  options = [
    opt("--local", help = "the repository's own file"),
    opt("--global", help = "the user's file"),
    opt("-f|--file", okValue, arg = "<file>", help = "a named file"),
    opt("--all", help = "every value of a multi-valued key"),
  ]

proc cmdConfig*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse the scope options, then the sub-verb.
  let o = parse(options, args, "config", synopsis)
  var scope = scDefault
  var file = ""
  for (k, v) in o.occurrences:      # the last scope given wins
    case k
    of "local": scope = scLocal
    of "global": scope = scGlobal
    of "file": (scope = scFile; file = v)
    else: discard
  let all = o.has "all"
  let rest = o.args
  failIf(rest.len == 0, o.use)
  let sub = rest[0]
  let rem = rest[1 .. ^1]

  case sub
  of "list":
    failIf(rem.len != 0, o.use)
    for e in readConfigFor(c, scope, file).entries:
      # A variable written with no `=` is an implicit true.  git lists it as a
      # bare key rather than `key=true`, which is how a reader tells "present"
      # apart from "set to the string true".
      if e.isBool: echo e.key
      else: echo e.key & "=" & e.value
    return 0

  of "get":
    failIf(rem.len != 1, o.use)
    let cfg = readConfigFor(c, scope, file)
    let key = rem[0].toLowerAscii
    var values: seq[string]
    for e in cfg.entries:
      if e.key.toLowerAscii == key: values.add e.value
    if values.len == 0: return 1          # unset: the script's "no"
    if all:
      for v in values: echo v
    else:
      echo values[^1]                     # last one wins, as everywhere else
    return 0

  of "set":
    failIf(rem.len != 2, o.use)
    setConfigValue(writeTarget(c, scope, file), rem[0], rem[1])
    return 0

  of "unset":
    failIf(rem.len != 1, o.use)
    let path = writeTarget(c, scope, file)
    var removed = 0
    try:
      removed = unsetConfigValue(path, rem[0], all)
    except GittleError as e:
      # git warns and exits 5 rather than failing outright, so a script can
      # tell "refused to guess" apart from "no such key".
      stderr.write "warning: " & e.msg & "\n"
      return 5
    return if removed > 0: 0 else: 5

  else:
    fail("unknown subcommand '" & sub & "'\n" & o.use)
