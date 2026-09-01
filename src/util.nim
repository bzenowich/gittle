## Errors, exit status, and the small filesystem helpers every writer needs.
##
## Everything gittle can explain to a user is a `GittleError`.  `main` catches
## it, prints `gittle: <message>` and exits 128, which is git's status for a
## fatal error; anything else escaping to `main` is a bug and gets Nim's own
## traceback, which is the right outcome for a bug.
##
## The messages are meant to be actionable rather than terse.  A tool this
## small cannot afford advice machinery, so what would have been a hint goes
## in the error text itself -- see the repository extension gate for the shape
## that takes.

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
  ## Write via a temporary file in the same directory plus `rename`.
  ##
  ## `rename` within a directory is atomic on POSIX, so a concurrent reader
  ## sees either the old file or the complete new one, never a partial write,
  ## and a crash leaves at worst a stray temporary rather than a corrupt
  ## object.  The temporary has to be in the *same* directory because `rename`
  ## across filesystems is not atomic and may not even be possible.
  ##
  ## `mode` defaults to 0444: a loose object is named by the hash of its own
  ## contents, so there is never a reason to modify one in place, and making it
  ## read-only says so.
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
