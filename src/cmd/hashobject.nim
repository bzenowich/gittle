## `hash-object` -- compute, and optionally store, an object ID.
##
## In scope (docs/10): `<file>...`, `-t`, `-w`, `--stdin`.

import std/[strutils, os]
import ../cli, ../objects, ../oid, ../repository, ../util

const usageText = "usage: gittle hash-object [-t <type>] [-w] [--stdin] [--] <file>..."

proc hashOne(c: Ctx, kind: ObjectType, data: string, write: bool) =
  let o = if write: c.repo.writeObject(kind, data)
          else: hashObject(kind, data)
  echo $o

proc cmdHashObject*(c: Ctx, args: seq[string]): int =
  var kind = otBlob
  var write = false
  var fromStdin = false
  var files: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-' or a == "-":
      files.add a
    elif a == "--":
      noMoreOpts = true
    elif a == "-t":
      inc i
      failIf(i >= args.len, "option '-t' requires a value\n" & usageText)
      kind = parseObjectType(args[i])
      failIf(kind == otBad, "invalid object type '" & args[i] & "'")
    elif a.startsWith("-t"):
      kind = parseObjectType(a[2 .. ^1])
      failIf(kind == otBad, "invalid object type '" & a[2 .. ^1] & "'")
    elif a == "-w":
      write = true
    elif a == "--stdin":
      fromStdin = true
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  failIf(not fromStdin and files.len == 0, usageText)

  # git hashes stdin first, then the file arguments (builtin/hash-object.c).
  if fromStdin:
    hashOne(c, kind, readAll(stdin), write)
  for f in files:
    failIf(not fileExists(f) and not symlinkExists(f),
           "could not open '" & f & "' for reading")
    hashOne(c, kind, readWholeFile(f), write)
  0
