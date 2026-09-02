## `commit` -- record the staged content as a new commit.
##
## In scope (docs/06): `<pathspec>…`, `-a`, `-m`, `-F`, `-e`/`--no-edit`,
## `-s`/`--signoff`, `--author`, `--date`, `--amend`, `--allow-empty`,
## `-n`/`--no-verify`, `-q`, `--`.
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

import std/[os, strutils]
import ../cli, ../commitobj, ../diffcore, ../dir, ../hooks, ../ident, ../index,
       ../oid, ../pathspec, ../pretty, ../repository, ../sequencer, ../status,
       ../trees, ../util

const usageText = """usage: gittle commit [-a] [-m <msg>] [-F <file>] [--amend]
                     [--author=<author>] [--date=<date>] [-s] [-q]
                     [--allow-empty] [--no-verify] [-e|--no-edit]
                     [--] [<pathspec>…]"""

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
    failIf(o.email.len == 0,
           "malformed --author '" & override & "'\n" &
           "  it must look like: A U Thor <author@example.com>")
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
  if not stageWorkingPath(repo, into, path): discard into.removePath(path)

proc partialTree(repo: Repository, idx: Index, paths: seq[string],
                 headTree: Oid, haveHead: bool): tuple[oid: Oid, index: Index] =
  ## `gittle commit <pathspec>` commits *the working tree* for those paths and
  ## HEAD's content for everything else -- deliberately ignoring whatever else
  ## is staged.  So the tree is built from a scratch index seeded with HEAD,
  ## not from the real one.
  ##
  ## Only tracked paths can be named this way; git refuses an untracked one
  ## rather than quietly adding it, and so does the caller.
  result.index = Index(version: 2)
  if haveHead: repo.readTreeInto(result.index, headTree)
  for path in paths: repo.stageOrRemove(result.index, path)
  result.oid = repo.writeTree(result.index)

proc cmdCommit*(c: Ctx, argv: seq[string]): int =
  let args = expandShortOptions(argv, {'m', 'F'})
  var messages: seq[string]
  var all = false
  var amend = false
  var allowEmpty = false
  var signoff = false
  var quiet = false
  var noVerify = false
  var forceEdit = false
  var noEdit = false
  var authorOpt, dateOpt: string
  var specs: seq[string]
  var i = 0
  var noMoreOpts = false

  proc valueFor(a: string, dflt = ""): string =
    ## As `optionValue`, plus the stuck short spelling: `commit -mfoo` is one
    ## argument, and `-m` is the only option here that takes a value at all.
    if a.len > 2 and a[0] == '-' and a[1] != '-': return a[2 .. ^1]
    let eq = a.find('=')
    if eq > 0 and a.startsWith("--"): return a[eq + 1 .. ^1]
    inc i
    failIf(i >= args.len, "option '" & a & "' requires a value")
    args[i]

  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-':
      specs.add a
    elif a == "--": noMoreOpts = true
    elif a == "-a" or a == "--all": all = true
    elif a == "--amend": amend = true
    elif a == "--allow-empty": allowEmpty = true
    elif a == "-s" or a == "--signoff": signoff = true
    elif a == "--no-signoff": signoff = false
    elif a == "-q" or a == "--quiet": quiet = true
    elif a == "-n" or a == "--no-verify": noVerify = true
    elif a == "--verify": noVerify = false
    elif a == "-e" or a == "--edit": forceEdit = true
    elif a == "--no-edit": noEdit = true
    elif a == "-m" or a.startsWith("--message"): messages.add valueFor(a)
    elif a == "-F" or a.startsWith("--file"):
      let f = valueFor(a)
      messages.add(if f == "-": readAll(stdin) else: readWholeFile(f))
    elif a.startsWith("--author"): authorOpt = valueFor(a)
    elif a.startsWith("--date"): dateOpt = valueFor(a)
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["-p", "--patch", "-i", "--include", "-o", "--only", "-v",
               "--verbose", "--dry-run", "--short", "--porcelain", "-C",
               "--reuse-message", "--fixup", "--squash", "--cleanup",
               "--reset-author"]:
      fail(a & " is out of scope for gittle v1 (docs/06)")
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  let repo = c.repo
  failIf(repo.workTree.len == 0,
         "cannot commit in a bare repository: there is no working tree")
  failIf(all and specs.len > 0,
         "paths with -a does not make sense\n" &
         "  -a stages every tracked change; naming paths commits those " &
         "paths only")

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
  var havePicked = false
  if op == opCherryPick:
    pickedAuthor = parseCommit(
      repo.readObject(repo.stateOid("CHERRY_PICK_HEAD")).data).author
    havePicked = true

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

  # `-a` is the index pass of `add` over the whole tree: every tracked path is
  # restaged, and one whose file has gone is removed.  Untracked files are not
  # touched, which is the entire difference between `commit -a` and `add -A`.
  var indexDirty = false
  if all:
    var tracked: seq[string]
    for e in idx.entries: tracked.add e.path
    for path in tracked:
      let before = idx.entries[idx.find(path)].oid
      if not stageWorkingPath(repo, idx, path):
        discard idx.removePath(path)
        indexDirty = true
      elif idx.entries[idx.find(path)].oid != before:
        indexDirty = true

  let ps = parsePathspec(specs, repo.prefix)
  var treeOid: Oid
  var partialPaths: seq[string]
  # The index the commit is actually made from, which the hooks must see.  It
  # is the real one unless a pathspec sent us through a scratch index.
  var effective = idx
  if specs.len > 0:
    for e in idx.entries:
      if e.stage == 0 and ps.matches(e.path): partialPaths.add e.path
    # Only a tracked path can be committed this way; naming an untracked one is
    # a mistake rather than a request to add it.
    let missed = ps.firstUnmatched(partialPaths)
    failIf(missed.len > 0,
           "pathspec '" & missed & "' did not match any file(s) known to gittle")
    let headTree = if haveOld: oldCommit.tree
                   elif head.found: parseCommit(repo.readObject(head.oid).data).tree
                   else: nullOid
    let partial = partialTree(repo, idx, partialPaths, headTree, head.found)
    treeOid = partial.oid
    effective = partial.index
  else:
    treeOid = repo.writeTree(idx)

  # Nothing to commit: the tree we would record is the one the parent already
  # has.  `--amend` is exempt, because amending the message alone is the
  # commonest use of it.
  # A merge whose result happens to equal the first parent's tree is still a
  # merge worth recording -- the second parent is the point of it -- so the
  # empty check is skipped there as it is for `--amend`.
  if not allowEmpty and not amend and extraParents.len == 0:
    let parentTree = if parents.len == 1:
                       parseCommit(repo.readObject(parents[0]).data).tree
                     else: nullOid
    # git prints the whole of `status` here, not a one-line refusal: the
    # question the user is about to ask is "then what *is* changed?", and the
    # answer is already computed (`builtin/commit.c:prepare_to_commit`).
    if (parents.len == 1 and parentTree == treeOid) or
       (parents.len == 0 and repo.readObject(treeOid).data.len == 0):
      let st = computeStatus(repo, idx, parsePathspec(@[], repo.prefix), umNormal)
      stdout.write longStatus(st, umNormal,
                              repo.cfg.getBool("advice.statusHints", true),
                              (if repo.cfg.getBool("status.relativePaths", true):
                                 repo.prefix else: ""))
      stdout.flushFile()
      return 1

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
  var msg = joinMessages(messages)
  let useEditor = (messages.len == 0 and not noEdit) or forceEdit
  if msg.len == 0 and op != opNone: msg = repo.readState("MERGE_MSG")
  if msg.len == 0 and haveOld: msg = oldCommit.message
  if signoff:
    msg = appendSignoff(cleanupMessage(msg, dropComments = false),
                        getIdent(repo.cfg, irCommitter))

  let msgFile = repo.gitDir / "COMMIT_EDITMSG"
  writeFile(msgFile, msg & (if useEditor: editTemplate else: ""))
  if useEditor: launchEditor(repo.cfg, msgFile)

  # 3. commit-msg, which may rewrite the file.
  if not noVerify:
    let rc = runHook(repo.cfg, repo.gitDir, hookIndex, "commit-msg", msgFile)
    if rc != 0: return rc

  # 4. read back and clean up.
  msg = cleanupMessage(readWholeFile(msgFile), dropComments = useEditor)
  failIf(msg.len == 0, "Aborting commit due to empty commit message.")

  # 5. the commit, then the ref.
  let author = identFor(repo.cfg, irAuthor, authorOpt, dateOpt,
                        (if haveOld: oldCommit.author else: pickedAuthor),
                        haveOld or havePicked)
  let committer = getIdent(repo.cfg, irCommitter)
  let newOid = repo.writeObject(otCommit,
                                buildCommit(treeOid, parents, author, committer, msg))

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

  if not quiet:
    let hr = repo.refs.readRef(headRef)
    let branch = if hr.found and hr.isSymbolic: shortenRefname(hr.symTarget)
                 else: "detached HEAD"
    var line = "[" & branch & (if parents.len == 0: " (root-commit)" else: "") &
               " " & repo.uniqueAbbrev(newOid, repo.autoAbbrev) & "] " &
               subject(msg)
    if author.name != committer.name or author.email != committer.email:
      line.add "\n Author: " & author.name & " <" & author.email & ">"
    # The date is worth printing exactly when it is not this moment: an
    # amended commit keeps its original one, and a cherry-pick concluded here
    # keeps the picked commit's (`builtin/commit.c:author_date_is_interesting`).
    if amend or havePicked:
      line.add "\n Date: " &
               formatDate(author.when0, author.tzOffset, DateMode(kind: dkDefault),
                          author.when0)
    echo line
    # The counts and the creations, deletions and mode changes: what changed
    # structurally, which the subject line does not say.  A merge commit gets
    # none of it: the summary is a diff against the first parent, and git's
    # default for a merge is to show no diff at all (`log_tree_commit` with
    # `diff-merges` off), so there is nothing to count.
    if parents.len < 2:
      let parentTree = if parents.len == 1:
                         parseCommit(repo.readObject(parents[0]).data).tree
                       else: nullOid
      stdout.write commitSummary(repo,
        pairsTreeTree(repo, parentTree, treeOid, parsePathspec(@[], "")))
      stdout.flushFile()
  0
