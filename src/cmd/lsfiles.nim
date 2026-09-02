## `ls-files` -- list index and working-tree files.
##
## In scope: `<file>`, `-c`, `-s`, `-o`, `-u`, `--exclude-standard`,
## `--error-unmatch`, `-z`, `--`.  docs/minimize.md §3 trims `-d`, `-m`, `-k`
## and `-i` -- the working-tree comparisons `status` already makes, and which
## never appeared in the logs it surveyed.  They are refused by name.
##
## ## One pass over the index, then the untracked walk
##
## The cached pass prints in index order, which is git's structure
## (`builtin/ls-files.c:show_files`); `-o` follows it with the walk `status`
## and `add` share, so the untracked files come after the tracked ones.
##
## ## The paths are relative to where you are standing
##
## `git ls-files` in a subdirectory lists that subdirectory's files, named
## relative to it -- and a `:(top)` pathspec that reaches outside prints
## `../abspath.c`.  Both come from the pathspec layer, which is why the local
## matcher this command used in phase 3 is gone.

import ../cli, ../dir, ../ignore, ../index, ../pathspec, ../repository, ../util


const
  synopsis = "[-c] [-s] [-o] [-u] [--exclude-standard] [--error-unmatch] [-z] [--] [<file>…]"
  options = [
    opt("-c|--cached", help = "tracked files (the default)"),
    opt("-s|--stage", help = "mode, object ID and stage beside each name"),
    opt("-o|--others", help = "untracked files"),
    opt("-u|--unmerged", help = "unmerged entries only"),
    opt("--exclude-standard", help = "with -o, leave ignored files out"),
    opt("--error-unmatch", help = "exit 1 when a named path is not tracked"),
    opt("-z", help = "NUL after each name, and no quoting"),
    opt("-d|--deleted|-m|--modified|-k|--killed|-i|--ignored", okRefused, help = "docs/minimize.md §3"),
    opt("--directory|--deduplicate|--resolve-undo|--sparse|--recurse-submodules", okRefused, help = "docs/09"),
  ]

proc cmdLsFiles*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then the cached pass over the index and, under
  ## `-o`, the walk for untracked files.
  let o = parse(options, args, "ls-files", synopsis)
  var showCached = o.has "cached"
  var showStage = o.has "stage"
  let showOthers = o.has "others"
  let showUnmerged = o.has "unmerged"
  let excludeStandard = o.has "exclude-standard"
  let errorUnmatch = o.has "error-unmatch"
  let nulTerminated = o.has "z"
  let specs = o.args
  if showUnmerged: showStage = true
  # With no selector at all, `-c` is the default.
  if not (showCached or showStage or showOthers): showCached = true

  let repo = c.repo
  let ps = parsePathspec(specs, repo.prefix, implicitPrefix = true)
  let idx = readIndex(repo.indexPath)
  var matched: seq[string]

  proc emit(shown: string) =
    ## One name as an output field: `util.pathField` holds the `-z` rule.
    stdout.write pathField(shown, nulTerminated)

  if showCached or showStage:
    for e in idx.entries:
      if not ps.matches(e.path): continue
      if showUnmerged and e.stage == 0: continue
      # `--error-unmatch` is satisfied by the cached pass alone, which is
      # where git records a pathspec as matched (`show_ce`).
      matched.add e.path
      if showStage:
        stdout.write formatMode(e.mode), " ", $e.oid, " ", $e.stage, "\t"
      emit ps.displayPath(e.path)

  if showOthers and repo.workTree.len > 0:
    # Without `--exclude-standard` nothing is excluded, which is the plumbing
    # default: `ls-files -o` alone lists build output too, and callers that
    # want the porcelain answer say so.
    let ig = if excludeStandard: newIgnore(repo) else: nil
    for path in walkWorkTree(repo, idx, ig, ps, {wwUntracked}):
      emit ps.displayPath(path)

  # `--error-unmatch` is a status code, not a fatal error: git prints the
  # complaint and exits 1, where a `fail` here would exit 128.
  if errorUnmatch:
    let missed = ps.firstUnmatched(matched)
    if missed.len > 0:
      stdout.flushFile()
      stderr.write "error: pathspec '" & missed &
                   "' did not match any file(s) known to git\n"
      return 1
  stdout.flushFile()
  0
