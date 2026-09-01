## Walking the working tree: what is here that the index does not know about.
##
## The index answers "what is tracked".  This answers the other half, and it is
## the half with all the judgement in it: a directory full of build output must
## not be walked at all, `.git` must never be entered, and a directory that
## contains a repository of its own is not a directory for these purposes.
##
## `add` uses it to find new files; `status`, `clean` and `ls-files -o` in
## later phases ask the same question with a different answer wanted.
##
## ## Pruning is not an optimisation here
##
## Skipping an ignored directory is what makes `!ignored/keep.txt` do nothing,
## which is the documented behavior (plan.md §4) rather than a shortcut -- so
## the prune has to happen in the walk even when the walk is cheap.  Skipping a
## directory a pathspec cannot reach *is* only an optimisation, and
## `Pathspec.mightMatchDir` is written to err toward walking.
##
## ## What is deliberately not here
##
## git's `dir.c` is 4,192 lines, and nearly all of the difference is the
## untracked cache and the fsmonitor hook -- accelerators, discarded by R3.
## The other omission is deliberate scope: a subdirectory containing its own
## `.git` is a submodule, which is cut, so gittle reports it and walks past
## rather than recording the gitlink git would.

import std/[os, posix, algorithm]
import ignore, index, objects, pathspec, repository

type
  WalkWant* = enum
    wwUntracked   ## paths not in the index and not ignored
    wwIgnored     ## paths not in the index that ignore rules exclude

proc walkWorkTree*(repo: Repository, idx: Index, ig: Ignore, ps: Pathspec,
                   want: set[WalkWant] = {wwUntracked}): seq[string] =
  ## Every working-tree path matching `ps` that the index does not have.
  ##
  ## Returned sorted by path bytes, which is the order git prints and the order
  ## the index wants anyway.  A depth-first walk does *not* produce it: `a.txt`
  ## sorts before `a/b` because `.` is 0x2E and `/` is 0x2F, while a walk
  ## visits the directory `a` first.
  if repo.workTree.len == 0: return

  var stack = @[""]           # root-relative directories, "" or ending in '/'
  while stack.len > 0:
    let dir = stack.pop()
    var names: seq[string]
    for _, path in walkDir(repo.workTree / dir, relative = true,
                           checkDir = false):
      names.add path
    sort(names)

    for name in names:
      if dir.len == 0 and name == ".git": continue
      let rel = dir & name
      let full = repo.workTree / rel
      let isDir = dirExists(full) and symlinkExists(full) == false

      if isDir:
        # A nested repository is a submodule, and submodules are cut.  Saying
        # so is better than silently staging its contents as ordinary files,
        # which is the one outcome nobody wants.
        if fileExists(full / ".git") or dirExists(full / ".git"):
          stderr.write "warning: '" & rel & "/' contains a repository; " &
                       "gittle does not support submodules and is skipping it\n"
          continue
        let ignored = ig.isIgnored(rel, true)
        # An ignored directory is never entered -- see the module header.  It
        # is entered when ignored paths are what was asked for, because there
        # is no other way to reach them.
        if ignored and wwIgnored notin want: continue
        if not ps.mightMatchDir(rel): continue
        stack.add rel & "/"
        continue

      if idx.find(rel) >= 0: continue       # tracked; ignore rules do not apply
      let ignored = ig.isIgnored(rel, false)
      if ignored and wwIgnored notin want: continue
      if not ignored and wwUntracked notin want: continue
      if ps.matches(rel): result.add rel

  sort(result)

proc pathIsIgnored*(repo: Repository, idx: Index, ig: Ignore, path: string): bool =
  ## For a path named outright rather than found by walking.  A tracked path is
  ## never ignored, whatever the rules say.
  if idx.find(path) >= 0: return false
  ig.isIgnored(path, dirExists(repo.workTreePath(path)))

# ---------------------------------------------------------------------------
# Staging
# ---------------------------------------------------------------------------

proc stageWorkingPath*(repo: Repository, idx: Index, path: string): bool =
  ## Stage the working-tree file at `path`, or report that it is not there.
  ##
  ## An entry whose stat data still matches is left completely alone -- not
  ## re-hashed, and not even rewritten with fresh stat data.  That is what
  ## makes `add .` over a large tree cost a `lstat` per file rather than a read
  ## and a SHA-1, and it is the entire purpose of the stat cache in the index.
  let full = repo.workTreePath(path)
  let (ok, st) = statPath(full)
  if not ok or S_ISDIR(st.st_mode): return false
  let existing = idx.find(path)
  if existing >= 0 and idx.entries[existing].statMatches(st) and
     idx.entries[existing].size != 0:
    return true
  var e = IndexEntry(path: path)
  e.fillStat(st)
  e.oid = repo.writeObject(otBlob, readWorkingFile(full, st))
  idx.addEntry(e)
  true
