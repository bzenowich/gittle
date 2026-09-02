## `index-pack` -- build a `.idx` for a packfile, and check the pack while
## doing it.
##
## In scope (docs/10): `<pack-file>`, `--stdin`, `-o`, `--fix-thin`, `-v`.
## The work is all in [indexpack.nim](../indexpack.nim); this is the argument
## surface and the two output forms.  `-v` prints the progress git prints;
## gittle has no progress meter (docs/03 cuts `--progress` everywhere) so it
## reports only the summary line git ends with.

import std/[os, posix, strutils]
import ../cli, ../indexpack, ../oid, ../objects, ../repository, ../util

const usageText = """usage: gittle index-pack [-v] [-o <index-file>] <pack-file>
   or: gittle index-pack --stdin [--fix-thin] [<pack-file>]

   --stdin           read the pack from standard input and write it out
   --fix-thin        complete a thin pack from the repository's own objects
   -o <index-file>   write the index here rather than beside the pack
   -v                report what was indexed"""

proc readStdinTo(path: string) =
  var f: File
  failIf(not open(f, path, fmWrite), "cannot create '" & path & "'")
  defer: f.close()
  var buf = newString(64 * 1024)
  while true:
    let n = stdin.readBuffer(addr buf[0], buf.len)
    if n <= 0: break
    failIf(f.writeBuffer(addr buf[0], n) != n, "short write to " & path)

proc cmdIndexPack*(c: Ctx, args: seq[string]): int =
  var fromStdin, fixThin, verbose = false
  var idxPath, packArg = ""
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--stdin": fromStdin = true
    of "--fix-thin": fixThin = true
    of "-v": verbose = true
    of "-o":
      inc i
      failIf(i >= args.len, "option '-o' requires a value")
      idxPath = args[i]
    of "-h", "--help": (echo usageText; return 0)
    else:
      if a.startsWith("-o"): idxPath = a[2 .. ^1]
      elif a.startsWith("-"):
        fail("gittle index-pack does not support '" & a & "' (docs/10)\n" &
             usageText)
      else:
        failIf(packArg.len > 0, "too many arguments\n" & usageText)
        packArg = a
    inc i
  failIf(not fromStdin and packArg.len == 0, usageText)
  failIf(fixThin and not fromStdin, "--fix-thin cannot be used without --stdin")

  var r: tuple[hash: Oid, nObjects: int]
  if fromStdin and packArg.len == 0:
    # No name given: the pack goes into the object store under the name its
    # own checksum gives it, which is `installPack`'s whole job and the same
    # path a `fetch` takes.
    let tmp = c.repo.objDirs[0] / "pack" / ("tmp_gittle_" & $getpid() & ".pack")
    createDir(tmp.parentDir)
    readStdinTo(tmp)
    r = installPack(c.repo, tmp, fixThin)
  else:
    var packPath = packArg
    if fromStdin: readStdinTo(packPath)
    else: failIf(not fileExists(packPath), "cannot read '" & packPath & "'")
    if idxPath.len == 0:
      failIf(not packPath.endsWith(".pack"),
             "packfile name '" & packPath & "' does not end with .pack")
      idxPath = packPath[0 ..< packPath.len - 5] & ".idx"
    # The repository is only needed to complete a thin pack, and `index-pack`
    # is documented to work on a loose pack outside one.
    var lookup: proc (o: Oid): GitObject = nil
    if fixThin:
      let repo = c.repo
      lookup = proc (o: Oid): GitObject =
        if repo.hasObject(o): repo.readObject(o) else: GitObject(kind: otBad)
    r = indexPack(packPath, idxPath, fixThin, lookup)

  if verbose:
    stderr.write "Indexed " & $r.nObjects & " objects\n"
  if fromStdin: echo "pack\t" & $r.hash
  else: echo $r.hash
  0
