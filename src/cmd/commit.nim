## `commit` -- record the staged content as a new commit.
##
## In scope (docs/06): `<pathspec>…`, `-a`, `-m`, `-F`, `-e`/`--no-edit`,
## `-s`/`--signoff`, `--author`, `--date`, `--amend`, `--allow-empty`,
## `-n`/`--no-verify`, `-q`, `--`.  `--verify` and `--no-signoff` were cut in
## the second minimisation pass (docs/minimize-2.md B4): they negate flags that
## are already off, so nothing but a script that had already said `-s` or `-n`
## could want them, and no such script exists in either tool-call log.
##
## ## The order of operations, and why it is that order
##
## 1. **`pre-commit`** runs first, before the message exists, so that a hook
##    which rejects the *content* never makes the user write a message.
## 2. The message is assembled from `-m`, `-F`, or the amended commit, written
##    to `$GIT_DIR/COMMIT_EDITMSG`, and the editor is opened if one is needed.
## 3. **`commit-msg`** runs on that file and may rewrite it.
## 4. The file is read back and cleaned up; an empty result aborts.
## 5. The tree is written, then the commit, then HEAD moves.
##
## Steps 2 to 4 go through a file even when no editor is involved, because
## that is what makes `commit-msg` able to edit the message at all.
##
## ## Which cleanup, and why it depends on the editor
##
## `sequencer.c:get_cleanup_mode`: with an editor the message is *stripped*,
## which removes comment lines, because the template put them there.  Without
## one only whitespace is cleaned, because a `-m` message that begins with `#`
## is a message that begins with `#`.  Getting this backwards silently deletes
## a user's first line, and the commit is already written by the time anyone
## looks.
##
## ## What phase 5 adds
##
## The summary line is here; the ` 1 file changed, 1 insertion(+)` and
## `create mode` lines under it are a diff, and arrive with the diff engine.
## `nothing to commit` is likewise reported without the `status` output git
## prints alongside it.

import std/os
import ../cli, ../commitobj, ../dir, ../hooks, ../ident, ../index,
       ../oid, ../pathspec, ../repository, ../sequencer, ../status,
       ../trees, ../util, ../worktree


const editTemplate = """
# Please enter the commit message for your changes.  Lines starting with '#'
# will be ignored, and an empty message aborts the commit.
"""

proc identFor(cfg: Config, role: IdentRole, override, dateOverride: string,
              fallback: Ident, haveFallback: bool): Ident =
  ## Resolve one side of the authorship.
  ##
  ## `--amend` keeps the original author unless the command line says
  ## otherwise -- that is the point of amending rather than recommitting, and
  ## it is why the fallback is threaded through rather than looked up again.
  result = if haveFallback: fallback else: getIdent(cfg, role)
  if override.len > 0:
    let o = parseIdentLine(override)
    failIf(o.email.len == 0, "malformed --author '" & override &
           "': it must look like A U Thor <author@example.com>")
    result.name = o.name
    result.email = o.email
    if o.when0 != 0:
      result.when0 = o.when0
      result.tzOffset = o.tzOffset
  if dateOverride.len > 0:
    let stamp = parseDate(dateOverride)
    result.when0 = stamp.when0
    result.tzOffset = stamp.tzOffset

proc stageOrRemove(repo: Repository, into: Index, path: string) =
  ## Stage the working-tree version of a path into `into`, or drop the
  ## entry when the file is gone.
  if not stageWorkingPath(repo, into, path): discard into.removePath(path)

proc partialCommit(repo: Repository, idx: Index, ps: Pathspec, headTree: Oid,
                   haveHead: bool): tuple[oid: Oid, index: Index,
                                          paths: seq[string]] =
  ## `gittle commit <pathspec>` commits *the working tree* for those paths and
  ## HEAD's content for everything else -- deliberately ignoring whatever else
  ## is staged.  So the tree is built from a scratch index seeded with HEAD,
  ## not from the real one, and that scratch index is what the hooks are shown.
  ##
  ## Only tracked paths can be named this way; git refuses an untracked one
  ## rather than quietly adding it, and refuses it *before* writing anything.
  for e in idx.entries:
    if e.stage == 0 and ps.matches(e.path): result.paths.add e.path
  let missed = ps.firstUnmatched(result.paths)
  failIf(missed.len > 0,
         "pathspec '" & missed & "' did not match any file(s) known to gittle")
  result.index = Index(version: 2)
  if haveHead: repo.readTreeInto(result.index, headTree)
  for path in result.paths: repo.stageOrRemove(result.index, path)
  result.oid = repo.writeTree(result.index)

proc reportNothingToCommit(repo: Repository, idx: Index): int =
  ## git prints the whole of `status` here, not a one-line refusal: the
  ## question the user is about to ask is "then what *is* changed?", and the
  ## answer is already computed (`builtin/commit.c:prepare_to_commit`).
  let st = computeStatus(repo, idx, parsePathspec(@[], repo.prefix), umNormal)
  stdout.write longStatus(st, umNormal,
    (if repo.cfg.getBool("status.relativePaths", true): repo.prefix else: ""))
  stdout.flushFile()
  1

proc prepareMessage(repo: Repository, messages: seq[string], op: Operation,
                    amended: string, signoff, useEditor: bool): string =
  ## Step 2: assemble the message and put it where `commit-msg` can rewrite it.
  ##
  ## The sources, in order: `-m`/`-F`, then the message the operation in
  ## progress already prepared (`MERGE_MSG`), then the commit being amended.
  ## Returns the *file*, not the text, because the hook runs on the file next
  ## and the caller reads it back afterwards.
  var msg = joinMessages(messages)
  if msg.len == 0 and op != opNone: msg = repo.readState("MERGE_MSG")
  if msg.len == 0: msg = amended
  if signoff:
    msg = appendSignoff(cleanupMessage(msg, dropComments = false),
                        getIdent(repo.cfg, irCommitter))
  result = repo.gitDir / "COMMIT_EDITMSG"
  writeFile(result, msg & (if useEditor: editTemplate else: ""))
  if useEditor: launchEditor(repo.cfg, result)

const
  synopsis = "[-a] [-m <msg>] [-F <file>] [--amend] [--author=<author>] [--date=<date>]\n[-s] [-q] [--allow-empty] [--no-verify] [-e|--no-edit] [--] [<pathspec>…]"
  options = [
    opt("-a|--all", help = "stage every tracked change first"),
    opt("-m|--message", okValue, arg = "<msg>", help = "the message; repeatable, paragraphs joined"),
    opt("-F|--file", okValue, arg = "<file>", help = "read the message from a file, `-` for stdin"),
    opt("--amend", help = "replace the tip commit"),
    opt("--allow-empty", help = "record a commit with no change"),
    opt("-s|--signoff", help = "add a Signed-off-by trailer"),
    opt("-q|--quiet", help = "print no summary"),
    opt("-n|--no-verify", help = "skip the pre-commit and commit-msg hooks"),
    opt("-e|--edit", help = "open the editor even when a message was given"),
    opt("--no-edit", help = "never open the editor"),
    opt("--author", okValue, arg = "<author>", help = "override the author, `A U Thor <a@b>`"),
    opt("--date", okValue, arg = "<date>", help = "override the author date"),
    opt("--verify|--no-signoff", okRefused,
        help = "nothing to negate: the hooks run and no trailer is added unless -n or -s says so"),
    opt("-p|--patch|-i|--include|-o|--only|-v|--verbose|--dry-run|--short|--porcelain|" &
        "-C|--reuse-message|--fixup|--squash|--cleanup|--reset-author", okRefused, help = "docs/06"),
  ]

proc cmdCommit*(c: Ctx, argv: seq[string]): int =
  ## Entry point: parse, build the tree to commit (the index, `-a`'s
  ## refresh of it, or a partial tree for named paths), take the message
  ## through the hooks and the editor, and write the commit.
  let o = parse(options, argv, "commit", synopsis)
  var messages: seq[string]
  for (k, v) in o.occurrences:        # -m and -F accumulate, in order
    if k == "message": messages.add v
    elif k == "file": messages.add(if v == "-": readAll(stdin)
                                   else: readWholeFile(v))
  let all = o.has "all"
  let amend = o.has "amend"
  let quiet = o.has "quiet"
  let noVerify = o.has "no-verify"
  let specs = o.args
  let repo = c.repo
  failIf(repo.workTree.len == 0,
         "cannot commit in a bare repository: there is no working tree")
  failIf(all and specs.len > 0, "paths with -a does not make sense: -a stages " &
         "every tracked change, naming paths commits those paths only")

  let idx = readIndex(repo.indexPath)
  for e in idx.entries:
    if e.stage != 0: repo.dieResolveConflict("commit", idx)

  let head = repo.refs.resolveRef(headRef)
  # A merge that stopped on a conflict is concluded here, and this is the only
  # thing that makes the result a merge commit: `MERGE_HEAD` names the other
  # parent, and `MERGE_MSG` is the message `merge` had already prepared.
  let op = repo.currentOp
  let extraParents = if op == opMerge: repo.mergeHeads else: @[]
  # A conflicted cherry-pick concluded here keeps the picked commit's author:
  # the commit being made *is* that commit, replayed
  # (`builtin/commit.c` reuses `CHERRY_PICK_HEAD` as its author-message).
  var pickedAuthor: Ident
  let havePicked = op == opCherryPick
  if havePicked:
    pickedAuthor = parseCommit(
      repo.readObject(repo.stateOid("CHERRY_PICK_HEAD")).data).author

  var parents: seq[Oid]
  var oldCommit: Commit
  var haveOld = false
  if amend:
    # Amending would replace the commit HEAD names, and the operation in
    # progress is *about* to make a new one on top of it -- so there is no
    # sensible thing for the two to mean together.
    failIf(op != opNone,
           "You are in the middle of a " & op.opName & " -- cannot amend.")
    failIf(not head.found, "you have nothing to amend")
    oldCommit = parseCommit(repo.readObject(head.oid).data)
    haveOld = true
    parents = oldCommit.parents
  elif head.found:
    parents = @[head.oid] & extraParents

  # `-a` is `add`'s index pass over the whole tree (worktree.nim), in place.
  var indexDirty = all and repo.restageTracked(idx, idx, parsePathspec(@[]))

  let ps = parsePathspec(specs, repo.prefix)
  var treeOid: Oid
  var partialPaths: seq[string]
  # The index the commit is actually made from, which the hooks must see.  It
  # is the real one unless a pathspec sent us through a scratch index.
  var effective = idx
  if specs.len > 0:
    let headTree = if haveOld: oldCommit.tree
                   elif head.found: parseCommit(repo.readObject(head.oid).data).tree
                   else: nullOid
    let partial = partialCommit(repo, idx, ps, headTree, head.found)
    (treeOid, effective, partialPaths) = partial
  else:
    treeOid = repo.writeTree(idx)

  # Nothing to commit: the tree we would record is the one the parent already
  # has.  `--amend` is exempt, because amending the message alone is the
  # commonest use of it.
  # A merge whose result happens to equal the first parent's tree is still a
  # merge worth recording -- the second parent is the point of it -- so the
  # empty check is skipped there as it is for `--amend`.
  if not o.has("allow-empty") and not amend and extraParents.len == 0:
    let parentTree = if parents.len == 1:
                       parseCommit(repo.readObject(parents[0]).data).tree
                     else: nullOid
    if (parents.len == 1 and parentTree == treeOid) or
       (parents.len == 0 and repo.readObject(treeOid).data.len == 0):
      return reportNothingToCommit(repo, idx)

  # The hooks are shown the index that is being committed.  Under `-a` or a
  # pathspec that is not the file on disk, so it is written out beside it and
  # removed afterwards -- git does the same with `next-index-<pid>`.
  var hookIndex = repo.indexPath
  if all or specs.len > 0:
    hookIndex = repo.gitDir / ("next-index-" & $getCurrentProcessId())
    writeFile(hookIndex, serializeIndex(effective))
  defer:
    if hookIndex != repo.indexPath: discard tryRemoveFile(hookIndex)

  # 1. pre-commit, before a message exists.
  if not noVerify:
    let rc = runHook(repo.cfg, repo.gitDir, hookIndex, "pre-commit")
    if rc != 0: return rc

  # 2. the message.
  let useEditor = (messages.len == 0 and not o.has("no-edit")) or o.has("edit")
  let msgFile = prepareMessage(repo, messages, op,
                               (if haveOld: oldCommit.message else: ""),
                               o.has("signoff"), useEditor)

  # 3. commit-msg, which may rewrite the file.
  if not noVerify:
    let rc = runHook(repo.cfg, repo.gitDir, hookIndex, "commit-msg", msgFile)
    if rc != 0: return rc

  # 4. read back and clean up.
  let msg = cleanupMessage(readWholeFile(msgFile), dropComments = useEditor)
  failIf(msg.len == 0, "Aborting commit due to empty commit message.")

  # 5. the commit, then the ref.
  let author = identFor(repo.cfg, irAuthor, o.val "author", o.val "date",
                        (if haveOld: oldCommit.author else: pickedAuthor),
                        haveOld or havePicked)
  let newOid = repo.writeObject(otCommit,
    buildCommit(treeOid, parents, author, getIdent(repo.cfg, irCommitter), msg))

  # git names the operation in the reflog only for the two it recognises as
  # "in progress" -- a revert concluded by hand records a plain `commit:`.
  let what = if amend: "commit (amend): "
             elif parents.len == 0: "commit (initial): "
             elif extraParents.len > 0: "commit (merge): "
             elif havePicked: "commit (cherry-pick): "
             else: "commit: "
  repo.refs.updateRef(headRef, newOid,
                      oldOid = (if head.found: head.oid else: nullOid),
                      checkOld = true, msg = what & subject(msg))
  # The operation is over the moment its commit exists; leaving the markers
  # would make the *next* `commit` record two parents again.
  repo.removeState("MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "AUTO_MERGE",
                   "CHERRY_PICK_HEAD", "REVERT_HEAD")

  # A partial commit stages what it committed.  git does this *after* the
  # commit succeeds, and so does gittle: an index updated for a commit that
  # then failed on an empty message would leave the user's staging area
  # silently rearranged.
  for path in partialPaths:
    repo.stageOrRemove(idx, path)
    indexDirty = true
  if indexDirty: idx.writeIndex()

  # The `[main abc1234] subject` line and the counts under it, which
  # `cherry-pick`, `rebase --continue` and `merge --continue` all print too:
  # one renderer, in sequencer.nim.  A commit made on a detached HEAD or with
  # an author who is not the committer says so, and an amended or replayed
  # commit prints its date because that date is *not* this moment
  # (`builtin/commit.c:author_date_is_interesting`).
  if not quiet:
    repo.summarizeCommit(newOid, rootCommit = parents.len == 0,
                         showDate = amend or havePicked)
  0
