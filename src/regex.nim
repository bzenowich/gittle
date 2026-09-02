## Regular expressions: the libc ones.
##
## plan.md decision 3 budgeted ~500 lines for a vendored ERE engine and §6.4
## said to spike the libc route first, because **that is what git itself
## does**: `compat/regex/` is only compiled when `NO_REGEX` is defined for a
## platform whose libc lacks `REG_STARTEND`.  The spike settled it (phase-5.md
## has the table); this file is the whole cost, and it is thirty lines of
## binding rather than five hundred of engine.
##
## ## Who still asks
##
## Two callers, and they want different things:
##
## * `log --grep`, `--author` and `--committer` (`cmd/log.nim`) match a whole
##   commit message or identity against a pattern, in process.  This is the
##   engine that answers them.
## * `grep` (`cmd/grep.nim`) no longer selects lines here -- `grep(1)` does
##   that now (docs/minimize-2.md B1) -- but it still needs to know *where*
##   inside a selected line the match sits, because `--color` paints it.  It
##   calls `matchLine` for that, and for the compile check: an invalid pattern
##   must be refused with libc's own message, which is git's, before any
##   external tool sees it.
##
## ## The two flags that make it behave like git's
##
## **`REG_STARTEND`** is a BSD extension, present in glibc and musl, that adds
## a length to the subject instead of relying on a NUL terminator.  Without it
## a line has to be copied out and terminated before every match; with it the
## subject is a pointer and a length into a buffer that is already in memory.
## git requires it outright -- `git-compat-util.h` has an `#error` if it is
## missing.
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
  REG_STARTEND {.importc, header: "<regex.h>".}: cint
  REG_NOMATCH {.importc, header: "<regex.h>".}: cint

# The three libc entry points (POSIX `regex.h`): compile, match, and the
# text of an error code.  See plan.md 6.4 for why libc's engine and not ours.
proc regcomp(preg: ptr RegexT, pattern: cstring, cflags: cint): cint
  {.importc, header: "<regex.h>".}
proc regexec(preg: ptr RegexT, s: cstring, nmatch: csize_t,
             pmatch: ptr RegmatchT, eflags: cint): cint
  {.importc, header: "<regex.h>".}
proc regerror(errcode: cint, preg: ptr RegexT, buf: cstring,
              size: csize_t): csize_t {.importc, header: "<regex.h>".}

type
  Regex* = ref object
    ## A compiled pattern.  Nothing but the libc object: `-F` is handled by
    ## quoting the literal into an ERE at compile time rather than by a second
    ## search routine beside this one (R4, one matcher).
    re: RegexT

  Match* = tuple[hit: bool, so, eo: int]
    ## Offsets relative to the start of the slice that was searched.

func ereQuote(s: string): string =
  ## `-F`: the pattern that matches `s` and nothing else.
  ##
  ## git shortcuts a literal past the engine entirely (`grep.c:is_fixed`);
  ## gittle escapes it instead, so there is one search routine rather than a
  ## regex one and a memmem one.  Every ERE metacharacter is backslashed --
  ## including `\` itself, first, or the escaping would escape its own output.
  for c in s:
    if c in {'.', '[', ']', '{', '}', '(', ')', '*', '+', '?', '^', '$',
             '|', '\\'}: result.add '\\'
    result.add c

proc compileRegex*(pattern: string, icase = false, fixed = false): Regex =
  ## Compile, or fail with libc's own message.
  ##
  ## The message text is not paraphrased: `regerror` produces exactly the
  ## string git prints after its `-e option, '<pat>': ` prefix, because git
  ## calls the same function on the same libc.  Rewording it would be a
  ## divergence invented for no reason.
  result = Regex()
  var flags = REG_EXTENDED or REG_NEWLINE
  if icase: flags = flags or REG_ICASE
  let pat = if fixed: ereQuote(pattern) else: pattern
  let rc = regcomp(addr result.re, pat.cstring, flags)
  if rc != 0:
    var buf = newString(1024)
    let n = int(regerror(rc, addr result.re, buf.cstring, csize_t(buf.len)))
    buf.setLen(max(n - 1, 0))
    fail("invalid regular expression '" & pattern & "': " & buf)

proc matchLine*(re: Regex, data: string, start, stop: int): Match =
  ## Where does the pattern first match inside `data[start ..< stop]`?
  ##
  ## The subject *begins* at `start`, so `^` anchors where the caller means it
  ## to -- see the module header.  A slice past the end of the string is the
  ## empty subject, which is a legal thing to match against (`^$` does).
  var m: RegmatchT
  m.rm_so = 0
  m.rm_eo = cint(stop - start)
  let base = if start >= data.len: cstring"" else: cast[cstring](unsafeAddr data[start])
  if regexec(addr re.re, base, 1, addr m, REG_STARTEND) == REG_NOMATCH:
    return (false, 0, 0)
  (true, int(m.rm_so), int(m.rm_eo))

proc matches*(re: Regex, s: string): bool =
  ## The whole of a string as one subject -- what `log --grep` and `--author`
  ## ask.  `REG_NEWLINE` keeps a multi-line commit message line-oriented, so
  ## `^Signed-off-by` finds a trailer rather than only a first line.
  re.matchLine(s, 0, s.len).hit
