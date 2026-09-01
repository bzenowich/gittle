## `log` -- show commit history.
##
## Phase 4 landed the walk and the formatting; phase 5 adds the diff and the
## limiting patterns.  One group is still deferred:
##
## * **revision ranges** (`A..B`, `^A`, `--all`, `--branches`) and the
##   traversal orders (`--topo-order`, `--since`) -- phase 6, with `rev-list`
##   and `rev-parse`, where that whole option surface belongs.
##
## It refuses by name.  A `log` that silently ignored an option would answer a
## different question from the one asked, and look like it had answered.
##
## ## What separates a commit from its diff
##
## One blank line, unless the format is `oneline`, in which case none
## (`log-tree.c:log_tree_diff_flush`).  And when `--stat` and `-p` are asked
## for *together*, a `---` goes on that line -- which is the only place in
## git's output where the two formats interact.
##
## **A merge commit gets no diff at all.**  The combined-diff formats (`-c`,
## `--cc`) are cut in docs/03, and `--diff-merges=off` -- what git did by
## default before 1.5 -- is the behavior that leaves.
##
## ## Telling a revision from a path
##
## `gittle log foo` is ambiguous, and git resolves it by trying: if `foo` names
## an object it is a revision, otherwise if it is a file it is a path,
## otherwise it is an error naming both possibilities.  `--` settles it, which
## is why scripts should use it and why the error message says so.

import std/[os, strutils, times]
import ../cli, ../commitobj, ../diffcore, ../ident, ../pathspec, ../pretty,
       ../regex, ../repository, ../revwalk, ../util

const usageText = """usage: gittle log [<options>] [<commit>…] [[--] <path>…]

   -n <n>, --max-count=<n>   stop after <n> commits
   --skip=<n>                skip the first <n>
   --reverse                 oldest first
   --first-parent            follow only the first parent of a merge
   --no-walk                 show the named commits only
   --parents                 also print each commit's parents
   --oneline                 one line each, abbreviated
   --pretty=<fmt>            oneline|medium|full|fuller|raw|format:…|tformat:…
   --format=<fmt>            same as --pretty=<fmt>
   --abbrev-commit           abbreviate object names
   --abbrev=<n>              use at least <n> digits
   --date=<fmt>              default|relative|iso8601|rfc2822|short|raw|unix|
                             human|iso8601-strict|format:<strftime>
   --decorate[=short|full|auto|no]
   --grep=<pat>              limit to commits whose message matches
   --author=<pat>, --committer=<pat>
   -i, -E, -F, --all-match, --invert-grep
   -p, --stat, --numstat, --shortstat, --raw, --name-only, --name-status,
   -U<n>, -w, -b, --diff-filter, -S<string>, --color …  -- see `gittle diff`"""

type Limiters = object
  ## `--grep`, `--author` and `--committer`, and how they combine.
  ##
  ## Measured against git rather than read off the manual (R8): patterns of
  ## **different kinds are AND-ed** -- `--author=A --committer=B` selects
  ## commits matching both, and matches nothing when nobody is both -- while
  ## repeated patterns of the *same* kind are OR-ed, unless `--all-match`
  ## turns the message group into an AND as well.  `--invert-grep` inverts the
  ## message group only, and leaves the identity groups alone.
  grep, author, committer: seq[Regex]
  allMatch, invertGrep: bool

proc anyMatch(pats: seq[Regex], s: string): bool =
  for p in pats:
    if p.matches(s): return true
  false

proc allMatchOf(pats: seq[Regex], s: string): bool =
  for p in pats:
    if not p.matches(s): return false
  true

proc selects(l: Limiters, c: Commit): bool =
  ## The identity a pattern is matched against is `Name <email>`, which is the
  ## `author` header with its timestamp removed (`grep.c:strip_timestamp`).
  if l.author.len > 0 and
     not anyMatch(l.author, c.author.name & " <" & c.author.email & ">"):
    return false
  if l.committer.len > 0 and
     not anyMatch(l.committer, c.committer.name & " <" & c.committer.email & ">"):
    return false
  if l.grep.len > 0:
    let hit = if l.allMatch: allMatchOf(l.grep, c.message)
              else: anyMatch(l.grep, c.message)
    if hit == l.invertGrep: return false
  true

const deferred: array[2, (string, seq[string])] = [
  ("out of scope for gittle v1 (docs/04)", @[
    "--full-diff", "--follow", "--graph"]),
  ("phase 6, with rev-list and rev-parse", @[
    "--all", "--branches", "--tags", "--remotes", "--not", "--stdin",
    "--topo-order", "--date-order", "--since", "--after", "--until",
    "--before", "--merges", "--no-merges", "--min-parents", "--max-parents",
    "--ancestry-path", "--objects", "--left-right", "--cherry-pick",
    "--boundary", "--simplify-by-decoration", "--count"])]
    ## What `log` does not do yet, as a table, so that each refuses by name
    ## with the phase that brings it.  Silently ignoring an option answers a
    ## different question from the one asked, and looks like it answered.

proc checkDeferred(a: string) =
  let name = if a.contains('='): a[0 ..< a.find('=')] else: a
  for (why, names) in deferred:
    for n in names:
      if n == name:
        fail(a & " is not implemented in this version\n  it is " & why)

proc cmdLog*(c: Ctx, args: seq[string]): int =
  var opts = PrettyOpts(kind: pkMedium, now: getTime().toUnix())
  var maxCount = -1
  var skip = 0
  var reverse = false
  var noWalk = false
  var decorateMode = "auto"
  var firstParent = false
  var abbrevLen = 0
  var dopts = defaultDiffOpts()
  var lim = Limiters()
  var greps, authors, committers: seq[string]
  var icase = false
  var fixed = false
  var revs: seq[string]
  var specs: seq[string]
  var i = 0
  var seenDashDash = false

  proc valueFor(a: string): string =
    ## `--opt=v`, `--opt v` and `-nV` all reach here.
    let eq = a.find('=')
    if eq > 0: return a[eq + 1 .. ^1]
    inc i
    failIf(i >= args.len, "option '" & a & "' requires a value")
    args[i]

  while i < args.len:
    let a = args[i]
    if seenDashDash:
      specs.add a
    elif a == "--":
      seenDashDash = true
    elif a.len > 1 and a[0] == '-':
      checkDeferred(a)
      if a == "--reverse": reverse = true
      elif a == "--first-parent": firstParent = true
      elif a == "--parents": opts.showParents = true
      elif a == "--oneline":
        opts.kind = pkOneline
        opts.abbrevCommit = true
      elif a == "--abbrev-commit": opts.abbrevCommit = true
      elif a == "--no-abbrev-commit": opts.abbrevCommit = false
      elif a == "--relative-date": opts.dateMode = DateMode(kind: dkRelative)
      elif a == "--no-decorate": decorateMode = "no"
      elif a == "--no-walk" or a.startsWith("--no-walk="): noWalk = true
      elif a == "-n" or a.startsWith("--max-count"): maxCount = parseInt(valueFor(a))
      elif a.len > 2 and a[1] == 'n' and a[2] in {'0' .. '9'}:
        maxCount = parseInt(a[2 .. ^1])       # `-n5`, which git also accepts
      elif a.startsWith("--skip"): skip = parseInt(valueFor(a))
      elif a.startsWith("--abbrev"): abbrevLen = parseInt(valueFor(a))
      elif a.startsWith("--date"): opts.dateMode = parseDateMode(valueFor(a))
      elif a.startsWith("--decorate"):
        decorateMode = if a.contains('='): a[a.find('=') + 1 .. ^1] else: "short"
      elif a.startsWith("--pretty") or a.startsWith("--format"):
        parsePretty((if a.contains('='): a[a.find('=') + 1 .. ^1] else: ""), opts)
      elif a == "-h" or a == "--help":
        echo usageText
        return 0
      elif a.startsWith("--grep"): greps.add valueFor(a)
      elif a.startsWith("--author"): authors.add valueFor(a)
      elif a.startsWith("--committer"): committers.add valueFor(a)
      elif a == "-i" or a == "--regexp-ignore-case": icase = true
      elif a == "-F" or a == "--fixed-strings": fixed = true
      elif a == "-E" or a == "--extended-regexp":
        discard   # gittle's patterns are always ERE -- plan.md 6.4
      elif a == "-G" or a == "--basic-regexp" or a == "-P" or a == "--perl-regexp":
        fail(a & " is out of scope for gittle v1 (docs/07): patterns are " &
             "POSIX extended regular expressions, always")
      elif a == "--all-match": lim.allMatch = true
      elif a == "--invert-grep": lim.invertGrep = true
      elif a.len > 1 and a[1] in {'0' .. '9'}:
        maxCount = parseInt(a[1 .. ^1])       # the bare `-5` form
      elif parseDiffOpt(a, dopts, valueFor): discard
      else:
        fail("unknown option '" & a & "'\n" & usageText)
    else:
      revs.add a
    inc i

  # Compiled once, after parsing, because `-i` and `-F` may follow the pattern
  # they modify: `log --grep=x -i` is an ordinary thing to type.
  for g in greps: lim.grep.add compileRegex(g, icase, fixed)
  for g in authors: lim.author.add compileRegex(g, icase, fixed)
  for g in committers: lim.committer.add compileRegex(g, icase, fixed)

  failIf(decorateMode notin ["short", "full", "auto", "no"],
         "invalid --decorate argument: " & decorateMode)
  failIf(decorateMode == "full",
         "--decorate=full is out of scope for gittle v1 (docs/07)")
  opts.decorate = decorateMode == "short" or (decorateMode == "auto" and isTty())

  let repo = c.repo
  # An abbreviation is a *minimum* that `uniqueAbbrev` lengthens until it names
  # one object, and the default minimum scales with the repository -- seven in
  # a small one, ten in the git repository next door.
  opts.abbrev = if abbrevLen > 0: abbrevLen else: repo.autoAbbrev
  # git has one `--abbrev`, shared by the commit header and the diff's `index`
  # line, so the value has to reach both option sets.
  if abbrevLen > 0: dopts.abbrev = abbrevLen

  # A leading argument that is not a revision is a path -- and everything after
  # it is too, which is what makes `log Makefile` work without a `--`.  When
  # `--` *was* given the question does not arise: everything before it is a
  # revision, which is exactly why scripts should use it.
  var starts: seq[Oid]
  for r in revs:
    var o: Oid
    var ok = true
    try: o = repo.resolveOid(r)
    except GittleError: ok = false
    if ok and (seenDashDash or specs.len == 0):
      starts.add o
    else:
      failIf(not fileExists(repo.workTreePath(repo.prefix & r)) and
             not dirExists(repo.workTreePath(repo.prefix & r)),
             "ambiguous argument '" & r & "': unknown revision or path not " &
             "in the working tree\n" &
             "  Use '--' to separate paths from revisions")
      specs.add r

  if starts.len == 0:
    let h = repo.refs.resolveRef(headRef)
    failIf(not h.found,
           "your current branch '" & repo.headRefName &
           "' does not have any commits yet")
    starts.add h.oid

  let ps = parsePathspec(specs, repo.prefix)
  let w = newRevWalk(repo)
  w.firstParent = firstParent
  w.paths = ps
  w.limiting = not ps.isEmpty
  for o in starts: w.push(o)

  # `--no-walk` shows the named commits and stops; it is how `rev-list` is used
  # to format a list of commits somebody already has.
  # `log` shows no diff unless one was asked for, which is the one place it
  # differs from `show`.  Tracked separately from `-s`, because `-s --stat`
  # *is* a request for a diff.
  let wantDiff = dopts.formats.card > 0
  checkDiffOpts(dopts)
  opts.nulTerminate = dopts.nulTerminate

  proc render(o: Oid, commit: Commit): string =
    ## One commit, and the diff under it if any format was asked for.
    ##
    ## A merge has none: the combined formats are cut (docs/03), so there is
    ## nothing to show against several parents at once.  A root commit is
    ## diffed against the empty tree, which is what the null object ID means
    ## to `pairsTreeTree`.
    result = formatOne(repo, o, commit, opts)
    if not wantDiff or commit.parents.len > 1: return
    let old = if commit.parents.len == 1:
                repo.peelTo(commit.parents[0], otTree).oid
              else: nullOid
    let d = renderDiff(repo, pairsTreeTree(repo, old, commit.tree, ps), dopts)
    if not d.changed: return
    # One blank line between the message and the diff, and none after a
    # `oneline` header (`log-tree.c:log_tree_diff_flush`).  `---` goes on that
    # line when a stat and a patch were both asked for -- the only place the
    # two formats interact.
    if opts.kind != pkOneline:
      if dfStat in dopts.formats and dfPatch in dopts.formats: result.add "---"
      result.add "\n"
    result.add d.text

  var entries: seq[string]
  var shown = 0
  var skipped = 0
  if noWalk:
    for o in starts:
      let commit = repo.readCommit(o)
      if not lim.selects(commit): continue
      entries.add render(o, commit)
  else:
    for (o, commit) in w.walk:
      if not lim.selects(commit): continue
      if skipped < skip:
        inc skipped
        continue
      if maxCount >= 0 and shown >= maxCount: break
      inc shown
      entries.add render(o, commit)

  if reverse:
    for k in 0 ..< entries.len div 2:
      swap(entries[k], entries[entries.high - k])

  let sep = entrySeparator(opts.kind, dopts.nulTerminate)
  for k, e in entries:
    if k > 0: stdout.write sep
    stdout.write e
  stdout.flushFile()
  0
