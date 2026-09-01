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
