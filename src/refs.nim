## The `files` reference backend: reading, resolving and safely updating refs.
##
## R4 says one ref backend, and this is it.  `reftable` is refused outright by
## the extension gate in `repository.nim` (plan.md §6.1) rather than partially
## supported.
##
## ## The four things a name can be
##
## A reference name like `refs/heads/main` can be stored in more than one way,
## and a reader has to check them in the right order:
##
## 1. **A loose ref** -- the file `$GIT_DIR/refs/heads/main`, containing forty
##    hex digits and a newline.  This is what a fresh ref update writes.
## 2. **A packed ref** -- a line in `$GIT_DIR/packed-refs`.  `git gc` moves
##    loose refs here so that a repository with a hundred thousand tags is one
##    file rather than a hundred thousand.  **A loose ref shadows a packed one
##    of the same name**, which is what makes packing safe to do concurrently
##    with updates.
## 3. **A symbolic ref** -- a file whose contents are `ref: refs/heads/main`.
##    HEAD is normally one of these; it is how "the current branch" is stored.
## 4. **Nothing.**  Reading a ref that does not exist is not an error, and
##    several callers depend on that (creating a branch, checking whether one
##    is already there).
##
## ## Where the file lives
##
## In a repository with linked worktrees there are two directories in play.
## Most refs are shared and live in the *common* directory; a few are private
## to one worktree and live in that worktree's own git directory.  The private
## ones are HEAD and the other root-level pseudorefs, plus `refs/worktree/`,
## `refs/bisect/` and `refs/rewritten/` (`refs.c:is_per_worktree_ref`).  Get
## this wrong and two worktrees share a HEAD, which is exactly the thing
## worktrees exist to avoid.
##
## ## Why updating is the hard part
##
## The formats above are trivial.  Updating them safely is not, and that is
## what most of this file is:
##
## * **A reader must never see a half-written ref.**  So a write goes to
##   `<ref>.lock` and is then `rename`d into place, which is atomic on POSIX.
## * **Two writers must not interleave.**  The lock file is created with
##   `O_CREAT | O_EXCL`, so the second writer fails rather than corrupting.
##   This is also why `.lock` is a forbidden suffix in a ref name (refname.nim).
## * **A compare-and-swap must actually compare.**  `update-ref <ref> <new>
##   <old>` has to read the current value *while holding the lock*, or the
##   check is meaningless.
## * **Deleting has two places to look.**  A ref may exist loose, packed, or
##   both, and removing only one leaves it visible through the other.
##
## Reflog writing lives here too, because a ref update is the only thing that
## ever appends to one.  The `reflog` command that reads them back is phase 6.

import std/[os, strutils, algorithm, sequtils, posix]
import oid, objects, refname, ident, util

const
  headRef* = "HEAD"
  refsPrefix* = "refs/"
  packedRefsFile = "packed-refs"
  lockSuffix = ".lock"
  maxSymrefDepth = 5
    ## git's own limit (`refs.c`).  A chain longer than this is a loop.

type
  Ref* = object
    ## One reference, however it happened to be stored.
    name*: string       ## the full name, e.g. `refs/heads/main`
    oid*: Oid           ## its value; `nullOid` when it is symbolic
    symTarget*: string  ## the ref it points at, or "" when it is direct
    peeled*: Oid        ## an annotated tag's target, if `packed-refs` recorded it
    hasPeeled*: bool
    packed*: bool       ## it came from `packed-refs`, not a file

  LogRefsPolicy* = enum
    ## `core.logAllRefUpdates`, resolved (`refs.c:should_autocreate_reflog`).
    lrNone     ## never create a reflog; append only where one already exists
    lrNormal   ## create for refs/heads/, refs/remotes/, refs/notes/ and HEAD
    lrAlways   ## create for every ref

  RefStore* = ref object
    ## Everything the ref layer needs, without a dependency on `Repository`.
    ## `repository.nim` builds one of these and hands it out.
    gitDir*: string      ## this worktree's git directory
    commonDir*: string   ## the shared one; equal to `gitDir` outside a worktree
    logPolicy*: LogRefsPolicy
    identFn*: proc (): Ident {.closure.}
      ## Deferred on purpose: reading refs must never require an identity, and
      ## demanding one would make `for-each-ref` fail in a repository where
      ## `user.email` is unset.
    objectKindFn*: proc (o: Oid): ObjectType {.closure.}
      ## The type of an object, or `otBad` if it is not in the database.
      ## Supplied by `repository.nim` so that a ref can never be pointed at an
      ## object that is not there -- see `checkNewValue`.
    packed: seq[Ref]
    packedLoaded: bool

func isSymbolic*(r: Ref): bool = r.symTarget.len > 0

# ---------------------------------------------------------------------------
# Where things live
# ---------------------------------------------------------------------------

func isPerWorktreeRef*(name: string): bool =
  ## Is this ref private to one worktree rather than shared?
  ## `refs.c:is_per_worktree_ref`, plus the root-level pseudorefs: anything
  ## that is not under `refs/` at all (HEAD, ORIG_HEAD, MERGE_HEAD, …) belongs
  ## to the worktree that is using it.
  if not name.startsWith(refsPrefix): return true
  name.startsWith("refs/worktree/") or name.startsWith("refs/bisect/") or
    name.startsWith("refs/rewritten/")

func baseDir*(s: RefStore, name: string): string =
  if isPerWorktreeRef(name): s.gitDir else: s.commonDir

func refPath*(s: RefStore, name: string): string =
  ## The loose file for `name`, whether or not it exists.
  s.baseDir(name) / name

func reflogPath*(s: RefStore, name: string): string =
  s.baseDir(name) / "logs" / name

func packedRefsPath*(s: RefStore): string =
  ## Always shared: `packed-refs` never holds a per-worktree ref.
  s.commonDir / packedRefsFile

# ---------------------------------------------------------------------------
# Reading
# ---------------------------------------------------------------------------

proc parseRefContents(text, path: string): Ref =
  ## The contents of a loose ref file: either `ref: <name>` or an object ID.
  ##
  ## Tolerant on purpose (R1).  FETCH_HEAD in particular carries extra columns
  ## after the object ID, and several tools write a ref with no trailing
  ## newline, so anything after the value is ignored rather than rejected.
  var body = text
  if body.startsWith("ref:"):
    result.symTarget = body[4 .. ^1].strip()
    failIf(result.symTarget.len == 0, "empty symbolic ref in " & path)
    return
  body = body.strip()
  # Stop at the first whitespace: FETCH_HEAD lines are `<oid>\t<description>`.
  let sp = body.find({' ', '\t', '\n'})
  if sp >= 0: body = body[0 ..< sp]
  failIf(not tryParseOid(body, result.oid),
         "invalid object name in " & path & ": '" & body & "'")

proc readLooseRef(s: RefStore, name: string): tuple[found: bool, r: Ref] =
  let path = s.refPath(name)
  if not fileExists(path): return (false, Ref())
  var raw: string
  try:
    raw = readFile(path)
  except IOError, OSError:
    # A ref that vanished between the `fileExists` and the read is simply
    # absent; another process packing refs does exactly this.
    return (false, Ref())
  result.r = parseRefContents(raw, path)
  result.r.name = name
  result.found = true

proc loadPackedRefs(s: RefStore) =
  ## Parse `packed-refs` once per process.
  ##
  ## The format is a header comment naming the traits the writer guaranteed,
  ## then one `<oid> <refname>` line per ref, each optionally followed by a
  ## `^<oid>` line giving what an annotated tag peels to.  gittle does not rely
  ## on the `sorted` trait -- it sorts the result itself, which costs nothing
  ## at this scale and removes a way to be wrong about someone else's file.
  if s.packedLoaded: return
  s.packedLoaded = true
  let path = s.packedRefsPath
  if not fileExists(path): return
  var lineNo = 0
  for line in readWholeFile(path).splitLines:
    inc lineNo
    if line.len == 0: continue
    if line[0] == '#': continue
    if line[0] == '^':
      failIf(s.packed.len == 0, path & ":" & $lineNo & ": peel line with no ref")
      failIf(not tryParseOid(line[1 .. ^1].strip(), s.packed[^1].peeled),
             path & ":" & $lineNo & ": invalid peeled object name")
      s.packed[^1].hasPeeled = true
      continue
    let sp = line.find(' ')
    failIf(sp < 0, path & ":" & $lineNo & ": malformed packed-refs line")
    var r = Ref(name: line[sp + 1 .. ^1].strip(), packed: true)
    failIf(not tryParseOid(line[0 ..< sp], r.oid),
           path & ":" & $lineNo & ": invalid object name")
    s.packed.add r
  sort(s.packed, proc (a, b: Ref): int = cmp(a.name, b.name))

proc lookupPacked(s: RefStore, name: string): tuple[found: bool, r: Ref] =
  s.loadPackedRefs()
  var lo = 0
  var hi = s.packed.len
  while lo < hi:
    let mid = (lo + hi) div 2
    let c = cmp(s.packed[mid].name, name)
    if c == 0: return (true, s.packed[mid])
    elif c < 0: lo = mid + 1
    else: hi = mid
  (false, Ref())

proc readRef*(s: RefStore, name: string): tuple[found: bool, r: Ref] =
  ## Read one ref by its full name, without following symbolic refs.
  ## Loose first: a loose ref shadows a packed one of the same name.
  result = s.readLooseRef(name)
  if result.found: return
  result = s.lookupPacked(name)

proc refExists*(s: RefStore, name: string): bool =
  s.readRef(name).found

proc resolveRef*(s: RefStore, name: string):
    tuple[found: bool, finalName: string, oid: Oid] =
  ## Follow symbolic refs to the object ID at the end of the chain.
  ##
  ## A symbolic ref whose target does not exist is *not* an error: that is
  ## exactly the state of HEAD in a repository with no commits yet, where HEAD
  ## points at `refs/heads/main` and `refs/heads/main` does not exist.  Callers
  ## get `found = false` with `finalName` set to the branch that would be
  ## created, which is what `commit` needs to know.
  var current = name
  for _ in 0 ..< maxSymrefDepth:
    let (found, r) = s.readRef(current)
    if not found:
      return (false, current, nullOid)
    if r.isSymbolic:
      current = r.symTarget
      continue
    return (true, current, r.oid)
  fail("too many levels of symbolic refs starting at " & name)

# ---------------------------------------------------------------------------
# Iteration
# ---------------------------------------------------------------------------

iterator walkLooseRefs(dir, prefix: string): tuple[name, path: string] =
  ## Every file under `dir`, yielding `prefix`-relative names.  Recursion is
  ## explicit rather than `walkDirRec` so a broken symlink or a directory that
  ## disappears mid-walk cannot abort the whole listing.
  var stack = @[(dir, prefix)]
  while stack.len > 0:
    let (d, p) = stack.pop()
    if not dirExists(d): continue
    var entries: seq[tuple[kind: PathComponent, path: string]]
    try:
      for kind, path in walkDir(d): entries.add (kind, path)
    except OSError:
      continue
    for (kind, path) in entries:
      let name = p & path.lastPathPart
      case kind
      of pcDir, pcLinkToDir: stack.add (path, name & "/")
      else:
        if not path.lastPathPart.endsWith(lockSuffix):
          yield (name, path)

proc allRefs*(s: RefStore, prefix = refsPrefix): seq[Ref] =
  ## Every ref under `prefix`, loose and packed merged, sorted by name.
  ##
  ## Both worktree-private and shared refs are included, since a caller asking
  ## for "the refs" means the ones visible from here.
  var seen = newSeq[string]()

  # Both directories are walked: the common one holds the shared refs, and a
  # linked worktree's own directory holds its private ones.  Outside a worktree
  # the two are the same path, so the second walk is skipped.
  var bases = @[s.commonDir]
  if s.gitDir != s.commonDir: bases.add s.gitDir
  for base in bases:
    for (name, _) in walkLooseRefs(base / prefix, prefix):
      if name in seen: continue
      let (found, r) = s.readLooseRef(name)
      if found:
        seen.add name
        result.add r

  s.loadPackedRefs()
  for r in s.packed:
    if r.name.startsWith(prefix) and r.name notin seen:
      result.add r

  sort(result, proc (a, b: Ref): int = cmp(a.name, b.name))

# ---------------------------------------------------------------------------
# The DWIM search order
# ---------------------------------------------------------------------------

const revParseRules* = ["", refsPrefix, "refs/tags/", "refs/heads/",
                        "refs/remotes/", "refs/remotes/@/HEAD"]
  ## `refs.c:ref_rev_parse_rules`, in order.  `@` marks where the abbreviated
  ## name is substituted; every other rule is a plain prefix.  The order is why
  ## a tag beats a branch of the same name.

proc dwimRef*(s: RefStore, name: string): tuple[found: bool, full: string, oid: Oid] =
  ## Turn a name a human typed -- `main`, `v1.0`, `origin/main`, `HEAD` -- into
  ## a full ref name and its value, trying git's rules in git's order.
  for rule in revParseRules:
    let candidate = if rule.len == 0: name
                    elif rule.endsWith("/HEAD"): rule[0 ..< rule.len - 6] & name & "/HEAD"
                    else: rule & name
    # A one-level name is only a ref if it looks like a pseudoref; this stops
    # `gittle cat-file -t master` from being answered by a stray file called
    # `master` in the git directory.
    if not candidate.startsWith(refsPrefix) and
       not isValidRefname(candidate, {rfAllowOneLevel}):
      continue
    let (found, full, oid) = s.resolveRef(candidate)
    if found: return (true, full, oid)
  (false, "", nullOid)

# ---------------------------------------------------------------------------
# Reflog
# ---------------------------------------------------------------------------

func normalizeReflogMsg*(msg: string): string =
  ## Collapse runs of whitespace to single spaces and trim
  ## (`refs.c:copy_reflog_msg`).  A reflog entry is one line by construction --
  ## the message is the last field and a newline ends the record -- so an
  ## embedded newline would corrupt the file rather than merely look untidy.
  var wasSpace = true
  for c in msg:
    let isSpace = c in Whitespace
    if wasSpace and isSpace: continue
    result.add(if isSpace: ' ' else: c)
    wasSpace = isSpace
  result = result.strip(leading = false)

proc shouldAutocreateReflog(s: RefStore, name: string): bool =
  case s.logPolicy
  of lrAlways: true
  of lrNone: false
  of lrNormal:
    name.startsWith("refs/heads/") or name.startsWith("refs/remotes/") or
      name.startsWith("refs/notes/") or name == headRef

proc willWriteReflog*(s: RefStore, name: string): bool =
  ## Would an update to `name` produce a reflog entry?  `prepare` asks so that
  ## it can demand the writer's identity before anything is renamed.
  fileExists(s.reflogPath(name)) or s.shouldAutocreateReflog(name)

proc appendReflog(s: RefStore, name: string, oldOid, newOid: Oid, msg: string) =
  ## Append one entry, creating the log only where the policy says to.
  ##
  ## Where the policy says not to, an *existing* log is still appended to: a
  ## user who ran `git config core.logAllRefUpdates true` once and then turned
  ## it off still expects the logs they already have to stay coherent.
  let path = s.reflogPath(name)
  let exists = fileExists(path)
  if not exists and not s.shouldAutocreateReflog(name): return
  if not exists: createDir(parentDir(path))

  var line = $oldOid & " " & $newOid & " " & $s.identFn()
  let m = normalizeReflogMsg(msg)
  if m.len > 0: line.add "\t" & m
  line.add "\n"

  let f = open(path, fmAppend)
  defer: f.close()
  f.write(line)

# ---------------------------------------------------------------------------
# Writing
# ---------------------------------------------------------------------------
#
# Every write goes through a transaction, even a single one.  `update-ref
# --stdin` is defined to be all-or-nothing -- a batch that fails must leave
# every ref exactly as it was -- and a fetch or a push applies a batch of ref
# updates with the same requirement.  Building the single-ref case on top of
# the batch case is cheaper than having two code paths that must agree.
#
# The shape is the same as git's:
#
#   prepare   take every lock, verify every old value, decide what to write
#   commit    rename every lock into place
#   abort     drop every lock, changing nothing
#
# Locks are taken in sorted name order.  That is not cosmetic: two processes
# updating the same pair of refs in opposite orders would otherwise deadlock,
# and since `O_EXCL` never waits, they would both fail instead of one winning.

type
  RefUpdateKind* = enum
    ruSet          ## point the ref at an object ID
    ruDelete       ## remove the ref wherever it is stored
    ruSetSymbolic  ## point the ref at another ref
    ruVerify       ## assert the current value and change nothing
                   ## -- `update-ref --stdin`'s `verify`, which exists so a
                   ## batch can be conditional on refs it does not modify

  RefUpdate* = object
    ## One requested change.  The `have*` flags matter: "no old value given"
    ## and "old value given as the null OID" are different requirements that
    ## would otherwise be the same field.
    kind*: RefUpdateKind
    name*: string
    newOid*: Oid
    newTarget*: string
    oldOid*: Oid
    oldTarget*: string
    haveOldOid*: bool     ## an expected object ID was specified
    haveOldTarget*: bool  ## an expected symref target was specified
    noDeref*: bool        ## act on this ref itself, not on what it points at
    msg*: string          ## reflog reason

  RefLock = object
    ## A held `<ref>.lock`.  `commitLock` renames it into place; anything else
    ## must `rollback`, including on the way out of an exception.
    path: string       ## the ref file the lock stands for
    lockPath: string
    fd: cint
    held: bool

  TxState = enum txOpen, txPrepared, txClosed

  Plan = object
    ## What `prepare` decided to do about one update.
    target: string    ## the ref actually written, after following symrefs
    alias: string     ## the symref we came through, or "" -- it gets a reflog
                      ## entry of its own, which is how HEAD keeps a history
                      ## even though the branch is what moves
    before: Oid       ## the value before the change, for the reflog
    content: string   ## bytes to write; empty when nothing is written
    delete: bool
    verifyOnly: bool  ## locked and checked, but left exactly as it was
    msg: string

  RefTransaction* = ref object
    store: RefStore
    updates: seq[RefUpdate]
    locks: seq[RefLock]
    plans: seq[Plan]
    state: TxState

func isPrepared*(tx: RefTransaction): bool = tx.state == txPrepared
func isClosed*(tx: RefTransaction): bool = tx.state == txClosed

# -- locks ------------------------------------------------------------------

proc rollback(l: var RefLock) =
  if l.held:
    if l.fd >= 0:
      discard close(l.fd)
      l.fd = -1
    discard tryRemoveFile(l.lockPath)
    l.held = false

proc checkNoDirFileConflict(s: RefStore, name: string) =
  ## `refs/heads/a` and `refs/heads/a/b` cannot both exist: one needs a file
  ## where the other needs a directory.  Detecting it here turns a confusing
  ## `mkdir` failure into a message that names the ref in the way.
  var prefix = ""
  for part in name.split('/'):
    if prefix.len > 0 and fileExists(s.refPath(prefix)):
      fail("cannot lock ref '" & name & "': '" & prefix &
           "' exists and is not a directory")
    prefix = if prefix.len == 0: part else: prefix & "/" & part
  if dirExists(s.refPath(name)):
    fail("cannot lock ref '" & name & "': there are refs beneath it")

proc lockRef(s: RefStore, name: string): RefLock =
  ## Take `<ref>.lock`.
  ##
  ## `O_CREAT | O_EXCL` is the entire mutual-exclusion mechanism: if the file
  ## already exists another process holds the ref, and we fail immediately
  ## rather than wait.  Waiting would risk a deadlock no timeout could tell
  ## apart from a crashed process holding a stale lock.
  s.checkNoDirFileConflict(name)
  result.path = s.refPath(name)
  result.lockPath = result.path & lockSuffix
  createDir(parentDir(result.path))
  result.fd = open(result.lockPath.cstring,
                   O_WRONLY or O_CREAT or O_EXCL, 0o666.Mode)
  if result.fd < 0:
    if errno == EEXIST:
      fail("cannot lock ref '" & name & "': it is already locked\n" &
           "  another gittle or git process may be running, or a previous " &
           "one crashed;\n  if you are sure none is, remove " & result.lockPath)
    fail("cannot lock ref '" & name & "': " & $strerror(errno))
  result.held = true

proc writeLock(l: var RefLock, content: string) =
  ## Fill the lock file, but leave it a lock: nothing is visible yet.
  let n = write(l.fd, content.cstring, content.len)
  failIf(n != content.len, "short write to " & l.lockPath)
  failIf(close(l.fd) != 0, "cannot close " & l.lockPath)
  l.fd = -1

proc commitLock(l: var RefLock) =
  ## `rename` is atomic on POSIX, so a concurrent reader sees either the old
  ## value or the new one and never a mixture.
  moveFile(l.lockPath, l.path)
  l.held = false

proc releaseAfterDelete(l: var RefLock) =
  if l.fd >= 0:
    discard close(l.fd)
    l.fd = -1
  discard tryRemoveFile(l.lockPath)
  l.held = false

# -- packed-refs and leftovers ----------------------------------------------

proc rewritePackedRefsWithout(s: RefStore, names: seq[string]) =
  ## Remove `names` from `packed-refs`, rewriting the file under its own lock.
  ##
  ## The header is regenerated and deliberately does *not* claim `peeled` or
  ## `fully-peeled`.  gittle copies through the peel lines it finds but never
  ## computes one, so claiming every tag is peeled would be a lie a later
  ## reader is entitled to act on.
  s.loadPackedRefs()
  var keep: seq[Ref]
  var removedAny = false
  for r in s.packed:
    if r.name in names: removedAny = true
    else: keep.add r
  if not removedAny: return

  let path = s.packedRefsPath
  let lockPath = path & lockSuffix
  let fd = open(lockPath.cstring, O_WRONLY or O_CREAT or O_EXCL, 0o666.Mode)
  if fd < 0:
    if errno == EEXIST: fail("cannot lock " & path & ": it is already locked")
    fail("cannot lock " & path & ": " & $strerror(errno))
  discard close(fd)

  var text = "# pack-refs with: sorted \n"
  for r in keep:
    text.add $r.oid & " " & r.name & "\n"
    if r.hasPeeled: text.add "^" & $r.peeled & "\n"
  try:
    writeFile(lockPath, text)
    moveFile(lockPath, path)
  except CatchableError:
    discard tryRemoveFile(lockPath)
    raise
  s.packed = keep

proc pruneEmptyRefDirs(s: RefStore, name: string) =
  ## Remove the directories a deleted ref left behind, so `refs/heads` does not
  ## slowly fill with empty trees.  Stops at `refs/`, and any failure just ends
  ## the walk: a directory that is not empty simply stays.
  var dir = parentDir(s.refPath(name))
  let stopAt = s.baseDir(name) / "refs"
  while dir.len > stopAt.len and dir.startsWith(stopAt):
    try:
      if toSeq(walkDir(dir)).len > 0: break
      removeDir(dir)
    except CatchableError:
      break
    dir = parentDir(dir)

# -- the transaction --------------------------------------------------------

proc newTransaction*(s: RefStore): RefTransaction =
  RefTransaction(store: s, state: txOpen)

proc add*(tx: RefTransaction, u: RefUpdate) =
  ## Queue a change.  Nothing is locked or checked until `prepare`.
  failIf(tx.state != txOpen, "ref transaction is no longer open")
  failIf(not isValidRefname(u.name, {rfAllowOneLevel}),
         "invalid ref name: '" & u.name & "'")
  if u.kind == ruSet:
    failIf(u.newOid.isNull,
           "refusing to set '" & u.name & "' to the null object ID")
  if u.kind == ruSetSymbolic:
    failIf(not isValidRefname(u.newTarget, {rfAllowOneLevel}),
           "invalid ref target: '" & u.newTarget & "'")
  tx.updates.add u

proc abort*(tx: RefTransaction) =
  ## Drop every lock.  Safe before `prepare`, and safe to call twice.
  for i in 0 ..< tx.locks.len:
    tx.locks[i].rollback()
  tx.locks.setLen(0)
  tx.plans.setLen(0)
  tx.state = txClosed

func isBranch(name: string): bool = name.startsWith("refs/heads/")

proc checkNewValue(s: RefStore, u: RefUpdate, target: string) =
  ## A ref must name an object that exists, and a branch must name a commit.
  ##
  ## Without this a typo produces a repository that `git fsck` calls broken and
  ## that every later command trips over -- and the object ID is well-formed,
  ## so nothing else would catch it.  git makes the same two checks in
  ## `refs.c:ref_transaction_commit`.
  if u.kind != ruSet or s.objectKindFn == nil: return
  let kind = s.objectKindFn(u.newOid)
  failIf(kind == otBad,
         "trying to write ref '" & u.name & "' with nonexistent object " &
         $u.newOid)
  failIf(kind != otCommit and isBranch(target),
         "trying to write non-commit object " & $u.newOid & " to branch '" &
         target & "'")

proc verifyOld(s: RefStore, u: RefUpdate, name: string) =
  ## The compare half of compare-and-swap, run with the lock held -- which is
  ## the only way the answer stays true long enough to act on.
  if u.haveOldTarget:
    let (found, rf) = s.readRef(name)
    failIf(not found or not rf.isSymbolic,
           "cannot lock ref '" & u.name & "': expected a symbolic ref with " &
           "target '" & u.oldTarget & "'")
    failIf(rf.symTarget != u.oldTarget,
           "cannot lock ref '" & u.name & "': is at " & rf.symTarget &
           " but expected " & u.oldTarget)
    return

  if not u.haveOldOid: return

  let (resolved, _, current) = s.resolveRef(name)
  if u.oldOid.isNull:
    # The null object ID means "must not exist"; this is how `create` and
    # git's own `--create-reflog`-free branch creation express themselves.
    failIf(resolved,
           "cannot lock ref '" & u.name & "': reference already exists")
  else:
    failIf(not resolved,
           "cannot lock ref '" & u.name & "': unable to resolve reference '" &
           u.name & "'")
    failIf(current != u.oldOid,
           "cannot lock ref '" & u.name & "': is at " & $current &
           " but expected " & $u.oldOid)

proc prepare*(tx: RefTransaction) =
  ## Take every lock and check every precondition.  Once this returns, `commit`
  ## cannot fail for any reason gittle can foresee.
  failIf(tx.state != txOpen, "ref transaction is no longer open")
  let s = tx.store

  sort(tx.updates, proc (a, b: RefUpdate): int = cmp(a.name, b.name))
  for i in 1 ..< tx.updates.len:
    failIf(tx.updates[i].name == tx.updates[i-1].name,
           "multiple updates for ref '" & tx.updates[i].name &
           "' are not allowed")

  try:
    for u in tx.updates:
      var p = Plan(msg: u.msg, target: u.name)

      # Following a symbolic ref is the default: `update-ref HEAD <oid>` moves
      # the branch HEAD names rather than turning HEAD into a direct ref.  The
      # `symref-*` commands and `--no-deref` opt out.
      if not u.noDeref and u.kind != ruSetSymbolic:
        var depth = 0
        while true:
          let (found, rf) = s.readRef(p.target)
          if not found or not rf.isSymbolic: break
          if p.alias.len == 0: p.alias = p.target
          inc depth
          failIf(depth > maxSymrefDepth,
                 "too many levels of symbolic refs starting at " & u.name)
          p.target = rf.symTarget

      var lock = s.lockRef(p.target)
      tx.locks.add lock
      s.checkNewValue(u, p.target)
      s.verifyOld(u, p.target)
      p.before = s.resolveRef(p.target).oid

      case u.kind
      of ruSet: p.content = $u.newOid & "\n"
      of ruSetSymbolic: p.content = "ref: " & u.newTarget & "\n"
      of ruDelete: p.delete = true
      of ruVerify: p.verifyOnly = true
      tx.plans.add p

    # If any of this will write a reflog, resolve the identity *now*.  An
    # unset `user.email` discovered after the first rename would leave the
    # batch half applied, which is exactly what the transaction exists to
    # prevent -- and the identity is the one input that can fail this late.
    for p in tx.plans:
      if not p.delete and not p.verifyOnly and
         (s.willWriteReflog(p.target) or
          (p.alias.len > 0 and s.willWriteReflog(p.alias))):
        discard s.identFn()
        break

    tx.state = txPrepared
  except CatchableError:
    tx.abort()
    raise

proc commit*(tx: RefTransaction) =
  ## Make every prepared change visible, then record it.
  ##
  ## Reflogs are appended after the renames, not before, so a log never claims
  ## a change that did not happen.  The reverse -- a change with no log entry --
  ## is the survivable failure of the two.
  failIf(tx.state != txPrepared, "ref transaction has not been prepared")
  let s = tx.store
  var deleted: seq[string]

  for i in 0 ..< tx.plans.len:
    if tx.plans[i].verifyOnly:
      # The check already happened under the lock in `prepare`; all that is
      # left is to let go without touching the ref.
      tx.locks[i].rollback()
    elif tx.plans[i].delete:
      discard tryRemoveFile(tx.locks[i].path)
      tx.locks[i].releaseAfterDelete()
      deleted.add tx.plans[i].target
    else:
      tx.locks[i].writeLock(tx.plans[i].content)
      tx.locks[i].commitLock()
  tx.locks.setLen(0)

  # One rewrite for the whole batch: `packed-refs` is a single file, and
  # rewriting it once per deleted ref would be quadratic in a `fetch --prune`.
  if deleted.len > 0:
    s.rewritePackedRefsWithout(deleted)

  for p in tx.plans:
    if p.verifyOnly: continue
    if p.delete:
      # The reflog goes with the ref.  Leaving it behind would make a branch of
      # the same name, created later, appear to continue the deleted one.
      discard tryRemoveFile(s.reflogPath(p.target))
      s.pruneEmptyRefDirs(p.target)
      continue
    let after = s.resolveRef(p.target).oid
    s.appendReflog(p.target, p.before, after, p.msg)
    if p.alias.len > 0:
      s.appendReflog(p.alias, p.before, after, p.msg)

  tx.state = txClosed

template withTransaction(store: RefStore, tx, body: untyped) =
  ## Run a single change as a transaction of one, aborting on any failure.
  let tx = newTransaction(store)
  try:
    body
    tx.prepare()
    tx.commit()
  except CatchableError:
    tx.abort()
    raise

# -- single-update conveniences ---------------------------------------------

proc updateRef*(s: RefStore, name: string, newOid: Oid, oldOid = nullOid,
                checkOld = false, msg = "") =
  ## Point `name` at `newOid`, following it if it is a symbolic ref.
  withTransaction(s, tx):
    tx.add RefUpdate(kind: ruSet, name: name, newOid: newOid,
                     oldOid: oldOid, haveOldOid: checkOld, msg: msg)

proc deleteRef*(s: RefStore, name: string, oldOid = nullOid, checkOld = false,
                noDeref = false, msg = "") =
  ## Remove `name` wherever it is stored: the loose file, `packed-refs`, or both.
  withTransaction(s, tx):
    tx.add RefUpdate(kind: ruDelete, name: name, oldOid: oldOid,
                     haveOldOid: checkOld, noDeref: noDeref, msg: msg)

proc writeSymRef*(s: RefStore, name, target: string, msg = "") =
  ## Make `name` a symbolic ref pointing at `target`.
  withTransaction(s, tx):
    tx.add RefUpdate(kind: ruSetSymbolic, name: name, newTarget: target,
                     msg: msg)

proc newRefStore*(gitDir, commonDir: string, policy: LogRefsPolicy,
                  identFn: proc (): Ident {.closure.},
                  objectKindFn: proc (o: Oid): ObjectType {.closure.} = nil): RefStore =
  RefStore(gitDir: gitDir, commonDir: commonDir, logPolicy: policy,
           identFn: identFn, objectKindFn: objectKindFn)
