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

import std/[os, strutils, algorithm, sequtils, sets, posix]
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

# A symbolic ref names another ref rather than an object.
func isSymbolic*(r: Ref): bool = r.symTarget.len > 0

func found*(r: Ref): bool = r.name.len > 0
  ## A ref with no name is one that is not there.  Reading a ref that does not
  ## exist is not an error -- creating a branch and checking whether one is
  ## already present both depend on that -- so absence needs a representation,
  ## and the name is already it.

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
  ## The directory a ref lives under: per-worktree ones in `gitDir`, the
  ## rest in the common dir.
  if isPerWorktreeRef(name): s.gitDir else: s.commonDir

func refPath*(s: RefStore, name: string): string =
  ## The loose file for `name`, whether or not it exists.
  s.baseDir(name) / name

func reflogPath*(s: RefStore, name: string): string =
  ## The reflog file under `logs/`.
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

proc readLooseRef(s: RefStore, name: string): Ref =
  ## A loose ref file, or not found; a symref when it starts `ref: `.
  let path = s.refPath(name)
  if not fileExists(path): return
  var raw: string
  try:
    raw = readFile(path)
  except IOError, OSError:
    # A ref that vanished between the `fileExists` and the read is simply
    # absent; another process packing refs does exactly this.
    return
  result = parseRefContents(raw, path)
  result.name = name

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
  let path = s.packedRefsPath   # named in every error message below
  var lineNo = 0
  for line in readIfExists(path).splitLines:
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

proc readRef*(s: RefStore, name: string): Ref =
  ## Read one ref by its full name, without following symbolic refs.
  ## Loose first: a loose ref shadows a packed one of the same name.
  result = s.readLooseRef(name)
  if result.found: return
  s.loadPackedRefs()
  var lo = 0
  var hi = s.packed.len
  while lo < hi:
    let mid = (lo + hi) div 2
    let c = cmp(s.packed[mid].name, name)
    if c == 0: return s.packed[mid]
    elif c < 0: lo = mid + 1
    else: hi = mid

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
    let r = s.readRef(current)
    if not r.found:
      return (false, current, nullOid)
    if r.isSymbolic:
      current = r.symTarget
      continue
    return (true, current, r.oid)
  fail("too many levels of symbolic refs starting at " & name)

# ---------------------------------------------------------------------------
# Iteration
# ---------------------------------------------------------------------------

proc allRefs*(s: RefStore, prefix = refsPrefix): seq[Ref] =
  ## Every ref under `prefix`, loose and packed merged, sorted by name.
  ##
  ## Both worktree-private and shared refs are included, since a caller asking
  ## for "the refs" means the ones visible from here.  `walkDirRec` with
  ## `checkDir = false` yields nothing for a directory that is absent, which is
  ## the ordinary state of `refs/` in a repository whose refs are all packed.
  var seen = initHashSet[string]()

  # Two directories: the common one holds the shared refs, and a linked
  # worktree's own holds its private ones.  Outside a worktree they are the
  # same path, so the second walk is skipped.
  var bases = @[s.commonDir]
  if s.gitDir != s.commonDir: bases.add s.gitDir
  for base in bases:
    for rel in walkDirRec(base / prefix, relative = true, checkDir = false):
      if rel.endsWith(lockSuffix): continue
      let name = prefix & rel
      if name in seen: continue
      let r = s.readLooseRef(name)
      if r.found:
        seen.incl name
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

proc refExists(s: RefStore, name: string): bool =
  ## Does the ref resolve to anything, loose or packed?
  s.readRef(name).found

func expandRule*(rule, name: string): string =
  ## One `revParseRules` entry with the abbreviated name substituted:
  ## `refs/tags/` and `v1` make `refs/tags/v1`, and `refs/remotes/@/HEAD` and
  ## `origin` make `refs/remotes/origin/HEAD`.
  ##
  ## git's rules are `printf` formats and the `@` here stands exactly where
  ## its `%.*s` does (`refs.c:ref_rev_parse_rules`).  This is the only place
  ## that substitution is written; it was four places, which is how
  ## `remotes.buildRefMap` came to expand the `/HEAD` rule as a plain prefix
  ## and match nothing (docs/minimize.md §7.1).
  if rule.len == 0: name
  elif rule.endsWith("/HEAD"): rule[0 ..< rule.len - 6] & name & "/HEAD"
  else: rule & name

func matchRule(rule, full: string): string =
  ## `expandRule` run backwards: the abbreviated name this rule would have
  ## expanded into `full`, or "" if it could not have produced it at all.
  if rule.endsWith("/HEAD"):
    let head = rule[0 ..< rule.len - 6]
    if full.startsWith(head) and full.endsWith("/HEAD"):
      return full[head.len .. full.len - 6]
  elif full.startsWith(rule):
    return full[rule.len .. ^1]

iterator refCandidates(name: string): string =
  ## Every full ref name a short name could mean, in git's order -- the order
  ## is why a tag beats a branch of the same name.
  ##
  ## A one-level candidate is only offered if it looks like a pseudoref, which
  ## stops `gittle cat-file -t master` from being answered by a stray file
  ## called `master` in the git directory.
  for rule in revParseRules:
    let candidate = expandRule(rule, name)
    if candidate.startsWith(refsPrefix) or
       isValidRefname(candidate, {rfAllowOneLevel}):
      yield candidate

proc shortenRef*(s: RefStore, full: string, strict = false): string =
  ## The shortest name that still means this ref: `refs/heads/main` -> `main`,
  ## for `rev-parse --abbrev-ref` and `branch`'s listings.
  ##
  ## It is `dwimRef` run backwards (`refs.c:refs_shorten_unambiguous_ref`).
  ## Try the rules from the most specific to the least; a rule's short name is
  ## acceptable only if **no earlier rule** turns it into a ref that exists,
  ## because an earlier rule would win when the name is read back.  So a tag
  ## and a branch both called `x` leave the branch spelled `heads/x`.
  ##
  ## `--abbrev-ref=strict` demands that *every* other rule fail, not only the
  ## earlier ones -- a stricter answer for scripts that will feed it back to a
  ## different tool.
  for i in countdown(revParseRules.high, 1):
    let short = matchRule(revParseRules[i], full)
    if short.len == 0: continue
    var ambiguous = false
    for j in 0 ..< (if strict: revParseRules.len else: i):
      if j != i and s.refExists(expandRule(revParseRules[j], short)):
        ambiguous = true
        break
    if not ambiguous: return short
  full

proc expandRefName*(s: RefStore, name: string): string =
  ## The full name of the ref a short name means, **without** following it.
  ##
  ## `dwimRef` answers "what object does this name?" and therefore resolves
  ## symbolic refs; `reflog HEAD` needs the other question, because HEAD has a
  ## log of its own that is not the log of the branch it points at.
  for candidate in refCandidates(name):
    if s.readRef(candidate).found: return candidate
  ""

proc dwimRef*(s: RefStore, name: string): tuple[found: bool, full: string, oid: Oid] =
  ## Turn a name a human typed -- `main`, `v1.0`, `origin/main`, `HEAD` -- into
  ## a full ref name and its value, trying git's rules in git's order.
  for candidate in refCandidates(name):
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
  ## `core.logAllRefUpdates`: a new branch, remote-tracking ref or note
  ## gets a log; anything else only if one already exists.
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

proc appendReflog(s: RefStore, name: string, oldOid, newOid: Oid, msg: string,
                  force = false) =
  ## Append one entry, creating the log only where the policy says to.
  ##
  ## Where the policy says not to, an *existing* log is still appended to: a
  ## user who ran `git config core.logAllRefUpdates true` once and then turned
  ## it off still expects the logs they already have to stay coherent.
  let path = s.reflogPath(name)
  let exists = fileExists(path)
  if not exists and not force and not s.shouldAutocreateReflog(name): return
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

  RefUpdate* = object
    ## One requested change.  The `have*` flags matter: "no old value given"
    ## and "old value given as the null OID" are different requirements that
    ## would otherwise be the same field.
    kind*: RefUpdateKind
    name*: string
    newOid*: Oid
    newTarget*: string
    oldOid*: Oid
    haveOldOid*: bool     ## an expected object ID was specified
    logOld*: Oid          ## what the reflog should record as the old value,
                          ## when that is not what the ref currently holds.
                          ## `branch -m` is the case: the new name has no
                          ## value yet, and a log entry saying it came from
                          ## nowhere would lose the rename.
    haveLogOld*: bool
    noDeref*: bool        ## act on this ref itself, not on what it points at
    forceLog*: bool       ## write a reflog whatever the policy says.  `stash`
                          ## is the case: the stack of stashes *is* the reflog
                          ## of `refs/stash`, so it cannot be optional
    noLog*: bool          ## write no reflog at all.  git's
                          ## `REF_TRANSACTION_FLAG_INITIAL`, used when a
                          ## repository is being *populated* rather than
                          ## changed -- `clone` writes a hundred thousand
                          ## remote-tracking refs and a log of "this ref came
                          ## into existence at clone time" for each is noise
                          ## no one reads
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
    logBefore: Oid    ## what the reflog says it was, usually `before`
    noop: bool        ## the ref already holds this value
    alias: string     ## the symref we came through, or "" -- it gets a reflog
                      ## entry of its own, which is how HEAD keeps a history
                      ## even though the branch is what moves
    before: Oid       ## the value before the change, for the reflog
    content: string   ## bytes to write; empty when nothing is written
    delete: bool
    forceLog: bool
    noLog: bool
    msg: string

  RefTransaction* = ref object
    store: RefStore
    updates: seq[RefUpdate]
    locks: seq[RefLock]
    plans: seq[Plan]
    state: TxState

# -- locks ------------------------------------------------------------------

proc rollback(l: var RefLock) =
  ## Give a lock up without writing: close and unlink `<ref>.lock`.
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
      # Cause and cure in one sentence: the path *is* the instruction, since
      # another process holding it and a crashed one leaving it behind look
      # identical from here and differ only in whether that process still runs.
      fail("cannot lock ref '" & name & "': another gittle or git holds " &
           result.lockPath & ", or one crashed and left it behind")
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
  ## Release a lock whose ref was just deleted -- the lock file goes, the
  ## ref file is already gone.
  if l.fd >= 0:
    discard close(l.fd)
    l.fd = -1
  discard tryRemoveFile(l.lockPath)
  l.held = false

# -- packed-refs and leftovers ----------------------------------------------

proc writePackedRefs(s: RefStore, text: string) =
  ## Replace `packed-refs` wholesale, under its own `.lock`.
  ##
  ## The lock is the point: `packed-refs` is one file holding every shared
  ## ref, so two writers that merely wrote it atomically would still lose one
  ## of the two sets of changes.  `O_EXCL` never waits, so a second writer
  ## fails outright rather than blocking -- which is what git does, and what
  ## makes a concurrent `git pack-refs` an error instead of a silent rewind.
  let path = s.packedRefsPath
  let lockPath = path & lockSuffix
  let fd = open(lockPath.cstring, O_WRONLY or O_CREAT or O_EXCL, 0o666.Mode)
  if fd < 0:
    if errno == EEXIST: fail("cannot lock " & path & ": it is already locked")
    fail("cannot lock " & path & ": " & $strerror(errno))
  discard close(fd)
  try:
    writeFile(lockPath, text)
    moveFile(lockPath, path)
  except CatchableError:
    discard tryRemoveFile(lockPath)
    raise

proc rewritePackedRefsWithout(s: RefStore, names: seq[string]) =
  ## Remove `names` from `packed-refs`, rewriting the file under its own lock.
  s.loadPackedRefs()
  var keep: seq[Ref]
  var removedAny = false
  for r in s.packed:
    if r.name in names: removedAny = true
    else: keep.add r
  if not removedAny: return

  # The header deliberately does *not* claim `peeled` or `fully-peeled`: this
  # writer copies through the peel lines it finds and never computes one, so
  # claiming every tag is peeled would be a lie a later reader is entitled to
  # act on.  (`gc` used to write a peeled file; docs/minimize.md §3.4
  # handed packing refs back to git, so nothing here computes a peel now.)
  var text = "# pack-refs with: sorted \n"
  for r in keep:
    text.add $r.oid & " " & r.name & "\n"
    if r.hasPeeled: text.add "^" & $r.peeled & "\n"
  s.writePackedRefs(text)
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
  ## An empty transaction over the store.
  RefTransaction(store: s, state: txOpen)

proc add*(tx: RefTransaction, update: RefUpdate) =
  ## Queue a change.  Nothing is locked or checked until `prepare`.
  var u = update
  failIf(tx.state != txOpen, "ref transaction is no longer open")
  failIf(not isValidRefname(u.name, {rfAllowOneLevel}),
         "invalid ref name: '" & u.name & "'")
  if u.kind == ruSet and u.newOid.isNull:
    # git spells a delete as an update to the null object ID, which is how
    # `update-ref --stdin` deletes a ref and checks its old value in one
    # command.  Take it at its word rather than refusing.
    u.kind = ruDelete
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
      var p = Plan(msg: u.msg, target: u.name, forceLog: u.forceLog,
                   noLog: u.noLog)

      # Following a symbolic ref is the default for *every* kind of update:
      # `update-ref HEAD <oid>` moves the branch HEAD names rather than turning
      # HEAD into a direct ref, and -- less obviously -- `symref-update` on a
      # symbolic ref rewrites what it points at, not the ref itself.  Only a
      # caller that passes `noDeref` acts on the named ref directly, which is
      # what the `symbolic-ref` command and `option no-deref` do.
      if not u.noDeref:
        var depth = 0
        while true:
          let rf = s.readRef(p.target)
          if not rf.found or not rf.isSymbolic: break
          if p.alias.len == 0: p.alias = p.target
          inc depth
          failIf(depth > maxSymrefDepth,
                 "too many levels of symbolic refs starting at " & u.name)
          p.target = rf.symTarget

      # git's "special hack" (`refs/files-backend.c:commit_ref_update`, and
      # `refs.c:split_head_update` in the transaction layer): HEAD keeps a
      # history of the branch it is on, so *any* update to that branch is
      # logged to HEAD as well -- however the branch was named.  Without this,
      # `update-ref refs/heads/main` and `branch -m` leave HEAD's reflog with
      # a hole where the current branch moved.
      if p.alias.len == 0 and p.target != headRef:
        let (_, headTarget, _) = s.resolveRef(headRef)
        if headTarget == p.target: p.alias = headRef

      var lock = s.lockRef(p.target)
      tx.locks.add lock
      s.checkNewValue(u, p.target)
      s.verifyOld(u, p.target)
      p.before = s.resolveRef(p.target).oid
      p.logBefore = if u.haveLogOld: u.logOld else: p.before

      case u.kind
      of ruSet:
        p.content = $u.newOid & "\n"
        # Writing a ref the value it already has is not a change, and git
        # records neither the write nor a reflog entry for it
        # (`refs/files-backend.c:lock_ref_for_update`).  HEAD is the exception
        # below: it is updated *through* the branch, so its own log still gets
        # the entry -- which is why `reset --soft HEAD` shows up in
        # `reflog show` and leaves the branch's log alone.
        # ... and never when the ref being written is itself symbolic: an
        # object ID written into a symref *replaces* it, which is a change
        # however equal the values are (git's test is on `REF_ISSYMREF` for
        # exactly this reason).  That is how `symbolic-ref`-style refs get
        # detached, and skipping it would leave HEAD attached.
        let cur = s.readRef(p.target)
        p.noop = cur.found and not cur.isSymbolic and p.before == u.newOid
      of ruSetSymbolic: p.content = "ref: " & u.newTarget & "\n"
      of ruDelete: p.delete = true
      tx.plans.add p

    # If any of this will write a reflog, resolve the identity *now*.  An
    # unset `user.email` discovered after the first rename would leave the
    # batch half applied, which is exactly what the transaction exists to
    # prevent -- and the identity is the one input that can fail this late.
    for p in tx.plans:
      if not p.delete and not p.noLog and
         (p.forceLog or s.willWriteReflog(p.target) or
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
    if tx.plans[i].noop:
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
    if p.delete:
      # The reflog goes with the ref.  Leaving it behind would make a branch of
      # the same name, created later, appear to continue the deleted one.
      discard tryRemoveFile(s.reflogPath(p.target))
      s.pruneEmptyRefDirs(p.target)
      # HEAD's own log survives, and records that what it pointed at is gone.
      if p.alias.len > 0: s.appendReflog(p.alias, p.before, nullOid, p.msg)
      continue
    if p.noLog: continue
    let after = s.resolveRef(p.target).oid
    if not p.noop: s.appendReflog(p.target, p.logBefore, after, p.msg,
                                  force = p.forceLog)
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
                checkOld = false, msg = "", logOld = nullOid,
                haveLogOld = false, noDeref = false, forceLog = false,
                noLog = false) =
  ## Point `name` at `newOid`, following it if it is a symbolic ref.
  ##
  ## `noDeref` is what detaches HEAD: writing an object ID *into* HEAD rather
  ## than into the branch it names is the whole of what "detached" means.
  withTransaction(s, tx):
    tx.add RefUpdate(kind: ruSet, name: name, newOid: newOid,
                     oldOid: oldOid, haveOldOid: checkOld, msg: msg,
                     logOld: logOld, haveLogOld: haveLogOld, noDeref: noDeref,
                     forceLog: forceLog, noLog: noLog)

proc deleteRef*(s: RefStore, name: string, oldOid = nullOid, checkOld = false,
                noDeref = false, msg = "") =
  ## Remove `name` wherever it is stored: the loose file, `packed-refs`, or both.
  withTransaction(s, tx):
    tx.add RefUpdate(kind: ruDelete, name: name, oldOid: oldOid,
                     haveOldOid: checkOld, noDeref: noDeref, msg: msg)

proc writeSymRef*(s: RefStore, name, target: string, msg = "",
                  noLog = false) =
  ## Make `name` itself a symbolic ref pointing at `target`.
  ##
  ## `noDeref` is deliberate: `symbolic-ref A B` must rewrite A even when A is
  ## already a symbolic ref, or the command could never repoint one.
  withTransaction(s, tx):
    tx.add RefUpdate(kind: ruSetSymbolic, name: name, newTarget: target,
                     noDeref: true, msg: msg, noLog: noLog)

proc newRefStore*(gitDir, commonDir: string, policy: LogRefsPolicy,
                  identFn: proc (): Ident {.closure.},
                  objectKindFn: proc (o: Oid): ObjectType {.closure.} = nil): RefStore =
  ## A store over a repository's ref directories; `identFn` is asked for
  ## the committer only when a reflog is actually written.
  RefStore(gitDir: gitDir, commonDir: commonDir, logPolicy: policy,
           identFn: identFn, objectKindFn: objectKindFn)
