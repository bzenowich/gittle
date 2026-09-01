## Repository discovery, the configuration a command needs before it runs, the
## extension gate from plan.md 6.1, and object lookup across loose files,
## packs, and alternates.

import std/[os, strutils, algorithm]
import oid, objects, config, packfile, refs, ident, refname, util

export refs, refname, config

type
  Repository* = ref object
    gitDir*: string      ## the per-worktree directory
    commonDir*: string   ## where objects/ and most refs live; == gitDir unless
                         ## this is a linked worktree
    workTree*: string    ## "" when bare
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

proc ceilings(): seq[string] =
  for p in getEnv("GIT_CEILING_DIRECTORIES").split(':'):
    if p.len > 0: result.add p.normalizedPath

proc discoverGitDir(startDir: string): tuple[gitDir, workTree: string] =
  ## Walk up looking for `.git`, or for a bare repository at the directory
  ## itself.  Stops at the filesystem root or a GIT_CEILING_DIRECTORIES entry.
  let stops = ceilings()
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
    if parent in stops: break
    dir = parent
  fail("not a git repository (or any of the parent directories): .git")

# -- the extension gate (plan.md 6.1) ---------------------------------------

proc gateRefusal(key, value, why: string): string =
  result = "cannot operate on this repository\n"
  result.add "  " & key & " = " & value & "\n"
  result.add "  " & why

proc checkExtensions(r: Repository) =
  ## `Documentation/technical/repository-version.adoc` is explicit: an
  ## implementation that does not understand a listed extension key *or its
  ## value* MUST NOT operate on the repository.  Refusing is the specified
  ## behavior, so the gate is general rather than a reftable special case.
  let version = r.cfg.getInt("core.repositoryFormatVersion", 0)
  if version > 1:
    fail(gateRefusal("core.repositoryFormatVersion", $version,
      "gittle understands repository format versions 0 and 1."))

  for e in r.cfg.withPrefix("extensions"):
    let name = e.key[len("extensions.") .. ^1].toLowerAscii
    let v = e.value.toLowerAscii
    # `noop` and `preciousObjects` are respected at any format version; every
    # other extension is only meaningful at version 1.
    case name
    of "noop":
      discard
    of "preciousobjects":
      discard  # honored by gc, which never deletes when it is set
    of "objectformat":
      if v != "sha1":
        fail(gateRefusal(e.key, e.value,
          "gittle implements SHA-1 only (plan.md R4)."))
    of "refstorage":
      if v != "files":
        fail(gateRefusal(e.key, e.value,
          "gittle supports only the 'files' ref backend.\n" &
          "  Convert with real git:  git refs migrate --ref-format=files\n" &
          "  (that command cannot migrate a repository that has worktrees)"))
    of "worktreeconfig", "relativeworktrees":
      discard  # both supported; neither changes an on-disk format
    of "compatobjectformat":
      fail(gateRefusal(e.key, e.value,
        "gittle cannot read a dual-hash repository."))
    of "partialclone":
      fail(gateRefusal(e.key, e.value,
        "gittle has no promisor remotes; every object must be present."))
    of "submodulepathconfig":
      fail(gateRefusal(e.key, e.value, "gittle does not support submodules."))
    else:
      if version >= 1:
        fail(gateRefusal(e.key, e.value,
          "gittle does not know this repository extension."))

# -- opening ----------------------------------------------------------------

proc loadObjDirs(r: Repository) =
  r.objDirs = @[getEnv("GIT_OBJECT_DIRECTORY", r.commonDir / "objects")]
  for p in getEnv("GIT_ALTERNATE_OBJECT_DIRECTORIES").split(':'):
    if p.len > 0: r.objDirs.add p
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
  result.loadObjDirs()

# -- object lookup ----------------------------------------------------------

proc loadPacks(r: Repository) =
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

proc findPacked(r: Repository, o: Oid): tuple[pack: Pack, offset: int] =
  r.loadPacks()
  for p in r.packs:
    let i = p.find(o)
    if i >= 0: return (p, p.offsetAt(i))
  (nil, 0)

proc findLoose(r: Repository, o: Oid): string =
  for d in r.objDirs:
    let p = loosePath(d, o)
    if fileExists(p): return p
  ""

proc hasObject*(r: Repository, o: Oid): bool =
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
  writeLoose(r.objDirs[0], kind, data)

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

proc headRefName*(r: Repository): string =
  ## The branch HEAD names, whether or not it exists yet.  In a repository with
  ## no commits this is the branch a first commit would create.
  let (found, rf) = r.refs.readRef(headRef)
  if found and rf.isSymbolic: rf.symTarget else: headRef

proc resolveOid*(r: Repository, name: string): Oid =
  ## Turn a name into an object ID, in git's order of preference:
  ##
  ## 1. a full 40-digit object name, which always wins -- it is unambiguous by
  ##    construction, and something that long is never meant as a ref;
  ## 2. a reference, through the DWIM rules in `refs.nim` (`HEAD`, `main`,
  ##    `v1.0`, `origin/main`, or any full ref name);
  ## 3. an unambiguous abbreviated object name of at least four digits.
  ##
  ## The `^`, `~`, `@{…}` and `<tree-ish>:<path>` operators need the revision
  ## walk and arrive in phase 6.
  if tryParseOid(name, result):
    return

  let d = r.refs.dwimRef(name)
  if d.found:
    return d.oid

  var pre: OidPrefix
  failIf(not tryParsePrefix(name, pre) or pre.nybbles < 4,
         "not a valid object name: " & name)

  var found: seq[Oid]
  # Loose objects live in fan-out directories named by the first byte, so a
  # prefix of one nybble has to look in sixteen of them.
  let hex = ($pre.lowerBound)[0 ..< pre.nybbles]
  for d in r.objDirs:
    if pre.nybbles == 1:
      for n in 0 .. 15:
        let sub = d / (hex & "0123456789abcdef"[n])
        if not dirExists(sub): continue
        for kind, path in walkDir(sub):
          var o: Oid
          if tryParseOid(sub.lastPathPart & path.lastPathPart, o) and
             pre.matches(o) and o notin found:
            found.add o
    else:
      let sub = d / hex[0 ..< 2]
      if not dirExists(sub): continue
      for kind, path in walkDir(sub):
        var o: Oid
        if tryParseOid(hex[0 ..< 2] & path.lastPathPart, o) and
           pre.matches(o) and o notin found:
          found.add o
  r.loadPacks()
  for p in r.packs:
    for o in p.matching(pre):
      if o notin found: found.add o

  if found.len == 0: fail("not a valid object name: " & name)
  if found.len > 1:
    var msg = "short object ID " & name & " is ambiguous; candidates are:"
    sort(found, cmp)
    for o in found: msg.add "\n  " & $o
    fail(msg)
  found[0]
