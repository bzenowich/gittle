## `ls-files` -- list index and working-tree files.
##
## In scope for phase 3 (docs/09): `<file>`, `-c`, `-s`, `-d`, `-m`, `-u`,
## `--error-unmatch`, `-z`, `--`.  `-o`, `-i` and `--exclude-standard` are in
## scope for v1 but need the ignore engine, which plan.md §7 places in phase 4;
## they refuse by name rather than listing everything.
##
## ## Pathspecs here really are patterns
##
## Unlike `ls-tree` -- which does no wildcard matching at all -- `ls-files`
## takes full pathspecs, and by default a `*` in one **crosses directory
## separators**: `git ls-files '*.c'` finds 641 files in the git repository,
## where `:(glob)*.c` finds only the 244 in the top directory.  So the default
## is `globMatch` *without* pathname mode, plus the literal directory-prefix
## rule that makes `ls-files Documentation` list everything beneath it.

import std/[posix, sets, strutils]
import ../cli, ../glob, ../index, ../repository, ../util

const usageText = """usage: gittle ls-files [-c] [-s] [-d] [-m] [-u]
                       [--error-unmatch] [-z] [--] [<file>…]"""

proc pathspecMatches(path: string, specs: seq[string]): bool =
  ## An empty pathspec matches everything.  Otherwise a spec matches an exact
  ## path, everything under it when it names a directory, or a glob whose
  ## wildcards cross `/`.
  if specs.len == 0: return true
  for s in specs:
    let spec = s.strip(leading = false, chars = {'/'})
    if spec.len == 0: return true
    if path == spec: return true
    if path.startsWith(spec & "/"): return true
    if globMatch(spec, path, {}): return true
  false

proc cmdLsFiles*(c: Ctx, args: seq[string]): int =
  var showCached = false
  var showStage = false
  var showDeleted = false
  var showModified = false
  var showUnmerged = false
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
    elif a == "-u" or a == "--unmerged": showUnmerged = true
    elif a == "--error-unmatch": errorUnmatch = true
    elif a == "-z": nulTerminated = true
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["-o", "--others", "-i", "--ignored", "--exclude-standard",
               "--directory", "-k", "--killed"]:
      fail(a & " is not implemented in this version\n" &
           "  listing untracked or ignored files needs the ignore engine " &
           "(phase 4)")
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  # `-u` implies `-s`: there is no point showing unmerged entries without the
  # stage numbers that distinguish them (`builtin/ls-files.c:709`).
  if showUnmerged: showStage = true
  # With no selector at all, `-c` is the default.
  if not (showCached or showStage or showDeleted or showModified):
    showCached = true

  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  let terminator = if nulTerminated: '\0' else: '\n'
  var matched = initHashSet[string]()

  proc emit(e: IndexEntry) =
    if showStage:
      stdout.write formatMode(e.mode), " ", $e.oid, " ", $e.stage, "\t"
    stdout.write(if nulTerminated: e.path else: quotePath(e.path))
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

  # One pass, with up to three lines per entry -- an entry that is cached,
  # deleted *and* modified is printed three times.  That is git's structure
  # (`show_files`), and it is why `ls-files -c -m` repeats a modified file.
  for e in idx.entries:
    if not pathspecMatches(e.path, specs): continue

    if (showCached or showStage) and (not showUnmerged or e.stage != 0):
      # Only the cached pass satisfies `--error-unmatch`: git records a
      # pathspec as matched inside `show_ce`, which the deleted and modified
      # passes do not reach.  So `ls-files --error-unmatch -m <path>` fails for
      # a path that exists but is not modified.
      matched.incl e.path
      emit(e)
    if not (showDeleted or showModified): continue
    if e.skipWorktree: continue

    let (ok, st) = statPath(repo.workTreePath(e.path))
    if not ok and showDeleted: emit(e)
    if showModified and (not ok or isModified(e, st)): emit(e)

  # `--error-unmatch` is a status code, not a fatal error: git prints the
  # complaint and exits 1, where a `fail` here would exit 128.
  if errorUnmatch:
    for s in specs:
      if s notin matched:
        stdout.flushFile()
        stderr.write "error: pathspec '" & s &
                     "' did not match any file(s) known to git\n"
        return 1
  stdout.flushFile()
  0
