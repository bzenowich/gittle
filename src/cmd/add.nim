## `add` -- stage content into the index.
##
## In scope (docs/06): `<pathspec>…`, `-n`/`--dry-run`, `-v`/`--verbose`,
## `-f`/`--force`, `-u`/`--update`, `-A`/`--all`, `--`.  Everything cut from
## `add` is one of two things: an interactive engine (`-p`, `-i`, `-e`) or a
## gitattributes one (`--renormalize`, `--chmod`), and R6 says neither earns a
## subsystem.
##
## ## It is two passes, not one
##
## Over the same pathspec:
##
## 1. **The index pass** re-stages every entry already tracked, and *records
##    the removal* of one whose file has gone.  Ignore rules are not consulted:
##    they apply to untracked paths only, and a tracked file stays tracked
##    whatever a `.gitignore` says.
## 2. **The walk pass** finds untracked files, with `.git` and every ignored
##    directory pruned.
##
## Plain `gittle add <pathspec>` does both.  Since git 2.0 that includes
## removals, so it is exactly `-A` restricted to the pathspec; `-u` is pass one
## alone, and `-A` is both with the pathspec defaulting to the whole tree.
##
## ## Naming an ignored path is an error, not a skip
##
## A path a wildcard merely reached is skipped silently -- that is what the
## ignore rules are for.  A path typed out in full is a statement of intent, so
## git lists them and refuses with status **1**, and nothing is staged.  gittle
## does the same, including checking before it writes anything: a partial
## `add` that then failed would be worse than either outcome.

import std/[algorithm, os, posix, strutils]
import ../cli, ../dir, ../ignore, ../index, ../pathspec, ../repository, ../util

const usageText = """usage: gittle add [-n] [-v] [-f] [-u] [-A] [--] <pathspec>…"""

proc cmdAdd*(c: Ctx, argv: seq[string]): int =
  let args = expandShortOptions(argv, {})
  var dryRun = false
  var verbose = false
  var force = false
  var updateOnly = false
  var addAll = false
  var specs: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-':
      specs.add a
    elif a == "--": noMoreOpts = true
    elif a == "-n" or a == "--dry-run": dryRun = true
    elif a == "-v" or a == "--verbose": verbose = true
    elif a == "-f" or a == "--force": force = true
    elif a == "-u" or a == "--update": updateOnly = true
    elif a == "-A" or a == "--all" or a == "--no-ignore-removal": addAll = true
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["-p", "--patch", "-i", "--interactive", "-e", "--edit"]:
      fail(a & " is not implemented in this version\n" &
           "  interactive and hunk-level staging are cut from v1 (plan.md R6)")
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  failIf(updateOnly and addAll, "-u and -A are incompatible")

  let repo = c.repo
  failIf(repo.workTree.len == 0, "add is not possible in a bare repository")

  if specs.len == 0 and not (updateOnly or addAll):
    # git treats this as a mistake worth naming but not worth failing over.
    echo "Nothing specified, nothing added."
    stderr.write "hint: Maybe you wanted to say 'gittle add .'?\n"
    return 0

  let ps = parsePathspec(specs, repo.prefix)
  let idx = readIndex(repo.indexPath)
  let ig = newIgnore(repo)

  # Refuse before staging anything.  A path only a wildcard reached is skipped;
  # one written out in full is reported.
  var refused: seq[string]
  if not force:
    for p in ps.literalPaths:
      if fileExists(repo.workTreePath(p)) or dirExists(repo.workTreePath(p)):
        if pathIsIgnored(repo, idx, ig, p): refused.add p
  if refused.len > 0:
    sort(refused)
    stderr.write "The following paths are ignored by one of your " &
                 ".gitignore files:\n"
    for p in refused: stderr.write p & "\n"
    stderr.write "hint: Use -f if you really want to add them.\n"
    return 1

  var staged: seq[string]     # what to report under -n/-v
  var removed: seq[string]
  var touched: seq[string]    # every path any pathspec item matched

  # Pass 1: the index.  Iterating a copy of the paths because staging mutates
  # the entry list underneath us.
  var tracked: seq[string]
  for e in idx.entries:
    if e.stage == 0 and ps.matches(e.path): tracked.add e.path
  for path in tracked:
    touched.add path
    let (ok, st) = statPath(repo.workTreePath(path))
    if not ok or S_ISDIR(st.st_mode):
      removed.add path
      if not dryRun: discard idx.removePath(path)
    else:
      let before = idx.find(path)
      let oidBefore = idx.entries[before].oid
      if dryRun:
        # Report only a real change: a dry run that lists every tracked file
        # tells the user nothing.
        if not idx.entries[before].statMatches(st): staged.add path
      else:
        discard stageWorkingPath(repo, idx, path)
        if idx.entries[idx.find(path)].oid != oidBefore: staged.add path

  # Pass 2: the walk.  `-u` is defined as not doing this.
  if not updateOnly:
    for path in walkWorkTree(repo, idx, ig, ps,
                             if force: {wwUntracked, wwIgnored} else: {wwUntracked}):
      # The walk yields a nested repository as `name/`.  git would stage a
      # 160000 gitlink; submodules are cut (plan.md §4), and writing one would
      # produce a repository gittle could not then read -- so it is reported
      # and skipped.  `touched` still counts it, so a pathspec that matched
      # only this is not also reported as matching nothing.
      touched.add path
      if path.endsWith("/"):
        stderr.write "warning: '" & path & "' contains a repository; " &
                     "gittle does not support submodules and is skipping it\n"
        continue
      staged.add path
      if not dryRun: discard stageWorkingPath(repo, idx, path)

  # Every item must have matched something; git makes this fatal rather than a
  # warning, because a typo in a path is nearly always a mistake worth stopping
  # for.
  let missed = ps.firstUnmatched(touched)
  failIf(missed.len > 0, "pathspec '" & missed & "' did not match any files")

  if verbose or dryRun:
    sort(staged)
    sort(removed)
    for p in staged: echo "add '" & p & "'"
    for p in removed: echo "remove '" & p & "'"

  if not dryRun and (staged.len > 0 or removed.len > 0): idx.writeIndex()
  0
