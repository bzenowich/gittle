## Changing tracked files: the two-way update.
##
## Everything before this phase either appended to the object store or
## rewrote the index.  `checkout`, `switch`, `restore` and `reset --hard` are
## the first commands that overwrite a file somebody was editing, and that
## makes them the one place in gittle where a bug destroys work.
##
## git's answer is `unpack-trees.c` -- 2,800 lines, almost all of it the
## n-way merge phase 7 needs.  What this phase needs is the **two-way** case,
## `unpack-trees.c:twoway_merge`, which is one rule applied per path.  Call
## the three versions of a path *current* (the index), *old* (the tree HEAD
## names) and *new* (the tree being moved to):
##
## | current | old | new | what happens |
## |---|---|---|---|
## | absent | — | present | take new (refuse if an untracked file is there) |
## | absent | present | absent | nothing to do |
## | present | — | absent, old absent | keep: the path is not in this move |
## | present | any | new == old | keep: this move does not touch the path |
## | present | any | current == new | keep: already there |
## | present | old, current == old | absent | delete |
## | present | old, current == old | new | take new |
## | present | anything else | | **refuse** |
##
## The last row is the whole safety property, and it is why the walk happens
## twice: once to decide, and only if nothing was refused, once to apply.  A
## checkout that has written half the files and then discovered a conflict is
## worse than one that refused.
##
## Two separate things can make it refuse, and git words them differently
## because they are different mistakes:
##
## * the index does not match `old` -- something is **staged**;
## * the working file does not match the index -- something is **modified**.
##
## `--force` skips both checks and takes `new` regardless, which is exactly
## what `checkout -f`, `switch --discard-changes` and `reset --hard` are for.

import std/[algorithm, os, sets, strutils, tables]
import index, objects, oid, pathspec, repository, trees

type
  Version* = object
    ## One path as some tree records it.  `mode == 0` means "not in this tree",
    ## which is why absence needs no separate representation.
    mode*: uint32
    oid*: Oid

  TreeMap* = Table[string, Version]

  Plan* = object
    ## What a two-way update decided, before any of it has happened.
    take*: seq[string]      ## paths to write from the new tree
    remove*: seq[string]    ## paths to delete
    modified*: seq[string]  ## working-tree changes that would be lost
    staged*: seq[string]    ## index changes that would be lost
    untracked*: seq[string] ## files that are not tracked and would be lost

func exists(v: Version): bool = v.mode != 0

proc flatten*(repo: Repository, tree: Oid): TreeMap =
  ## Every blob in a tree, by full path.  Directories are not entries here:
  ## the index has no notion of one, and neither has the working-tree update.
  if tree.isNull: return
  for e in repo.walkTree(tree):
    if modeType(e.mode) != otTree:
      result[e.name] = Version(mode: canonMode(e.mode), oid: e.oid)

proc versionOf*(idx: Index, path: string): Version =
  let k = idx.find(path)
  if k >= 0: Version(mode: canonMode(idx.entries[k].mode), oid: idx.entries[k].oid)
  else: Version()

proc workingMatches(repo: Repository, idx: Index, path: string): bool =
  ## Is the working file what the index says it is?  The stat cache answers
  ## almost always; a racily-clean entry falls through to reading the content,
  ## which is what the zeroed size in the index is asking for (see index.nim).
  let k = idx.find(path)
  if k < 0: return false
  let full = repo.workTreePath(path)
  let (ok, st) = statPath(full)
  if not ok: return false
  if idx.entries[k].statMatches(st) and idx.entries[k].size != 0: return true
  if modeForFile(st) != canonMode(idx.entries[k].mode): return false
  hashObject(otBlob, readWorkingFile(full, st)) == idx.entries[k].oid

proc upToDate*(repo: Repository, idx: Index, path: string, v: Version): bool =
  ## Is this path already exactly `v`, in both the index and the working tree?
  ##
  ## Asked before every write, because rewriting a file with the bytes it
  ## already has is not free: it resets the mtime, which makes the stat cache
  ## miss on the next `status`, and it changes how many paths a command
  ## reports having updated.
  let k = idx.find(path)
  k >= 0 and idx.entries[k].oid == v.oid and
    canonMode(idx.entries[k].mode) == v.mode and repo.workingMatches(idx, path)

proc planTwoWay*(repo: Repository, idx: Index, oldTree, newTree: TreeMap,
                 force: bool): Plan =
  ## Decide, and only decide.  Nothing on disk changes here.
  var paths: HashSet[string]
  for p in oldTree.keys: paths.incl p
  for p in newTree.keys: paths.incl p
  for e in idx.entries:
    if e.stage == 0: paths.incl e.path

  for path in paths:
    let old = oldTree.getOrDefault(path)
    let new = newTree.getOrDefault(path)
    let cur = versionOf(idx, path)

    if not cur.exists:
      if not new.exists: continue           # gone in both: nothing to do
      # The path is new to us.  A file already sitting there is somebody's
      # untracked work, and taking the new version would destroy it.
      if not force and fileExists(repo.workTreePath(path)):
        result.untracked.add path
      else:
        result.take.add path
      continue

    if old == new: continue                 # this move does not touch the path
    if cur == new: continue                 # already what we are moving to

    if cur != old and not force:
      result.staged.add path
      continue
    # The index agrees with where we are, so the only thing that can be lost
    # is an unsaved edit.
    if not force and not repo.workingMatches(idx, path):
      result.modified.add path
      continue
    if new.exists: result.take.add path
    else: result.remove.add path

  sort(result.take)
  sort(result.remove)
  sort(result.modified)
  sort(result.staged)
  sort(result.untracked)

proc removeWorkingPath*(repo: Repository, path: string) =
  ## Delete a tracked file, and any directory it leaves empty.  git prunes
  ## those because a checkout that left `a/b/c/` behind as three empty
  ## directories would make the next `status` report a directory that is not
  ## in any tree.
  discard tryRemoveFile(repo.workTreePath(path))
  var dir = parentDir(path)
  while dir.len > 0:
    let full = repo.workTreePath(dir)
    var empty = true
    for _, _ in walkDir(full): (empty = false; break)
    if not empty: break
    try: removeDir(full) except OSError: break
    dir = parentDir(dir)

proc writeWorkingPath*(repo: Repository, path: string, v: Version) =
  ## Put one blob into the working tree, with its recorded mode.
  ##
  ## The file is removed before it is written rather than truncated: the old
  ## one may be a symlink, or read-only, and in both cases writing through it
  ## does the wrong thing.
  let full = repo.workTreePath(path)
  createDir(parentDir(full))
  discard tryRemoveFile(full)
  let data = repo.readObject(v.oid).data
  if v.mode == modeSymlink:
    createSymlink(data, full)
    return
  writeFile(full, data)
  setFilePermissions(full, if v.mode == modeExecutable: {fpUserRead, fpUserWrite,
                                                   fpUserExec, fpGroupRead,
                                                   fpGroupExec, fpOthersRead,
                                                   fpOthersExec}
                           else: {fpUserRead, fpUserWrite, fpGroupRead,
                                  fpOthersRead})

proc applyToIndex*(repo: Repository, idx: Index, path: string, v: Version) =
  ## Record the file just written.  The stat data is read back from disk, not
  ## guessed: an index entry whose stat does not match the file it describes
  ## makes every later `status` re-read the content.
  var e = IndexEntry(path: path, oid: v.oid)
  let (ok, st) = statPath(repo.workTreePath(path))
  if ok: e.fillStat(st)
  e.mode = v.mode
  idx.addEntry(e)

proc applyPlan*(repo: Repository, idx: Index, plan: Plan, newTree: TreeMap,
                toWorkTree = true) =
  ## Do what was decided, and record it in the index.
  ##
  ## `read-tree -m` without `-u` is the one caller that wants the index moved
  ## and the files left alone -- it is the plumbing half of a checkout -- and
  ## the entry it writes has no stat data, because no file matches it.
  for path in plan.remove:
    if toWorkTree: repo.removeWorkingPath(path)
    discard idx.removePath(path)
  for path in plan.take:
    let v = newTree[path]
    if modeType(v.mode) == otCommit: continue   # a gitlink is another repository
    if not toWorkTree:
      idx.addEntry IndexEntry(path: path, mode: v.mode, oid: v.oid)
      continue
    repo.writeWorkingPath(path, v)
    repo.applyToIndex(idx, path, v)

proc refusedPlumbing*(plan: Plan): bool =
  ## The same three refusals in `unpack-trees`' *plumbing* words, which are not
  ## the porcelain ones: `read-tree` is a script's tool and names the one entry
  ## that stopped it, where `checkout` groups them under an explanation and
  ## some advice.
  for (paths, text) in [(plan.staged, "Entry '$1' would be overwritten by merge. Cannot merge."),
                        (plan.modified, "Entry '$1' not uptodate. Cannot merge."),
                        (plan.untracked, "Untracked working tree file '$1' would be overwritten by merge.")]:
    for p in paths:
      result = true
      stderr.write "error: " & text.replace("$1", p) & "\n"

proc refused*(plan: Plan, verb: string): bool =
  ## The refusals, in git's words (`unpack-trees.c` carries one message per
  ## case, and which one appears tells the user which mistake they made).
  ##
  ## An `error:` and a status of 1, not a fatal: the command line was fine and
  ## the repository is fine, so this is a *result*, and a script testing the
  ## status should be able to tell it from a usage mistake.
  # One shape, three rows: which paths, what they are, and what to do first.
  let cases = [
    (plan.modified, "Your local changes to the following files would be " &
                    "overwritten by ",
                    "Please commit your changes or stash them before"),
    (plan.staged,   "Your local changes to the following files would be " &
                    "overwritten by ",
                    "Please commit your changes or stash them before"),
    (plan.untracked, "The following untracked working tree files would be " &
                     "overwritten by ",
                     "Please move or remove them before")]
  # The advice names the operation differently from the diagnosis: git says
  # "overwritten by checkout" but "before you switch branches", because the
  # second half is telling the user what they were trying to *do*
  # (`unpack-trees.c:setup_unpack_trees_porcelain`).
  let doing = if verb == "checkout": "switch branches" else: verb
  for (paths, lost, advice) in cases:
    if paths.len == 0: continue
    result = true
    stderr.write "error: " & lost & verb & ":\n\t" & paths.join("\n\t") &
                 "\n" & advice & " you " & doing & ".\nAborting\n"

proc checkoutPaths*(repo: Repository, idx: Index, source: TreeMap,
                    ps: Pathspec, toWorktree, toIndex: bool,
                    skipUnchanged = false):
    tuple[matched, written: int] =
  ## `restore`, and `checkout -- <paths>`: replace some paths from a source,
  ## and leave everything else -- including HEAD -- alone.
  ##
  ## No two-way rule applies here.  The user named the paths, so overwriting
  ## them is the request, not a risk to be checked for.
  ##
  ## Two counts come back, and they are different questions: `matched` says
  ## whether the pathspec found anything at all -- a pathspec that matched
  ## nothing is an error -- and `written` is what the "Updated N paths"
  ## message reports.
  ##
  ## `skipUnchanged` is for the case where the *index* is the source: git's
  ## `checkout_entry` returns without writing when the file already matches
  ## its index entry, and the count it reports -- "Updated 2 paths from the
  ## index" -- is of files actually written, not of files matched.
  for path, v in source:
    if not ps.matches(path): continue
    if modeType(v.mode) == otCommit: continue
    inc result.matched
    if skipUnchanged and repo.upToDate(idx, path, v): continue
    if toIndex: repo.applyToIndex(idx, path, v)
    if toWorktree:
      repo.writeWorkingPath(path, v)
      # Writing the file changes its stat data, so the index entry describing
      # it has to be refreshed even when only the working tree was asked for.
      if idx.find(path) >= 0: repo.applyToIndex(idx, path, versionOf(idx, path))
    inc result.written

proc refreshIndex*(repo: Repository, idx: Index): seq[string] =
  ## Fill in the stat data for every entry whose working file still matches
  ## it, and return the paths where it does not -- which is what `reset`
  ## prints under "Unstaged changes after reset:"
  ## (`read-cache.c:refresh_index`, whose porcelain format is `M\t<path>`).
  ##
  ## An index built from a tree has no stat data at all, so without this every
  ## file in the repository would look modified to the next `status`.
  for i in 0 ..< idx.entries.len:
    if idx.entries[i].stage != 0: continue
    let path = idx.entries[i].path
    let (ok, st) = statPath(repo.workTreePath(path))
    if not ok:
      result.add path
      continue
    if idx.entries[i].statMatches(st) and idx.entries[i].size != 0: continue
    if modeForFile(st) != canonMode(idx.entries[i].mode):
      result.add path
      continue
    # The stat says nothing useful, so the content has to answer -- but only
    # after the size has ruled out the easy no.
    if st.st_size.int != repo.objectInfo(idx.entries[i].oid).size:
      result.add path
      continue
    if hashObject(otBlob, readWorkingFile(repo.workTreePath(path), st)) ==
       idx.entries[i].oid:
      idx.entries[i].fillStat(st)
    else:
      result.add path

proc resetIndexTo*(repo: Repository, idx: Index, tree: TreeMap) =
  ## Replace the index with a tree, carrying over the stat data of every entry
  ## that did not change.  Without the carry-over, `refreshIndex` would have to
  ## re-read every file in the repository after every `reset`.
  var old: Table[string, IndexEntry]
  for e in idx.entries:
    if e.stage == 0: old[e.path] = e
  idx.entries.setLen(0)
  for path, v in tree:
    var e = IndexEntry(path: path, mode: v.mode, oid: v.oid)
    if old.hasKey(path) and old[path].oid == v.oid and
       canonMode(old[path].mode) == v.mode:
      e = old[path]
      e.mode = v.mode
    idx.addEntry(e)

proc resetWorkTree*(repo: Repository, idx: Index, tree: TreeMap) =
  ## `reset --hard`: make the working tree the tree, whatever is in the way.
  ##
  ## Not the two-way rule -- this is git's `oneway_merge`.  There is no
  ## question to ask: every tracked path becomes what the tree says, and
  ## anything that was tracked and is not in the tree goes.
  var known: seq[string]
  for e in idx.entries:
    # Every stage, not only stage 0: a path a conflict added exists in the
    # index at stages 1 and 3 with no stage 0 at all, and skipping it would
    # leave the file behind as a mysterious untracked one.
    if known.len == 0 or known[^1] != e.path: known.add e.path
  for path in known:
    if path notin tree: repo.removeWorkingPath(path)
  for path, v in tree:
    if modeType(v.mode) == otCommit: continue
    let k = idx.find(path)
    if k >= 0 and idx.entries[k].oid == v.oid and
       canonMode(idx.entries[k].mode) == v.mode:
      let (ok, st) = statPath(repo.workTreePath(path))
      if ok and idx.entries[k].statMatches(st) and idx.entries[k].size != 0:
        continue
    repo.writeWorkingPath(path, v)
