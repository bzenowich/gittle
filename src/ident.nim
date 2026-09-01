## Who is writing, and when.
##
## Every reflog entry and (from phase 4) every commit and tag carries an
## identity line in git's `ident` format:
##
##     Alice Example <alice@example.com> 1788281927 -0400
##      \______ name ______/ \___ email ___/ \__ epoch __/ \tz/
##
## The timestamp is seconds since the epoch in UTC, followed by the writer's
## local offset from UTC, which is display information only -- it never changes
## what instant the entry refers to.  The offset is written the way a human
## would read it, so a writer four hours behind UTC records `-0400`.
##
## Where the name and email come from, in order (`ident.c`):
##
##   1. `GIT_COMMITTER_NAME` / `GIT_COMMITTER_EMAIL` (or the `AUTHOR` pair),
##   2. `user.name` / `user.email` from the configuration,
##   3. nothing -- and gittle refuses rather than inventing a plausible
##      identity, because an identity is written permanently into objects that
##      are named by their own hash.  git guesses from the hostname and marks
##      the result as implicit; that is a compatibility nicety v1 does without.
##
## `GIT_COMMITTER_DATE` / `GIT_AUTHOR_DATE` override the clock.  v1 accepts the
## raw `<epoch> <±hhmm>` form and ISO 8601, which is the cut from `docs/05`:
## git's free-form "approxidate" parser (`yesterday`, `3 weeks ago`) is several
## hundred lines on its own and buys nothing a script needs.

import std/[os, strutils, times]
import config, util

type
  IdentRole* = enum
    ## Which set of environment variables to consult.  A commit records both;
    ## a reflog entry records only the committer.
    irAuthor = "AUTHOR"
    irCommitter = "COMMITTER"

  Ident* = object
    name*: string
    email*: string
    when0*: int64   ## seconds since the epoch, UTC
    tzOffset*: int  ## minutes east of UTC, so -240 prints as `-0400`

func formatTz*(minutesEast: int): string =
  ## `-240` -> `-0400`.  Always four digits and always signed, which is what
  ## makes the ident line fixed-width enough to parse by splitting on spaces.
  let sign = if minutesEast < 0: '-' else: '+'
  let m = abs(minutesEast)
  sign & align($(m div 60), 2, '0') & align($(m mod 60), 2, '0')

func `$`*(id: Ident): string =
  ## The ident line as it is written into a reflog, a commit or a tag.
  id.name & " <" & id.email & "> " & $id.when0 & " " & formatTz(id.tzOffset)

proc parseTzOffset(s: string): int =
  ## `+0530` / `-0400` -> minutes east of UTC.
  failIf(s.len != 5 or s[0] notin {'+', '-'}, "bad timezone offset: " & s)
  for i in 1 .. 4:
    failIf(s[i] notin Digits, "bad timezone offset: " & s)
  let mag = parseInt(s[1 .. 2]) * 60 + parseInt(s[3 .. 4])
  if s[0] == '-': -mag else: mag

proc parseDate*(s: string): tuple[when0: int64, tzOffset: int] =
  ## The two date spellings v1 accepts.
  ##
  ## * git's internal form, `<epoch> <±hhmm>` -- what git itself writes, and
  ##   what a script that wants a reproducible commit passes in.
  ## * ISO 8601, `2026-09-01T12:00:00±hh:mm` (a space instead of `T`, and a
  ##   `Z` instead of an offset, both work).
  let t = s.strip()
  failIf(t.len == 0, "empty date")

  # <epoch> <±hhmm>
  let parts = t.splitWhitespace()
  if parts.len == 2 and parts[0].len > 0 and parts[0].allCharsInSet(Digits):
    return (parseBiggestInt(parts[0]).int64, parseTzOffset(parts[1]))

  # ISO 8601.  Nim's parser wants the shape spelled out, so try the plausible
  # ones rather than guessing.
  var iso = t.replace("Z", "+00:00")
  if iso.len > 10 and iso[10] == ' ': iso[10] = 'T'
  for fmt in ["yyyy-MM-dd'T'HH:mm:sszzz", "yyyy-MM-dd'T'HH:mm:ss'.'fffzzz",
              "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]:
    try:
      let dt = parse(iso, fmt)
      return (dt.toTime().toUnix(), -(dt.utcOffset div 60))
    except TimeParseError, ValueError:
      discard
  fail("cannot parse date: " & s)

proc nowStamp(): tuple[when0: int64, tzOffset: int] =
  let n = now()
  # Nim reports the offset in seconds *west* of UTC; git writes east.
  (n.toTime().toUnix(), -(n.utcOffset div 60))

proc getIdent*(cfg: Config, role: IdentRole): Ident =
  ## Resolve the identity to record, or explain what the user has to set.
  let prefix = "GIT_" & $role & "_"
  result.name = getEnv(prefix & "NAME", cfg.get("user.name"))
  result.email = getEnv(prefix & "EMAIL", cfg.get("user.email"))

  if result.name.len == 0 or result.email.len == 0:
    fail("unable to auto-detect an identity\n" &
         "  Set them explicitly:\n" &
         "    gittle config set --global user.name \"Your Name\"\n" &
         "    gittle config set --global user.email you@example.com")

  # An email is written between angle brackets and a name is written before
  # them, so neither may contain one; git strips these characters rather than
  # refusing, and so do we.
  result.name = result.name.multiReplace(("<", ""), (">", ""), ("\n", " "))
  result.email = result.email.multiReplace(("<", ""), (">", ""), ("\n", ""))

  let dateEnv = getEnv(prefix & "DATE")
  let stamp = if dateEnv.len > 0: parseDate(dateEnv) else: nowStamp()
  result.when0 = stamp.when0
  result.tzOffset = stamp.tzOffset
