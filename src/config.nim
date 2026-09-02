## The configuration file subset: a flat INI parser.
##
## Sections and variable names are case-insensitive and are folded to lower
## case; a subsection name keeps its case.  Keys are therefore stored as
## `section.subsection.variable`, which is exactly the name `git config` takes.
## Not supported: `include.path` / `includeIf` (v1 has no use for them).

import std/[strutils, os]
import util

type
  ConfigEntry* = object
    key*: string
    value*: string
    isBool*: bool  ## the variable appeared with no `=`, meaning true

  Config* = object
    entries*: seq[ConfigEntry]

func isNameChar(c: char): bool =
  ## May the character appear in a variable name?  (`config.c:iskeychar`)
  c.isAlphaNumeric or c == '-'

# ---------------------------------------------------------------------------
# One pass over the lines, two consumers
# ---------------------------------------------------------------------------
#
# Reading a configuration file and *editing* one need the same thing: which
# line is a section header, which is a variable, and which section is in force.
# The reader then parses values; the editor replaces a line.  Scanning once and
# sharing the result keeps the two from drifting apart -- a variable the reader
# sees and the editor does not is a `config set` that silently adds a duplicate.

type
  LineKind = enum lkOther, lkSection, lkVariable

  ScannedLine = object
    kind: LineKind
    section: string     ## the section in force here, lowercased
    subsection: string  ## its subsection, case preserved -- git treats
                        ## `[remote "Origin"]` and `[remote "origin"]` as two
    hasSub: bool
    name: string        ## for lkVariable, the lowercased variable name
    indent: string      ## whatever whitespace the author used
    keyText: string     ## the name exactly as written, so an edit can keep it
    valueAt: int        ## where the value starts, or -1 for an implicit true

proc scanLines(lines: openArray[string], path: string): seq[ScannedLine] =
  ## Classify every line -- section header, variable, or other -- and carry
  ## the current section along, so an edit knows where it stands.
  var section = ""
  var subsection = ""
  var hasSub = false
  for lineNo, line in lines.pairs:
    var sl = ScannedLine(kind: lkOther, section: section,
                         subsection: subsection, hasSub: hasSub, valueAt: -1)
    var i = 0
    while i < line.len and line[i] in {' ', '\t'}: inc i

    if i < line.len and line[i] notin {'#', ';'}:
      if line[i] == '[':
        inc i
        let nameStart = i
        while i < line.len and (isNameChar(line[i]) or line[i] == '.'): inc i
        section = line[nameStart ..< i].toLowerAscii
        subsection = ""
        hasSub = false
        while i < line.len and line[i] in {' ', '\t'}: inc i
        if i < line.len and line[i] == '"':
          inc i
          while i < line.len and line[i] != '"':
            if line[i] == '\\' and i + 1 < line.len: inc i
            subsection.add line[i]
            inc i
          failIf(i >= line.len,
                 path & ":" & $(lineNo + 1) & ": unterminated subsection")
          inc i
          hasSub = true
          while i < line.len and line[i] in {' ', '\t'}: inc i
        failIf(i >= line.len or line[i] != ']',
               path & ":" & $(lineNo + 1) & ": bad section header")
        sl = ScannedLine(kind: lkSection, section: section,
                         subsection: subsection, hasSub: hasSub, valueAt: -1)
      else:
        let nameStart = i
        while i < line.len and isNameChar(line[i]): inc i
        if i > nameStart:
          sl.kind = lkVariable
          sl.name = line[nameStart ..< i].toLowerAscii
          sl.indent = line[0 ..< nameStart]
          sl.keyText = line[nameStart ..< i]
          while i < line.len and line[i] in {' ', '\t'}: inc i
          # No `=` at all is an implicit true; anything else here is malformed.
          if i < line.len:
            failIf(line[i] != '=',
                   path & ":" & $(lineNo + 1) & ": bad config line")
            inc i
            while i < line.len and line[i] in {' ', '\t'}: inc i
            sl.valueAt = i
    result.add sl

func fullSection(sl: ScannedLine): string =
  ## `section` or `section.subsection`, lower-cased as git compares them.
  if sl.hasSub: sl.section & "." & sl.subsection else: sl.section

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc parseValue(line: string, start: int, path: string, lineNo: int,
                more: var bool): string =
  ## Read a value starting at `start`.
  ##
  ## Quoting protects leading and trailing whitespace and the comment
  ## characters; a backslash at end of line continues onto the next, which
  ## `more` reports.
  var i = start
  var quoted = false
  var lastNonSpace = -1
  while i < line.len:
    let c = line[i]
    if c == '"':
      quoted = not quoted
      inc i
      lastNonSpace = result.len
      continue
    if not quoted and (c == '#' or c == ';'):
      break
    if c == '\\':
      inc i
      if i >= line.len:
        more = true
        break
      let e = line[i]
      inc i
      case e
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'b': result.add '\b'
      of '\\': result.add '\\'
      of '"': result.add '"'
      else: fail(path & ":" & $lineNo & ": bad escape '\\" & e & "'")
      lastNonSpace = result.len
      continue
    result.add c
    if quoted or c notin {' ', '\t'}: lastNonSpace = result.len
    inc i
  failIf(quoted, path & ":" & $lineNo & ": unterminated quote")
  result.setLen(max(lastNonSpace, 0))

proc parseConfig*(text, path: string): Config =
  ## The whole parse: `scanLines`, then each variable line into an entry,
  ## with continuation lines joined.
  let lines = text.splitLines
  let scanned = scanLines(lines, path)
  var i = 0
  while i < lines.len:
    let sl = scanned[i]
    if sl.kind != lkVariable:
      inc i
      continue
    failIf(sl.section.len == 0,
           path & ":" & $(i + 1) & ": variable outside a section")
    let key = fullSection(sl) & "." & sl.name
    if sl.valueAt < 0:
      result.entries.add ConfigEntry(key: key, value: "true", isBool: true)
    else:
      var more = false
      var v = parseValue(lines[i], sl.valueAt, path, i + 1, more)
      while more and i + 1 < lines.len:
        inc i
        more = false
        v.add parseValue(lines[i], 0, path, i + 1, more)
      result.entries.add ConfigEntry(key: key, value: v)
    inc i

proc globalConfigPath*(): string =
  ## The user's own configuration file.
  ##
  ## `~/.gitconfig` if it exists, otherwise the XDG location; if neither
  ## exists, `~/.gitconfig`, because that is where a new one should go.
  ## `GIT_CONFIG_GLOBAL` overrides both, which is what lets a test run against
  ## a controlled configuration instead of the developer's own.
  let env = getEnv("GIT_CONFIG_GLOBAL")
  if env.len > 0: return env
  let home = getHomeDir()
  let classic = home / ".gitconfig"
  if fileExists(classic): return classic
  let xdg = getEnv("XDG_CONFIG_HOME", home / ".config") / "git" / "config"
  if fileExists(xdg): return xdg
  classic

proc loadConfig*(path: string): Config =
  ## Parse a file, or nothing when it does not exist -- an absent config
  ## file is an empty one.
  if not fileExists(path): return
  parseConfig(readWholeFile(path), path)

proc add*(c: var Config, other: Config) =
  ## Later entries win, which is git's own last-one-wins rule.
  c.entries.add other.entries

proc get*(c: Config, key: string): string =
  ## The last value set for `key`, or "" if unset.
  let k = key.toLowerAscii
  for i in countdown(c.entries.high, 0):
    if c.entries[i].key.toLowerAscii == k: return c.entries[i].value
  ""

iterator getAll*(c: Config, key: string): string =
  ## Every value set for `key`, in file order.  Most variables are
  ## last-one-wins, but a few are genuinely lists -- a remote may have several
  ## `fetch` refspecs, and taking only the last would silently stop tracking
  ## most of them.
  let k = key.toLowerAscii
  for e in c.entries:
    if e.key.toLowerAscii == k: yield e.value

proc has*(c: Config, key: string): bool =
  ## Is the key set at all?  Distinct from `get`, since an empty value is
  ## legal.
  let k = key.toLowerAscii
  for e in c.entries:
    if e.key.toLowerAscii == k: return true
  false

proc getBool*(c: Config, key: string, default: bool): bool =
  ## A boolean the way git reads one: `true`/`yes`/`on`/`1` and the bare
  ## key, `false`/`no`/`off`/`0`; anything else is the default.
  if not c.has(key): return default
  case c.get(key).toLowerAscii
  of "true", "yes", "on", "1", "": true
  of "false", "no", "off", "0": false
  else: default

proc getInt*(c: Config, key: string, default: int): int =
  ## An integer, or the default when unset or malformed.
  if not c.has(key): return default
  try: parseInt(c.get(key).strip()) except ValueError: default

iterator withPrefix*(c: Config, prefix: string): ConfigEntry =
  ## Every entry whose key starts with `prefix.` -- how the extension gate
  ## walks `extensions.*`.
  let p = prefix.toLowerAscii & "."
  for e in c.entries:
    if e.key.toLowerAscii.startsWith(p): yield e

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------
#
# Setting a variable is a *line edit*, not a re-serialization.  A configuration
# file is written by hand as often as by a tool: it carries comments, chosen
# indentation, section ordering and blank lines that mean something to whoever
# wrote them.  Parsing it into a table and printing the table back out would be
# far less code and would quietly destroy all of that, so instead the file is
# read as lines, the one line that matters is replaced, and everything else is
# handed back untouched.

type
  SplitKey* = object
    ## `remote.origin.url` -> section `remote`, subsection `origin`, name `url`.
    ##
    ## The split is by *first* and *last* dot, not by every dot: a subsection is
    ## usually a remote or branch name and may contain dots of its own, as
    ## `branch.release.2.x.merge` does.
    section*: string
    subsection*: string
    hasSub*: bool
    name*: string

proc splitKey*(key: string): SplitKey =
  ## `section.subsection.name` taken apart, with git's rule that the
  ## subsection is everything between the first and last dot, case kept.
  let first = key.find('.')
  failIf(first <= 0, "key does not contain a section: " & key)
  let last = key.rfind('.')
  failIf(last == key.len - 1, "key does not contain a variable name: " & key)
  result.section = key[0 ..< first].toLowerAscii
  result.name = key[last + 1 .. ^1].toLowerAscii
  if last > first:
    result.subsection = key[first + 1 ..< last]
    result.hasSub = true

func quoteValue(v: string): string =
  ## Render a value so the parser reads back exactly what was stored.
  ##
  ## Quoting is only applied where it is needed -- a value with edge whitespace,
  ## a comment character, or a quote of its own -- so ordinary values stay
  ## readable in the file.
  var needsQuotes = v.len == 0 or v[0] in {' ', '\t'} or v[^1] in {' ', '\t'}
  var body = ""
  for c in v:
    case c
    of '\\': body.add "\\\\"
    of '"': body.add "\\\""; needsQuotes = true
    of '\n': body.add "\\n"; needsQuotes = true
    of '\t': body.add "\\t"
    of '#', ';': body.add c; needsQuotes = true
    else: body.add c
  if needsQuotes: "\"" & body & "\"" else: body

func sectionHeader(k: SplitKey): string =
  ## The header line for a section, with the subsection quoted as git
  ## writes it.
  if k.hasSub: "[" & k.section & " \"" & k.subsection.replace("\\", "\\\\")
                                                    .replace("\"", "\\\"") & "\"]"
  else: "[" & k.section & "]"

func sameSection(sl: ScannedLine, k: SplitKey): bool =
  ## Section names are case-insensitive; subsection names are not.  That
  ## asymmetry is git's, and it matters: `[remote "Origin"]` and
  ## `[remote "origin"]` are two different remotes.
  sl.section == k.section and sl.hasSub == k.hasSub and
    (not k.hasSub or sl.subsection == k.subsection)

proc setConfigValue*(path, key, value: string) =
  ## Set `key` to `value` in the file at `path`, creating the file, the section
  ## or the variable as needed.  An existing variable keeps its line's
  ## indentation and the spelling of its name.
  let k = splitKey(key)
  var lines: seq[string]
  if fileExists(path):
    var text = readWholeFile(path)
    # `splitLines` on a trailing newline yields a final empty element; drop it
    # so the file does not gain a blank line every time it is written.
    if text.len > 0 and text[^1] == '\n': text.setLen(text.len - 1)
    lines = text.splitLines
  let scanned = scanLines(lines, path)

  var lastMatch = -1
  var sectionEnd = -1
  for i, sl in scanned:
    if sl.kind == lkVariable and sameSection(sl, k) and sl.name == k.name:
      lastMatch = i
    if sameSection(sl, k) and sl.kind != lkOther:
      sectionEnd = i
    elif sl.kind == lkSection and sectionEnd >= 0 and not sameSection(sl, k):
      discard  # a later section; sectionEnd already points inside ours

  if lastMatch >= 0:
    lines[lastMatch] = scanned[lastMatch].indent & scanned[lastMatch].keyText &
                       " = " & quoteValue(value)
  elif sectionEnd >= 0:
    lines.insert("\t" & k.name & " = " & quoteValue(value), sectionEnd + 1)
  else:
    lines.add sectionHeader(k)
    lines.add "\t" & k.name & " = " & quoteValue(value)

  createDir(parentDir(path))
  writeFile(path, lines.join("\n") & "\n")

proc unsetConfigValue*(path, key: string, all: bool): int =
  ## Remove `key`.  Returns the number of lines removed.
  ##
  ## Refusing to guess which of several values to drop is git's behavior too:
  ## without `--all`, a multi-valued key is an error rather than a coin toss.
  let k = splitKey(key)
  if not fileExists(path): return 0
  var text = readWholeFile(path)
  if text.len > 0 and text[^1] == '\n': text.setLen(text.len - 1)
  var lines = text.splitLines
  let scanned = scanLines(lines, path)

  var matches: seq[int]
  for i, sl in scanned:
    if sl.kind == lkVariable and sameSection(sl, k) and sl.name == k.name:
      matches.add i
  if matches.len == 0: return 0
  failIf(matches.len > 1 and not all,
         key & " has multiple values")

  for i in countdown(matches.high, 0):
    lines.delete(matches[i])

  # Removing the last variable in a section removes the section header too.
  # git does this, and leaving a bare `[new]` behind would be more than
  # untidy: the next `set` would then append into a section that reads as
  # though someone meant to put something there.  Only a block that is now
  # entirely empty goes -- a comment inside it is somebody's note, and stays.
  let after = scanLines(lines, path)
  var drop: seq[int]
  for i, sl in after:
    if sl.kind != lkSection or not sameSection(sl, k): continue
    var empty = true
    for j in i + 1 ..< after.len:
      if after[j].kind == lkSection: break
      if after[j].kind == lkVariable or lines[j].strip().len > 0:
        empty = false
        break
    if empty: drop.add i
  for i in countdown(drop.high, 0):
    lines.delete(drop[i])

  writeFile(path, lines.join("\n") & "\n")
  matches.len
