## Shell-style glob matching.
##
## One engine, used by `for-each-ref` patterns now and by pathspecs and
## `.gitignore` in phase 4 (plan.md §5 budgets them together for exactly this
## reason).  It is git's `wildmatch.c` cut down to the syntax git's own
## documentation promises:
##
##   `?`        one character
##   `*`        any run of characters
##   `**`       any run of characters *including* `/`, in pathname mode
##   `[abc]`    one of a set; `[a-z]` ranges, `[!abc]` or `[^abc]` negated
##   `\x`       a literal `x`
##
## The one subtlety is **pathname mode**.  With it, `*` and `?` refuse to match
## a `/`, so `refs/*` names the refs directly under `refs/` and not every ref
## in the repository; `**` is the opt-out that crosses directories.  Without
## it, every wildcard matches everything, which is what `.gitignore` patterns
## containing no slash want.
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
  ## Match one `[...]` bracket expression, leaving `pi` just past the `]`.
  ##
  ## `]` immediately after the opening bracket (or after the negation) is a
  ## literal, which is the standard escape hatch for including it in a set.
  var i = pi + 1
  var negated = false
  if i < pat.len and (pat[i] == '!' or pat[i] == '^'):
    negated = true
    inc i
  var matched = false
  var first = true
  while i < pat.len and (pat[i] != ']' or first):
    first = false
    var lo = pat[i]
    if lo == '\\' and i + 1 < pat.len:
      inc i
      lo = pat[i]
    if i + 2 < pat.len and pat[i+1] == '-' and pat[i+2] != ']':
      var hi = pat[i+2]
      if hi == '\\' and i + 3 < pat.len:
        inc i
        hi = pat[i+2]
      let c = foldIf(ch, fold)
      if foldIf(lo, fold) <= c and c <= foldIf(hi, fold): matched = true
      i += 3
    else:
      if foldIf(lo, fold) == foldIf(ch, fold): matched = true
      inc i
  # An unterminated class is a malformed pattern; treat it as no match rather
  # than reading past the end.
  if i >= pat.len: return false
  pi = i + 1
  matched != negated

func matchFrom(pat: string, pi: int, s: string, si: int,
               flags: set[GlobFlag]): bool =
  ## Match `pat[pi..]` against `s[si..]`.
  let pathname = gfPathname in flags
  let fold = gfIgnoreCase in flags
  var p = pi
  var i = si
  while p < pat.len:
    case pat[p]
    of '*':
      # `**` crosses directory separators; a single `*` does not, in pathname
      # mode.  Collapse a run of stars first so `***` behaves like `**`.
      var stars = 0
      while p < pat.len and pat[p] == '*':
        inc p
        inc stars
      let crossSlash = not pathname or stars >= 2
      if p >= pat.len:
        # A trailing star matches the rest, provided it is allowed to.
        if crossSlash: return true
        return s.find('/', i) < 0
      var j = i
      while true:
        if matchFrom(pat, p, s, j, flags): return true
        if j >= s.len: return false
        if not crossSlash and s[j] == '/': return false
        inc j
    of '?':
      if i >= s.len: return false
      if pathname and s[i] == '/': return false
      inc p
      inc i
    of '[':
      if i >= s.len: return false
      if pathname and s[i] == '/': return false
      var np = p
      if not matchClass(pat, np, s[i], fold): return false
      p = np
      inc i
    of '\\':
      inc p
      if p >= pat.len: return false
      if i >= s.len or foldIf(pat[p], fold) != foldIf(s[i], fold): return false
      inc p
      inc i
    else:
      if i >= s.len or foldIf(pat[p], fold) != foldIf(s[i], fold): return false
      inc p
      inc i
  i == s.len

func globMatch*(pattern, s: string, flags: set[GlobFlag] = {}): bool =
  ## Does `s` match `pattern` in full?
  matchFrom(pattern, 0, s, 0, flags)
