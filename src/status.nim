## `status`: what is different, in four output formats.
##
## The computation is two diffs and a walk, and nothing else:
##
## | | |
## |---|---|
## | **staged** | HEAD's tree against the index -- what a commit would record |
## | **unstaged** | the index against the working tree -- what a commit would miss |
## | **untracked** | the working tree against the index, minus the ignore rules |
##
## Both diffs come from `diffcore.nim` and the walk from `dir.nim`, so this
## module is entirely about *presentation*.  That is the right shape for it:
## plan.md §2 observes that a third of git is the command layer, and `status`
## is the clearest example -- one pair of status letters per path, rendered
## four different ways.
##
## ## The two letters
##
## Every path gets `XY`: `X` is what the index has done to it since HEAD and
## `Y` what the working tree has done to it since the index.  A dot or a space
## means "nothing".  So ` M` is edited but not staged, `M ` is staged and
## unedited since, and `MM` is staged and then edited again -- which is the
## one people are surprised by, and the reason two letters exist at all.
##
## ## Untracked directories
##
## With the default `-u normal`, git reports a whole directory as `dir/`
## rather than listing what is in it, but only when the directory contains
## nothing *tracked*.  That is what keeps a new source tree from filling the
## screen while still showing a new file dropped next to tracked ones.
## `-u all` lists every file; `-u no` lists none.
##
## ## Unmerged paths
##
## A conflicted path is neither staged nor unstaged: it has no stage-0 entry
## for either diff to see, so both of them skip it and it is collected
## separately, straight out of the index.  Which of the three stages exist is
## the whole content of the report -- `DU` is "deleted by us", meaning stages
## 1 and 3 but no 2 -- so the seven combinations are a table indexed by that
## bitmask (`wt-status.c:wt_shortstatus_unmerged`).
##
## ## What is deliberately not here
##
## `--ignored` (docs/08 cuts it), submodule summaries, and `bisect` and `am`,
## whose in-progress states have no command behind them in gittle.

import std/[algorithm, os, sets, strutils]
import diffcore, dir, ignore, index, objects, pathspec, refs, repository,
       revision, revwalk, sequencer, util

type
  Tracking* = object
    ## Where a branch stands against its configured upstream.  All four
    ## `status` formats report it, and so does `checkout` after a switch, so
    ## it is computed once and rendered four ways.
    upstream*: string   ## the short name, or "" when none is configured
    gone*: bool         ## configured, but the remote-tracking ref is absent
    ahead*, behind*: int

  UntrackedMode* = enum
    umNo, umNormal, umAll

  StatusFormat* = enum
    sfLong, sfShort, sfPorcelainV1, sfPorcelainV2

  Entry* = object
    path*: string
    x*, y*: char            ## index-vs-HEAD, worktree-vs-index; ' ' is "same"
    headMode*, indexMode*, workMode*: uint32
    headOid*, indexOid*: Oid
    stagemask*: int         ## bit s-1 set when stage s exists; 0 when merged
    stageModes*: array[3, uint32]
    stageOids*: array[3, Oid]

  Status* = object
    entries*: seq[Entry]
    untracked*: seq[string]
    branch*: string         ## the branch HEAD names, without `refs/heads/`
    detached*: bool
    headDesc*: string       ## `HEAD detached at v1.0`, when it is detached
    tracking*: Tracking     ## where the branch stands against its upstream
    headOid*: Oid
    initial*: bool          ## HEAD points at a branch with no commits yet
    op*: Operation          ## what the repository is in the middle of
    opHead*: string         ## the commit being picked or reverted, abbreviated
    opBranch*, opOnto*: string   ## what a rebase is moving, and onto what
    opDone*, opTodo*: seq[string]  ## a rebase's todo list, either side of now

const unmergedTable = [
  (1, "DD", "both deleted:"),    (2, "AU", "added by us:"),
  (3, "UD", "deleted by them:"), (4, "UA", "added by them:"),
  (5, "DU", "deleted by us:"),   (6, "AA", "both added:"),
  (7, "UU", "both modified:")]
  ## Which stages exist, as a bitmask, and how the short and long formats name
  ## it (`wt-status.c:wt_shortstatus_unmerged` and
  ## `wt_status_unmerged_status_string`).  Stage 1 is the base, 2 ours, 3
  ## theirs, so mask 3 is "we have it, they deleted it".

func unmergedLetters(mask: int): (char, char) =
  ## The two columns of the short format for an unmerged path, from its
  ## stage mask.
  for (m, letters, _) in unmergedTable:
    if m == mask: return (letters[0], letters[1])
  ('U', 'U')

func unmergedLabel(mask: int): string =
  ## The long format's label for an unmerged path, from its stage mask.
  for (m, _, label) in unmergedTable:
    if m == mask: return label
  "unmerged:"

proc hasTrackedUnder(idx: Index, dir: string): bool =
  ## Does the index hold anything inside this directory?
  ##
  ## Binary search for where `dir/` would sort and look at what is there: the
  ## index is sorted by path bytes, so everything under a directory is one
  ## contiguous run beginning at that point.
  let pre = dir & "/"
  var lo = 0
  var hi = idx.entries.len
  while lo < hi:
    let mid = (lo + hi) div 2
    if idx.entries[mid].path < pre: lo = mid + 1
    else: hi = mid
  lo < idx.entries.len and idx.entries[lo].path.startsWith(pre)

proc collapseUntracked(idx: Index, paths: seq[string]): seq[string] =
  ## `-u normal`: replace the contents of a wholly-untracked directory with
  ## the directory itself.
  ##
  ## The rule is the *shallowest* directory containing nothing tracked, so a
  ## brand-new `a/b/c/d.txt` collapses all the way to `a/`.  A directory that
  ## also holds a tracked file is left alone and its untracked files are
  ## listed one by one.
  var seen: seq[string]
  for p in paths:
    # The walk already collapsed a nested repository to `name/`; there is
    # nothing above it that could be collapsed further.
    if p.endsWith("/"):
      if seen.len == 0 or seen[^1] != p: seen.add p
      continue
    var cut = -1
    var at = p.find('/')
    while at >= 0:
      if not idx.hasTrackedUnder(p[0 ..< at]):
        cut = at
        break
      at = p.find('/', at + 1)
    let name = if cut >= 0: p[0 .. cut] else: p
    if seen.len == 0 or seen[^1] != name: seen.add name
  seen

proc trackingOf*(repo: Repository, branch: string): Tracking =
  ## Two reachability counts, which is why nothing asks for this twice.
  let up = repo.upstreamRef(branch)
  if up.len == 0: return
  result.upstream = repo.refs.shortenRef(up)
  let here = repo.refs.resolveRef(branch)
  let there = repo.refs.resolveRef(up)
  if not there.found:
    result.gone = true
  elif here.found:
    result.ahead = repo.countRange(here.oid, there.oid)
    result.behind = repo.countRange(there.oid, here.oid)

proc computeStatus*(repo: Repository, idx: Index, ps: Pathspec,
                    untracked: UntrackedMode): Status =
  ## The whole model, in the order the two letters are defined.
  let h = repo.refs.resolveRef(headRef)
  result.branch = repo.headRefName
  const heads = refsPrefix & "heads/"
  if result.branch.startsWith(heads):
    result.branch = result.branch[heads.len .. ^1]
  else:
    result.detached = true
    result.headDesc = headDescription(repo)
  result.initial = not h.found
  if h.found: result.headOid = h.oid

  result.tracking = repo.trackingOf(repo.headRefName)

  let headTree = if h.found: repo.peelTo(h.oid, otTree).oid else: nullOid

  # The conflicted paths, first: an unmerged path has no stage-0 entry, so the
  # HEAD-to-index diff would otherwise report every one of them as *deleted*.
  # Which stages exist is the whole report, and it comes straight out of the
  # index.
  var byPath: seq[Entry]
  var conflicted: HashSet[string]
  var u: Entry
  for e in idx.entries:
    if e.stage == 0 or not ps.matches(e.path): continue
    if e.path != u.path or u.stagemask == 0:
      if u.stagemask != 0: byPath.add u
      u = Entry(path: e.path)
      conflicted.incl e.path
      let (ok, st) = statPath(repo.workTreePath(e.path))
      if ok: u.workMode = modeForFile(st)
    u.stagemask = u.stagemask or (1 shl (e.stage - 1))
    u.stageModes[e.stage - 1] = canonMode(e.mode)
    u.stageOids[e.stage - 1] = e.oid
  if u.stagemask != 0: byPath.add u
  for i in 0 ..< byPath.len:
    (byPath[i].x, byPath[i].y) = unmergedLetters(byPath[i].stagemask)

  # An entry is indexed by path so the two diffs can meet in it: a path may
  # appear in both, and `MM` is exactly that case.
  proc slot(path: string): int =
    for i, e in byPath:
      if e.path == path: return i
    byPath.add Entry(path: path, x: ' ', y: ' ')
    byPath.high

  for p in pairsTreeIndex(repo, headTree, idx, ps):
    if p.path in conflicted or not repo.changed(p): continue
    let i = slot(p.path)
    byPath[i].x = p.status
    byPath[i].headMode = p.oldMode
    byPath[i].indexMode = p.newMode
    byPath[i].headOid = p.oldOid
    byPath[i].indexOid = p.newOid

  # Every staged path also has a working-tree mode, which is the index's
  # unless the unstaged pass below says otherwise.  Porcelain v2 prints all
  # three modes, and `000000` there would claim the file is gone.
  for i in 0 ..< byPath.len:
    if byPath[i].stagemask == 0: byPath[i].workMode = byPath[i].indexMode

  for p in pairsIndexWork(repo, idx, ps):
    if p.path in conflicted or not repo.changed(p): continue
    let i = slot(p.path)
    byPath[i].y = p.status
    byPath[i].workMode = p.newMode
    if byPath[i].x == ' ':
      # Not staged, so HEAD and the index agree and the pair we have describes
      # the index side; the HEAD side is the same.
      byPath[i].headMode = p.oldMode
      byPath[i].indexMode = p.oldMode
      byPath[i].headOid = p.oldOid
      byPath[i].indexOid = p.oldOid

  byPath.sort(proc (a, b: Entry): int = cmp(a.path, b.path))
  result.entries = byPath

  result.op = repo.currentOp
  case result.op
  of opCherryPick, opRevert:
    let o = repo.stateOid(if result.op == opCherryPick: "CHERRY_PICK_HEAD"
                          else: "REVERT_HEAD")
    result.opHead = repo.uniqueAbbrev(o, repo.autoAbbrev)
  of opRebase:
    const heads = refsPrefix & "heads/"
    let name = repo.readState(rebaseDir / "head-name").strip()
    if name.startsWith(heads): result.opBranch = name[heads.len .. ^1]
    let onto = repo.readState(rebaseDir / "onto").strip()
    if onto.len == OidHexLen:
      result.opOnto = repo.uniqueAbbrev(parseOid(onto), repo.autoAbbrev)
    # The todo lines are re-rendered with an abbreviated object ID, because
    # the file holds the full one and the report is for a human
    # (`wt-status.c:read_rebase_todolist` calls `format_todo_line`).
    proc shorten(lines: seq[string]): seq[string] =
      for line in lines:
        let f = line.splitWhitespace
        if f.len < 2: continue
        result.add f[0] & " " & repo.uniqueAbbrev(parseOid(f[1]), repo.autoAbbrev) &
                   (if f.len > 2: " " & f[2 .. ^1].join(" ") else: "")
    var doneLines, todoLines: seq[string]
    for line in repo.readState(rebaseDir / "done").splitLines:
      if line.strip().len > 0: doneLines.add line
    for line in repo.readState(rebaseDir / "git-rebase-todo").splitLines:
      if line.strip().len > 0: todoLines.add line
    result.opDone = shorten(doneLines)
    result.opTodo = shorten(todoLines)
  else: discard

  if untracked != umNo:
    let ig = newIgnore(repo)
    let found = walkWorkTree(repo, idx, ig, ps)
    result.untracked = if untracked == umAll: found
                       else: collapseUntracked(idx, found)

# ---------------------------------------------------------------------------
# The short and porcelain formats
# ---------------------------------------------------------------------------

proc shortLines*(st: Status, fmt: StatusFormat, branch: bool, nulTerm: bool,
                 relative: bool, prefix: string): string =
  ## `-s`, `--porcelain` and `--porcelain=v2`, which differ in three things:
  ## how the branch header is spelled, whether the per-path record carries
  ## modes and object IDs, and whether an untracked path is `??` or `?`.
  ##
  ## And in a fourth thing that is easy to miss: **porcelain v1 is the only
  ## format with root-relative paths.**  `wt-status.c:wt_porcelain_print`
  ## clears `relative_paths` for v1 and the v2 printer does not, so
  ## `--porcelain=v2` from a subdirectory says `../top.txt` where
  ## `--porcelain` says `top.txt`.  Surprising, and it is the wire.
  let sep = if nulTerm: "\0" else: "\n"

  proc name(p: string): string =
    ## A path as the short formats print it: relative or not, quoted or not.
    # `-z` is the one mode with no quoting: the terminator already makes every
    # byte unambiguous, which is why it exists.
    let rel = if relative: relativeTo(p, prefix) else: p
    if nulTerm: rel else: quotePath(rel)

  if branch:
    if fmt == sfPorcelainV2:
      result.add "# branch.oid " &
                 (if st.initial: "(initial)" else: $st.headOid) & sep
      result.add "# branch.head " &
                 (if st.detached: "(detached)" else: st.branch) & sep
      # Both lines are omitted entirely when there is no upstream: an absent
      # relationship is silence, not a zero.
      if st.tracking.upstream.len > 0:
        result.add "# branch.upstream " & st.tracking.upstream & sep
        if not st.tracking.gone:
          result.add "# branch.ab +" & $st.tracking.ahead & " -" &
                     $st.tracking.behind & sep
    else:
      if st.detached: result.add "## HEAD (no branch)" & sep
      elif st.initial: result.add "## No commits yet on " & st.branch & sep
      else:
        # `## main...origin/main [ahead 1, behind 2]`.  The counts are omitted
        # when the two are level, so the common case is just the two names.
        result.add "## " & st.branch
        if st.tracking.upstream.len > 0:
          result.add "..." & st.tracking.upstream
          if st.tracking.ahead > 0 or st.tracking.behind > 0:
            result.add " ["
            if st.tracking.ahead > 0: result.add "ahead " & $st.tracking.ahead
            if st.tracking.ahead > 0 and st.tracking.behind > 0: result.add ", "
            if st.tracking.behind > 0: result.add "behind " & $st.tracking.behind
            result.add "]"
          elif st.tracking.gone: result.add " [gone]"
        result.add sep

  # Porcelain v2 prints every changed entry and *then* every unmerged one --
  # two passes rather than one path-sorted list, which is the only place where
  # a format's order is not path order
  # (`wt-status.c:wt_porcelain_v2_print`).  Every other format interleaves.
  let passes = if fmt == sfPorcelainV2: 1 else: 0
  for pass in 0 .. passes:
    for e in st.entries:
      if passes == 1 and (e.stagemask != 0) != (pass == 1): continue
      if fmt != sfPorcelainV2:
        result.add e.x & e.y & " " & name(e.path) & sep
      elif e.stagemask != 0:
        # The `u` record carries *four* modes -- the three stages and the
        # working tree -- and three object IDs, where the `1` record carries
        # three modes and two IDs.  A parser tells them apart by the leading
        # letter, not by counting.
        result.add "u " & e.x & e.y & " N... "
        for m in e.stageModes: result.add formatMode(m) & " "
        result.add formatMode(e.workMode) & " "
        for o in e.stageOids: result.add $o & " "
        result.add name(e.path) & sep
      else:
        # Porcelain v2 spells "unchanged" as `.` where the short format spells
        # it as a space, so that every field is non-blank and the record
        # splits on whitespace.
        let x = if e.x == ' ': '.' else: e.x
        let y = if e.y == ' ': '.' else: e.y
        result.add "1 " & x & y & " N... " &
                   formatMode(e.headMode) & " " & formatMode(e.indexMode) &
                   " " & formatMode(e.workMode) & " " &
                   $e.headOid & " " & $e.indexOid & " " & name(e.path) & sep

  for p in st.untracked:
    result.add (if fmt == sfPorcelainV2: "? " else: "?? ") & name(p) & sep

# ---------------------------------------------------------------------------
# The long format
# ---------------------------------------------------------------------------

const
  changeLabels = [
    ('A', "new file:"), ('M', "modified:"), ('D', "deleted:"),
    ('T', "typechange:"), ('U', "unmerged:")]
    ## `wt-status.c:wt_status_diff_status_string`.  Padded to a fixed column
    ## below, which is why the table holds the bare word.
  labelWidth = 12

proc labelFor(c: char): string =
  ## The long format's label for a change letter, padded to the column.
  for (k, text) in changeLabels:
    if k == c: return text.alignLeft(labelWidth)
  "unknown:".alignLeft(labelWidth)

proc trackingLine*(t: Tracking): string =
  ## `Your branch is up to date with 'origin/main'.` and its three siblings.
  ## Printed by `checkout` and `status` alike, which is why it lives here
  ## rather than in either (`wt-status.c:wt_status_print_tracking`).  The
  ## `(use "git pull" …)` lines under each are `advice.statusHints`, cut.
  if t.upstream.len == 0: return ""
  let name = t.upstream
  if t.gone:
    return "Your branch is based on '" & name & "', but the upstream is gone.\n"
  let ahead = t.ahead
  let behind = t.behind

  # `1 commit`, `2 commits`.
  proc commits(n: int): string = $n & (if n == 1: " commit" else: " commits")
  if ahead == 0 and behind == 0:
    "Your branch is up to date with '" & name & "'.\n"
  elif behind == 0:
    "Your branch is ahead of '" & name & "' by " & commits(ahead) & ".\n"
  elif ahead == 0:
    "Your branch is behind '" & name & "' by " & commits(behind) &
    ", and can be fast-forwarded.\n"
  else:
    # The plural is decided by the *sum* of the two counts, not by either of
    # them (`remote.c`, the `Q_()` around this string) -- so one commit each
    # way still says "commits".
    "Your branch and '" & name & "' have diverged,\nand have " &
    $ahead & " and " & $behind & " different commit" &
    (if ahead + behind == 1: "" else: "s") & " each, respectively.\n"

proc inProgressBlock(st: Status, unmerged: bool): string =
  ## "You have unmerged paths." and its four siblings: which operation is in
  ## progress, and where it stands (`wt-status.c:wt_longstatus_print_state`).
  case st.op
  of opNone: return ""
  of opMerge:
    result = if unmerged: "You have unmerged paths.\n"
             else: "All conflicts fixed but you are still merging.\n"
  of opCherryPick, opRevert:
    let noun = if st.op == opCherryPick: "cherry-picking" else: "reverting"
    result = "You are currently " & noun & " commit " & st.opHead & ".\n"
  of opRebase:
    func plural(n: int, one, many: string): string =
      ## `1 command` / `2 commands`.
      $n & " " & (if n == 1: one else: many)
    if st.opDone.len == 0: result.add "No commands done.\n"
    else:
      result.add "Last command" & (if st.opDone.len == 1: "" else: "s") &
                 " done (" & plural(st.opDone.len, "command", "commands") &
                 " done):\n"
      for k in max(st.opDone.len - 2, 0) ..< st.opDone.len:
        result.add "   " & st.opDone[k] & "\n"
    if st.opTodo.len == 0: result.add "No commands remaining.\n"
    else:
      result.add "Next command" & (if st.opTodo.len == 1: "" else: "s") &
                 " to do (" & plural(st.opTodo.len, "remaining command",
                                     "remaining commands") & "):\n"
      for k in 0 ..< min(2, st.opTodo.len):
        result.add "   " & st.opTodo[k] & "\n"
    result.add (if st.opBranch.len > 0:
                "You are currently rebasing branch '" & st.opBranch & "' on '" &
                st.opOnto & "'.\n"
              else: "You are currently rebasing.\n")
  result.add "\n"

proc longStatus*(st: Status, untracked: UntrackedMode, prefix: string): string =
  ## The default format.  It is git's own with `advice.statusHints=false`:
  ## the 26 parenthesised `(use "git …")` hints and the two decision trees
  ## that chose between them went in the minimization pass (docs/minimize.md
  ## §3, tier 3) -- the headings say what state a path is in, which is the
  ## information, and the oracle compares against git with hints off.
  var staged, unstaged, unmerged: seq[Entry]
  for e in st.entries:
    if e.stagemask != 0: unmerged.add e
    else:
      if e.x != ' ': staged.add e
      if e.y != ' ': unstaged.add e
  if st.op == opRebase and st.opOnto.len > 0:
    result.add "interactive rebase in progress; onto " & st.opOnto & "\n"
  elif st.detached:
    result.add st.headDesc & "\n"
  else:
    result.add "On branch " & st.branch & "\n"
    let track = st.tracking.trackingLine
    if track.len > 0: result.add track & "\n"
  if st.initial:
    result.add "\nNo commits yet\n\n"
  result.add inProgressBlock(st, unmerged.len > 0)
  proc section(title: string, lines: seq[string]): string =
    ## One block of the long format: a heading, then one tab-indented line
    ## per path, then a blank line; nothing when there are no paths.
    if lines.len == 0: return
    result = title & ":\n"
    for l in lines: result.add "\t" & l & "\n"
    result.add "\n"
  var rows: seq[string]
  for e in staged: rows.add labelFor(e.x) & quotePath(relativeTo(e.path, prefix))
  result.add section("Changes to be committed", rows)
  rows = @[]
  for e in unmerged:
    rows.add unmergedLabel(e.stagemask).alignLeft(labelWidth + 5) &
             quotePath(relativeTo(e.path, prefix))
  result.add section("Unmerged paths", rows)
  rows = @[]
  for e in unstaged: rows.add labelFor(e.y) & quotePath(relativeTo(e.path, prefix))
  result.add section("Changes not staged for commit", rows)
  rows = @[]
  for p in st.untracked: rows.add quotePath(relativeTo(p, prefix))
  result.add section("Untracked files", rows)
  if untracked == umNo and staged.len > 0:
    result.add "Untracked files not listed\n"
  if staged.len == 0:
    result.add (
      if unstaged.len > 0 or unmerged.len > 0: "no changes added to commit\n"
      elif st.untracked.len > 0: "nothing added to commit but untracked files present\n"
      elif st.initial or untracked == umNo: "nothing to commit\n"
      else: "nothing to commit, working tree clean\n")
