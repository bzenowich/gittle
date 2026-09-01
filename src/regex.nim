## Regular expressions: the libc ones.
##
## plan.md decision 3 budgeted ~500 lines for a vendored ERE engine and §6.4
## said to spike the libc route first, because **that is what git itself
## does**: `compat/regex/` is only compiled when `NO_REGEX` is defined for a
## platform whose libc lacks `REG_STARTEND`.  The spike settled it (phase-5.md
## has the table); this file is the whole cost, and it is forty lines of
## binding rather than five hundred of engine.
##
## ## The two flags that make it behave like git's
##
## **`REG_STARTEND`** is a BSD extension, present in glibc and musl, that adds
## a length to the subject instead of relying on a NUL terminator.  Without it
## a line has to be copied out and terminated before every match; with it the
## subject is a pointer and a length into a buffer that is already in memory,
## which is what lets `grep` search a blob without rewriting it.  git requires
## it outright -- `git-compat-util.h` has an `#error` if it is missing.
##
## **`REG_NEWLINE`** is set at compile time, as in `grep.c:compile_regexp`.
## With it `.` and a negated class stop at a newline, which is what makes a
## pattern line-oriented even when the buffer it is matched against is not.
##
## ## The trap that cost the spike an hour
##
## `^` under `REG_STARTEND` anchors to the **true start of the buffer**, not to
## `rm_so`.  Confining a match to a line by setting `rm_so`/`rm_eo` to that
## line's offsets therefore makes `^` match only on the first line of the file.
## git avoids it by passing a pointer to the line itself and offsets `0 ..
## len` -- so the buffer *begins* at the line -- and `REG_STARTEND` is what
## makes that safe when the bytes after it are not a terminator.  `matchLine`
## below does the same thing, which is why it takes a slice rather than a
## string.

import std/strutils
import util

type
  RegexT {.importc: "regex_t", header: "<regex.h>", bycopy.} = object
    re_nsub: csize_t
  RegmatchT {.importc: "regmatch_t", header: "<regex.h>", bycopy.} = object
    rm_so, rm_eo: cint

var
  REG_EXTENDED {.importc, header: "<regex.h>".}: cint
  REG_ICASE {.importc, header: "<regex.h>".}: cint
  REG_NEWLINE {.importc, header: "<regex.h>".}: cint
  REG_NOTBOL {.importc, header: "<regex.h>".}: cint
  REG_STARTEND {.importc, header: "<regex.h>".}: cint
  REG_NOMATCH {.importc, header: "<regex.h>".}: cint

proc regcomp(preg: ptr RegexT, pattern: cstring, cflags: cint): cint
  {.importc, header: "<regex.h>".}
proc regexec(preg: ptr RegexT, s: cstring, nmatch: csize_t,
             pmatch: ptr RegmatchT, eflags: cint): cint
  {.importc, header: "<regex.h>".}
proc regerror(errcode: cint, preg: ptr RegexT, buf: cstring,
              size: csize_t): csize_t {.importc, header: "<regex.h>".}

type
  Regex* = ref object
    ## A compiled pattern.  `fixed` and `word` are the two options git applies
    ## *around* the engine rather than inside it, so they live here with it.
    re: RegexT
    isFixed: bool      ## `-F`: `fixed` is the literal to look for, `re` unused
    fixed: string
    icase: bool
    word: bool         ## `-w`: a match must begin and end on a word boundary

  Match* = tuple[hit: bool, so, eo: int]
    ## Offsets relative to the start of the slice that was searched.

func wordChar(c: char): bool =
  ## git's `word_char` (`grep.c`): alphanumeric or underscore, in the C locale.
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc compileRegex*(pattern: string, icase = false, fixed = false,
                   word = false): Regex =
  ## Compile, or fail with libc's own message.
  ##
  ## The message text is not paraphrased: `regerror` produces exactly the
  ## string git prints after its `-e option, '<pat>': ` prefix, because git
  ## calls the same function on the same libc.  Rewording it would be a
  ## divergence invented for no reason.
  result = Regex(icase: icase, word: word, isFixed: fixed)
  if fixed:
    result.fixed = if icase: pattern.toLowerAscii else: pattern
    return
  var flags = REG_EXTENDED or REG_NEWLINE
  if icase: flags = flags or REG_ICASE
  let rc = regcomp(addr result.re, pattern.cstring, flags)
  if rc != 0:
    var buf = newString(1024)
    let n = int(regerror(rc, addr result.re, buf.cstring, csize_t(buf.len)))
    buf.setLen(max(n - 1, 0))
    fail("invalid regular expression '" & pattern & "': " & buf)

proc execAt(re: Regex, data: string, start, stop: int, notBol: bool): Match =
  ## One `regexec` over `data[start ..< stop]`, with the subject *beginning* at
  ## `start` so that `^` anchors where the caller means it to.
  var m: RegmatchT
  m.rm_so = 0
  m.rm_eo = cint(stop - start)
  let base = if start >= data.len: cstring"" else: cast[cstring](unsafeAddr data[start])
  var eflags: cint = 0
  if notBol: eflags = eflags or REG_NOTBOL
  if regexec(addr re.re, base, 1, addr m, eflags or REG_STARTEND) == REG_NOMATCH:
    return (false, 0, 0)
  (true, int(m.rm_so), int(m.rm_eo))

func fold(re: Regex, c: char): char =
  if re.icase: toLowerAscii(c) else: c

proc execFixed(re: Regex, data: string, start, stop: int, from0: int): Match =
  ## `-F`: a literal search over the slice, folding case when `-i` asked for
  ## it.  A literal needle is never compiled at all, which is how git
  ## shortcuts it too (`grep.c:is_fixed`).  Scanned in place rather than over a
  ## copy, because `grep -F` on a large blob would otherwise duplicate it once
  ## per candidate position.
  let n = re.fixed.len
  var i = start + from0
  while i + n <= stop:
    var k = 0
    while k < n and re.fold(data[i + k]) == re.fixed[k]: inc k
    if k == n: return (true, i - start, i - start + n)
    inc i
  (false, 0, 0)

proc matchLine*(re: Regex, data: string, start, stop: int): Match =
  ## Does the pattern match somewhere in `data[start ..< stop]`?
  ##
  ## The loop exists only for `-w`.  git's reasoning
  ## (`grep.c:headerless_match_one_pattern`) is that the *first* match on a
  ## line may fail the word test while a later one passes -- `grep -w cat` on
  ## `concat cat` must hit -- so a rejected match restarts the search just past
  ## the next non-word character rather than giving up on the line.
  var at = 0
  while true:
    let m = if re.isFixed: re.execFixed(data, start, stop, at)
            else: re.execAt(data, start + at, stop, at > 0)
    if not m.hit: return (false, 0, 0)
    let so = (if re.isFixed: m.so else: m.so + at)
    let eo = (if re.isFixed: m.eo else: m.eo + at)
    if not re.word: return (true, so, eo)
    let len = stop - start
    if so != eo and
       (so == 0 or not wordChar(data[start + so - 1])) and
       (eo == len or not wordChar(data[start + eo])):
      return (true, so, eo)
    # Skip past this match's first byte, then past the rest of its word: the
    # next candidate can only begin after a non-word character.
    at = so + 1
    while at < len and wordChar(data[start + at - 1]): inc at
    if at >= len: return (false, 0, 0)

proc matches*(re: Regex, s: string): bool =
  ## The whole of a string as one line -- what `log --grep` and `--author` ask.
  re.matchLine(s, 0, s.len).hit
