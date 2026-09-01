## `update-index` -- modify the index.
##
## In scope (docs/10): `<file>…`, `--add`, `--remove`, `--refresh`,
## `--cacheinfo`, `--stdin`, `-z`, `--`.
##
## The two flags that look like conveniences are the whole safety model:
## without `--add` a path that is not already staged is an error, and without
## `--remove` a path whose file has vanished is an error.  `update-index` is
## plumbing, so it refuses to guess which of the two a caller meant.

import std/[posix, strutils]
import ../cli, ../index, ../objects, ../repository, ../util

const usageText = """usage: gittle update-index [--add] [--remove] [--refresh]
                          [--cacheinfo <mode>,<object>,<path>]
                          [--stdin [-z]] [--] [<file>…]"""

proc stageFile(repo: Repository, idx: Index, path: string,
               allowAdd, allowRemove: bool) =
  ## Stage the working-tree file at `path`, or remove its entry if it is gone.
  let full = repo.workTreePath(path)
  let (ok, st) = statPath(full)
  if not ok or S_ISDIR(st.st_mode):
    failIf(not allowRemove,
           "cannot stage '" & path & "': it does not exist\n" &
           "  use --remove to drop it from the index")
    failIf(not idx.removePath(path),
           "'" & path & "' is not in the index and does not exist")
    return

  let existing = idx.find(path)
  failIf(existing < 0 and not allowAdd,
         "cannot add '" & path & "' to the index\n" &
         "  use --add to add a path that is not already tracked")

  var e = IndexEntry(path: path)
  e.fillStat(st)
  e.oid = repo.writeObject(otBlob, readWorkingFile(full, st))
  idx.addEntry(e)

proc parseCacheinfo(repo: Repository, idx: Index, arg: string) =
  ## `--cacheinfo <mode>,<object>,<path>` inserts an entry with no working-tree
  ## file at all -- which is how a tree is built for a path that is not checked
  ## out.  The stat fields stay zero, so the next `status` compares content.
  let parts = arg.split(',', 3)
  failIf(parts.len != 3, "invalid --cacheinfo: expected <mode>,<object>,<path>")
  var mode: uint32 = 0
  for ch in parts[0]:
    failIf(ch notin {'0' .. '7'}, "invalid mode in --cacheinfo: " & parts[0])
    mode = mode * 8 + uint32(ord(ch) - ord('0'))
  failIf(mode notin [modeRegular, modeExecutable, modeSymlink, modeGitlink],
         "invalid mode " & parts[0] & " in --cacheinfo")
  var e = IndexEntry(mode: mode, path: parts[2])
  e.oid = repo.resolveOid(parts[1])
  failIf(not repo.hasObject(e.oid),
         "--cacheinfo names an object that is not in the database: " & parts[1])
  idx.addEntry(e)

proc refresh(repo: Repository, idx: Index): int =
  ## Re-stat every entry and record what changed.
  ##
  ## An entry whose stat still matches is left alone.  One whose stat differs
  ## but whose *content* is unchanged gets fresh stat data -- that is the whole
  ## point, and what makes the next `status` cheap.  One whose content really
  ## changed is reported and left for the caller to stage.
  for e in idx.entries.mitems:
    if e.stage != 0: continue
    let full = repo.workTreePath(e.path)
    let (ok, st) = statPath(full)
    if not ok:
      echo e.path & ": needs update"
      result = 1
      continue
    if e.statMatches(st): continue
    let oid = hashObject(otBlob, readWorkingFile(full, st))
    if oid == e.oid:
      e.fillStat(st)      # same content, new stat: the cache was merely stale
    else:
      echo e.path & ": needs update"
      result = 1

proc cmdUpdateIndex*(c: Ctx, args: seq[string]): int =
  var allowAdd = false
  var allowRemove = false
  var doRefresh = false
  var fromStdin = false
  var nulTerminated = false
  var cacheinfos: seq[string]
  var paths: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-':
      paths.add a
    elif a == "--": noMoreOpts = true
    elif a == "--add": allowAdd = true
    elif a == "--remove": allowRemove = true
    elif a == "--refresh": doRefresh = true
    elif a == "--stdin": fromStdin = true
    elif a == "-z": nulTerminated = true
    elif a == "--cacheinfo":
      # The modern form is one comma-separated argument; the historical form is
      # three separate ones, and scripts in the wild still use it.
      failIf(i + 1 >= args.len, "option '--cacheinfo' requires a value")
      if args[i+1].contains(','):
        inc i
        cacheinfos.add args[i]
      else:
        failIf(i + 3 >= args.len, "--cacheinfo needs <mode> <object> <path>")
        cacheinfos.add args[i+1] & "," & args[i+2] & "," & args[i+3]
        i += 3
    elif a.startsWith("--cacheinfo="):
      cacheinfos.add a["--cacheinfo=".len .. ^1]
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  if fromStdin:
    let data = readAll(stdin)
    let sep = if nulTerminated: '\0' else: '\n'
    for p in data.split(sep):
      if p.len > 0: paths.add p

  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  var status = 0

  for ci in cacheinfos: parseCacheinfo(repo, idx, ci)
  for p in paths: stageFile(repo, idx, p, allowAdd, allowRemove)
  if doRefresh: status = refresh(repo, idx)

  # Nothing was asked for, so nothing is written: `update-index` with no
  # arguments must not rewrite the index and disturb its mtime.
  if cacheinfos.len > 0 or paths.len > 0 or doRefresh:
    idx.writeIndex()
  status
