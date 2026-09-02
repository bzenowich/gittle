## `stash` -- set aside uncommitted work and get a clean tree back.
##
## In scope (docs/08): `push` (the default), `list`, `pop`, `apply`, `drop`,
## `clear`, `<stash>`, `-u`/`--include-untracked`, `-m <message>`, `-q`, and a
## pathspec for `push`.  Cut: `show` (it is `diff stash@{0}^ stash@{0}`),
## `-k`/`--keep-index`, `save`, `branch`, `create`, `store`, `export`/`import`,
## `-p`, `-S`, `-a`, `--index`.
##
## ## A stash entry is a commit with two or three parents
##
##     w_commit   the working tree            "WIP on main: 1234567 subject"
##      |  |  \
##      |  |   u_commit   the untracked files (only with -u)
##      |  i_commit       the index at the time
##      HEAD
##
## Nothing else records the state: the *tree* of `w_commit` is the working
## tree, the tree of its second parent is the index, and its first parent says
## what all of that was relative to.  That is why `git stash show` is a plain
## diff between two trees, and why `git log --graph` shows a stash as a merge.
##
## ## The stack is a reflog
##
## `stash@{2}` is not a ref: it is `refs/stash`'s reflog entry 2.  The ref
## always names the newest entry, so pushing is an ordinary ref update and
## `drop` is the one operation that has to *rewrite* a reflog -- removing a
## line and re-chaining the old-value column, because every entry's old value
## is the previous entry's new one.
##
## ## Applying is a merge, not a checkout
##
## | | |
## |---|---|
## | base | the tree the stash was made against |
## | ours | the index as it is **now** |
## | theirs | the stashed working tree |
##
## So a stash can be applied onto a tree that has moved on, and conflicts if
## the same lines moved.  Afterwards the index is put back to what it was --
## `unstage_changes_unless_new` -- except for paths that did not exist in it
## before, which stay staged because there is nowhere else to put them.

import std/[os, strutils, tables]
import ../cli, ../commitobj, ../dir, ../ident, ../ignore,
       ../index, ../mergetree, ../objects, ../oid, ../pathspec, ../refs,
       ../repository, ../revision, ../revwalk, ../sequencer, ../status,
       ../trees, ../util, ../worktree


const stashRef = refsPrefix & "stash"

type Entry = object
  ## One stash, as its commit describes it.
  oid: Oid          ## the `w_commit`
  base: Oid         ## its first parent: what it was made against
  workTree: Oid     ## its tree
  indexTree: Oid    ## the second parent's tree
  untracked: Oid    ## the third parent's tree, or null
  message: string

proc readEntry(repo: Repository, oid: Oid): Entry =
  ## A stash commit taken apart: the base, the tree, the index tree and,
  ## with `-u`, the untracked tree.
  let c = repo.readCommit(oid)
  failIf(c.parents.len < 2, $oid & " is not a stash-like commit")
  result = Entry(oid: oid, base: c.parents[0], workTree: c.tree,
                 indexTree: repo.readCommit(c.parents[1]).tree,
                 message: c.message)
  if c.parents.len > 2:
    result.untracked = repo.readCommit(c.parents[2]).tree

proc resolveStash(repo: Repository, name: string): tuple[oid: Oid, idx: int] =
  ## `stash@{2}`, or the top of the stack.
  ##
  ## The reflog is stored oldest first and numbered newest first, so
  ## `stash@{0}` is the *last* line -- which is also why pushing is an append
  ## and every index shifts when one is dropped.
  let log = repo.refs.readReflog(stashRef)
  if log.len == 0:
    # An empty stack is a result, not a broken repository, so git's status
    # here is 1 rather than the 128 a fatal would give.
    stderr.write "No stash entries found.\n"
    exitWith(1)
  if name.len == 0: return (log[^1].newOid, 0)
  result.oid = repo.resolveRevish(name)
  result.idx = -1
  for i in countdown(log.high, 0):
    if log[i].newOid == result.oid: return (result.oid, log.high - i)

proc branchName(repo: Repository): string =
  ## The branch for the `WIP on <branch>` message, or `(no branch)`.
  const heads = refsPrefix & "heads/"
  let h = repo.headRefName
  if h.startsWith(heads): h[heads.len .. ^1] else: "(no branch)"

proc dropEntry(repo: Repository, idx: int) =
  ## Remove one reflog entry, re-chaining the ones below it.
  ##
  ## Every entry records the value the ref had *before* it, so deleting a line
  ## leaves the next one claiming a predecessor that no longer exists.  git
  ## rewrites the column (`reflog delete`), and the oldest entry always claims
  ## to have come from nothing.
  let log = repo.refs.readReflog(stashRef)
  var kept: seq[ReflogEntry]
  for i, e in log:
    if log.high - i != idx: kept.add e
  if kept.len == 0:
    repo.refs.deleteRef(stashRef)
    discard tryRemoveFile(repo.refs.reflogPath(stashRef))
    return
  # The ref moves first, with its log removed, so that the update appends
  # nothing: the rewritten log below is the whole truth about the stack, and
  # an entry recording the drop itself would become `stash@{0}`.
  discard tryRemoveFile(repo.refs.reflogPath(stashRef))
  repo.refs.updateRef(stashRef, kept[^1].newOid)
  var text = ""
  for i, e in kept:
    let prev = if i == 0: nullOid else: kept[i - 1].newOid
    text.add $prev & " " & $e.newOid & " " & e.who & "\t" & e.message & "\n"
  writeFile(repo.refs.reflogPath(stashRef), text)

proc untrackedTree(repo: Repository, idx: Index, ps: Pathspec): tuple[oid: Oid,
                   paths: seq[string]] =
  ## A tree of everything the working tree has that the index does not.  Its
  ## own commit, with no parent: it is not a version of the project, it is a
  ## bag of files to put back.
  let ig = newIgnore(repo)
  let found = walkWorkTree(repo, idx, ig, ps)
  if found.len == 0: return
  let scratch = Index(version: 2)
  for path in found:
    if path.endsWith("/"): continue     # a nested repository, not a file
    if stageWorkingPath(repo, scratch, path): result.paths.add path
  if result.paths.len == 0: return
  result.oid = repo.writeTree(scratch)

proc workTree(repo: Repository, idx: Index, ps: Pathspec): tuple[oid: Oid,
              dirty: bool] =
  ## The working tree as a tree object: the index with every tracked file's
  ## current content stood in for it.  A path the pathspec does not reach
  ## keeps its indexed content, which is what makes `stash push <path>` a
  ## partial stash.
  let scratch = Index(version: 2)
  for e in idx.entries:
    if e.stage != 0: continue
    scratch.addEntry e
  for e in idx.entries:
    if e.stage != 0 or not ps.matches(e.path): continue
    let before = e.oid
    if not stageWorkingPath(repo, scratch, e.path):
      discard scratch.removePath(e.path)
      result.dirty = true
    elif scratch.entries[scratch.find(e.path)].oid != before:
      result.dirty = true
  result.oid = repo.writeTree(scratch)

proc doPush(c: Ctx, message: string, includeUntracked, quiet: bool,
            specs: seq[string]): int =
  ## `stash push`: snapshot the index and the working tree (and the
  ## untracked files) as commits, record them in the reflog, then reset
  ## the tree to HEAD.
  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  for e in idx.entries:
    failIf(e.stage != 0, "cannot save the current index state")
  let head = repo.refs.resolveRef(headRef)
  failIf(not head.found,
         "You do not have the initial commit yet")
  let ps = parsePathspec(specs, repo.prefix)

  let headTree = repo.peelTo(head.oid, otTree).oid
  let indexTree = repo.writeTree(idx)
  let work = repo.workTree(idx, ps)
  let untracked = if includeUntracked: repo.untrackedTree(idx, ps)
                  else: (nullOid, newSeq[string]())
  if indexTree == headTree and not work.dirty and untracked.oid.isNull:
    if not quiet: echo "No local changes to save"
    return 0

  let author = getIdent(repo.cfg, irAuthor)
  let committer = getIdent(repo.cfg, irCommitter)
  let branch = repo.branchName
  let headLine = repo.uniqueAbbrev(head.oid, repo.autoAbbrev) & " " &
                 subject(repo.readCommit(head.oid).message)

  # The two auxiliary commits' messages end in a newline and the stash's own
  # does not.  That is not tidiness: an object ID is the hash of exact bytes
  # (R1), and git writes these two with a trailing newline and the third
  # without one.
  var parents = @[head.oid,
                  repo.writeObject(otCommit, buildCommit(indexTree, @[head.oid],
                    author, committer,
                    "index on " & branch & ": " & headLine & "\n"))]
  if not untracked.oid.isNull:
    parents.add repo.writeObject(otCommit, buildCommit(untracked.oid, @[],
      author, committer,
      "untracked files on " & branch & ": " & headLine & "\n"))

  # No trailing newline: git builds this message with `strbuf_addf` and does
  # not complete the line, so the commit object's body is exactly one line
  # with no terminator.  Adding one would change the object ID (R1).
  let msg = if message.len > 0: "On " & branch & ": " & message
            else: "WIP on " & branch & ": " & headLine
  let w = repo.writeObject(otCommit,
    buildCommit(work.oid, parents, author, committer, msg))
  repo.refs.updateRef(stashRef, w, msg = msg, forceLog = true)

  # Now put the working tree back.  Untracked files stashed with `-u` are
  # removed here and nowhere else -- they are not tracked, so no tree update
  # would take them away.
  for path in untracked.paths: discard tryRemoveFile(repo.workTreePath(path))
  let headMap = repo.flatten(headTree)
  if specs.len > 0:
    # A pathspec restores only what it names, and leaves everything else --
    # staged or not -- exactly as it is.  git spells this as `add` followed by
    # a reversed `apply --cached`; the effect is that the named paths go back
    # to what HEAD has and nothing else is touched.
    var paths: seq[string]
    for e in idx.entries:
      if e.stage == 0 and ps.matches(e.path): paths.add e.path
    for path in headMap.keys:
      if ps.matches(path) and idx.find(path) < 0: paths.add path
    for path in paths:
      if headMap.hasKey(path):
        repo.writeWorkingPath(path, headMap[path])
        repo.applyToIndex(idx, path, headMap[path])
      else:
        repo.removeWorkingPath(path)
        discard idx.removePath(path)
  else:
    repo.resetWorkTree(idx, headMap)
    repo.resetIndexTo(idx, headMap)
    discard repo.refreshIndex(idx)
    # git puts the whole tree back by running a real `reset --hard`, which
    # leaves both of its traces even though HEAD does not move.
    repo.writeState("ORIG_HEAD", $head.oid & "\n")
    repo.refs.updateRef(headRef, head.oid, msg = "reset: moving to HEAD")
  idx.writeIndex()
  if not quiet: echo "Saved working directory and index state " & msg
  0

proc doApply(c: Ctx, name: string, drop, quiet: bool): int =
  ## `stash apply`/`pop`: the three-way merge the module comment
  ## describes, then restore the index, then drop the entry for `pop`.
  let repo = c.repo
  let idx = readIndex(repo.indexPath)
  for e in idx.entries:
    failIf(e.stage != 0, "cannot apply a stash in the middle of a merge")
  let (oid, pos) = repo.resolveStash(name)
  let st = repo.readEntry(oid)

  let ours = repo.writeTree(idx)
  # The label git uses for our side says which situation this is: a stash
  # applied where it was made is "the version it was based on", and one
  # applied somewhere else is "updated upstream".
  let opts = MergeOpts(labelOurs: (if st.base == ours: "Version stash was based on"
                                   else: "Updated upstream"),
                       labelTheirs: "Stashed changes")
  let res = repo.mergeIntoWorkTree(idx,
                                   repo.flatten(repo.peelTo(st.base, otTree).oid),
                                   repo.flatten(ours),
                                   repo.flatten(st.workTree), opts, "stash")
  reportMerge(res)

  if res.conflicts == 0:
    # Put the index back to what it was, except for paths it did not have:
    # a file the stash introduced has no unstaged version to fall back to
    # (`builtin/stash.c:unstage_changes_unless_new`).
    let before = repo.flatten(ours)
    for i in 0 ..< idx.entries.len:
      let path = idx.entries[i].path
      if not before.hasKey(path): continue
      # Back to the version the index held, and with **no stat data**: the
      # file on disk is the merge's now, not this entry's, and an entry whose
      # stat matched a file it no longer describes would make the next
      # `status` call the path unmodified (index.nim's racy-clean note).
      idx.entries[i] = IndexEntry(path: path, mode: before[path].mode,
                                  oid: before[path].oid,
                                  flags: idx.entries[i].flags,
                                  extFlags: idx.entries[i].extFlags)
  if not st.untracked.isNull:
    for path, v in repo.flatten(st.untracked):
      repo.writeWorkingPath(path, v)
  idx.writeIndex()

  if res.conflicts == 0 and drop and pos >= 0: repo.dropEntry(pos)
  if not quiet:
    # git reports the result by running `status`, conflict or not: what the
    # user needs next is the list of what has landed and what has not.
    let s = computeStatus(repo, readIndex(repo.indexPath),
                          parsePathspec(@[], repo.prefix), umNormal)
    stdout.write longStatus(s, umNormal, (if repo.cfg.getBool("status.relativePaths", true):
                               repo.prefix else: ""))
    stdout.flushFile()
  if res.conflicts > 0:
    # Not dropped: the entry is the only copy of the work that did not apply.
    if drop: echo "The stash entry is kept in case you need it again."
    return 1
  if drop and pos >= 0:
    echo "Dropped " & (if name.len > 0: name else: stashRef & "@{0}") &
         " (" & $oid & ")"
  0

const
  synopsis = "[push] [-u] [-q] [-m <message>] [--] [<pathspec>…]\nlist\n(pop|apply|drop) [<stash>]\nclear"
  options = [
    opt("-u|--include-untracked", help = "stash untracked files as well"),
    opt("--no-include-untracked"),
    opt("-q|--quiet", help = "say nothing"),
    opt("-m|--message", okValue, arg = "<message>", help = "the stash's description"),
    opt("-k|--keep-index|--no-keep-index", okRefused, help = "docs/minimize.md §3.5"),
    opt("-p|--patch|-S|--staged|-a|--all|--only-untracked|--index|--label-ours|" &
        "--label-theirs|--label-base|--print|--to-ref|--pathspec-from-file|--pathspec-file-nul",
        okRefused, help = "docs/08"),
  ]

proc cmdStash*(c: Ctx, argv: seq[string]): int =
  ## Entry point: parse, find the sub-verb, dispatch.
  let o = parse(options, argv, "stash", synopsis)
  var includeUntracked = false
  for (k, _) in o.occurrences:
    if k == "include-untracked": includeUntracked = true
    elif k == "no-include-untracked": includeUntracked = false
  let quiet = o.has "quiet"
  let message = o.val "message"
  # The sub-verb is the first positional, unless it came after `--`.
  var sub = ""
  var rest = o.args
  if rest.len > 0 and o.dashDashAt != 0 and
     rest[0] in ["push", "list", "show", "pop", "apply", "drop", "clear"]:
    sub = rest[0]
    rest.delete(0)
  let repo = c.repo
  failIf(repo.workTree.len == 0, "stash is not possible in a bare repository")
  if sub.len == 0: sub = (if rest.len == 0: "push" else: "push")

  case sub
  of "push": return c.doPush(message, includeUntracked, quiet, rest)
  of "clear":
    if repo.refs.readRef(stashRef).found:
      repo.refs.deleteRef(stashRef)
      discard tryRemoveFile(repo.refs.reflogPath(stashRef))
    return 0
  of "list":
    # `stash@{n}: <message>` -- the reflog, formatted the way `%gd: %gs` would.
    let log = repo.refs.readReflog(stashRef)
    for i in countdown(log.high, 0):
      echo "stash@{" & $(log.high - i) & "}: " & log[i].message
    return 0
  of "show": fail("gittle stash show is not supported; use " &
                  "'gittle diff stash@{0}^ stash@{0}'")
  of "drop":
    let name = if rest.len > 0: rest[0] else: ""
    let (oid, pos) = repo.resolveStash(name)
    failIf(pos < 0, "'" & name & "' is not a stash reference")
    repo.dropEntry(pos)
    echo "Dropped " & (if name.len > 0: name else: stashRef & "@{0}") &
         " (" & $oid & ")"
    return 0
  of "pop", "apply":
    return c.doApply((if rest.len > 0: rest[0] else: ""), sub == "pop", quiet)
  else: fail("unknown subcommand '" & sub & "'\n" & o.use)
