## Errors, and the small filesystem helpers every writer needs.

import std/[os, posix, strutils]

type
  GittleError* = object of CatchableError
    ## Anything gittle can explain to the user.  `main` prints these as
    ## "gittle: <message>" and exits 128, the way git does.

proc cexit(code: cint) {.importc: "exit", header: "<stdlib.h>", noreturn.}

proc exitWith*(code: int) {.noreturn.} =
  ## Nim's `quit` clamps the status to int8 on POSIX, which turns git's
  ## conventional fatal status 128 into 127.  Go straight to C's `exit`, which
  ## flushes stdio on the way out.
  flushFile(stdout)
  flushFile(stderr)
  cexit(cint(code))

proc fail*(msg: string) {.noreturn.} =
  raise newException(GittleError, msg)

proc failIf*(cond: bool, msg: string) {.inline.} =
  if cond: fail(msg)

proc readWholeFile*(path: string): string =
  ## Like `readFile`, but reports the path when it fails.
  try:
    result = readFile(path)
  except IOError, OSError:
    fail("cannot read '" & path & "': " & getCurrentExceptionMsg())

var tmpSeq = 0

proc writeFileAtomic*(path, data: string, mode: int = 0o444) =
  ## Write via a temporary file in the same directory plus `rename`, so a reader
  ## never sees a partial file and a crash never leaves a corrupt one.  Loose
  ## objects are read-only once written, which is why `mode` defaults to 0444.
  let dir = parentDir(path)
  inc tmpSeq
  let tmp = dir / ("tmp_gittle_" & $getpid() & "_" & $tmpSeq)
  try:
    writeFile(tmp, data)
    doAssert chmod(tmp.cstring, Mode(mode)) == 0
    moveFile(tmp, path)
  except CatchableError:
    removeFile(tmp)
    raise

proc isHexDigits*(s: string): bool =
  for c in s:
    if c notin HexDigits: return false
  s.len > 0
