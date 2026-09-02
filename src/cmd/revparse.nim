## `rev-parse` -- the revision grammar, exposed.
##
## Two commands share a name here, and it helps to see them apart:
##
## * **an object-name calculator.** Every argument that resolves is printed as
##   a 40-digit ID, excluded ones prefixed `^`; `--verify` demands exactly one;
##   `--symbolic-full-name` and `--abbrev-ref` print the *ref* instead.
## * **a repository-layout oracle.** `--git-dir`, `--show-toplevel` and the
##   three `--is-…` predicates, which is how every shell script written
##   against git finds its bearings.
##
## In scope: `--verify`, `-q`, `--short[=<n>]`, `--symbolic-full-name`,
## `--abbrev-ref[=strict|loose]`, `--git-dir`, `--show-toplevel`, the three
## `--is-…` predicates, revisions and `--`.  docs/minimize.md §3 trims
## `--show-cdup`, `--show-prefix`, `--git-path` and `--sq`, none of which
## appeared in the logs it surveyed; they are refused by name, because the
## echo-back rule below would otherwise print them as if they were answers.
##
## ## Everything it does not understand, it echoes
##
## An argument that starts with `-` and is not an option `rev-parse` knows is
## printed back unchanged, and one that resolves to nothing is printed and
## *then* diagnosed.  That is not sloppiness: `rev-parse` exists to be run by
## a script over its own argument list, sorting flags from revisions from
## paths, so passing the unrecognised through is the job
## (`builtin/rev-parse.c:show_file`).

import std/[os, strutils]
import ../cli, ../oid, ../refs, ../repository, ../revision, ../util

const usageText = """usage: gittle rev-parse [<options>] <args>…

   --verify                  require exactly one argument naming one object
   -q, --quiet               with --verify, fail silently
   --short[=<n>]             abbreviate the printed object names
   --symbolic-full-name      print full ref names, skipping non-refs
   --abbrev-ref[=strict|loose]  print the shortest unambiguous ref name
   --git-dir                 the repository directory
   --show-toplevel           the working tree root
   --is-inside-git-dir, --is-inside-work-tree, --is-bare-repository"""

proc cmdRevParse*(c: Ctx, args: seq[string]): int =
  ## Entry point: a streaming interpreter over the arguments, printing
  ## each as it goes, since `--short` and friends change how the rest
  ## render.
  var verify, quiet, symbolic, abbrevRef, strictRef, asIs = false
  var shortLen = 0
  # Pre-scanned, not noticed as it goes by: a `--` anywhere makes an earlier
  # unresolvable argument a hard error rather than a filename, because the
  # user has already said where the paths begin.
  let sawDashDash = "--" in args
  let cwd = getCurrentDir()
  let insideGitDir = cwd == c.repo.gitDir or cwd.startsWith(c.repo.gitDir & "/")
  var verified: seq[RevPoint]

  proc emit(p: RevPoint) =
    ## One resolved point.  `--symbolic-full-name` and `--abbrev-ref` print
    ## the ref the argument named and print *nothing at all* when it named no
    ## ref, so that a script can filter refs out of a mixed list.
    var text = ""
    if (symbolic or abbrevRef) and p.name.len > 0:
      let d = c.repo.refs.dwimRef(p.name)
      if not d.found: return
      text = if abbrevRef: c.repo.refs.shortenRef(d.full, strictRef) else: d.full
    elif symbolic or abbrevRef:
      return
    elif shortLen > 0:
      text = c.repo.uniqueAbbrev(p.oid, shortLen)
    else:
      text = $p.oid
    echo (if p.uninteresting: "^" else: "") & text

  for arg in args:
    if asIs:
      echo arg
      if not sawDashDash: failAmbiguous(c.repo, arg)
      continue
    if arg == "--":
      asIs = true
      echo "--"
      continue

    if arg == "-h" or arg == "--help":
      echo usageText
      return 0

    # The layout queries: each answers and moves on, so `rev-parse --git-dir
    # --show-toplevel` prints two lines in that order.
    var layout = true
    case arg
    of "--git-dir":
      # Relative when the repository sits under the directory we are standing
      # in -- `.git` at the top, `.` when standing inside it -- and absolute
      # otherwise, which is what a script that will `cd` elsewhere needs.
      let gd = c.repo.gitDir
      echo (if gd == cwd: "."
            elif gd.startsWith(cwd & "/"): gd[cwd.len + 1 .. ^1]
            else: gd)
    of "--show-toplevel":
      failIf(c.repo.workTree.len == 0, "this operation must be run in a work tree")
      echo c.repo.workTree
    of "--is-inside-git-dir": echo insideGitDir
    of "--is-inside-work-tree": echo c.repo.workTree.len > 0 and not insideGitDir
    of "--is-bare-repository": echo c.repo.bare
    of "--verify": verify = true
    of "-q", "--quiet": quiet = true
    of "--symbolic-full-name": symbolic = true
    of "--symbolic":
      fail("--symbolic is out of scope for gittle v1 (docs/09); " &
           "use --symbolic-full-name")
    of "--show-cdup", "--show-prefix", "--git-path", "--sq":
      fail(arg & " is out of scope for gittle (docs/minimize.md §3)")
    else:
      layout = false

    if layout: continue
    if arg.startsWith("--short"):
      # `--short` implies `--verify`: an abbreviation is only meaningful for
      # one object, so git refuses to print several (`builtin/rev-parse.c`).
      verify = true
      shortLen = if arg.contains('='): parseInt(arg[arg.find('=') + 1 .. ^1])
                 else: c.repo.autoAbbrev
      shortLen = clamp(shortLen, minAbbrev, OidHexLen)
      continue
    if arg.startsWith("--abbrev-ref"):
      # git's default here is *strict*, not loose: `abbrev_ref_strict` is
      # initialised from `warn_ambiguous_refs`, which `core.warnAmbiguousRefs`
      # leaves true (`builtin/rev-parse.c`).  So with both a branch and a tag
      # named `dup`, `--abbrev-ref refs/tags/dup` prints `tags/dup` -- the
      # shortest name that still resolves to the ref asked about.
      #
      # This must be defaulted here and not in `refs.shortenRef`, whose loose
      # default is what `branch`, `worktree` and `status` listings want, as
      # git's do.
      abbrevRef = true
      strictRef = not arg.endsWith("=loose")
      continue

    if arg.len > 1 and arg[0] == '-':
      echo arg                      # an option we do not know: pass it through
      if verify: (if quiet: return 1 else: fail("Needed a single revision"))
      continue

    var points: seq[RevPoint]
    if c.repo.addRevArg(arg, false, points):
      # Under `--verify` a single plain revision is held back and printed at
      # the end, because whether it *is* single is not known until then.
      if verify and points.len == 1: verified.add points[0]
      else:
        for p in points: emit p
      continue

    if verify: (if quiet: return 1 else: fail("Needed a single revision"))
    failIf(sawDashDash, "bad revision '" & arg & "'")
    asIs = true
    echo arg
    failAmbiguous(c.repo, arg)

  if verify:
    if verified.len != 1:
      if quiet: return 1
      fail("Needed a single revision")
    emit verified[0]
  0
