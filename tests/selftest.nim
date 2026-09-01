## The two modules that have no git command in front of them, exercised so
## `oracle.sh` can compare them against `sha1sum` and against themselves.
##
##   selftest sha1   < input   -- hash stdin, feeding it in awkward chunk sizes
##   selftest zlib   < input   -- round-trip stdin through every inflate path
##
## Built by tests/oracle.sh; not part of the gittle binary.

import std/[os, strutils]
import sha1, zlib

proc hex(d: Sha1Digest): string =
  result = newStringOfCap(40)
  for b in d: result.add toHex(b.int, 2).toLowerAscii

proc testSha1(data: string) =
  ## Deliberately ragged chunking, so the 64-byte block buffering is exercised
  ## at every alignment rather than only at whole blocks.
  var c = initSha1()
  var i = 0
  var n = 1
  while i < data.len:
    let m = min(n, data.len - i)
    c.update(data.toOpenArrayByte(i, i + m - 1))
    i += m
    n = (n * 7 + 3) mod 200 + 1
  echo hex(c.finish())

proc testZlib(data: string) =
  let p: pointer = if data.len == 0: nil else: unsafeAddr data[0]
  let comp = deflateAll(p, data.len, ZBestSpeed)
  let cp: pointer = unsafeAddr comp[0]

  doAssert inflateAll(cp, comp.len) == data, "inflateAll mismatch"

  let (exact, consumed) = inflateExact(cp, comp.len, data.len)
  doAssert exact == data, "inflateExact mismatch"
  doAssert consumed == comp.len, "inflateExact consumed " & $consumed &
                                 " of " & $comp.len

  let want = min(17, data.len)
  doAssert inflatePrefix(cp, comp.len, want) == data[0 ..< want],
           "inflatePrefix mismatch"

  # The property pack reading depends on: a stream followed by unrelated bytes
  # must still report exactly how many of them it used.
  let padded = comp & "GARBAGE-GARBAGE-GARBAGE"
  let (e2, c2) = inflateExact(unsafeAddr padded[0], padded.len, data.len)
  doAssert e2 == data, "inflateExact mismatch with trailing bytes"
  doAssert c2 == comp.len, "trailing bytes changed consumed: " & $c2

  echo "ok ", data.len, " -> ", comp.len

when isMainModule:
  let data = readAll(stdin)
  case (if paramCount() >= 1: paramStr(1) else: "")
  of "sha1": testSha1(data)
  of "zlib": testZlib(data)
  else:
    stderr.write "usage: selftest (sha1 | zlib) < input\n"
    quit(2)
