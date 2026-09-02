## `pack-objects` -- make a packfile out of a set of objects.
##
## In scope (docs/10): `base-name`, `--stdout`, `--revs`, `-q`.  Every delta
## and window option is cut, because gittle does not search for deltas at all
## -- [packwrite.nim](../packwrite.nim) explains what that costs and what it
## buys.  `--thin` is cut with them, so a pack gittle writes always stands on
## its own.
##
## Two input modes, both on standard input, and the difference is what the
## lines mean:
##
## * plain -- one object name per line, and that is the set;
## * `--revs` -- revision arguments (`<commit>`, `^<commit>`, `--not`), and
##   the set is everything they reach.  This is the mode `push` uses, and it
##   is `rev-list --objects` feeding a packer.

import std/[os, strutils]
import ../cli, ../indexpack, ../oid, ../packwrite, ../repository,
       ../revision, ../revwalk, ../util

const usageText = """usage: gittle pack-objects [--revs] [-q] (--stdout | <base-name>) < <object-list>

   --revs      read revision arguments rather than object names
   --stdout    write the pack to standard output
   -q          say nothing"""

proc cmdPackObjects*(c: Ctx, args: seq[string]): int =
  var revs, toStdout, quiet = false
  var baseName = ""
  for a in args:
    case a
    of "--revs": revs = true
    of "--stdout": toStdout = true
    of "-q", "--quiet": quiet = true
    of "-h", "--help": (echo usageText; return 0)
    else:
      if a.startsWith("-"):
        fail("gittle pack-objects does not support '" & a.split('=')[0] &
             "' (docs/10)\n" & usageText)
      failIf(baseName.len > 0, "too many arguments\n" & usageText)
      baseName = a
  failIf(toStdout == (baseName.len > 0), usageText)

  let repo = c.repo
  var oids: seq[Oid]
  if revs:
    var wants, haves: seq[Oid]
    var negate = false
    for raw in stdin.readAll().splitLines():
      var line = raw.strip()
      if line.len == 0: continue
      if line == "--not": (negate = true; continue)
      if line == "--all": continue
      var excluded = negate
      if line.startsWith("^"):
        excluded = not negate
        line = line[1 .. ^1]
      let o = repo.resolveRevish(line)
      if excluded: haves.add o else: wants.add o
    oids = repo.objectsBetween(wants, haves)
  else:
    for raw in stdin.readAll().splitLines():
      let line = raw.strip()
      if line.len == 0: continue
      # `rev-list --objects` prints `<oid> <path>`; the path is a packing hint
      # and not part of the name.
      oids.add repo.resolveRevish(line.split(' ')[0])

  if toStdout:
    discard writePack(repo, oids, proc (d: string) = stdout.write d)
    stdout.flushFile()
    return 0

  # A named pack is written to a temporary and then indexed, because its name
  # is its own checksum and that is not known until the last byte.
  let tmp = baseName & "-tmp-" & $getCurrentProcessId() & ".pack"
  createDir(tmp.parentDir)
  var f: File
  failIf(not open(f, tmp, fmWrite), "cannot create '" & tmp & "'")
  var h: Oid
  try:
    h = writePack(repo, oids, proc (d: string) =
      failIf(d.len > 0 and f.writeBuffer(unsafeAddr d[0], d.len) != d.len,
             "short write to " & tmp))
  finally:
    f.close()
  let final = baseName & "-" & $h & ".pack"
  moveFile(tmp, final)
  discard indexPack(final, baseName & "-" & $h & ".idx", fixThin = false)
  echo $h
  0
