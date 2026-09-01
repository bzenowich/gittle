## `read-tree` -- load a tree into the index.
##
## In scope for phase 3: `<tree-ish>` and `--empty`.  `-m`, `--reset` and `-u`
## are in scope for v1 (docs/10) but need machinery from later phases -- two-
## and three-way tree merging is phase 7, and updating the working tree is the
## checkout of phase 6 -- so they refuse by name rather than doing something
## that merely resembles them.
##
## The stat fields of every entry are left zero, because nothing has been
## checked out and there is no file to describe.  A zeroed stat is exactly the
## "I do not know, go and look" that `status` needs, and it is what git leaves
## behind too.

import ../cli, ../index, ../repository, ../trees, ../util

const usageText = "usage: gittle read-tree (<tree-ish> | --empty)"

proc cmdReadTree*(c: Ctx, args: seq[string]): int =
  var empty = false
  var rest: seq[string]
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--empty": empty = true
    of "-h", "--help":
      echo usageText
      return 0
    of "-m", "--reset", "-u", "-i", "--trivial", "--aggressive":
      fail(a & " is not implemented in this version\n" &
           "  tree merging arrives in phase 7 and working-tree updates in " &
           "phase 6")
    else:
      if a.len > 1 and a[0] == '-':
        fail("unknown option '" & a & "'\n" & usageText)
      rest.add a
    inc i

  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  if empty:
    failIf(rest.len != 0, usageText)
    idx.entries.setLen(0)
  else:
    failIf(rest.len != 1, usageText)
    repo.readTreeInto(idx, repo.resolveTree(rest[0]))
  idx.writeIndex()
  0
