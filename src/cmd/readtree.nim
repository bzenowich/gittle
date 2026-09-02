## `read-tree` -- load one, two or three trees into the index.
##
## In scope (docs/10): `<tree-ish>…`, `-m`, `--reset`, `-u`, `--empty`.
##
## ## How many trees decides what it means
##
## | | |
## |---|---|
## | one, no `-m` | replace the index with the tree, stat data and all discarded |
## | one, `-m` | the same, but an entry that already matches keeps its stat data |
## | two, `-m` | **the two-way update** -- move from the first tree to the second, refusing rather than overwriting: `checkout`'s rule, as plumbing |
## | three, `-m` | **the trivial three-way merge** -- base, ours, theirs, and unmerged stages wherever both sides had an opinion |
##
## `-u` updates the working tree as well; without it only the index moves,
## which is what makes `read-tree -m` the tool a script uses to *stage* a
## change it will check out itself.  `--reset` is `-m` with the safety check
## switched off, which is how `reset --hard` is spelled in a script.
##
## ## The three-way here is *trivial*, and that is the difference from `merge`
##
## `read-tree` never writes a blob.  It resolves a path only when at most one
## side changed it, and records stages 1, 2 and 3 for every path where both
## did -- it does not merge content, so it produces no conflict markers.
## Resolving those stages was `merge-index`'s job, which is cut (docs/10), and
## is `merge`'s now.
##
## ## Two vocabularies for the same three refusals
##
## The safety check is `checkout`'s and the wording is not: `unpack-trees`
## keeps a plumbing message and a porcelain message for every case, and
## `read-tree` takes the plumbing one -- one line naming one entry, because
## the caller is a script and the next thing it does is read the exit status.
## See `worktree.nim`'s two `refused` procs.
##
## The stat fields of an entry with no file behind it are left zero, because
## nothing has been checked out and there is nothing to describe.  A zeroed
## stat is exactly the "I do not know, go and look" that `status` needs, and
## it is what git leaves behind too.

import std/[sets, strutils, tables]
import ../cli, ../index, ../repository, ../revision, ../trees, ../util,
       ../worktree

const usageText = """usage: gittle read-tree [-m [--reset]] [-u] <tree-ish> [<tree-ish> [<tree-ish>]]
   or: gittle read-tree --empty"""

proc cmdReadTree*(c: Ctx, args: seq[string]): int =
  var empty, merge, reset, update = false
  var rest: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--empty": empty = true
    of "-m": merge = true
    of "--reset": (reset = true; merge = true)
    of "-u": update = true
    of "-h", "--help":
      echo usageText
      return 0
    of "-i", "--trivial", "--aggressive", "-n", "--dry-run", "-v", "-q",
       "--quiet", "--index-output", "--no-sparse-checkout",
       "--recurse-submodules", "--no-recurse-submodules":
      fail(a & " is out of scope for gittle v1 (docs/10)")
    else:
      if a.len > 1 and a[0] == '-':
        if a.startsWith("--prefix="):
          fail("--prefix is out of scope for gittle v1 (docs/10)")
        fail("unknown option '" & a & "'\n" & usageText)
      rest.add a
    inc i

  failIf(update and not merge,
         "-u is meaningless without -m, --reset, or --prefix")

  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  if empty:
    failIf(rest.len != 0, usageText)
    idx.entries.setLen(0)
    idx.writeIndex()
    return 0
  failIf(merge and rest.len == 0, "you must specify at least one tree to merge")
  failIf(rest.len < 1 or rest.len > 3, usageText)
  var trees: seq[TreeMap]
  for spec in rest: trees.add repo.flatten(repo.resolveTree(spec))

  if not merge:
    repo.readTreeInto(idx, repo.resolveTree(rest[0]))
  elif trees.len == 1:
    # One tree with `-m` differs from one tree without it in exactly one way,
    # and it is the stat data: an entry whose content is unchanged keeps it,
    # so the next `status` need not re-read the file.
    repo.resetIndexTo(idx, trees[0])
  else:
    # Two trees move from the first to the second.  Three reduce to the same
    # thing first: work out what each path becomes, leaving a path both sides
    # changed at *ours* so that the move does not touch it, and record its
    # stages afterwards.
    var newTree = trees[^1]
    var conflicted: seq[string]
    if trees.len == 3:
      newTree = TreeMap()
      var paths: HashSet[string]
      for t in trees:
        for p in t.keys: paths.incl p
      for path in paths:
        let o = trees[0].getOrDefault(path)
        let a = trees[1].getOrDefault(path)
        let b = trees[2].getOrDefault(path)
        let v = if a == b or o == b: a
                elif o == a: b
                else:
                  conflicted.add path
                  a
        if v.mode != 0: newTree[path] = v

    let plan = repo.planTwoWay(idx, trees[^2], newTree, force = reset)
    if plan.refusedPlumbing: return 128
    repo.applyPlan(idx, plan, newTree, toWorkTree = update)
    for path in conflicted:
      var stages: seq[IndexEntry]
      for s, t in trees:
        let v = t.getOrDefault(path)
        if v.mode == 0: continue
        var e = IndexEntry(path: path, mode: v.mode, oid: v.oid)
        e.setStage(s + 1)
        stages.add e
      idx.addUnmerged(stages)
  idx.writeIndex()
  0
