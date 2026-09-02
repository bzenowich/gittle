## The three-way merge of one file: `xdiff/xmerge.c`.
##
## Given a common ancestor and two descendants of it, produce the text that
## contains both sets of changes -- and, where they overlap, conflict markers
## naming the two sides.  Every conflict gittle ever writes comes out of this
## file, whether the caller was `merge-file`, `merge`, `cherry-pick`, `revert`,
## `rebase` or `stash apply`.
##
## ## How a three-way merge is actually computed
##
## Not from the three files directly.  It is **two diffs against the base**,
## interleaved:
##
##     base -> ours    a script of edits
##     base -> theirs  another script of edits
##
## Walk the two scripts together over the base's line numbers.  An edit that
## no edit on the other side comes near is *taken* -- the other side had no
## opinion about those lines.  Two edits that touch overlapping base lines are
## a **conflict**, unless they turn out to be the identical edit, in which case
## either copy will do.
##
## That is `xdl_do_merge`, and the reason it is worth restating is that it
## explains the shape of every conflict a user has ever seen: the markers do
## not delimit "lines that differ", they delimit *a region of the base* that
## both sides rewrote.
##
## ## The two refinements, which are what make the output usable
##
## The raw result marks the whole overlapping region as conflicting, and that
## is much larger than the disagreement usually is.  git then does two things
## in opposite directions (`level >= XDL_MERGE_ZEALOUS`):
##
## * **Refine** (`xdl_refine_conflicts`) -- diff the two conflicting sides
##   against *each other* and keep only the parts that actually differ.  A
##   hundred-line region where the two sides differ in one line becomes a
##   one-line conflict, and if the diff comes out empty the sides agreed after
##   all and the conflict disappears.
## * **Simplify** (`xdl_simplify_non_conflicts`) -- and then, having split one
##   conflict into several, swallow any gap of three lines or fewer between
##   two of them back into a single conflict.  Two conflicts separated by one
##   common line take more lines on screen than one conflict does.
##
## `merge-file` runs one level higher again (`XDL_MERGE_ZEALOUS_ALNUM`), where
## a gap is swallowed regardless of its length if it contains no letter or
## digit: a run of `}`, `*/` and blank lines is not context worth preserving.
##
## ## Where gittle deliberately differs
##
## The diffs above are gittle's diff engine, which implements only git's
## `--minimal` path (diff.nim's header says why).  git's merge asks for the
## default one.  The consequence is the same as it is for `diff`: on inputs
## where the two disagree, both answers are correct three-way merges of the
## same three files, and gittle prints the minimal one.  The oracle passes
## `--diff-algorithm=minimal` (`merge-file`) and `-Xdiff-algorithm=minimal`
## (`merge`) for that reason.
##
## Also cut, all of them options this file would otherwise need a parameter
## for (docs/10, docs/05): `--diff3`/`--zdiff3` (conflicts never show the
## base), `--ours`/`--theirs`/`--union` (no auto-resolution), and the
## whitespace flags, which arrive only through `-X` strategy options.

import std/strutils
import diff

const defaultMarkerSize* = 7
  ## `DEFAULT_CONFLICT_MARKER_SIZE` in `xdiff.h`.  Seven `<` is not arbitrary:
  ## it is one more than the six a context diff's `>>>>>>` could produce.

type
  MergeLevel* = enum
    ## How hard to work at making the conflict small.  Both levels refine and
    ## simplify; they differ only in whether a gap with no letter or digit in
    ## it counts as a reason to keep two conflicts apart.
    mlZealous       ## `XDL_MERGE_ZEALOUS`: what `merge` and friends use
    mlZealousAlnum  ## `XDL_MERGE_ZEALOUS_ALNUM`: what `merge-file` uses

  Region = object
    ## One decided stretch of the output, in three coordinate systems at once:
    ## `i0` indexes the base, `i1` ours, `i2` theirs.
    ##
    ## `mode` is git's: 0 conflict, 1 take ours, 2 take theirs, 3 take both,
    ## and 4 "the refinement found the two sides identical, emit nothing" --
    ## which is not the same as 0 lines of conflict, because a mode-4 region
    ## does not advance the output cursor past itself.
    mode: int
    i0, chg0: int
    i1, chg1: int
    i2, chg2: int

# ---------------------------------------------------------------------------
# Building the region list
# ---------------------------------------------------------------------------

proc append(regions: var seq[Region], mode, i0, chg0, i1, chg1, i2, chg2: int) =
  ## `xdl_append_merge`.  A region that starts at or before the end of the
  ## previous one is folded into it rather than added -- and if the two had
  ## different modes, the fusion is a conflict, because "take ours" and "take
  ## theirs" over the same lines is exactly what a conflict is.
  if regions.len > 0 and (i1 <= regions[^1].i1 + regions[^1].chg1 or
                          i2 <= regions[^1].i2 + regions[^1].chg2):
    if mode != regions[^1].mode: regions[^1].mode = 0
    regions[^1].chg0 = i0 + chg0 - regions[^1].i0
    regions[^1].chg1 = i1 + chg1 - regions[^1].i1
    regions[^1].chg2 = i2 + chg2 - regions[^1].i2
  else:
    regions.add Region(mode: mode, i0: i0, chg0: chg0, i1: i1, chg1: chg1,
                       i2: i2, chg2: chg2)

proc sameLines(ours, theirs: seq[string], i1, i2, count: int): bool =
  ## Are `count` lines of the two sides identical, starting at `i1` and
  ## `i2`?  The identical-edit case of `xdl_do_merge`.
  for k in 0 ..< count:
    if ours[i1 + k] != theirs[i2 + k]: return false
  true

proc buildRegions(d1, d2: Records): seq[Region] =
  ## `xdl_do_merge`'s first half: walk the two scripts over the base's line
  ## numbers and classify every edit.
  ##
  ## The bookkeeping is that each side's edit has to be reported in the
  ## *other* side's coordinates too, and away from a conflict the two sides
  ## are simply offset by however much the other side has inserted so far --
  ## which is what the `i2 = xscr1->i1 + ...` arithmetic is computing.
  var s1 = 0
  var s2 = 0
  while s1 < d1.edits.len and s2 < d2.edits.len:
    let e1 = d1.edits[s1]
    let e2 = d2.edits[s2]

    # Wholly before the other side's next edit: nobody disagrees.
    if e1.i1 + e1.c1 < e2.i1:
      result.append(1, e1.i1, e1.c1, e1.i2, e1.c2, e2.i2 - e2.i1 + e1.i1, e1.c1)
      inc s1
      continue
    if e2.i1 + e2.c1 < e1.i1:
      result.append(2, e2.i1, e2.c1, e1.i2 - e1.i1 + e2.i1, e2.c1, e2.i2, e2.c2)
      inc s2
      continue

    # They touch.  Identical edits of the identical base lines are not a
    # disagreement; anything else is.
    if e1.i1 != e2.i1 or e1.c1 != e2.c1 or e1.c2 != e2.c2 or
       not sameLines(d1.b, d2.b, e1.i2, e2.i2, e1.c2):
      # The conflicting region is the union of the two edits, expressed in all
      # three coordinate systems.  `off` and `ffo` are how far apart the two
      # edits start and end in the base; whichever side starts later has its
      # region extended backwards so that both cover the same base lines.
      let off = e1.i1 - e2.i1
      let ffo = off + e1.c1 - e2.c1
      var i0 = e1.i1
      var i1 = e1.i2
      var i2 = e2.i2
      if off > 0:
        i0 -= off
        i1 -= off
      else:
        i2 += off
      var chg0 = e1.i1 + e1.c1 - i0
      var chg1 = e1.i2 + e1.c2 - i1
      var chg2 = e2.i2 + e2.c2 - i2
      if ffo < 0:
        chg0 -= ffo
        chg1 -= ffo
      else:
        chg2 += ffo
      result.append(0, i0, chg0, i1, chg1, i2, chg2)

    # Advance whichever side ends first, or both if they end together.
    let end1 = e1.i1 + e1.c1
    let end2 = e2.i1 + e2.c1
    if end1 >= end2: inc s2
    if end2 >= end1: inc s1

  # One script ran out.  Everything left on the other is uncontested, and the
  # offset between the two sides is now fixed at the total each side inserted.
  while s1 < d1.edits.len:
    let e = d1.edits[s1]
    result.append(1, e.i1, e.c1, e.i2, e.c2, e.i1 + d2.b.len - d2.a.len, e.c1)
    inc s1
  while s2 < d2.edits.len:
    let e = d2.edits[s2]
    result.append(2, e.i1, e.c1, e.i1 + d1.b.len - d1.a.len, e.c1, e.i2, e.c2)
    inc s2

# ---------------------------------------------------------------------------
# The two refinements
# ---------------------------------------------------------------------------

proc refine(regions: var seq[Region], ours, theirs: seq[string]) =
  ## `xdl_refine_conflicts`: diff the two sides of each conflict against each
  ## other and keep only what genuinely differs.  One region becomes zero (the
  ## sides agreed), one, or several.
  ##
  ## The base coordinates are not recomputed, and in git they are not either:
  ## `i0`/`chg0` are read only by the `diff3` styles, which are cut.
  var out0: seq[Region]
  for m in regions:
    if m.mode != 0 or m.chg1 == 0 or m.chg2 == 0:
      out0.add m
      continue
    let d = diffRecords(ours[m.i1 ..< m.i1 + m.chg1].join(),
                        theirs[m.i2 ..< m.i2 + m.chg2].join())
    if d.edits.len == 0:
      # The two sides wrote the same thing by different routes.
      var identical = m
      identical.mode = 4
      out0.add identical
      continue
    for k, e in d.edits:
      out0.add Region(mode: 0,
                      i0: (if k == 0: m.i0 else: 0),
                      chg0: (if k == 0: m.chg0 else: 0),
                      i1: e.i1 + m.i1, chg1: e.c1,
                      i2: e.i2 + m.i2, chg2: e.c2)
  regions = out0

func containsAlnum(lines: seq[string], start, count: int): bool =
  ## Does any of the lines hold a letter or a digit?  What
  ## `XDL_MERGE_ZEALOUS_ALNUM` asks of a gap before keeping it.
  for i in start ..< start + count:
    for ch in lines[i]:
      if ch in {'0' .. '9', 'A' .. 'Z', 'a' .. 'z'}: return true
  false

proc simplify(regions: var seq[Region], ours: seq[string], alnum: bool) =
  ## `xdl_simplify_non_conflicts`: swallow a short gap between two conflicts.
  ##
  ## Refining is what creates the gaps -- it is the reason a single overlapping
  ## region can come back as three conflicts -- so this runs after it and
  ## partly undoes it, on the principle that fewer, larger conflicts read
  ## better than more, smaller ones separated by nothing.
  var i = 0
  while i + 1 < regions.len:
    let gapStart = regions[i].i1 + regions[i].chg1
    let gapEnd = regions[i + 1].i1
    if regions[i].mode != 0 or regions[i + 1].mode != 0 or
       (gapEnd - gapStart > 3 and
        (not alnum or ours.containsAlnum(gapStart, gapEnd - gapStart))):
      inc i
    else:
      regions[i].chg1 = regions[i + 1].i1 + regions[i + 1].chg1 - regions[i].i1
      regions[i].chg2 = regions[i + 1].i2 + regions[i + 1].chg2 - regions[i].i2
      regions.delete(i + 1)

# ---------------------------------------------------------------------------
# Emitting
# ---------------------------------------------------------------------------

func isEolCrlf(recs: seq[string], i: int): int =
  ## Does line `i` end in CRLF?  1 yes, 0 no, -1 unknowable -- which happens
  ## for a file with no lines, and for a single line with no terminator.
  ##
  ## The marker lines a conflict adds have to end the way the file does, or a
  ## CRLF file acquires three lone-LF lines in the middle of it.
  proc crlf(s: string): int = (if s.len > 1 and s[^2] == '\r': 1 else: 0)
  if recs.len == 0: return -1
  if i < recs.len - 1: return crlf(recs[i])   # every line but the last has one
  if recs[i].len > 0 and recs[i][^1] == '\n': return crlf(recs[i])
  if i == 0: return -1                         # the only line, unterminated
  crlf(recs[i - 1])

func needsCr(ours, theirs, base: seq[string], m: Region): bool =
  ## `is_cr_needed`.  Ask the line before the conflict on each side, then the
  ## base's first line, and stop at the first definite "LF only".  Note that
  ## "unknowable" keeps asking, which is why the test is `!= 0` and not `> 0`.
  var n = isEolCrlf(ours, if m.i1 != 0: m.i1 - 1 else: 0)
  if n != 0: n = isEolCrlf(theirs, if m.i2 != 0: m.i2 - 1 else: 0)
  if n != 0: n = isEolCrlf(base, 0)
  n > 0

func copyRecs(recs: seq[string], start, count: int,
              cr = false, addNl = false): string =
  ## Concatenate records, optionally terminating the last one.
  ##
  ## `addNl` is what stops a side whose last line has no newline from running
  ## into the `=======` that follows it -- the marker has to start a line even
  ## though the content did not end one.
  if count < 1: return
  for i in start ..< start + count: result.add recs[i]
  if addNl and (result.len == 0 or result[^1] != '\n'):
    if cr: result.add '\r'
    result.add '\n'

func marker(ch: char, size: int, label: string, cr: bool): string =
  ## One conflict marker line: the character `size` times, the label, and
  ## a CR when the file uses CRLF.
  result = repeat(ch, size)
  if label.len > 0: result.add ' ' & label
  if cr: result.add '\r'
  result.add '\n'

proc mergeText*(base, ours, theirs: string,
                labelOurs = "", labelTheirs = "",
                markerSize = defaultMarkerSize,
                level = mlZealous): tuple[text: string, conflicts: int] =
  ## Three texts in, one text and a conflict count out.  `xdl_merge`.
  ##
  ## A side that did not change the base at all short-circuits to the other
  ## side's bytes verbatim, which is not an optimisation: it is what makes a
  ## merge of an unchanged side byte-identical to that side even where the
  ## line splitting would not round-trip (a file with no final newline).
  let d1 = diffRecords(base, ours)
  if d1.edits.len == 0: return (theirs, 0)
  let d2 = diffRecords(base, theirs)
  if d2.edits.len == 0: return (ours, 0)

  var regions = buildRegions(d1, d2)
  regions.refine(d1.b, d2.b)
  regions.simplify(d1.b, level == mlZealousAlnum)

  var i = 0
  for m in regions:
    if m.mode == 4: continue
    result.text.add copyRecs(d1.b, i, m.i1 - i)   # the uncontested run before
    if m.mode == 0:
      inc result.conflicts
      let cr = needsCr(d1.b, d2.b, d1.a, m)
      result.text.add marker('<', markerSize, labelOurs, cr)
      result.text.add copyRecs(d1.b, m.i1, m.chg1, cr, addNl = true)
      result.text.add marker('=', markerSize, "", cr)
      result.text.add copyRecs(d2.b, m.i2, m.chg2, cr, addNl = true)
      result.text.add marker('>', markerSize, labelTheirs, cr)
    else:
      # Mode 3 -- both sides, in order -- can only arise from `append`
      # fusing a mode 1 and a mode 2 that did not overlap after all, so
      # ours needs a terminator before theirs begins.
      if (m.mode and 1) != 0:
        result.text.add copyRecs(d1.b, m.i1, m.chg1, needsCr(d1.b, d2.b, d1.a, m),
                                 addNl = (m.mode and 2) != 0)
      if (m.mode and 2) != 0:
        result.text.add copyRecs(d2.b, m.i2, m.chg2)
    i = m.i1 + m.chg1
  result.text.add copyRecs(d1.b, i, d1.b.len - i)
