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

import std/[os, posix, strutils, times]

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
  ## A fatal error: the message is printed as `gittle: <msg>` and the exit
  ## status is 128, as git's `die` does.
  raise newException(GittleError, msg)

proc failIf*(cond: bool, msg: string) {.inline.} =
  ## `fail` when the condition holds.
  if cond: fail(msg)

const cEscapes* = [('\a', 'a'), ('\b', 'b'), ('\f', 'f'), ('\n', 'n'),
                   ('\r', 'r'), ('\t', 't'), ('\v', 'v'), ('"', '"'),
                   ('\\', '\\')]
  ## The escapes git's `quote_c_style` writes and reads, as (byte, letter).
  ## Written as pairs rather than a packed string because a packed one is off
  ## by a character if you miscount it, and nothing catches that until the
  ## output is wrong.

func needsQuote*(s: string): bool =
  ## Would `quotePath` wrap this in quotes?  `diff` asks separately, because
  ## it quotes a *pair* of strings together: `diff --git "a/odd path" "b/odd
  ## path"` puts one set of quotes around the prefix and the path both
  ## (`quote.c:quote_two_c_style`).
  for c in s:
    if c < ' ' or c >= '\x7F' or c == '"' or c == '\\': return true
  false

proc quoteBody*(s: string): string =
  ## The escaped bytes, without the surrounding quotes.
  for c in s:
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
  if not needsQuote(path): return path
  "\"" & quoteBody(path) & "\""

proc pathField*(path: string, nulTerminated: bool): string =
  ## A path as an *output field*: the whole thing, terminator included.
  ##
  ## Every gittle command that prints paths obeys the same two rules, and they
  ## are a pair -- `-z` makes the terminator a NUL **and** turns the quoting
  ## off, because a NUL already delimits unambiguously and quoting on top of it
  ## would only make the bytes harder to read back.  Keeping the pair in one
  ## place is what stops a command from acquiring one half of `-z` and not the
  ## other.
  if nulTerminated: path & "\0" else: quotePath(path) & "\n"

func hexVal*(c: char): int {.inline.} =
  ## The value of one hex digit, or -1 for anything else.  Both cases are
  ## wanted: an object ID is 40 of these and a `%xx` escape is two, and in both
  ## places a non-digit is a parse failure the caller reports its own way.
  case c
  of '0'..'9': ord(c) - ord('0')
  of 'a'..'f': ord(c) - ord('a') + 10
  of 'A'..'F': ord(c) - ord('A') + 10
  else: -1

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
      let hi = hexVal(format[i+1])
      let lo = hexVal(format[i+2])
      failIf(hi < 0 or lo < 0,
             "bad %-escape '%" & format[i+1 .. i+2] & "' in format string")
      result.add char(hi shl 4 or lo)
      i += 3

proc dateNow*(): int64 =
  ## "Now", for every relative and human date gittle prints.
  ##
  ## `GIT_TEST_DATE_NOW` overrides it, which is git's own facility
  ## (`date.c:get_time`) and exists for exactly one reason: a comparison of
  ## `--date=relative` between two programs run a second apart is a
  ## comparison of *when they ran*.  One of them eventually lands on the far
  ## side of a "5 months ago"/"6 months ago" boundary and the test fails for
  ## no reason at all.
  let x = getEnv("GIT_TEST_DATE_NOW")
  if x.len > 0:
    try: return int64(parseInt(x.strip())) except ValueError: discard
  getTime().toUnix()

proc readWholeFile*(path: string): string =
  ## Like `readFile`, but reports the path when it fails.
  try:
    result = readFile(path)
  except IOError, OSError:
    fail("cannot read '" & path & "': " & getCurrentExceptionMsg())

proc readIfExists*(path: string): string =
  ## The file's contents, or the empty string when there is no such file.
  ##
  ## Most of the files gittle reads under `.git` are *optional*: there is no
  ## `packed-refs` until something packs refs, no reflog until a ref moves, no
  ## `objects/info/alternates` unless a clone was shared, and an absent config
  ## file is an empty one.  Absence is the ordinary state, not an error, so
  ## these are read through here rather than through `readWholeFile`.
  ##
  ## A file that disappears *between* the test and the read counts as absent
  ## too.  That is a real race and not a theoretical one -- another process
  ## running `git pack-refs` replaces a loose ref with an entry in
  ## `packed-refs`, and git's own ref reader treats the resulting `ENOENT` the
  ## same way (`refs/files-backend.c:parse_loose_ref_contents` callers).
  if not fileExists(path): return ""
  try:
    readFile(path)
  except IOError, OSError:
    ""

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
