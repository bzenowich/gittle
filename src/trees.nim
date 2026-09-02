## Trees: building one from the index, filling the index from one, and walking
## one recursively.
##
## ## Why write-tree is a single pass
##
## A tree object lists only its *immediate* children, so turning a flat index
## into a tree looks like it needs a grouping pass and a sort.  It does not,
## because the two sort orders were designed to agree:
##
## * **Index entries** are sorted by path as raw bytes.
## * **Tree entries** are sorted by name with an implicit `/` appended to
##   directory names.  This is why `foo.txt` comes before the tree `foo`:
##   `.` is 0x2E and `/` is 0x2F, so `"foo.txt"` < `"foo/"`.
##
## Under both rules everything under `foo/` forms one contiguous run, and that
## run sits exactly where the tree entry named `foo` belongs.  So one walk over
## the sorted index, recursing whenever a path still contains a `/`, emits every
## tree with its entries already in order.  Nothing needs collecting, sorting or
## grouping first (R7: do not build what you immediately consume).
##
## The one thing to be careful about is the *reverse*: when writing a tree the
## implicit `/` matters, so `sortTreeEntries` below is not `sort by name`.
##
## ## What is deliberately not here
##
## The `TREE` cache-tree extension makes git's `write-tree` incremental by
## remembering which subtrees already exist.  It is a cache (R3): gittle neither
## reads nor writes it, and recomputes every tree every time.  On the git
## repository next door that is a few hundred milliseconds -- worth it to avoid
## a cache that is silently wrong when it disagrees with the entries.

import std/[algorithm, strutils]
import index, objects, oid, repository, util

# ---------------------------------------------------------------------------
# The index -> a tree
# ---------------------------------------------------------------------------

func treeSortKey(name: string, mode: uint32): string =
  ## A tree entry sorts under its name plus, for a directory, a trailing `/`.
  if mode == modeTree: name & "/" else: name

proc sortTreeEntries(entries: var seq[TreeEntry]) =
  ## git's tree order: by name, with a directory compared as if its name
  ## ended in `/`.
  sort(entries, proc (a, b: TreeEntry): int =
    cmp(treeSortKey(a.name, a.mode), treeSortKey(b.name, b.mode)))

proc formatTree*(entries: seq[TreeEntry]): string =
  ## The bytes of a tree object: `<octal mode> <name>\0<20 raw bytes>` per
  ## entry, with **no leading zero on the mode** -- a directory is stored as
  ## `40000`, not `040000`.  The padded six-digit form is what `cat-file -p`
  ## *displays*; writing it would produce a different object ID for the same
  ## tree, which is R1 in one line.
  for e in entries:
    result.add octalMode(e.mode)
    result.add ' '
    result.add e.name
    result.add '\0'
    for i in 0 ..< OidLen: result.add char(e.oid.b[i])

proc writeTreeFrom(repo: Repository, entries: seq[IndexEntry],
                   start: int, prefix: string): tuple[oid: Oid, next: int] =
  ## Write the tree for everything under `prefix`, beginning at `start`.
  ## Returns its object ID and the index of the first entry beyond it.
  var children: seq[TreeEntry]
  var i = start
  while i < entries.len and entries[i].path.startsWith(prefix):
    let rest = entries[i].path[prefix.len .. ^1]
    let slash = rest.find('/')
    if slash < 0:
      children.add TreeEntry(mode: entries[i].mode, name: rest,
                             oid: entries[i].oid)
      inc i
    else:
      # A whole subdirectory: recurse over the contiguous run that shares it.
      let dir = rest[0 ..< slash]
      let sub = repo.writeTreeFrom(entries, i, prefix & dir & "/")
      children.add TreeEntry(mode: modeTree, name: dir, oid: sub.oid)
      i = sub.next
  sortTreeEntries(children)
  result.oid = repo.writeObject(otTree, formatTree(children))
  result.next = i

proc writeTree*(repo: Repository, idx: Index): Oid =
  ## Write the index out as a tree, and every subtree it contains.
  ##
  ## An unmerged entry is refused: a path with three stages has no single
  ## content, so there is no tree to write.  git says the same thing.
  for e in idx.entries:
    failIf(e.stage != 0, "cannot write a tree: '" & e.path &
           "' is unmerged; resolve the conflict and stage the result")
    failIf(e.path.startsWith("/") or e.path.contains("//") or
           e.path.endsWith("/"),
           "cannot write a tree: malformed path '" & e.path & "'")
  var sorted = idx.entries
  sort(sorted, cmpEntries)
  repo.writeTreeFrom(sorted, 0, "").oid

# ---------------------------------------------------------------------------
# A tree -> the index
# ---------------------------------------------------------------------------

iterator walkTree*(repo: Repository, root: Oid, prefix = "",
                   descend: proc (e: TreeEntry): bool {.closure.} = nil): TreeEntry =
  ## Every entry in a tree, depth first and in tree order, with `name` carrying
  ## the full path from the tree that was asked for.  A directory is yielded
  ## *before* its contents, which is what `ls-tree -t` prints and what
  ## `read-tree` can skip over.
  ##
  ## `descend` decides, per directory, whether to walk into it; `nil` means
  ## always.  It is a decision rather than a flag because `ls-tree` needs it to
  ## be one: without `-r` it still descends into a directory when a path
  ## argument names something below it (`builtin/ls-tree.c:show_recursive`).
  ##
  ## Iterative rather than recursive: Nim iterators cannot recurse, and a stack
  ## also means a pathological tree cannot exhaust the real one.  Children are
  ## pushed in reverse so that popping yields them in order, and pushing them
  ## on top of the remaining siblings is what makes the traversal depth first.
  var stack: seq[TreeEntry]

  template pushChildren(oid: Oid, base: string) =
    ## Queue a tree's entries for the walk, in order, with their paths
    ## prefixed.
    var kids: seq[TreeEntry]
    for k in treeEntries(repo.readObject(oid).data): kids.add k
    for i in countdown(kids.high, 0):
      var k = kids[i]
      k.name = base & k.name
      stack.add k

  pushChildren(root, prefix)
  while stack.len > 0:
    let e = stack.pop()
    yield e
    if e.mode == modeTree and (descend == nil or descend(e)):
      pushChildren(e.oid, e.name & "/")

proc readTreeInto*(repo: Repository, idx: Index, root: Oid) =
  ## Replace the index's contents with a tree's.
  ##
  ## The stat fields are left zero: nothing has been checked out, so there is
  ## no file to describe, and a zeroed stat is exactly the "I do not know, go
  ## and look" that `status` needs.  git does the same after `read-tree`.
  idx.entries.setLen(0)
  for e in repo.walkTree(root):
    if e.mode == modeTree: continue          # trees are implied by their paths
    var entry = IndexEntry(mode: e.mode, oid: e.oid, path: e.name)
    entry.size = 0
    idx.entries.add entry
  sort(idx.entries, cmpEntries)
