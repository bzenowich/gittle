## `clean` -- delete what is in the working tree and in no tree at all.
##
## In scope (docs/06): `<pathspec>…`, `-d`, `-f`/`--force`, `-n`/`--dry-run`,
## `-q`/`--quiet`, `-e <pattern>`/`--exclude=<pattern>`, `-x`, `-X`.  `-i` is
## cut with every other interactive engine (plan.md R6).
##
## ## The whole command is one decision: collapse, or descend
##
## Finding untracked files is [dir.nim](../dir.nim)'s job and was built in
## phase 4.  What `clean` adds is that it reports and removes *directories*,
## and therefore has to decide, per directory, whether to name it once or to
## name the files inside it.  git calls that `DIR_SHOW_OTHER_DIRECTORIES` and
## `correct_untracked_entries`; the rule is:
##
## > A directory collapses to one entry when everything below it is going to
## > be deleted anyway.  Anything below it that must survive -- a tracked
## > file, or an ignored one that `-x` was not given for -- forces the walk
## > to descend and name the deletable files one by one.
##
## Get it wrong in one direction and `clean -fd` removes a directory holding
## `node_modules`; wrong in the other and it leaves empty directories behind.
##
## `-x` and `-X` do not select a third and fourth kind of path.  There is one
## exclude list -- the `-e` patterns, plus the standard ignore files unless
## `-x` said to leave them out -- and the two flags say which side of it to
## delete:
##
## | | the exclude list is | deletable | a directory collapses when |
## |---|---|---|---|
## | (default) | `-e` + the ignore files | untracked, not excluded | nothing tracked or excluded below |
## | `-x` | `-e` only | untracked, not excluded | nothing tracked or excluded below |
## | `-X` | `-e` + the ignore files | untracked *and* excluded | everything below is excluded |
##
## Reading `-x` as "delete ignored files too" rather than "there are no
## ignore files" gets `clean -x -e '*.log'` wrong: the `-e` pattern still has
## to protect the files it names.
##
## ## Two rules that are not about ignore files
##
## * **A pathspec implies `-d`.**  `clean -f sub/` recurses into untracked
##   directories under `sub/`, because naming a path is the same statement
##   `-d` makes (`builtin/clean.c`, `if (argc) remove_directories = 1`).
## * **A nested repository is skipped**, and reported, unless `-ff`.  Someone
##   else's history is not this command's to throw away.

import std/[algorithm, os, strutils]
import ../cli, ../ignore, ../index, ../pathspec, ../repository, ../util

const usageText = """usage: gittle clean [-d] [-f] [-n] [-q] [-e <pattern>] [-x | -X] [--] [<pathspec>…]

   -d              recurse into untracked directories
   -f, --force     actually delete; required unless clean.requireForce is false
   -n, --dry-run   report what would be deleted
   -q, --quiet     report only errors
   -e <pattern>    add an exclude pattern
   -x              delete ignored files too
   -X              delete only ignored files"""

type
  Entry = object
    path: string     ## root-relative; a directory carries a trailing `/`
    isDir: bool

  Cleaner = object
    repo: Repository
    idx: Index
    ig: Ignore
    ps: Pathspec
    ignoredOnly: bool ## `-X`: delete what the exclude list names, and only that
    dirs: bool       ## `-d`, or a pathspec, which means the same thing
    keepNested: bool ## a nested repository is someone else's; `-ff` overrides

proc anyTrackedUnder(cl: Cleaner, dir: string): bool =
  ## Is anything below this directory in the index?  The entries are sorted by
  ## path, so the first one that could be under `dir/` settles it.
  var lo = 0
  var hi = cl.idx.entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if cl.idx.entries[mid].path < dir: lo = mid + 1 else: hi = mid
  lo < cl.idx.entries.len and cl.idx.entries[lo].path.startsWith(dir)

proc isNestedRepo(full: string): bool =
  fileExists(full / ".git") or dirExists(full / ".git")

proc children(full: string): seq[string] =
  ## The names in a directory, sorted.  Both walks here are in path order --
  ## the scan because git reports in it, and the removal because a failure
  ## report has to name the files it did remove in the same order.
  for _, path in walkDir(full, relative = true, checkDir = false):
    result.add path
  sort(result)

proc scan(cl: Cleaner, dir: string, found: var seq[Entry]):
    tuple[keep, excluded: bool] =
  ## Everything deletable under `dir` ("" or ending in `/`), and what was
  ## found below it that is not.  The two flags are the collapse decision:
  ## the caller uses them to choose between the entries this returned and one
  ## entry naming `dir` itself.  `keep` means something below must survive
  ## whatever the mode; `excluded` means something below matched the exclude
  ## list, which is a reason to survive in one mode and to go in the other.
  for name in children(cl.repo.workTree / dir):
    if dir.len == 0 and name == ".git": continue
    let rel = dir & name
    let full = cl.repo.workTree / rel
    let isDir = dirExists(full) and not symlinkExists(full)

    if not isDir:
      if cl.idx.isTracked(rel): (result.keep = true; continue)
      let ex = cl.ig.isIgnored(rel, false)
      if ex: result.excluded = true
      if ex != cl.ignoredOnly:
        # Not deletable in this mode.  Under `-X` that is a reason the
        # directory cannot go as one unit; in the other modes it is recorded
        # as `excluded` instead, because whether it blocks the collapse
        # depends on `-d` -- see the collapse rule below.
        if cl.ignoredOnly: result.keep = true
        continue
      if cl.ps.matches(rel): found.add Entry(path: rel)
      else: result.keep = true            # a pathspec spared it, so it stays
      continue

    if cl.keepNested and isNestedRepo(full):
      # Not listed at all: `dir.c`'s DIR_SKIP_NESTED_GIT.  It does *not* stop
      # an ancestor from collapsing -- the removal walk meets it again and
      # reports it there ("Skipping repository"), which is the only place the
      # user is told about it.
      continue

    if cl.ig.isIgnored(rel, true):
      # An excluded directory is never entered, whichever way round the modes
      # are -- which is the rule the ignore engine is built around: a `!`
      # inside it could not be reached, so it cannot re-include anything
      # (plan.md §4).
      result.excluded = true
      if not cl.ignoredOnly: continue
      if cl.ps.matches(rel): found.add Entry(path: rel & "/", isDir: true)
      else: result.keep = true
      continue
    if not cl.ps.mightMatchDir(rel): (result.keep = true; continue)

    var sub: seq[Entry]
    let below = cl.scan(rel & "/", sub)
    if below.keep: result.keep = true
    if below.excluded: result.excluded = true
    # Collapse only when the whole directory goes, and only when the
    # directory itself is what the pathspec named.  Under `-X` "the whole
    # directory" means everything below it was excluded; otherwise it means
    # nothing below it was.  Without `-d` the exclude half does not apply:
    # git does not even collect ignored paths then, and the collapsed entry
    # is about to be skipped anyway.
    let collapses = not below.keep and not cl.anyTrackedUnder(rel & "/") and
                    (cl.ignoredOnly or not cl.dirs or not below.excluded) and
                    cl.ps.matches(rel)
    if collapses: found.add Entry(path: rel & "/", isDir: true)
    else:
      result.keep = true
      found.add sub

proc removeTree(cl: Cleaner, rel: string, dryRun, quiet: bool,
                errors: var int): bool =
  ## Delete a directory and everything in it, reporting what it could not.
  ##
  ## `builtin/clean.c:remove_dirs`, and the reporting is the interesting half:
  ## when the directory goes entirely, only the directory is named, and when
  ## something inside it survives, every file that *was* removed is named
  ## instead.  Returns whether the directory is gone.
  let full = cl.repo.workTree / rel
  if cl.keepNested and isNestedRepo(full):
    if not quiet:
      echo (if dryRun: "Would skip repository " else: "Skipping repository ") &
           relativeTo(rel, cl.ps.prefix)
    return false

  result = true
  var removed: seq[string]
  for name in children(full):
    let child = rel & "/" & name
    let childFull = full / name
    if dirExists(childFull) and not symlinkExists(childFull):
      if cl.removeTree(child, dryRun, quiet, errors):
        # No trailing slash here, unlike the entry the caller printed: git
        # builds these names from the walk and that one from the directory
        # lister, and only the lister adds one.
        removed.add relativeTo(child, cl.ps.prefix)
      else: result = false
    elif dryRun or tryRemoveFile(childFull):
      removed.add relativeTo(child, cl.ps.prefix)
    else:
      stderr.write "warning: failed to remove " &
                   relativeTo(child, cl.ps.prefix) & "\n"
      inc errors
      result = false

  if result:
    # Refusing to remove the directory the command was run in is git's rule,
    # and it is a kindness: the shell would be left in a directory that is no
    # longer there.
    if (try: sameFile(full, getCurrentDir()) except OSError: false):
      echo (if dryRun: "Would refuse to remove current working directory"
            else: "Refusing to remove current working directory")
      result = false
    elif dryRun: discard
    else:
      try: removeDir(full)
      except OSError:
        stderr.write "warning: failed to remove " &
                     relativeTo(rel, cl.ps.prefix) & "/\n"
        inc errors
        result = false
  if not result and not quiet:
    for p in removed:
      echo (if dryRun: "Would remove " else: "Removing ") & p

proc cmdClean*(c: Ctx, argv: seq[string]): int =
  var args = expandShortOptions(argv, {'e'})
  var force = 0
  var dryRun, quiet, dirs, alsoIgnored, ignoredOnly = false
  var excludes, specs: seq[string]
  var i = 0
  var noMoreOpts = false
  optionValue(args, i)
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-': specs.add a
    elif a == "--": noMoreOpts = true
    elif a == "-n" or a == "--dry-run": dryRun = true
    elif a == "-q" or a == "--quiet": quiet = true
    elif a == "-f" or a == "--force": inc force
    elif a == "-d": dirs = true
    elif a == "-x": alsoIgnored = true
    elif a == "-X": ignoredOnly = true
    elif a == "-e" or a.startsWith("--exclude"): excludes.add valueFor(a)
    elif a == "-h" or a == "--help": (echo usageText; return 0)
    elif a == "-i" or a == "--interactive":
      fail("interactive cleaning is cut from v1 (plan.md R6)")
    else: fail("unknown option '" & a & "'\n" & usageText)
    inc i

  failIf(alsoIgnored and ignoredOnly,
         "options '-x' and '-X' cannot be used together")

  let repo = c.repo
  failIf(repo.workTree.len == 0, "this operation must be run in a work tree")
  failIf(repo.cfg.getBool("clean.requireForce", true) and force == 0 and
         not dryRun,
         "clean.requireForce is true and -f not given: refusing to clean")

  # `-x` is "there are no ignore files", not "delete ignored files too": the
  # `-e` patterns are a separate, higher-precedence list and survive it.
  var cl = Cleaner(
    repo: repo, idx: readIndex(repo.indexPath),
    ig: (if alsoIgnored: newEmptyIgnore(repo) else: newIgnore(repo)),
    ps: parsePathspec(specs, repo.prefix, implicitPrefix = true),
    ignoredOnly: ignoredOnly,
    # Naming a path says the same thing `-d` says.
    dirs: dirs or specs.len > 0,
    keepNested: force < 2)
  cl.ig.addCommandLinePatterns(excludes)

  var found: seq[Entry]
  discard cl.scan("", found)

  var errors = 0
  for e in found:
    if e.isDir and not cl.dirs: continue
    let shown = relativeTo(e.path, cl.ps.prefix)
    if e.isDir:
      let gone = cl.removeTree(e.path[0 ..< e.path.len - 1], dryRun, quiet,
                               errors)
      if gone and not quiet:
        echo (if dryRun: "Would remove " else: "Removing ") & shown
    elif dryRun or tryRemoveFile(repo.workTree / e.path):
      if not quiet: echo (if dryRun: "Would remove " else: "Removing ") & shown
    else:
      stderr.write "warning: failed to remove " & shown & "\n"
      inc errors
  if errors != 0: 1 else: 0
