## `merge-base` -- where two histories last agreed.
##
## The command is four lines; the algorithm behind it is in `revwalk.nim` and
## is used by five other things: `A...B` in every command that takes a range,
## `branch --merged`, `branch -d`'s refusal to delete unmerged work, the
## ahead/behind counts, and -- in phase 7 -- the three-way merge itself, whose
## *base* is exactly what this prints.
##
## Two commits can have **several** best common ancestors, which surprises
## people: a criss-cross merge leaves two ancestors, neither reachable from
## the other, and there is no principled way to prefer one.  `--all` prints
## them; without it git prints whichever came out first, and a merge picks one
## and lives with it.
##
## No common ancestor at all is not an error.  Two histories that were never
## joined -- an imported tree grafted alongside another -- have none, and the
## exit status says so with no message.

import ../cli, ../oid, ../repository, ../revision, ../revwalk, ../util

const usageText = """usage: gittle merge-base [-a] <commit> <commit>…
   or: gittle merge-base --is-ancestor <commit> <commit>

   -a, --all         print every best common ancestor, not just one
   --is-ancestor     exit 0 if the first commit is an ancestor of the second"""

proc cmdMergeBase*(c: Ctx, args: seq[string]): int =
  var all, isAncestor = false
  var revs: seq[string]
  for a in args:
    case a
    of "-a", "--all": all = true
    of "--is-ancestor": isAncestor = true
    of "-h", "--help": (echo usageText; return 0)
    of "--octopus", "--independent", "--fork-point":
      fail(a & " is out of scope for gittle v1 (docs/09)")
    else:
      failIf(a.len > 1 and a[0] == '-', "unknown option '" & a & "'\n" & usageText)
      revs.add a

  let repo = c.repo
  var oids: seq[Oid]
  for r in revs: oids.add repo.resolveCommittish(r)

  if isAncestor:
    failIf(oids.len != 2, "--is-ancestor takes exactly two commits")
    # Exit status only: this is a *test*, and printing the answer as well
    # would make `if gittle merge-base --is-ancestor …` noisy.
    return if repo.isAncestor(oids[0], oids[1]): 0 else: 1

  failIf(oids.len < 2, usageText)
  let bases = repo.mergeBases(oids[0], oids[1 .. ^1])
  if bases.len == 0: return 1
  for b in (if all: bases else: bases[0 .. 0]): echo b
  0
