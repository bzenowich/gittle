## The revision walk: which commits, in which order.
##
## A commit history is a DAG, and every command that shows history has to
## linearise it.  git's default -- and gittle's -- is **commit-date order**: a
## priority queue keyed by committer timestamp, newest first, seeded with the
## starting commits, popping each commit's parents in as it goes.
##
## Date order is not topological.  A commit whose clock was wrong can appear
## before its own child, and a merge of an old branch interleaves.  git accepts
## that for the default because the queue costs nothing and the pathological
## input is a repository with skewed clocks.  `--topo-order` and `--date-order`
## fix it, at the price of reading the whole selection before printing any of
## it; both are the same algorithm with a different tie-break, below.
##
## ## Exclusion is not filtering
##
## `rev-list A ^B` does not walk A and drop what B reaches.  `^B` paints B and
## **every one of its ancestors** uninteresting as it is met, and the walk
## stops when nothing interesting is left in the queue
## (`revision.c:limit_list`).  That is what makes `main..topic` cheap on a
## repository whose history is a hundred thousand commits deep: the walk never
## descends past the fork.
##
## The stopping rule needs one concession to reality.  A repository with
## skewed clocks can hold an interesting commit *older* than the uninteresting
## ones currently at the head of the queue, so git does not stop the moment
## the queue looks dull -- it keeps going for five more pops (`SLOP`).  Five is
## git's number, and matching it matters: it decides the output.
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

import std/[algorithm, heapqueue, sets, tables]
import commitobj, oid, objects, pathspec, repository, trees

const slopSize = 5
  ## `revision.c:SLOP` -- how many uninteresting pops to keep going for
  ## before believing the walk is over.

type
  QItem = object
    date: int64
    order: int          ## insertion order, to break ties deterministically
    oid: Oid

  WalkFlag = enum
    wfSeen           ## has been queued, so it is never queued twice
    wfUninteresting  ## excluded: this commit and its ancestors are not wanted
    wfLeft           ## reached from the left side of an `A...B`

  RevOrder* = enum
    ## `--topo-order` and `--date-order` are one algorithm -- Kahn's, over the
    ## selected commits -- with two different queues, and git spells them as
    ## one enum for the same reason (`commit.c:sort_in_topological_order`).
    roDefault    ## commit date, streamed straight off the walk's own queue
    roTopo       ## parents strictly after every child; a stack breaks ties
    roDate       ## parents strictly after every child; commit date breaks ties

  RevEntry* = object
    oid*: Oid
    commit*: Commit
    left*: bool         ## for `--left-right`
    show*: bool         ## survived simplification and the commit filters
    parents*: seq[Oid]  ## pruned by simplification, rewritten by `--parents`

  CommitMeta = tuple[tree: Oid, parents: seq[Oid], date: int64]
    ## The three fields the walk itself needs, cached.  Reading a commit means
    ## inflating it, and the walk asks for the same commit three or four times
    ## -- once to date it for the queue, once when it is popped, once as some
    ## child's parent, and again if the excluded side reaches it.  Keeping
    ## twenty bytes and a parent list is far cheaper than keeping the object,
    ## and it is what makes a walk over a hundred thousand commits linear in
    ## *reads* rather than in reads times fan-in.

  RevWalk* = ref object
    repo*: Repository
    queue: HeapQueue[QItem]
    flags: Table[Oid, set[WalkFlag]]
    meta: Table[Oid, CommitMeta]
    simplified: Table[Oid, tuple[show: bool, follow: seq[Oid]]]
    counter: int
    starts: seq[Oid]        ## in the order given, which `--no-walk` preserves
    firstParent*: bool
    paths*: Pathspec
    limiting*: bool         ## the pathspec is non-empty, so simplification applies
    order*: RevOrder
    noWalk*: bool           ## show the named commits and nothing else
    noWalkSorted*: bool     ## ... in date order rather than the given order
    rewriteParents*: bool   ## `--parents`: print an ancestry that was simplified
    minParents*: int        ## `--merges` is 2
    maxParents*: int        ## `--no-merges` is 1; -1 means no limit
    maxAge*: int64          ## `--since`: stop at commits older than this
    minAge*: int64          ## `--until`: do not show commits newer than this

func `<`(a, b: QItem): bool =
  ## The heap pops the smallest, so "smaller" has to mean "comes out first":
  ## newest committer date first, and insertion order within a tie so that two
  ## commits with the same timestamp come out the way they went in.
  if a.date != b.date: a.date > b.date else: a.order < b.order

proc newRevWalk*(repo: Repository): RevWalk =
  ## A walk over the repository with nothing queued and no limits.
  RevWalk(repo: repo, queue: initHeapQueue[QItem](),
          flags: initTable[Oid, set[WalkFlag]](),
          maxParents: -1, maxAge: -1, minAge: -1)

proc readCommit*(repo: Repository, o: Oid): Commit =
  ## Read and parse a commit object.
  parseCommit(repo.readObject(o).data)

proc headLine*(repo: Repository, oid: Oid): string =
  ## `HEAD is now at 1630431 The 21st batch` -- what `checkout --detach` and
  ## `reset --hard` both say afterwards.  The subject is what makes a bare
  ## object ID identifiable at a glance, which is the whole point of printing
  ## it rather than the ID alone.
  "HEAD is now at " & repo.uniqueAbbrev(oid, repo.autoAbbrev) & " " &
    subject(repo.readCommit(oid).message)

proc meta(w: RevWalk, o: Oid): CommitMeta =
  ## A commit's tree, parents and date, read once and cached: the walk
  ## asks for them repeatedly.
  if w.meta.hasKey(o): return w.meta[o]
  let c = w.repo.readCommit(o)
  result = (c.tree, c.parents, c.committer.when0)
  w.meta[o] = result

proc push*(w: RevWalk, o: Oid, uninteresting = false, left = false) =
  ## Add a commit to the queue, or -- if it is already there -- add to what is
  ## known about it.  Pushing the same commit twice is harmless and common:
  ## `log HEAD main` on a repository where they are the same commit, and every
  ## merge, whose parents are reachable two ways.
  ##
  ## The flags are a property of the *commit*, not of the queue entry, which
  ## is what lets a commit queued as interesting become uninteresting before
  ## it is popped -- that is the whole mechanism of `A ^B`.
  var f = w.flags.getOrDefault(o)
  if uninteresting: f.incl wfUninteresting
  if left: f.incl wfLeft
  if wfSeen in f:
    w.flags[o] = f
    return
  f.incl wfSeen
  w.flags[o] = f
  inc w.counter
  w.queue.push QItem(date: w.repo.readCommit(o).committer.when0,
                     order: w.counter, oid: o)

func isUninteresting*(w: RevWalk, o: Oid): bool =
  ## Was this commit excluded?  `rev-list --objects` asks it of every parent
  ## of every commit it shows, to find the boundary.
  wfUninteresting in w.flags.getOrDefault(o)

proc markUninteresting*(w: RevWalk, o: Oid) =
  ## Paint a commit's **whole ancestry** uninteresting, at once, stopping
  ## wherever the mark is already set (`revision.c:mark_parents_uninteresting`).
  ##
  ## Doing it eagerly rather than as the queue reaches each commit is what
  ## makes `rev-list side ^main` empty even when every commit carries the same
  ## timestamp: `side` is already painted before the queue is touched, so the
  ## order the queue would have popped them in cannot matter.
  var stack = w.meta(o).parents
  while stack.len > 0:
    let p = stack.pop()
    var f = w.flags.getOrDefault(p)
    if wfUninteresting in f: continue
    f.incl wfUninteresting
    w.flags[p] = f
    for q in w.meta(p).parents: stack.add q

proc start*(w: RevWalk, o: Oid, uninteresting = false, left = false) =
  ## A starting point named on the command line, as opposed to a parent found
  ## during the walk.  `--no-walk` shows exactly these, in this order.
  if not uninteresting and o notin w.starts: w.starts.add o
  w.push(o, uninteresting, left)
  if uninteresting: w.markUninteresting(o)

# ---------------------------------------------------------------------------
# The object walk
# ---------------------------------------------------------------------------
#
# `rev-list --objects`, `pack-objects` and `push` all ask the same question --
# *which objects are on this side and not on that one* -- so the two halves of
# the answer live here rather than in any one of them.

proc walkObjects*(repo: Repository, root: Oid, path: string,
                  seen: var HashSet[Oid],
                  emit: proc (o: Oid, p: string) {.closure.} = nil) =
  ## Pre-order, in tree-entry order: the tree itself, then each entry, a
  ## subtree fully before its next sibling (`list-objects.c:process_tree`).
  ##
  ## That order is not decorative.  Each object is reported with the **path it
  ## was found at**, and a packer reads the resulting sequence as a hint that
  ## neighbours will delta well against each other.
  ##
  ## `emit = nil` walks the *excluded* side: mark everything under `root` seen
  ## and report none of it.  That is what `edgeTrees` wants -- "the other end
  ## already has all of this" -- and it is the same traversal, so it is not a
  ## second proc.  A gitlink is skipped either way: it names a commit in
  ## another repository, which is not ours to send or to claim.
  if root in seen: return
  seen.incl root
  if emit != nil: emit(root, path)
  for e in treeEntries(repo.readObject(root).data):
    let full = if path.len == 0: e.name else: path & "/" & e.name
    case modeType(e.mode)
    of otTree: repo.walkObjects(e.oid, full, seen, emit)
    of otCommit: discard
    else:
      if e.oid notin seen:
        seen.incl e.oid
        if emit != nil: emit(e.oid, full)

proc edgeTrees*(repo: Repository, w: RevWalk, commits: seq[Oid],
                seen: var HashSet[Oid]) =
  ## **The edge.**  What the excluded side already has is exactly the trees of
  ## the shown commits' excluded *parents*, taken whole
  ## (`list-objects.c:mark_edges_uninteresting`).  Marking them seen is what
  ## makes `HEAD ^origin/main` the set of objects the other end is missing --
  ## and it is why a fetch, and a push, is small.
  for o in commits:
    for p in repo.readCommit(o).parents:
      if w.isUninteresting(p):
        repo.walkObjects(repo.readCommit(p).tree, "", seen)

# ---------------------------------------------------------------------------
# Comparing two trees under a pathspec
# ---------------------------------------------------------------------------

proc anyMatchingUnder(repo: Repository, tree: Oid, prefix: string,
                      ps: Pathspec): bool =
  ## Does this tree contain any path the pathspec matches?  Needed when a path
  ## is a directory on one side and absent (or a file) on the other: the whole
  ## subtree appeared or vanished, and whether that counts depends on what is
  ## inside it.
  ##
  ## `walkTree` yields full paths and takes the descend decision as a
  ## predicate, so the pruning is `mightMatchDir` and nothing else has to be
  ## written: a directory the pathspec cannot reach into is never read.
  for e in repo.walkTree(tree, prefix,
                         proc (d: TreeEntry): bool = ps.mightMatchDir(d.name)):
    if modeType(e.mode) != otTree and ps.matches(e.name): return true

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
    ## The entry of that name, or -1.
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

proc simplify(w: RevWalk, o: Oid): tuple[show: bool, follow: seq[Oid]] =
  ## History simplification for one commit: is it worth showing, and which of
  ## its parents explain the state?  With no pathspec every commit is shown
  ## and every parent followed, which is why the whole thing collapses to
  ## nothing in the ordinary case.
  ##
  ## Memoised, because `--parents` asks the same question again while walking
  ## down to a rewritten parent, and each answer costs a tree comparison.
  if w.simplified.hasKey(o): return w.simplified[o]
  let m = w.meta(o)
  result = (true, m.parents)
  if w.limiting:
    if m.parents.len == 0:
      # A root commit "changed" the paths only if it has any of them.  Asked
      # this way rather than by comparing against the empty tree, which need
      # not be in the object database at all.
      result.show = w.repo.anyMatchingUnder(m.tree, "", w.paths)
    else:
      for p in m.parents:
        if not w.repo.treesDiffer(m.tree, w.meta(p).tree, w.paths):
          result = (false, @[p])
          break
    w.simplified[o] = result

proc rewriteParent(w: RevWalk, start: Oid): Oid =
  ## `--parents` under a pathspec prints an ancestry the simplification has
  ## already collapsed, so each parent has to be replaced by the nearest
  ## ancestor that *is* shown -- otherwise the printed graph names commits
  ## that are not in the output (`revision.c:rewrite_one`).
  result = start
  while true:
    if wfUninteresting in w.flags.getOrDefault(result): return
    let (show, follow) = w.simplify(result)
    if show or follow.len != 1: return
    result = follow[0]

proc everybodyUninteresting(w: RevWalk): bool =
  ## Is nothing left in the queue that could still be shown?  The walk's
  ## stopping rule.
  for i in 0 ..< w.queue.len:
    if wfUninteresting notin w.flags.getOrDefault(w.queue[i].oid): return false
  true

iterator rawWalk(w: RevWalk): RevEntry =
  ## One pass of `revision.c:limit_list`, yielding as it goes.
  ##
  ## Each commit is queued at most once, so the flags it carries when it is
  ## *popped* are the last word -- which is how a commit queued from an
  ## interesting tip and later reached from an excluded one comes out
  ## excluded.
  var slop = slopSize
  var lastDate = high(int64)   ## the date of the newest commit shown so far

  while w.queue.len > 0:
    let item = w.queue.pop()
    let m = w.meta(item.oid)
    var f = w.flags.getOrDefault(item.oid)

    # `--since` is a boundary, not a filter: a commit older than it is treated
    # as excluded, so the walk stops there instead of reading the rest of
    # history and throwing it away.
    if w.maxAge != -1 and m.date < w.maxAge:
      f.incl wfUninteresting
      w.flags[item.oid] = f

    if wfUninteresting in f:
      # The maximal excluded set: no simplification, every parent, all the way
      # down (`revision.c:mark_parents_uninteresting`).
      for p in m.parents:
        w.push(p, uninteresting = true)
        w.markUninteresting(p)
      # Keep going a little past the point where the queue looks finished:
      # a skewed clock can hide an interesting commit behind older-looking
      # excluded ones.
      if w.queue.len == 0: break
      if lastDate <= w.queue[0].date or not w.everybodyUninteresting():
        slop = slopSize
      else:
        dec slop
        if slop <= 0: break
      continue

    let (show0, follow) = w.simplify(item.oid)
    var show = show0
    # `--first-parent` stops the *traversal* at the first parent; it does not
    # change what the commit is.  git leaves `commit->parents` alone
    # (`revision.c:process_parents` merely breaks out of the loop), so a merge
    # still prints its `Merge:` line naming both.
    for k, p in follow:
      if w.firstParent and k > 0: break
      w.push(p, left = wfLeft in f)

    # Every commit the walk reaches is yielded, simplified away or not, and
    # the caller drops the ones with `show` clear.  That is not tidiness: the
    # topological sort counts a commit's *children*, so it has to see the ones
    # that will not be printed or it computes the wrong order for the ones
    # that will.
    if w.minParents > 0 and m.parents.len < w.minParents: show = false
    if w.maxParents >= 0 and m.parents.len > w.maxParents: show = false
    if show: lastDate = m.date
    # `--until` is a filter, not a boundary: an ancestor of a too-new commit
    # can still be old enough, so the walk carries on past it.
    if w.minAge != -1 and m.date > w.minAge: show = false

    # The parents yielded are the *pruned* ones, not the rewritten ones.
    # Rewriting happens at output, after the sort, because the topological
    # order is computed over the real ancestry -- git rewrites in
    # `get_revision` and sorts before it.
    yield RevEntry(oid: item.oid, left: wfLeft in f, show: show,
                   parents: follow)

proc topoSort(w: RevWalk, list: seq[RevEntry]): seq[RevEntry] =
  ## Kahn's algorithm over the commits already selected
  ## (`commit.c:sort_in_topological_order`): count how many of a commit's
  ## children are in the list, emit the ones with none left, and decrement.
  ##
  ## The two orders differ only in the queue.  `--topo-order` uses a **stack**,
  ## which keeps one line of history together until it runs out; `--date-order`
  ## uses the same date-keyed heap as the default walk, which interleaves them
  ## but still never prints a parent before its child.
  var index = initTable[Oid, int]()
  for i, e in list: index[e.oid] = i
  # An in-degree of one means "in the list and not yet spoken for"; git seeds
  # the count at one so that zero can mean "not in the list at all".
  var degree = initTable[Oid, int]()
  for e in list: degree[e.oid] = 1
  for e in list:
    for p in e.parents:
      if degree.getOrDefault(p) > 0: degree[p] = degree[p] + 1

  var stack: seq[Oid]
  var heap = initHeapQueue[QItem]()
  var counter = 0
  proc put(o: Oid) =
    ## Queue a commit for output in the chosen order: a stack for
    ## `--topo-order`, the date heap otherwise.
    if w.order == roTopo: stack.add o
    else:
      inc counter
      heap.push QItem(date: w.meta(o).date, order: counter, oid: o)
  for e in list:
    if degree[e.oid] == 1: put e.oid
  # The tips have to come out in the order the traversal produced them, and a
  # stack would reverse them, so git reverses the stack once up front.
  if w.order == roTopo: reverse(stack)

  while stack.len > 0 or heap.len > 0:
    let o = if w.order == roTopo: stack.pop() else: heap.pop().oid
    for p in list[index[o]].parents:
      if degree.getOrDefault(p) == 0: continue
      degree[p] = degree[p] - 1
      if degree[p] == 1: put p
    degree[o] = 0
    result.add list[index[o]]

proc rewrite(w: RevWalk, e: var RevEntry) =
  ## `--parents` under a pathspec: replace each parent by the nearest ancestor
  ## that is shown, so the printed ancestry names only commits in the output.
  if not (w.rewriteParents and w.limiting): return
  var rewritten: seq[Oid]
  for p in e.parents:
    let r = w.rewriteParent(p)
    if r notin rewritten: rewritten.add r
  e.parents = rewritten

iterator walk*(w: RevWalk): RevEntry =
  ## The commits, in the order asked for.
  ##
  ## The default streams: nothing is held, so `log -1` on a repository with a
  ## hundred thousand commits reads one.  Every other order has to see the
  ## whole selection before it can print the first line, which is the real
  ## cost of `--topo-order` and the reason it is not the default.
  if w.noWalk:
    var only = w.starts
    if w.noWalkSorted:
      sort(only, proc (a, b: Oid): int =
        cmp(w.repo.readCommit(b).committer.when0,
            w.repo.readCommit(a).committer.when0))
    for o in only:
      let c = w.repo.readCommit(o)
      yield RevEntry(oid: o, commit: c, parents: c.parents, show: true,
                     left: wfLeft in w.flags.getOrDefault(o))
  elif w.order == roDefault:
    for e in w.rawWalk:
      if not e.show: continue
      var f = e
      f.commit = w.repo.readCommit(e.oid)
      w.rewrite(f)
      yield f
  else:
    # The whole selection has to exist before the first line can be printed,
    # so it is kept as three fields a commit rather than as the commit: over
    # a hundred thousand of them, the messages alone would be tens of
    # megabytes, and only the ones that get printed are read back.
    var all: seq[RevEntry]
    for e in w.rawWalk: all.add e
    for e in w.topoSort(all):
      if not e.show: continue
      var f = e
      f.commit = w.repo.readCommit(e.oid)
      w.rewrite(f)
      yield f

# ---------------------------------------------------------------------------
# Reachability: merge bases, ancestry, ahead/behind
# ---------------------------------------------------------------------------
#
# One algorithm answers all three questions, and it is git's
# `commit.c:paint_down_to_common`.  Walk both sides at once in date order,
# painting each commit with which side reached it; a commit painted by both
# sides is a common ancestor, and the first ones found this way are the
# *best* ones -- nothing below them can be a better answer, so they are marked
# stale and their ancestors are painted stale too rather than reported again.
#
# Date order is what makes this terminate early: once every commit still in
# the queue is stale, everything reachable from here is an ancestor of an
# answer already found, and the walk stops.  On a skewed-clock repository it
# is still correct -- staleness, not the date, decides -- merely slower.

type Paint = enum
  pSide1     ## reachable from the first commit
  pSide2     ## reachable from any of the others
  pStale     ## below a common ancestor already reported

proc paintDownToCommon(repo: Repository, one: Oid,
                       twos: openArray[Oid]): seq[Oid] =
  ## Every common ancestor of `one` and `twos` that is not below another one.
  ## May still contain redundant entries when `twos` has more than one member;
  ## `mergeBases` removes those.
  if one in twos: return @[one]

  var flags: Table[Oid, set[Paint]]
  var queue = initHeapQueue[QItem]()
  var counter = 0

  proc enqueue(o: Oid, f: set[Paint]) =
    ## Queue a commit whenever its paint *changed*, even if it has been
    ## queued -- and popped -- before.  A commit reached first from one side
    ## and later from the other has only just become a common ancestor, and
    ## nothing would notice if it were not looked at again
    ## (`commit.c:paint_down_to_common` inserts unconditionally too).
    let had = flags.getOrDefault(o)
    if f <= had: return
    flags[o] = had + f
    inc counter
    queue.push QItem(date: repo.readCommit(o).committer.when0,
                     order: counter, oid: o)

  enqueue(one, {pSide1})
  for t in twos: enqueue(t, {pSide2})

  while queue.len > 0:
    # Stop as soon as nothing interesting is left: a queue of stale commits
    # can only reach ancestors of answers already given.
    var live = false
    for i in 0 ..< queue.len:
      if pStale notin flags[queue[i].oid]: live = true; break
    if not live: break

    let item = queue.pop()
    var f = flags[item.oid]
    if {pSide1, pSide2} <= f and pStale notin f:
      result.add item.oid
      f.incl pStale
      flags[item.oid] = f
    for p in repo.readCommit(item.oid).parents:
      enqueue(p, f)

proc objectsBetween*(repo: Repository, wants, haves: openArray[Oid]): seq[Oid] =
  ## Every object reachable from `wants` and not from `haves`, commits first.
  ## The set a push has to send, and what `pack-objects --revs` is given.
  let w = newRevWalk(repo)
  var tags: seq[Oid]
  for h in haves:
    if not repo.hasObject(h): continue
    let (peeled, _) = repo.peelTo(h, otCommit)
    w.start(peeled, uninteresting = true)
  for o in wants:
    if repo.objectInfo(o).kind == otTag: tags.add o
    w.start(repo.peelTo(o, otCommit).oid)
  var commits: seq[Oid]
  for e in w.walk: commits.add e.oid

  var seen: HashSet[Oid]
  repo.edgeTrees(w, commits, seen)
  var objs = tags & commits
  for o in commits:
    repo.walkObjects(repo.readCommit(o).tree, "", seen,
                     proc (x: Oid, p: string) = objs.add x)
  objs

proc isAncestor*(repo: Repository, a, b: Oid): bool =
  ## Is `a` reachable from `b`?  `merge-base --is-ancestor`, and the safety
  ## check behind `branch -d`.  Asked as "is `a` its own merge base with `b`",
  ## which is how git asks it (`commit-reach.c:repo_in_merge_bases`).
  if a == b: return true
  for m in repo.paintDownToCommon(a, [b]):
    if m == a: return true
  false

proc mergeBases*(repo: Repository, a: Oid, rest: openArray[Oid]): seq[Oid] =
  ## The best common ancestors.  With two commits `paintDownToCommon` already
  ## answers exactly; with more, one of its answers can be an ancestor of
  ## another, and git drops those (`commit.c:remove_redundant`).  The list is
  ## almost always one long, so the quadratic filter costs nothing.
  let found = repo.paintDownToCommon(a, rest)
  if found.len <= 1 or rest.len <= 1: return found
  for i, x in found:
    var redundant = false
    for j, y in found:
      if i != j and repo.isAncestor(x, y): redundant = true; break
    if not redundant: result.add x

proc mergeBase*(repo: Repository, a, b: Oid): Oid =
  ## The single best common ancestor, or the null ID when there is none --
  ## two histories that were never joined have no merge base at all, and that
  ## is not an error.
  let m = repo.mergeBases(a, [b])
  if m.len > 0: m[0] else: nullOid

proc ancestry*(repo: Repository, tips: seq[Oid],
               exclude = initHashSet[Oid]()): HashSet[Oid] =
  ## Every commit reachable from `tips`, never entering `exclude`.  The one
  ## explicit-stack walk that `--merged`, `--contains`' cutoff and the
  ## ahead/behind counts all need; a `RevWalk` is for *ordered* output and
  ## costs more than this.
  var stack = tips
  while stack.len > 0:
    let o = stack.pop()
    if o in result or o in exclude: continue
    result.incl o
    for p in repo.readCommit(o).parents: stack.add p

proc countRange*(repo: Repository, tip, other: Oid): int =
  ## How many commits `tip` has that `other` does not: `other..tip`, which is
  ## what `ahead 3` in a tracking line counts.
  repo.ancestry(@[tip], repo.ancestry(@[other])).len
