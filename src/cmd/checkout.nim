## `checkout`, `switch` and `restore` -- three commands, two operations.
##
## `checkout` predates the split and does both: given a branch it **switches**,
## given paths it **restores**.  git split it in 2.23 precisely because those
## are different and dangerous to confuse -- `git checkout <name>` where a
## file and a branch share a name did one of them and the user meant the
## other.  All three are here, sharing the code, because they *are* the same
## code and the difference is which half a command's arguments are allowed to
## reach.
##
## | | switches HEAD | writes the index | writes the working tree |
## |---|---|---|---|
## | `checkout <branch>` | yes | to the new tree | to the new tree |
## | `checkout <tree> -- <paths>` | no | those paths | those paths |
## | `checkout -- <paths>` | no | no | from the index |
## | `switch <branch>` | yes | to the new tree | to the new tree |
## | `restore <paths>` | no | no | from the index |
## | `restore --staged <paths>` | no | from HEAD | no |
## | `restore -s <tree> <paths>` | no | with `--staged` | yes |
##
## The switching half is `worktree.nim`'s two-way update, which refuses rather
## than overwrites.  The restoring half does not check anything: the user
## named the paths, so replacing them is the request.
##
## ## What a switch has to say afterwards
##
## More than it looks.  `Switched to branch 'x'` is the easy part; the
## interesting one is that leaving a branch for a bare commit prints a whole
## paragraph of advice, because a commit made on a detached HEAD is reachable
## from nothing and is the one way an ordinary git session loses work.  gittle
## prints git's paragraph verbatim -- it is the message, not decoration.

import std/[strutils, tables]
import ../cli, ../diffcore, ../index, ../objects, ../pathspec,
       ../refname,
       ../refs, ../repository, ../revision, ../revwalk, ../status, ../util,
       ../worktree
import branch as cmdbranch

const
  usageText = """usage: gittle checkout [<options>] <branch>
   or: gittle checkout [<options>] [<tree-ish>] [--] <pathspec>…

   -b <branch>               create a branch and switch to it
   -B <branch>               as -b, resetting the branch if it exists
   -d, --detach              check out a commit, leaving HEAD detached
   -f, --force               throw away local changes while switching
   -q, --quiet               say nothing on success
   -t, --track, --no-track   set up (or do not set up) upstream tracking
   --ours, --theirs          for unmerged paths, take stage 2 or stage 3"""

  detachedAdvice = """

You are in 'detached HEAD' state. You can look around, make experimental
changes and commit them, and you can discard any commits you make in this
state without impacting any branches by switching back to a branch.

If you want to create a new branch to retain commits you create, you may
do so (now or later) by using -c with the switch command. Example:

  gittle switch -c <new-branch-name>

Or undo this operation with:

  gittle switch -

Turn off this advice by setting config variable advice.detachedHead to false
"""
    ## `advice.c:advise_detached_head`, verbatim.  The paragraph is the point:
    ## a commit made here is reachable from no ref, and this is the only
    ## warning the user gets before making one.

  heads = refsPrefix & "heads/"

type Mode = enum mCheckout, mSwitch, mRestore

proc doSwitch(c: Ctx, target: string, newBranch: string, forceBranch: bool,
              detach, force, quiet, track, trackGiven: bool): int =
  ## Move HEAD, and bring the index and the working tree with it.
  let repo = c.repo
  let oid = repo.resolveCommittish(target)
  let d = repo.refs.dwimRef(target)

  # Where HEAD will point afterwards: a branch when one was named or created,
  # and the commit itself otherwise.
  var destRef = ""
  if newBranch.len > 0:
    failIf(not isValidRefname(heads & newBranch, {}),
           "'" & newBranch & "' is not a valid branch name")
    let existing = repo.refs.readRef(heads & newBranch)
    failIf(existing.found and not forceBranch,
           "a branch named '" & newBranch & "' already exists")
    destRef = heads & newBranch
  elif not detach and d.found and d.full.startsWith(heads):
    destRef = d.full

  let head = repo.refs.resolveRef(headRef)
  let idx = readIndex(repo.indexPath)
  let oldTree = if head.found: repo.flatten(repo.peelTo(head.oid, otTree).oid)
                else: TreeMap()
  let newTree = repo.flatten(repo.peelTo(oid, otTree).oid)
  let plan = repo.planTwoWay(idx, oldTree, newTree, force)
  # "checkout" for `switch` too: git hardcodes the word when it sets up the
  # messages (`builtin/checkout.c` passes "checkout" from both entry points),
  # and the advice line then says "switch branches" for either.
  if plan.refused("checkout"): return 1
  repo.applyPlan(idx, plan, newTree)
  idx.writeIndex()

  # What is *still* different after the switch: a local change that survived
  # because neither side touched the path.  git prints it as a name-status
  # diff of the new commit against the working tree, so that a carried-over
  # edit is announced rather than discovered later
  # (`builtin/checkout.c:show_local_changes`).
  if not force and not quiet:
    var dopts = defaultDiffOpts()
    dopts.formats = {dfNameStatus}
    # Deliberately not flushed: git's own ordering has the "Switched to
    # branch" line -- which goes to standard error, unbuffered -- appear
    # first, and a script capturing both streams sees them in that order.
    stdout.write renderDiff(repo, pairsTreeWork(repo,
                            repo.peelTo(oid, otTree).oid, idx,
                            parsePathspec(@[])), dopts).text

  # The reflog names both ends, which is what `@{-1}` and `checkout -` read
  # back later -- so it has to be written even when the branch does not move.
  let fromName = if repo.headRefName.startsWith(heads):
                   repo.headRefName[heads.len .. ^1]
                 else: repo.uniqueAbbrev(head.oid, repo.autoAbbrev)
  # Detaching records the argument **as typed** -- `v1`, `HEAD~1` -- because
  # that is what `HEAD@{1}` and the "detached at" description read back, and a
  # name the user recognises is the whole value of the entry.
  let toName = if destRef.len > 0: destRef[heads.len .. ^1] else: target
  let msg = "checkout: moving from " & fromName & " to " & toName

  var branchExisted = false
  if newBranch.len > 0:
    branchExisted = repo.refs.readRef(destRef).found
    repo.refs.updateRef(destRef, oid, msg =
      (if branchExisted: "branch: Reset to " else: "branch: Created from ") & target)
    if trackGiven and track or (not trackGiven and d.found and
       d.full.startsWith(refsPrefix & "remotes/")):
      if d.found: cmdbranch.setBranchUpstream(c, newBranch, d.full, quiet)

  if destRef.len > 0:
    let already = repo.headRefName == destRef
    repo.refs.writeSymRef(headRef, destRef, msg = msg)
    if not quiet:
      let name = destRef[heads.len .. ^1]
      stderr.write (if newBranch.len > 0 and branchExisted:
                      "Switched to and reset branch '"
                    elif newBranch.len > 0: "Switched to a new branch '"
                    elif already: "Already on '"
                    else: "Switched to branch '") & name & "'\n"
      # The same tracking line `status` prints, from the same code: after a
      # switch the user wants to know where the new branch stands.
      stderr.write repo.trackingOf(destRef).trackingLine
  else:
    let wasAttached = repo.headRefName != headRef
    if not quiet and wasAttached and not detach:
      # Only the *unasked-for* detachment gets the lecture: `--detach` says
      # the user knows.
      stderr.write "Note: switching to '" & target & "'.\n" & detachedAdvice & "\n"
    repo.refs.updateRef(headRef, oid, msg = msg, noDeref = true)
    if not quiet: stderr.write repo.headLine(oid) & "\n"
  0

proc doRestore(c: Ctx, source: string, sourceGiven: bool, specs: seq[string],
               toWorktree, toIndex: bool): int =
  ## Replace paths, and touch nothing else.
  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  let ps = parsePathspec(specs, repo.prefix)
  failIf(ps.isEmpty, "you must specify path(s) to restore")

  var src: TreeMap
  if sourceGiven:
    src = repo.flatten(repo.resolveTree(source))
  else:
    # No source: the index is the source, which is what makes `restore <path>`
    # and `checkout -- <path>` mean "throw away my edit".
    for e in idx.entries:
      if e.stage == 0:
        src[e.path] = Version(mode: canonMode(e.mode), oid: e.oid)

  let n = repo.checkoutPaths(idx, src, ps, toWorktree, toIndex)
  if n == 0:
    # An `error:` and exit 1: a pathspec that matches nothing is a mistake in
    # the command line, not a broken repository.
    stderr.write "error: pathspec '" & specs[0] &
                 "' did not match any file(s) known to gittle\n"
    return 1
  idx.writeIndex()
  0

proc run(c: Ctx, args: seq[string], mode: Mode): int =
  var newBranch = ""
  var source = ""
  var specs: seq[string]
  var rest: seq[string]
  var forceBranch, detach, force, quiet, track, trackGiven = false
  var sourceGiven, staged, worktreeGiven, seenDashDash = false
  var i = 0
  let a2 = expandShortOptions(args, {'b', 'B', 'c', 'C', 's'})

  optionValue(a2, i)

  while i < a2.len:
    let a = a2[i]
    if seenDashDash: specs.add a
    elif a == "--": seenDashDash = true
    elif a.len > 1 and a[0] == '-':
      case a
      of "-f", "--force", "--discard-changes": force = true
      of "-q", "--quiet": quiet = true
      of "-d", "--detach": detach = true
      of "-t", "--track": (track = true; trackGiven = true)
      of "--no-track": (track = false; trackGiven = true)
      of "-S", "--staged": staged = true
      of "-W", "--worktree": worktreeGiven = true
      of "-h", "--help": (echo usageText; return 0)
      of "--ours", "--theirs":
        fail(a & " needs unmerged index entries, which arrive with the merge " &
             "machinery in phase 7")
      of "-m", "--merge", "-p", "--patch", "--orphan", "--overlay",
         "--no-overlay", "--conflict", "--guess", "--no-guess":
        fail(a & " is out of scope for gittle v1 (docs/06)")
      else:
        if a == "-b" or a == "-c" or a == "--create": newBranch = valueFor(a)
        elif a == "-B" or a == "-C" or a == "--force-create":
          newBranch = valueFor(a)
          forceBranch = true
        elif a == "-s" or a.startsWith("--source"):
          source = valueFor(a)
          sourceGiven = true
        else: fail("unknown option '" & a & "'\n" & usageText)
    else:
      rest.add a
    inc i

  let repo = c.repo

  if mode == mRestore:
    specs = rest & specs
    # `--staged` alone means the index only; naming both, or neither, is the
    # documented way to say "both" and "the working tree".
    # `--staged` with no `--source` restores from HEAD: the index's own
    # content is what is being replaced, so it cannot also be the source.
    if staged and not sourceGiven:
      source = "HEAD"
      sourceGiven = true
    return c.doRestore(source, sourceGiven, specs,
                       toWorktree = worktreeGiven or not staged,
                       toIndex = staged)

  # `checkout` has to decide, per invocation, whether it was asked to switch
  # or to restore -- and the answer is "restore" as soon as any path is named.
  if mode == mCheckout and (specs.len > 0 or
      (rest.len > 0 and newBranch.len == 0 and not repo.looksLikeRev(rest[0]))):
    var tree = ""
    var given = false
    if rest.len > 0 and (seenDashDash or repo.looksLikeRev(rest[0])):
      tree = rest[0]
      given = true
      rest = rest[1 .. ^1]
    specs = rest & specs
    return c.doRestore(tree, given, specs, toWorktree = true, toIndex = given)

  failIf(rest.len > 1, usageText)
  var target = if rest.len > 0: rest[0]
               elif newBranch.len > 0: "HEAD"
               else:
                 failIf(mode == mCheckout, usageText)
                 fail("you must specify a branch to switch to")
  # `checkout -` and `switch -` are `@{-1}`: the branch you were on before.
  if target == "-": target = "@{-1}"
  failIf(mode == mSwitch and newBranch.len == 0 and not repo.looksLikeRev(target),
         "invalid reference: " & target)
  if mode == mSwitch and not detach and newBranch.len == 0:
    # `switch` refuses to detach by accident -- that is the whole reason it
    # exists next to `checkout` -- and names what it got instead, because
    # "that is a tag" and "that is a raw commit" are different mistakes
    # (`builtin/checkout.c:die_expecting_a_branch`).
    let d2 = repo.refs.dwimRef(target)
    if not d2.full.startsWith(heads):
      var what = "commit '" & target & "'"
      for (prefix, label) in {"refs/tags/": "tag", "refs/remotes/": "remote branch"}:
        if d2.found and d2.full.startsWith(prefix):
          what = label & " '" & d2.full[prefix.len .. ^1] & "'"
      if d2.found and what.startsWith("commit"): what = "'" & d2.full & "'"
      fail("a branch is expected, got " & what & "\nhint: If you want to " &
           "detach HEAD at the commit, try again with the --detach option.")
  c.doSwitch(target, newBranch, forceBranch, detach, force, quiet,
             track, trackGiven)

proc cmdCheckout*(c: Ctx, args: seq[string]): int = run(c, args, mCheckout)
proc cmdSwitch*(c: Ctx, args: seq[string]): int = run(c, args, mSwitch)
proc cmdRestore*(c: Ctx, args: seq[string]): int = run(c, args, mRestore)
