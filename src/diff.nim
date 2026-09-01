## The diff engine: Myers, and the hunks that come out of it.
##
## This is a reimplementation of git's `xdiff/` in the one configuration gittle
## ships (R4: one diff algorithm).  It is written from the C rather than from
## the paper, and that is deliberate: the *algorithm* is Myers' and is in the
## paper, but which of several equally-minimal diffs gets printed is decided by
## three layers of post-processing that only the source describes.  A diff that
## is correct but lays its hunks out differently disagrees with git on every
## file it touches, which is a worse outcome than being slower.
##
## ## The five stages
##
## | | | |
## |---|---|---|
## | 1 | split and classify | every line gets an integer *class*; two lines share one exactly when git's `xdl_recmatch` would call them equal under the whitespace flags |
## | 2 | trim and discard | drop the common head and tail, then mark every line whose class occurs nowhere on the other side as changed -- it can never match, so the search need not carry it (`xprepare.c`) |
## | 3 | search | Myers from both ends at once, splitting at the meeting point and recursing (`xdiffi.c:xdl_split`, `xdl_recs_cmp`) |
## | 4 | compact | slide each run of changed lines as far as it will go, and choose where it lands (`xdiffi.c:xdl_change_compact`) |
## | 5 | emit | group changes into hunks, add context, find the enclosing "function" line (`xemit.c`) |
##
## Stage 4 is the one nobody expects. Between two identical lines a change can
## sit in several places -- adding a line to `a b b c` could report either `b`
## -- and the choice is what makes a patch readable or unreadable.  git slides
## every group as far down as it will go, then back up to whichever position
## scores best under the *indent heuristic*: a weighted measure of blank lines
## and indentation around the two split points, with the weights fitted against
## a corpus (`mhagger/diff-slider-tools`).  Skipping it changes the output on
## 3.7% of the commits in the repository next door, so the weights are copied
## rather than invented.
##
## ## Where gittle deliberately differs
##
## git's Myers is **not minimal by default.**  `xdl_split` gives up on an
## expensive box in two ways -- a "good enough" snake found past a cost
## threshold, and a hard cost ceiling -- and `xdl_cleanup_records` additionally
## discards lines that occur *too often* to be worth matching.  All three are
## accelerators for inputs far larger than gittle's targets (R3), and all three
## make the result non-minimal.  gittle implements the `need_min` path only,
## which is exactly what `git diff --minimal` selects.
##
## The consequence is measurable and is stated rather than hidden: on 2.5% of
## the commits in the repository next door, `git diff` and `git diff --minimal`
## disagree, and gittle prints the latter.  Both are correct patches for the
## same change.  The oracle compares against `--minimal` for that reason, the
## way it passes `--no-use-mailmap` for `log`.

import std/[strutils, tables]

# ---------------------------------------------------------------------------
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
    ## One file, prepared.  Lines are slices into `text` rather than copies:
    ## a diff of the reference repository's largest blob would otherwise
    ## allocate the file twice over.
    text: string
    lo, hi: seq[int]      ## line i is `text[lo[i] ..< hi[i]]`, newline excluded
    cls: seq[int]         ## its equivalence class
    changed: seq[bool]
    refIdx: seq[int]      ## the search's index space -> a line number

func nrec(s: Side): int = s.lo.len

func line(s: Side, i: int): string = s.text[s.lo[i] ..< s.hi[i]]

func chg(s: Side, i: int): bool =
  ## `changed` with git's two sentinels: the C code allocates the array with a
  ## slot at -1 and at N so the sliding loops need no bounds test, and every
  ## one of them relies on those slots reading false.
  i >= 0 and i < s.changed.len and s.changed[i]

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

proc classify(a, b: var Side, ws: WsMode) =
  ## Give every line an integer class, shared by exactly the lines that compare
  ## equal.  Everything downstream compares classes, so the whitespace rules
  ## and the cost of comparing long lines are both paid once, here.
  var ids = initTable[string, int]()

  proc classifyOne(s: var Side) =
    s.cls.setLen(s.nrec)
    for i in 0 ..< s.nrec:
      let key = normalize(s.line(i), ws)
      let found = ids.getOrDefault(key, -1)
      if found >= 0:
        s.cls[i] = found
      else:
        let id = ids.len
        ids[key] = id
        s.cls[i] = id

  classifyOne(a)
  classifyOne(b)

# ---------------------------------------------------------------------------
# 2. Trimming and discarding
# ---------------------------------------------------------------------------

proc prepare(a, b: var Side, ws: WsMode) =
  ## Stage 2.  Two reductions, both of which only remove work:
  ##
  ## **Trim** the matching head and tail (`xprepare.c:xdl_trim_ends`).  Most
  ## real edits touch a small part of a file, and Myers' cost is quadratic in
  ## the size of the box it searches.
  ##
  ## **Discard** any line whose class does not occur at all on the other side.
  ## It can never be part of a match, so marking it changed now and leaving it
  ## out of the search is exactly equivalent and much cheaper -- a file with a
  ## thousand new lines searches a box a thousand lines smaller.
  ##
  ## git does one more thing here that gittle does not: with the default
  ## (non-minimal) flags it *also* discards lines that occur very often, which
  ## is a speed heuristic that changes the answer.  See the module header.
  classify(a, b, ws)
  a.changed.setLen(a.nrec)
  b.changed.setLen(b.nrec)

  var start = 0
  let lim = min(a.nrec, b.nrec)
  while start < lim and a.cls[start] == b.cls[start]: inc start
  var tail = 0
  while tail < lim - start and
        a.cls[a.nrec - 1 - tail] == b.cls[b.nrec - 1 - tail]: inc tail

  # Counted over the *whole* file on each side, not over the trimmed region:
  # git's classifier counts every record before anything is trimmed
  # (`xprepare.c:xdl_classify_record`), so a line that also occurs in the
  # common head or tail is kept.  Counting the trimmed region instead discards
  # it, and the search then finds a different -- still minimal -- diff.
  var countA = initCountTable[int]()
  var countB = initCountTable[int]()
  for c in a.cls: countA.inc c
  for c in b.cls: countB.inc c

  for i in start ..< a.nrec - tail:
    if countB.getOrDefault(a.cls[i]) == 0: a.changed[i] = true
    else: a.refIdx.add i
  for i in start ..< b.nrec - tail:
    if countA.getOrDefault(b.cls[i]) == 0: b.changed[i] = true
    else: b.refIdx.add i

# ---------------------------------------------------------------------------
# 3. The search
# ---------------------------------------------------------------------------

type Splitter = object
  ## The K-vectors, one per direction, shared across the whole recursion.
  ## Indices are diagonals and run negative, so both are offset by `off`.
  kvdf, kvdb: seq[int]
  off: int

const lineMax = high(int)

proc splitBox(a, b: Side, sp: var Splitter, off1, lim1, off2, lim2: int):
    tuple[i1, i2: int] =
  ## The middle of Myers' divide and conquer (`xdiffi.c:xdl_split`).
  ##
  ## Grow a forward path from the top-left corner and a backward path from the
  ## bottom-right, one edit at a time, until they meet.  The meeting point is
  ## on *some* shortest edit path, so the box splits there and each half is a
  ## smaller instance of the same problem.  Searching from both ends is what
  ## makes the memory linear rather than quadratic: only the frontier of each
  ## path is kept, never the paths themselves.
  ##
  ## `odd` decides which of the two directions can detect the overlap, and it
  ## is a parity argument: a forward path of `d` edits and a backward path of
  ## `d` edits can only cross on a diagonal whose parity matches.
  let dmin = off1 - lim2
  let dmax = lim1 - off2
  let fmid = off1 - off2
  let bmid = lim1 - lim2
  let odd = ((fmid - bmid) and 1) != 0
  var fmin = fmid
  var fmax = fmid
  var bmin = bmid
  var bmax = bmid

  template f(d: int): var int = sp.kvdf[d + sp.off]
  template bk(d: int): var int = sp.kvdb[d + sp.off]

  f(fmid) = off1
  bk(bmid) = lim1

  while true:
    # Extend the band of diagonals by one, in the direction that is still
    # inside the box.  The `-1` and `lineMax` written past the new edge are
    # what let the core loop below compare neighbours without a bounds test.
    if fmin > dmin:
      dec fmin
      f(fmin - 1) = -1
    else: inc fmin
    if fmax < dmax:
      inc fmax
      f(fmax + 1) = -1
    else: dec fmax

    var d = fmax
    while d >= fmin:
      var i1 = if f(d - 1) >= f(d + 1): f(d - 1) + 1 else: f(d + 1)
      var i2 = i1 - d
      while i1 < lim1 and i2 < lim2 and
            a.cls[a.refIdx[i1]] == b.cls[b.refIdx[i2]]:
        inc i1
        inc i2
      f(d) = i1
      if odd and bmin <= d and d <= bmax and bk(d) <= i1:
        return (i1, i2)
      d -= 2

    if bmin > dmin:
      dec bmin
      bk(bmin - 1) = lineMax
    else: inc bmin
    if bmax < dmax:
      inc bmax
      bk(bmax + 1) = lineMax
    else: dec bmax

    d = bmax
    while d >= bmin:
      var i1 = if bk(d - 1) < bk(d + 1): bk(d - 1) else: bk(d + 1) - 1
      var i2 = i1 - d
      while i1 > off1 and i2 > off2 and
            a.cls[a.refIdx[i1 - 1]] == b.cls[b.refIdx[i2 - 1]]:
        dec i1
        dec i2
      bk(d) = i1
      if not odd and fmin <= d and d <= fmax and i1 <= f(d):
        return (i1, i2)
      d -= 2

proc recsCmp(a, b: var Side, sp: var Splitter,
             off1i, lim1i, off2i, lim2i: int) =
  ## Divide and conquer over the box, marking changed lines at the bottom of
  ## the recursion (`xdiffi.c:xdl_recs_cmp`).  Shrinking the box by its common
  ## head and tail first is not only a speed-up: it is what leaves an empty
  ## dimension to detect, which is the only place a line is ever *marked*.
  var off1 = off1i
  var lim1 = lim1i
  var off2 = off2i
  var lim2 = lim2i
  while off1 < lim1 and off2 < lim2 and
        a.cls[a.refIdx[off1]] == b.cls[b.refIdx[off2]]:
    inc off1
    inc off2
  while off1 < lim1 and off2 < lim2 and
        a.cls[a.refIdx[lim1 - 1]] == b.cls[b.refIdx[lim2 - 1]]:
    dec lim1
    dec lim2

  if off1 == lim1:
    for i in off2 ..< lim2: b.changed[b.refIdx[i]] = true
  elif off2 == lim2:
    for i in off1 ..< lim1: a.changed[a.refIdx[i]] = true
  else:
    let s = splitBox(a, b, sp, off1, lim1, off2, lim2)
    recsCmp(a, b, sp, off1, s.i1, off2, s.i2)
    recsCmp(a, b, sp, s.i1, lim1, s.i2, lim2)

proc runMyers(a, b: var Side) =
  if a.refIdx.len == 0 or b.refIdx.len == 0:
    for i in a.refIdx: a.changed[i] = true
    for i in b.refIdx: b.changed[i] = true
    return
  let ndiags = a.refIdx.len + b.refIdx.len + 3
  var sp = Splitter(kvdf: newSeq[int](ndiags + 2),
                    kvdb: newSeq[int](ndiags + 2),
                    off: b.refIdx.len + 1)
  recsCmp(a, b, sp, 0, a.refIdx.len, 0, b.refIdx.len)

# ---------------------------------------------------------------------------
# 4. Compaction, and where a change gets to sit
# ---------------------------------------------------------------------------

const
  # The weights `xdiffi.c` uses for the indent heuristic.  They were fitted
  # against a corpus (mhagger/diff-slider-tools) rather than derived, so they
  # are copied verbatim: inventing our own numbers here would produce a diff that is
  # readable in a different way from git's, which is the one outcome with no
  # value at all.
  maxIndent = 200
  maxBlanks = 20
  startOfFilePenalty = 1
  endOfFilePenalty = 21
  totalBlankWeight = -30
  postBlankWeight = 6
  relativeIndentPenalty = -4
  relativeIndentWithBlankPenalty = 10
  relativeOutdentPenalty = 24
  relativeOutdentWithBlankPenalty = 17
  relativeDedentPenalty = 23
  relativeDedentWithBlankPenalty = 17
  indentWeight = 60
  maxSliding = 100

func getIndent(s: Side, i: int): int =
  ## The line's indentation in columns, tabs counted to the next multiple of
  ## eight, or -1 for a line that is blank or entirely whitespace.
  var col = 0
  for k in s.lo[i] ..< s.hi[i]:
    let c = s.text[k]
    if c notin spaceChars: return col
    elif c == ' ': inc col
    elif c == '\t': col += 8 - col mod 8
    if col >= maxIndent: return maxIndent
  -1

type
  SplitMeasure = object
    endOfFile: bool
    indent: int      ## of the line just after the split, -1 if blank
    preBlank: int    ## blank lines immediately above
    preIndent: int   ## indent of the nearest non-blank line above
    postBlank: int   ## blank lines after the line following the split
    postIndent: int  ## indent of the nearest non-blank line after those
  SplitScore = object
    effectiveIndent: int
    penalty: int

func measureSplit(s: Side, split: int): SplitMeasure =
  if split >= s.nrec:
    result.endOfFile = true
    result.indent = -1
  else:
    result.indent = s.getIndent(split)
  result.preIndent = -1
  for i in countdown(split - 1, 0):
    result.preIndent = s.getIndent(i)
    if result.preIndent != -1: break
    inc result.preBlank
    if result.preBlank == maxBlanks:
      result.preIndent = 0
      break
  result.postIndent = -1
  for i in split + 1 ..< s.nrec:
    result.postIndent = s.getIndent(i)
    if result.postIndent != -1: break
    inc result.postBlank
    if result.postBlank == maxBlanks:
      result.postIndent = 0
      break

func addSplitScore(m: SplitMeasure, sc: var SplitScore) =
  ## How bad a place this is to cut, in git's units (`score_add_split`).
  ##
  ## The shape of it: blank lines around the cut are strongly *good*, the end
  ## of the file is bad, and a line indented differently from the one above it
  ## is bad in three different ways depending on whether it looks like the
  ## start of a block, the end of one, or neither.  That is what makes a hunk
  ## boundary land on a function boundary rather than three lines into one.
  if m.preIndent == -1 and m.preBlank == 0: sc.penalty += startOfFilePenalty
  if m.endOfFile: sc.penalty += endOfFilePenalty
  let postBlank = if m.indent == -1: 1 + m.postBlank else: 0
  let totalBlank = m.preBlank + postBlank
  sc.penalty += totalBlankWeight * totalBlank
  sc.penalty += postBlankWeight * postBlank
  let indent = if m.indent != -1: m.indent else: m.postIndent
  let anyBlanks = totalBlank != 0
  sc.effectiveIndent += indent
  if indent == -1 or m.preIndent == -1 or indent == m.preIndent:
    discard
  elif indent > m.preIndent:
    sc.penalty += (if anyBlanks: relativeIndentWithBlankPenalty
                   else: relativeIndentPenalty)
  elif m.postIndent != -1 and m.postIndent > indent:
    # Indented less than what precedes it but more than what follows: this
    # looks like the *start* of a block, so cutting here is worse.
    sc.penalty += (if anyBlanks: relativeOutdentWithBlankPenalty
                   else: relativeOutdentPenalty)
  else:
    sc.penalty += (if anyBlanks: relativeDedentWithBlankPenalty
                   else: relativeDedentPenalty)

func scoreCmp(a, b: SplitScore): int =
  let ci = (if a.effectiveIndent > b.effectiveIndent: 1
            elif a.effectiveIndent < b.effectiveIndent: -1 else: 0)
  indentWeight * ci + (a.penalty - b.penalty)

type Group = object
  start, stop: int   ## `stop` is the first unchanged line after the group

func groupInit(s: Side): Group =
  while s.chg(result.stop): inc result.stop

func groupNext(s: Side, g: var Group): bool =
  ## Move to the next (possibly empty) group; false at the end of the file.
  if g.stop == s.nrec: return false
  g.start = g.stop + 1
  g.stop = g.start
  while s.chg(g.stop): inc g.stop
  true

func groupPrevious(s: Side, g: var Group): bool =
  if g.start == 0: return false
  g.stop = g.start - 1
  g.start = g.stop
  while s.chg(g.start - 1): dec g.start
  true

func slideDown(s: var Side, g: var Group): bool =
  ## Move the group one line later, if the line just after it is the same as
  ## its first line -- in which case the two arrangements describe the same
  ## edit.  Running into a following group absorbs it.
  if g.stop < s.nrec and s.cls[g.start] == s.cls[g.stop]:
    s.changed[g.start] = false
    inc g.start
    s.changed[g.stop] = true
    inc g.stop
    while s.chg(g.stop): inc g.stop
    return true
  false

func slideUp(s: var Side, g: var Group): bool =
  if g.start > 0 and s.cls[g.start - 1] == s.cls[g.stop - 1]:
    dec g.start
    s.changed[g.start] = true
    dec g.stop
    s.changed[g.stop] = false
    while s.chg(g.start - 1): dec g.start
    return true
  false

proc changeCompact(s: var Side, o: var Side) =
  ## Slide every group of changed lines to where it reads best
  ## (`xdiffi.c:xdl_change_compact`).  Called once per side, with the other
  ## side passed as `o` so the two stay in step.
  ##
  ## Three rules, in order of precedence:
  ##
  ## 1. Slide up as far as possible, then down as far as possible, repeating
  ##    while the group keeps growing -- sliding can merge it with a neighbour,
  ##    and a merged group can slide further than either part could.
  ## 2. If some position lines this group up with a *changed* group on the
  ##    other side, take the last such position.  That is what keeps a modified
  ##    line printed as one `-`/`+` pair instead of a deletion here and an
  ##    insertion three lines away.
  ## 3. Otherwise score every reachable position with the indent heuristic and
  ##    take the best.
  var g = groupInit(s)
  var go = groupInit(o)
  while true:
    if g.stop != g.start:
      var groupSize = 0
      var earliestEnd = 0
      var endMatchingOther = -1
      while true:
        groupSize = g.stop - g.start
        endMatchingOther = -1
        while slideUp(s, g):
          discard groupPrevious(o, go)
        earliestEnd = g.stop
        if go.stop > go.start: endMatchingOther = g.stop
        while true:
          if not slideDown(s, g): break
          discard groupNext(o, go)
          if go.stop > go.start: endMatchingOther = g.stop
        if groupSize == g.stop - g.start: break

      if g.stop == earliestEnd:
        discard                                   # it could not be shifted
      elif endMatchingOther != -1:
        while go.stop == go.start:
          discard slideUp(s, g)
          discard groupPrevious(o, go)
      else:
        var bestShift = -1
        var bestScore: SplitScore
        var shift = max(earliestEnd, g.stop - groupSize - 1)
        shift = max(shift, g.stop - maxSliding)
        while shift <= g.stop:
          var score = SplitScore()
          addSplitScore(measureSplit(s, shift), score)
          addSplitScore(measureSplit(s, shift - groupSize), score)
          if bestShift == -1 or scoreCmp(score, bestScore) <= 0:
            bestScore = score
            bestShift = shift
          inc shift
        while g.stop > bestShift:
          discard slideUp(s, g)
          discard groupPrevious(o, go)

    if not groupNext(s, g): break
    discard groupNext(o, go)

# ---------------------------------------------------------------------------
# 5. The change script, and hunks
# ---------------------------------------------------------------------------

type
  Change = object
    ## One run of changed lines: `c1` lines removed at `i1`, `c2` added at
    ## `i2`.  Either count may be zero, which is what a pure insertion or
    ## deletion is.
    i1, i2, c1, c2: int

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

proc buildScript(a, b: Side): seq[Change] =
  ## Turn the two `changed` arrays into a list of changes, walked from the end
  ## so that the result comes out in order (`xdiffi.c:xdl_build_script`).
  var i1 = a.nrec
  var i2 = b.nrec
  while i1 >= 0 or i2 >= 0:
    if a.chg(i1 - 1) or b.chg(i2 - 1):
      let l1 = i1
      let l2 = i2
      while a.chg(i1 - 1): dec i1
      while b.chg(i2 - 1): dec i2
      result.add Change(i1: i1, i2: i2, c1: l1 - i1, c2: l2 - i2)
    dec i1
    dec i2
  for k in 0 ..< result.len div 2:
    swap(result[k], result[result.high - k])

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
  var old = oldText
  var newText = newTextIn
  if ctxLen == 0:
    let cut = trimCommonTail(old, newText)
    if cut > 0:
      old.setLen(old.len - cut)
      newText.setLen(newText.len - cut)
  splitLines(old, result.a)
  splitLines(newText, result.b)
  prepare(result.a, result.b, ws)
  runMyers(result.a, result.b)
  changeCompact(result.a, result.b)
  changeCompact(result.b, result.a)
  result.changes = buildScript(result.a, result.b)
  # Computed from the *trimmed* text, as git computes it from the trimmed
  # mmfile: a tail that was cut away always ended on a line boundary, so a
  # file that lost its unterminated last line no longer has one.
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
