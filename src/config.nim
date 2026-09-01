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
  c.isAlphaNumeric or c == '-'

proc parseValue(line: string, start: int, path: string, lineNo: int,
                more: var bool): string =
  ## Read a value starting at `start`.  Sets `more` if the line ended with a
  ## backslash continuation.
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
    if quoted or c notin {' ', '\t'}:
      result.add c
      lastNonSpace = result.len
    else:
      result.add c
    inc i
  if quoted: fail(path & ":" & $lineNo & ": unterminated quote")
  if lastNonSpace >= 0: result.setLen(lastNonSpace) else: result.setLen(0)

proc parseConfig*(text, path: string): Config =
  var section = ""
  var lineNo = 0
  var pending = ""     ## key waiting for a continued value
  var pendingVal = ""
  for rawLine in text.splitLines:
    inc lineNo
    var line = rawLine
    if pending.len > 0:
      var more = false
      pendingVal.add parseValue(line, 0, path, lineNo, more)
      if more: continue
      result.entries.add ConfigEntry(key: pending, value: pendingVal)
      pending = ""
      pendingVal = ""
      continue

    var i = 0
    while i < line.len and line[i] in {' ', '\t'}: inc i
    if i >= line.len or line[i] in {'#', ';'}: continue

    if line[i] == '[':
      inc i
      let nameStart = i
      while i < line.len and (isNameChar(line[i]) or line[i] == '.'): inc i
      section = line[nameStart ..< i].toLowerAscii
      while i < line.len and line[i] in {' ', '\t'}: inc i
      if i < line.len and line[i] == '"':
        inc i
        var sub = ""
        while i < line.len and line[i] != '"':
          if line[i] == '\\' and i + 1 < line.len: inc i
          sub.add line[i]
          inc i
        if i >= line.len: fail(path & ":" & $lineNo & ": unterminated subsection")
        inc i
        section = section & "." & sub  # subsection case is significant
        while i < line.len and line[i] in {' ', '\t'}: inc i
      if i >= line.len or line[i] != ']':
        fail(path & ":" & $lineNo & ": bad section header")
      continue

    # variable
    let nameStart = i
    while i < line.len and isNameChar(line[i]): inc i
    let name = line[nameStart ..< i].toLowerAscii
    if name.len == 0: fail(path & ":" & $lineNo & ": bad config line")
    if section.len == 0: fail(path & ":" & $lineNo & ": variable outside a section")
    let key = section & "." & name
    while i < line.len and line[i] in {' ', '\t'}: inc i
    if i >= line.len:
      result.entries.add ConfigEntry(key: key, value: "true", isBool: true)
      continue
    if line[i] != '=': fail(path & ":" & $lineNo & ": bad config line")
    inc i
    while i < line.len and line[i] in {' ', '\t'}: inc i
    var more = false
    let v = parseValue(line, i, path, lineNo, more)
    if more:
      pending = key
      pendingVal = v
    else:
      result.entries.add ConfigEntry(key: key, value: v)
  if pending.len > 0:
    result.entries.add ConfigEntry(key: pending, value: pendingVal)

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

proc has*(c: Config, key: string): bool =
  let k = key.toLowerAscii
  for e in c.entries:
    if e.key.toLowerAscii == k: return true
  false

proc getBool*(c: Config, key: string, default: bool): bool =
  if not c.has(key): return default
  case c.get(key).toLowerAscii
  of "true", "yes", "on", "1", "": true
  of "false", "no", "off", "0": false
  else: default

proc getInt*(c: Config, key: string, default: int): int =
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
  if k.hasSub: "[" & k.section & " \"" & k.subsection.replace("\\", "\\\\")
                                                    .replace("\"", "\\\"") & "\"]"
  else: "[" & k.section & "]"

type
  LineKind = enum lkOther, lkSection, lkVariable

  ScannedLine = object
    ## One line of the file, classified enough to decide whether it is the
    ## line we are looking for.
    kind: LineKind
    section: string     ## the section in force at this line, lowercased
    subsection: string
    hasSub: bool
    name: string        ## for lkVariable, the lowercased variable name
    indent: string      ## whatever whitespace the author used
    keyText: string     ## the key exactly as written, so it can be preserved

proc scanLines(lines: seq[string]): seq[ScannedLine] =
  ## Classify every line, carrying the current section forward.  Nothing here
  ## interprets values: this pass only has to find the right *line*.
  var section = ""
  var subsection = ""
  var hasSub = false
  for line in lines:
    var sl = ScannedLine(kind: lkOther, section: section,
                         subsection: subsection, hasSub: hasSub)
    var i = 0
    while i < line.len and line[i] in {' ', '\t'}: inc i
    if i < line.len and line[i] notin {'#', ';'}:
      if line[i] == '[':
        inc i
        let start = i
        while i < line.len and (line[i].isAlphaNumeric or line[i] in {'-', '.'}):
          inc i
        section = line[start ..< i].toLowerAscii
        subsection = ""
        hasSub = false
        while i < line.len and line[i] in {' ', '\t'}: inc i
        if i < line.len and line[i] == '"':
          inc i
          var sub = ""
          while i < line.len and line[i] != '"':
            if line[i] == '\\' and i + 1 < line.len: inc i
            sub.add line[i]
            inc i
          subsection = sub
          hasSub = true
        sl.kind = lkSection
        sl.section = section
        sl.subsection = subsection
        sl.hasSub = hasSub
      else:
        let start = i
        while i < line.len and (line[i].isAlphaNumeric or line[i] == '-'): inc i
        if i > start:
          sl.kind = lkVariable
          sl.name = line[start ..< i].toLowerAscii
          sl.indent = line[0 ..< start]
          sl.keyText = line[start ..< i]
    result.add sl

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
  let scanned = scanLines(lines)

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
  let scanned = scanLines(lines)

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
  let after = scanLines(lines)
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
