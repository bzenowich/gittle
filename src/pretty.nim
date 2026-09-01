## How a commit is printed: dates, the built-in formats, `format:` and
## decoration.
##
## This is output formatting, which plan.md §2 identifies as a third of git and
## the reason its command layer is 97k lines.  It lives here rather than in
## `cmd/log.nim` for exactly that reason: `log`, `show`, `commit`'s summary
## line and (phase 6) `rev-list` all print commits, and the version that lives
## in a command file is the version the next command reimplements.
##
## ## Dates
##
## A commit records *two* things about time: the instant, as seconds since the
## epoch, and the writer's offset from UTC, which is display information only.
## Every format below renders the instant in the recorded offset, except
## `local`, which is the modifier that says "use mine instead".
##
## | `--date=` | example |
## |---|---|
## | `default` | `Tue Sep 1 14:48:08 2026 -0400` |
## | `relative` | `3 weeks ago` |
## | `iso8601` | `2026-09-01 14:48:08 -0400` |
## | `iso8601-strict` | `2026-09-01T14:48:08-04:00` |
## | `rfc2822` | `Tue, 1 Sep 2026 14:48:08 -0400` |
## | `short` | `2026-09-01` |
## | `raw` | `1788288488 -0400` |
## | `unix` | `1788288488` |
## | `human` | drops what the reader can infer -- see below |
## | `format:<strftime>` | whatever you asked for |
##
## `human` is the only one with judgement in it (`date.c:show_date_normal`): it
## drops the year when it is this year, the date as well when it is today, the
## timezone when it is yours, and the seconds always -- and a time today
## degrades to the relative form.  Reproduced rather than approximated, because
## an approximation is right until the reader is in a different month.
##
## ## Why the month and weekday names are here
##
## They are C-locale abbreviations, and the ones the system would give depend
## on `LC_TIME`.  A commit summary that reads `mar. 1 sept. 2026` in one
## person's terminal and not another's is a compatibility bug in a tool whose
## output gets parsed.

import std/[algorithm, posix, strutils, times]
import commitobj, ident, oid, objects, refs, repository, util

const
  weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  fullWeekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                      "Friday", "Saturday"]
  fullMonthNames = ["January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November",
                    "December"]

type
  DateKind* = enum
    dkDefault, dkRelative, dkIso, dkIsoStrict, dkRfc, dkShort, dkRaw,
    dkUnix, dkHuman, dkStrftime

  DateMode* = object
    kind*: DateKind
    local*: bool        ## render in *our* timezone, not the recorded one
    strftime*: string

proc parseDateMode*(spec: string): DateMode =
  ## `--date=<format>`, including the `-local` suffix every named format
  ## accepts (`date.c:parse_date_format`).
  var s = spec
  if s.endsWith("-local"):
    result.local = true
    s = s[0 ..< s.len - 6]
  if s.startsWith("format:") or s.startsWith("format-local:"):
    result.local = result.local or s.startsWith("format-local:")
    result.kind = dkStrftime
    result.strftime = s[s.find(':') + 1 .. ^1]
    return
  result.kind = case s
    of "", "default", "normal": dkDefault
    of "local": (result.local = true; dkDefault)
    of "relative": dkRelative
    of "iso", "iso8601": dkIso
    of "iso-strict", "iso8601-strict": dkIsoStrict
    of "rfc", "rfc2822": dkRfc
    of "short": dkShort
    of "raw": dkRaw
    of "unix": dkUnix
    of "human": dkHuman
    else: fail("unknown date format '" & spec & "'")

# ---------------------------------------------------------------------------
# Rendering one instant
# ---------------------------------------------------------------------------

type Broken = object
  year, mon, mday, hour, min, sec, wday, yday: int

proc breakDown(when0: int64, tzMinutes: int): Broken =
  ## The instant as seen from `tzMinutes` east of UTC.  Shifting the epoch and
  ## then decomposing in UTC is the whole trick: it keeps every timezone rule
  ## out of the calculation, which is right because the offset is *recorded*
  ## rather than looked up.
  let dt = utc(fromUnix(when0 + int64(tzMinutes) * 60))
  Broken(year: dt.year, mon: int(dt.month) - 1, mday: dt.monthday,
         hour: dt.hour, min: dt.minute, sec: dt.second,
         wday: (int(dt.weekday) + 1) mod 7, yday: dt.yearday)

func pad2(n: int): string = (if n < 10: "0" else: "") & $n

func tzString(tzMinutes: int): string = formatTz(tzMinutes)

proc localOffset(when0: int64): int =
  ## Our own offset at that instant, in minutes east -- what `-local` renders
  ## in, and what `human` compares against.
  -(local(fromUnix(when0)).utcOffset div 60)

proc relativeDate(when0, now0: int64): string =
  ## `date.c:show_date_relative`, unit for unit and rounding for rounding.
  ## The thresholds are not round numbers (90 seconds, 36 hours, 10 weeks) and
  ## every one of them shows up in output somebody compares.
  if now0 < when0: return "in the future"
  proc plural(n: int64, unit: string): string =
    $n & " " & unit & (if n == 1: "" else: "s") & " ago"
  var diff = now0 - when0
  if diff < 90: return plural(diff, "second")
  diff = (diff + 30) div 60
  if diff < 90: return plural(diff, "minute")
  diff = (diff + 30) div 60
  if diff < 36: return plural(diff, "hour")
  diff = (diff + 12) div 24
  if diff < 14: return plural(diff, "day")
  if diff < 70: return plural((diff + 3) div 7, "week")
  if diff < 365: return plural((diff + 15) div 30, "month")
  if diff < 1825:
    let totalMonths = (diff * 12 * 2 + 365) div (365 * 2)
    let years = totalMonths div 12
    let months = totalMonths mod 12
    if months == 0: return plural(years, "year")
    return $years & " year" & (if years == 1: "" else: "s") & ", " &
           $months & " month" & (if months == 1: "" else: "s") & " ago"
  plural((diff + 183) div 365, "year")

proc strftimeLike(fmt: string, b: Broken, tzMinutes: int,
                  when0: int64): string =
  ## The `format:` directives worth having, as a table (R7).  An unrecognised
  ## one is emitted verbatim rather than guessed at.
  var i = 0
  while i < fmt.len:
    if fmt[i] != '%' or i + 1 >= fmt.len:
      result.add fmt[i]
      inc i
      continue
    case fmt[i + 1]
    of 'Y': result.add $b.year
    of 'y': result.add pad2(b.year mod 100)
    of 'm': result.add pad2(b.mon + 1)
    of 'd': result.add pad2(b.mday)
    of 'e': result.add (if b.mday < 10: " " else: "") & $b.mday
    of 'H': result.add pad2(b.hour)
    of 'M': result.add pad2(b.min)
    of 'S': result.add pad2(b.sec)
    of 'a': result.add weekdayNames[b.wday]
    of 'A': result.add fullWeekdayNames[b.wday]
    of 'b', 'h': result.add monthNames[b.mon]
    of 'B': result.add fullMonthNames[b.mon]
    of 'j': result.add align($(b.yday + 1), 3, '0')
    of 'z': result.add tzString(tzMinutes)
    of 'F': result.add $b.year & "-" & pad2(b.mon + 1) & "-" & pad2(b.mday)
    of 'T': result.add pad2(b.hour) & ":" & pad2(b.min) & ":" & pad2(b.sec)
    of 's': result.add $when0
    of '%': result.add '%'
    else:
      result.add fmt[i]
      result.add fmt[i + 1]
    i += 2

proc humanDate(b: Broken, tzMinutes: int, when0, now0: int64): string =
  ## `date.c:show_date_normal` with the "human" comparison filled in: drop
  ## whatever the reader can infer from today's date, and fall back to the
  ## relative form for anything from today.
  let nowTz = localOffset(now0)
  let n = breakDown(now0, nowTz)
  var hideTz = tzMinutes == nowTz
  let hideYear = b.year == n.year
  var hideDate = false
  var hideWday = false
  if hideYear and b.mon == n.mon:
    if b.mday > n.mday: discard          # in the future: leave everything on
    elif b.mday == n.mday: (hideDate = true; hideWday = true)
    elif b.mday + 5 > n.mday: hideDate = true
  # Anything from today degrades to the relative form, which is more useful
  # than a clock time the reader can already see.
  if hideWday: return relativeDate(when0, now0)
  # Seconds always go; the timezone goes whenever the date is shown; and the
  # weekday *and* the time go whenever the year has to be shown, because a
  # date that old makes the hour noise.
  hideTz = hideTz or not hideDate
  hideWday = not hideYear
  let hideTime = not hideYear
  if not hideWday: result.add weekdayNames[b.wday] & " "
  if not hideDate: result.add monthNames[b.mon] & " " & $b.mday & " "
  if not hideTime: result.add pad2(b.hour) & ":" & pad2(b.min)
  else: result = result.strip(leading = false)
  if not hideYear: result.add " " & $b.year
  if not hideTz: result.add " " & tzString(tzMinutes)

proc formatDate*(when0: int64, tzMinutes: int, mode: DateMode,
                 now0: int64): string =
  ## `now0` is passed in rather than read from the clock so that a single
  ## `log` renders every relative date against one instant, and so a test can
  ## pin it.
  if mode.kind == dkUnix: return $when0
  var tz = tzMinutes
  if mode.local: tz = localOffset(when0)
  if mode.kind == dkRaw: return $when0 & " " & tzString(tz)
  if mode.kind == dkRelative: return relativeDate(when0, now0)
  let b = breakDown(when0, tz)
  case mode.kind
  of dkShort:
    $b.year & "-" & pad2(b.mon + 1) & "-" & pad2(b.mday)
  of dkIso:
    $b.year & "-" & pad2(b.mon + 1) & "-" & pad2(b.mday) & " " &
      pad2(b.hour) & ":" & pad2(b.min) & ":" & pad2(b.sec) & " " & tzString(tz)
  of dkIsoStrict:
    let stamp = $b.year & "-" & pad2(b.mon + 1) & "-" & pad2(b.mday) & "T" &
                pad2(b.hour) & ":" & pad2(b.min) & ":" & pad2(b.sec)
    if tz == 0: stamp & "Z"
    else:
      let s = tzString(tz)
      stamp & s[0 .. 2] & ":" & s[3 .. 4]
  of dkRfc:
    weekdayNames[b.wday] & ", " & $b.mday & " " & monthNames[b.mon] & " " &
      $b.year & " " & pad2(b.hour) & ":" & pad2(b.min) & ":" & pad2(b.sec) &
      " " & tzString(tz)
  of dkStrftime:
    strftimeLike(mode.strftime, b, tz, when0)
  of dkHuman:
    humanDate(b, tz, when0, now0)
  else:
    # The default format, and the one place `-local` changes more than the
    # numbers: rendering in the reader's own zone makes the offset noise, so
    # git drops it (`date.c:show_date_normal`, `hide.tz = local`).
    weekdayNames[b.wday] & " " & monthNames[b.mon] & " " & $b.mday & " " &
      pad2(b.hour) & ":" & pad2(b.min) & ":" & pad2(b.sec) & " " & $b.year &
      (if mode.local: "" else: " " & tzString(tz))

# ---------------------------------------------------------------------------
# Decoration
# ---------------------------------------------------------------------------

proc decorations(repo: Repository, o: Oid): seq[string] =
  ## The refs pointing at this commit, as `log --decorate` names them:
  ## `HEAD -> main`, `tag: v1.0`, `origin/main`.
  ##
  ## An annotated tag decorates the commit it *peels to*, not the tag object,
  ## which is why the peel happens here and not in the caller.
  let head = repo.refs.readRef(headRef)
  var headBranch = ""
  if head.found and head.isSymbolic: headBranch = head.symTarget
  var branches, remotes, tags: seq[string]
  for r in repo.refs.allRefs():
    var target = r.oid
    if r.name.startsWith("refs/tags/"):
      # A lightweight tag names the commit already; an annotated one names a
      # tag object that has to be followed.
      try:
        if repo.objectInfo(target).kind == otTag:
          target = repo.peelTo(target, otCommit).oid
      except GittleError: discard
      if target == o: tags.add "tag: " & r.name["refs/tags/".len .. ^1]
    elif r.oid != o: continue
    elif r.name.startsWith("refs/heads/"):
      let short = r.name["refs/heads/".len .. ^1]
      if r.name == headBranch: branches.insert("HEAD -> " & short, 0)
      else: branches.add short
    elif r.name.startsWith("refs/remotes/"):
      remotes.add r.name["refs/remotes/".len .. ^1]
    else:
      branches.add r.name
  # Detached HEAD points at an object directly and decorates as bare `HEAD`.
  if headBranch.len == 0 and head.found and head.oid == o:
    result.add "HEAD"
  sort(tags)
  result.add branches
  result.add tags
  result.add remotes

# ---------------------------------------------------------------------------
# Commit formatting
# ---------------------------------------------------------------------------

type
  PrettyKind* = enum
    pkOneline, pkMedium, pkFull, pkFuller, pkRaw, pkFormat, pkTFormat

  PrettyOpts* = object
    kind*: PrettyKind
    format*: string        ## the user string, for `pkFormat`/`pkTFormat`
    dateMode*: DateMode
    abbrev*: int           ## how many digits an abbreviation starts at
    abbrevCommit*: bool    ## abbreviate the object name in the header line
    decorate*: bool
    showParents*: bool
    now*: int64

proc parsePretty*(spec: string, opts: var PrettyOpts) =
  ## `--pretty=<what>`.  The built-ins are a small closed set; anything with a
  ## `format:` or `tformat:` prefix is a user format, and a bare unknown word
  ## is refused rather than silently treated as one.
  if spec.startsWith("format:"):
    opts.kind = pkFormat
    opts.format = spec["format:".len .. ^1]
  elif spec.startsWith("tformat:"):
    opts.kind = pkTFormat
    opts.format = spec["tformat:".len .. ^1]
  else:
    opts.kind = case spec
      of "", "medium": pkMedium
      of "oneline": pkOneline
      of "full": pkFull
      of "fuller": pkFuller
      of "raw": pkRaw
      of "short", "reference", "email", "mboxrd":
        fail("--pretty=" & spec & " is out of scope for gittle v1 (docs/04)")
      else:
        # git treats an unrecognised word as an implicit `tformat:`, which is
        # how `--pretty=%h` works.
        opts.format = spec
        pkTFormat

func expandTabs(line: string, tabWidth = 8): string =
  ## Tabs in a log message become spaces to the next tab stop -- and the stop
  ## is counted from the start of the *message* line, not from the start of the
  ## output line, so the four-space indent does not shift it
  ## (`pretty.c:strbuf_add_tabexpand`).
  ##
  ## This is on by default for every format that indents the message, which is
  ## why `--expand-tabs` being out of scope (docs/04) does not mean "emit the
  ## tab": the default *is* expansion, and `--no-expand-tabs` is the option.
  ##
  ## Width is counted in UTF-8 code points.  git measures display width, so a
  ## double-width character in the same line as a tab aligns differently; that
  ## costs a column in a rare case and saves a character-width table.
  var width = 0
  for ch in line:
    if ch == '\t':
      let pad = tabWidth - (width mod tabWidth)
      for _ in 1 .. pad: result.add ' '
      width += pad
    else:
      result.add ch
      if (uint8(ch) and 0xC0'u8) != 0x80'u8: inc width

func indented(msg: string, tabWidth: int): string =
  ## The message as `log` shows it (`pretty.c:pp_remainder`), which is three
  ## rules rather than one:
  ##
  ## * every line is prefixed with four spaces, **including** the empty ones,
  ##   so a blank line in the message is four spaces and a newline;
  ## * every line loses its trailing whitespace;
  ## * blank lines *before* the first real line are dropped entirely.
  ##
  ## `tabWidth` is 8 for the formats git gives it to -- medium, full and
  ## fuller -- and 0 for `raw`, which prints the tab (`pretty.c`'s
  ## `builtin_formats` table).
  var first = true
  var i = 0
  while i < msg.len:
    let eol = msg.find('\n', i)
    let stop = if eol < 0: msg.len else: eol
    var n = stop
    while n > i and msg[n - 1] in Whitespace: dec n
    let line = msg[i ..< n]
    i = (if eol < 0: msg.len else: eol + 1)
    if line.len == 0 and first: continue
    first = false
    result.add "    " & (if tabWidth > 0: expandTabs(line, tabWidth) else: line) & "\n"

proc nameOf(repo: Repository, o: Oid, abbrev: int): string =
  if abbrev <= 0: $o else: repo.uniqueAbbrev(o, abbrev)

proc headerName(repo: Repository, o: Oid, opts: PrettyOpts): string =
  ## The object name in a `commit` or `oneline` line.
  ##
  ## `--abbrev=<n>` alone does **not** shorten it: that option sets the
  ## *length* abbreviations use, and `--abbrev-commit` is what turns the header
  ## abbreviation on.  `%h` and the `Merge:` line abbreviate either way, which
  ## is why `log --abbrev=12` changes those two and nothing else.
  if opts.abbrevCommit: repo.uniqueAbbrev(o, opts.abbrev) else: $o

proc expandFormat(repo: Repository, o: Oid, c: Commit, fmt: string,
                  opts: PrettyOpts): string =
  ## The `format:` placeholder vocabulary.  Unknown placeholders are emitted
  ## verbatim, which is git's behavior and keeps a format string containing a
  ## literal `%` from being an error.
  var i = 0
  while i < fmt.len:
    if fmt[i] != '%':
      result.add fmt[i]
      inc i
      continue
    if i + 1 >= fmt.len:
      result.add '%'
      inc i
      continue
    let two = if i + 2 < fmt.len: fmt[i+1 .. i+2] else: ""
    var used = 2
    case fmt[i + 1]
    of 'H': result.add $o
    of 'h': result.add repo.uniqueAbbrev(o, opts.abbrev)
    of 'T': result.add $c.tree
    of 't': result.add repo.uniqueAbbrev(c.tree, opts.abbrev)
    of 'P':
      for k, p in c.parents:
        if k > 0: result.add ' '
        result.add $p
    of 'p':
      for k, p in c.parents:
        if k > 0: result.add ' '
        result.add repo.uniqueAbbrev(p, opts.abbrev)
    of 's': result.add subject(c.message)
    of 'f':
      # The subject "sanitised for a filename" (`pretty.c:format_sanitized_
      # subject`): runs of anything but a letter, digit, `.` or `_` become one
      # dash, with no dash at either end -- so it can be a file name without
      # further quoting, which is what `format-patch` uses it for.
      let start = result.len
      var space = 2       # 2 means "at the start", so no leading dash
      let subj = subjectLine(c.message)
      var k = 0
      while k < subj.len:
        let ch = subj[k]
        if ch.isAlphaNumeric or ch == '.' or ch == '_':
          if space == 1: result.add '-'
          space = 0
          result.add ch
          # A run of dots collapses to one: `...` in a subject would otherwise
          # survive into something meant to be a file name.
          if ch == '.':
            while k + 1 < subj.len and subj[k + 1] == '.': inc k
        else: space = space or 1
        inc k
      while result.len > start and result[^1] in {'.', '-'}:
        result.setLen(result.len - 1)
    of 'b': result.add body(c.message)
    of 'B': result.add c.message
    of 'e': discard          # encoding; gittle writes only UTF-8
    of 'n': result.add '\n'
    of '%': result.add '%'
    of 'd':
      let d = decorations(repo, o)
      if d.len > 0: result.add " (" & d.join(", ") & ")"
    of 'D': result.add decorations(repo, o).join(", ")
    of 'x':
      if i + 3 < fmt.len:
        try:
          result.add char(parseHexInt(fmt[i+2 .. i+3]))
          used = 4
        except ValueError:
          result.add fmt[i]
          used = 1
      else:
        result.add fmt[i]
        used = 1
    of 'a', 'c':
      let id = if fmt[i + 1] == 'a': c.author else: c.committer
      if i + 2 >= fmt.len:
        result.add fmt[i]
        used = 1
      else:
        case fmt[i + 2]
        of 'n', 'N': result.add id.name
        of 'e', 'E': result.add id.email
        of 'd': result.add formatDate(id.when0, id.tzOffset, opts.dateMode, opts.now)
        of 'D': result.add formatDate(id.when0, id.tzOffset,
                                      DateMode(kind: dkRfc), opts.now)
        of 'r': result.add relativeDate(id.when0, opts.now)
        of 't': result.add $id.when0
        of 'i': result.add formatDate(id.when0, id.tzOffset,
                                      DateMode(kind: dkIso), opts.now)
        of 'I': result.add formatDate(id.when0, id.tzOffset,
                                      DateMode(kind: dkIsoStrict), opts.now)
        of 's': result.add formatDate(id.when0, id.tzOffset,
                                      DateMode(kind: dkShort), opts.now)
        else:
          result.add two
        used = 3
    else:
      result.add fmt[i]
      used = 1
    i += used

proc identLine(id: Ident, line: string): string =
  ## `Name <email>`, from the bytes as stored where possible: an ident line git
  ## wrote is what should be printed back, and reassembling one from the parse
  ## would normalise away whatever oddity it had.  The two trailing fields are
  ## the timestamp and the offset, which the header lines render separately.
  let gt = line.rfind('>')
  if gt >= 0: return line[0 .. gt]
  id.name & " <" & id.email & ">"

proc formatOne*(repo: Repository, o: Oid, c: Commit, opts: PrettyOpts,
                header = ""): string =
  ## One commit, rendered.  `header` is what `show` puts before a commit that
  ## it reached through a tag.
  let dec = if opts.decorate: decorations(repo, o) else: @[]
  let decText = if dec.len > 0: " (" & dec.join(", ") & ")" else: ""

  case opts.kind
  of pkFormat, pkTFormat:
    result = expandFormat(repo, o, c, opts.format, opts)
    # `format:` *separates* records and `tformat:` *terminates* them.  The
    # whole visible difference is the final newline, which is why
    # `log --pretty=format:%h > f` leaves a file with no newline at the end
    # and `tformat:` does not.  `entrySeparator` is the other half.
    if opts.kind == pkTFormat: result.add "\n"
    return
  of pkOneline:
    result.add repo.headerName(o, opts)
    result.add decText & " " & subject(c.message) & "\n"
    return
  else: discard

  result.add "commit " & repo.headerName(o, opts) & decText
  if opts.showParents:
    for p in c.parents: result.add " " & repo.headerName(p, opts)
  result.add "\n"
  result.add header
  # `Merge:` marks a commit with more than one parent, and it is the only place
  # the built-in formats mention parents at all.  Not in `raw`, which already
  # shows every `parent` header verbatim.
  if c.parents.len > 1 and opts.kind != pkRaw:
    result.add "Merge:"
    for p in c.parents: result.add " " & repo.uniqueAbbrev(p, opts.abbrev)
    result.add "\n"
  case opts.kind
  of pkRaw:
    # Every header, verbatim.  Reconstructing the four gittle understands
    # would drop `gpgsig`, `mergetag` and `encoding` -- and `raw` exists
    # precisely so nothing is dropped.
    result.add c.headers
  of pkFull:
    result.add "Author: " & identLine(c.author, c.authorLine) & "\n"
    result.add "Commit: " & identLine(c.committer, c.committerLine) & "\n"
  of pkFuller:
    result.add "Author:     " & identLine(c.author, c.authorLine) & "\n"
    result.add "AuthorDate: " &
               formatDate(c.author.when0, c.author.tzOffset, opts.dateMode,
                          opts.now) & "\n"
    result.add "Commit:     " & identLine(c.committer, c.committerLine) & "\n"
    result.add "CommitDate: " &
               formatDate(c.committer.when0, c.committer.tzOffset,
                          opts.dateMode, opts.now) & "\n"
  else:
    result.add "Author: " & identLine(c.author, c.authorLine) & "\n"
    result.add "Date:   " &
               formatDate(c.author.when0, c.author.tzOffset, opts.dateMode,
                          opts.now) & "\n"
  result.add "\n"
  result.add indented(c.message, if opts.kind == pkRaw: 0 else: 8)
  # git trims trailing whitespace off the *whole* rendered commit and then puts
  # back exactly one newline (`pretty.c:pretty_print_commit`: `strbuf_rtrim`
  # then `strbuf_addch('\n')`).  That is what removes the four-space indent a
  # message's trailing blank line would otherwise leave behind, and what makes
  # a commit with an empty message print with no blank line under its headers.
  result = result.strip(leading = false)
  result.add "\n"

func entrySeparator*(kind: PrettyKind): string =
  ## What goes *between* two rendered commits.  The formats that terminate
  ## each entry with a newline need nothing; the ones that do not are
  ## separated by a blank line, which is why `log` has one between commits and
  ## `log --oneline` does not.
  if kind in {pkOneline, pkTFormat}: "" else: "\n"

proc isTty*(): bool =
  ## `--decorate=auto` and `--color=auto` both ask this.  Decoration is for a
  ## human reading a terminal; a pipe is a program, and a program parsing
  ## `log` output should not have to strip ref names it never asked for.
  isatty(stdout.getFileHandle()) != 0
