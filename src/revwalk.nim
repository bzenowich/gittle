## The revision walk: which commits, in which order.
##
## A commit history is a DAG, and every command that shows history has to
## linearise it.  git's default -- and gittle's only order in v1 -- is
## **commit-date order**: a priority queue keyed by committer timestamp,
## newest first, seeded with the starting commits, popping each commit's
## parents in as it goes.  `--topo-order` and `--date-order` are phase 6 with
## the rest of the `rev-list` surface.
##
## Date order is not topological.  A commit whose clock was wrong can appear
## before its own child, and a merge of an old branch interleaves.  git accepts
## that for the default because the queue costs nothing and the pathological
## input is a repository with skewed clocks.
##
## ## Path limiting is history simplification
##
## `log -- <path>` does not filter the output; it changes the walk.  The
## default rule (`revision.c:simplify_commit`):
##
## * if the commit's tree, **restricted to the pathspec**, is identical to some
##   parent's, the commit is not shown and only that parent is followed --
##   nothing here happened to those paths, and the parent explains the state;
## * otherwise the commit is shown and every parent is followed.
##
## The consequence people find surprising is that side branches vanish: a merge
## whose result matches its first parent takes you down the first parent alone.
## That is what makes `log -- file` a readable history rather than every commit
## that ever touched a directory containing it.
##
## Comparing two trees under a pathspec short-circuits wherever two subtree
## object IDs are equal, which is what makes this cheap: two commits a
## thousand apart still compare in a few dozen tree reads.  Note what it is
## *not*: a tree comparison, not a diff.  Nothing here is phase 5.

import std/[heapqueue, sets]
import commitobj, oid, objects, pathspec, repository

type
  QItem = object
    date: int64
    order: int          ## insertion order, to break ties deterministically
    oid: Oid

  RevWalk* = ref object
    repo: Repository
    queue: HeapQueue[QItem]
    seen: HashSet[Oid]
    counter: int
    firstParent*: bool
    paths*: Pathspec
    limiting*: bool     ## the pathspec is non-empty, so simplification applies

func `<`(a, b: QItem): bool =
  ## The heap pops the smallest, so "smaller" has to mean "comes out first":
  ## newest committer date first, and insertion order within a tie so that two
  ## commits with the same timestamp come out the way they went in.
  if a.date != b.date: a.date > b.date else: a.order < b.order

proc newRevWalk*(repo: Repository): RevWalk =
  RevWalk(repo: repo, queue: initHeapQueue[QItem](),
          seen: initHashSet[Oid]())

proc readCommit*(repo: Repository, o: Oid): Commit =
  parseCommit(repo.readObject(o).data)

proc push*(w: RevWalk, o: Oid) =
  ## Add a starting point.  Pushing the same commit twice is harmless and
  ## common -- `log HEAD main` on a repository where they are the same commit.
  if o in w.seen: return
  w.seen.incl o
  inc w.counter
  w.queue.push QItem(date: w.repo.readCommit(o).committer.when0,
                     order: w.counter, oid: o)

# ---------------------------------------------------------------------------
# Comparing two trees under a pathspec
# ---------------------------------------------------------------------------

proc anyMatchingUnder(repo: Repository, tree: Oid, prefix: string,
                      ps: Pathspec): bool =
  ## Does this tree contain any path the pathspec matches?  Needed when a path
  ## is a directory on one side and absent (or a file) on the other: the whole
  ## subtree appeared or vanished, and whether that counts depends on what is
  ## inside it.
  for e in treeEntries(repo.readObject(tree).data):
    let path = prefix & e.name
    if modeType(e.mode) == otTree:
      if ps.mightMatchDir(path) and repo.anyMatchingUnder(e.oid, path & "/", ps):
        return true
    elif ps.matches(path):
      return true

proc treesDiffer*(repo: Repository, a, b: Oid, ps: Pathspec,
                  prefix = ""): bool =
  ## Do these two trees differ anywhere the pathspec reaches?
  ##
  ## Identical object IDs settle a whole subtree in one comparison, which is
  ## the property the entire walk leans on.
  if a == b: return false
  if ps.isEmpty: return true

  # Tree entries are already sorted, so this is a merge of two sorted lists --
  # but the sort key includes an implicit `/` on directories (see trees.nim),
  # so collecting both sides and looking names up is simpler than getting the
  # merge's comparison subtly wrong.
  var an, bn: seq[TreeEntry]
  for e in treeEntries(repo.readObject(a).data): an.add e
  for e in treeEntries(repo.readObject(b).data): bn.add e

  proc find(s: seq[TreeEntry], name: string): int =
    result = -1
    for i, e in s:
      if e.name == name: return i

  proc side(e: TreeEntry, path: string): bool =
    ## One entry with no counterpart: it appeared or vanished.
    if modeType(e.mode) == otTree:
      ps.mightMatchDir(path) and repo.anyMatchingUnder(e.oid, path & "/", ps)
    else: ps.matches(path)

  for e in an:
    let path = prefix & e.name
    let j = find(bn, e.name)
    if j < 0:
      if side(e, path): return true
      continue
    let f = bn[j]
    if e.mode == f.mode and e.oid == f.oid: continue
    if modeType(e.mode) == otTree and modeType(f.mode) == otTree:
      if ps.mightMatchDir(path) and
         repo.treesDiffer(e.oid, f.oid, ps, path & "/"): return true
    elif side(e, path) or side(f, path): return true

  for f in bn:
    if find(an, f.name) < 0 and side(f, prefix & f.name): return true

# ---------------------------------------------------------------------------
# The walk
# ---------------------------------------------------------------------------

proc treeOf(repo: Repository, o: Oid): Oid = repo.readCommit(o).tree

iterator walk*(w: RevWalk): tuple[oid: Oid, commit: Commit] =
  ## Commits in date order, with path simplification applied when a pathspec
  ## was given.  Every commit is yielded at most once: `seen` is checked when a
  ## parent is *pushed*, not when it is popped, so a commit reachable by two
  ## routes enters the queue once.
  while w.queue.len > 0:
    let item = w.queue.pop()
    let c = w.repo.readCommit(item.oid)
    var follow = c.parents
    var show = true

    if w.limiting:
      if c.parents.len == 0:
        # A root commit "changed" the paths only if it has any of them.  Asked
        # this way rather than by comparing against the empty tree, which need
        # not be in the object database at all.
        show = w.repo.anyMatchingUnder(c.tree, "", w.paths)
      else:
        for p in c.parents:
          if not w.repo.treesDiffer(c.tree, w.repo.treeOf(p), w.paths):
            show = false
            follow = @[p]
            break

    if w.firstParent and follow.len > 1: follow = @[follow[0]]
    if show: yield (item.oid, c)
    for p in follow: w.push(p)
