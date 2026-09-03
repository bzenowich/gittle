## `status` -- report working tree state.
##
## Argument parsing over `status.nim`, which does the work.  The only decision
## made here is which format was asked for, and the rule is not quite the
## obvious one: `-z` **implies porcelain v1** rather than merely changing the
## terminator, because a NUL-terminated long format would be meaningless.

import ../cli, ../color, ../index, ../pathspec, ../repository, ../status,
       ../util


const
  synopsis = "[<options>] [--] [<pathspec>…]"
  options = [
    opt("-s|--short", help = "the two-column short format"),
    opt("--long", help = "the descriptive format (the default)"),
    opt("--porcelain", okOptValue, arg = "[=<version>]", help = "the stable machine format, v1 or v2"),
    opt("-b|--branch", help = "include branch information"),
    opt("-z", help = "NUL-terminate records (implies --porcelain=v1)"),
    opt("-u|--untracked-files", okOptValue, arg = "[<mode>]", help = "no, normal (default) or all"),
    opt("--color", okOptValue, arg = "[=<when>]", help = "colour the long format: always, never or auto"),
    opt("--no-color"),
    opt("--ignored|--ignore-submodules|--column|--no-column|--ahead-behind|--no-ahead-behind|" &
        "--renames|--no-renames|--find-renames|--show-stash|-v|--verbose", okRefused, help = "docs/08"),
  ]

proc cmdStatus*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, compute the status, print it in the format asked.
  let o = parse(options, args, "status", synopsis)
  var fmt = sfLong
  var nulTerm = false
  var untracked = umNormal
  var color = isTty()   # git's `color.ui=auto`; `--color`/`--no-color` below can override
  for (k, v) in o.occurrences:        # the last format given wins, as in git
    case k
    of "short": fmt = sfShort
    of "long": fmt = sfLong
    of "z":
      nulTerm = true
      if fmt == sfLong: fmt = sfPorcelainV1
    of "porcelain":
      fmt = case (if v.len == 0: "1" else: v)
        of "1", "v1": sfPorcelainV1
        of "2", "v2": sfPorcelainV2
        else: fail("unsupported porcelain version '" & v & "'")
    of "untracked-files":
      untracked = case v
        of "", "normal": umNormal
        of "no": umNo
        of "all": umAll
        else: fail("invalid untracked files mode '" & v & "'")
    of "no-color": color = false
    of "color": color = resolveColor(v)
    else: discard
  let branch = o.has "branch"
  let specs = o.args
  let repo = c.repo
  failIf(repo.workTree.len == 0,
         "this operation must be run in a work tree")
  let ps = parsePathspec(specs, repo.prefix)
  let idx = readIndex(repo.indexPath)
  let st = computeStatus(repo, idx, ps, untracked)

  # Paths are printed relative to the directory the command was run in, unless
  # `status.relativePaths` says otherwise -- or unless the format is porcelain
  # v1, whose whole promise is that its output does not depend on where you
  # stood.  Which is the whole of the difference between v1 and `-s`, so it is
  # said here and the renderer never asks again.
  let relative = repo.cfg.getBool("status.relativePaths", true) and
                 fmt != sfPorcelainV1
  stdout.write renderStatus(st, fmt, untracked,
                            (if relative: repo.prefix else: ""), branch,
                            nulTerm, color)
  stdout.flushFile()
  0
