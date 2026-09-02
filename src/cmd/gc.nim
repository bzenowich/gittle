## `gc` -- housekeeping, with the packing done by the server.
##
## `gittle gc [--full] [-q]`.  Everything else git's `gc` takes
## (`--prune=<date>`, `--auto`, `--aggressive`, `--cruft`, ...) is refused
## with one line: it either names a job this command does not do, or a
## knob for one.
##
## ## Why a fetch, and not a packer
##
## R2 says gittle never searches for a delta, and so it cannot repack: a
## pack it wrote itself would be a copy of every object at full size, ten
## times what git's is (plan.md §3.1, measured).  The first version of this
## command therefore only *added* a pack of the loose objects and left
## every older pack alone (R2a) -- which meant the repository grew one
## pack per fetch and nothing ever consolidated them.
##
## But the remote always runs full git.  A fetch says "I want these tips
## and I have these commits", and the server's `pack-objects` sends the
## difference as one properly deltified pack
## (`builtin/fetch.c` → `fetch-pack.c`, `upload-pack.c:create_pack_file`).
## **The haves do not have to be honest.**  Offer only the commits whose
## objects already sit in the pack worth keeping, and the server sends
## everything newer -- including what gittle already holds loose or in
## small packs -- packed the way git would pack it.  So `gc` is a caller of
## the fetch engine (`remotes.receivePack`) with wants and haves of its
## own choosing, and no ref moves at all.  docs/minimize.md §3.4 is the
## decision.
##
## The wants are every branch and tag the remote advertises whose object
## is already here (a want must be an advertised tip, and one that is not
## here yet is `fetch`'s business).  The haves come from a walk back from
## each want to the first commit found in the **largest existing pack**:
## every commit on the near side of that frontier is what the new pack
## will hold.  Three levels are possible, by where the walk stops:
##
## | level | haves | the server sends | deleted afterwards |
## |---|---|---|---|
## | pack pushed history | first commit in *any* pack | the commits since the last pack | loose objects the new pack covers |
## | consolidate (**default**) | first commit in the *largest* pack | everything outside that pack | every smaller pack, and loose object, the new pack covers |
## | `--full` | none | the whole history, as a clone would | every old pack and loose object |
##
## The first is what git's own `gc` amounts to between full repacks, and
## it is not offered: it is the default minus the consolidation, and the
## bytes it saves on the wire are bounded by the size of the smaller packs
## -- which is exactly what the default exists to get rid of.
##
## The pack is asked for **non-thin**.  A fetch takes a thin pack and
## appends the bases it is missing; here the file must stand on its own,
## or a base would be copied out of the pack being kept and the old pack
## could never be shown redundant.  It goes through the same `installPack`
## as a fetch -- the pack checksum and every object's own hash -- which is
## what lets the delete pass trust it.  The connectivity walk a fetch runs
## afterwards is skipped: it exists to keep a ref from moving to a history
## that cannot be read, and this command moves none.
##
## ## The one safety rule
##
## A loose object, or a pack other than the new one and the largest kept
## one, is deleted only when **every object in it exists in a kept pack**.
## Nothing else is ever removed.  That is what makes this safe beside a
## real git writing the same repository, and it is what draws the limits:
##
## * **unpushed work** -- a local branch not yet pushed, a stash, a staged
##   blob, a commit only the reflog names -- the server has never seen it
##   and cannot send it, so it stays loose until the first `gc` after a
##   push;
## * **unreachable objects** are never pruned.  A branch fetched and then
##   deleted pins its pack, because the server sends only what its own
##   tips reach.  Pruning needs a grace period against writes in flight,
##   which is why git waits two weeks (`gc.pruneExpire`); it stays git's
##   job;
## * **reflog expiry and packed refs** are local files git manages fine;
##   packing refs only speeds up a repository with thousands of them;
## * **being offline**: the gc needs the remote, opened the way `fetch`
##   opens it -- the current branch's remote, else `origin`.  A device
##   that pushes already has that requirement.
##
## ## When it runs on its own
##
## git runs `maintenance run --auto` at the end of `commit`, `merge`,
## `rebase`, `fetch` and `am`, and it does nothing until about 6,700 loose
## objects (`gc.auto`) have piled up.  gittle has one trigger, at the end
## of a successful `push` (cmd/push.nim): that is the moment the server is
## known to hold everything worth packing, and the connection to it was
## just open.  The threshold is git's, estimated git's way (`objects/17`
## times 256), and `gc.auto = 0` turns it off.  It runs in the foreground;
## gittle has no background mode.
##
## `extensions.preciousObjects` says another tool holds references into
## this object store that gittle cannot see, possibly by path to a loose
## file: the delete pass is skipped entirely (plan.md §6 promised this
## when it decided to accept the extension).  An alternate object
## directory belongs to somebody else and is neither counted nor touched.
## A `.keep` file beside a pack means what it means to git
## (`builtin/repack.c`): that pack is never deleted.

import std/[algorithm, os, posix, sequtils, sets, strutils]
import ../cli, ../oid, ../packfile, ../remotes, ../repository, ../revwalk,
       ../transport, ../util, ../worktrees


proc ownPacks(repo: Repository): seq[Pack] =
  ## Every pack in this repository's own object directory, largest first --
  ## which is the one that is kept.
  for kind, path in walkDir(repo.objDirs[0] / "pack", checkDir = false):
    if kind in {pcFile, pcLinkToFile} and path.endsWith(".idx"):
      result.add openPack(path)
  result.sort(proc (a, b: Pack): int =
    cmp(getFileSize(b.packPath), getFileSize(a.packPath)))

const
  synopsis = "[--full] [-q]"
  options = [
    opt("--full", help = "repack the whole history into one pack, as a clone would"),
    opt("-q|--quiet", help = "say nothing"),
    opt("--prune|--no-prune|--auto|--aggressive|--cruft|--keep-largest-pack|--force",
        okRefused, help = "the server packs; gittle neither prunes nor repacks (docs/minimize.md §3.4)"),
  ]

proc looseObjectEstimate*(repo: Repository): int =
  ## git's own guess at how many loose objects there are, without counting
  ## them all: the files in `objects/17`, one bucket of 256
  ## (`builtin/gc.c:too_many_loose_objects`).  `gc.auto` is compared with
  ## this; its default, 6700, is git's.
  for _, _ in walkDir(repo.objDirs[0] / "17", checkDir = false): inc result
  result * 256

proc gcRepository*(c: Ctx, remote: string, full, quiet: bool) =
  ## The whole of `gc`: prune stale worktrees, fetch the pack the module
  ## comment describes from `remote`, then the delete pass under the safety
  ## rule.  `push` calls this too, on the remote it just pushed to, when the
  ## loose-object estimate crosses `gc.auto` -- the one moment the server is
  ## known to hold the history worth packing.
  let repo = c.repo
  pruneWorktrees(repo, dryRun = false, verbose = false)
  let packs = repo.ownPacks()
  let largest = if full or packs.len == 0: nil else: packs[0]
  let rem = repo.lookupRemote(remote)
  let program = repo.cfg.get("remote." & rem.name & ".uploadpack")
  let conn = connect(rem.url, if program.len > 0: program
                              else: "git-upload-pack", wantV2 = true)
  defer: conn.finish()
  conn.handshake()

  # Wants and haves, as the module comment describes.  A tip the walk from
  # an earlier tip already passed is walked no further, and is still wanted:
  # a want the server finds nothing new for costs nothing.
  var wants, haves, stack: seq[Oid]
  var seen: HashSet[Oid]
  for r in conn.lsRefs(["refs/heads/", "refs/tags/"]):
    if r.unborn or not repo.hasObject(r.oid) or r.oid in wants: continue
    wants.add r.oid
    if largest == nil: continue
    try: stack.add repo.peelTo(r.oid, otCommit).oid
    except GittleError: continue      # a tag of a tree or a blob: no history
    while stack.len > 0:
      let o = stack.pop()
      if seen.containsOrIncl(o): continue
      if largest.contains(o): haves.add o
      else: stack.add repo.readCommit(o).parents
  var kept: seq[Pack]
  if largest != nil: kept.add largest
  if wants.len > 0:
    let newPack = receivePack(repo, conn, wants, haves, includeTag = false,
                              quiet = quiet or isatty(2) == 0, thin = false)
    if not newPack.isNull:
      kept.add openPack(repo.objDirs[0] / "pack" / ("pack-" & $newPack & ".idx"))

  if repo.cfg.getBool("extensions.preciousObjects", false): return
  # Is the object in one of the packs being kept?
  proc covered(o: Oid): bool = kept.anyIt(it.contains(o))
  # A kept pack is known by its *path*, not its handle: a pack's name is its
  # checksum, so a second `gc` with nothing new to send receives the very
  # same file it made last time -- installed over the old one, which must
  # then not be found "covered" by itself and deleted.
  for p in packs:
    if kept.anyIt(it.packPath == p.packPath) or
       fileExists(p.packPath[0 ..^ 6] & ".keep"): continue
    if (0 ..< p.nObjects).anyIt(not covered(p.oidAt(it))): continue
    p.close()
    for ext in [".pack", ".idx", ".rev", ".bitmap", ".mtimes", ".promisor"]:
      discard tryRemoveFile(p.packPath[0 ..^ 6] & ext)
  # The loose objects, in this repository's own object directory only, and
  # then the fan-out directories that emptied: git's `prune` removes those
  # too, and 256 empty directories are what a reader would otherwise mistake
  # for a repository with loose objects in it.
  for kind, sub in walkDir(repo.objDirs[0], checkDir = false):
    if kind != pcDir or sub.lastPathPart.len != 2: continue
    for _, path in walkDir(sub):
      var o: Oid
      if tryParseOid(sub.lastPathPart & path.lastPathPart, o) and covered(o):
        discard tryRemoveFile(path)
    if toSeq(walkDir(sub)).len == 0:
      try: removeDir(sub) except OSError: discard

proc cmdGc*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then `gcRepository` against the default remote,
  ## exactly the one `fetch` with no argument would open.
  let o = parse(options, args, "gc", synopsis)
  gcRepository(c, c.repo.defaultRemote(), full = o.has "full", quiet = o.has "quiet")
  0
