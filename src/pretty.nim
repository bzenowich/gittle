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
## | `iso8601` | `2026-09-01 14:48:08 -0400` |
## | `iso8601-strict` | `2026-09-01T14:48:08-04:00` |
## | `rfc2822` | `Tue, 1 Sep 2026 14:48:08 -0400` |
## | `short` | `2026-09-01` |
## | `raw` | `1788288488 -0400` |
## | `unix` | `1788288488` |
##
## `relative`, `human` and `format:<strftime>` were removed in the
## minimization pass (docs/minimize.md §3, tier 3): display conveniences no
## script depends on, and a quarter of this module between them.
##
## ## Why the month and weekday names are here
##
## They are C-locale abbreviations, and the ones the system would give depend
## on `LC_TIME`.  A commit summary that reads `mar. 1 sept. 2026` in one
## person's terminal and not another's is a compatibility bug in a tool whose
## output gets parsed.

import std/[algorithm, strutils, times]
import color, commitobj, ident, oid, objects, refs, repository, util
export color

const
  weekdayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
  monthNames = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

type
  DateKind* = enum
    dkDefault, dkIso, dkIsoStrict, dkRfc, dkShort, dkRaw, dkUnix

  DateMode* = object
    kind*: DateKind
    local*: bool        ## render in *our* timezone, not the recorded one

proc parseDateMode*(spec: string): DateMode =
  ## `--date=<mode>[-local]`.  `relative`, `human` and `format:<strftime>`
  ## were removed in the minimization pass (docs/minimize.md §3, tier 3):
  ## each is a display convenience no script can depend on, and together
  ## they were a quarter of this module.
  var s = spec
  if s.endsWith("-local"):
    result.local = true
    s = s[0 ..< s.len - 6]
  result.kind = case s
    of "", "default", "normal": dkDefault
    of "local": (result.local = true; dkDefault)
    of "iso", "iso8601": dkIso
    of "iso-strict", "iso8601-strict": dkIsoStrict
    of "rfc", "rfc2822": dkRfc
    of "short": dkShort
    of "raw": dkRaw
    of "unix": dkUnix
    else:
      fail((if s in ["relative", "human"] or s.startsWith("format"):
              "--date=" & s & " is out of scope for gittle (docs/minimize.md §3)"
            else: "unknown date format '" & spec & "'"))

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

proc formatDate*(when0: int64, tzMinutes: int, mode: DateMode,
                 now0: int64): string =
  ## `now0` is passed in rather than read from the clock so that a single
  ## `log` renders every relative date against one instant, and so a test can
  ## pin it.
  if mode.kind == dkUnix: return $when0
  var tz = tzMinutes
  if mode.local: tz = localOffset(when0)
  if mode.kind == dkRaw: return $when0 & " " & tzString(tz)
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
    nulTerminate*: bool     ## `-z`: records end with NUL, not newline
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

proc headerName*(repo: Repository, o: Oid, opts: PrettyOpts): string =
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
                header = "", mark = ""): string =
  ## One commit, rendered.  `header` is what `show` puts before a commit that
  ## it reached through a tag; `mark` is `--left-right`'s `<` or `>`, which
  ## goes immediately before the object name -- so *after* the word `commit`
  ## on the formats that print one, and not at all under a user format
  ## (`log-tree.c:show_log`).
  let dec = if opts.decorate: decorations(repo, o) else: @[]
  let decText = if dec.len > 0: " (" & dec.join(", ") & ")" else: ""

  case opts.kind
  of pkFormat, pkTFormat:
    result = expandFormat(repo, o, c, opts.format, opts)
    # `format:` *separates* records and `tformat:` *terminates* them.  The
    # whole visible difference is the final newline, which is why
    # `log --pretty=format:%h > f` leaves a file with no newline at the end
    # and `tformat:` does not.  `entrySeparator` is the other half.
    if opts.kind == pkTFormat:
      result.add (if opts.nulTerminate: '\0' else: '\n')
    return
  of pkOneline:
    result.add mark & repo.headerName(o, opts)
    if opts.showParents:
      for p in c.parents: result.add " " & repo.headerName(p, opts)
    result.add decText & " " & subject(c.message) & "\n"
    return
  else: discard

  result.add "commit " & mark & repo.headerName(o, opts) & decText
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

func entrySeparator*(kind: PrettyKind, nulTerminate = false): string =
  ## What goes *between* two rendered commits.  The formats that terminate
  ## each entry with a newline need nothing; the ones that do not are
  ## separated by a blank line, which is why `log` has one between commits and
  ## `log --oneline` does not.
  ##
  ## `-z` replaces it with a NUL, because it sets git's `line_termination`
  ## for the whole of `log`, not only for the diff records
  ## (`log-tree.c:show_log`).
  if kind in {pkOneline, pkTFormat}: ""
  elif nulTerminate: "\0"
  else: "\n"
