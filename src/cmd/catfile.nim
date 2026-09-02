## `cat-file` -- inspect objects.
##
## In scope (docs/09): `<object>`, `<type>`, `-t`, `-s`, `-e`, `-p`,
## `--batch[=<format>]`, `--batch-check[=<format>]`.

import std/[strutils]
import ../cli, ../objects, ../oid, ../repository, ../revision, ../util

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

# -- batch mode -------------------------------------------------------------

proc emitFormat(fmt: string, o: Oid, kind: ObjectType, size: int) =
  ## `--batch`'s vocabulary is three atoms wide; the interpolation itself is
  ## the same one `for-each-ref` uses.
  stdout.write interpolate(fmt, proc (atom: string): string =
    case atom
    of "objectname": $o
    of "objecttype": $kind
    of "objectsize": $size
    else: fail("unknown format atom '%(" & atom & ")'"))
  stdout.write "\n"

proc runBatch(c: Ctx, fmt: string, withContents: bool): int =
  let r = c.repo
  for rawLine in stdin.lines:
    let name = rawLine.strip()
    if name.len == 0: continue
    var o: Oid
    var ok = true
    try:
      o = r.resolveRevish(name)
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
        o = r.resolveRevish(rest[0])
      except GittleError:
        return 1
      return (if r.hasObject(o): 0 else: 1)
    let o = r.resolveRevish(rest[0])
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
  let o = r.resolveRevish(rest[1])
  stdout.write r.peelTo(o, want).obj.data
  stdout.flushFile()
  0
