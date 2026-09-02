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


type Mode = enum mSoft, mMixed, mHard

const
  synopsis = "[--soft | --mixed | --hard] [-q] [<commit>]\n[<tree-ish>] [--] <pathspec>…"
  options = [
    opt("--soft", help = "move HEAD only"),
    opt("--mixed", help = "move HEAD and reset the index (the default)"),
    opt("--hard", help = "move HEAD and reset the index and the working tree"),
    opt("-q|--quiet", help = "report only errors"),
    opt("--merge|--keep|-N|-p|--patch|--refresh|--no-refresh", okRefused, help = "docs/08"),
  ]

proc cmdReset*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, tell a revision from a path, then either the
  ## path form (unstage) or the mode form (move HEAD, and the index and
  ## tree as the mode says).
  let o = parse(options, args, "reset", synopsis)
  var mode = mMixed
  var modeGiven = false
  for (k, _) in o.occurrences:
    case k
    of "soft": (mode = mSoft; modeGiven = true)
    of "mixed": (mode = mMixed; modeGiven = true)
    of "hard": (mode = mHard; modeGiven = true)
    else: discard
  let quiet = o.has "quiet"
  let seenDashDash = o.dashDash
  # Before `--` a word may be a revision or a path; after it, only a path.
  var rest = if o.dashDashAt >= 0: o.args[0 ..< o.dashDashAt] else: o.args
  var specs = if o.dashDashAt >= 0: o.args[o.dashDashAt .. ^1] else: @[]
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
