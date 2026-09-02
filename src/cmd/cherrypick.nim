## `cherry-pick` and `revert` -- replay a commit, or undo one.
##
## One file, because they are one command with the three trees swapped:
##
## | | base | ours | theirs |
## |---|---|---|---|
## | `cherry-pick C` | C's parent | HEAD | C |
## | `revert C` | C | HEAD | C's parent |
##
## That is the whole difference in the mechanism.  What is left differs only in
## the message -- a pick keeps the original's message and *author*, a revert
## writes `Revert "…"` and is authored by whoever ran it -- and in which state
## file names the commit in progress.
##
## In scope (docs/06, docs/08, docs/05 `sequencer`): `<commit>…` and ranges,
## `-e`/`--edit`/`--no-edit`, `-x`, `-n`/`--no-commit`, `-s`/`--signoff`, and
## `--continue`/`--skip`/`--quit`/`--abort`.  Cut: `-m` (picking a merge
## relative to a parent), `--ff`, `--allow-empty`, `--empty=`, `--cleanup`,
## `--strategy`/`-X`, `--reference`, and rerere.
##
## ## Why the merge base is the parent, and not a merge base
##
## `merge` asks "what is the common ancestor of these two histories".  A pick
## does not: the change being replayed is exactly `parent -> commit`, so the
## parent *is* the base, and there is no ancestry question to answer.  git
## calls `merge_incore_nonrecursive` here for that reason
## (`sequencer.c:do_recursive_merge`), and gittle calls `mergeTrees` directly
## rather than going through `virtualBase`.
##
## ## The todo list
##
## A single commit leaves no `sequencer/` directory: there is nothing to
## remember, since a conflict stops before HEAD has moved and `--abort` is
## then just "put HEAD's content back".  Two or more create one, because
## stopping halfway means some picks have already been committed and `--abort`
## has to undo them (`sequencer/head`), while `--continue` has to know which
## are left (`sequencer/todo`).

import std/[os, posix, strutils]
import ../cli, ../commitobj, ../ident, ../index, ../mergetree, ../objects,
       ../oid, ../pretty, ../refs, ../repository, ../revision, ../revwalk,
       ../sequencer, ../util

type Kind* = enum pkCherry, pkRevert

const usageText = """usage: gittle cherry-pick [-e|--no-edit] [-x] [-n] [-s] <commit>…
   or: gittle revert     [-e|--no-edit] [-n] [-s] <commit>…
   or: gittle <either> --continue | --skip | --quit | --abort"""

func verb(k: Kind): string = (if k == pkCherry: "cherry-pick" else: "revert")
func headFile(k: Kind): string =
  if k == pkCherry: "CHERRY_PICK_HEAD" else: "REVERT_HEAD"

proc pickMessage(repo: Repository, k: Kind, c: Commit, oid: Oid,
                 recordOrigin: bool): string =
  ## What the replayed commit will say.
  if k == pkRevert:
    # `sequencer.c:sequencer_format_revert_message`.  The full object ID, not
    # an abbreviation: this line is the machine-readable record of what was
    # undone, and an abbreviation can become ambiguous as the repository grows.
    return "Revert \"" & subject(c.message) & "\"\n\nThis reverts commit " &
           $oid & ".\n"
  result = c.message
  if recordOrigin:
    # `-x`.  A blank line first unless the message already ends in a trailer
    # block, so the footer does not glue itself to a paragraph.
    if result.len > 0 and result[^1] != '\n': result.add "\n"
    result.add "\n(cherry picked from commit " & $oid & ")\n"

proc todoLine(repo: Repository, k: Kind, oid: Oid, msg: string): string =
  (if k == pkCherry: "pick " else: "revert ") &
  repo.uniqueAbbrev(oid, repo.autoAbbrev) & " " & subject(msg) & "\n"

proc conflictAdvice(repo: Repository, k: Kind, oid: Oid, subj: string) =
  ## What git says when a pick stops.  The `error:` line names the commit that
  ## could not be applied; the hints are the three ways forward, and they are
  ## printed because a user who has never seen this has no way to guess them.
  let v = k.verb
  stderr.write "error: could not " & (if k == pkCherry: "apply " else: "revert ") &
               repo.uniqueAbbrev(oid, repo.autoAbbrev) & "... " & subj & "\n"
  if repo.cfg.getBool("advice.mergeConflict", true):
    stderr.write "hint: After resolving the conflicts, mark them with\n" &
      "hint: \"gittle add/rm <pathspec>\", then run\n" &
      "hint: \"gittle " & v & " --continue\".\n" &
      "hint: You can instead skip this commit with \"gittle " & v &
      " --skip\".\n" &
      "hint: To abort and get back to the state before \"gittle " & v &
      "\",\nhint: run \"gittle " & v & " --abort\".\n" &
      "hint: Disable this message with \"gittle config set " &
      "advice.mergeConflict false\"\n"

proc writeTodo(repo: Repository, k: Kind, todo: seq[Oid], from0: int) =
  ## The remaining picks, current one first.  Absent when only one is left to
  ## do and nothing has been done, which is git's rule for not creating the
  ## directory at all.
  var text = ""
  for i in from0 ..< todo.len:
    text.add repo.todoLine(k, todo[i],
                           parseCommit(repo.readObject(todo[i]).data).message)
  repo.writeState(sequencerDir / "todo", text)

proc doCommit(repo: Repository, idx: Index, msg0: string, author: Ident,
              useEditor, signoff: bool, reflog: string, showDate = true): int =
  ## Write the replayed commit.  The tree comes from the index, so this is the
  ## same act whether the pick applied cleanly or the user resolved it by hand
  ## and ran `--continue`.
  let msg = repo.finalMessage(msg0, useEditor, signoff)
  let head = repo.refs.resolveRef(headRef)
  repo.summarizeCommit(
    repo.commitOnHead(idx, @[head.oid], author, msg, reflog & subject(msg)),
    showDate = showDate)
  0

proc collect(repo: Repository, args: seq[string]): seq[Oid] =
  ## The commits to replay, in the order they will be replayed.
  ##
  ## A plain name is one commit, taken in the order written.  A range is a
  ## walk, and comes out **oldest first** -- `cherry-pick A..B` replays B's
  ## history forwards, because replaying it backwards would conflict with
  ## itself at every step.
  for a in args:
    if a.contains("..") or (a.len > 0 and a[0] == '^'):
      let w = newRevWalk(repo)
      var ri = initRevInput()
      w.addRevisionArg(ri, a)
      w.finishRevInput(ri, defaultHead = false)
      var walked: seq[Oid]
      for e in w.walk: walked.add e.oid
      for i in countdown(walked.high, 0): result.add walked[i]
    else:
      # git resolves these through `handle_revision_arg`, whose complaint is
      # about the *revision* rather than about the object it did not find.
      failIf(not repo.looksLikeRev(a), "bad revision '" & a & "'")
      result.add repo.resolveCommittish(a)

proc replay(c: Ctx, todo: seq[Oid], k: Kind, recordOrigin, noCommit, signoff,
            useEditor: bool, sequence = false): int =
  ## Apply each commit in turn, stopping at the first conflict.
  ##
  ## `sequence` says the `sequencer/` directory already exists -- either
  ## because this run has more than one commit to replay, or because it is a
  ## `--continue` of one that had.
  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  var seq0 = sequence or todo.len > 1
  if seq0 and not fileExists(repo.statePath(sequencerDir / "head")):
    repo.writeState(sequencerDir / "head",
                    $repo.refs.resolveRef(headRef).oid & "\n")

  for i, pick in todo:
    let cm = repo.readCommit(pick)
    failIf(cm.parents.len > 1,
           "commit " & $pick & " is a merge but no -m option was given.")
    let head = repo.refs.resolveRef(headRef)
    let parentTree = if cm.parents.len == 1:
                       repo.peelTo(cm.parents[0], otTree).oid
                     else: nullOid
    let label = repo.uniqueAbbrev(pick, repo.autoAbbrev) & " (" &
                subject(cm.message) & ")"
    # The whole difference between the two commands, in three lines.
    let baseTree = if k == pkCherry: parentTree else: cm.tree
    let theirTree = if k == pkCherry: cm.tree else: parentTree
    let theirLabel = if k == pkCherry: label else: "parent of " & label

    let msg = repo.pickMessage(k, cm, pick, recordOrigin)
    let res = repo.applyThreeWay(idx, baseTree, theirTree, theirLabel, k.verb)
    reportMerge(res)
    idx.writeIndex()

    if res.conflicts > 0 or noCommit:
      # Everything the next command needs: which commit stopped, the message
      # it was going to get, and -- if there are more -- what is left to do.
      # Which of the two head files exists afterwards is not symmetric, and
      # `sequencer.c:do_pick_commit` says why: `CHERRY_PICK_HEAD` exists for
      # the benefit of a later `commit`, so `-n` -- which has already decided
      # not to commit -- does not write it, while `REVERT_HEAD` is written
      # exactly under `-n`.  Both are written when the pick stopped.
      if res.conflicts > 0 or (k == pkRevert and noCommit):
        repo.writeState(k.headFile, $pick & "\n")
      repo.writeState("MERGE_MSG", msg & res.conflictComments)
      if seq0:
        repo.writeTodo(k, todo, i)
        repo.writeState(sequencerDir / "abort-safety", $head.oid & "\n")
      if res.conflicts == 0: return 0        # `-n`: applied, not committed
      repo.conflictAdvice(k, pick, subject(cm.message))
      return 1

    let author = if k == pkCherry: cm.author else: getIdent(repo.cfg, irAuthor)
    result = doCommit(repo, idx, msg, author, useEditor, signoff,
                      reflog = k.verb & ": ")
    if result != 0: return
  if seq0: repo.removeState(sequencerDir)

proc run(c: Ctx, argv: seq[string], k: Kind): int =
  let args = expandShortOptions(argv, {})
  var recordOrigin, noCommit, signoff, forceEdit, noEdit = false
  var cont, skip, quit0, abort = false
  var specs: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-': specs.add a
    elif a == "--": noMoreOpts = true
    elif a == "-x": recordOrigin = true
    elif a == "-n" or a == "--no-commit": noCommit = true
    elif a == "-s" or a == "--signoff": signoff = true
    elif a == "--no-signoff": signoff = false
    elif a == "-e" or a == "--edit": forceEdit = true
    elif a == "--no-edit": noEdit = true
    elif a == "--continue": cont = true
    elif a == "--skip": skip = true
    elif a == "--quit": quit0 = true
    elif a == "--abort": abort = true
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["-m", "--mainline", "-r", "--cleanup", "--ff", "--allow-empty",
               "--allow-empty-message", "--empty", "--keep-redundant-commits",
               "--strategy", "-X", "--strategy-option", "--reference",
               "--rerere-autoupdate", "--no-rerere-autoupdate", "-S",
               "--gpg-sign", "--no-gpg-sign"]:
      fail(a & " is out of scope for gittle v1 (docs/06)")
    else: fail("unknown option '" & a & "'\n" & usageText)
    inc i

  let repo = c.repo
  failIf(repo.workTree.len == 0,
         k.verb & " is not possible in a bare repository")
  let idx = readIndex(repo.indexPath)

  # ---- the four state verbs, none of which takes a commit
  if cont or skip or quit0 or abort:
    let wanted = if k == pkCherry: opCherryPick else: opRevert
    if quit0:
      # `--quit` never complains: forgetting an operation that is not running
      # has already achieved what it asked for.
      repo.removeState(sequencerDir, k.headFile, "MERGE_MSG", "AUTO_MERGE")
      return 0
    if repo.currentOp notin {opCherryPick, opRevert} and
       not dirExists(repo.statePath(sequencerDir)):
      # git's wording, and git's two lines: the `error:` says what is not
      # happening, the `fatal:` says which command gave up.
      stderr.write "error: no cherry-pick or revert in progress\n"
      fail(k.verb & " failed")
    if abort:
      # Where to go back to: the sequence's starting point if there was a
      # list, and HEAD itself if a single pick stopped before moving it.
      let start = repo.stateOid(sequencerDir / "head")
      let target = if start.isNull: repo.refs.resolveRef(headRef).oid else: start
      repo.writeState("ORIG_HEAD", $repo.refs.resolveRef(headRef).oid & "\n")
      repo.restoreTo(idx, target)
      repo.refs.updateRef(headRef, target, msg = "reset: moving to " & $target)
      repo.removeState(sequencerDir, k.headFile, "MERGE_MSG", "AUTO_MERGE")
      return 0

    let stopped = repo.stateOid(k.headFile)
    if cont:
      # "Committing", not "Cherry-picking": `--continue` concludes through
      # the same path `commit` does, and says so.
      for e in idx.entries:
        if e.stage != 0: repo.dieResolveConflict("commit", idx)
      failIf(stopped.isNull, "no " & k.verb & " in progress")
      let cm = repo.readCommit(stopped)
      let author = if k == pkCherry: cm.author else: getIdent(repo.cfg, irAuthor)
      # `--continue` concludes through the same code path `commit` uses, and
      # git's reflog and summary follow that: a cherry-pick is named because
      # `CHERRY_PICK_HEAD` is what makes it recognisable, and a revert is not.
      let rc = doCommit(repo, idx, cleanupMessage(repo.readState("MERGE_MSG"),
                                                  dropComments = true),
                        author, useEditor = false, signoff = false,
                        reflog = (if k == pkCherry: "commit (cherry-pick): "
                                  else: "commit: "),
                        showDate = k == pkCherry)
      if rc != 0: return rc
    repo.removeState(k.headFile, "MERGE_MSG", "AUTO_MERGE")

    # What is left, minus the entry just finished or skipped: the todo list
    # always begins with the commit that stopped.
    var rest: seq[Oid]
    for line in repo.readState(sequencerDir / "todo").splitLines:
      let f = line.splitWhitespace
      if f.len >= 2: rest.add repo.resolveCommittish(f[1])
    if rest.len > 0: rest = rest[1 .. ^1]
    if rest.len == 0:
      repo.removeState(sequencerDir)
      return 0
    return c.replay(rest, k, recordOrigin = false, noCommit = false,
                    signoff = false, useEditor = false, sequence = true)

  repo.refuseIfInProgress(idx, k.verb)
  failIf(specs.len == 0, "no commit specified\n" & usageText)
  # An editor by default for `revert` and never for `cherry-pick`, and only
  # when there is a terminal to open one on
  # (`builtin/revert.c` asks `isatty` for its default).
  let useEditor = forceEdit or
                  (k == pkRevert and not noEdit and isTty() and isatty(0) != 0)
  c.replay(repo.collect(specs), k, recordOrigin, noCommit, signoff, useEditor)

proc cmdCherryPick*(c: Ctx, argv: seq[string]): int = run(c, argv, pkCherry)
proc cmdRevert*(c: Ctx, argv: seq[string]): int = run(c, argv, pkRevert)
