## Packfiles: `.idx` v2 lookup, `.pack` object reading, and delta application.
##
## A packfile is how git stores almost every object almost all of the time.
## The repository beside this one holds 420,113 objects; 420,111 of them are in
## a single 322 MiB pack, and none is a separate file.  Reading one is
## therefore not an optimisation -- it is the ordinary case.
##
## ## The two files
##
## A pack comes in two parts, named after the same 40-hex digest:
##
## * `pack-<hash>.pack` -- a 12-byte header (`PACK`, a version, an object
##   count), then every object back to back, then a 20-byte checksum of
##   everything before it.  Objects are stored *in an arbitrary order* and
##   there is no table of contents.
## * `pack-<hash>.idx` -- the table of contents, which is why it can be
##   regenerated from the pack alone (`git index-pack`).
##
## ## The index, version 2
##
##     8 bytes     \377tOc, then the version, 2
##     1024 bytes  a 256-entry fan-out table: entry `i` is the number of
##                 objects whose first byte is <= `i`
##     N * 20      every object's ID, sorted
##     N * 4       a CRC32 of each object's packed bytes
##     N * 4       each object's offset in the pack; if the top bit is set,
##                 the rest indexes the table below instead
##     M * 8       offsets that do not fit in 31 bits, for packs over 2 GiB
##     20 + 20     the pack's checksum, then the index's own
##
## The fan-out table is the trick that makes lookup fast without loading
## anything: the first byte of the wanted ID indexes straight into it, and the
## binary search that follows starts already narrowed to about 1/256th of the
## file.
##
## ## Two different variable-length integers
##
## The pack format uses two varint encodings that look alike and are not
## interchangeable, which is a rewarding source of bugs:
##
## * The **size** varint, in an object's header.  Seven bits per byte,
##   little-endian, top bit set means "another byte follows" -- except that the
##   first byte gives up three bits to the object type, so it carries only
##   four.  See `readEntry`.
## * The **offset** varint, used by `OBJ_OFS_DELTA` for the distance back to
##   its base, and again by index version 4 for path prefixes.  Also seven bits
##   per byte, but each continuation *adds one* before shifting, so that no
##   value has two encodings.  See the loop in `readEntry`.
##
## Both are also big-endian in a sense the other is not; do not merge them.
##
## ## What is read and what is not
##
## Both files are memory-mapped, so nothing here copies more than the object
## being returned.  Only index version 2 is read: git has written v2 by default
## since 1.6, and a v1 index can be regenerated in seconds, so refusing it costs
## a user nothing and saves a format.  The `.rev` reverse index and any bitmap
## file beside the pack are ignored entirely (R3).

import std/[memfiles, os, tables, deques]
import oid, objects, zlib, util

type
  Pack* = ref object
    packPath*: string
    idxPath*: string
    packMap: MemFile
    idxMap: MemFile
    pack: ptr UncheckedArray[byte]
    packLen*: int
    idx: ptr UncheckedArray[byte]
    idxLen: int
    nObjects*: int
    ## Byte offsets of the `.idx` tables, all derived from `nObjects`.
    oidsAt, crcAt, ofsAt, bigOfsAt: int
    byOffset: Table[int, int]   ## pack offset -> index, built on demand
    baseCache: Table[int, GitObject]
    baseOrder: Deque[int]
    baseBytes: int

  PackEntry* = object
    ## An object's header as it appears in the pack, before any delta is applied.
    kind*: ObjectType
    size*: int        ## the *stored* size: for a delta, the delta's own length
    dataAt*: int      ## offset of the zlib stream
    baseOffset*: int  ## otOfsDelta: absolute offset of the base
    baseOid*: Oid     ## otRefDelta: the base's name

const
  idxMagic = [0xFF'u8, 0x74, 0x4F, 0x63]  # "\377tOc"
  packSignature = "PACK"
  fanoutAt = 8
  fanoutBytes = 256 * 4
  packHeaderLen = 12
  trailerLen = OidLen

# -- big-endian readers -----------------------------------------------------

func be32(b: ptr UncheckedArray[byte], at: int): uint32 {.inline.} =
  ## A big-endian 32-bit field of a mapped file.
  (uint32(b[at]) shl 24) or (uint32(b[at+1]) shl 16) or
  (uint32(b[at+2]) shl 8) or uint32(b[at+3])

func be64(b: ptr UncheckedArray[byte], at: int): uint64 {.inline.} =
  ## A big-endian 64-bit field of a mapped file.
  (uint64(be32(b, at)) shl 32) or uint64(be32(b, at + 4))

func oidAtRaw(b: ptr UncheckedArray[byte], at: int): Oid {.inline.} =
  ## Twenty bytes of a mapped file as an object ID.
  for i in 0 ..< OidLen: result.b[i] = b[at + i]

# -- opening ----------------------------------------------------------------

proc close*(p: Pack) =
  ## Unmap both files; safe to call twice.
  if p.pack != nil:
    p.packMap.close()
    p.pack = nil
  if p.idx != nil:
    p.idxMap.close()
    p.idx = nil

proc openPack*(idxPath: string): Pack =
  ## `idxPath` names the `.idx`; the `.pack` beside it must exist.
  result = Pack()
  result.idxPath = idxPath
  result.packPath = idxPath[0 ..< idxPath.len - 4] & ".pack"
  if not fileExists(result.packPath):
    fail("no packfile for index " & idxPath)

  result.idxMap = memfiles.open(idxPath)
  result.idx = cast[ptr UncheckedArray[byte]](result.idxMap.mem)
  result.idxLen = result.idxMap.size
  failIf(result.idxLen < fanoutAt + fanoutBytes + 2 * trailerLen,
         "pack index too short: " & idxPath)

  for i in 0 ..< 4:
    failIf(result.idx[i] != idxMagic[i],
           "pack index " & idxPath & " is version 1; regenerate it with " &
           "`git index-pack` (gittle reads version 2 only)")
  let version = be32(result.idx, 4)
  failIf(version != 2, "unsupported pack index version " & $version &
                       " in " & idxPath)

  result.nObjects = int(be32(result.idx, fanoutAt + 255 * 4))
  result.oidsAt = fanoutAt + fanoutBytes
  result.crcAt = result.oidsAt + result.nObjects * OidLen
  result.ofsAt = result.crcAt + result.nObjects * 4
  result.bigOfsAt = result.ofsAt + result.nObjects * 4
  failIf(result.bigOfsAt + 2 * trailerLen > result.idxLen,
         "pack index truncated: " & idxPath)

  result.packMap = memfiles.open(result.packPath)
  result.pack = cast[ptr UncheckedArray[byte]](result.packMap.mem)
  result.packLen = result.packMap.size
  failIf(result.packLen < packHeaderLen + trailerLen,
         "packfile too short: " & result.packPath)
  for i in 0 ..< 4:
    failIf(char(result.pack[i]) != packSignature[i],
           "bad packfile signature in " & result.packPath)
  let pv = be32(result.pack, 4)
  failIf(pv != 2 and pv != 3, "unsupported pack version " & $pv)

# -- index lookup -----------------------------------------------------------

func oidAt*(p: Pack, i: int): Oid {.inline.} =
  ## The `i`th object ID of the index, in sorted order.
  oidAtRaw(p.idx, p.oidsAt + i * OidLen)

proc offsetAt*(p: Pack, i: int): int =
  ## The pack offset of entry `i`: the 32-bit table, or the 64-bit one
  ## when the high bit says so.
  let v = be32(p.idx, p.ofsAt + i * 4)
  if (v and 0x8000_0000'u32) == 0:
    int(v)
  else:
    let big = int(v and 0x7FFF_FFFF'u32)
    failIf(p.bigOfsAt + (big + 1) * 8 + 2 * trailerLen > p.idxLen,
           "large-offset table overrun in " & p.idxPath)
    int(be64(p.idx, p.bigOfsAt + big * 8))

func fanout(p: Pack, b: byte): int {.inline.} =
  ## How many objects have a first byte at or below `b`.
  int(be32(p.idx, fanoutAt + int(b) * 4))

proc find*(p: Pack, o: Oid): int =
  ## Index position of `o`, or -1.  The fanout table narrows the binary search
  ## to the objects sharing a first byte before it starts.
  var lo = if o.b[0] == 0: 0 else: p.fanout(o.b[0] - 1)
  var hi = p.fanout(o.b[0])
  while lo < hi:
    let mid = (lo + hi) div 2
    let c = cmp(p.oidAt(mid), o)
    if c == 0: return mid
    elif c < 0: lo = mid + 1
    else: hi = mid
  -1

iterator matching*(p: Pack, pre: OidPrefix): Oid =
  ## Every object whose name starts with `pre`.  Used to resolve abbreviations
  ## and to detect ambiguity.
  # A one-nybble prefix spans sixteen fanout buckets; anything longer pins the
  # first byte exactly.
  let firstLo = pre.b[0]
  let firstHi = if pre.nybbles == 1: pre.b[0] or 0x0F'u8 else: pre.b[0]
  var lo = if firstLo == 0: 0 else: p.fanout(firstLo - 1)
  var hi = p.fanout(firstHi)
  let last = hi
  # Binary search for the first OID >= the prefix's lower bound.
  let bound = pre.lowerBound
  while lo < hi:
    let mid = (lo + hi) div 2
    if cmp(p.oidAt(mid), bound) < 0: lo = mid + 1
    else: hi = mid
  var i = lo
  while i < last:
    let o = p.oidAt(i)
    if not pre.matches(o): break
    yield o
    inc i

proc contains*(p: Pack, o: Oid): bool = p.find(o) >= 0

# -- pack object headers ----------------------------------------------------

proc readEntryAt*(pack: ptr UncheckedArray[byte], packLen, offset: int,
                  name: string): PackEntry =
  ## Parse the object header at `offset`.  Does not inflate anything.
  ##
  ## Takes the mapping rather than a `Pack` because `index-pack` has to read
  ## exactly these headers out of a pack that has no index yet -- that being
  ## what it is about to write.
  failIf(offset < packHeaderLen or offset >= packLen - trailerLen,
         "offset " & $offset & " is outside " & name)
  var at = offset
  var c = pack[at]
  inc at
  result.kind = packTypeFromInt(int((c shr 4) and 7))
  failIf(result.kind == otBad, "bad object type in " & name & " at " & $offset)
  # The size varint: four bits in the first byte (the other four are the type
  # and the continuation flag), then seven per byte, little-endian.
  var size = int(c and 15)
  var shift = 4
  while (c and 0x80) != 0:
    failIf(at >= packLen, "truncated object header in " & name)
    c = pack[at]
    inc at
    size = size or (int(c and 0x7F) shl shift)
    shift += 7
  result.size = size

  case result.kind
  of otOfsDelta:
    # The relative-offset encoding: 7 bits per byte, but each continuation adds
    # one so that no value has two encodings.  (Same varint as index v4.)
    var b = pack[at]
    inc at
    var ofs = int(b and 0x7F)
    while (b and 0x80) != 0:
      failIf(at >= packLen, "truncated ofs-delta base in " & name)
      b = pack[at]
      inc at
      ofs = ((ofs + 1) shl 7) or int(b and 0x7F)
    failIf(ofs <= 0 or ofs > offset - packHeaderLen,
           "ofs-delta base out of range in " & name)
    result.baseOffset = offset - ofs
  of otRefDelta:
    failIf(at + OidLen > packLen, "truncated ref-delta base in " & name)
    result.baseOid = oidAtRaw(pack, at)
    at += OidLen
  else:
    discard
  result.dataAt = at

proc inflateEntryAt*(pack: ptr UncheckedArray[byte], packLen: int,
                     e: PackEntry): tuple[data: string, consumed: int] =
  ## The object's stored bytes -- the content itself, or the delta -- and how
  ## many compressed bytes they occupied, which is the only way to find where
  ## the next object begins.
  inflateExact(addr pack[e.dataAt], packLen - e.dataAt, e.size)

proc readEntry*(p: Pack, offset: int): PackEntry =
  ## The header of the entry at `offset`: its type, size and, for a delta,
  ## its base.
  readEntryAt(p.pack, p.packLen, offset, p.packPath)

proc inflateEntry(p: Pack, e: PackEntry): string =
  ## The stored bytes of an entry -- content, or a delta.
  inflateEntryAt(p.pack, p.packLen, e).data

# -- deltas -----------------------------------------------------------------

func deltaVarint(d: string, at: var int): int =
  ## The delta header's varint: plain seven bits per byte, little-endian, top
  ## bit as the continuation flag (`patch-delta.c`).  Note this is a *third*
  ## encoding, distinct from both pack varints -- it has no type field stolen
  ## from the first byte and no +1 on continuation.
  var shift = 0
  while true:
    failIf(at >= d.len, "truncated delta header")
    let c = byte(d[at])
    inc at
    result = result or (int(c and 0x7F) shl shift)
    if (c and 0x80) == 0: break
    shift += 7

proc applyDelta*(base, delta: string): string =
  ## Reconstruct an object from a base and a delta (`patch-delta.c`).
  ##
  ## A delta is a tiny program with two instructions, run against the base:
  ##
  ## * **copy** -- top bit set.  The low four bits say which of four offset
  ##   bytes follow, the next three say which of three size bytes follow, and
  ##   absent bytes are zero.  So copying 4 bytes from offset 0 costs two bytes
  ##   of delta, and a size of zero means 65536 (a special case that exists
  ##   only because the encoding cannot otherwise express it).
  ## * **insert** -- top bit clear, and the byte itself is a length of 1..127,
  ##   followed by that many literal bytes.  Zero is reserved.
  ##
  ## The header gives the base size (checked, because a mismatch means we found
  ## the wrong base) and the result size, so the whole result is one
  ## allocation and every write is bounds-checked against it.
  var at = 0
  let baseSize = deltaVarint(delta, at)
  let resultSize = deltaVarint(delta, at)
  failIf(baseSize != base.len,
         "delta base size mismatch: delta says " & $baseSize &
         ", base is " & $base.len)
  result = newString(resultSize)
  var outPos = 0
  while at < delta.len:
    let op = byte(delta[at])
    inc at
    if (op and 0x80) != 0:
      # Copy from the base: a bitmask says which offset and size bytes follow.
      var cpOff = 0
      var cpSize = 0
      for i in 0 ..< 4:
        if (op and byte(1 shl i)) != 0:
          failIf(at >= delta.len, "truncated delta copy")
          cpOff = cpOff or (int(byte(delta[at])) shl (i * 8))
          inc at
      for i in 0 ..< 3:
        if (op and byte(0x10 shl i)) != 0:
          failIf(at >= delta.len, "truncated delta copy")
          cpSize = cpSize or (int(byte(delta[at])) shl (i * 8))
          inc at
      if cpSize == 0: cpSize = 0x10000
      failIf(cpOff < 0 or cpSize < 0 or cpOff + cpSize > base.len,
             "delta copy runs past the base")
      failIf(outPos + cpSize > resultSize, "delta produced too many bytes")
      if cpSize > 0:
        copyMem(addr result[outPos], unsafeAddr base[cpOff], cpSize)
      outPos += cpSize
    elif op != 0:
      # Insert the next `op` literal bytes.
      let n = int(op)
      failIf(at + n > delta.len, "truncated delta insert")
      failIf(outPos + n > resultSize, "delta produced too many bytes")
      copyMem(addr result[outPos], unsafeAddr delta[at], n)
      outPos += n
      at += n
    else:
      fail("delta opcode 0 is reserved")
  failIf(outPos != resultSize,
         "delta produced " & $outPos & " bytes, header said " & $resultSize)

# -- writing headers --------------------------------------------------------
#
# The two encodings `readEntry` decodes, written back out.  They live here,
# beside the reader that has to agree with them, because a pack whose header
# is written by one rule and read by another is a repository that cannot be
# read back.

func packEntryHeader*(kind: ObjectType, size: int): string =
  ## Type and size: three type bits and the low four size bits in the first
  ## byte, then seven size bits per byte, little-endian.  `ObjectType`'s
  ## numbering *is* the pack's, which is why there is no table here.
  var n = size
  result.add char((int(kind) shl 4) or (n and 15) or
                  (if n shr 4 > 0: 0x80 else: 0))
  n = n shr 4
  while n > 0:
    result.add char((n and 0x7F) or (if n shr 7 > 0: 0x80 else: 0))
    n = n shr 7

func ofsDeltaHeader*(distance: int): string =
  ## The distance back to an OBJ_OFS_DELTA's base, most significant group
  ## first, each continuation biased by one so no value has two spellings.
  var buf: array[16, char]
  var i = buf.high
  var n = distance
  buf[i] = char(n and 0x7F)
  while (n shr 7) > 0:
    n = (n shr 7) - 1
    dec i
    buf[i] = char(0x80 or (n and 0x7F))
  for k in i .. buf.high: result.add buf[k]

# -- reading objects --------------------------------------------------------

const
  maxDeltaDepth = 200
    ## git's own ceiling is `pack.depth` (default 50); this is only a guard
    ## against a cycle in a corrupt pack.
  baseCacheLimit = 64 * 1024 * 1024
    ## Delta bases resolved on the way to an object, kept for the next one.
    ## Adjacent objects in a pack share nearly all of their chain, so this turns
    ## a depth-50 walk per object into one lookup.  Purely an in-process cache:
    ## R3 is about the caches git writes to disk, none of which gittle reads.

proc cacheBase(p: Pack, offset: int, obj: GitObject) =
  ## Remember a resolved base, bounded in bytes, so a chain of deltas off
  ## the same object does not re-apply it each time.
  if obj.data.len > baseCacheLimit div 4: return
  if p.baseCache.hasKey(offset): return
  p.baseCache[offset] = obj
  p.baseOrder.addLast offset
  p.baseBytes += obj.data.len
  while p.baseBytes > baseCacheLimit and p.baseOrder.len > 0:
    let victim = p.baseOrder.popFirst()
    p.baseBytes -= p.baseCache[victim].data.len
    p.baseCache.del victim

proc readAtDepth(p: Pack, offset, depth: int,
                 findExternal: proc (o: Oid): GitObject {.closure.}): GitObject =
  ## Read an object at `offset`, applying deltas recursively; a base the
  ## pack lacks comes through `findExternal` (a thin pack, or another pack).
  failIf(depth > maxDeltaDepth, "delta chain too deep in " & p.packPath)
  if depth > 0:
    let hit = p.baseCache.getOrDefault(offset)
    if hit.kind != otBad: return hit
  let e = p.readEntry(offset)
  case e.kind
  of otOfsDelta, otRefDelta:
    var base: GitObject
    if e.kind == otOfsDelta:
      base = p.readAtDepth(e.baseOffset, depth + 1, findExternal)
    else:
      let i = p.find(e.baseOid)
      if i >= 0:
        base = p.readAtDepth(p.offsetAt(i), depth + 1, findExternal)
      elif findExternal != nil:
        base = findExternal(e.baseOid)
      else:
        fail("missing delta base " & $e.baseOid & " for " & p.packPath)
    result.kind = base.kind
    result.data = applyDelta(base.data, p.inflateEntry(e))
  else:
    result.kind = e.kind
    result.data = p.inflateEntry(e)
  if depth > 0: p.cacheBase(offset, result)

proc readAt*(p: Pack, offset: int,
             findExternal: proc (o: Oid): GitObject {.closure.} = nil): GitObject =
  ## Read the object at `offset`, applying any delta chain.  `findExternal`
  ## resolves a ref-delta base that lives outside this pack.
  p.readAtDepth(offset, 0, findExternal)

proc offsetToIndex(p: Pack, offset: int): int =
  ## Which object in the index lives at this pack offset, or -1.
  ##
  ## The pack has no such map -- that is what the `.rev` file git writes is
  ## for, and R3 says gittle does not read one -- so it is built once, on
  ## demand, from the index that is already open.  Only `pack-objects` asks,
  ## and only when it is reusing a delta whose base it must be able to *name*.
  if p.byOffset.len == 0 and p.nObjects > 0:
    for i in 0 ..< p.nObjects: p.byOffset[p.offsetAt(i)] = i
  p.byOffset.getOrDefault(offset, -1)

proc storedDelta*(p: Pack, offset: int): tuple[base: Oid, raw: string] =
  ## The object at `offset` exactly as it lies in the pack, when it lies there
  ## as a delta: the base's *name* and the delta's still-compressed bytes.
  ##
  ## An empty `raw` means it is not a delta and there is nothing to reuse.
  ## This is the whole of R2 on the writing side (plan.md §3.1): gittle never
  ## searches for a delta, it only ever passes on one somebody else already
  ## found.
  let e = p.readEntry(offset)
  if not e.kind.isDelta: return
  case e.kind
  of otOfsDelta:
    let i = p.offsetToIndex(e.baseOffset)
    if i < 0: return
    result.base = p.oidAt(i)
  of otRefDelta: result.base = e.baseOid
  else: discard
  let n = inflateEntryAt(p.pack, p.packLen, e).consumed
  result.raw = newString(n)
  if n > 0: copyMem(addr result.raw[0], addr p.pack[e.dataAt], n)

proc typeAndSizeAt*(p: Pack, offset: int,
                    findExternal: proc (o: Oid): GitObject {.closure.} = nil):
    tuple[kind: ObjectType, size: int] =
  ## `cat-file -t` and `-s` without materialising the object.  A delta already
  ## carries its result size in its header; only the type needs the chain
  ## walked, and that reads headers alone.
  var e = p.readEntry(offset)
  if not e.kind.isDelta:
    return (e.kind, e.size)

  # Size: the second varint of this delta's header, from its first few bytes.
  const deltaHeaderMax = 32
  let prefix = inflatePrefix(addr p.pack[e.dataAt], p.packLen - e.dataAt,
                             min(deltaHeaderMax, e.size))
  var at = 0
  discard deltaVarint(prefix, at)
  result.size = deltaVarint(prefix, at)

  # Type: follow bases until one is not a delta.
  var depth = 0
  while e.kind.isDelta:
    inc depth
    failIf(depth > maxDeltaDepth, "delta chain too deep in " & p.packPath)
    if e.kind == otOfsDelta:
      e = p.readEntry(e.baseOffset)
    else:
      let i = p.find(e.baseOid)
      if i >= 0:
        e = p.readEntry(p.offsetAt(i))
      elif findExternal != nil:
        return (findExternal(e.baseOid).kind, result.size)
      else:
        fail("missing delta base " & $e.baseOid & " for " & p.packPath)
  result.kind = e.kind
