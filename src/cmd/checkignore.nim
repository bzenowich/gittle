## `check-ignore` -- why is this path ignored, and by what?
##
## In scope (docs/13): `<pathname>…`, `-q`/`--quiet`, `-v`/`--verbose`.
## `--stdin`, `-z`, `-n`/`--non-matching` and `--no-index` are cut.
##
## The engine is [ignore.nim](../ignore.nim), built in phase 4 and used by
## `add`, `status` and `ls-files` ever since; this command is the one that
## *shows its working*, so it is the only caller that needs the deciding
## pattern rather than a yes or no.
##
## ## Three rules that are easy to get wrong
##
## * **A tracked path is never ignored.**  git tests the pathspec against the
##   *index*, not the exact name, so `check-ignore build` reports nothing when
##   `build/keep.txt` is tracked (`builtin/check-ignore.c`, the `seen` array).
## * **Without `-v`, a negated pattern is not a match.**  `!keep.log` decides
##   the path -- it is why the path is *not* ignored -- so `-v` prints it, and
##   the plain form must not, or the exit status would say "ignored".
## * **The exit status is the answer**: 0 when at least one path is ignored,
##   1 when none is.  That is backwards from every other command, and it is
##   what makes `check-ignore -q <path>` usable in an `if`.

import std/os
import ../cli, ../ignore, ../index, ../pathspec, ../repository, ../util

const
  synopsis = "[-q] [-v] <pathname>…"
  options = [
    opt("-q|--quiet", help = "say nothing; the exit status is the answer"),
    opt("-v|--verbose", help = "print the pattern that decided, and where it came from"),
    opt("--stdin|-z|-n|--non-matching|--no-index", okRefused, help = "docs/13"),
  ]

proc cmdCheckIgnore*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then ask the ignore engine about each path and
  ## report the deciding pattern under `-v`.
  let o = parse(options, args, "check-ignore", synopsis)
  let quiet = o.has "quiet"
  let verbose = o.has "verbose"
  let names = o.args
  failIf(names.len == 0, "no path specified")
  failIf(quiet and names.len > 1, "--quiet is only valid with a single pathname")
  failIf(quiet and verbose, "cannot have both --quiet and --verbose")

  let repo = c.repo
  failIf(repo.workTree.len == 0,
         "This operation must be run in a work tree")
  let idx = readIndex(repo.indexPath)
  let ig = newIgnore(repo)

  var ignored = 0
  for name in names:
    # Each argument is its own pathspec, because the output quotes the
    # argument back and the answer is per argument.
    let ps = parsePathspec([name], repo.prefix)
    var tracked = false
    for e in idx.entries:
      if ps.matches(e.path):
        tracked = true
        break
    var d: Decision
    if not tracked:
      let path = inPrefix(name, repo.prefix)
      d = ig.decide(path, dirExists(repo.workTreePath(path)))
      # A `!pat` decided the path, and what it decided is "not ignored".  The
      # plain form must not report it: the exit status is a count of ignored
      # paths, and `-v` is the only caller that wants the reasoning.
      if not verbose and d.found and not d.ignored: d.found = false
    if d.found:
      inc ignored
      if not quiet:
        if verbose: echo d.src & ":" & $d.lineNo & ":" & d.text & "\t" & name
        else: echo name
  if ignored > 0: 0 else: 1
