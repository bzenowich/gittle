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

const
  synopsis = "[-a] <commit> <commit>…\n--is-ancestor <commit> <commit>"
  options = [
    opt("-a|--all", help = "print every best common ancestor, not just one"),
    opt("--is-ancestor", help = "exit 0 if the first commit is an ancestor of the second"),
    opt("--octopus|--independent|--fork-point", okRefused, help = "docs/09"),
  ]

proc cmdMergeBase*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, resolve the commits, then `--is-ancestor` or the
  ## merge-base walk.
  let o = parse(options, args, "merge-base", synopsis)
  let all = o.has "all"
  let isAncestor = o.has "is-ancestor"
  let revs = o.args
  let repo = c.repo
  var oids: seq[Oid]
  for r in revs: oids.add repo.resolveCommittish(r)

  if isAncestor:
    failIf(oids.len != 2, "--is-ancestor takes exactly two commits")
    # Exit status only: this is a *test*, and printing the answer as well
    # would make `if gittle merge-base --is-ancestor …` noisy.
    return if repo.isAncestor(oids[0], oids[1]): 0 else: 1

  failIf(oids.len < 2, o.use)
  let bases = repo.mergeBases(oids[0], oids[1 .. ^1])
  if bases.len == 0: return 1
  for b in (if all: bases else: bases[0 .. 0]): echo b
  0
