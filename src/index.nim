## The index: `$GIT_DIR/index`, the `DIRC` format.
##
## The index is a flat, sorted list of every path in the repository with the
## object ID it currently stages and a copy of the file's `stat` data.  It is
## three things at once:
##
## * **the staging area** -- `add` writes it, `commit` turns it into a tree;
## * **a cache** -- the `stat` data exists so `status` can answer "did this
##   change?" for ten thousand files without reading ten thousand files;
## * **the merge scratchpad** -- during a conflict one path has up to three
##   entries, at stages 1, 2 and 3, which is why the sort key is (path, stage).
##
## ## The file
##
##     12 bytes    "DIRC", a version (2, 3 or 4), and the entry count
##     entries     sorted by (path bytes, stage)
##     extensions  a 4-byte signature, a 4-byte length, and that many bytes
##     20 bytes    SHA-1 of everything above
##
## An entry is fixed-width stat data, the object ID, a 16-bit flags word, then
## the path and enough NUL padding to reach a multiple of eight.  Version 3
## adds a second flags word when the entry needs one; version 4 prefix-
## compresses each path against the previous entry's and drops the padding.
##
## Decision 8: v1 **reads 2, 3 and 4** and **writes 2, or 3 when an entry needs
## extended flags** -- which is git's own rule.
##
## ## Two things this file exists to get right
##
## **A zeroed checksum is valid.** `feature.manyFiles` turns on
## `index.skipHash`, and git then writes a trailing hash of all zeroes.  An
## implementation that validates it reports a perfectly good index as corrupt.
##
## **Racily clean entries.**  If a file is modified in the same second the
## index is written, its recorded mtime equals the index's own and no amount of
## stat data can distinguish "unchanged" from "changed after we looked".  git
## handles this when *writing*: an entry whose mtime is not older than the index
## gets its recorded size set to zero, which forces the next reader to compare
## content rather than trust the stat
## (`read-cache.c:ce_smudge_racily_clean_entry`).  gittle does the same, and
## errs toward smudging: an unnecessary smudge costs one hash on the next
## `status`, while a missing one reports a modified file as clean.

import std/[os, posix, times, algorithm, strutils]
import objects, oid, sha1, util

const
  indexSignature = "DIRC"
  entryHeaderLen = 62   ## the fixed part: 10 * 4 bytes of stat, 20 of OID, 2 of flags
  flagExtended = 0x4000'u16
  flagValid = 0x8000'u16
  flagStageMask = 0x3000'u16
  flagNameMask = 0x0FFF'u16
  extFlagSkipWorktree = 0x2000'u16
  extFlagIntentToAdd = 0x1000'u16

type
  IndexEntry* = object
    ## One staged path.  The stat fields are `stat(2)` data verbatim: they are
    ## never interpreted, only compared against a fresh `lstat`.
    ctimeSec*, ctimeNsec*: uint32
    mtimeSec*, mtimeNsec*: uint32
    dev*, ino*: uint32
    mode*: uint32
    uid*, gid*: uint32
    size*: uint32
    oid*: Oid
    flags*: uint16      ## assume-valid, extended, stage, and the name length
    extFlags*: uint16   ## v3+: skip-worktree, intent-to-add
    path*: string

  Index* = ref object
    entries*: seq[IndexEntry]
    version*: int        ## the version it was read as; writing decides afresh
    timestampSec*: int64 ## the index file's own mtime, for the racy check;
                         ## 0 when there was no index to read
    path*: string        ## where it was read from, and where it is written

func stage*(e: IndexEntry): int = int((e.flags and flagStageMask) shr 12)

func skipWorktree*(e: IndexEntry): bool = (e.extFlags and extFlagSkipWorktree) != 0

func cmpEntries*(a, b: IndexEntry): int =
  ## The index's sort order: path as raw bytes, then stage.  No locale, no
  ## special casing of `/` -- which is exactly what makes `write-tree` a single
  ## pass (see trees.nim).
  result = cmp(a.path, b.path)
  if result == 0: result = cmp(a.stage, b.stage)

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

type Reader = object
  data: string
  pos: int

proc need(r: var Reader, n: int) =
  ## Refuse to read past the end -- a truncated index is corrupt, not short.
  failIf(r.pos + n > r.data.len, "index file is truncated")

proc u32(r: var Reader): uint32 =
  ## A big-endian 32-bit field.
  r.need(4)
  result = (uint32(byte(r.data[r.pos])) shl 24) or
           (uint32(byte(r.data[r.pos+1])) shl 16) or
           (uint32(byte(r.data[r.pos+2])) shl 8) or
            uint32(byte(r.data[r.pos+3]))
  r.pos += 4

proc u16(r: var Reader): uint16 =
  ## A big-endian 16-bit field.
  r.need(2)
  result = (uint16(byte(r.data[r.pos])) shl 8) or uint16(byte(r.data[r.pos+1]))
  r.pos += 2

proc varintOffset(r: var Reader): int =
  ## The offset encoding, shared with `OBJ_OFS_DELTA` -- seven bits per byte,
  ## each continuation adding one so no value has two spellings.  Version 4
  ## uses it for the number of bytes to strip from the previous path.
  r.need(1)
  var b = byte(r.data[r.pos])
  inc r.pos
  result = int(b and 0x7F)
  while (b and 0x80) != 0:
    r.need(1)
    b = byte(r.data[r.pos])
    inc r.pos
    result = ((result + 1) shl 7) or int(b and 0x7F)

proc readEntry(r: var Reader, version: int, prev: string): IndexEntry =
  ## One index entry, in the layout of `version` -- v4 takes its path as a
  ## suffix on the previous one.
  let start = r.pos
  result.ctimeSec = r.u32()
  result.ctimeNsec = r.u32()
  result.mtimeSec = r.u32()
  result.mtimeNsec = r.u32()
  result.dev = r.u32()
  result.ino = r.u32()
  result.mode = r.u32()
  result.uid = r.u32()
  result.gid = r.u32()
  result.size = r.u32()
  r.need(OidLen)
  for i in 0 ..< OidLen: result.oid.b[i] = byte(r.data[r.pos + i])
  r.pos += OidLen
  result.flags = r.u16()
  if (result.flags and flagExtended) != 0:
    failIf(version < 3, "extended flags in a version 2 index")
    result.extFlags = r.u16()

  if version >= 4:
    # The path is the previous entry's, minus `strip` trailing bytes, plus a
    # NUL-terminated suffix.  There is no padding.
    let strip = r.varintOffset()
    failIf(strip > prev.len, "index v4 path prefix is longer than the previous path")
    let nul = r.data.find('\0', r.pos)
    failIf(nul < 0, "unterminated path in index")
    result.path = prev[0 ..< prev.len - strip] & r.data[r.pos ..< nul]
    r.pos = nul + 1
  else:
    # The name length lives in the flags unless it is 0xFFF, which means "long,
    # find the NUL".  Reading to the NUL always works, so the length is only
    # used to check the file agrees with itself.
    let nul = r.data.find('\0', r.pos)
    failIf(nul < 0, "unterminated path in index")
    result.path = r.data[r.pos ..< nul]
    let declared = int(result.flags and flagNameMask)
    failIf(declared != flagNameMask.int and declared != result.path.len,
           "index entry name length disagrees with the path")
    # Pad with NULs to a multiple of eight, counting from the entry's start.
    r.pos = start + (((nul - start) + 8) and not 7)

proc skipExtensions(r: var Reader, endAt: int) =
  ## Extensions are `<signature><length><data>`.  A signature beginning `A`-`Z`
  ## is optional and may be skipped; a lowercase one is *required*, and an
  ## implementation that does not understand it must not proceed.
  ##
  ## Every optional extension git defines is a cache (R3), so all of them are
  ## skipped -- and on write they are dropped rather than carried across, since
  ## a cache tree that no longer matches the entries is a `write-tree` that
  ## produces the wrong answer.
  while r.pos + 8 <= endAt:
    let sig = r.data[r.pos ..< r.pos + 4]
    r.pos += 4
    let size = int(r.u32())
    failIf(r.pos + size > endAt, "index extension '" & sig & "' overruns the file")
    if sig[0] notin {'A' .. 'Z'}:
      case sig
      of "link":
        fail("this index is split, which gittle does not read\n" &
             "  Undo it with real git:  git update-index --no-split-index")
      of "sdir":
        fail("this index uses sparse directory entries, which gittle does " &
             "not read\n  Expand it with real git:  git sparse-checkout disable")
      else:
        fail("unknown required index extension '" & sig & "'")
    r.pos += size

proc parseIndex*(data, path: string): Index =
  ## The whole file: header, entries, then the extensions, of which only
  ## the ones gittle understands may be *required*.
  result = Index(path: path)
  if data.len == 0: return          # a missing or empty index is an empty one
  var r = Reader(data: data, pos: 0)
  failIf(data.len < 12 + OidLen, "index file is too short")
  failIf(data[0 ..< 4] != indexSignature,
         "not an index file (bad signature): " & path)
  r.pos = 4
  result.version = int(r.u32())
  failIf(result.version notin 2 .. 4,
         "unsupported index version " & $result.version & " in " & path)
  let count = int(r.u32())

  var prev = ""
  for _ in 0 ..< count:
    let e = readEntry(r, result.version, prev)
    prev = e.path
    result.entries.add e

  # Extensions are checked *before* the entries are validated.  In a split
  # index the entries are deltas against a shared file and several have empty
  # paths, so validating them first would report "empty path" instead of the
  # `link` extension that actually explains the file.
  skipExtensions(r, data.len - OidLen)
  for e in result.entries:
    failIf(e.path.len == 0, "empty path in index: " & path)

  # The trailing checksum, which `index.skipHash` legitimately writes as zeroes.
  var trailer: Oid
  for i in 0 ..< OidLen: trailer.b[i] = byte(data[data.len - OidLen + i])
  if not trailer.isNull:
    var c = initSha1()
    c.update(data.toOpenArrayByte(0, data.len - OidLen - 1))
    failIf(toOid(c.finish()) != trailer, "index checksum mismatch in " & path)

proc readIndex*(path: string): Index =
  ## Read the index file, or an empty v2 index when there is none, and
  ## remember its mtime for the racy-git check.
  if not fileExists(path):
    return Index(path: path, version: 2)
  result = parseIndex(readWholeFile(path), path)
  result.timestampSec = getLastModificationTime(path).toUnix()

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------

type Writer = object
  buf: string

proc u32(w: var Writer, v: uint32) =
  ## A big-endian 32-bit field.
  w.buf.add char((v shr 24) and 0xFF)
  w.buf.add char((v shr 16) and 0xFF)
  w.buf.add char((v shr 8) and 0xFF)
  w.buf.add char(v and 0xFF)

proc u16(w: var Writer, v: uint16) =
  ## A big-endian 16-bit field.
  w.buf.add char((v shr 8) and 0xFF)
  w.buf.add char(v and 0xFF)

proc needsVersion3(idx: Index): bool =
  ## git's own rule: write version 2 unless an entry carries extended flags,
  ## in which case there is nowhere to put them but version 3.
  for e in idx.entries:
    if e.extFlags != 0: return true
  false

proc smudgeRacy(idx: Index, e: var IndexEntry) =
  ## Force a content comparison for an entry that a stat cannot settle.
  ##
  ## Zero is not a plausible size for a file whose entry we are keeping, so a
  ## reader sees a mismatch and falls back to hashing -- which is the answer we
  ## could not give cheaply.
  if idx.timestampSec == 0: return
  if int64(e.mtimeSec) >= idx.timestampSec:
    e.size = 0

proc serializeIndex*(idx: Index): string =
  ## The bytes of the index, byte-exact (R1) -- git will read this file.
  ##
  ## The entries are sorted into a local copy rather than in place: `Index` is
  ## a `ref`, so sorting `idx.entries` would reorder the caller's object as a
  ## side effect of asking for its bytes.
  var entries = idx.entries
  sort(entries, cmpEntries)
  let version = if needsVersion3(idx): 3 else: 2

  var w = Writer()
  w.buf.add indexSignature
  w.u32(uint32(version))
  w.u32(uint32(entries.len))

  for entry in entries:
    var e = entry
    idx.smudgeRacy(e)
    let start = w.buf.len
    w.u32(e.ctimeSec); w.u32(e.ctimeNsec)
    w.u32(e.mtimeSec); w.u32(e.mtimeNsec)
    w.u32(e.dev); w.u32(e.ino); w.u32(e.mode)
    w.u32(e.uid); w.u32(e.gid); w.u32(e.size)
    for i in 0 ..< OidLen: w.buf.add char(e.oid.b[i])

    var flags = e.flags and not (flagExtended or flagNameMask)
    flags = flags or uint16(min(e.path.len, int(flagNameMask)))
    if version >= 3 and e.extFlags != 0: flags = flags or flagExtended
    w.u16(flags)
    if version >= 3 and e.extFlags != 0: w.u16(e.extFlags)

    w.buf.add e.path
    # At least one NUL, then padding to a multiple of eight from the entry's
    # start.  Version 4 would drop this, but v1 never writes version 4.
    w.buf.add '\0'
    while (w.buf.len - start) mod 8 != 0: w.buf.add '\0'

  # No extensions: every one git defines is a cache (R3), and carrying a stale
  # cache tree across a write would make `write-tree` produce the wrong tree.
  var c = initSha1()
  c.update(w.buf)
  let sum = toOid(c.finish())
  result = w.buf
  for i in 0 ..< OidLen: result.add char(sum.b[i])

proc writeIndex*(idx: Index) =
  ## Write through `index.lock` plus `rename`, the same discipline a ref update
  ## uses: a reader never sees a half-written index, and a crash leaves the old
  ## one intact.
  let data = serializeIndex(idx)
  let lockPath = idx.path & ".lock"
  let fd = open(lockPath.cstring, O_WRONLY or O_CREAT or O_EXCL, 0o666.Mode)
  if fd < 0:
    if errno == EEXIST:
      fail("cannot lock the index: " & lockPath & " already exists\n" &
           "  another gittle or git process may be running, or a previous " &
           "one crashed")
    fail("cannot lock the index: " & $strerror(errno))
  discard close(fd)
  try:
    writeFile(lockPath, data)
    moveFile(lockPath, idx.path)
  except CatchableError:
    discard tryRemoveFile(lockPath)
    raise

# ---------------------------------------------------------------------------
# Lookup and mutation
# ---------------------------------------------------------------------------

proc find*(idx: Index, path: string, stage = 0): int =
  ## The position of an entry, or -1.  Binary search: the entries are sorted,
  ## and `ls-files` on a large repository does this once per pathspec.
  var lo = 0
  var hi = idx.entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    let c = cmp(idx.entries[mid].path, path)
    let d = if c != 0: c else: cmp(idx.entries[mid].stage, stage)
    if d == 0: return mid
    elif d < 0: lo = mid + 1
    else: hi = mid
  -1

proc isTracked*(idx: Index, path: string): bool =
  ## Is the path in the index at *any* stage?
  ##
  ## A conflicted path has no stage-0 entry at all, so `find` alone would call
  ## it untracked -- and `status` would list every file in a conflicted merge
  ## under "Untracked files".
  for s in 0 .. 3:
    if idx.find(path, s) >= 0: return true
  false

proc removePath*(idx: Index, path: string): bool =
  ## Remove every stage of `path`.  Returns whether anything was there.
  var kept: seq[IndexEntry]
  for e in idx.entries:
    if e.path != path: kept.add e
    else: result = true
  if result: idx.entries = kept

func setStage*(e: var IndexEntry, stage: int) =
  ## Move an entry to a merge stage.  The stage lives in the flags word beside
  ## the name length, which `serializeIndex` recomputes, so only these two bits
  ## have to be preserved by hand.
  e.flags = (e.flags and not flagStageMask) or (uint16(stage) shl 12)

proc addUnmerged*(idx: Index, entries: openArray[IndexEntry]) =
  ## Insert the stages of one conflicted path together.
  ##
  ## `addEntry` cannot do this one stage at a time: adding an entry replaces
  ## every stage of its path, which is exactly what makes staging a resolution
  ## a single call, and here it would delete the stage just written.
  if entries.len == 0: return
  discard idx.removePath(entries[0].path)
  for e in entries: idx.entries.add e
  sort(idx.entries, cmpEntries)

proc addEntry*(idx: Index, e: IndexEntry) =
  ## Insert or replace, keeping the list sorted.  Adding a merged entry
  ## replaces every stage of that path, which is how resolving a conflict works.
  discard idx.removePath(e.path)
  idx.entries.add e
  sort(idx.entries, cmpEntries)

# ---------------------------------------------------------------------------
# The working tree
# ---------------------------------------------------------------------------

proc modeForFile*(st: Stat): uint32 =
  ## git records exactly three modes for a file: a symlink, or a regular file
  ## that is executable or not.  Everything else about the permission bits is
  ## deliberately discarded -- `core.fileMode` aside, git does not track them.
  if S_ISLNK(st.st_mode): modeSymlink
  elif (st.st_mode.uint32 and 0o111) != 0: modeExecutable
  else: modeRegular

proc statPath*(path: string): tuple[ok: bool, st: Stat] =
  ## `lstat`, as a pair rather than an exception: a missing path is an
  ## ordinary answer here.
  result.ok = lstat(path.cstring, result.st) == 0

proc fillStat*(e: var IndexEntry, st: Stat) =
  ## Copy `stat` data into an entry.  These fields are never interpreted, only
  ## compared against a later `lstat`, so truncation to 32 bits is harmless --
  ## a value that changes still changes.
  e.ctimeSec = uint32(st.st_ctim.tv_sec)
  e.ctimeNsec = uint32(st.st_ctim.tv_nsec)
  e.mtimeSec = uint32(st.st_mtim.tv_sec)
  e.mtimeNsec = uint32(st.st_mtim.tv_nsec)
  e.dev = uint32(st.st_dev)
  e.ino = uint32(st.st_ino)
  e.uid = uint32(st.st_uid)
  e.gid = uint32(st.st_gid)
  e.size = uint32(st.st_size)
  e.mode = modeForFile(st)

proc statMatches*(e: IndexEntry, st: Stat): bool =
  ## Does the stat data say this file is unchanged?
  ##
  ## Only the fields that would change if the content did: size, mtime and the
  ## mode git records.  `ctime`, `dev` and `ino` are recorded but not compared,
  ## because a checkout or a backup restore moves them without touching content.
  e.size == uint32(st.st_size) and
    e.mtimeSec == uint32(st.st_mtim.tv_sec) and
    e.mtimeNsec == uint32(st.st_mtim.tv_nsec) and
    e.mode == modeForFile(st)

proc readWorkingFile*(path: string, st: Stat): string =
  ## The bytes git would hash for this path: a symlink's *target*, not the file
  ## it points at, which is why a symlink is stored as a blob of its target.
  if S_ISLNK(st.st_mode):
    var buf = newString(int(st.st_size) + 1)
    let n = readlink(path.cstring, cast[cstring](addr buf[0]), buf.len)
    failIf(n < 0, "cannot read symlink '" & path & "'")
    buf.setLen(n)
    buf
  else:
    readWholeFile(path)
