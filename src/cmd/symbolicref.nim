## `symbolic-ref` -- read and write symbolic references.
##
## In scope (docs/10): `<name> [<ref>]`, `-d`/`--delete`, `--short`, `-q`.
##
## A symbolic ref is a file whose contents are `ref: <other-ref>`.  Exactly one
## of them matters in day-to-day use -- HEAD, which is how "the branch I am on"
## is stored -- and `symbolic-ref` is the plumbing that reads and sets it.
## `checkout` in phase 6 is largely this command plus a working-tree update.

import std/strutils
import ../cli, ../repository, ../util

const usageText = """usage: gittle symbolic-ref [-q] [--short] <name>
   or: gittle symbolic-ref <name> <ref>
   or: gittle symbolic-ref -d [-q] <name>"""

proc cmdSymbolicRef*(c: Ctx, args: seq[string]): int =
  var del = false
  var short = false
  var quiet = false
  var rest: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts:
      rest.add a
    elif a == "--":
      noMoreOpts = true
    elif a == "-d" or a == "--delete":
      del = true
    elif a == "--short":
      short = true
    elif a == "-q" or a == "--quiet":
      quiet = true
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a.len > 1 and a[0] == '-':
      fail("unknown option '" & a & "'\n" & usageText)
    else:
      rest.add a
    inc i

  let store = c.repo.refs

  if del:
    failIf(rest.len != 1, usageText)
    let r = store.readRef(rest[0])
    if not r.found or not r.isSymbolic:
      # `-q` is about a ref that is not symbolic; a ref that does not exist at
      # all is still an error, the same as git's.
      failIf(not r.found, "cannot delete '" & rest[0] & "': no such ref")
      if quiet: return 1
      fail("cannot delete '" & rest[0] & "': not a symbolic ref")
    store.deleteRef(rest[0], noDeref = true)
    return 0

  if rest.len == 2:
    # Setting it.  git requires the target to look like a ref rather than an
    # object name, because a symbolic ref that points at an object is a file
    # every other tool will misread.
    failIf(not rest[1].startsWith(refsPrefix),
           "refusing to point '" & rest[0] & "' at '" & rest[1] &
           "', which is outside refs/")
    store.writeSymRef(rest[0], rest[1])
    return 0

  failIf(rest.len != 1, usageText)
  let r = store.readRef(rest[0])
  if not r.found or not r.isSymbolic:
    # Not a symbolic ref: exit 1 silently under `-q`, complain otherwise.  A
    # detached HEAD is exactly this case, which is why `-q` exists.
    if quiet: return 1
    fail("ref " & rest[0] & " is not a symbolic ref")
  echo(if short: shortenRefname(r.symTarget) else: r.symTarget)
  0
