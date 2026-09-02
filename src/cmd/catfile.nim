## `cat-file` -- inspect objects.
##
## In scope (docs/09): `<object>`, `<type>`, `-t`, `-s`, `-e`, `-p`,
## `--batch[=<format>]`, `--batch-check[=<format>]`.

import std/[strutils]
import ../cli, ../objects, ../oid, ../repository, ../revision, ../util

const
  defaultFormat = "%(objectname) %(objecttype) %(objectsize)"

# -- pretty printing --------------------------------------------------------

proc prettyPrint(obj: GitObject) =
  ## `-p`: a tree as `ls-tree` shows it, a commit or tag as its raw text.
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
  ## `--batch`/`--batch-check`: one object name per input line, answered
  ## through the format; a missing object is reported inline, not fatal.
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

const
  synopsis = "(-t | -s | -e | -p) <object>\n<type> <object>\n(--batch | --batch-check)[=<format>] < <objects>"
  options = [
    opt("-t", help = "print the object's type"),
    opt("-s", help = "print the object's size"),
    opt("-e", help = "exit 0 if the object exists, 1 if not; print nothing"),
    opt("-p", help = "pretty-print the object"),
    opt("--batch", okOptValue, arg = "[=<format>]", help = "one object per input line, with its content"),
    opt("--batch-check", okOptValue, arg = "[=<format>]", help = "the same, without the content"),
  ]

proc cmdCatFile*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then one of the three shapes -- batch, a single
  ## mode letter, or `<type> <object>`.
  let o = parse(options, args, "cat-file", synopsis)
  var mode = '\0'          # one of t s e p, or \0 for the <type> form
  for m in "tsep":
    if o.has $m:
      failIf(mode != '\0', "only one of -t, -s, -e, -p may be given")
      mode = m
  let batch = o.has "batch"
  let batchCheck = o.has "batch-check"
  let format = if o.val("batch").len > 0: o.val "batch"
               elif o.val("batch-check").len > 0: o.val "batch-check"
               else: defaultFormat
  let rest = o.args
  if batch or batchCheck:
    failIf(batch and batchCheck, "cannot use --batch with --batch-check")
    failIf(rest.len > 0, o.use)
    return runBatch(c, format, batch)

  let r = c.repo
  if mode != '\0':
    failIf(rest.len != 1, o.use)
    if mode == 'e':
      # No output either way; the exit status is the whole answer.
      var oid: Oid
      try:
        oid = r.resolveRevish(rest[0])
      except GittleError:
        return 1
      return (if r.hasObject(oid): 0 else: 1)
    let oid = r.resolveRevish(rest[0])
    case mode
    of 't': echo $r.objectInfo(oid).kind
    of 's': echo $r.objectInfo(oid).size
    of 'p': prettyPrint(r.readObject(oid))
    else: discard
    stdout.flushFile()
    return 0

  # The `<type> <object>` form.
  failIf(rest.len != 2, o.use)
  let want = parseObjectType(rest[0])
  failIf(want == otBad, "invalid object type '" & rest[0] & "'")
  let oid = r.resolveRevish(rest[1])
  stdout.write r.peelTo(oid, want).obj.data
  stdout.flushFile()
  0
