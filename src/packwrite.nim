## Writing a packfile: the object order, and R2.
##
## The format is the one [packfile.nim](packfile.nim) describes -- a 12-byte
## header, the objects back to back, a SHA-1 of everything before it -- so
## what a packer actually decides is only two things: which objects, and in
## what form each one is stored.
##
## ## Never search for a delta; pass on the one you were given
##
## This is plan.md's **R2**, and it is the single decision that keeps this
## file at a hundred lines instead of the seven thousand `diff-delta.c` plus
## the window and depth machinery in `builtin/pack-objects.c` come to.
## Measured on the repository next door (plan.md §3.1): git's pack is 304 MiB,
## the same objects stored with no deltas at all are **3,122 MiB**, and the
## same objects with every existing delta *copied through* -- no similarity
## search whatsoever -- are **309 MiB, produced in 2.4 seconds**.
##
## Delta search buys 1.6%.  So: an object that is already stored as a delta in
## a local pack, and whose base is also going out, is copied across still
## compressed and still a delta; everything else is written whole.  A freshly
## committed object has no delta and gets none, which is why a push of new
## work is a little larger than git's and a push of old history is the same
## size.
##
## The one bookkeeping subtlety is that an `OBJ_OFS_DELTA` names its base by
## *distance backwards in this pack*, so a copied delta must be re-headed with
## the distance in the new file, and the base must therefore be written first.
## `emit` below is that ordering, done depth first.

import std/[sets, tables]
import oid, objects, packfile, repository, sha1, util, zlib

type
  PackSink* = proc (data: string) {.closure.}

  Writer = object
    sink: PackSink
    ctx: Sha1Ctx
    written: int
    at: Table[Oid, int]     ## where each object was put, for the delta offsets
    members: HashSet[Oid]   ## what is going out at all

proc put(w: var Writer, data: string) =
  ## Write bytes to the pack: through the running checksum and out.
  if data.len == 0: return
  w.ctx.update(data)
  w.written += data.len
  w.sink(data)

func be32str(v: uint32): string =
  ## A 32-bit field, big-endian, as four bytes.
  result = newString(4)
  for i in 0 .. 3: result[i] = char((v shr ((3 - i) * 8)) and 0xFF)

proc emit(w: var Writer, repo: Repository, o: Oid, depth: int) =
  ## Write one object, once: a stored delta is copied through as a
  ## `ref-delta` after its base (R2), anything else goes whole.
  if w.at.hasKey(o): return
  failIf(depth > 100, "delta chain too deep while writing a pack")

  # Reuse, if the object is already a delta here and its base is going too.
  let (pack, offset) = repo.findPacked(o)
  if pack != nil:
    let d = pack.storedDelta(offset)
    if d.raw.len > 0 and d.base in w.members:
      w.emit(repo, d.base, depth + 1)
      let baseAt = w.at[d.base]
      let here = w.written
      let e = pack.readEntry(offset)
      w.put packEntryHeader(otOfsDelta, e.size)
      w.put ofsDeltaHeader(here - baseAt)
      w.put d.raw
      w.at[o] = here
      return

  let obj = repo.readObject(o)
  let here = w.written
  w.put packEntryHeader(obj.kind, obj.data.len)
  w.put deflateAll(cast[pointer](if obj.data.len == 0: nil
                                 else: unsafeAddr obj.data[0]),
                   obj.data.len, ZBestSpeed)
  w.at[o] = here

proc writePack*(repo: Repository, oids: seq[Oid], sink: PackSink): Oid =
  ## Write a pack containing exactly `oids`, in that order except where a
  ## reused delta forces its base ahead of it.  Returns the pack's checksum,
  ## which is also the name git gives the file.
  var w = Writer(sink: sink, ctx: initSha1())
  for o in oids: w.members.incl o
  w.put "PACK"
  w.put be32str(2)
  w.put be32str(uint32(w.members.len))
  for o in oids: w.emit(repo, o, 0)
  failIf(w.at.len != w.members.len, "pack writer lost an object")
  let digest = w.ctx.finish()
  var trailer = newString(OidLen)
  for i in 0 ..< OidLen: trailer[i] = char(digest[i])
  # The trailer is not part of what it covers, so it goes out unhashed.
  w.sink(trailer)
  digest.toOid
