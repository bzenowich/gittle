## The two modules that have no git command in front of them, exercised so
## `oracle.sh` can compare them against `sha1sum` and against themselves.
##
##   selftest sha1   < input   -- hash stdin, feeding it in awkward chunk sizes
##   selftest zlib   < input   -- round-trip stdin through every inflate path
##   selftest glob             -- the glob engine against a table of cases
##   selftest diff <a> <b> [-U<n>] [-w|-b|--ignore-space-at-eol|--ignore-cr-at-eol]
##                             -- the hunks of a unified diff, exactly the
##                                lines `git diff --no-index --minimal` prints
##                                after its four header lines
##
## Built by tests/oracle.sh; not part of the gittle binary.

import std/[os, strutils]
import sha1, zlib, glob, refname, diff

proc testDiff() =
  ## Print the hunks the way git prints them, so oracle.sh can diff the two
  ## streams directly rather than comparing a summary of them.
  var ctx = 3
  var ws = wsExact
  var files: seq[string]
  for i in 2 .. paramCount():
    let a = paramStr(i)
    case a
    of "-w", "--ignore-all-space": ws = wsIgnoreAll
    of "-b", "--ignore-space-change": ws = wsIgnoreChange
    of "--ignore-space-at-eol": ws = wsIgnoreEol
    of "--ignore-cr-at-eol": ws = wsIgnoreCr
    else:
      if a.startsWith("-U"): ctx = parseInt(a[2 .. ^1])
      else: files.add a
  let r = diffText(readFile(files[0]), readFile(files[1]), ctx, ws)
  for h in r.hunks:
    stdout.write "@@ -" & (if h.c1 == 0: $(h.s1 - 1) else: $h.s1) &
                 (if h.c1 == 1: "" else: "," & $h.c1) &
                 " +" & (if h.c2 == 0: $(h.s2 - 1) else: $h.s2) &
                 (if h.c2 == 1: "" else: "," & $h.c2) & " @@"
    if h.funcName.len > 0: stdout.write " " & h.funcName
    stdout.write "\n"
    for l in h.lines:
      stdout.write (case l.kind
                    of dlContext: " "
                    of dlDelete: "-"
                    of dlAdd: "+")
      stdout.write l.text & "\n"
      if l.noNewline: stdout.write "\\ No newline at end of file\n"

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

const globCases = [
  # (pattern, subject, pathname-mode expected, plain expected)
  ("*", "abc", true, true),
  ("*", "a/b", false, true),          # `*` stops at `/` in pathname mode
  ("**", "a/b", true, true),          # `**` is the opt-out
  ("a/*", "a/b", true, true),
  ("a/*", "a/b/c", false, true),
  ("a/**", "a/b/c", true, true),
  ("refs/heads/*", "refs/heads/main", true, true),
  ("refs/heads/*", "refs/heads/f/x", false, true),
  ("refs/*/side", "refs/heads/side", true, true),
  ("?", "a", true, true),
  ("?", "/", false, true),
  ("a?c", "abc", true, true),
  ("a?c", "ac", false, false),
  ("[abc]d", "bd", true, true),
  ("[!abc]d", "bd", false, false),
  ("[^abc]d", "zd", true, true),
  ("[a-c]d", "bd", true, true),
  ("[a-c]d", "dd", false, false),
  ("[]]x", "]x", true, true),         # `]` first in a class is a literal
  ("a\\*b", "a*b", true, true),         # an escaped star is a literal star
  ("a\\*b", "axb", false, false),
  ("", "", true, true),
  ("", "a", false, false),
  ("a*b*c", "abxbyc", true, true),    # backtracking
  ("*.c", "foo.c", true, true),
  ("*.c", "d/foo.c", false, true),
  ("[", "[", false, false),           # an unterminated class matches nothing
]

proc testGlob() =
  var failures = 0
  for (pat, sub, wantPath, wantPlain) in globCases:
    let gotPath = globMatch(pat, sub, {gfPathname})
    let gotPlain = globMatch(pat, sub, {})
    if gotPath != wantPath:
      inc failures
      echo "  pathname: '", pat, "' vs '", sub, "' -> ", gotPath, ", want ", wantPath
    if gotPlain != wantPlain:
      inc failures
      echo "  plain:    '", pat, "' vs '", sub, "' -> ", gotPlain, ", want ", wantPlain

  # Case folding, and the shortening helpers that sit beside the matcher.
  doAssert globMatch("ABC", "abc", {gfIgnoreCase})
  doAssert not globMatch("ABC", "abc", {})
  doAssert shortenRefname("refs/heads/main") == "main"
  doAssert shortenRefname("refs/tags/v1") == "v1"
  doAssert shortenRefname("refs/remotes/o/main") == "o/main"
  doAssert shortenRefname("HEAD") == "HEAD"
  doAssert isValidRefname("refs/heads/main")
  doAssert not isValidRefname("refs/heads/a..b")
  doAssert not isValidRefname("main")
  doAssert isValidRefname("HEAD", {rfAllowOneLevel})

  doAssert failures == 0, $failures & " glob cases failed"
  echo "ok ", globCases.len, " glob cases"

when isMainModule:
  let mode = if paramCount() >= 1: paramStr(1) else: ""
  case mode
  of "diff": testDiff()
  of "glob": testGlob()
  of "sha1": testSha1(readAll(stdin))
  of "zlib": testZlib(readAll(stdin))
  else:
    stderr.write "usage: selftest (sha1 | zlib | glob) [< input]\n"
    quit(2)
