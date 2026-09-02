## Repository discovery, the configuration a command needs before it runs, the
## extension gate from plan.md 6.1, and object lookup across loose files,
## packs, and alternates.

import std/[os, strutils, algorithm]
import oid, objects, config, packfile, refs, ident, refname, util

# Re-exported deliberately.  Every caller that holds a `Repository` also
# handles the `Oid`s and `ObjectType`s it hands back, and a missing `oid`
# import does not fail to compile -- it silently selects Nim's generic `$` and
# prints an object ID as `(b: [179, 176, ...])`.
export refs, refname, config, oid, objects

type
  Repository* = ref object
    gitDir*: string      ## the per-worktree directory
    commonDir*: string   ## where objects/ and most refs live; == gitDir unless
                         ## this is a linked worktree
    workTree*: string    ## "" when bare
    prefix*: string      ## the directory the command was run in, relative to
                         ## `workTree` and ending in `/`; "" at the root.
                         ## Pathspecs are resolved against it, and paths are
                         ## printed relative to it, the way git does both.
    bare*: bool
    cfg*: Config
    objDirs*: seq[string]  ## the main object directory first, then alternates
    packsLoaded: bool
    packs: seq[Pack]
    refStoreCache: RefStore

# -- discovery --------------------------------------------------------------

proc looksLikeGitDir(dir: string): bool =
  ## A repository in its own right: it owns the object database.
  fileExists(dir / "HEAD") and dirExists(dir / "objects") and
    dirExists(dir / "refs")

proc looksLikeWorktreeDir(dir: string): bool =
  ## A linked worktree's git directory holds HEAD, the index and its own logs,
  ## but no `objects/` -- those live in the common directory it points at.
  fileExists(dir / "HEAD") and fileExists(dir / "commondir")

proc readGitLink(path: string): string =
  ## A `.git` *file* points at the real directory: "gitdir: <path>".
  let text = readWholeFile(path).strip()
  if not text.startsWith("gitdir:"):
    fail("invalid gitfile format: " & path)
  let target = text[7 .. ^1].strip()
  failIf(target.len == 0, "invalid gitfile format: " & path)
  if isAbsolute(target): target else: parentDir(path) / target

proc discoverGitDir(startDir: string): tuple[gitDir, workTree: string] =
  ## Walk up looking for `.git`, or for a bare repository at the directory
  ## itself, stopping at the filesystem root.  (`GIT_CEILING_DIRECTORIES`
  ## went in the minimization pass: nothing set it.)
  var dir = absolutePath(startDir).normalizedPath
  while true:
    let dotGit = dir / ".git"
    if dirExists(dotGit):
      if looksLikeGitDir(dotGit): return (dotGit, dir)
    elif fileExists(dotGit):
      let target = readGitLink(dotGit)
      failIf(not looksLikeGitDir(target) and not looksLikeWorktreeDir(target),
             "not a git repository: " & target & " (from " & dotGit & ")")
      return (target, dir)
    if looksLikeGitDir(dir):
      return (dir, "")
    let parent = parentDir(dir)
    if parent.len == 0 or parent == dir: break
    dir = parent
  fail("not a git repository (or any of the parent directories): .git")

# -- the extension gate (plan.md 6.1) ---------------------------------------

const
  anyValue = ""    ## the extension is understood whatever it is set to
  noValue = "\x00" ## understood, but no value of it is one gittle can honor

  knownExtensions = [
    # name                  the one value gittle accepts, and why not otherwise
    ("noop",               anyValue, ""),
    ("preciousobjects",    anyValue, ""),  # honored by gc, which never deletes
    ("worktreeconfig",     anyValue, ""),  # supported; no on-disk format changes
    ("relativeworktrees",  anyValue, ""),  # likewise
    ("objectformat",       "sha1",
      "gittle implements SHA-1 only (plan.md R4)."),
    ("refstorage",         "files",
      "gittle supports only the 'files' ref backend.\n" &
      "  Convert with real git:  git refs migrate --ref-format=files\n" &
      "  (that command cannot migrate a repository that has worktrees)"),
    ("compatobjectformat", noValue,
      "gittle cannot read a dual-hash repository."),
    ("partialclone",       noValue,
      "gittle has no promisor remotes; every object must be present."),
    ("submodulepathconfig", noValue,
      "gittle does not support submodules."),
  ]
    ## The gate, as a table.  `worktreeConfig` and `relativeWorktrees` matter
    ## more than they look: a naive "refuse anything listed" gate would reject
    ## a perfectly ordinary repository because someone once ran
    ## `git config --worktree`.

proc gateRefusal(key, value, why: string): string =
  ## The message the extension gate refuses with: what was found and what
  ## to do about it (plan.md §6.1).
  "cannot operate on this repository\n  " & key & " = " & value & "\n  " & why

proc checkExtensions(r: Repository) =
  ## `Documentation/technical/repository-version.adoc` is explicit: an
  ## implementation that does not understand a listed extension key *or its
  ## value* MUST NOT operate on the repository.  Refusing is the specified
  ## behavior, so the gate is general rather than a reftable special case --
  ## which costs about the same and also handles every extension git adds later.
  let version = r.cfg.getInt("core.repositoryFormatVersion", 0)
  failIf(version > 1, gateRefusal("core.repositoryFormatVersion", $version,
    "gittle understands repository format versions 0 and 1."))

  for e in r.cfg.withPrefix("extensions"):
    let name = e.key[len("extensions.") .. ^1].toLowerAscii
    var known = false
    for (n, accept, why) in knownExtensions:
      if n != name: continue
      known = true
      # `noop` and `preciousObjects` are respected at any format version; the
      # rest are only meaningful at version 1, but refusing a value we cannot
      # honor is right either way.
      failIf(accept != anyValue and accept != e.value.toLowerAscii,
             gateRefusal(e.key, e.value, why))
      break
    failIf(not known and version >= 1, gateRefusal(e.key, e.value,
      "gittle does not know this repository extension."))

# -- opening ----------------------------------------------------------------

proc loadObjDirs(r: Repository) =
  ## The object directories: this repository's, then any alternates named
  ## in `objects/info/alternates` -- which a `git clone --shared` writes, so
  ## a repository git made that way still opens.  (The two environment
  ## variables git also reads went in the minimization pass: nothing set
  ## them.)
  r.objDirs = @[r.commonDir / "objects"]
  # objects/info/alternates: one directory per line, relative to objects/.
  let altFile = r.objDirs[0] / "info" / "alternates"
  if fileExists(altFile):
    for line in readWholeFile(altFile).splitLines:
      let s = line.strip()
      if s.len == 0 or s[0] == '#': continue
      r.objDirs.add(if isAbsolute(s): s else: r.objDirs[0] / s)

proc openRepository*(gitDirOpt, workTreeOpt, startDir: string,
                     bareOpt: bool, overrides: Config): Repository =
  ## `gitDirOpt`/`workTreeOpt` come from `--git-dir`/`--work-tree` or the
  ## environment; either may be empty, in which case discovery runs.
  result = Repository()

  var gitDir = gitDirOpt
  if gitDir.len == 0: gitDir = getEnv("GIT_DIR")
  var workTree = workTreeOpt
  if workTree.len == 0: workTree = getEnv("GIT_WORK_TREE")

  if gitDir.len > 0:
    result.gitDir = absolutePath(gitDir, startDir).normalizedPath
    failIf(not dirExists(result.gitDir),
           "not a git repository: '" & gitDir & "'")
    result.workTree = if workTree.len > 0:
                        absolutePath(workTree, startDir).normalizedPath
                      else: ""
  else:
    let d = discoverGitDir(startDir)
    result.gitDir = d.gitDir
    result.workTree = if workTree.len > 0:
                        absolutePath(workTree, startDir).normalizedPath
                      else: d.workTree

  # A linked worktree keeps objects and most refs in the common directory.
  result.commonDir = result.gitDir
  let commonFile = result.gitDir / "commondir"
  if fileExists(commonFile):
    let t = readWholeFile(commonFile).strip()
    result.commonDir = (if isAbsolute(t): t else: result.gitDir / t).normalizedPath

  # Configuration is a merge, later files winning: the user's own file, then
  # the repository's, then this worktree's, then `-c` on the command line.
  # `--system` is out of scope (docs/11): a single static binary with no
  # install prefix has no system-wide file to read.
  result.cfg = loadConfig(globalConfigPath())
  result.cfg.add loadConfig(result.commonDir / "config")
  if result.cfg.getBool("extensions.worktreeConfig", false):
    result.cfg.add loadConfig(result.gitDir / "config.worktree")
  result.cfg.add overrides

  checkExtensions(result)

  result.bare = bareOpt or result.cfg.getBool("core.bare", result.workTree.len == 0)
  if result.bare: result.workTree = ""
  if result.workTree.len > 0:
    let here = absolutePath(startDir).normalizedPath
    if here == result.workTree: result.prefix = ""
    elif here.startsWith(result.workTree & "/"):
      result.prefix = here[result.workTree.len + 1 .. ^1] & "/"
  result.loadObjDirs()

# -- object lookup ----------------------------------------------------------

proc loadPacks(r: Repository) =
  ## Open every pack in every object directory, once, on first need.
  if r.packsLoaded: return
  r.packsLoaded = true
  for objDir in r.objDirs:
    let packDir = objDir / "pack"
    if not dirExists(packDir): continue
    var idxs: seq[string]
    for kind, path in walkDir(packDir):
      if kind in {pcFile, pcLinkToFile} and path.endsWith(".idx"):
        idxs.add path
    sort(idxs)
    for i in idxs:
      r.packs.add openPack(i)

proc reopenPacks*(r: Repository) =
  ## Forget the packs that were open and look again.  Every other lookup path
  ## caches, which is right for a process that reads; `fetch` is the one that
  ## *adds* a pack mid-run, and an object it just received would otherwise be
  ## invisible until the next command.
  for p in r.packs: p.close()
  r.packs.setLen(0)
  r.packsLoaded = false

proc findPacked*(r: Repository, o: Oid): tuple[pack: Pack, offset: int] =
  ## Which pack holds the object, and where in it; `(nil, 0)` if none.
  r.loadPacks()
  for p in r.packs:
    let i = p.find(o)
    if i >= 0: return (p, p.offsetAt(i))
  (nil, 0)

proc findLoose(r: Repository, o: Oid): string =
  ## The loose file holding the object, or the empty string.
  for d in r.objDirs:
    let p = loosePath(d, o)
    if fileExists(p): return p
  ""

proc hasObject*(r: Repository, o: Oid): bool =
  ## Is the object anywhere, loose or packed?
  r.findLoose(o).len > 0 or r.findPacked(o).pack != nil

proc readObject*(r: Repository, o: Oid): GitObject =
  ## Loose first, then packs -- git's order, and the one that makes a freshly
  ## written object visible before the next repack.
  let lp = r.findLoose(o)
  if lp.len > 0: return readLooseAt(lp)
  let (p, offset) = r.findPacked(o)
  if p != nil:
    # A ref-delta base may live in another pack; let the resolver reach back in.
    return p.readAt(offset, proc (b: Oid): GitObject = r.readObject(b))
  fail("object not found: " & $o)

proc objectInfo*(r: Repository, o: Oid): tuple[kind: ObjectType, size: int] =
  ## Type and size without materialising the object.
  let lp = r.findLoose(o)
  if lp.len > 0: return readLooseHeaderAt(lp)
  let (p, offset) = r.findPacked(o)
  if p != nil:
    return p.typeAndSizeAt(offset, proc (b: Oid): GitObject = r.readObject(b))
  fail("object not found: " & $o)

proc writeObject*(r: Repository, kind: ObjectType, data: string): Oid =
  ## Write an object, unless it is already here.
  ##
  ## The existence check covers packs as well as loose files, which matters:
  ## `write-tree` rewrites every tree in the repository, and without this a
  ## single run would litter the object store with thousands of loose copies of
  ## objects that are already in a pack.  git makes the same check
  ## (`freshen_packed_object`).
  result = hashObject(kind, data)
  if r.hasObject(result): return
  discard writeLoose(r.objDirs[0], kind, data)

# ---------------------------------------------------------------------------
# The ref store
# ---------------------------------------------------------------------------

proc logRefsPolicy(cfg: Config, bare: bool): LogRefsPolicy =
  ## `core.logAllRefUpdates` is a tri-state, not a boolean: unset means "the
  ## normal set of refs, unless this repository is bare", and the string
  ## `always` means every ref including tags (`refs.c`).
  if not cfg.has("core.logAllRefUpdates"):
    return if bare: lrNone else: lrNormal
  let v = cfg.get("core.logAllRefUpdates").toLowerAscii
  case v
  of "always": lrAlways
  of "false", "no", "off", "0": lrNone
  else: lrNormal

proc refs*(r: Repository): RefStore =
  ## The ref store for this repository, created on first use.
  if r.refStoreCache == nil:
    let cfg = r.cfg
    r.refStoreCache = newRefStore(
      r.gitDir, r.commonDir, logRefsPolicy(cfg, r.bare),
      proc (): Ident = getIdent(cfg, irCommitter),
      proc (o: Oid): ObjectType =
        # `otBad` means "not in this database", which is how the ref layer
        # refuses to point a ref at an object that is not there.
        try: r.objectInfo(o).kind except GittleError: otBad)
  r.refStoreCache

proc upstreamRef*(r: Repository, refname: string): string =
  ## The remote-tracking ref a branch follows: `refs/heads/main` ->
  ## `refs/remotes/origin/main`.
  ##
  ## Three things have to line up, and git checks all three
  ## (`remote.c:branch_get_upstream`): `branch.<name>.merge` names the branch
  ## **on the remote**, `branch.<name>.remote` names the remote, and the
  ## remote's own fetch refspec says where its branches are kept locally.
  ## Without the refspec there is no upstream at all -- a `remote.<name>.url`
  ## on its own is not enough -- which is why a repository configured half way
  ## shows no tracking information rather than the wrong tracking information.
  ##
  ## gittle writes and reads only the default refspec
  ## (`+refs/heads/*:refs/remotes/<remote>/*`); a custom one is phase 8.
  if not refname.startsWith("refs/heads/"): return ""
  let branch = refname["refs/heads/".len .. ^1]
  let merge = r.cfg.get("branch." & branch & ".merge")
  let remote = r.cfg.get("branch." & branch & ".remote")
  if merge.len == 0 or remote.len == 0: return ""
  if remote == ".": return merge      # an upstream in this same repository
  if r.cfg.get("remote." & remote & ".fetch").len == 0: return ""
  if not merge.startsWith("refs/heads/"): return ""
  "refs/remotes/" & remote & "/" & merge["refs/heads/".len .. ^1]

proc headerField*(data, name: string): string =
  ## The value of a leading `<name> <value>` line in a commit or a tag.  Both
  ## put their structural headers first and end them with a blank line, so this
  ## never scans the message.
  var i = 0
  while i < data.len:
    let eol = data.find('\n', i)
    let line = if eol < 0: data[i .. ^1] else: data[i ..< eol]
    if line.len == 0: break
    if line.startsWith(name & " "): return line[name.len + 1 .. ^1].strip()
    if eol < 0: break
    i = eol + 1
  ""

proc peelTags*(r: Repository, start: Oid): Oid =
  ## Follow tag objects to whatever they point at; anything else comes back
  ## as it is.  `peelTo` wants a particular type; this wants "not a tag".
  result = start
  for _ in 0 .. 15:
    if r.objectInfo(result).kind != otTag: return
    result = parseOid(headerField(r.readObject(result).data, "object"))
  fail($start & ": tag chain too deep")

proc peelTo*(r: Repository, start: Oid, want: ObjectType):
    tuple[oid: Oid, obj: GitObject] =
  ## Follow a name to the type actually wanted: a tag yields what it points at,
  ## a commit yields its tree.  This is what makes `<tree-ish>` an argument type
  ## rather than a literal tree -- `ls-tree HEAD` and `cat-file tree v1.0` both
  ## end up here.  Both the object and its name come back, because callers want
  ## one or the other and re-hashing to recover the name would be absurd.
  var o = start
  for _ in 0 .. 15:
    let obj = r.readObject(o)
    if obj.kind == want: return (o, obj)
    var next = ""
    case obj.kind
    of otTag: next = headerField(obj.data, "object")
    of otCommit:
      if want != otTree: break
      next = headerField(obj.data, "tree")
    else: break
    failIf(next.len == 0, "invalid " & $obj.kind & " object " & $o)
    o = parseOid(next)
  fail($start & ": not a " & $want)

proc workTreePath*(r: Repository, path: string): string =
  ## Where an index entry's file lives.  In a bare repository there is no
  ## working tree, and the path is used as given so that a caller which should
  ## not be looking at files fails visibly rather than reading the wrong ones.
  if r.workTree.len > 0: r.workTree / path else: path

proc indexPath*(r: Repository): string =
  ## The index is per-worktree -- that is most of the point of a worktree -- so
  ## it lives in `gitDir`, never the common directory.  `GIT_INDEX_FILE`
  ## overrides it, which is how `read-tree --index-output` and the merge
  ## machinery work on a scratch index.
  let env = getEnv("GIT_INDEX_FILE")
  if env.len > 0: env else: r.gitDir / "index"

proc headRefName*(r: Repository): string =
  ## The branch HEAD names, whether or not it exists yet.  In a repository with
  ## no commits this is the branch a first commit would create.
  let rf = r.refs.readRef(headRef)
  if rf.found and rf.isSymbolic: rf.symTarget else: headRef

proc objectsMatching*(r: Repository, pre: OidPrefix): seq[Oid] =
  ## Every object whose name begins with `pre`, loose and packed.
  ##
  ## Loose objects sit in fan-out directories named by their first byte, so a
  ## one-nybble abbreviation has to look in sixteen of them and any longer one
  ## in exactly one.  `walkDir` yields nothing for a directory that is absent,
  ## which is the ordinary state of most of them.
  let hex = ($pre.lowerBound)[0 ..< pre.nybbles]
  var subdirs: seq[string]
  if pre.nybbles == 1:
    for n in "0123456789abcdef": subdirs.add hex & n
  else:
    subdirs.add hex[0 ..< 2]
  for d in r.objDirs:
    for sub in subdirs:
      for _, path in walkDir(d / sub):
        var o: Oid
        if tryParseOid(sub & path.lastPathPart, o) and pre.matches(o) and
           o notin result:
          result.add o
  r.loadPacks()
  for p in r.packs:
    for o in p.matching(pre):
      if o notin result: result.add o

# ---------------------------------------------------------------------------
# Abbreviated object names
# ---------------------------------------------------------------------------

const
  minAbbrev* = 4          ## git refuses anything shorter, and so does `resolveOid`
  fallbackAbbrev* = 7     ## git's `FALLBACK_DEFAULT_ABBREV`, for a small repository

proc approximateObjectCount(r: Repository): int =
  ## Packed objects exactly, loose objects estimated the way git estimates them
  ## (`odb.c`): count one fan-out directory and multiply by 256.  The answer
  ## only picks a starting length, so an estimate is the right shape of answer.
  r.loadPacks()
  for p in r.packs: result += p.nObjects
  for d in r.objDirs:
    var n = 0
    for _, _ in walkDir(d / "17"): inc n
    result += n * 256

proc autoAbbrev*(r: Repository): int =
  ## How long an abbreviation has to be before collisions become likely.
  ##
  ## With about 2^n objects a collision is expected around 2^(n/2), and there
  ## are four bits to a hex digit, so the length is ceil((msb + 1) / 2) -- with
  ## a floor of seven (`odb.c`).  On the repository next door, 420,113 objects
  ## give ten, which is what `git ls-tree --abbrev` prints.
  var count = approximateObjectCount(r)
  var msb = -1
  while count > 0:
    inc msb
    count = count shr 1
  result = max((msb + 1 + 1) div 2, fallbackAbbrev)

proc uniqueAbbrev*(r: Repository, o: Oid, minLen: int): string =
  ## The shortest prefix of `o` that is at least `minLen` digits and names no
  ## other object.
  ##
  ## `--abbrev=<n>` is a *minimum*, not a length: git lengthens it until the
  ## result is unambiguous (`odb.c:repo_find_unique_abbrev`), because an
  ## abbreviation naming two objects is worse than a long one.  Truncating
  ## instead produces output that looks right and cannot be pasted back.
  let full = $o
  var n = clamp(minLen, minAbbrev, OidHexLen)
  while n < OidHexLen:
    var pre: OidPrefix
    discard tryParsePrefix(full[0 ..< n], pre)
    if r.objectsMatching(pre).len <= 1: break
    inc n
  full[0 ..< n]
