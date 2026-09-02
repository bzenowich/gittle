## `branch` -- list, create, rename and delete branches.
##
## A branch is a file in `refs/heads/` holding one object ID.  Everything
## below is bookkeeping around that fact, and the listing is a `for-each-ref`
## with a format built for it -- which is literally how git does it
## (`builtin/branch.c:build_format`).  git builds that format as a string and
## runs it through `ref-filter.c`; gittle no longer has an atom grammar to run
## it through (docs/minimize-2.md B5), so `listBranches` renders its own
## columns and borrows only the *selection* -- `collectRefs` and `RefFilter`,
## in `cmd/foreachref.nim`.
##
## ## The three things a branch is, besides a ref
##
## * **the reflog**, `logs/refs/heads/<name>`, which a rename has to carry
##   with it or the branch loses its history of where it has been;
## * **`branch.<name>.remote` and `.merge`**, which say where it came from and
##   where it goes back to -- a rename has to move those too;
## * **HEAD**, if it happens to point here, which a rename has to follow.
##
## Missing any of the three leaves a repository that looks right and behaves
## strangely later, so the rename does all four things or none of them.
##
## ## `-d` asks a real question
##
## Refusing to delete an unmerged branch is the only place `branch` needs the
## revision walk: "merged" means the tip is reachable from HEAD (or from the
## branch's own upstream, which is what makes deleting a pushed branch work).
## `-D` says do it anyway, and prints the object ID so the work can be found
## again -- the reflog entry `-d` writes is the other half of that promise.
##
## ## What was trimmed
##
## `--sort`, `--format`, `--points-at`, `--no-contains`, `--no-merged` and
## `--edit-description` came out in the minimisation pass (docs/minimize.md
## §3): a survey of use found none of them, and `for-each-ref refs/heads`
## answers the first five.  Each refuses by name rather than being ignored.
##
## The second pass (docs/minimize-2.md B4) re-measured the same two logs and
## took three more: `--merged`, which `for-each-ref --merged refs/heads`
## answers, and the two upstream verbs `-u`/`--set-upstream-to` and
## `--unset-upstream`, which are `branch.<name>.remote` and `.merge` in the
## config and nothing else -- `push -u` and `checkout -b --track` are how an
## upstream actually gets set, and both go through `setBranchUpstream` still.
## `--contains` (5 uses), `-vv`, `-a`, `-r`, `-m`, `-f`, `--list` and
## `--show-current` -- everything the logs do use -- stay, as do the verbs
## `-d`/`-D` and `-q`/`-t`/`--no-track`, which `checkout` and `worktree` reach
## through this file's own procs.

import std/[os, strutils]
import ../cli, ../commitobj, ../config, ../refname, ../refs,
       ../repository, ../revision, ../revwalk, ../sequencer, ../util,
       ../worktrees
import foreachref


const heads = refsPrefix & "heads/"
const remotes = refsPrefix & "remotes/"

# ---------------------------------------------------------------------------
# Upstream configuration
# ---------------------------------------------------------------------------

proc setBranchUpstream*(c: Ctx, branch, upstream: string, quiet: bool) =
  ## `branch.<name>.remote` names *where*, `.merge` names the ref **as the
  ## remote calls it** -- not the local remote-tracking ref.  Getting that
  ## backwards produces a configuration that looks right and fetches nothing.
  let repo = c.repo
  let d = repo.refs.dwimRef(upstream)
  failIf(not d.found, "the requested upstream branch '" & upstream &
         "' does not exist")
  var remote = "."
  var merge = d.full
  if d.full.startsWith(remotes):
    let rest = d.full[remotes.len .. ^1]
    let slash = rest.find('/')
    failIf(slash <= 0, "'" & upstream & "' is not a valid remote-tracking branch")
    remote = rest[0 ..< slash]
    merge = "refs/heads/" & rest[slash + 1 .. ^1]
  setConfigValue(repo.gitDir / "config", "branch." & branch & ".remote", remote)
  setConfigValue(repo.gitDir / "config", "branch." & branch & ".merge", merge)
  if not quiet:
    echo "branch '" & branch & "' set up to track '" &
         repo.refs.shortenRef(d.full) & "'."

proc trackingFor(repo: Repository, startRef: string): bool =
  ## Should a new branch started here be set up to track?
  ##
  ## `branch.autoSetupMerge` defaults to `true`, which means "track when the
  ## start point is a remote-tracking branch and not otherwise" -- so
  ## `branch topic origin/main` tracks and `branch topic main` does not.
  let mode = repo.cfg.get("branch.autoSetupMerge")
  case mode
  of "false", "no": false
  of "always": startRef.len > 0
  else: startRef.startsWith(remotes)

# ---------------------------------------------------------------------------
# The listing
# ---------------------------------------------------------------------------

proc trackText(repo: Repository, refName: string, brackets: bool): string =
  ## `[ahead 3, behind 1]`, `[gone]`, or nothing when the branch is level with
  ## its upstream or has none (`ref-filter.c:stat_tracking_info`).
  let up = repo.upstreamRef(refName)
  if up.len == 0: return ""
  let there = repo.refs.resolveRef(up)
  if not there.found: return (if brackets: "[gone]" else: "gone")
  let here = repo.refs.resolveRef(refName)
  if not here.found: return ""
  let ahead = repo.countRange(here.oid, there.oid)
  let behind = repo.countRange(there.oid, here.oid)
  if ahead == 0 and behind == 0: return ""
  let inner = if ahead == 0: "behind " & $behind
              elif behind == 0: "ahead " & $ahead
              else: "ahead " & $ahead & ", behind " & $behind
  if brackets: "[" & inner & "]" else: inner

proc tipSubject(repo: Repository, o: Oid): string =
  ## The first paragraph of the commit's message, folded onto one line: the
  ## last column of `branch -v`.  git asks `ref-filter.c` for
  ## `%(contents:subject)`; a branch always names a commit, so there is no tag
  ## to peel here and no atom grammar to go through.
  ##
  ## The signature is stripped first because a signed commit keeps it inside
  ## the message (`gpg-interface.c:parse_signed_buffer`), and a subject that
  ## began with a line of base64 would be worse than useless.
  subject(stripSignature(repo.readCommit(o).message))

proc listBranches(c: Ctx, f: RefFilter, kinds: set[range[0 .. 1]],
                  verbose: int): int =
  ## `kinds` is which namespaces to list: 0 local, 1 remote-tracking.
  let repo = c.repo
  var prefixes: seq[string]
  if 0 in kinds: prefixes.add heads
  if 1 in kinds: prefixes.add remotes
  # When both namespaces are on show, the remote ones wear a `remotes/` prefix
  # so that `origin/main` cannot be mistaken for a local branch of that name.
  let remotePrefix = if kinds == {1}: "" else: "remotes/"

  let headBranch = repo.headRefName
  let rows = repo.collectRefs(prefixes, f)

  proc shownName(r: RefRow): string =
    ## The name as the listing shows it: `main`, or `remotes/origin/main` when
    ## both namespaces are on show.
    if r.rf.name.startsWith(heads): r.rf.name[heads.len .. ^1]
    else: remotePrefix & r.rf.name[remotes.len .. ^1]

  # A detached HEAD is not a ref, so it is not in the listing -- but git shows
  # it, first, as a row of its own, and it counts toward the column width.
  var detached = ""
  if 0 in kinds and repo.headRefName == headRef and f.patterns.len == 0:
    let h = repo.refs.resolveRef(headRef)
    if h.found:
      # Mid-rebase, HEAD really is detached, but saying so is useless: what
      # the user wants to know is which branch is being moved
      # (`builtin/branch.c:get_head_description`).
      const heads = refsPrefix & "heads/"
      let moving = repo.readState(rebaseDir / "head-name").strip()
      detached =
        if repo.currentOp != opRebase: "(" & repo.headDescription & ")"
        elif moving.startsWith(heads):
          "(no branch, rebasing " & moving[heads.len .. ^1] & ")"
        else:
          "(no branch, rebasing detached HEAD " &
          repo.uniqueAbbrev(h.oid, repo.autoAbbrev) & ")"

  var width = detached.len
  for r in rows: width = max(width, shownName(r).len)

  proc line(mark, name: string, oid: Oid, refName, symTarget: string): string =
    ## One listing row: the mark, the padded name, and under `-v` the tip,
    ## the upstream state and the subject.  `refName` is empty for the
    ## detached-HEAD row below, which is not a ref: it has no worktree of its
    ## own to name and no upstream to compare against.
    result = mark & (if verbose > 0: name.alignLeft(width) else: name)
    if symTarget.len > 0:
      # A symbolic ref -- `origin/HEAD` -- names another ref, and that is all
      # there is to say about it: no object ID, no subject.
      return result & " -> " & repo.refs.shortenRef(symTarget)
    if verbose == 0: return
    result.add " " & repo.uniqueAbbrev(oid, repo.autoAbbrev) & " "
    # `-vv` names the other worktree a branch is checked out in, just after
    # the object ID: it is the reason `+` was printed and the reason a
    # `checkout` of it will be refused.
    if verbose > 1 and refName.len > 0 and refName != headBranch:
      let wtPath = repo.checkedOutAt(refName)
      if wtPath.len > 0: result.add "(" & wtPath & ") "
    let up = if refName.len > 0: repo.upstreamRef(refName) else: ""
    if verbose > 1 and up.len > 0:
      let t = trackText(repo, refName, brackets = false)
      result.add "[" & repo.refs.shortenRef(up) &
                 (if t.len > 0: ": " & t else: "") & "] "
    elif verbose == 1 and refName.len > 0:
      let t = trackText(repo, refName, brackets = true)
      if t.len > 0: result.add t & " "
    result.add tipSubject(repo, oid)

  if detached.len > 0:
    echo line("* ", detached, repo.refs.resolveRef(headRef).oid, "", "")
  for r in rows:
    # `+` marks a branch some *other* worktree has checked out, which is a
    # branch this one may not move (worktrees.nim).  git spells the same rule
    # as `%(if)%(HEAD)%(then)*%(else)%(if)%(worktreepath)%(then)+`.
    let mark = if r.rf.name == headBranch: "* "
               elif repo.checkedOutAt(r.rf.name).len > 0: "+ "
               else: "  "
    echo line(mark, shownName(r), r.oid, r.rf.name, r.rf.symTarget)
  0

# ---------------------------------------------------------------------------
# Creating, deleting, renaming
# ---------------------------------------------------------------------------

proc createBranch*(c: Ctx, name, startPoint: string, force, quiet, track: bool,
                  trackGiven: bool) =
  ## `branch <name> [<start>]`: refuse a bad or taken name, write the ref
  ## with a reflog line naming where it came from, and set up tracking
  ## when `branch.autoSetupMerge` says to.
  let repo = c.repo
  failIf(not isValidRefname(heads & name, {}),
         "'" & name & "' is not a valid branch name")
  let full = heads & name
  let existing = repo.refs.readRef(full)
  failIf(existing.found and not force,
         "a branch named '" & name & "' already exists")
  # Any worktree, not only this one: two checkouts of one branch would let a
  # commit in either move the ref under the other (worktrees.nim).
  if existing.found:
    let where = repo.checkedOutAt(full)
    failIf(where.len > 0, "cannot force update the branch '" & name &
           "' used by worktree at '" & where & "'")

  # With no start point the reflog records the *branch* the new one came from,
  # not the word "HEAD" -- that is what makes the entry readable a year later.
  let start = if startPoint.len > 0: startPoint
              elif repo.headRefName.startsWith(heads):
                repo.headRefName[heads.len .. ^1]
              else: "HEAD"
  let oid = repo.resolveCommittish(start)
  let d = repo.refs.dwimRef(start)
  let startRef = if d.found: d.full else: ""

  repo.refs.updateRef(full, oid, msg =
    (if existing.found: "branch: Reset to " else: "branch: Created from ") & start)
  if trackGiven and not track: return
  if (trackGiven and track) or repo.trackingFor(startRef):
    if startRef.len > 0: setBranchUpstream(c, name, startRef, quiet)

proc deleteBranches(c: Ctx, names: seq[string], force, quiet, remote: bool): int =
  ## `-d`/`-D` over several names: every refusal is an `error:` and exit 1
  ## rather than fatal, so the others are still tried.
  let repo = c.repo
  let prefix = if remote: remotes else: heads
  let head = repo.refs.resolveRef(headRef)
  for name in names:
    let full = if name.startsWith(refsPrefix): name else: prefix & name
    let r = repo.refs.readRef(full)
    if not r.found:
      stderr.write "error: branch '" & name & "' not found\n"
      result = 1
      continue
    let usedAt = if remote: "" else: repo.checkedOutAt(full)
    if usedAt.len > 0:
      # An `error:` and exit 1, not a fatal: `branch -d a b c` goes on to the
      # others, which is why every refusal in this loop is reported this way.
      stderr.write "error: cannot delete branch '" & name &
                   "' used by worktree at '" & usedAt & "'\n"
      result = 1
      continue
    if not force:
      # "Merged" means the work is not about to be lost: reachable from HEAD,
      # or already pushed to the branch's own upstream.
      var merged = head.found and repo.isAncestor(r.oid, head.oid)
      let up = repo.upstreamRef(full)
      if not merged and up.len > 0:
        let there = repo.refs.resolveRef(up)
        merged = there.found and repo.isAncestor(r.oid, there.oid)
      failIf(not merged, "the branch '" & name & "' is not fully merged; " &
             "'gittle branch -D " & name & "' deletes it anyway")
    repo.refs.deleteRef(full, msg = "branch: deleted")
    if not quiet:
      echo "Deleted " & (if remote: "remote-tracking " else: "") & "branch " &
           name & " (was " & repo.uniqueAbbrev(r.oid, repo.autoAbbrev) & ")."

proc renameBranch(c: Ctx, oldName, newName: string, force: bool) =
  ## A rename moves four things: the ref, its reflog, its configuration
  ## section, and HEAD if it was pointing here.
  let repo = c.repo
  let old = heads & oldName
  let dest = heads & newName
  failIf(not isValidRefname(dest, {}),
         "'" & newName & "' is not a valid branch name")
  let r = repo.refs.readRef(old)
  failIf(not r.found, "no branch named '" & oldName & "'")
  failIf(repo.refs.readRef(dest).found and not force,
         "a branch named '" & newName & "' already exists")

  # The order is the whole of the correctness here, and it is git's
  # (`refs/files-backend.c:files_copy_or_rename_ref`).  The reflog moves
  # *first*, because deleting the old ref takes its log with it.  HEAD is
  # repointed **last**, so its own log records the branch going away and then
  # arriving under the new name -- two entries, not a silent jump.
  let logmsg = "Branch: renamed " & old & " to " & dest
  let wasHead = repo.headRefName == old
  let oldLog = repo.refs.reflogPath(old)
  if fileExists(oldLog):
    let newLog = repo.refs.reflogPath(dest)
    createDir(parentDir(newLog))
    moveFile(oldLog, newLog)
  repo.refs.deleteRef(old, msg = logmsg)
  # The new name has no previous value, but the reflog has to say where the
  # branch came *from*, so the old value is forced to the branch's own.
  repo.refs.updateRef(dest, r.oid, msg = logmsg,
                      logOld = r.oid, haveLogOld = true)
  if wasHead: repo.refs.writeSymRef(headRef, dest, msg = logmsg)

  for key in ["remote", "merge", "rebase", "description"]:
    let v = repo.cfg.get("branch." & oldName & "." & key)
    if v.len > 0:
      setConfigValue(repo.gitDir / "config", "branch." & newName & "." & key, v)
      discard unsetConfigValue(repo.gitDir / "config",
                               "branch." & oldName & "." & key, all = true)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

const
  synopsis = "[<options>] [<pattern>…]\n[-f] <branch> [<start-point>]\n(-d | -D) [-r] <branch>…\n(-m | -M) [<old-branch>] <new-branch>"
  options = [
    opt("-l|--list", help = "list branches (the default)"),
    opt("-a|--all", help = "list local and remote-tracking branches"),
    opt("-r|--remotes", help = "list remote-tracking branches"),
    opt("-v|--verbose", okCount, help = "show the tip commit, and with -vv the upstream"),
    opt("--show-current", help = "print the branch HEAD is on"),
    opt("-d|--delete", help = "delete a branch"),
    opt("-D", help = "delete a branch even if it is not merged"),
    opt("-m|--move", help = "rename a branch"),
    opt("-M", help = "rename over an existing branch"),
    opt("-f|--force", help = "overwrite an existing branch"),
    opt("-q|--quiet", help = "say nothing on success"),
    opt("-t|--track", help = "set up upstream tracking from the start point"),
    opt("--no-track", help = "do not set up tracking"),
    opt("--contains", okOptNext, arg = "[<commit>]", help = "list only branches containing <commit> (HEAD by default)"),
    opt("-c|--copy|-C|--create-reflog", okRefused, help = "docs/06"),
    opt("-u|--set-upstream-to|--unset-upstream", okRefused,
        help = "trimmed (docs/minimize-2.md B4); an upstream is branch.<name>.remote and .merge, and push -u writes them"),
    opt("--sort|--format|--points-at|--no-contains|--merged|--no-merged|--edit-description",
        okRefused, help = "trimmed (docs/minimize.md §3, B4); use for-each-ref refs/heads"),
  ]

proc cmdBranch*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, then dispatch on which of the four jobs the
  ## options and positionals add up to -- upstream bookkeeping, delete,
  ## rename, create, or list.
  let o = parse(options, args, "branch", synopsis)
  var f = RefFilter()
  applyFilterOpts(c, o, f)
  var kinds: set[range[0 .. 1]] = {}
  var track, trackGiven = false
  for (k, _) in o.occurrences:        # the last of -a/-r, and of -t/--no-track, wins
    case k
    of "all": kinds = {0, 1}
    of "remotes": kinds = {1}
    of "track": (track = true; trackGiven = true)
    of "no-track": (track = false; trackGiven = true)
    else: discard
  let verbose = o.count "verbose"
  let list = o.has "list"
  let quiet = o.has "quiet"
  let force = o.has("force") or o.has("D") or o.has("M")
  let del = o.has("delete") or o.has("D")
  let move = o.has("move") or o.has("M")
  let showCurrent = o.has "show-current"
  var rest = o.args
  let repo = c.repo
  if kinds.card == 0: kinds = {0}

  if showCurrent:
    let name = repo.headRefName
    if name.startsWith(heads): echo name[heads.len .. ^1]
    return 0

  if del:
    failIf(rest.len == 0, "branch name required")
    return deleteBranches(c, rest, force, quiet, 1 in kinds)

  if move:
    failIf(rest.len == 0 or rest.len > 2, o.use)
    # The last argument is the new name; what is left, if anything, is the old.
    let dest = rest[^1]
    rest.setLen(rest.len - 1)
    # With one argument the branch renamed is the one HEAD is on, and a
    # detached HEAD has none.
    var src = if rest.len > 0: rest[0] else: repo.headRefName
    if rest.len == 0:
      failIf(not src.startsWith(heads), "cannot rename a detached HEAD")
      src = src[heads.len .. ^1]
    renameBranch(c, src, dest, force)
    return 0

  # A bare name creates; anything else is a listing, and the leftovers are
  # patterns.  `--list` forces the listing reading, which is how a branch
  # whose name looks like a pattern is listed rather than created.
  if rest.len > 0 and not list and verbose == 0 and f.patterns.len == 0:
    failIf(rest.len > 2, o.use)
    createBranch(c, rest[0], (if rest.len > 1: rest[1] else: ""),
                 force, quiet, track, trackGiven)
    return 0

  f.patterns.add rest
  listBranches(c, f, kinds, verbose)
