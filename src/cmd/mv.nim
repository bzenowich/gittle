## `mv` -- rename a tracked path, in the working tree and in the index at once.
##
## In scope (docs/07): `-f`/`--force`, `-n`/`--dry-run`, `-v`/`--verbose`.
## `-k` (skip the ones that would fail) and `--sparse` are cut.
##
## ## It is `rename(2)` plus a list of refusals
##
## The move itself is one system call and one index edit.  What
## `builtin/mv.c` is is the eleven things it checks first, in a fixed order,
## and the order is part of the behavior: `gittle mv dir existing-file` is
## "destination already exists" and not "cannot move directory over file",
## because the directory test comes earlier.  Each one dies with the same
## shape, `<what>, source=<src>, destination=<dst>`, so the whole family is a
## string and a `goto` in C and a string and an early return here.
##
## ## Moving a directory moves what the index knows, not what is on disk
##
## `rename(2)` takes the whole directory across, untracked files included --
## that is what the user asked for.  The *index* has no directories in it, so
## the entries under `dir/` are rewritten one at a time to `newdir/`; an
## untracked file that came along is still untracked at the far end.  A
## directory with nothing tracked under it is refused ("source directory is
## empty") rather than moved, because there would be no index edit to make and
## `mv(1)` already does that job.

import std/[os, posix, strutils]
import ../cli, ../index, ../pathspec, ../repository, ../util

proc rename(oldPath, newPath: cstring): cint {.importc, header: "<stdio.h>".}
  ## `rename(2)`.  Nim's `moveFile` refuses a directory and `moveDir` copies
  ## across filesystems; a rename is what git does and what has to happen
  ## here, failure included -- "destination directory does not exist" is a
  ## message the caller is entitled to.

const usageText = """usage: gittle mv [-v] [-f] [-n] <source>… <destination>"""

type Move = object
  src, dst: string
  isDir: bool      ## the source is a directory: rename it, but touch no entry
  viaParent: bool  ## an entry carried along by its directory: index only

proc cmdMv*(c: Ctx, argv: seq[string]): int =
  let args = expandShortOptions(argv, {})
  var force, dryRun, verbose = false
  var rest: seq[string]
  for a in args:
    if a.len == 0 or a[0] != '-': rest.add a
    elif a == "-f" or a == "--force": force = true
    elif a == "-n" or a == "--dry-run": dryRun = true
    elif a == "-v" or a == "--verbose": verbose = true
    elif a == "-h" or a == "--help": (echo usageText; return 0)
    elif a == "-k" or a == "--sparse":
      fail("gittle mv does not support '" & a & "' (docs/07)")
    else: fail("unknown option '" & a & "'\n" & usageText)
  failIf(rest.len < 2, usageText)

  let repo = c.repo
  failIf(repo.workTree.len == 0, "this operation must be run in a work tree")
  let idx = readIndex(repo.indexPath)

  proc full(p: string): string = repo.workTreePath(p)
  proc isDirOnDisk(p: string): bool =
    let (ok, st) = statPath(full(p))
    ok and S_ISDIR(st.st_mode)

  var sources: seq[string]
  for i in 0 ..< rest.len - 1: sources.add inPrefix(rest[i], repo.prefix)
  let destRaw = rest[^1]
  var dest = inPrefix(destRaw, repo.prefix)

  # A trailing `/` on the destination is a claim that it is a directory, and
  # `gittle mv file no-such-dir/` must fail on it.  The one exception is a
  # single directory source: `mv dir newname/` renames, because there is
  # nothing else it could mean.
  let keepSlash = not (sources.len == 1 and isDirOnDisk(sources[0]) and
                       not isDirOnDisk(dest))
  let destWasSlash = destRaw.len > 0 and destRaw[^1] == '/'

  var moves: seq[Move]
  let destIsDir = dest.len == 0 or isDirOnDisk(dest)
  if not destIsDir:
    failIf(sources.len != 1, "destination '" & destRaw & "' is not a directory")
    if keepSlash and destWasSlash: dest.add "/"
    moves.add Move(src: sources[0], dst: dest)
  else:
    for s in sources:
      moves.add Move(src: s, dst: (if dest.len == 0: "" else: dest & "/") &
                                  s.lastPathPart)

  proc refuse(m: Move, why: string) {.noreturn.} =
    fail(why & ", source=" & m.src & ", destination=" & m.dst)

  var taken: seq[string]     # destinations already claimed, for the clash check
  var movedDirs: seq[string]
  var i = 0
  while i < moves.len:
    let m = moves[i]
    if dryRun: echo "Checking rename of '" & m.src & "' to '" & m.dst & "'"
    let (srcOk, srcSt) = statPath(full(m.src))
    if not srcOk: refuse(m, "bad source")
    if m.dst.startsWith(m.src) and
       (m.dst.len == m.src.len or m.dst[m.src.len] == '/'):
      refuse(m, "can not move directory into itself")
    if S_ISDIR(srcSt.st_mode):
      if fileExists(full(m.dst)) or dirExists(full(m.dst)) or
         symlinkExists(full(m.dst)):
        refuse(m, "destination already exists")
      failIf(idx.find(m.src) >= 0,
             "gittle does not support submodules, and '" & m.src &
             "' is a directory in the index")
      # Every tracked path under the directory moves with it.  They are
      # appended after the ones the user named, which is git's order and the
      # order `-v` prints them in.
      var carried = 0
      for e in idx.entries:
        if e.path.startsWith(m.src & "/"):
          moves.add Move(src: e.path,
                         dst: m.dst & e.path[m.src.len .. ^1], viaParent: true)
          inc carried
      if carried == 0: refuse(m, "source directory is empty")
      moves[i].isDir = true
      movedDirs.add m.src
      inc i
      continue

    if idx.find(m.src) < 0:
      failIf(idx.isTracked(m.src), "conflicted, source=" & m.src &
             ", destination=" & m.dst)
      refuse(m, "not under version control")
    let (dstOk, dstSt) = statPath(full(m.dst))
    if dstOk:
      if not force: refuse(m, "destination exists")
      if not (S_ISREG(dstSt.st_mode) or S_ISLNK(dstSt.st_mode)):
        refuse(m, "Cannot overwrite")
      if verbose: stderr.write "warning: overwriting '" & m.dst & "'\n"
    if m.dst in taken: refuse(m, "multiple sources for the same target")
    if m.dst.len > 0 and m.dst[^1] == '/':
      refuse(m, "destination directory does not exist")
    # Only a path that will actually be renamed on disk needs its destination
    # directory to be there.  An entry carried along by its parent gets no
    # rename of its own -- the directory move already put it where it goes --
    # so git skips this check for it (`needs_worktree_rename`), and checking
    # anyway refuses every directory move into a new name.
    let parent = m.dst.parentDir
    if not m.viaParent and parent.len > 0:
      let (pOk, pSt) = statPath(full(parent))
      if not pOk: refuse(m, "destination directory does not exist")
      elif not S_ISDIR(pSt.st_mode): refuse(m, "destination is not a directory")
    taken.add m.dst
    inc i

  # `gittle mv dir dir2 dir/f newname` would move `dir/f` twice, once on its
  # own and once inside `dir`, and the second rename would fail on a file that
  # is no longer there.  git refuses the pair rather than ordering them.
  for m in moves:
    if m.viaParent: continue
    var d = m.src.parentDir
    while d.len > 0:
      failIf(d in movedDirs, "cannot move both '" & m.src &
             "' and its parent directory '" & d & "'")
      d = d.parentDir

  for m in moves:
    if dryRun or verbose: echo "Renaming " & m.src & " to " & m.dst
    if dryRun: continue
    if not m.viaParent:
      failIf(rename(full(m.src).cstring, full(m.dst).cstring) < 0,
             "renaming '" & m.src & "' to '" & m.dst & "' failed: " &
             $strerror(errno))
    if m.isDir: continue
    let k = idx.find(m.src)
    var e = idx.entries[k]
    e.path = m.dst
    discard idx.removePath(m.src)
    idx.addEntry(e)

  # A directory whose tracked content all moved away is removed even if the
  # rename left it behind, which happens when only part of it was named.
  for d in movedDirs:
    var stillThere = false
    for e in idx.entries:
      if e.path.startsWith(d & "/"): (stillThere = true; break)
    if not stillThere and dirExists(full(d)):
      try: removeDir(full(d)) except OSError: discard

  idx.writeIndex()
  0
