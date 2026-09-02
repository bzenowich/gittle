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

const headsPrefix = refsPrefix & "heads/"
  ## Where a branch name lives.  `status` strips it twice: once from HEAD, and
  ## once from the branch a rebase is moving.

func unmergedRow(mask: int): (string, string) =
  ## The short format's two letters and the long format's label for an
  ## unmerged path, looked up together because they are one row of one table.
  ## A mask of 0 cannot reach here -- a path with no stages is not conflicted
  ## -- but the lookup is kept total rather than partial.
  for (m, letters, label) in unmergedTable:
    if m == mask: return (letters, label)
  ("UU", "unmerged:")

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
  if result.branch.startsWith(headsPrefix):
    result.branch = result.branch[headsPrefix.len .. ^1]
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
    let letters = unmergedRow(byPath[i].stagemask)[0]
    (byPath[i].x, byPath[i].y) = (letters[0], letters[1])

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
    let name = repo.readState(rebaseDir / "head-name").strip()
    if name.startsWith(headsPrefix): result.opBranch = name[headsPrefix.len .. ^1]
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
# Rendering: one walk, four formats
# ---------------------------------------------------------------------------
#
# All four formats are the same three things in the same order: a header
# saying where HEAD is, a series of *sections* -- an optional heading and one
# row per path -- and, for the long format, a closing sentence.  So there is
# one renderer, and what the formats disagree about is which of four buckets
# a path lands in and how its row is spelled:
#
# | bucket | long | porcelain v2 | short, porcelain v1 |
# |---|---|---|---|
# | 0 | staged, `modified:  f` | every merged path, `1 …` | *every* path, `XY f` |
# | 1 | unmerged, `both modified:  f` | every unmerged path, `u …` | -- |
# | 2 | unstaged, `modified:  f` | -- | -- |
# | 3 | untracked, `f` | untracked, `? f` | untracked, `?? f` |
#
# Bucket 1 is why porcelain v2 needs one at all: it prints every changed path
# and *then* every unmerged one, which is the only place where a format's
# order is not path order (`wt-status.c:wt_porcelain_v2_print`).  The short
# format has a single bucket because it puts both letters of a path on one
# line and so has nothing to split; the long format has three because it lists
# an `MM` path twice, once as staged and once as not.

const
  sectionHeadings = ["Changes to be committed", "Unmerged paths",
                     "Changes not staged for commit", "Untracked files"]
    ## The long format's heading per bucket
    ## (`wt-status.c:wt_longstatus_print`).  The machine formats print no
    ## headings at all, so they never read this.
  changeLabels = [
    ('A', "new file:"), ('M', "modified:"), ('D', "deleted:"),
    ('T', "typechange:"), ('U', "unmerged:")]
    ## `wt-status.c:wt_status_diff_status_string`.  Padded to a fixed column
    ## below, which is why the table holds the bare word.
  labelWidth = 12

func labelFor(c: char): string =
  ## The long format's label for a change letter, padded to the column.
  for (k, text) in changeLabels:
    if k == c: return text.alignLeft(labelWidth)
  "unknown:".alignLeft(labelWidth)

func dotted(c: char): char =
  ## Porcelain v2 spells "unchanged" as `.` where the short format spells it
  ## as a space, so that every field of a record is non-blank and the record
  ## splits on whitespace.
  if c == ' ': '.' else: c

proc v2Row(e: Entry, path: string): string =
  ## One porcelain-v2 record: space-separated fields with the path last.
  ##
  ## The two record shapes differ only in how many fields of each kind they
  ## carry, which is the whole reason they are one proc.  A `u` record has
  ## *four* modes -- the three stages and the working tree -- and three object
  ## IDs; a `1` record has three modes (HEAD, index, working tree) and two
  ## IDs.  A parser tells them apart by the leading letter, not by counting
  ## (`wt-status.c:wt_porcelain_v2_print_*`).  `N...` is the rename score,
  ## which is always that: gittle detects no renames.
  let u = e.stagemask != 0
  let modes = if u: @(e.stageModes) & @[e.workMode]
              else: @[e.headMode, e.indexMode, e.workMode]
  let oids = if u: @(e.stageOids) else: @[e.headOid, e.indexOid]
  var f = @[(if u: "u" else: "1"), dotted(e.x) & dotted(e.y), "N..."]
  for m in modes: f.add formatMode(m)
  for o in oids: f.add $o
  f.add path
  f.join(" ")

proc trackingLine*(t: Tracking): string =
  ## `Your branch is up to date with 'origin/main'.` and its four siblings.
  ## Printed by `checkout` and `status` alike, which is why it lives here
  ## rather than in either (`wt-status.c:wt_status_print_tracking`).  The
  ## `(use "git pull" …)` lines under each are `advice.statusHints`, cut.
  if t.upstream.len == 0: return ""
  let name = t.upstream
  if t.gone:
    return "Your branch is based on '" & name & "', but the upstream is gone.\n"

  # `1 commit`, `2 commits`.
  proc commits(n: int): string = $n & (if n == 1: " commit" else: " commits")
  if t.ahead == 0 and t.behind == 0:
    "Your branch is up to date with '" & name & "'.\n"
  elif t.behind == 0:
    "Your branch is ahead of '" & name & "' by " & commits(t.ahead) & ".\n"
  elif t.ahead == 0:
    "Your branch is behind '" & name & "' by " & commits(t.behind) &
    ", and can be fast-forwarded.\n"
  else:
    # The plural is decided by the *sum* of the two counts, not by either of
    # them (`remote.c`, the `Q_()` around this string) -- so one commit each
    # way still says "commits".
    "Your branch and '" & name & "' have diverged,\nand have " &
    $t.ahead & " and " & $t.behind & " different commit" &
    (if t.ahead + t.behind == 1: "" else: "s") & " each, respectively.\n"

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
    # A rebase's two halves are one sentence with different words in it, and
    # both pluralise on the same count (`wt-status.c:show_rebase_information`)
    # -- so `$` marks where the `s` goes and the pair is a table.  Two lines
    # of each are shown: the *last* two done, the *next* two to do.
    for (lines, isDone, label, noun) in [
        (st.opDone, true, "Last command$ done", "command$ done"),
        (st.opTodo, false, "Next command$ to do", "remaining command$")]:
      let n = lines.len
      let s = if n == 1: "" else: "s"
      if n == 0:
        result.add "No commands " & (if isDone: "done" else: "remaining") & ".\n"
      else:
        result.add label.replace("$", s) & " (" & $n & " " &
                   noun.replace("$", s) & "):\n"
        let start = if isDone: n - min(2, n) else: 0
        for k in 0 ..< min(2, n): result.add "   " & lines[start + k] & "\n"
    result.add (if st.opBranch.len > 0:
                  "You are currently rebasing branch '" & st.opBranch &
                  "' on '" & st.opOnto & "'.\n"
                else: "You are currently rebasing.\n")
  result.add "\n"

proc header(st: Status, fmt: StatusFormat, branch: bool, sep: string): string =
  ## Where HEAD is, in each format's own words: up to four `# branch.*` lines
  ## for porcelain v2, one `##` line for the short formats, a paragraph for
  ## the long one.  All three say the same four things -- the branch, whether
  ## it is detached or unborn, the upstream, and how far apart the two are --
  ## in prose that shares no bytes with the others, which is why this is a
  ## case and not a table.  The machine formats print it only under `-b`; the
  ## long format always does.
  # `-b` is the machine formats' switch for this whole block; the long format
  # has no such switch and always says where HEAD is.
  if fmt != sfLong and not branch: return
  let t = st.tracking
  case fmt
  of sfPorcelainV2:
    # Built as fields because the last two are omitted *entirely* when there
    # is no upstream: an absent relationship is silence here, not a zero.
    var fields = @[("oid", if st.initial: "(initial)" else: $st.headOid),
                   ("head", if st.detached: "(detached)" else: st.branch)]
    if t.upstream.len > 0:
      fields.add(("upstream", t.upstream))
      if not t.gone: fields.add(("ab", "+" & $t.ahead & " -" & $t.behind))
    for (k, v) in fields: result.add "# branch." & k & " " & v & sep
  of sfShort, sfPorcelainV1:
    if st.detached: result = "## HEAD (no branch)" & sep
    elif st.initial: result = "## No commits yet on " & st.branch & sep
    else:
      # `## main...origin/main [ahead 1, behind 2]`.  The bracket is dropped
      # when the two are level, so the common case is just the two names; a
      # `[gone]` upstream reports no counts, because there is nothing to count
      # against.
      var ab: seq[string]
      if t.gone: ab.add "gone"
      if t.ahead > 0: ab.add "ahead " & $t.ahead
      if t.behind > 0: ab.add "behind " & $t.behind
      result = "## " & st.branch &
               (if t.upstream.len > 0: "..." & t.upstream else: "") &
               (if ab.len > 0: " [" & ab.join(", ") & "]" else: "") & sep
  of sfLong:
    if st.op == opRebase and st.opOnto.len > 0:
      result = "interactive rebase in progress; onto " & st.opOnto & "\n"
    elif st.detached: result = st.headDesc & "\n"
    else:
      result = "On branch " & st.branch & "\n"
      let track = t.trackingLine
      if track.len > 0: result.add track & "\n"
    if st.initial: result.add "\nNo commits yet\n\n"

proc renderStatus*(st: Status, fmt: StatusFormat, untracked: UntrackedMode,
                   prefix: string, branch = false, nulTerm = false): string =
  ## The report, in whichever of the four formats was asked for.
  ##
  ## `prefix` is the directory paths are printed relative to, and `""` prints
  ## them from the repository root.  That is porcelain v1's whole promise --
  ## its output does not depend on where you stood -- and it is the caller's
  ## decision to pass `""`, which is why v1 is nowhere distinguished from `-s`
  ## below.  It is also the one thing that is easy to miss about the wire:
  ## `wt-status.c:wt_porcelain_print` clears `relative_paths` for v1 and the
  ## v2 printer does not, so `--porcelain=v2` from a subdirectory says
  ## `../top.txt` where `--porcelain` says `top.txt`.
  ##
  ## `branch` is `-b`; the long format ignores it and always names the branch.
  let long = fmt == sfLong
  let v2 = fmt == sfPorcelainV2
  let sep = if nulTerm: "\0" else: "\n"

  proc pathField(p: string): string =
    ## A path as a record carries it: relative, and quoted -- except under
    ## `-z`, the one mode with no quoting, because the NUL terminator already
    ## makes every byte unambiguous, which is why `-z` exists.
    let rel = relativeTo(p, prefix)
    if nulTerm: rel else: quotePath(rel)

  var rows: array[4, seq[string]]
  for e in st.entries:
    let p = pathField(e.path)
    let u = e.stagemask != 0
    if v2: rows[ord(u)].add v2Row(e, p)
    elif not long: rows[0].add e.x & e.y & " " & p
    elif u: rows[1].add unmergedRow(e.stagemask)[1].alignLeft(labelWidth + 5) & p
    else:
      if e.x != ' ': rows[0].add labelFor(e.x) & p
      if e.y != ' ': rows[2].add labelFor(e.y) & p
  for p in st.untracked:
    rows[3].add (if long: "" elif v2: "? " else: "?? ") & pathField(p)

  result = header(st, fmt, branch, sep)
  if long: result.add inProgressBlock(st, rows[1].len > 0)
  for i, group in rows:
    if group.len == 0: continue
    # A long-format section is a heading, tab-indented rows and a blank line;
    # a machine-format one is the rows and nothing else.
    if long: result.add sectionHeadings[i] & ":\n"
    for line in group: result.add (if long: "\t" & line & "\n" else: line & sep)
    if long: result.add "\n"
  if not long: return

  # The closing sentence, which is about what was *not* printed above.
  if untracked == umNo and rows[0].len > 0:
    result.add "Untracked files not listed\n"
  if rows[0].len == 0:
    result.add (
      if rows[1].len > 0 or rows[2].len > 0: "no changes added to commit\n"
      elif st.untracked.len > 0: "nothing added to commit but untracked files present\n"
      elif st.initial or untracked == umNo: "nothing to commit\n"
      else: "nothing to commit, working tree clean\n")

proc longStatus*(st: Status, untracked: UntrackedMode, prefix: string): string =
  ## The long format alone, for `commit` and `stash` to paste into the editor
  ## template as commented-out lines.  `status` calls `renderStatus` directly.
  renderStatus(st, sfLong, untracked, prefix)
