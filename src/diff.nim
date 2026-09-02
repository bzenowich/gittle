## The diff engine: `diff(1)`, and the hunks that come out of it.
##
## Until the minimization pass (docs/minimize.md §5) this module was a
## reimplementation of git's `xdiff/` -- Myers' algorithm, git's trimming,
## and the indent heuristic that decides where an ambiguous hunk sits --
## 272 lines that produced git's output hunk for hunk.  It is now a caller
## of the `diff` every Unix system has, on the Unix-philosophy argument that
## finding the edit script is one tool's job and gittle's job is the rest:
## the object store, the headers, the counts, and the three-way merge.
##
## ## What `diff` is asked, and what is read back
##
##     diff -a -d -U0 <old> <new>
##
## `-a` says text whatever the bytes look like (gittle decides what is
## binary, before asking), `-d` says find a *minimal* script, which is the
## one configuration gittle ever produced (`git diff --minimal`), and `-U0`
## says print the changes with no context.  Everything but the hunk headers
## is thrown away: an `@@ -a,b +c,d @@` line *is* one edit -- `b` lines at
## `a` became `d` lines at `c` -- and that is the whole interface.  Context,
## hunk grouping and the `@@` function name are added back here, from the
## texts gittle already holds, exactly as before.  Both GNU diff and
## busybox's have every flag used; nothing else of either is relied on.
##
## ## Whitespace, and the missing final newline
##
## `-w`, `-b` and the two `--ignore-*-at-eol` modes are not `diff`'s flags
## but gittle's own normalisation: each line is rewritten under the mode
## (`xutils.c:xdl_recmatch`, the same rules as before), the rewritten copies
## are what `diff` sees, and the original lines are what gets printed, by
## line number.  That keeps the modes identical across `diff`
## implementations, busybox's included, which lacks the eol variants.
##
## A last line without a newline is a different line from the same bytes
## with one -- that is the whole content of `\ No newline at end of file`
## -- and `diff` agrees, provided the file is handed over as-is.  So under
## the exact mode the texts are written unchanged; under a whitespace mode
## the terminator is whitespace like any other and every line gets one.
##
## ## What changed on screen, and what did not
##
## The edit script is minimal either way, so the *counts* -- `--stat`,
## `--numstat`, the summary after `commit` -- are what they were.  Where an
## equal hunk could sit in several places, `diff` slides it differently from
## git's indent heuristic on a few percent of real commits; both are correct
## patches for the same change, and `git apply` takes either.  The oracle
## checks that, rather than the bytes (`tests/oracle.sh`, "diff engine").
##
## The cost is one `fork`+`exec` per file pair, about a millisecond.  The
## three-way merge (mergefile.nim) is unchanged: it is two edit scripts
## against the base, interleaved, and `diffRecords` still hands it those.

import std/[os, osproc, strutils, tempfiles]
import util

# 1. Lines, whitespace, and equivalence classes
# ---------------------------------------------------------------------------

type
  WsMode* = enum
    ## The whitespace comparison flags, strongest first.  git checks them in
    ## this order and the first one set wins (`xutils.c:xdl_recmatch`), so one
    ## enum says everything four booleans would.
    wsExact          ## bytes must match
    wsIgnoreCr       ## --ignore-cr-at-eol
    wsIgnoreEol      ## --ignore-space-at-eol
    wsIgnoreChange   ## -b
    wsIgnoreAll      ## -w

const spaceChars = {' ', '\t', '\n', '\v', '\f', '\r'}
  ## `XDL_ISSPACE`, which is C's `isspace` in the C locale.  A line never
  ## contains its own newline here, but `\r` and `\v` do occur inside one.

func normalize(line: string, ws: WsMode): string =
  ## The bytes two lines are compared *as*.
  ##
  ## git compares character by character with the flag's rule inline; gittle
  ## rewrites each line once into a canonical form and compares those, which is
  ## equivalent in all four modes and lets a hash table do the work:
  ##
  ## * `-w` -- every whitespace byte removed;
  ## * `-b` -- each run of whitespace collapsed to one space, trailing dropped.
  ##   The run must exist on *both* sides, which is why it collapses to a space
  ##   rather than to nothing;
  ## * `--ignore-space-at-eol` -- trailing whitespace dropped;
  ## * `--ignore-cr-at-eol` -- one trailing `\r` dropped.
  case ws
  of wsExact:
    line
  of wsIgnoreCr:
    if line.len > 0 and line[^1] == '\r': line[0 ..< line.high] else: line
  of wsIgnoreEol:
    line.strip(leading = false, chars = spaceChars)
  of wsIgnoreChange:
    var s = ""
    var i = 0
    while i < line.len:
      if line[i] in spaceChars:
        while i < line.len and line[i] in spaceChars: inc i
        if i < line.len: s.add ' '     # a trailing run is dropped outright
      else:
        s.add line[i]
        inc i
    s
  of wsIgnoreAll:
    var s = ""
    for c in line:
      if c notin spaceChars: s.add c
    s


type
  Side = object
    text: string
    lo, hi: seq[int]      ## line i is `text[lo[i] ..< hi[i]]`, newline excluded

func nrec(s: Side): int = s.lo.len

func line(s: Side, i: int): string = s.text[s.lo[i] ..< s.hi[i]]

func terminated(s: Side, i: int): bool = s.hi[i] < s.text.len
  ## Did line `i` end with a newline?  Only the last line can fail to.

func splitLines(text: string, s: var Side) =
  ## git's line splitting: a line ends at `\n` or at the end of the buffer, and
  ## the newline is not part of the line.  A file ending in `\n` therefore has
  ## no empty final line, which is what makes "\ No newline at end of file" a
  ## property of the last line rather than a line of its own.
  s.text = text
  var i = 0
  while i < text.len:
    var e = text.find('\n', i)
    if e < 0: e = text.len
    s.lo.add i
    s.hi.add e
    i = e + 1


# ---------------------------------------------------------------------------
# 2. The edit script, from diff(1)
# ---------------------------------------------------------------------------

type
  Change = object
    ## One run of changed lines: `c1` lines removed at `i1`, `c2` added at
    ## `i2`.  Either count may be zero, which is what a pure insertion or
    ## deletion is.  Zero-based, where `@@` headers are one-based.
    i1, i2, c1, c2: int

proc forDiff(s: Side, ws: WsMode): string =
  ## The bytes `diff` compares for one side: untouched under the exact mode,
  ## otherwise every line normalised and newline-terminated.
  if ws == wsExact: return s.text
  for i in 0 ..< s.nrec: result.add normalize(s.line(i), ws) & "\n"

proc externalDiff(a, b: Side, ws: WsMode): seq[Change] =
  ## Run `diff -U0` over the two sides and read its hunk headers.
  ##
  ## `@@ -A,B +C,D @@`: `B` old lines starting at line `A` became `D` new
  ## lines starting at `C`.  A count of zero moves the meaning of the start
  ## by one -- `-5,0` is "after old line 5", so the zero-based index is 5
  ## itself where `-5,2` means index 4.  A missing `,B` is a count of one.
  let (fa, pa) = createTempFile("gittle-", ".old")
  let (fb, pb) = createTempFile("gittle-", ".new")
  fa.close()
  fb.close()
  try:
    writeFile(pa, a.forDiff(ws))
    writeFile(pb, b.forDiff(ws))
    let (output, status) = execCmdEx("diff -a -d -U0 " & quoteShell(pa) & " " &
                                     quoteShell(pb), options = {poUsePath})
    failIf(status > 1, "diff failed: " & output.strip())
    for hl in output.splitLines():
      if not hl.startsWith("@@ -"): continue
      var ch: Change
      for (spec, start, count) in [(hl.split(' ')[1][1 .. ^1], addr ch.i1, addr ch.c1),
                                   (hl.split(' ')[2][1 .. ^1], addr ch.i2, addr ch.c2)]:
        let parts = spec.split(',')
        count[] = if parts.len > 1: parseInt(parts[1]) else: 1
        start[] = parseInt(parts[0]) - (if count[] == 0: 0 else: 1)
      result.add ch
  finally:
    removeFile(pa)
    removeFile(pb)

# ---------------------------------------------------------------------------
# 3. Hunks: context, grouping, and the function name
# ---------------------------------------------------------------------------

type
  DiffLineKind* = enum
    dlContext, dlDelete, dlAdd

  DiffLine* = object
    kind*: DiffLineKind
    text*: string
    noNewline*: bool   ## this line was the last one and had no terminator

  Hunk* = object
    s1*, c1*, s2*, c2*: int   ## one-based starts and counts, as in `@@`
    funcName*: string
    lines*: seq[DiffLine]

  DiffResult* = object
    hunks*: seq[Hunk]
    added*, deleted*: int


func isFuncLine(s: Side, i: int): bool =
  ## git's default "what does a hunk header name" test (`xemit.c:def_ff`): a
  ## line that starts in the first column with a letter, `_` or `$`.  It is a
  ## crude proxy for a function definition and it is the only one git applies
  ## without a gitattributes driver, which decision 6 cuts.
  if s.lo[i] >= s.hi[i]: return false
  s.text[s.lo[i]] in {'a'..'z', 'A'..'Z', '_', '$'}

func validUtf8Prefix(s: string): int =
  ## How many leading bytes of `s` are complete, valid UTF-8 characters
  ## (`utf8.c:pick_one_utf8_char`, as used by `diff.c:sane_truncate_line`).
  ##
  ## Overlong forms, surrogates, `U+FFFE`/`U+FFFF` and anything above
  ## `U+10FFFF` are rejected as well as truncated sequences: this is git's
  ## validator and not a general one, and the point is to agree with it.
  var i = 0
  while i < s.len:
    let c0 = byte(s[i])
    var n = 0
    if c0 < 0x80'u8:
      n = 1
    elif (c0 and 0xE0'u8) == 0xC0'u8:
      if i + 2 > s.len or (byte(s[i+1]) and 0xC0'u8) != 0x80'u8 or
         (c0 and 0xFE'u8) == 0xC0'u8: return i          # overlong
      n = 2
    elif (c0 and 0xF0'u8) == 0xE0'u8:
      if i + 3 > s.len or (byte(s[i+1]) and 0xC0'u8) != 0x80'u8 or
         (byte(s[i+2]) and 0xC0'u8) != 0x80'u8 or
         (c0 == 0xE0'u8 and (byte(s[i+1]) and 0xE0'u8) == 0x80'u8) or
         (c0 == 0xED'u8 and (byte(s[i+1]) and 0xE0'u8) == 0xA0'u8) or
         (c0 == 0xEF'u8 and byte(s[i+1]) == 0xBF'u8 and
          (byte(s[i+2]) and 0xFE'u8) == 0xBE'u8): return i
      n = 3
    elif (c0 and 0xF8'u8) == 0xF0'u8:
      if i + 4 > s.len or (byte(s[i+1]) and 0xC0'u8) != 0x80'u8 or
         (byte(s[i+2]) and 0xC0'u8) != 0x80'u8 or
         (byte(s[i+3]) and 0xC0'u8) != 0x80'u8 or
         (c0 == 0xF0'u8 and (byte(s[i+1]) and 0xF0'u8) == 0x80'u8) or
         (c0 == 0xF4'u8 and byte(s[i+1]) > 0x8F'u8) or c0 > 0xF4'u8: return i
      n = 4
    else:
      return i
    i += n
  s.len

func funcLineText(s: Side, i: int): string =
  ## The name that goes on the `@@` line.  Two truncations, and the second one
  ## is not obvious:
  ##
  ## 1. at most 80 bytes with trailing whitespace removed -- git's
  ##    `func_line.buf` is 80 bytes and `xemit.c:def_ff` right-trims whatever
  ##    fits in it;
  ## 2. cut back to the last complete UTF-8 character.  git does this to the
  ##    whole header line rather than to the name
  ##    (`diff.c:fn_out_consume` calls `sane_truncate_line` on any line
  ##    starting with `@`), which comes to the same thing because everything
  ##    before the name is ASCII.  Without it, a hunk header in a translation
  ##    file ends in half a character -- which is exactly where the reference
  ##    repository disagreed with an earlier version of this file.
  var e = min(s.hi[i], s.lo[i] + 80)
  while e > s.lo[i] and s.text[e - 1] in spaceChars: dec e
  let raw = s.text[s.lo[i] ..< e]
  raw[0 ..< validUtf8Prefix(raw)]

proc emitLine(s: Side, i: int, kind: DiffLineKind, noNlAtEof: bool): DiffLine =
  ## One output line of a hunk, marking the last line of a side that had
  ## no final newline.
  DiffLine(kind: kind, text: s.line(i),
           noNewline: noNlAtEof and i == s.nrec - 1)

func trimCommonTail(a, b: string): int =
  ## How many bytes to lop off the end of both buffers before diffing at all
  ## (`xdiff-interface.c:trim_common_tail`).
  ##
  ## git does this **only at `-U0`**, where no context is printed and a shared
  ## tail therefore cannot appear in the output.  It compares whole 1 KiB
  ## blocks, then walks forward to the first newline so that what remains ends
  ## on a line boundary.  It is an optimisation that *changes the answer*: the
  ## search runs over a smaller box and can settle on a different, equally
  ## minimal, diff.  gittle implements it for that reason and no other.
  const blk = 1024
  let smaller = min(a.len, b.len)
  var trimmed = 0
  while blk + trimmed <= smaller and
        a[a.len - trimmed - blk ..< a.len - trimmed] ==
        b[b.len - trimmed - blk ..< b.len - trimmed]:
    trimmed += blk
  var recovered = 0
  while recovered < trimmed:
    let c = a[a.len - trimmed + recovered]
    inc recovered
    if c == '\n': break
  trimmed - recovered


proc runDiff(oldText, newTextIn: string, ws: WsMode, ctxLen: int): tuple[
    a, b: Side, changes: seq[Change], noNl1, noNl2: bool] =
  ## Split, diff, and say whether either side lacked a final newline.
  ##
  ## With no context wanted, a common tail is cut off first, on a line
  ## boundary (`xdiff/xprepare.c:xdl_trim_ends`, done here so `diff` reads
  ## less): a tail that was cut away always ended on a line boundary, so a
  ## file that lost its unterminated last line no longer has one.
  var old = oldText
  var newText = newTextIn
  if ctxLen == 0:
    let cut = trimCommonTail(old, newText)
    if cut > 0:
      old.setLen(old.len - cut)
      newText.setLen(newText.len - cut)
  splitLines(old, result.a)
  splitLines(newText, result.b)
  result.changes = externalDiff(result.a, result.b, ws)
  result.noNl1 = old.len > 0 and old[^1] != '\n'
  result.noNl2 = newText.len > 0 and newText[^1] != '\n'

proc diffText*(oldText, newText: string, ctxLen = 3, ws = wsExact): DiffResult =
  ## The whole engine: two blobs in, hunks out.
  let (a, b, changes, noNl1, noNl2) = runDiff(oldText, newText, ws, ctxLen)
  for ch in changes:
    result.deleted += ch.c1
    result.added += ch.c2

  var funcName = ""
  var funcPrev = -1
  var k = 0
  while k < changes.len:
    # Everything within twice the context of the previous change belongs in
    # the same hunk, because the two context runs would otherwise overlap
    # (`xemit.c:xdl_get_hunk`).
    var last = k
    while last + 1 < changes.len and
          changes[last + 1].i1 - (changes[last].i1 + changes[last].c1) <=
            2 * ctxLen:
      inc last

    let first = changes[k]
    let final = changes[last]
    var s1 = max(first.i1 - ctxLen, 0)
    var s2 = max(first.i2 - ctxLen, 0)
    let lctx = min(ctxLen, min(a.nrec - (final.i1 + final.c1),
                               b.nrec - (final.i2 + final.c2)))
    let e1 = final.i1 + final.c1 + lctx
    let e2 = final.i2 + final.c2 + lctx

    # The name on the `@@` line is the nearest preceding line in the *old*
    # file that looks like a definition -- and it is searched only back as far
    # as the previous hunk looked, so a hunk with nothing new above it keeps
    # the previous hunk's name rather than rescanning the file.
    var i = s1 - 1
    while i >= 0 and i < a.nrec and i != funcPrev:
      if a.isFuncLine(i):
        funcName = a.funcLineText(i)
        break
      dec i
    funcPrev = s1 - 1

    var h = Hunk(s1: s1 + 1, c1: e1 - s1, s2: s2 + 1, c2: e2 - s2,
                 funcName: funcName)
    var p1 = s1
    var p2 = s2
    for j in k .. last:
      let ch = changes[j]
      while p2 < ch.i2:
        h.lines.add b.emitLine(p2, dlContext, noNl2)
        inc p1
        inc p2
      for x in ch.i1 ..< ch.i1 + ch.c1:
        h.lines.add a.emitLine(x, dlDelete, noNl1)
      for x in ch.i2 ..< ch.i2 + ch.c2:
        h.lines.add b.emitLine(x, dlAdd, noNl2)
      p1 = ch.i1 + ch.c1
      p2 = ch.i2 + ch.c2
    while p2 < e2:
      h.lines.add b.emitLine(p2, dlContext, noNl2)
      inc p2
    result.hunks.add h
    k = last + 1

proc diffCounts*(oldText, newText: string, ws = wsExact):
    tuple[added, deleted: int] =
  ## Line counts only, for `--stat` and `--numstat`.  The context and the
  ## hunk grouping are what `diffText` does *after* the algorithm, so skipping
  ## them is not an approximation -- the counts are the same.
  let changes = runDiff(oldText, newText, ws, 3).changes
  for ch in changes:
    result.added += ch.c2
    result.deleted += ch.c1

# ---------------------------------------------------------------------------
# 6. The ungrouped script, for the three-way merge
# ---------------------------------------------------------------------------

type
  Edit* = object
    ## One run of changed lines, exactly as `xdl_build_script` produces it:
    ## `c1` lines of the old file at `i1` become `c2` lines of the new file at
    ## `i2`.  `diffText` groups these into hunks and adds context; the merge
    ## (mergefile.nim) wants them ungrouped, because two scripts against the
    ## same base are what it interleaves.
    i1*, i2*, c1*, c2*: int

  Records* = object
    ## Two files as line *records*, plus the script between them.
    ##
    ## A record keeps its terminator, where the `text` of a `DiffLine` does
    ## not.  The merge builds its output by concatenating records
    ## (`xmerge.c:xdl_recs_copy`), so what it copies has to be the original
    ## bytes -- including whether the last line had a newline at all.
    a*, b*: seq[string]
    edits*: seq[Edit]

func records(s: Side): seq[string] =
  ## The lines of a side as records -- terminator included, which is what
  ## the merge concatenates.
  for i in 0 ..< s.nrec:
    # `hi[i]` is the newline, or the end of the text for a final line without
    # one, so one past it is the record and the bound is what distinguishes
    # the two cases.
    result.add s.text[s.lo[i] ..< min(s.hi[i] + 1, s.text.len)]

proc diffRecords*(oldText, newText: string): Records =
  ## The whole engine again, stopping one stage earlier than `diffText`.
  let (a, b, changes, _, _) = runDiff(oldText, newText, wsExact, 3)
  result.a = a.records
  result.b = b.records
  for ch in changes:
    result.edits.add Edit(i1: ch.i1, i2: ch.i2, c1: ch.c1, c2: ch.c2)
