## `index-pack`: turn a packfile into a repository object.
##
## A `.pack` on its own is unusable.  It has no table of contents -- objects
## sit back to back in whatever order the sender chose, and a delta names its
## base either by an offset backwards or by an object ID that may not even be
## in the file.  This module reads one, checks it, works out every object's
## name, and writes the `.idx` that makes the pair readable by
## [packfile.nim](packfile.nim) and by git.
##
## ## Why this is the security surface
##
## It is the one place gittle takes bytes from someone else.  The server is
## cut (plan.md §6 decision 2) so gittle never accepts a *push*, but a *fetch*
## is a packfile from the far end all the same, and a hostile or broken server
## is as real as a hostile client.  Three checks, in this order, and nothing
## is installed until all three pass:
##
## 1. **The pack checksum.**  The trailing 20 bytes are SHA-1 over everything
##    before them.  Cheap, and it catches truncation and corruption in transit.
## 2. **Every object's own hash.**  Each object's name is *computed* from the
##    bytes that arrived, never taken from the sender.  A delta that
##    reconstructs to different content than the sender intended therefore
##    gets a different name, and nothing that referred to the intended one
##    will find it.
## 3. **Connectivity** (`checkConnected`, called by `fetch`).  Every object
##    the received commits and trees refer to has to be present -- here or
##    already in the repository.  Without it a server could hand over a commit
##    whose tree is absent, and the ref would be updated to name a history
##    that cannot be read.
##
## Bounds are checked in the reader rather than trusted: `readEntryAt` refuses
## an offset outside the file and a delta base outside the pack,
## `applyDelta` refuses a copy that runs past its base or a result longer than
## its own header promised.
##
## ## Thin packs
##
## A sender that knows what the receiver already has may leave the base of a
## delta *out* of the pack -- that is what `thin-pack` negotiates, and it is
## most of why an incremental fetch is small.  Such a pack cannot stand on its
## own: its `.idx` would list objects whose bytes are only reconstructible
## with an object stored elsewhere, and a later repack would have to go
## looking.  `--fix-thin` completes it, which is what git does and what
## `fetch` always asks for: the missing bases are appended to the pack as
## ordinary objects, the object count in the header is corrected, and the
## trailing checksum is recomputed.  The pack that lands on disk is
## self-contained (`builtin/index-pack.c:fix_unresolved_deltas`).
##
## ## What is not here
##
## No `.rev` file, no multi-pack index, no bitmaps (R3): they are caches git
## writes and gittle only ever declines to read.  No threading: the delta
## resolution is one depth-first walk.

import std/[algorithm, memfiles, os, sets, tables]
import commitobj, oid, objects, packfile, repository, sha1, util, zlib

const
  packHeaderLen = 12
  trailerLen = OidLen
  idxMagic = "\xFFtOc"

type
  Entry = object
    ## One object as it lies in the pack, before and after its name is known.
    offset: int         ## first byte of the header
    endAt: int          ## first byte after the object's zlib stream
    kind: ObjectType    ## as stored: possibly a delta
    baseOffset: int
    baseOid: Oid
    crc: uint32
    oid: Oid
    resolved: bool

  Indexer = ref object
    path: string
    map: MemFile
    pack: ptr UncheckedArray[byte]
    len: int
    entries: seq[Entry]
    byOffset: Table[int, int]      ## pack offset -> index into `entries`
    byOid: Table[Oid, int]         ## resolved name -> index into `entries`
    ofsChildren: Table[int, seq[int]]
    refChildren: Table[Oid, seq[int]]

func be32(b: ptr UncheckedArray[byte], at: int): uint32 {.inline.} =
  (uint32(b[at]) shl 24) or (uint32(b[at+1]) shl 16) or
  (uint32(b[at+2]) shl 8) or uint32(b[at+3])

func put32(s: var string, v: uint32) =
  for i in countdown(3, 0): s.add char((v shr (i * 8)) and 0xFF)

func put64(s: var string, v: uint64) =
  for i in countdown(7, 0): s.add char((v shr (i * 8)) and 0xFF)

# ---------------------------------------------------------------------------
# The file
# ---------------------------------------------------------------------------

proc verifyChecksum(path: string): Oid =
  ## SHA-1 over the whole file except its last 20 bytes, which are that hash.
  ## Read in blocks: this is the one place gittle meets a file it has no
  ## reason to believe fits in memory.
  var f: File
  failIf(not open(f, path), "cannot read '" & path & "'")
  defer: f.close()
  let size = int(f.getFileSize())
  failIf(size < packHeaderLen + trailerLen, "packfile too short: " & path)
  var ctx = initSha1()
  var buf = newString(64 * 1024)
  var left = size - trailerLen
  while left > 0:
    let n = f.readBuffer(addr buf[0], min(buf.len, left))
    failIf(n <= 0, "short read on " & path)
    ctx.update(buf.toOpenArrayByte(0, n - 1))
    left -= n
  let want = ctx.finish().toOid
  var tail = newString(trailerLen)
  failIf(f.readBuffer(addr tail[0], trailerLen) != trailerLen,
         "short read on " & path)
  var got: Oid
  for i in 0 ..< OidLen: got.b[i] = byte(tail[i])
  failIf(got != want,
         "pack checksum mismatch in " & path & "\n  header says " & $got &
         ", contents hash to " & $want)
  want

proc remap(ix: Indexer) =
  if ix.pack != nil: ix.map.close()
  ix.map = memfiles.open(ix.path)
  ix.pack = cast[ptr UncheckedArray[byte]](ix.map.mem)
  ix.len = ix.map.size

proc packObjectCount(ix: Indexer): int =
  for i in 0 ..< 4:
    failIf(char(ix.pack[i]) != "PACK"[i], "bad packfile signature in " & ix.path)
  let v = be32(ix.pack, 4)
  failIf(v != 2 and v != 3, "unsupported pack version " & $v)
  int(be32(ix.pack, 8))

# ---------------------------------------------------------------------------
# Scanning
# ---------------------------------------------------------------------------

proc scan(ix: Indexer, count: int) =
  ## Walk the objects in file order, recording where each begins and ends.
  ##
  ## The end is not written down anywhere: the only way to find it is to
  ## inflate the object and ask zlib how many input bytes it consumed.  That
  ## is also what makes the CRC computable, since it covers the *stored*
  ## bytes -- header, base reference and compressed body.
  var at = packHeaderLen
  for i in 0 ..< count:
    let e = readEntryAt(ix.pack, ix.len, at, ix.path)
    let inflated = inflateEntryAt(ix.pack, ix.len, e)
    var ent = Entry(offset: at, endAt: e.dataAt + inflated.consumed,
                    kind: e.kind, baseOffset: e.baseOffset, baseOid: e.baseOid)
    ent.crc = crc32(addr ix.pack[at], ent.endAt - at)
    if not e.kind.isDelta:
      ent.oid = hashObject(e.kind, inflated.data)
      ent.resolved = true
    ix.byOffset[at] = i
    ix.entries.add ent
    at = ent.endAt
  failIf(at != ix.len - trailerLen,
         "packfile has trailing garbage: " & $(ix.len - trailerLen - at) &
         " bytes after the last object")

proc buildChildLists(ix: Indexer) =
  ix.ofsChildren.clear()
  ix.refChildren.clear()
  ix.byOid.clear()
  for i, e in ix.entries:
    if e.resolved: ix.byOid[e.oid] = i
    case e.kind
    of otOfsDelta: ix.ofsChildren.mgetOrPut(e.baseOffset, @[]).add i
    of otRefDelta: ix.refChildren.mgetOrPut(e.baseOid, @[]).add i
    else: discard

# ---------------------------------------------------------------------------
# Resolving
# ---------------------------------------------------------------------------

proc objectAt(ix: Indexer, i: int): string =
  inflateEntryAt(ix.pack, ix.len, readEntryAt(ix.pack, ix.len,
                                              ix.entries[i].offset,
                                              ix.path)).data

proc resolveChildren(ix: Indexer, i: int, kind: ObjectType, data: string,
                     pending: var int)

proc resolveOne(ix: Indexer, i: int, kind: ObjectType, base: string,
                pending: var int) =
  ## Apply this delta to its base, name the result, and go on to whatever was
  ## waiting on *it*.  Depth-first, so only one chain is ever in memory.
  let content = applyDelta(base, ix.objectAt(i))
  ix.entries[i].kind = kind
  ix.entries[i].oid = hashObject(kind, content)
  ix.entries[i].resolved = true
  dec pending
  ix.resolveChildren(i, kind, content, pending)

proc resolveChildren(ix: Indexer, i: int, kind: ObjectType, data: string,
                     pending: var int) =
  for c in ix.ofsChildren.getOrDefault(ix.entries[i].offset):
    if not ix.entries[c].resolved: ix.resolveOne(c, kind, data, pending)
  for c in ix.refChildren.getOrDefault(ix.entries[i].oid):
    if not ix.entries[c].resolved: ix.resolveOne(c, kind, data, pending)

proc appendObjects(ix: Indexer, objs: seq[GitObject]) =
  ## Write the missing bases onto the end of the pack, fix the object count in
  ## the header, and recompute the trailing checksum
  ## (`fixup_pack_header_footer`).  The file is rewritten in place, so the
  ## mapping has to go and come back.
  ix.map.close()
  ix.pack = nil
  var f: File
  failIf(not open(f, ix.path, fmReadWriteExisting), "cannot extend " & ix.path)
  let oldSize = int(f.getFileSize())
  f.setFilePos(oldSize - trailerLen)
  var body: string
  for o in objs:
    body.add packEntryHeader(o.kind, o.data.len)
    body.add deflateAll(cast[pointer](if o.data.len == 0: nil
                                      else: unsafeAddr o.data[0]),
                        o.data.len, ZBestSpeed)
  f.write body

  # The count in the header changed, so the checksum over the file did too.
  var header = "PACK"
  header.put32 2'u32
  header.put32 uint32(ix.entries.len + objs.len)
  f.setFilePos(0)
  f.write header
  f.setFilePos(0)
  var ctx = initSha1()
  var buf = newString(64 * 1024)
  var left = oldSize - trailerLen + body.len
  while left > 0:
    let n = f.readBuffer(addr buf[0], min(buf.len, left))
    failIf(n <= 0, "short read on " & ix.path)
    ctx.update(buf.toOpenArrayByte(0, n - 1))
    left -= n
  let digest = ctx.finish()
  var trailer = newString(trailerLen)
  for i in 0 ..< OidLen: trailer[i] = char(digest[i])
  f.setFilePos(oldSize - trailerLen + body.len)
  f.write trailer
  f.close()
  ix.remap()

  # And the new objects are entries like any other.
  var at = oldSize - trailerLen
  for o in objs:
    let e = readEntryAt(ix.pack, ix.len, at, ix.path)
    let inflated = inflateEntryAt(ix.pack, ix.len, e)
    let endAt = e.dataAt + inflated.consumed
    ix.byOffset[at] = ix.entries.len
    ix.entries.add Entry(offset: at, endAt: endAt, kind: e.kind,
                         crc: crc32(addr ix.pack[at], endAt - at),
                         oid: hashObject(e.kind, inflated.data), resolved: true)
    at = endAt

proc resolve(ix: Indexer, fixThin: bool,
             findExternal: proc (o: Oid): GitObject) =
  var pending = 0
  for e in ix.entries:
    if not e.resolved: inc pending
  while true:
    ix.buildChildLists()
    for i in 0 ..< ix.entries.len:
      if ix.entries[i].resolved and not ix.entries[i].kind.isDelta:
        ix.resolveChildren(i, ix.entries[i].kind, ix.objectAt(i), pending)
    if pending == 0: return

    # What is left is a thin pack: deltas against objects the sender assumed
    # we already had.  Collect the ones we do have and append them.
    failIf(not fixThin or findExternal == nil,
           "packfile has " & $pending & " unresolved delta" &
           (if pending == 1: "" else: "s") & "\n" &
           "  it is a thin pack; index it with --fix-thin inside a repository " &
           "that has the bases")
    var wanted: seq[Oid]
    var seen: Table[Oid, bool]
    for e in ix.entries:
      if e.resolved or e.kind != otRefDelta: continue
      if ix.byOid.hasKey(e.baseOid) or seen.hasKey(e.baseOid): continue
      seen[e.baseOid] = true
      wanted.add e.baseOid
    var objs: seq[GitObject]
    for o in wanted:
      let got = findExternal(o)
      failIf(got.kind == otBad,
             "packfile is missing the delta base " & $o &
             ", and this repository does not have it either")
      objs.add got
    failIf(objs.len == 0, "packfile has " & $pending & " unresolved deltas")
    ix.appendObjects(objs)

# ---------------------------------------------------------------------------
# Writing the index
# ---------------------------------------------------------------------------

proc writeIdx(ix: Indexer, idxPath: string, packHash: Oid) =
  ## `.idx` version 2, exactly as documented in
  ## [packfile.nim](packfile.nim) and `Documentation/gitformat-pack.adoc`.
  var order = newSeq[int](ix.entries.len)
  for i in 0 ..< order.len: order[i] = i
  order.sort(proc (a, b: int): int = cmp(ix.entries[a].oid, ix.entries[b].oid))
  for k in 1 ..< order.len:
    failIf(ix.entries[order[k]].oid == ix.entries[order[k - 1]].oid,
           "packfile contains " & $ix.entries[order[k]].oid & " twice")

  var buf = idxMagic
  buf.put32 2'u32
  var fanout: array[256, uint32]
  for i in order: inc fanout[int(ix.entries[i].oid.b[0])]
  var running = 0'u32
  for i in 0 .. 255:
    running += fanout[i]
    buf.put32 running
  for i in order:
    for b in ix.entries[i].oid.b: buf.add char(b)
  for i in order: buf.put32 ix.entries[i].crc

  # An offset that does not fit in 31 bits is replaced by an index into a
  # table of 64-bit offsets, flagged by the top bit.  Packs over 2 GiB are the
  # only ones that have any.
  var big: seq[int]
  for i in order:
    let ofs = ix.entries[i].offset
    if ofs < 0x8000_0000:
      buf.put32 uint32(ofs)
    else:
      buf.put32 (0x8000_0000'u32 or uint32(big.len))
      big.add ofs
  for ofs in big: buf.put64 uint64(ofs)

  for b in packHash.b: buf.add char(b)
  let selfHash = sha1(buf)
  for b in selfHash: buf.add char(b)
  writeFileAtomic(idxPath, buf)

# ---------------------------------------------------------------------------
# The entry point
# ---------------------------------------------------------------------------

proc indexPack*(packPath, idxPath: string, fixThin: bool,
                findExternal: proc (o: Oid): GitObject = nil):
    tuple[hash: Oid, nObjects: int] =
  ## Check `packPath`, resolve every delta in it, and write `idxPath`.
  ## Returns the pack's checksum -- which is also the name git gives the pair
  ## (`builtin/index-pack.c:final`) -- and how many objects it holds.
  var hash = verifyChecksum(packPath)
  let ix = Indexer(path: packPath)
  ix.remap()
  defer: (if ix.pack != nil: ix.map.close())
  let count = ix.packObjectCount()
  ix.scan(count)
  ix.resolve(fixThin, findExternal)
  if ix.entries.len != count:
    # fix-thin appended objects, so the checksum computed above is stale.
    hash = verifyChecksum(packPath)
  ix.writeIdx(idxPath, hash)
  (hash, ix.entries.len)

# ---------------------------------------------------------------------------
# Putting one in a repository
# ---------------------------------------------------------------------------

proc installPack*(repo: Repository, tmpPack: string, fixThin: bool):
    tuple[hash: Oid, nObjects: int] =
  ## Index a freshly received pack and move it, with its index, into
  ## `objects/pack/` under the name git would give it -- the pack's own
  ## checksum (`builtin/index-pack.c:final`).
  ##
  ## The `.idx` is renamed **after** the `.pack`, because a reader that finds
  ## an index looks for the pack beside it and fails if it is not there yet,
  ## while a pack with no index is simply invisible.  git orders it the same
  ## way and for the same reason.
  result = indexPack(tmpPack, tmpPack & ".idx", fixThin,
                     proc (o: Oid): GitObject =
                       if repo.hasObject(o): repo.readObject(o)
                       else: GitObject(kind: otBad))
  let dir = repo.objDirs[0] / "pack"
  createDir(dir)
  let base = dir / ("pack-" & $result.hash)
  moveFile(tmpPack, base & ".pack")
  moveFile(tmpPack & ".idx", base & ".idx")
  repo.reopenPacks()

proc checkConnected*(repo: Repository, tips: openArray[Oid]) =
  ## Every object reachable from `tips` is present.
  ##
  ## This is check 3 of the three at the top of this file, and the reason it
  ## is not free: it reads every commit and every tree that arrived.  git runs
  ## the same walk after a fetch (`connected.c:check_connected`, a
  ## `rev-list --objects --not --all`) and for the same reason -- a ref may
  ## not be moved to a commit whose history cannot be read, or the repository
  ## is broken from the next command onwards rather than at the moment the
  ## bad data arrived.
  ##
  ## Blobs are checked for presence but not opened; nothing refers to them.
  var seen: HashSet[Oid]
  var queue: seq[Oid]
  for t in tips:
    if not seen.containsOrIncl(t): queue.add t
  while queue.len > 0:
    let o = queue.pop()
    failIf(not repo.hasObject(o), "the remote did not send " & $o &
           ", which the history it did send refers to")
    let info = repo.objectInfo(o)
    case info.kind
    of otCommit:
      let c = parseCommit(repo.readObject(o).data)
      if not seen.containsOrIncl(c.tree): queue.add c.tree
      for p in c.parents:
        if not seen.containsOrIncl(p): queue.add p
    of otTree:
      for e in treeEntries(repo.readObject(o).data):
        # A gitlink names a commit in a repository that is not this one.
        if e.mode == modeGitlink: continue
        if not seen.containsOrIncl(e.oid): queue.add e.oid
    of otTag:
      let target = parseOid(headerField(repo.readObject(o).data, "object"))
      if not seen.containsOrIncl(target): queue.add target
    else: discard
