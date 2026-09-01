## `ls-files` -- list index and working-tree files.
##
## In scope (docs/09): `<file>`, `-c`, `-s`, `-d`, `-m`, `-o`, `-i`, `-u`,
## `--exclude-standard`, `--error-unmatch`, `-z`, `--`.
##
## ## One pass, up to three emissions per entry
##
## `-c -m -d` is not three passes and is not deduplicated: a file that is
## cached, deleted *and* modified is printed three times, interleaved with the
## other entries in index order.  That is git's structure (`show_files`), and
## copying it is why `ls-files -c -m` repeats a modified file the way git's does.
##
## ## The paths are relative to where you are standing
##
## `git ls-files` in a subdirectory lists that subdirectory's files, named
## relative to it -- and a `:(top)` pathspec that reaches outside prints
## `../abspath.c`.  Both come from the pathspec layer, which is why the local
## matcher this command used in phase 3 is gone.

import std/posix
import ../cli, ../dir, ../ignore, ../index, ../pathspec, ../repository, ../util

const usageText = """usage: gittle ls-files [-c] [-s] [-d] [-m] [-o] [-i] [-u]
                       [--exclude-standard] [--error-unmatch] [-z] [--] [<file>…]"""

proc cmdLsFiles*(c: Ctx, args: seq[string]): int =
  var showCached = false
  var showStage = false
  var showDeleted = false
  var showModified = false
  var showOthers = false
  var showIgnored = false
  var showUnmerged = false
  var excludeStandard = false
  var errorUnmatch = false
  var nulTerminated = false
  var specs: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-':
      specs.add a
    elif a == "--": noMoreOpts = true
    elif a == "-c" or a == "--cached": showCached = true
    elif a == "-s" or a == "--stage": showStage = true
    elif a == "-d" or a == "--deleted": showDeleted = true
    elif a == "-m" or a == "--modified": showModified = true
    elif a == "-o" or a == "--others": showOthers = true
    elif a == "-i" or a == "--ignored": showIgnored = true
    elif a == "-u" or a == "--unmerged": showUnmerged = true
    elif a == "--exclude-standard": excludeStandard = true
    elif a == "--error-unmatch": errorUnmatch = true
    elif a == "-z": nulTerminated = true
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["--directory", "-k", "--killed", "--deduplicate",
               "--resolve-undo", "--sparse", "--recurse-submodules"]:
      fail(a & " is out of scope for gittle v1 (docs/09)")
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  # `-u` implies `-s`: there is no point showing unmerged entries without the
  # stage numbers that distinguish them (`builtin/ls-files.c:709`).
  if showUnmerged: showStage = true
  # `-i` is a filter, not a selector, so it needs something to filter.
  failIf(showIgnored and not (showOthers or showCached or showStage),
         "ls-files -i must be used with either -o or -c")
  # With no selector at all, `-c` is the default.
  if not (showCached or showStage or showDeleted or showModified or showOthers):
    showCached = true

  let repo = c.repo
  let ps = parsePathspec(specs, repo.prefix, implicitPrefix = true)
  let idx = readIndex(repo.indexPath)
  let terminator = if nulTerminated: '\0' else: '\n'
  var matched: seq[string]

  proc emit(e: IndexEntry) =
    if showStage:
      stdout.write formatMode(e.mode), " ", $e.oid, " ", $e.stage, "\t"
    let shown = ps.displayPath(e.path)
    stdout.write(if nulTerminated: shown else: quotePath(shown))
    stdout.write terminator

  proc isModified(e: IndexEntry, st: Stat): bool =
    ## `read-cache.c:ie_modified`.  A changed mode or type settles it at once;
    ## so does a size that differs from a *recorded* size.  Only when the stat
    ## is inconclusive -- which includes a racily-clean entry, whose recorded
    ## size was deliberately zeroed -- is the content read and hashed.
    if e.mode != modeForFile(st): return true
    if e.statMatches(st): return false
    if e.size != 0 and e.size != uint32(st.st_size): return true
    hashObject(otBlob, readWorkingFile(repo.workTreePath(e.path), st)) != e.oid

  let ig = if excludeStandard: newIgnore(repo) else: nil

  proc trackedIsIgnored(path: string): bool =
    ## `-i` over tracked files asks a question the walk cannot: ignore rules
    ## normally do not apply to a tracked path at all, and `-i -c` exists
    ## precisely to find the files where someone has ignored one anyway.
    ig != nil and ig.isIgnored(path, false)

  for e in idx.entries:
    if not ps.matches(e.path): continue
    if showIgnored and not trackedIsIgnored(e.path): continue

    if (showCached or showStage) and (not showUnmerged or e.stage != 0):
      # Only the cached pass satisfies `--error-unmatch`: git records a
      # pathspec as matched inside `show_ce`, which the deleted and modified
      # passes do not reach.  So `ls-files --error-unmatch -m <path>` fails for
      # a path that exists but is not modified.
      matched.add e.path
      emit(e)
    if not (showDeleted or showModified): continue
    if e.skipWorktree: continue

    let (ok, st) = statPath(repo.workTreePath(e.path))
    if not ok and showDeleted: emit(e)
    if showModified and (not ok or isModified(e, st)): emit(e)

  if showOthers and repo.workTree.len > 0:
    # Without `--exclude-standard` nothing is excluded, which is the plumbing
    # default: `ls-files -o` alone lists build output too, and callers that
    # want the porcelain answer say so.
    for path in walkWorkTree(repo, idx, ig, ps,
                             if showIgnored: {wwIgnored} else: {wwUntracked}):
      let shown = ps.displayPath(path)
      stdout.write(if nulTerminated: shown else: quotePath(shown))
      stdout.write terminator

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
