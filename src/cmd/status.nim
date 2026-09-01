## `status` -- report working tree state.
##
## Argument parsing over `status.nim`, which does the work.  The only decision
## made here is which format was asked for, and the rule is not quite the
## obvious one: `-z` **implies porcelain v1** rather than merely changing the
## terminator, because a NUL-terminated long format would be meaningless.

import std/strutils
import ../cli, ../index, ../pathspec, ../repository, ../status, ../util

const usageText = """usage: gittle status [<options>] [--] [<pathspec>…]

   -s, --short               the two-column short format
   --long                    the descriptive format (the default)
   --porcelain[=<version>]   the stable machine format, v1 or v2
   -b, --branch              include branch information
   -z                        NUL-terminate records (implies --porcelain=v1)
   -u[<mode>], --untracked-files[=<mode>]   no, normal (default) or all"""

const deferred = [
  ("--ignored", "docs/08"), ("--ignore-submodules", "docs/08"),
  ("--column", "docs/08"), ("--no-column", "docs/08"),
  ("--ahead-behind", "docs/08"), ("--no-ahead-behind", "docs/08"),
  ("--renames", "docs/08"), ("--no-renames", "docs/08"),
  ("--find-renames", "docs/08"), ("--show-stash", "docs/08"),
  ("-v", "docs/08"), ("--verbose", "docs/08")]
  ## Refused by name rather than ignored: a `status --ignored` that printed
  ## the ordinary listing would look like an answer.

proc cmdStatus*(c: Ctx, args: seq[string]): int =
  var fmt = sfLong
  var branch = false
  var nulTerm = false
  var untracked = umNormal
  var specs: seq[string]
  var i = 0
  var seenDashDash = false

  proc valueFor(a: string): string =
    let eq = a.find('=')
    if eq > 0: return a[eq + 1 .. ^1]
    inc i
    failIf(i >= args.len, "option '" & a & "' requires a value")
    args[i]

  proc setUntracked(mode: string) =
    untracked = case mode
      of "", "normal": umNormal
      of "no": umNo
      of "all": umAll
      else: fail("invalid untracked files mode '" & mode & "'")

  while i < args.len:
    let a = args[i]
    if seenDashDash: specs.add a
    elif a == "--": seenDashDash = true
    elif a.len > 1 and a[0] == '-':
      let name = if a.contains('='): a[0 ..< a.find('=')] else: a
      for (n, where) in deferred:
        failIf(n == name, a & " is out of scope for gittle v1 (" & where & ")")
      if a == "-s" or a == "--short": fmt = sfShort
      elif a == "--long": fmt = sfLong
      elif a == "-b" or a == "--branch": branch = true
      elif a == "-z":
        nulTerm = true
        if fmt == sfLong: fmt = sfPorcelainV1
      elif a == "--porcelain" or a.startsWith("--porcelain="):
        let v = if a.contains('='): a[a.find('=') + 1 .. ^1] else: "1"
        fmt = case v
          of "1", "v1": sfPorcelainV1
          of "2", "v2": sfPorcelainV2
          else: fail("unsupported porcelain version '" & v & "'")
      elif a == "-u": setUntracked("")
      elif a.startsWith("-u"): setUntracked(a[2 .. ^1])
      elif a.startsWith("--untracked-files"):
        setUntracked(if a.contains('='): a[a.find('=') + 1 .. ^1] else: "")
      elif a == "-h" or a == "--help":
        echo usageText
        return 0
      else: fail("unknown option '" & a & "'\n" & usageText)
    else: specs.add a
    inc i

  let repo = c.repo
  failIf(repo.workTree.len == 0,
         "this operation must be run in a work tree")
  let ps = parsePathspec(specs, repo.prefix)
  let idx = readIndex(repo.indexPath)
  let st = computeStatus(repo, idx, ps, untracked)

  # Paths are printed relative to the directory the command was run in, unless
  # `status.relativePaths` says otherwise -- or unless the format is porcelain
  # v1, whose whole promise is that its output does not depend on where you
  # stood.
  let relative = repo.cfg.getBool("status.relativePaths", true)
  let prefix = if relative: repo.prefix else: ""
  if fmt == sfLong:
    # Hints are on unless `advice.statusHints` turns them off -- the one advice
    # key gittle reads, because without it the long format's shape changes.
    let hints = repo.cfg.getBool("advice.statusHints", true)
    stdout.write longStatus(st, untracked, hints, prefix)
  else:
    stdout.write shortLines(st, fmt, branch, nulTerm,
                            relative and fmt != sfPorcelainV1, repo.prefix)
  stdout.flushFile()
  0
