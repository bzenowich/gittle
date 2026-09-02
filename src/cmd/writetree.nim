## `write-tree` -- write the index out as a tree.
##
## In scope (docs/10): no options at all. `--missing-ok` and `--prefix` are cut.
##
## The whole command is one line of work; the algorithm is in `trees.nim`, and
## the reason it is a single pass is documented there.

import ../cli, ../index, ../repository, ../trees, ../util

proc cmdWriteTree*(c: Ctx, args: seq[string]): int =
  ## Entry point: write the index as a tree and print its ID.
  let o = parse([], args, "write-tree", "")
  failIf(o.args.len > 0, o.use)
  let repo = c.repo
  echo $repo.writeTree(readIndex(repo.indexPath))
  0
