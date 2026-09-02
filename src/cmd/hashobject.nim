## `hash-object` -- compute, and optionally store, an object ID.
##
## In scope (docs/10): `<file>...`, `-t`, `-w`, `--stdin`.

import std/os
import ../cli, ../objects, ../oid, ../repository, ../util

const
  synopsis = "[-t <type>] [-w] [--stdin] [--] <file>..."
  options = [
    opt("-t", okValue, arg = "<type>", help = "the object type; blob by default"),
    opt("-w", help = "write the object into the repository as well"),
    opt("--stdin", help = "read the content from standard input"),
  ]

proc hashOne(c: Ctx, kind: ObjectType, data: string, write: bool) =
  ## Hash one blob, and store it under `-w`.
  let o = if write: c.repo.writeObject(kind, data)
          else: hashObject(kind, data)
  echo $o

proc cmdHashObject*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then hash stdin or each named file.
  let o = parse(options, args, "hash-object", synopsis)
  let kind = if o.has "t": parseObjectType(o.val "t") else: otBlob
  failIf(kind == otBad, "invalid object type '" & o.val("t") & "'")
  let write = o.has "w"
  let fromStdin = o.has "stdin"
  let files = o.args
  failIf(not fromStdin and files.len == 0, o.use)
  if fromStdin:
    hashOne(c, kind, readAll(stdin), write)
  for f in files:
    failIf(not fileExists(f) and not symlinkExists(f),
           "could not open '" & f & "' for reading")
    hashOne(c, kind, readWholeFile(f), write)
  0
