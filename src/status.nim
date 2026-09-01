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
## ## What is deliberately not here
##
## The in-progress states -- merge, rebase, cherry-pick, revert, bisect --
## are 400 lines of `wt-status.c` on their own and every one of them belongs
## to a command gittle has not built yet.  They arrive in phase 7.  Likewise
## `--ignored` (docs/08 cuts it), submodule summaries, and the upstream
## ahead/behind counts, which need a remote (phase 8).

import std/[algorithm, strutils]
import diffcore, dir, ignore, index, objects, pathspec, repository, util

type
  UntrackedMode* = enum
    umNo, umNormal, umAll

  StatusFormat* = enum
    sfLong, sfShort, sfPorcelainV1, sfPorcelainV2

  Entry* = object
    path*: string
    x*, y*: char            ## index-vs-HEAD, worktree-vs-index; ' ' is "same"
    headMode*, indexMode*, workMode*: uint32
    headOid*, indexOid*: Oid

  Status* = object
    entries*: seq[Entry]
    untracked*: seq[string]
    branch*: string         ## the branch HEAD names, without `refs/heads/`
    detached*: bool
    headOid*: Oid
    initial*: bool          ## HEAD points at a branch with no commits yet

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
  result.initial = not h.found
  if h.found: result.headOid = h.oid

  let headTree = if h.found: repo.peelTo(h.oid, otTree).oid else: nullOid

  # An entry is indexed by path so the two diffs can meet in it: a path may
  # appear in both, and `MM` is exactly that case.
  var byPath: seq[Entry]
  proc slot(path: string): int =
    for i, e in byPath:
      if e.path == path: return i
    byPath.add Entry(path: path, x: ' ', y: ' ')
    byPath.high

  for p in pairsTreeIndex(repo, headTree, idx, ps):
    if not repo.changed(p): continue
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
    byPath[i].workMode = byPath[i].indexMode

  for p in pairsIndexWork(repo, idx, ps):
    if not repo.changed(p): continue
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
      # `# branch.upstream` and `# branch.ab` need a configured remote-tracking
      # branch, which is phase 8.  git omits both when there is none, so an
      # absent upstream is silence rather than a divergence.
    else:
      if st.detached: result.add "## HEAD (no branch)" & sep
      elif st.initial: result.add "## No commits yet on " & st.branch & sep
      else: result.add "## " & st.branch & sep

  for e in st.entries:
    if fmt == sfPorcelainV2:
      # Porcelain v2 spells "unchanged" as `.` where the short format spells
      # it as a space, so that every field is non-blank and the record splits
      # on whitespace.
      let x = if e.x == ' ': '.' else: e.x
      let y = if e.y == ' ': '.' else: e.y
      result.add "1 " & x & y & " N... " &
                 formatMode(e.headMode) & " " & formatMode(e.indexMode) & " " &
                 formatMode(e.workMode) & " " &
                 $e.headOid & " " & $e.indexOid & " " & name(e.path) & sep
    else:
      result.add e.x & e.y & " " & name(e.path) & sep

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
  for (k, text) in changeLabels:
    if k == c: return text.alignLeft(labelWidth)
  "unknown:".alignLeft(labelWidth)

proc longStatus*(st: Status, untracked: UntrackedMode, hints: bool,
                 prefix: string): string =
  ## The descriptive format, which is the default and is the only one whose
  ## text is not machine-readable -- so every string in it is git's, verbatim
  ## (`wt-status.c:wt_longstatus_print`).
  ##
  ## The hints in parentheses are not decoration: which one appears reports
  ## something real.  "use git rm --cached" rather than "git restore --staged"
  ## means there is no commit to restore *from*, and "git add/rm" rather than
  ## "git add" means a file has been deleted and `add` alone would not record
  ## it.
  var staged, unstaged: seq[Entry]
  var anyDeleted = false
  for e in st.entries:
    if e.x != ' ': staged.add e
    if e.y != ' ':
      unstaged.add e
      if e.y == 'D': anyDeleted = true

  if st.detached:
    result.add "HEAD detached at " & ($st.headOid)[0 ..< 7] & "\n"
  else:
    result.add "On branch " & st.branch & "\n"
  # Sections are separated by a blank line *after* each one, so the first
  # follows `On branch …` directly and the last leaves a trailing blank.
  if st.initial:
    result.add "\nNo commits yet\n\n"

  if staged.len > 0:
    result.add "Changes to be committed:\n"
    if hints:
      result.add (if st.initial:
                    "  (use \"git rm --cached <file>...\" to unstage)\n"
                  else:
                    "  (use \"git restore --staged <file>...\" to unstage)\n")
    for e in staged:
      result.add "\t" & labelFor(e.x) & quotePath(relativeTo(e.path, prefix)) & "\n"
    result.add "\n"

  if unstaged.len > 0:
    result.add "Changes not staged for commit:\n"
    if hints:
      result.add (if anyDeleted:
                    "  (use \"git add/rm <file>...\" to update what will be committed)\n"
                  else:
                    "  (use \"git add <file>...\" to update what will be committed)\n")
      result.add "  (use \"git restore <file>...\" to discard changes in working directory)\n"
    for e in unstaged:
      result.add "\t" & labelFor(e.y) & quotePath(relativeTo(e.path, prefix)) & "\n"
    result.add "\n"

  if st.untracked.len > 0:
    result.add "Untracked files:\n"
    if hints:
      result.add "  (use \"git add <file>...\" to include in what will be committed)\n"
    for p in st.untracked:
      result.add "\t" & quotePath(relativeTo(p, prefix)) & "\n"
    result.add "\n"

  # git mentions the suppressed untracked files only when there is something
  # to commit -- otherwise the footer below already says what the state is
  # (`wt-status.c`: the `else if (s->committable)` branch).
  if untracked == umNo and staged.len > 0:
    result.add "Untracked files not listed"
    result.add (if hints: " (use -u option to show untracked files)\n" else: "\n")

  # The footer, in git's order of precedence: what you would have to do next
  # decides which sentence appears (`wt-status.c`, the `!s->committable` block).
  if staged.len == 0:
    result.add (
      if unstaged.len > 0:
        if hints: "no changes added to commit (use \"git add\" and/or \"git commit -a\")\n"
        else: "no changes added to commit\n"
      elif st.untracked.len > 0:
        if hints: "nothing added to commit but untracked files present (use \"git add\" to track)\n"
        else: "nothing added to commit but untracked files present\n"
      elif st.initial:
        if hints: "nothing to commit (create/copy files and use \"git add\" to track)\n"
        else: "nothing to commit\n"
      elif untracked == umNo:
        if hints: "nothing to commit (use -u to show untracked files)\n"
        else: "nothing to commit\n"
      else: "nothing to commit, working tree clean\n")
