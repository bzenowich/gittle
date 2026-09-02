## `gc` -- housekeeping, done additively.
##
## In scope (docs/07): `--prune=<date>`, `--no-prune`, `--quiet`.
## `--aggressive`, `--auto`, `--detach`, `--cruft`, `--keep-largest-pack`
## and `--force` are cut.
##
## ## R2a: never repack what was already packed
##
## This is the one rule that shapes the command (plan.md §3, R2a).  git's `gc`
## runs `repack -a -d`, which rewrites every pack in the repository -- and
## rewriting a pack means re-deltifying it, which gittle **cannot do**,
## because R2 says gittle never searches for a delta.  A repository whose
## 304 MiB pack came from a clone would come out of a naive `gittle gc` at
## 3.1 GiB (plan.md §3.1, measured).
##
## So `gittle gc` is additive: **loose objects are folded into a new pack and
## the packs that were already there are left alone.**  The result is a
## repository with more packs than git would leave, all of them optimally
## deltified, and a real `git gc` run later in the same repository restores
## git's own layout exactly.  The only thing gittle must never do is undo it.
##
## ## What it actually does, in order
##
## 1. **Prune worktrees** whose directories are gone ([worktrees.nim]).
## 2. **Pack refs**: every loose shared ref folded into `packed-refs`
##    ([refs.nim]).
## 3. **Pack loose objects** that are reachable, and delete the loose copies.
## 4. **Prune** loose objects that are unreachable *and* older than the
##    expiry -- two weeks by default, as in git.
##
## ## What it deliberately does not do
##
## * **Expire reflogs.**  git drops entries older than `gc.reflogExpire`
##   (90 days) and unreachable ones older than `gc.reflogExpireUnreachable`
##   (30 days).  That needs approxidate parsing, which is cut (plan.md §6.3),
##   and reflog growth is bounded and tiny; the cost of the difference is a
##   slightly longer `logs/HEAD`.  The oracle's fixture sets
##   `gc.reflogExpire=never`, so both tools read the same configuration file
##   and the divergence is *tested* rather than merely absent.
## * **Write a commit-graph, a multi-pack-index, or a `.rev` file.**  R3:
##   caches git writes and gittle declines to read.
## * **Touch the object store at all**, when `extensions.preciousObjects` is
##   set.  That extension says some other tool has references into this object
##   store that gittle cannot see -- possibly by path, to a loose file -- so
##   steps 3 and 4 are skipped entirely.  Steps 1 and 2 still run: neither
##   removes an object.

import std/[algorithm, os, sets, strutils, times]
import ../cli, ../index, ../indexpack, ../oid, ../packwrite, ../refs,
       ../repository, ../revision, ../revwalk, ../util, ../worktrees

const usageText = """usage: gittle gc [--prune=<date> | --no-prune] [--quiet]

   --prune=<date>   prune unreachable loose objects older than <date>
   --no-prune       prune nothing
   --quiet          say nothing"""

proc parseExpiry(spec: string): int64 =
  ## `--prune=<date>`.  The three words git's own users type are honored;
  ## everything else goes through the ISO-8601 parser, because approxidate
  ## ("2.weeks.ago") is out of scope (plan.md §6.3) and quietly meaning
  ## something else would be worse than refusing.
  case spec.toLowerAscii
  of "now", "all": high(int64)
  of "never": low(int64)
  else: parseTimestamp(spec)

proc looseObjects(repo: Repository): seq[tuple[oid: Oid, path: string,
                                               age: int64]] =
  ## Every loose object in *this* repository's own object directory.  An
  ## alternate belongs to somebody else and is never touched.
  const hex = "0123456789abcdef"
  let objDir = repo.objDirs[0]
  for a in hex:
    for b in hex:
      let sub = $a & $b
      for kind, path in walkDir(objDir / sub, checkDir = false):
        if kind notin {pcFile, pcLinkToFile}: continue
        var o: Oid
        if not tryParseOid(sub & path.lastPathPart, o): continue
        result.add (o, path, getLastModificationTime(path).toUnix)
  sort(result, proc (x, y: (Oid, string, int64)): int = cmp($x[0], $y[0]))

proc reachableSet(repo: Repository): HashSet[Oid] =
  ## Everything worth keeping.
  ##
  ## The roots are wider than "the refs", and each extra one is a way work has
  ## actually been lost: a **reflog** entry is how `reset --hard` is undone, a
  ## worktree's **index** holds a blob that has been added but not committed,
  ## and every **linked worktree** has a HEAD and an index of its own that
  ## this one cannot see.  git collects the same four
  ## (`reachable.c:mark_reachable_objects`).
  var roots: seq[Oid]
  var direct: seq[Oid]

  proc addRoot(o: Oid) =
    if not o.isNull and repo.hasObject(o): roots.add o

  for r in repo.refs.allRefs(refsPrefix): addRoot r.oid
  for w in repo.allWorktrees:
    addRoot w.headOid
    # Its index: a staged blob is in no tree yet, so nothing else names it.
    let idxPath = w.gitDir / "index"
    if fileExists(idxPath):
      for e in readIndex(idxPath).entries: direct.add e.oid
    # Its reflogs, which is what makes `HEAD@{5}` still resolvable.
    for path in walkDirRec(w.gitDir / "logs", checkDir = false):
      for line in readWholeFile(path).splitLines:
        let parts = line.split(' ')
        if parts.len < 2: continue
        var o: Oid
        if tryParseOid(parts[0], o): addRoot o
        if tryParseOid(parts[1], o): addRoot o

  # A root is walked as history when it peels to a commit, and taken as a bare
  # object otherwise.  The peel is *tried* rather than inferred from the type,
  # because a tag can name a tree or a blob and starting the history walk
  # there would fail rather than keep it -- and the root itself is kept either
  # way, which is what stops an annotated tag from being pruned out from under
  # the ref that names it.
  var commitish: seq[Oid]
  for o in roots:
    result.incl o
    try:
      discard repo.peelTo(o, otCommit)
      commitish.add o           # not the peeled ID: the walk peels it again
                                # and keeps the tag object as it goes
    except GittleError: direct.add o
  for o in repo.objectsBetween(commitish, @[]): result.incl o
  for o in direct:
    if not repo.hasObject(o): continue
    result.incl o
    if repo.objectInfo(o).kind == otTree:
      repo.walkObjects(o, "", result, proc (x: Oid, p: string) = discard)

proc packInto(repo: Repository, oids: seq[Oid]): Oid =
  ## Write one pack holding exactly these objects, and index it.  The name is
  ## the pack's own checksum, which is not known until the last byte, so it is
  ## written to a temporary and renamed.
  let base = repo.objDirs[0] / "pack" / "pack"
  createDir(base.parentDir)
  let tmp = base & "-tmp-" & $getCurrentProcessId() & ".pack"
  var f: File
  failIf(not open(f, tmp, fmWrite), "cannot create '" & tmp & "'")
  try:
    result = writePack(repo, oids, proc (d: string) =
      failIf(d.len > 0 and f.writeBuffer(unsafeAddr d[0], d.len) != d.len,
             "short write to " & tmp))
  finally:
    f.close()
  let final = base & "-" & $result & ".pack"
  moveFile(tmp, final)
  discard indexPack(final, base & "-" & $result & ".idx", fixThin = false)

proc cmdGc*(c: Ctx, args: seq[string]): int =
  var quiet = false
  var expiry = dateNow() - 14 * 24 * 60 * 60   # git's `2.weeks.ago`
  var i = 0
  optionValue(args, i)
  while i < args.len:
    let a = args[i]
    if a == "-q" or a == "--quiet": quiet = true
    elif a == "--no-prune": expiry = low(int64)
    elif a == "--prune": discard        # the default expiry, spelled out
    elif a.startsWith("--prune="): expiry = parseExpiry(valueFor(a))
    elif a == "-h" or a == "--help": (echo usageText; return 0)
    elif a in ["--aggressive", "--auto", "--detach", "--no-detach", "--cruft",
               "--no-cruft", "--force", "--keep-largest-pack"]:
      fail("gittle gc does not support '" & a & "' (docs/07)")
    else: fail("unknown option '" & a & "'\n" & usageText)
    inc i

  let repo = c.repo

  pruneWorktrees(repo, dryRun = false, verbose = false)

  repo.refs.packRefs(proc (o: Oid): Oid =
    # A peel line exists for a ref that names a tag object and for no other,
    # so this reports the null ID for everything else.
    if repo.objectInfo(o).kind != otTag: return nullOid
    try: repo.peelTo(o, otCommit).oid except GittleError: nullOid)

  # The extension says another tool holds references into this object store
  # that gittle cannot see -- possibly by path, to a loose file.  So the whole
  # object half is skipped: packing without removing the loose copies would
  # buy nothing, and removing them is exactly what the extension forbids
  # (plan.md §6, which promised this when it decided to accept it).
  if repo.cfg.getBool("extensions.preciousObjects", false): return 0

  let loose = repo.looseObjects()
  if loose.len == 0: return 0
  let reachable = repo.reachableSet()

  var toPack, toPrune: seq[Oid]
  var loosePath: seq[string]
  for (o, path, age) in loose:
    if o in reachable:
      toPack.add o
      loosePath.add path
    elif age <= expiry:
      toPrune.add o
      loosePath.add path

  if toPack.len > 0:
    discard repo.packInto(toPack)
    if not quiet:
      stderr.write "Packed " & $toPack.len & " loose object" &
                   (if toPack.len == 1: "" else: "s") & "\n"
  for path in loosePath: discard tryRemoveFile(path)
  # The fan-out directories a prune emptied; git's `prune` removes them too,
  # and 256 empty directories are what a reader would otherwise mistake for a
  # repository with loose objects in it.
  for kind, path in walkDir(repo.objDirs[0], checkDir = false):
    if kind != pcDir or path.lastPathPart.len != 2: continue
    var empty = true
    for _, _ in walkDir(path): (empty = false; break)
    if empty:
      try: removeDir(path) except OSError: discard
  0
