## Linked working trees: one repository, several checkouts.
##
## ## What is on disk
##
## A linked worktree is two directories that point at each other.  Under the
## repository, one administrative directory per worktree:
##
## ```
## .git/worktrees/<id>/
##     gitdir      /abs/path/to/<worktree>/.git    <- and a trailing newline
##     commondir   ../..                           <- back to the real .git
##     HEAD        ref: refs/heads/topic
##     index                                       <- its own, always
##     refs/                                       <- for its private refs
##     logs/HEAD
##     locked                                      <- while it is being made
## ```
##
## and in the worktree itself a `.git` **file**, not a directory:
##
## ```
## gitdir: /abs/path/to/.git/worktrees/<id>
## ```
##
## `<id>` is the basename of the worktree's path, made into a legal refname
## component and suffixed with a number if that is taken.  It is a label and
## nothing more -- `move` does not change it, so an id and a path agree only
## by coincidence after the first rename.
##
## ## Why the split is where it is
##
## Everything that is *about the history* -- objects, `refs/heads`, `refs/tags`
## -- is shared, and everything that is *about a checkout* -- HEAD, the index,
## the in-progress markers, `logs/HEAD` -- is per worktree.  That division is
## already built into [refs.nim](refs.nim) (`isPerWorktreeRef`) and
## [repository.nim](repository.nim) (`commonDir` beside `gitDir`), because
## gittle has had to *read* a linked worktree since phase 2.  What this module
## adds is creating, listing and removing them.
##
## ## The one invariant worth naming
##
## **A branch is checked out in at most one worktree.**  Two worktrees on one
## branch would let a commit in either move the ref under the other, and the
## second would find its own HEAD describing a tree it does not have.  So
## `checkedOutAt` is consulted by `worktree add`, by `checkout` and `switch`,
## and by `branch -d` and `branch -f` -- four commands, one question.

import std/[algorithm, os, strutils]
import oid, refs, repository, util

type
  Worktree* = object
    path*: string       ## absolute; for a bare main worktree, the repository
    id*: string         ## the directory under `worktrees/`; "" for the main one
    gitDir*: string     ## where its HEAD, index and reflogs live
    isMain*: bool
    isBare*: bool
    headRef*: string    ## the branch HEAD names; "" when detached
    headOid*: Oid
    locked*: bool
    lockReason*: string

func worktreesDir*(repo: Repository): string = repo.commonDir / "worktrees"

func adminDir*(repo: Repository, id: string): string =
  ## `.git/worktrees`, where each linked worktree has its admin directory.
  repo.worktreesDir / id

proc mainWorkTree*(repo: Repository): string =
  ## The repository's own working tree, which is not necessarily the one this
  ## command is running in.  Derived from the common directory rather than
  ## from `repo.workTree`, because inside a linked worktree the latter is the
  ## *linked* one (`worktree.c:get_main_worktree`).
  var p = repo.commonDir.absolutePath.normalizedPath
  if p.endsWith("/.git"): p.setLen(p.len - 5)
  p

proc readHeadFile*(repo: Repository, gitDir: string):
    tuple[refName: string, oid: Oid] =
  ## HEAD as some worktree has it.  A symbolic HEAD is resolved through the
  ## shared ref store, so an unborn branch comes back named with a null ID --
  ## which is what `worktree list` prints as `0000000 [main]`.
  let path = gitDir / "HEAD"
  if not fileExists(path): return
  let text = readWholeFile(path).strip()
  if text.startsWith("ref:"):
    result.refName = text[4 .. ^1].strip()
    let r = repo.refs.readRef(result.refName)
    if r.found and not r.isSymbolic: result.oid = r.oid
  else:
    discard tryParseOid(text, result.oid)

proc allWorktrees*(repo: Repository): seq[Worktree] =
  ## The main worktree first, then the linked ones sorted by path -- git's
  ## order, and the one `worktree list` prints.
  var main = Worktree(path: repo.mainWorkTree, isMain: true,
                      gitDir: repo.commonDir,
                      isBare: repo.cfg.getBool("core.bare", false))
  if main.isBare: main.path = repo.commonDir.absolutePath.normalizedPath
  (main.headRef, main.headOid) = repo.readHeadFile(main.gitDir)
  result.add main

  var linked: seq[Worktree]
  for kind, path in walkDir(repo.worktreesDir, checkDir = false):
    if kind notin {pcDir, pcLinkToDir}: continue
    var w = Worktree(id: path.lastPathPart, gitDir: path)
    let gitdirFile = path / "gitdir"
    if not fileExists(gitdirFile): continue
    var target = readWholeFile(gitdirFile).strip()
    if not isAbsolute(target): target = (path / target).normalizedPath
    if target.endsWith("/.git"): target.setLen(target.len - 5)
    w.path = target
    let lockFile = path / "locked"
    if fileExists(lockFile):
      w.locked = true
      w.lockReason = readWholeFile(lockFile).strip()
    (w.headRef, w.headOid) = repo.readHeadFile(path)
    linked.add w
  sort(linked, proc (a, b: Worktree): int = cmp(a.path, b.path))
  result.add linked

proc checkedOutAt*(repo: Repository, refName: string): string =
  ## Which worktree has this branch checked out, or "".  Includes the current
  ## one: `branch -d` refuses the branch you are standing on for the same
  ## reason it refuses one another worktree is standing on
  ## (`branch.c:branch_checked_out`).
  for w in repo.allWorktrees:
    if not w.isBare and w.headRef == refName: return w.path
  ""

# ---------------------------------------------------------------------------
# Pruning
# ---------------------------------------------------------------------------

proc pruneReason*(repo: Repository, id: string): string =
  ## Why this administrative directory should go, or "" to keep it.
  ## `worktree.c:should_prune_worktree`, minus the `--expire` grace period
  ## (docs/08 cuts it): a worktree whose directory is gone is gone.
  let dir = repo.adminDir(id)
  if not dirExists(dir): return "not a valid directory"
  if fileExists(dir / "locked"): return ""
  let gitdirFile = dir / "gitdir"
  if not fileExists(gitdirFile): return "gitdir file does not exist"
  var target = readWholeFile(gitdirFile).strip()
  if target.len == 0: return "invalid gitdir file"
  if not isAbsolute(target): target = (dir / target).normalizedPath
  if not fileExists(target) and not dirExists(target):
    return "gitdir file points to non-existent location"
  ""

proc removeAdminDir*(repo: Repository, id: string) =
  ## Delete a linked worktree's admin directory.
  try: removeDir(repo.adminDir(id))
  except OSError:
    fail("failed to delete '" & repo.adminDir(id) & "'")

proc pruneWorktrees*(repo: Repository, dryRun, verbose: bool) =
  ## Drop the administrative directories of worktrees that are no longer
  ## there.  `gc` runs this too, which is why it lives here and not in the
  ## command.
  var ids: seq[string]
  for kind, path in walkDir(repo.worktreesDir, checkDir = false):
    ids.add path.lastPathPart
  sort(ids)
  for id in ids:
    let why = repo.pruneReason(id)
    if why.len == 0: continue
    if dryRun or verbose:
      stderr.write "Removing worktrees/" & id & ": " & why & "\n"
    if not dryRun: repo.removeAdminDir(id)
  if dryRun or not dirExists(repo.worktreesDir): return
  for _, _ in walkDir(repo.worktreesDir): return    # not empty; leave it
  try: removeDir(repo.worktreesDir) except OSError: discard
