## Object types, the loose object framing, and loose read/write.
##
## R1 lives here.  The framing `"<type> <size>\0"` is what gets hashed, so a
## byte out of place produces a different object ID and silently forks the
## repository.  The parser is deliberately as strict as git's own
## `parse_loose_header` (object-file.c): canonical decimal size, no leading
## zeros, terminated by NUL.

import std/[os, strutils]
import oid, sha1, zlib, util

type
  ObjectType* = enum
    ## The numbering is git's own, shared between the loose header and the pack
    ## object header.  5 is unused; 6 and 7 only ever appear inside a pack.
    otBad = 0
    otCommit = 1
    otTree = 2
    otBlob = 3
    otTag = 4
    otOfsDelta = 6
    otRefDelta = 7

  GitObject* = object
    kind*: ObjectType
    data*: string

func `$`*(t: ObjectType): string =
  case t
  of otCommit: "commit"
  of otTree: "tree"
  of otBlob: "blob"
  of otTag: "tag"
  of otOfsDelta: "ofs-delta"
  of otRefDelta: "ref-delta"
  of otBad: "bad"

func parseObjectType*(s: string): ObjectType =
  case s
  of "commit": otCommit
  of "tree": otTree
  of "blob": otBlob
  of "tag": otTag
  else: otBad

func isDelta*(t: ObjectType): bool = t == otOfsDelta or t == otRefDelta

func packTypeFromInt*(n: int): ObjectType =
  case n
  of 1: otCommit
  of 2: otTree
  of 3: otBlob
  of 4: otTag
  of 6: otOfsDelta
  of 7: otRefDelta
  else: otBad

# -- framing and hashing ----------------------------------------------------

func objectHeader*(kind: ObjectType, size: int): string =
  $kind & " " & $size & "\0"

proc hashObject*(kind: ObjectType, data: openArray[byte]): Oid =
  ## The object ID: SHA-1 over header and payload, hashed without joining them.
  var c = initSha1()
  c.update(objectHeader(kind, data.len))
  c.update(data)
  toOid(c.finish())

proc hashObject*(kind: ObjectType, data: string): Oid {.inline.} =
  hashObject(kind, data.toOpenArrayByte(0, data.len - 1))

proc parseLooseHeader*(buf: string): tuple[kind: ObjectType, size, bodyAt: int] =
  ## Returns the type, the payload size, and the offset just past the NUL.
  ## Raises unless the header is exactly canonical.
  var i = 0
  while i < buf.len and buf[i] != ' ':
    if buf[i] == '\0': fail("malformed loose object header")
    inc i
  if i >= buf.len: fail("malformed loose object header")
  result.kind = parseObjectType(buf[0 ..< i])
  inc i  # the space

  # Canonical decimal: a lone "0", or a non-zero digit followed by digits.
  if i >= buf.len or buf[i] notin Digits: fail("malformed loose object header")
  var size = ord(buf[i]) - ord('0')
  inc i
  if size != 0:
    while i < buf.len and buf[i] in Digits:
      size = size * 10 + (ord(buf[i]) - ord('0'))
      inc i
  if i >= buf.len or buf[i] != '\0': fail("malformed loose object header")
  result.size = size
  result.bodyAt = i + 1

# -- loose objects on disk --------------------------------------------------

const maxLooseHeader = 64
  ## "commit " plus a 20-digit size and a NUL fits with room to spare.

func loosePath*(objdir: string, o: Oid): string =
  let h = $o
  objdir / h[0 ..< 2] / h[2 ..< OidHexLen]

proc readLooseHeaderAt*(path: string): tuple[kind: ObjectType, size: int] =
  ## Type and size without inflating the body -- what `cat-file -t` and `-s`
  ## need, and what makes them cheap on a large blob.
  let raw = readWholeFile(path)
  if raw.len == 0: fail("loose object file is empty: " & path)
  let hdr = inflatePrefix(unsafeAddr raw[0], raw.len, maxLooseHeader)
  let p = parseLooseHeader(hdr)
  (p.kind, p.size)

proc readLooseAt*(path: string): GitObject =
  let raw = readWholeFile(path)
  if raw.len == 0: fail("loose object file is empty: " & path)
  let all = inflateAll(unsafeAddr raw[0], raw.len)
  let p = parseLooseHeader(all)
  if all.len - p.bodyAt != p.size:
    fail("loose object size mismatch in " & path & ": header says " & $p.size &
         ", inflated " & $(all.len - p.bodyAt))
  result.kind = p.kind
  result.data = all[p.bodyAt .. ^1]

proc writeLoose*(objdir: string, kind: ObjectType, data: string): Oid =
  ## Write the object if it is not already present.  Existing objects are left
  ## alone: they are content-addressed, so rewriting one can only lose.
  result = hashObject(kind, data)
  let path = loosePath(objdir, result)
  if fileExists(path): return
  let framed = objectHeader(kind, data.len) & data
  # Level 1 is what git uses for loose objects (core.loosecompression defaults
  # to Z_BEST_SPEED in environment.c), so gittle's files match byte for byte.
  let comp = deflateAll(unsafeAddr framed[0], framed.len, ZBestSpeed)
  createDir(parentDir(path))
  writeFileAtomic(path, comp)

# -- trees ------------------------------------------------------------------
#
# A tree entry is `<mode> <name>\0<20 raw bytes>`, with the mode in octal ASCII
# and no leading zero.  Phase 3 writes these; phase 1 only needs to display
# them for `cat-file -p`.

type
  TreeEntry* = object
    mode*: uint32
    name*: string
    oid*: Oid

func modeType*(mode: uint32): ObjectType =
  ## The object type a tree entry's mode implies.  A gitlink (160000) names a
  ## commit in another repository.
  case mode and 0o170000'u32
  of 0o040000'u32: otTree
  of 0o160000'u32: otCommit
  else: otBlob

func octalMode*(mode: uint32): string =
  ## Octal with no leading zero -- how a mode is *stored* in a tree object.  A
  ## directory is `40000`, not `040000`, and writing the padded form would
  ## produce a different object ID for the same tree (R1).
  if mode == 0: return "0"
  var n = mode
  while n > 0:
    result = char(ord('0') + int(n and 7)) & result
    n = n shr 3

func formatMode*(mode: uint32): string =
  ## Six octal digits, zero-padded -- how git *displays* a mode, in `ls-tree`
  ## and `cat-file -p`.  Not what goes in the object.
  result = octalMode(mode)
  while result.len < 6: result = "0" & result

iterator treeEntries*(data: string): TreeEntry =
  var i = 0
  while i < data.len:
    let sp = data.find(' ', i)
    if sp < 0: fail("malformed tree: no space after mode")
    var mode: uint32 = 0
    for k in i ..< sp:
      failIf(data[k] notin {'0'..'7'}, "malformed tree: bad mode")
      mode = mode * 8 + uint32(ord(data[k]) - ord('0'))
    let nul = data.find('\0', sp + 1)
    if nul < 0: fail("malformed tree: unterminated name")
    failIf(nul + 1 + OidLen > data.len, "malformed tree: truncated object id")
    var e = TreeEntry(mode: mode, name: data[sp + 1 ..< nul])
    for k in 0 ..< OidLen: e.oid.b[k] = byte(data[nul + 1 + k])
    yield e
    i = nul + 1 + OidLen
