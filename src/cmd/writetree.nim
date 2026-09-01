## `write-tree` -- write the index out as a tree.
##
## In scope (docs/10): no options at all. `--missing-ok` and `--prefix` are cut.
##
## The whole command is one line of work; the algorithm is in `trees.nim`, and
## the reason it is a single pass is documented there.

import ../cli, ../index, ../repository, ../trees, ../util

const usageText = "usage: gittle write-tree"

proc cmdWriteTree*(c: Ctx, args: seq[string]): int =
  for a in args:
    if a == "-h" or a == "--help":
      echo usageText
      return 0
    fail("unknown option '" & a & "'\n" & usageText)
  let repo = c.repo
  echo $repo.writeTree(readIndex(repo.indexPath))
  0
