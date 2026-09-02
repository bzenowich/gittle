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
## `-t`/`--no-track` and `-W`/`--worktree` were refused in the second
## minimisation pass (docs/minimize-2.md B4).  What is left of tracking is the
## rule nobody spells out anyway -- a branch created from a remote-tracking one
## tracks it -- and `restore` writes the working tree unless `--staged` says
## otherwise, so `-W` only ever restated that.
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
       ../refname, ../worktrees,
       ../refs, ../repository, ../revision, ../revwalk, ../status, ../util,
       ../worktree
import branch as cmdbranch

const

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
              detach, force, quiet: bool): int =
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
  # A branch in use in another worktree cannot be checked out here
  # (worktrees.nim).  Switching to the branch this worktree is already on is
  # exempt -- it makes nothing worse -- and so is `-b`, whose branch is new.
  if destRef.len > 0 and destRef != repo.headRefName and
     (newBranch.len == 0 or forceBranch):
    let where = repo.checkedOutAt(destRef)
    failIf(where.len > 0, "'" & destRef[heads.len .. ^1] &
           "' is already used by worktree at '" & where & "'")

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
    # A branch created from a remote-tracking one tracks it.  `-t`/`--no-track`
    # are cut (docs/minimize-2.md B4), so this is the whole of the rule.
    if d.found and d.full.startsWith(refsPrefix & "remotes/"):
      cmdbranch.setBranchUpstream(c, newBranch, d.full, quiet)

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
               toWorktree, toIndex: bool, stage = 0, overlay = true,
               report = false): int =
  ## Replace paths, and touch nothing else.
  ##
  ## `stage` is `--ours` (2) or `--theirs` (3): for a conflicted path the
  ## source becomes that stage rather than the index's own version, which is
  ## how a user takes one side of a conflict wholesale.  Merged paths are
  ## unaffected, so `checkout --ours .` in the middle of a merge also discards
  ## edits to files nobody conflicted over.
  ##
  ## A path that has no such stage -- `--theirs` on a file they deleted --
  ## is an error under `checkout`, which is *overlay* mode, and a deletion
  ## under `restore`, which is not (`builtin/checkout.c:checkout_stage`).
  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  let ps = parsePathspec(specs, repo.prefix)
  failIf(ps.isEmpty, "you must specify path(s) to restore")

  var src: TreeMap
  var sourceTree: Oid
  if sourceGiven:
    sourceTree = repo.resolveTree(source)
    src = repo.flatten(sourceTree)
  else:
    # No source: the index is the source, which is what makes `restore <path>`
    # and `checkout -- <path>` mean "throw away my edit".
    for e in idx.entries:
      if e.stage == 0:
        src[e.path] = Version(mode: canonMode(e.mode), oid: e.oid)

  # Every conflicted path the pathspec reaches is decided *before* anything is
  # written, and an undecidable one stops the whole command
  # (`builtin/checkout.c:checkout_paths` runs this as its own pass, ahead of
  # the writes).  Half a checkout is worse than none.
  #
  # A source tree makes the question moot: its version replaces every stage,
  # which is why `checkout HEAD -- <conflicted path>` is the third way to
  # resolve a conflict.
  var drop: seq[string]
  var failed = false
  if not sourceGiven:
    var last = ""
    for e in idx.entries:
      if e.stage == 0 or e.path == last: continue
      last = e.path
      if not ps.matches(e.path): continue
      if stage == 0:
        stderr.write "error: path '" & e.path & "' is unmerged\n"
        failed = true
        continue
      let k = idx.find(e.path, stage)
      if k >= 0:
        src[e.path] = Version(mode: canonMode(idx.entries[k].mode),
                              oid: idx.entries[k].oid)
      elif overlay:
        stderr.write "error: path '" & e.path & "' does not have " &
                     (if stage == 2: "our" else: "their") & " version\n"
        failed = true
      else: drop.add e.path
  if failed: return 1

  var (matched, n) = repo.checkoutPaths(idx, src, ps, toWorktree, toIndex,
                                        skipUnchanged = not sourceGiven)
  # No-overlay: a conflicted path with no such stage loses its *file*, but
  # keeps its stages -- the conflict is still unresolved, and the index is
  # where that is recorded.
  for path in drop:
    repo.removeWorkingPath(path)
    inc matched
    inc n
  if matched == 0:
    # An `error:` and exit 1: a pathspec that matches nothing is a mistake in
    # the command line, not a broken repository.  Checked before the count is
    # reported, as git checks it before it checks anything out.
    stderr.write "error: pathspec '" & specs[0] &
                 "' did not match any file(s) known to gittle\n"
    return 1
  if report:
    # `checkout <paths>` says how much it did; `checkout -- <paths>` and
    # `restore` do not, and the difference really is the `--`
    # (`builtin/checkout.c`: `count_checkout_paths = !quiet && !has_dash_dash`).
    stderr.write "Updated " & $n & " path" & (if n == 1: "" else: "s") &
                 " from " &
                 (if sourceGiven: repo.uniqueAbbrev(sourceTree, repo.autoAbbrev)
                  else: "the index") & "\n"
  idx.writeIndex()
  0

const
  synopses: array[Mode, string] = [
    "[<options>] <branch>\n[<options>] [<commit>] [--] <pathspec>…\n-b|-B <new-branch> [<start-point>]",
    "[<options>] <branch>\n-c|-C <new-branch> [<start-point>]\n-d <commit>",
    "[-s <tree-ish>] [-S] [--ours | --theirs] [--] <pathspec>…"]
  options = [
    opt("-f|--force|--discard-changes", help = "throw away local changes in the way"),
    opt("-q|--quiet", help = "say nothing"),
    opt("-d|--detach", help = "detach HEAD at the commit"),
    opt("-b|-c|--create", okValue, arg = "<branch>", help = "create a branch first"),
    opt("-B|-C|--force-create", okValue, arg = "<branch>", help = "create or reset a branch first"),
    opt("-s|--source", okValue, arg = "<tree-ish>", help = "restore from this tree"),
    opt("-S|--staged", help = "restore the index"),
    opt("--ours", help = "take our side of a conflict"),
    opt("--theirs", help = "take their side of a conflict"),
    opt("-t|--track|--no-track", okRefused,
        help = "a branch created from a remote-tracking one tracks it; there is no other rule"),
    opt("-W|--worktree", okRefused,
        help = "restore writes the working tree unless --staged says otherwise"),
    opt("-m|--merge|-p|--patch|--orphan|--overlay|--no-overlay|--conflict|--guess|--no-guess",
        okRefused, help = "docs/06"),
  ]
  names: array[Mode, string] = ["checkout", "switch", "restore"]

proc run(c: Ctx, args: seq[string], mode: Mode): int =
  ## The one body behind `checkout`, `switch` and `restore`: parse against
  ## the mode's synopsis, decide whether the positionals are a branch or
  ## paths, and hand off to the branch switch or the path restore.
  let o = parse(options, args, names[mode], synopses[mode])
  # `--ours` is stage 2 and `--theirs` stage 3; naming both is nonsense, and
  # the one written last is the one git acts on.
  var stage = 0
  for (k, _) in o.occurrences:
    if k in ["ours", "theirs"]: stage = (if k == "ours": 2 else: 3)
  let force = o.has "force"
  let quiet = o.has "quiet"
  let detach = o.has "detach"
  let staged = o.has "staged"
  let forceBranch = o.has "force-create"
  var newBranch = if forceBranch: o.val "force-create" else: o.val "create"
  var sourceGiven = o.has "source"
  var source = o.val "source"
  let seenDashDash = o.dashDash
  # Before `--` a word may be a revision or a path; after it, only a path.
  var rest = if o.dashDashAt >= 0: o.args[0 ..< o.dashDashAt] else: o.args
  var specs = if o.dashDashAt >= 0: o.args[o.dashDashAt .. ^1] else: @[]
  let repo = c.repo

  if mode == mRestore:
    specs = rest & specs
    # `--staged` alone means the index only; naming both, or neither, is the
    # documented way to say "both" and "the working tree".
    # `--staged` with no `--source` restores from HEAD: the index's own
    # content is what is being replaced, so it cannot also be the source.
    failIf(stage != 0 and staged,
           "'--ours' or '--theirs' cannot be used with --staged")
    if staged and not sourceGiven:
      source = "HEAD"
      sourceGiven = true
    # `restore` is the no-overlay one: a path with no such stage is removed
    # rather than reported.
    return c.doRestore(source, sourceGiven, specs, toWorktree = not staged,
                       toIndex = staged, stage = stage, overlay = false)

  # `checkout` has to decide, per invocation, whether it was asked to switch
  # or to restore -- and the answer is "restore" as soon as any path is named.
  # `checkout <tree-ish> <pathspec>…` needs no `--` when the first argument
  # resolves and the rest cannot be references -- git only insists on the
  # separator when the first argument is ambiguous.
  if mode == mCheckout and newBranch.len == 0 and (specs.len > 0 or
      rest.len > 1 or (rest.len > 0 and not repo.looksLikeRev(rest[0]))):
    var tree = ""
    var given = false
    if rest.len > 0 and (seenDashDash or repo.looksLikeRev(rest[0])):
      tree = rest[0]
      given = true
      rest = rest[1 .. ^1]
    specs = rest & specs
    return c.doRestore(tree, given, specs, toWorktree = true, toIndex = given,
                       stage = stage, report = not quiet and not seenDashDash)

  failIf(rest.len > 1, o.use)
  var target = if rest.len > 0: rest[0]
               elif newBranch.len > 0: "HEAD"
               else:
                 failIf(mode == mCheckout, o.use)
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
  c.doSwitch(target, newBranch, forceBranch, detach, force, quiet)

# Entry point for `checkout`.
proc cmdCheckout*(c: Ctx, args: seq[string]): int = run(c, args, mCheckout)
# Entry point for `switch`.
proc cmdSwitch*(c: Ctx, args: seq[string]): int = run(c, args, mSwitch)
# Entry point for `restore`.
proc cmdRestore*(c: Ctx, args: seq[string]): int = run(c, args, mRestore)
