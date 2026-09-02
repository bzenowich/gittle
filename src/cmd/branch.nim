## `branch` -- list, create, rename and delete branches.
##
## A branch is a file in `refs/heads/` holding one object ID.  Everything
## below is bookkeeping around that fact, and the listing is a `for-each-ref`
## with a format built for it -- which is literally how git does it
## (`builtin/branch.c:build_format`), and why `reffilter.nim` exists.
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

import std/[os, strutils]
import ../cli, ../config, ../reffilter, ../refname, ../refs,
       ../repository, ../revision, ../revwalk, ../sequencer, ../util
import foreachref

const usageText = """usage: gittle branch [<options>] [<pattern>…]
   or: gittle branch [-f] <branch> [<start-point>]
   or: gittle branch (-d | -D) [-r] <branch>…
   or: gittle branch (-m | -M) [<old-branch>] <new-branch>

   -l, --list                list branches (the default)
   -a, --all                 list local and remote-tracking branches
   -r, --remotes             list remote-tracking branches
   -v, -vv, --verbose        show the tip commit, and with -vv the upstream
   --show-current            print the branch HEAD is on
   -d, --delete, -D          delete a branch
   -m, --move, -M            rename a branch
   -f, --force               overwrite an existing branch
   -q, --quiet               say nothing on success
   -t, --track, --no-track   set up (or do not set up) upstream tracking
   -u, --set-upstream-to=<upstream>, --unset-upstream
   --contains, --no-contains, --merged, --no-merged, --points-at
   --sort=<key>, --format=<fmt>"""

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

proc listBranches(c: Ctx, f: RefFilter, kinds: set[range[0 .. 1]],
                  verbose: int, format: string): int =
  ## `kinds` is which namespaces to list: 0 local, 1 remote-tracking.
  let repo = c.repo
  var prefixes: seq[string]
  if 0 in kinds: prefixes.add heads
  if 1 in kinds: prefixes.add remotes
  # When both namespaces are on show, the remote ones wear a `remotes/` prefix
  # so that `origin/main` cannot be mistaken for a local branch of that name.
  let remotePrefix = if kinds == {1}: "" else: "remotes/"

  var rows = repo.collectRefs(prefixes, f)

  proc shownName(r: RefRow): string =
    if r.rf.name.startsWith(heads): r.rf.name[heads.len .. ^1]
    else: remotePrefix & r.rf.name[remotes.len .. ^1]

  if format.len > 0:
    for i in 0 ..< rows.len: echo repo.expand(rows[i], format)
    return 0

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

  proc line(mark, name: string, r: RefRow, symTarget: string): string =
    result = mark & (if verbose > 0: name.alignLeft(width) else: name)
    if symTarget.len > 0:
      # A symbolic ref -- `origin/HEAD` -- names another ref, and that is all
      # there is to say about it: no object ID, no subject.
      return result & " -> " & repo.refs.shortenRef(symTarget)
    if verbose == 0: return
    var row = r
    result.add " " & repo.uniqueAbbrev(row.self.oid, repo.autoAbbrev) & " "
    if verbose > 1 and repo.upstreamRef(row.rf.name).len > 0:
      let up = repo.refs.shortenRef(repo.upstreamRef(row.rf.name))
      let t = trackText(repo, row.rf.name, brackets = false)
      result.add "[" & up & (if t.len > 0: ": " & t else: "") & "] "
    elif verbose == 1:
      let t = trackText(repo, row.rf.name, brackets = true)
      if t.len > 0: result.add t & " "
    result.add repo.fieldValue(row, "contents:subject")

  if detached.len > 0:
    echo line("* ", detached, RefRow(self: ObjInfo(
                oid: repo.refs.resolveRef(headRef).oid)), "")
  for i in 0 ..< rows.len:
    echo line((if rows[i].isHead: "* " else: "  "), shownName(rows[i]),
              rows[i], rows[i].rf.symTarget)
  0

# ---------------------------------------------------------------------------
# Creating, deleting, renaming
# ---------------------------------------------------------------------------

proc createBranch(c: Ctx, name, startPoint: string, force, quiet, track: bool,
                  trackGiven: bool) =
  let repo = c.repo
  failIf(not isValidRefname(heads & name, {}),
         "'" & name & "' is not a valid branch name")
  let full = heads & name
  let existing = repo.refs.readRef(full)
  failIf(existing.found and not force,
         "a branch named '" & name & "' already exists")
  failIf(existing.found and full == repo.headRefName,
         "cannot force update the branch '" & name &
         "' checked out at '" & repo.workTree & "'")

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
    if full == repo.headRefName:
      # An `error:` and exit 1, not a fatal: `branch -d a b c` goes on to the
      # others, which is why every refusal in this loop is reported this way.
      stderr.write "error: cannot delete branch '" & name &
                   "' used by worktree at '" & repo.workTree & "'\n"
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
      failIf(not merged,
             "the branch '" & name & "' is not fully merged.\n" &
             "If you are sure you want to delete it, run 'gittle branch -D " &
             name & "'.")
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

proc cmdBranch*(c: Ctx, args: seq[string]): int =
  var f = RefFilter()
  var kinds: set[range[0 .. 1]] = {}
  var verbose = 0
  var format = ""
  var force, quiet, del, move, list, showCurrent, unsetUpstream = false
  var track, trackGiven = false
  var upstreamTo = ""
  var rest: seq[string]
  var i = 0
  let a2 = expandShortOptions(args, {'u'})

  optionValue(a2, i)

  while i < a2.len:
    let a = a2[i]
    if a.len > 1 and a[0] == '-':
      case a
      of "-l", "--list": list = true
      of "-a", "--all": kinds = {0, 1}
      of "-r", "--remotes": kinds = {1}
      of "-v", "--verbose": inc verbose
      of "-q", "--quiet": quiet = true
      of "-f", "--force": force = true
      of "-d", "--delete": del = true
      of "-D": (del = true; force = true)
      of "-m", "--move": move = true
      of "-M": (move = true; force = true)
      of "-t", "--track": (track = true; trackGiven = true)
      of "--no-track": (track = false; trackGiven = true)
      of "--unset-upstream": unsetUpstream = true
      of "--show-current": showCurrent = true
      of "-h", "--help": (echo usageText; return 0)
      of "-c", "--copy", "-C", "--edit-description", "--create-reflog":
        fail(a & " is out of scope for gittle v1 (docs/06)")
      else:
        if a == "-u" or a.startsWith("--set-upstream-to"):
          upstreamTo = valueFor(a, "")
        elif a.startsWith("--format"): format = valueFor(a, "")
        elif a == "-vv": verbose = 2
        elif parseFilterOpt(c, f, a, valueFor): discard
        else: fail("unknown option '" & a & "'\n" & usageText)
    else:
      rest.add a
    inc i

  let repo = c.repo
  if kinds.card == 0: kinds = {0}

  if showCurrent:
    let name = repo.headRefName
    if name.startsWith(heads): echo name[heads.len .. ^1]
    return 0

  if unsetUpstream:
    let name = if rest.len > 0: rest[0]
               else:
                 failIf(not repo.headRefName.startsWith(heads),
                        "could not unset upstream of HEAD when it does not " &
                        "point to any branch")
                 repo.headRefName[heads.len .. ^1]
    for key in ["remote", "merge"]:
      discard unsetConfigValue(repo.gitDir / "config",
                               "branch." & name & "." & key, all = true)
    return 0

  if upstreamTo.len > 0:
    let name = if rest.len > 0: rest[0]
               else:
                 failIf(not repo.headRefName.startsWith(heads),
                        "could not set upstream of HEAD when it does not " &
                        "point to any branch")
                 repo.headRefName[heads.len .. ^1]
    setBranchUpstream(c, name, upstreamTo, quiet)
    return 0

  if del:
    failIf(rest.len == 0, "branch name required")
    return deleteBranches(c, rest, force, quiet, 1 in kinds)

  if move:
    failIf(rest.len == 0 or rest.len > 2, usageText)
    let (old, dest) =
      if rest.len == 2: (rest[0], rest[1])
      else:
        failIf(not repo.headRefName.startsWith(heads),
               "cannot rename a detached HEAD")
        (repo.headRefName[heads.len .. ^1], rest[0])
    renameBranch(c, old, dest, force)
    return 0

  # A bare name creates; anything else is a listing, and the leftovers are
  # patterns.  `--list` forces the listing reading, which is how a branch
  # whose name looks like a pattern is listed rather than created.
  if rest.len > 0 and not list and verbose == 0 and f.patterns.len == 0:
    failIf(rest.len > 2, usageText)
    createBranch(c, rest[0], (if rest.len > 1: rest[1] else: ""),
                 force, quiet, track, trackGiven)
    return 0

  f.patterns.add rest
  listBranches(c, f, kinds, verbose, format)
