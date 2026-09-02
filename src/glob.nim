## Shell-style glob matching -- **the** pattern matcher, for all of gittle.
##
## `.gitignore` rules, command-line pathspecs and `for-each-ref` patterns look
## like three pattern languages, and they are one matcher with three thin
## adapters in front of it.  This module is the matcher: git's `wildmatch.c`
## cut down to the syntax git's own documentation promises.
##
##   `?`        one character
##   `*`        any run of characters
##   `**`       any run of characters *including* `/`, in pathname mode
##   `[abc]`    one of a set; `[a-z]` ranges, `[!abc]` or `[^abc]` negated
##   `\x`       a literal `x`
##
## Two flags, and nothing else, distinguish the callers' dialects:
##
## | flag | what it changes |
## |---|---|
## | `gfPathname` | `*` and `?` refuse to cross a `/`; `**` is the opt-out |
## | `gfIgnoreCase` | ASCII case folding on every literal comparison |
##
## Pathname mode is the whole subtlety.  With it, `refs/*` names the refs
## directly under `refs/` and not every ref in the repository, and `*.c` in a
## pathspec means a `.c` file in *this* directory.  Without it every wildcard
## reaches everywhere, which is what a `.gitignore` pattern containing no
## slash wants, and what a bare `ls-files '*.c'` wants -- see `pathspec.nim`
## on why that surprises people.
##
## What each adapter adds on top, so this file can stay this small:
##
## | adapter | adds |
## |---|---|
## | `ignore.nim` | `!` negation, `/` anchoring, the basename rule, precedence |
## | `pathspec.nim` | the `:(magic)` words, the cwd prefix, the subtree rule |
## | `reffilter.nim` | matching the short name or the full name as a path |
##
## Matching is recursive with a backtracking `*`.  The pathological input for
## that shape is a pattern of many consecutive stars, which no ref name or
## ignore rule in practice contains; git's own matcher backtracks the same way.

import std/strutils

type
  GlobFlag* = enum
    gfPathname   ## `*` and `?` do not match `/`
    gfIgnoreCase

func foldIf(c: char, fold: bool): char {.inline.} =
  ## The character lower-cased when matching case-insensitively.
  if fold and c >= 'A' and c <= 'Z': char(ord(c) + 32) else: c

func matchClass(pat: string, pi: var int, ch: char, fold: bool): bool =
  ## Match one `[...]` bracket expression against `ch`, leaving `pi` just past
  ## the closing `]`.
  ##
  ## `]` immediately after the opening bracket (or after the negation) is a
  ## literal, which is the standard escape hatch for putting one in a set; a
  ## `-` with a `]` after it is a literal for the same reason.  An
  ## unterminated class is a malformed pattern and matches nothing, rather
  ## than being read past the end of the pattern.
  ##
  ## A bare member is a one-character range, so `[abc]` and `[a-c]` are the
  ## same loop with the endpoints picked differently.
  var i = pi + 1
  let negated = i < pat.len and pat[i] in {'!', '^'}
  if negated: inc i
  let c = foldIf(ch, fold)
  var matched = false
  var first = true
  while i < pat.len and (pat[i] != ']' or first):
    first = false
    var lo = pat[i]
    if lo == '\\' and i + 1 < pat.len:
      inc i
      lo = pat[i]
    var hi = lo
    if i + 2 < pat.len and pat[i+1] == '-' and pat[i+2] != ']':
      hi = pat[i+2]
      if hi == '\\' and i + 3 < pat.len:
        inc i
        hi = pat[i+2]
      i += 2
    inc i
    if foldIf(lo, fold) <= c and c <= foldIf(hi, fold): matched = true
  if i >= pat.len: return false
  pi = i + 1
  matched != negated

func matchFrom(pat: string, pi: int, s: string, si: int,
               flags: set[GlobFlag]): bool =
  ## Match `pat[pi..]` against the whole of `s[si..]`.
  ##
  ## Three atoms and one wildcard: a run of `*`, a single-character wildcard
  ## (`?` or a `[...]` class), and everything else, which is a literal -- with
  ## `\x` the way a literal `*`, `?` or `[` is written.
  let pathname = gfPathname in flags
  let fold = gfIgnoreCase in flags
  var p = pi
  var i = si
  while p < pat.len:
    case pat[p]
    of '*':
      # A run of stars is one wildcard, and two or more of them (`**`) is the
      # opt-out from pathname mode -- only that form may cross a `/`.  So
      # `***` behaves like `**`, which is what collapsing the run buys.
      let star = p
      while p < pat.len and pat[p] == '*': inc p
      let crossSlash = not pathname or p - star >= 2
      # A trailing star takes the whole rest, provided it is allowed to.
      if p >= pat.len: return crossSlash or s.find('/', i) < 0
      var j = i
      while true:
        if matchFrom(pat, p, s, j, flags): return true
        if j >= s.len: return false
        if not crossSlash and s[j] == '/': return false
        inc j
    of '?', '[':
      # Both consume exactly one character, and in pathname mode neither may
      # consume a `/`; only the class then has to say *which* characters.
      if i >= s.len or (pathname and s[i] == '/'): return false
      if pat[p] == '?': inc p
      elif not matchClass(pat, p, s[i], fold): return false
      inc i
    else:
      var c = pat[p]
      if c == '\\':
        inc p
        if p >= pat.len: return false     # a trailing backslash matches nothing
        c = pat[p]
      if i >= s.len or foldIf(c, fold) != foldIf(s[i], fold): return false
      inc p
      inc i
  i == s.len

func globMatch*(pattern, s: string, flags: set[GlobFlag] = {}): bool =
  ## Does the whole of `s` match `pattern`?
  matchFrom(pattern, 0, s, 0, flags)
