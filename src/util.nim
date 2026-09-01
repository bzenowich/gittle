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

const cEscapes* = [('\a', 'a'), ('\b', 'b'), ('\f', 'f'), ('\n', 'n'),
                   ('\r', 'r'), ('\t', 't'), ('\v', 'v'), ('"', '"'),
                   ('\\', '\\')]
  ## The escapes git's `quote_c_style` writes and reads, as (byte, letter).
  ## Written as pairs rather than a packed string because a packed one is off
  ## by a character if you miscount it, and nothing catches that until the
  ## output is wrong.

proc quotePath*(path: string): string =
  ## Render a path the way git prints one (`quote.c:quote_c_style`).
  ##
  ## A path is just bytes, and most of them are unremarkable.  One containing a
  ## quote, a backslash, a control character or any byte above ASCII is wrapped
  ## in double quotes with C-style escapes -- so `ls-files` output stays one
  ## path per line and can be pasted back into a shell.  `core.quotePath` turns
  ## the high-byte half off; v1 does not implement it, which matches the
  ## default and is what almost every repository sees.
  ##
  ## `-z` output is *not* quoted: a NUL terminator already makes every byte
  ## unambiguous, which is the whole reason `-z` exists.
  var needs = false
  for c in path:
    if c < ' ' or c >= '\x7F' or c == '"' or c == '\\':
      needs = true
      break
  if not needs: return path

  result = "\""
  for c in path:
    var escaped = false
    for (raw, letter) in cEscapes:
      if c == raw:
        result.add '\\'
        result.add letter
        escaped = true
        break
    if escaped: discard
    elif c < ' ' or c >= '\x7F':
      # Three octal digits, always: `\3` followed by a digit would reparse as a
      # different byte.
      let v = int(uint8(c))
      result.add '\\'
      result.add char(ord('0') + ((v shr 6) and 7))
      result.add char(ord('0') + ((v shr 3) and 7))
      result.add char(ord('0') + (v and 7))
    else:
      result.add c
  result.add '"'

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
