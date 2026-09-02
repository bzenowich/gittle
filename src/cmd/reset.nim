## `reset` -- move HEAD, and optionally what follows it.
##
## Three things can be reset, and the three modes are simply how far down the
## stack the change goes:
##
## | | HEAD | index | working tree |
## |---|---|---|---|
## | `--soft` | moves | untouched | untouched |
## | `--mixed` (default) | moves | reset to the commit | untouched |
## | `--hard` | moves | reset to the commit | reset to the commit |
##
## So `reset --soft HEAD~1` un-commits and leaves everything staged;
## `--mixed` un-commits and un-stages; `--hard` un-commits and throws the work
## away.  Only the last one destroys anything, and it is the only one that
## takes no notice of what is in the way -- which is the point of it.
##
## **The pathspec form is a fourth thing entirely.**  `reset <tree> -- <paths>`
## does not move HEAD at all: it copies those paths from the tree into the
## index, which is how `reset <path>` unstages.  git refuses `--hard` with
## paths for exactly this reason -- there is no coherent meaning for "move
## HEAD, but only for these files".
##
## ## ORIG_HEAD
##
## Every mode that moves HEAD writes the old value to `ORIG_HEAD` first, so
## that a `reset --hard` aimed at the wrong commit is recoverable with
## `reset --hard ORIG_HEAD`.  It costs one ref write and it is the only
## undo this command has.

import std/[strutils, tables]
import ../cli, ../index, ../pathspec, ../refs,
       ../repository, ../revision, ../revwalk, ../util, ../worktree

const usageText = """usage: gittle reset [--soft | --mixed | --hard] [<commit>]
   or: gittle reset [<tree-ish>] [--] <pathspec>…

   --soft            move HEAD only
   --mixed           move HEAD and reset the index (the default)
   --hard            move HEAD and reset the index and the working tree
   -q, --quiet       report only errors"""

type Mode = enum mSoft, mMixed, mHard

proc cmdReset*(c: Ctx, args: seq[string]): int =
  var mode = mMixed
  var modeGiven, quiet, seenDashDash = false
  var rest, specs: seq[string]

  for a in args:
    if seenDashDash: specs.add a
    elif a == "--": seenDashDash = true
    elif a.len > 1 and a[0] == '-':
      case a
      of "--soft": (mode = mSoft; modeGiven = true)
      of "--mixed": (mode = mMixed; modeGiven = true)
      of "--hard": (mode = mHard; modeGiven = true)
      of "-q", "--quiet": quiet = true
      of "-h", "--help": (echo usageText; return 0)
      of "--merge", "--keep", "-N", "-p", "--patch", "--refresh",
         "--no-refresh":
        fail(a & " is out of scope for gittle v1 (docs/08)")
      else: fail("unknown option '" & a & "'\n" & usageText)
    else: rest.add a

  let repo = c.repo
  # A leading argument is the commit only if it names one; otherwise it, and
  # everything after it, is a path.
  var rev = "HEAD"
  if rest.len > 0 and (seenDashDash or repo.looksLikeRev(rest[0])):
    rev = rest[0]
    rest = rest[1 .. ^1]
  elif rest.len > 0 and not seenDashDash:
    # The first argument is a revision or an existing path; anything else is
    # a mistake, and saying so beats resetting nothing and reporting success.
    failAmbiguous(repo, rest[0])
  specs = rest & specs

  let idx = readIndex(repo.indexPath)

  proc report(paths: seq[string]) =
    ## What `refreshIndex` could not refresh: the work this reset has just
    ## left uncommitted.  git prints it in the porcelain form, and only when
    ## there is something to print.
    if quiet or paths.len == 0: return
    echo "Unstaged changes after reset:"
    for p in paths: echo "M\t" & p

  if specs.len > 0:
    # The pathspec form: the index only, and HEAD stays where it is.
    failIf(modeGiven, "Cannot do a " & ($mode)[1 .. ^1].toLowerAscii &
           " reset with paths")
    let ps = parsePathspec(specs, repo.prefix)
    let tree = repo.flatten(repo.resolveTree(rev))
    # Both directions: a path in the tree is copied in, and a path that is in
    # the index but *not* in the tree is removed -- which is what unstages a
    # newly added file.
    var gone: seq[string]
    for e in idx.entries:
      if e.stage == 0 and ps.matches(e.path) and e.path notin tree:
        gone.add e.path
    for path in gone: discard idx.removePath(path)
    for path, v in tree:
      if ps.matches(path) and idx.find(path) < 0 or
         (ps.matches(path) and versionOf(idx, path) != v):
        var e = IndexEntry(path: path, mode: v.mode, oid: v.oid)
        idx.addEntry(e)
    report(repo.refreshIndex(idx))
    idx.writeIndex()
    return 0

  let oid = repo.resolveCommittish(rev)
  let head = repo.refs.resolveRef(headRef)
  if head.found:
    # The only undo this command has.  Written before anything else moves.
    repo.refs.updateRef("ORIG_HEAD", head.oid, noDeref = true)

  if mode != mSoft:
    let newTree = repo.flatten(repo.peelTo(oid, otTree).oid)
    if mode == mHard: repo.resetWorkTree(idx, newTree)
    repo.resetIndexTo(idx, newTree)
    let stale = repo.refreshIndex(idx)
    idx.writeIndex()
    if mode == mMixed: report(stale)

  repo.refs.updateRef(headRef, oid, msg = "reset: moving to " & rev)

  if mode == mHard and not quiet:
    echo repo.headLine(oid)
  0
