## `commit-tree` -- create a commit object.
##
## In scope (docs/10): `<tree>`, `-p`, `-m`, `-F`.  Signing is cut.
##
## This is `commit` with everything removed: no index, no hooks, no editor, no
## ref update, and -- importantly -- **no message cleanup**.  git's
## `commit-tree` writes the message exactly as given (`builtin/commit-tree.c`),
## which is what makes it the right command to test the commit *format* with:
## anything the two tools disagree about is the format itself and not the
## pipeline in front of it.

import ../cli, ../commitobj, ../ident, ../repository, ../util

const usageText = """usage: gittle commit-tree [(-p <parent>)…] [(-m <message>)…]
                          [(-F <file>)…] <tree>"""

proc cmdCommitTree*(c: Ctx, args: seq[string]): int =
  var parents: seq[string]
  var messages: seq[string]
  var treeArg = ""
  var i = 0

  proc valueFor(flag: string): string =
    inc i
    failIf(i >= args.len, "option '" & flag & "' requires a value")
    args[i]

  while i < args.len:
    let a = args[i]
    case a
    of "-p": parents.add valueFor("-p")
    of "-m": messages.add valueFor("-m")
    of "-F":
      let f = valueFor("-F")
      messages.add(if f == "-": readAll(stdin) else: readWholeFile(f))
    of "-h", "--help":
      echo usageText
      return 0
    else:
      failIf(a.len > 1 and a[0] == '-', "unknown option '" & a & "'\n" & usageText)
      failIf(treeArg.len > 0, "must give exactly one tree")
      treeArg = a
    inc i

  failIf(treeArg.len == 0, "must give exactly one tree")
  let repo = c.repo
  let tree = repo.resolveOid(treeArg)
  failIf(repo.objectInfo(tree).kind != otTree, "not a valid object name " & treeArg)

  var parentOids: seq[Oid]
  for p in parents:
    let o = repo.resolveOid(p)
    failIf(repo.objectInfo(o).kind != otCommit, "not a valid object name " & p)
    # git reports a duplicate and drops it rather than refusing the command
    # (`builtin/commit-tree.c:new_parent`), because a merge of a branch with
    # itself is a mistake worth naming but not worth failing over.
    if o in parentOids:
      stderr.write "error: duplicate parent " & $o & " ignored\n"
    else:
      parentOids.add o

  # With no -m and no -F the message comes from stdin, which is how a script
  # pipes one in without a temporary file.
  let msg = if messages.len > 0: joinMessages(messages) else: readAll(stdin)

  let data = buildCommit(tree, parentOids, getIdent(repo.cfg, irAuthor),
                         getIdent(repo.cfg, irCommitter), msg)
  echo $repo.writeObject(otCommit, data)
  0
