## `cat-file` -- inspect objects.
##
## In scope (docs/09): `<object>`, `<type>`, `-t`, `-s`, `-e`, `-p`,
## `--batch[=<format>]`, `--batch-check[=<format>]`.

import std/[strutils]
import ../cli, ../objects, ../oid, ../repository, ../util

const
  usageText = "usage: gittle cat-file (-t | -s | -e | -p | <type>) <object>\n" &
              "   or: gittle cat-file (--batch | --batch-check)[=<format>]"
  defaultFormat = "%(objectname) %(objecttype) %(objectsize)"

# -- pretty printing --------------------------------------------------------

proc prettyPrint(obj: GitObject) =
  case obj.kind
  of otTree:
    # `<mode> <type> <oid>\t<name>`, with the mode padded to six octal digits.
    for e in treeEntries(obj.data):
      stdout.write formatMode(e.mode), " ", $modeType(e.mode), " ", $e.oid,
                   "\t", e.name, "\n"
  else:
    stdout.write obj.data

# -- type dereferencing -----------------------------------------------------

proc headerField(data: string, name: string): string =
  ## The value of a leading `<name> <value>` line in a commit or tag.  Both put
  ## their structural headers first, so this never scans the message.
  var i = 0
  while i < data.len:
    let eol = data.find('\n', i)
    let line = if eol < 0: data[i .. ^1] else: data[i ..< eol]
    if line.len == 0: break          # blank line ends the header block
    if line.startsWith(name & " "): return line[name.len + 1 .. ^1].strip()
    if eol < 0: break
    i = eol + 1
  ""

proc peelTo(r: Repository, start: Oid, want: ObjectType): GitObject =
  ## `cat-file <type> <object>` asserts *or dereferences* to a type: a tag
  ## yields what it points at, a commit yields its tree.
  var o = start
  for _ in 0 .. 15:
    result = r.readObject(o)
    if result.kind == want: return
    case result.kind
    of otTag:
      let target = headerField(result.data, "object")
      failIf(target.len == 0, "invalid tag object " & $o)
      o = parseOid(target)
    of otCommit:
      if want != otTree: break
      let tree = headerField(result.data, "tree")
      failIf(tree.len == 0, "invalid commit object " & $o)
      o = parseOid(tree)
    else:
      break
  fail("gittle cat-file " & $start & ": bad file")

# -- batch mode -------------------------------------------------------------

proc emitFormat(fmt: string, o: Oid, kind: ObjectType, size: int) =
  var i = 0
  while i < fmt.len:
    if fmt[i] == '%' and i + 1 < fmt.len and fmt[i+1] == '(':
      let close = fmt.find(')', i + 2)
      failIf(close < 0, "unterminated %( in format")
      case fmt[i+2 ..< close]
      of "objectname": stdout.write $o
      of "objecttype": stdout.write $kind
      of "objectsize": stdout.write $size
      else: fail("unknown format atom '%(" & fmt[i+2 ..< close] & ")'")
      i = close + 1
    else:
      stdout.write fmt[i]
      inc i
  stdout.write "\n"

proc runBatch(c: Ctx, fmt: string, withContents: bool): int =
  let r = c.repo
  for rawLine in stdin.lines:
    let name = rawLine.strip()
    if name.len == 0: continue
    var o: Oid
    var ok = true
    try:
      o = r.resolveOid(name)
    except GittleError:
      ok = false
    if ok and not r.hasObject(o): ok = false
    if not ok:
      stdout.write name, " missing\n"
      continue
    if withContents:
      let obj = r.readObject(o)
      emitFormat(fmt, o, obj.kind, obj.data.len)
      stdout.write obj.data
      stdout.write "\n"
    else:
      let info = r.objectInfo(o)
      emitFormat(fmt, o, info.kind, info.size)
  stdout.flushFile()
  0

# -- entry point ------------------------------------------------------------

proc cmdCatFile*(c: Ctx, args: seq[string]): int =
  var mode = '\0'          # one of t s e p, or \0 for the <type> form
  var batch = false
  var batchCheck = false
  var format = defaultFormat
  var rest: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "-t", "-s", "-e", "-p":
      failIf(mode != '\0', "only one of -t, -s, -e, -p may be given")
      mode = a[1]
    of "--batch": batch = true
    of "--batch-check": batchCheck = true
    of "-h", "--help":
      echo usageText
      return 0
    of "--":
      inc i
      while i < args.len: rest.add args[i]; inc i
    else:
      if a.startsWith("--batch="):
        batch = true
        format = a["--batch=".len .. ^1]
      elif a.startsWith("--batch-check="):
        batchCheck = true
        format = a["--batch-check=".len .. ^1]
      elif a.len > 1 and a[0] == '-':
        fail("unknown option '" & a & "'\n" & usageText)
      else:
        rest.add a
    inc i

  if batch or batchCheck:
    failIf(batch and batchCheck, "cannot use --batch with --batch-check")
    failIf(rest.len > 0, usageText)
    return runBatch(c, format, batch)

  let r = c.repo
  if mode != '\0':
    failIf(rest.len != 1, usageText)
    if mode == 'e':
      # No output either way; the exit status is the whole answer.
      var o: Oid
      try:
        o = r.resolveOid(rest[0])
      except GittleError:
        return 1
      return (if r.hasObject(o): 0 else: 1)
    let o = r.resolveOid(rest[0])
    case mode
    of 't': echo $r.objectInfo(o).kind
    of 's': echo $r.objectInfo(o).size
    of 'p': prettyPrint(r.readObject(o))
    else: discard
    stdout.flushFile()
    return 0

  # The `<type> <object>` form.
  failIf(rest.len != 2, usageText)
  let want = parseObjectType(rest[0])
  failIf(want == otBad, "invalid object type '" & rest[0] & "'")
  let o = r.resolveOid(rest[1])
  stdout.write peelTo(r, o, want).data
  stdout.flushFile()
  0
