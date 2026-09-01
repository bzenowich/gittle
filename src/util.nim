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

proc interpolate*(format: string, atom: proc (name: string): string): string =
  ## Expand a git-style format string.
  ##
  ## Three things are recognised, and they are the same three wherever git
  ## takes a `--format`: `%(name)` calls `atom`, `%%` is a literal per cent, and
  ## `%xx` is a byte written as two hex digits -- which is how a format string
  ## carries a tab or a NUL through a shell that would otherwise eat it.
  var i = 0
  while i < format.len:
    if format[i] != '%':
      result.add format[i]
      inc i
    elif i + 1 < format.len and format[i+1] == '%':
      result.add '%'
      i += 2
    elif i + 1 < format.len and format[i+1] == '(':
      let close = format.find(')', i + 2)
      failIf(close < 0, "unterminated %( in format string")
      result.add atom(format[i+2 ..< close])
      i = close + 1
    else:
      failIf(i + 2 >= format.len, "unterminated % in format string")
      var v = 0
      for c in format[i+1 .. i+2]:
        let d = case c
                of '0'..'9': ord(c) - ord('0')
                of 'a'..'f': ord(c) - ord('a') + 10
                of 'A'..'F': ord(c) - ord('A') + 10
                else: -1
        failIf(d < 0, "bad %-escape '%" & format[i+1 .. i+2] & "' in format string")
        v = v * 16 + d
      result.add char(v)
      i += 3

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
