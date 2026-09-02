## The in-progress operation, on disk.
##
## A conflicted merge is not a state in a running program -- the program has
## exited.  It is a set of files in `$GIT_DIR`, and every command that can stop
## in the middle writes them so that the *next* command can pick up where it
## left off.  `status` reads them to say what you are in the middle of,
## `commit` reads them to learn the second parent, and `--continue` and
## `--abort` are nothing but "read them and finish" and "read them and undo".
##
## | file | written by | says |
## |---|---|---|
## | `MERGE_HEAD` | `merge` | the other parent, one object ID per line |
## | `MERGE_MSG` | all of them | the prepared message, with the conflicted paths listed as comments |
## | `MERGE_MODE` | `merge` | empty, or `no-ff` |
## | `ORIG_HEAD` | all of them | where HEAD was before, for `--abort` and for `@{1}`-style rescue |
## | `CHERRY_PICK_HEAD` | `cherry-pick` | the commit being replayed |
## | `REVERT_HEAD` | `revert` | the commit being undone |
## | `sequencer/todo` | `cherry-pick`, `revert` | the commits not yet replayed |
## | `sequencer/head` | `cherry-pick`, `revert` | HEAD before the first one |
## | `rebase-merge/…` | `rebase` | the same, plus the branch being moved |
##
## These names are git's, and the contents are git's, because the point of a
## repository being a git repository is that either tool can pick it up.  A
## `gittle merge` that stops on a conflict is concluded by `git commit`, and a
## `git cherry-pick` that stops is continued by `gittle cherry-pick
## --continue`.
##
## ## What is deliberately not written
##
## `AUTO_MERGE` -- the tree of the conflicted result, which git records so that
## `--remerge-diff` and `checkout --merge` can reconstruct the conflict later.
## Both are cut (docs/03, docs/06), so nothing would read it.
##
## `sequencer/opts`, and `rebase-merge`'s `gpg_sign_opt`, `strategy` and
## `strategy_opts` -- every option they record is out of scope, so an empty
## file is all they could say.

import std/[os, strutils]
import commitobj, diffcore, hooks, ident, index, mergetree, objects, oid,
       pathspec, pretty, refs, repository, trees, util, worktree

type
  Operation* = enum
    ## What the repository is in the middle of.  At most one of these is true
    ## at a time; git enforces that by refusing to start a second.
    opNone, opMerge, opCherryPick, opRevert, opRebase

const
  rebaseDir* = "rebase-merge"
  sequencerDir* = "sequencer"

proc statePath*(repo: Repository, name: string): string =
  repo.gitDir / name

proc readState*(repo: Repository, name: string): string =
  ## The contents of a state file, or the empty string when there is none.
  ## Absence is the normal case and not an error, which is why this is not
  ## `readWholeFile`.
  let p = repo.statePath(name)
  if fileExists(p): readFile(p) else: ""

proc writeState*(repo: Repository, name, data: string) =
  createDir(parentDir(repo.statePath(name)))
  writeFile(repo.statePath(name), data)

proc removeState*(repo: Repository, names: varargs[string]) =
  for n in names:
    let p = repo.statePath(n)
    if dirExists(p): removeDir(p)
    else: discard tryRemoveFile(p)

proc stateOid*(repo: Repository, name: string): Oid =
  ## A state file holding a single object ID, or the null ID.
  let s = repo.readState(name).strip()
  if s.len == OidHexLen: parseOid(s) else: nullOid

proc mergeHeads*(repo: Repository): seq[Oid] =
  ## `MERGE_HEAD` is a *list*: an octopus merge has several other parents.
  ## gittle never writes more than one (docs/05 cuts the octopus strategy) but
  ## it can be asked to conclude a merge git started.
  for line in repo.readState("MERGE_HEAD").splitLines:
    let s = line.strip()
    if s.len == OidHexLen: result.add parseOid(s)

proc currentOp*(repo: Repository): Operation =
  ## Which operation is in progress, tested in the order git tests it
  ## (`wt-status.c:wt_status_get_state`): the more specific markers first,
  ## because a cherry-pick that stopped on a conflict has `MERGE_MSG` too.
  if dirExists(repo.statePath(rebaseDir)): opRebase
  elif fileExists(repo.statePath("CHERRY_PICK_HEAD")): opCherryPick
  elif fileExists(repo.statePath("REVERT_HEAD")): opRevert
  elif fileExists(repo.statePath("MERGE_HEAD")): opMerge
  else: opNone

func opName*(op: Operation): string =
  case op
  of opNone: ""
  of opMerge: "merge"
  of opCherryPick: "cherry-pick"
  of opRevert: "revert"
  of opRebase: "rebase"

proc dieResolveConflict*(repo: Repository, me: string, idx: Index = nil) =
  ## `advice.c:die_resolve_conflict`: the refusal every command that would
  ## rewrite the index gives while conflicts are outstanding.
  ##
  ## `commit` passes its index, because it refreshes the index first and the
  ## refresh reports every unmerged path as `U <path>` on *standard output*
  ## (`read-cache.c:refresh_index`, in porcelain mode).  Standard output is
  ## deliberately left unflushed, so that a caller redirecting both streams
  ## into one sees the error first, exactly as it does from git.
  const verbs = [("commit", "Committing"), ("merge", "Merging"),
                 ("cherry-pick", "Cherry-picking"), ("revert", "Reverting"),
                 ("rebase", "Rebasing"), ("pull", "Pulling")]
  if idx != nil:
    var last = ""
    for e in idx.entries:
      if e.stage != 0 and e.path != last:
        last = e.path
        # `write`, not `echo`: echo flushes, and the point of the ordering is
        # that these lines stay in the buffer until exit.
        stdout.write "U\t" & e.path & "\n"
  var what = me
  for (name, gerund) in verbs:
    if name == me: what = gerund
  stderr.write "error: " & what &
               " is not possible because you have unmerged files.\n"
  if repo.cfg.getBool("advice.resolveConflict", true):
    stderr.write "hint: Fix them up in the work tree, and then use " &
                 "'gittle add/rm <file>'\nhint: as appropriate to mark " &
                 "resolution and make a commit.\n"
  fail("Exiting because of an unresolved conflict.")

proc refuseIfInProgress*(repo: Repository, idx: Index, verb: string) =
  ## git's rule: one operation at a time, and the message names the file that
  ## proves it -- because deleting that file is the escape hatch when the
  ## state is genuinely stale.
  ##
  ## Outstanding conflicts are reported first and differently: there the
  ## advice is `add/rm`, and here it is `commit`, because the merge is already
  ## resolved and only unconcluded (`builtin/merge.c` says so in a comment).
  for e in idx.entries:
    if e.stage != 0: repo.dieResolveConflict(verb)
  const marker = [opNone: "", opMerge: "MERGE_HEAD",
                  opCherryPick: "CHERRY_PICK_HEAD", opRevert: "REVERT_HEAD",
                  opRebase: "rebase-merge"]
  let op = repo.currentOp
  if op == opNone: return
  var msg = "You have not concluded your " & op.opName & " (" & marker[op] &
            " exists)."
  if repo.cfg.getBool("advice.resolveConflict", true):
    msg.add "\nPlease, commit your changes before you " & verb & "."
  fail(msg)

# ---------------------------------------------------------------------------
# The message
# ---------------------------------------------------------------------------

proc conflictComments*(res: MergeResult): string =
  ## The block git appends to `MERGE_MSG` when a merge stops:
  ##
  ##     # Conflicts:
  ##     #	one/path
  ##
  ## It is a comment, so `commit` strips it unless the user leaves it, and it
  ## exists so that the editor shows what still needs resolving.
  var paths: seq[string]
  for m in res.paths:
    if not m.clean: paths.add m.path
  if paths.len == 0: return
  result = "\n" & commentChar & " Conflicts:\n"
  for p in paths: result.add commentChar & "\t" & p & "\n"

# ---------------------------------------------------------------------------
# Running one merge into the working tree
# ---------------------------------------------------------------------------

proc mergeIntoWorkTree*(repo: Repository, idx: Index, base, ours, theirs: TreeMap,
                        opts: MergeOpts, verb: string): MergeResult =
  ## Merge three trees, refuse if it would destroy work, and apply it.
  ##
  ## The refusal is the same two-way check `checkout` uses, asked between
  ## *ours* and the merge result: a path the merge does not change cannot be
  ## overwritten, and a path it does change must be one the user has not
  ## edited.  It happens before the first write, so a refused merge leaves the
  ## working tree exactly as it was.
  result = repo.mergeTrees(base, ours, theirs, opts)
  let plan = repo.planTwoWay(idx, ours, result.resultTreeMap, force = false)
  if plan.refused(verb):
    # git's status here is 2, not 1: the strategy was asked and could not run,
    # which it distinguishes from a merge that ran and conflicted.
    stderr.write "Merge with strategy ort failed.\n"
    exitWith(2)
  repo.applyMerge(idx, result)

proc applyThreeWay*(repo: Repository, idx: Index, baseTree, theirTree: Oid,
                    labelTheirs, verb: string): MergeResult =
  ## Replay one change on top of HEAD: merge `baseTree -> theirTree` into the
  ## tree HEAD names.  A pick, a revert and a rebase step are all this; they
  ## differ only in which two trees they hand it, and in what they do with the
  ## result afterwards.
  let head = repo.refs.resolveRef(headRef)
  repo.mergeIntoWorkTree(idx, repo.flatten(baseTree),
                         repo.flatten(repo.peelTo(head.oid, otTree).oid),
                         repo.flatten(theirTree),
                         MergeOpts(labelOurs: "HEAD", labelTheirs: labelTheirs),
                         verb)

proc reportMerge*(res: MergeResult) =
  ## Everything the merge decided, in path order, which is the order git
  ## prints it in (`merge-ort.c:merge_display_update_messages`).
  for m in res.paths:
    for msg in m.messages: echo msg

# ---------------------------------------------------------------------------
# Making the commit
# ---------------------------------------------------------------------------

proc finalMessage*(repo: Repository, msg0: string, useEditor, signoff: bool,
                   tmpl = ""): string =
  ## The message a replayed commit will actually carry.
  ##
  ## Always through `COMMIT_EDITMSG`, even with no editor: that file is the
  ## interface the editor and the `commit-msg` hook share, and going through
  ## it in both cases is what keeps the two paths from diverging.  `tmpl` is
  ## the commented explanation an editor is shown and a `-m` message is not.
  var msg = msg0
  if signoff:
    msg = appendSignoff(cleanupMessage(msg, dropComments = false),
                        getIdent(repo.cfg, irCommitter))
  let msgFile = repo.gitDir / "COMMIT_EDITMSG"
  writeFile(msgFile, msg & (if useEditor: tmpl else: ""))
  if useEditor: launchEditor(repo.cfg, msgFile)
  result = cleanupMessage(readWholeFile(msgFile), dropComments = true)
  failIf(result.len == 0, "Aborting commit due to empty commit message.")

proc commitOnHead*(repo: Repository, idx: Index, parents: seq[Oid],
                   author: Ident, msg, reflog: string): Oid =
  ## Write the index out as a tree, commit it, and move HEAD.
  ##
  ## Every command in this phase ends here: a merge, a pick, a revert and a
  ## rebase step differ in what they put in `parents`, `author` and `msg`, and
  ## in nothing else.
  let newOid = repo.writeObject(otCommit,
    buildCommit(repo.writeTree(idx), parents, author,
                getIdent(repo.cfg, irCommitter), msg))
  repo.refs.updateRef(headRef, newOid, oldOid = parents[0], checkOld = true,
                      msg = reflog)
  idx.writeIndex()
  newOid

# ---------------------------------------------------------------------------
# Reporting a commit
# ---------------------------------------------------------------------------

proc summarizeCommit*(repo: Repository, newOid: Oid, rootCommit = false,
                      showDate = false) =
  ## `[main abc1234] the subject`, and the three things that can follow it.
  ##
  ## `sequencer.c:print_commit_summary`.  The `Author:` line appears only when
  ## the author is not the committer -- which is the normal case for a
  ## cherry-pick, and the reason it is worth printing.  The statistics are a
  ## diff against the first parent, so a merge commit gets none: git's default
  ## for a merge is to show no diff at all.
  let c = parseCommit(repo.readObject(newOid).data)
  let hr = repo.refs.readRef(headRef)
  let branch = if hr.found and hr.isSymbolic: shortenRefname(hr.symTarget)
               else: "detached HEAD"
  var line = "[" & branch & (if rootCommit: " (root-commit)" else: "") & " " &
             repo.uniqueAbbrev(newOid, repo.autoAbbrev) & "] " &
             subject(c.message)
  if c.author.name != c.committer.name or c.author.email != c.committer.email:
    line.add "\n Author: " & c.author.name & " <" & c.author.email & ">"
  if showDate:
    line.add "\n Date: " & formatDate(c.author.when0, c.author.tzOffset,
                                      DateMode(kind: dkDefault), c.author.when0)
  echo line
  if c.parents.len >= 2: return
  let parentTree = if c.parents.len == 1:
                     parseCommit(repo.readObject(c.parents[0]).data).tree
                   else: nullOid
  stdout.write repo.commitSummary(
    pairsTreeTree(repo, parentTree, c.tree, parsePathspec(@[])))
  stdout.flushFile()

# ---------------------------------------------------------------------------
# Undoing
# ---------------------------------------------------------------------------

proc restoreTo*(repo: Repository, idx: Index, commit: Oid) =
  ## What every `--abort` does: put HEAD's content back, whatever is in the
  ## way.  This is `reset --hard` without moving HEAD, and it is deliberately
  ## the forceful version -- the user asked to abandon the operation, and a
  ## half-merged working tree is not something to preserve.
  let tree = repo.flatten(repo.peelTo(commit, otTree).oid)
  repo.resetWorkTree(idx, tree)
  repo.resetIndexTo(idx, tree)
  discard repo.refreshIndex(idx)
  idx.writeIndex()
