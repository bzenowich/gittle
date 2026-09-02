## `merge` -- join another history into this one.
##
## In scope (docs/07, docs/05 `merge-options`): `<commit>`, `-m`,
## `--ff`/`--no-ff`/`--ff-only`, `--commit`/`--no-commit`,
## `-e`/`--edit`/`--no-edit`, `-s`/`--signoff`, `-q`/`-v`, and the three
## state verbs `--abort`, `--quit`, `--continue`.
##
## ## The three outcomes, and why fast-forward is not a merge
##
## | | |
## |---|---|
## | theirs is already an ancestor of ours | `Already up to date.` -- nothing to do |
## | ours is an ancestor of theirs | **fast-forward**: move the branch, no commit |
## | neither | a real three-way merge, and a commit with two parents |
##
## A fast-forward records nothing: the branch label simply moves to a commit
## that already has ours in its history, so no new object is written and the
## history stays linear.  `--no-ff` forces the commit anyway, which is how a
## project keeps the shape of a topic branch visible; `--ff-only` refuses
## anything else, which is how a script keeps history linear.
##
## ## What is cut
##
## `-s`/`-X` (only `ort` exists here -- R4), `--squash`, `--log`,
## `--autostash`, `--allow-unrelated-histories`, `--verify-signatures`, `-F`,
## and the octopus case: a second `<commit>` is refused rather than merged.
## No hook fires, here or anywhere but `commit` (plan.md decision 1), so
## `pre-merge-commit` and `post-merge` do not run.

import std/strutils
import ../cli, ../commitobj, ../diffcore, ../ident, ../index, ../mergetree,
       ../objects, ../oid, ../pathspec, ../refs, ../repository, ../revision,
       ../revwalk, ../sequencer, ../util, ../worktree


const editTemplate = """
# Please enter a commit message to explain why this merge is necessary,
# especially if it merges an updated upstream into a topic branch.
#
# Lines starting with '#' will be ignored, and an empty message aborts
# the commit.
"""

type FfMode = enum ffAuto, ffNever, ffOnly

proc defaultMessage(repo: Repository, target: string, oid: Oid): string =
  ## `fmt-merge-msg`'s title line, which is what the merge commit says when
  ## `-m` did not.
  ##
  ## The kind of ref decides the wording, and `into <branch>` is appended
  ## *unless the branch is `main` or `master`* -- git's default
  ## `merge.suppressDest` (`fmt-merge-msg.c`), on the grounds that merging into
  ## the trunk is the unremarkable case and does not need saying.
  let d = repo.refs.dwimRef(target)
  var what = "commit '" & target & "'"
  if d.found:
    const kinds = [("refs/heads/", "branch '"),
                   ("refs/tags/", "tag '"),
                   ("refs/remotes/", "remote-tracking branch '")]
    for (prefix, word) in kinds:
      if d.full.startsWith(prefix):
        what = word & d.full[prefix.len .. ^1] & "'"
        break
  result = "Merge " & what
  const heads = refsPrefix & "heads/"
  let head = repo.headRefName
  if head.startsWith(heads):
    let branch = head[heads.len .. ^1]
    if branch != "main" and branch != "master":
      result.add " into " & branch
  result.add "\n"

  # Merging an annotated tag quotes the tag's own message underneath, because
  # that message is the release note somebody wrote and the merge is where it
  # belongs (`fmt-merge-msg.c:fmt_tag_signature`).
  let obj = repo.readObject(oid)
  if obj.kind == otTag:
    let sep = obj.data.find("\n\n")
    if sep >= 0:
      var body = obj.data[sep + 2 .. ^1]
      body = stripSignature(body)
      if body.len > 0 and body[^1] != '\n': body.add '\n'
      result.add "\n" & body

proc commitMerge(repo: Repository, idx: Index, parents: seq[Oid],
                 msg0: string, useEditor, signoff: bool,
                 reflogPrefix: string, reflogTail = ""): tuple[oid: Oid,
                 msg: string] =
  ## Write the merge commit and move HEAD.  Shared by the clean-merge path and
  ## by `--continue`, which is the same act with the message already on disk.
  ##
  ## The reflog line is the prefix plus `reflogTail`, or plus the message's own
  ## subject when no tail is given: `merge` records what it *did* ("Merge made
  ## by the 'ort' strategy."), and a merge concluded by hand records what the
  ## user said.
  result.msg = repo.finalMessage(msg0, useEditor, signoff, editTemplate)
  result.oid = repo.commitOnHead(idx, parents, getIdent(repo.cfg, irAuthor),
    result.msg,
    reflogPrefix & (if reflogTail.len > 0: reflogTail else: result.msg.subject))
  repo.removeState("MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE")

proc printStat(repo: Repository, oldTree, newTree: Oid) =
  ## The diffstat between two trees, as `merge` prints it after a
  ## fast-forward or a merge commit.
  stdout.write repo.mergeSummary(pairsTreeTree(repo, oldTree, newTree,
                                               parsePathspec(@[])))
  stdout.flushFile()

const
  synopsis = "[-m <msg>] [--ff|--no-ff|--ff-only] [--[no-]commit] [-e|--no-edit] [-s] [-q|-v] <commit>\n--abort | --quit | --continue"
  options = [
    opt("-m|--message", okValue, arg = "<msg>", help = "the merge commit's message"),
    opt("--ff", help = "fast-forward when possible (the default)"),
    opt("--no-ff", help = "always make a merge commit"),
    opt("--ff-only", help = "refuse anything but a fast-forward"),
    opt("--commit", help = "commit the result (the default)"),
    opt("--no-commit", help = "stop before committing"),
    opt("-e|--edit", help = "open the editor on the message"),
    opt("--no-edit", help = "never open the editor"),
    opt("-s|--signoff", help = "add a Signed-off-by trailer"),
    opt("--no-signoff"),
    opt("-q|--quiet", help = "print no summary"),
    opt("-v|--verbose", help = "print the summary (the default)"),
    opt("--abort", help = "undo an unfinished merge"),
    opt("--quit", help = "forget an unfinished merge, keeping the tree as it is"),
    opt("--continue", help = "conclude a merge whose conflicts are resolved"),
    opt("-F|--file|--into-name|--overwrite-ignore|--no-overwrite-ignore|--cleanup|" &
        "--strategy|-X|--strategy-option|--squash|--no-squash|--log|--no-log|--stat|-n|" &
        "--no-stat|--compact-summary|--summary|--no-summary|--verify|--no-verify|" &
        "--verify-signatures|--no-verify-signatures|--autostash|--no-autostash|" &
        "--allow-unrelated-histories|--progress|--no-progress|--rerere-autoupdate",
        okRefused, help = "docs/07"),
  ]

proc cmdMerge*(c: Ctx, argv: seq[string]): int =
  ## Entry point: parse, then abort/quit/continue a stopped merge, or
  ## merge the target: fast-forward when allowed, else the three-way
  ## merge and a commit unless `--no-commit` or a conflict stops it.
  let o = parse(options, argv, "merge", synopsis)
  var ff = ffAuto
  var noCommit, signoff, quiet = false
  for (k, _) in o.occurrences:        # each pair: the last one given wins
    case k
    of "ff": ff = ffAuto
    of "no-ff": ff = ffNever
    of "ff-only": ff = ffOnly
    of "commit": noCommit = false
    of "no-commit": noCommit = true
    of "signoff": signoff = true
    of "no-signoff": signoff = false
    of "quiet": quiet = true
    of "verbose": quiet = false
    else: discard
  let messages = o.vals "message"
  let forceEdit = o.has "edit"
  let noEdit = o.has "no-edit"
  let abort = o.has "abort"
  let quit0 = o.has "quit"
  let cont = o.has "continue"
  let targets = o.args
  let repo = c.repo
  failIf(repo.workTree.len == 0, "merge is not possible in a bare repository")
  let idx = readIndex(repo.indexPath)
  let head = repo.refs.resolveRef(headRef)

  # ---- the three state verbs, each of which ignores <commit> entirely
  if abort or quit0 or cont:
    let op = repo.currentOp
    failIf(op != opMerge,
           (if cont: "There is no merge in progress (MERGE_HEAD missing)."
            else: "There is no merge to " & (if abort: "abort" else: "quit") &
                  " (MERGE_HEAD missing)."))
    if quit0:
      # Forget the merge; keep whatever the working tree and index now hold.
      repo.removeState("MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE")
      return 0
    if abort:
      repo.restoreTo(idx, head.oid)
      # git aborts by running a real `reset --hard HEAD`, and that leaves its
      # reflog entry behind even though HEAD did not move.
      repo.refs.updateRef(headRef, head.oid, msg = "reset: moving to HEAD")
      repo.removeState("MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE")
      return 0
    for e in idx.entries:
      if e.stage != 0: repo.dieResolveConflict("commit", idx)
    let made = commitMerge(repo, idx, @[head.oid] & repo.mergeHeads,
                           repo.readState("MERGE_MSG"),
                           useEditor = not noEdit, signoff = signoff,
                           reflogPrefix = "commit (merge): ")
    if not quiet: repo.summarizeCommit(made.oid)
    return 0

  repo.refuseIfInProgress(idx, "merge")
  failIf(targets.len == 0, "no commit specified\n" & o.use)
  failIf(targets.len > 1,
         "merging more than one commit at a time is out of scope for " &
         "gittle v1 (docs/05 cuts the octopus strategy)")
  failIf(not head.found, "merge into an unborn branch is out of scope for " &
         "gittle v1; use 'gittle checkout' or 'gittle reset'")
  let target = targets[0]
  let ours = head.oid
  if not repo.looksLikeRev(target):
    # git's `help_unknown_ref`: a line with no `error:` on it and a status of
    # 1, not a fatal -- the repository is fine, only the argument was not.
    stderr.write "merge: " & target & " - not something we can merge\n"
    return 1
  let named = repo.resolveRevish(target)
  let theirs = repo.resolveCommittish(target)

  # ORIG_HEAD is written before anything is decided, including before
  # "Already up to date": it is the user's way back, and `builtin/merge.c`
  # updates it as soon as the merge bases are known.
  repo.writeState("ORIG_HEAD", $ours & "\n")

  # ---- already up to date, and fast-forward
  if repo.isAncestor(theirs, ours):
    if not quiet: echo "Already up to date."
    return 0
  if repo.isAncestor(ours, theirs) and ff != ffNever:
    let oldTree = repo.peelTo(ours, otTree).oid
    let newTree = repo.peelTo(theirs, otTree).oid
    let plan = repo.planTwoWay(idx, repo.flatten(oldTree), repo.flatten(newTree),
                               force = false)
    if plan.refused("merge"):
      stderr.write "Merge with strategy ort failed.\n"
      return 2
    if not quiet:
      echo "Updating " & repo.uniqueAbbrev(ours, repo.autoAbbrev) & ".." &
           repo.uniqueAbbrev(theirs, repo.autoAbbrev)
      echo "Fast-forward"
    repo.applyPlan(idx, plan, repo.flatten(newTree))
    idx.writeIndex()
    repo.refs.updateRef(headRef, theirs, oldOid = ours, checkOld = true,
                        msg = (if c.reflogAction.len > 0: c.reflogAction
                               else: "merge " & target) & ": Fast-forward")
    if not quiet: printStat(repo, oldTree, newTree)
    return 0
  if ff == ffOnly:
    if repo.cfg.getBool("advice.diverging", true):
      stderr.write "hint: Diverging branches can't be fast-forwarded, you " &
        "need to either:\nhint:\nhint: \tgittle merge --no-ff\nhint:\n" &
        "hint: or:\nhint:\nhint: \tgittle rebase\nhint:\n" &
        "hint: Disable this message with \"gittle config set " &
        "advice.diverging false\"\n"
    fail("Not possible to fast-forward, aborting.")

  # ---- the real thing
  let opts = MergeOpts(labelOurs: "HEAD", labelTheirs: target)
  let oursTree = repo.peelTo(ours, otTree).oid
  let res = repo.mergeIntoWorkTree(idx,
    repo.flatten(repo.virtualBase(ours, theirs)),
    repo.flatten(oursTree),
    repo.flatten(repo.peelTo(theirs, otTree).oid), opts, "merge")
  reportMerge(res)
  idx.writeIndex()

  var msg = joinMessages(messages)
  if msg.len == 0: msg = defaultMessage(repo, target, named)
  repo.writeState("ORIG_HEAD", $ours & "\n")
  repo.writeState("MERGE_HEAD", $theirs & "\n")
  repo.writeState("MERGE_MSG", msg & res.conflictComments)
  repo.writeState("MERGE_MODE", if ff == ffNever: "no-ff\n" else: "")

  if res.conflicts > 0:
    echo "Automatic merge failed; fix conflicts and then commit the result."
    return 1
  if noCommit:
    # The merge is in the index and the working tree; the state files stay so
    # that `commit` still records two parents.
    return 0

  # An editor only on request: git opens one for a merge it *created* the
  # message for only when `merge.edit` or `-e` says so, and never for `-m`.
  const made = "Merge made by the 'ort' strategy."
  # The reflog says what the merge *did*, not what its message said -- so the
  # strategy line is the reflog entry and the subject is not.
  let newOid = commitMerge(repo, idx, @[ours, theirs], msg,
                           useEditor = forceEdit and not noEdit,
                           signoff = signoff,
                           reflogPrefix = (if c.reflogAction.len > 0: c.reflogAction
                                           else: "merge " & target) & ": ",
                           reflogTail = made).oid
  if not quiet:
    echo made
    printStat(repo, oursTree, repo.peelTo(newOid, otTree).oid)
  0
