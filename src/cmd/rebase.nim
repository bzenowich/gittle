## `rebase` -- replay a branch onto a different base.
##
## In scope (docs/08): `<upstream>`, `<branch>`, `--onto`, `-q`/`-v`, and
## `--continue`/`--skip`/`--abort`/`--quit`.
##
## ## It is cherry-pick in a loop, with a branch label moved at the end
##
## | | |
## |---|---|
## | 1 | work out which commits to replay: `<upstream>..<branch>`, oldest first, merges dropped |
## | 2 | detach HEAD at `<onto>` -- so a rebase that dies leaves the branch untouched |
## | 3 | replay each commit, exactly as `cherry-pick` does |
## | 4 | point `<branch>` at the result and re-attach HEAD to it |
##
## Step 2 is why `rebase --abort` can always work: until step 4, the branch
## still names the original commits, and aborting is `checkout <branch>`.  It
## is also why `status` says `HEAD detached` in the middle of one, and why the
## `rebase-merge` directory exists at all -- HEAD alone does not record which
## branch is being moved.
##
## ## The state directory
##
## `$GIT_DIR/rebase-merge/`, with git's file names, so that a rebase either
## tool started can be continued by the other:
##
## | | |
## |---|---|
## | `head-name` | the branch being moved, or `detached HEAD` |
## | `onto`, `orig-head` | where it is going, and where it started |
## | `git-rebase-todo` | the picks not yet done |
## | `done` | the picks already done |
## | `msgnum`, `end` | which one and how many, for `Rebasing (2/5)` |
## | `interactive` | present, and empty -- see below |
## | `message`, `author-script`, `stopped-sha` | the pick that stopped |
##
## The `interactive` file is written for a *non*-interactive rebase too, and
## that is not a mistake: since git 2.26 the merge backend runs every rebase
## through the interactive machinery, and `status` keys its report off that
## file (`wt-status.c:show_rebase_information`).  Writing it is what makes
## `status` say `interactive rebase in progress` for a plain `gittle rebase`,
## the way it does for a plain `git rebase`.
##
## ## What is cut, and the one place it shows
##
## `-i`, `--exec`, `--autosquash`, `--rebase-merges`, `--autostash`,
## `--keep-base`, `--root`, `--fork-point`, `--apply` and the strategy options
## (docs/08).  And **patch-id equivalence**: git's todo list drops commits
## whose change is already upstream by comparing patch IDs
## (`--cherry-mark`, cut in docs/04), and gittle's does not.  The consequence
## is smaller than it sounds, because such a commit replays to a tree
## identical to the one it is being replayed onto, and is dropped *then* --
## with the same message git prints.  What differs is the count in
## `Rebasing (n/m)` and the todo list `status` shows.

import std/[os, strutils]
import ../cli, ../commitobj, ../diffcore, ../ident, ../index, ../objects,
       ../oid, ../pathspec, ../refs, ../repository, ../revision, ../revwalk,
       ../sequencer, ../trees, ../util, ../worktree

const usageText = """usage: gittle rebase [--onto <newbase>] [-q|-v] [<upstream>] [<branch>]
   or: gittle rebase --continue | --skip | --abort | --quit"""

const heads = refsPrefix & "heads/"

type State = object
  ## `rebase-merge/`, read back.
  headName: string        ## `refs/heads/topic`, or `detached HEAD`
  onto, origHead: Oid
  todo, done: seq[string] ## whole todo lines, current pick first in `todo`
  quiet: bool

proc todoLine(repo: Repository, oid: Oid, msg: string): string =
  ## git's own instruction format: the *full* object ID, and the subject
  ## behind a `#` because `rebase.instructionFormat` defaults to `%s` and the
  ## todo parser prefixes one (`sequencer.c:sequencer_make_script`).
  "pick " & $oid & " # " & subject(msg)

func todoOid(line: string): string =
  let f = line.splitWhitespace
  if f.len >= 2: f[1] else: ""

func todoRest(line: string): string =
  ## Everything after the object ID -- `# t1` -- which is what git quotes back
  ## in `Could not apply <abbrev>... # t1`.
  let f = line.splitWhitespace
  if f.len >= 3: f[2 .. ^1].join(" ") else: ""

proc readState(repo: Repository): State =
  result.headName = repo.readState(rebaseDir / "head-name").strip()
  result.onto = repo.stateOid(rebaseDir / "onto")
  result.origHead = repo.stateOid(rebaseDir / "orig-head")
  result.quiet = fileExists(repo.statePath(rebaseDir / "quiet"))
  for line in repo.readState(rebaseDir / "git-rebase-todo").splitLines:
    if line.strip().len > 0: result.todo.add line
  for line in repo.readState(rebaseDir / "done").splitLines:
    if line.strip().len > 0: result.done.add line

proc writeProgress(repo: Repository, st: State, quiet, verbose: bool) =
  ## `Rebasing (2/5)`, ending in a carriage return so the next one overwrites
  ## it -- `-v` makes it a newline instead and keeps every line.
  repo.writeState(rebaseDir / "msgnum", $(st.done.len) & "\n")
  if quiet: return
  stderr.write "Rebasing (" & $st.done.len & "/" &
               $(st.done.len + st.todo.len) & ")" & (if verbose: "\n" else: "\r")

proc finish(repo: Repository, st: State, quiet: bool): int =
  ## Point the branch at what was replayed, and re-attach HEAD to it.
  let head = repo.refs.resolveRef(headRef)
  if st.headName.startsWith(heads):
    repo.refs.updateRef(st.headName, head.oid,
                        msg = "rebase (finish): " & st.headName & " onto " &
                              $st.onto)
    repo.refs.writeSymRef(headRef, st.headName,
                          msg = "rebase (finish): returning to " & st.headName)
  repo.removeState(rebaseDir)
  if not quiet:
    stderr.write "Successfully rebased and updated " &
                 (if st.headName.len > 0: st.headName else: "HEAD") & ".\n"
  0

proc conflictAdvice(repo: Repository) =
  if not repo.cfg.getBool("advice.mergeConflict", true): return
  stderr.write "hint: Resolve all conflicts manually, mark them as resolved with\n" &
    "hint: \"gittle add/rm <conflicted_files>\", then run \"gittle rebase --continue\".\n" &
    "hint: You can instead skip this commit: run \"gittle rebase --skip\".\n" &
    "hint: To abort and get back to the state before \"gittle rebase\", run " &
    "\"gittle rebase --abort\".\n" &
    "hint: Disable this message with \"gittle config set " &
    "advice.mergeConflict false\"\n"

proc stopHere(repo: Repository, st: State, pick: Oid, line: string,
              msg: string, author: Ident) =
  ## Record everything `--continue` will need, and say so.
  ##
  ## Two lines announce the same failure, and both are git's: the `error:`
  ## comes from the pick machinery, which does not know it is inside a rebase,
  ## and the `Could not apply` from the rebase loop, which quotes the todo
  ## line rather than the subject.
  repo.writeState(rebaseDir / "git-rebase-todo", st.todo.join("\n") &
                  (if st.todo.len > 0: "\n" else: ""))
  repo.writeState(rebaseDir / "done", st.done.join("\n") &
                  (if st.done.len > 0: "\n" else: ""))
  repo.writeState(rebaseDir / "message", msg)
  # And in `MERGE_MSG` as well: a user who resolves the conflict and runs
  # `commit` rather than `rebase --continue` gets the same message.
  repo.writeState("MERGE_MSG", msg)
  repo.writeState(rebaseDir / "stopped-sha", $pick & "\n")
  # The author is kept as shell assignments because git's `am` backend sourced
  # this file; the merge backend only parses it, but the format is the format.
  repo.writeState(rebaseDir / "author-script",
    "GIT_AUTHOR_NAME='" & author.name & "'\n" &
    "GIT_AUTHOR_EMAIL='" & author.email & "'\n" &
    "GIT_AUTHOR_DATE='@" & $author.when0 & " " & formatTz(author.tzOffset) & "'\n")
  repo.writeState("REBASE_HEAD", $pick & "\n")
  stderr.write "error: could not apply " &
               repo.uniqueAbbrev(pick, repo.autoAbbrev) & "... " &
               subject(msg) & "\n"
  repo.conflictAdvice()
  stderr.write "Could not apply " & repo.uniqueAbbrev(pick, repo.autoAbbrev) &
               "... " & line.todoRest & "\n"

proc replay(c: Ctx, st0: State, quiet, verbose: bool): int =
  ## Run the todo list until it is empty or something stops it.
  let repo = c.repo
  var st = st0
  let idx = readIndex(repo.indexPath)
  while st.todo.len > 0:
    let line = st.todo[0]
    st.todo = st.todo[1 .. ^1]
    st.done.add line
    let pick = repo.resolveCommittish(line.todoOid)
    let cm = repo.readCommit(pick)
    repo.writeProgress(st, quiet, verbose)

    let parentTree = if cm.parents.len == 1:
                       repo.peelTo(cm.parents[0], otTree).oid
                     else: nullOid
    let res = repo.applyThreeWay(idx, parentTree, cm.tree,
                repo.uniqueAbbrev(pick, repo.autoAbbrev) & " (" &
                subject(cm.message) & ")", "rebase")
    reportMerge(res)
    idx.writeIndex()
    if res.conflicts > 0:
      repo.stopHere(st, pick, line, cm.message & res.conflictComments, cm.author)
      return 1

    let head = repo.refs.resolveRef(headRef)
    # A commit whose change was already upstream replays to the tree it was
    # replayed onto.  git drops it rather than recording an empty commit, and
    # says which one it dropped (`sequencer.c:allow_empty`).
    if repo.writeTree(idx) == repo.peelTo(head.oid, otTree).oid:
      stderr.write "dropping " & $pick & " " & subject(cm.message) &
                   " -- patch contents already upstream\n"
      continue
    discard repo.commitOnHead(idx, @[head.oid], cm.author, cm.message,
                              "rebase (pick): " & subject(cm.message))
  repo.finish(st, quiet)

proc cmdRebase*(c: Ctx, argv: seq[string]): int =
  let args = expandShortOptions(argv, {})
  var onto = ""
  var quiet, verbose = false
  var cont, skip, abort, quit0 = false
  var rest: seq[string]
  var i = 0

  optionValue(args, i)
  while i < args.len:
    let a = args[i]
    if a.len == 0 or a[0] != '-': rest.add a
    elif a == "--onto" or a.startsWith("--onto="): onto = valueFor(a)
    elif a == "-q" or a == "--quiet": (quiet = true; verbose = false)
    elif a == "-v" or a == "--verbose": (verbose = true; quiet = false)
    elif a == "--continue": cont = true
    elif a == "--skip": skip = true
    elif a == "--abort": abort = true
    elif a == "--quit": quit0 = true
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["-i", "--interactive", "-r", "--rebase-merges", "-x", "--exec",
               "--autosquash", "--no-autosquash", "--autostash",
               "--no-autostash", "--update-refs", "--no-update-refs",
               "--keep-base", "--root", "--fork-point", "--no-fork-point",
               "-m", "--merge", "--apply", "-s", "--strategy", "-X",
               "--strategy-option", "--ignore-whitespace", "--whitespace",
               "--empty", "--keep-empty", "--no-keep-empty",
               "--reapply-cherry-picks", "--no-reapply-cherry-picks",
               "--no-ff", "--force-rebase", "-f", "--edit-todo",
               "--show-current-patch", "--committer-date-is-author-date",
               "--ignore-date", "--reset-author-date", "--signoff",
               "--trailer", "-S", "--gpg-sign", "--no-gpg-sign", "--verify",
               "--no-verify", "--stat", "-n", "--no-stat",
               "--rerere-autoupdate", "--no-rerere-autoupdate"]:
      fail(a & " is out of scope for gittle v1 (docs/08)")
    else: fail("unknown option '" & a & "'\n" & usageText)
    inc i

  let repo = c.repo
  failIf(repo.workTree.len == 0, "rebase is not possible in a bare repository")
  let idx = readIndex(repo.indexPath)

  # ---- the four state verbs
  if cont or skip or abort or quit0:
    failIf(not dirExists(repo.statePath(rebaseDir)), "no rebase in progress")
    var st = repo.readState()
    if quit0:
      # `REBASE_HEAD` survives: git forgets the rebase without forgetting
      # which commit it had stopped on.
      repo.removeState(rebaseDir, "AUTO_MERGE")
      return 0
    if abort:
      # Back to where the branch was, and back onto the branch: until `finish`
      # ran, the branch never moved, so this really is a checkout.  ORIG_HEAD
      # is left alone -- it already names the tip this rebase started from,
      # which is the thing worth being able to get back to.
      repo.restoreTo(idx, st.origHead)
      if st.headName.startsWith(heads):
        repo.refs.updateRef(st.headName, st.origHead)
        repo.refs.writeSymRef(headRef, st.headName,
                              msg = "rebase (abort): returning to " & st.headName)
      else:
        repo.refs.updateRef(headRef, st.origHead, noDeref = true,
                            msg = "rebase (abort): returning to " & $st.origHead)
      repo.removeState(rebaseDir, "REBASE_HEAD", "AUTO_MERGE", "MERGE_MSG")
      return 0

    if cont:
      # Not the `add/rm` advice the other commands give: rebase checks by
      # *refreshing the index*, and what it reports is that refresh's own
      # complaint, on standard output (`builtin/rebase.c`, ACTION_CONTINUE).
      var unmerged = false
      var last = ""
      for e in idx.entries:
        if e.stage != 0 and e.path != last:
          last = e.path
          unmerged = true
          echo e.path & ": needs merge"
      if unmerged:
        echo "You must edit all merge conflicts and then\nmark them as " &
             "resolved using gittle add"
        return 1
      # Nothing staged means the user committed the resolution by hand before
      # running `--continue`, and committing again would record an empty
      # commit (`sequencer.c:commit_staged_changes` asks the same question).
      let stopped = repo.stateOid("REBASE_HEAD")
      if not stopped.isNull and
         repo.writeTree(idx) != repo.peelTo(repo.refs.resolveRef(headRef).oid,
                                            otTree).oid:
        let cm = repo.readCommit(stopped)
        let head = repo.refs.resolveRef(headRef)
        let newOid = repo.commitOnHead(idx, @[head.oid], cm.author,
          cleanupMessage(repo.readState(rebaseDir / "message"),
                         dropComments = true),
          "rebase (continue): " & subject(cm.message))
        repo.summarizeCommit(newOid)
    else:
      # `--skip`: throw away the half-applied pick and go on to the next.
      repo.restoreTo(idx, repo.refs.resolveRef(headRef).oid)
    repo.removeState("REBASE_HEAD", "AUTO_MERGE", "MERGE_MSG")
    return c.replay(st, quiet or st.quiet, verbose)

  repo.refuseIfInProgress(idx, "rebase")

  # ---- a fresh rebase
  # `<branch>` names a branch to move, and it becomes HEAD for the duration:
  # the ref is expanded now so that `head-name` can record it in full.
  var branchName = repo.headRefName
  if rest.len > 1:
    let d = repo.refs.dwimRef(rest[1])
    branchName = if d.found: d.full else: rest[1]
  let branchTip = if rest.len > 1: repo.resolveCommittish(rest[1])
                  else: repo.refs.resolveRef(headRef).oid
  var upstreamName = if rest.len > 0: rest[0] else: ""
  if upstreamName.len == 0:
    let up = repo.upstreamRef(repo.headRefName)
    failIf(up.len == 0,
           "There is no tracking information for the current branch.\n" &
           "Please specify which branch you want to rebase against.")
    upstreamName = up
  let upstream = repo.resolveCommittish(upstreamName)
  let ontoName = if onto.len > 0: onto else: upstreamName
  let ontoOid = repo.resolveCommittish(ontoName)

  # Nothing to do: the branch already contains everything `onto` does, so
  # replaying would put every commit back where it is
  # (`builtin/rebase.c:can_fast_forward`).
  if repo.isAncestor(ontoOid, branchTip):
    if not quiet:
      if branchName.startsWith(heads):
        echo "Current branch " & branchName[heads.len .. ^1] & " is up to date."
      else:
        echo "HEAD is up to date."
    return 0

  # The commits to replay: what the branch has that upstream does not, oldest
  # first, merges dropped -- a merge has no single parent to diff against.
  let w = newRevWalk(repo)
  w.order = roTopo
  w.maxParents = 1
  w.push(branchTip)
  w.push(upstream, uninteresting = true)
  var picks: seq[Oid]
  for e in w.walk: picks.add e.oid

  var st = State(headName: (if branchName.startsWith(heads): branchName
                            else: "detached HEAD"),
                 onto: ontoOid, origHead: branchTip, quiet: quiet)
  for k in countdown(picks.high, 0):
    st.todo.add repo.todoLine(picks[k], repo.readCommit(picks[k]).message)

  # Detach at `onto` before anything is replayed.  Everything after this can
  # be undone by putting the branch back, which is exactly what `--abort` does.
  let head = repo.refs.resolveRef(headRef)
  let plan = repo.planTwoWay(idx, repo.flatten(repo.peelTo(head.oid, otTree).oid),
                             repo.flatten(repo.peelTo(ontoOid, otTree).oid),
                             force = false)
  if plan.refused("rebase"): return 1
  repo.writeState("ORIG_HEAD", $branchTip & "\n")
  repo.applyPlan(idx, plan, repo.flatten(repo.peelTo(ontoOid, otTree).oid))
  idx.writeIndex()
  if verbose:
    # `-v` implies `--stat`: what the new base brings that the old one did
    # not, so the user can see what they are rebasing onto.
    let mb = repo.mergeBase(ontoOid, branchTip)
    echo "Changes from " & $mb & " to " & $ontoOid & ":"
    stdout.write repo.mergeSummary(pairsTreeTree(repo,
      repo.peelTo(mb, otTree).oid, repo.peelTo(ontoOid, otTree).oid,
      parsePathspec(@[])))
    stdout.flushFile()
  repo.refs.updateRef(headRef, ontoOid, noDeref = true,
                      msg = (if c.reflogAction.len > 0: c.reflogAction else: "rebase") &
                            " (start): checkout " & ontoName)

  repo.writeState(rebaseDir / "head-name", st.headName & "\n")
  repo.writeState(rebaseDir / "onto", $ontoOid & "\n")
  repo.writeState(rebaseDir / "orig-head", $branchTip & "\n")
  repo.writeState(rebaseDir / "interactive", "")
  repo.writeState(rebaseDir / "end", $st.todo.len & "\n")
  repo.writeState(rebaseDir / "msgnum", "0\n")
  repo.writeState(rebaseDir / "git-rebase-todo", st.todo.join("\n") &
                  (if st.todo.len > 0: "\n" else: ""))
  repo.writeState(rebaseDir / "done", "")
  if quiet: repo.writeState(rebaseDir / "quiet", "")
  c.replay(st, quiet, verbose)
