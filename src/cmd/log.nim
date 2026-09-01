## `log` -- show commit history.
##
## Phase 4 lands the walk and the formatting: starting commits, `[--] <path>…`,
## the counting and ordering options that do not need a second traversal, and
## the pretty and date vocabularies.  Three groups are deferred, each to the
## phase that brings what they need:
##
## * **the diff** (`-p`, `--stat`, `--name-only`) -- phase 5;
## * **the limiting patterns** (`--grep`, `--author`, `--committer`) -- phase
##   5, with the regex engine (plan.md §6.4);
## * **revision ranges** (`A..B`, `^A`, `--all`, `--branches`) and the
##   traversal orders (`--topo-order`, `--since`) -- phase 6, with `rev-list`
##   and `rev-parse`, where that whole option surface belongs.
##
## Each refuses by name.  A `log` that silently ignored `--grep` would answer a
## different question from the one asked, and look like it had answered.
##
## ## Telling a revision from a path
##
## `gittle log foo` is ambiguous, and git resolves it by trying: if `foo` names
## an object it is a revision, otherwise if it is a file it is a path,
## otherwise it is an error naming both possibilities.  `--` settles it, which
## is why scripts should use it and why the error message says so.

import std/[os, strutils, times]
import ../cli, ../pathspec, ../pretty, ../repository, ../revwalk,
       ../util

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
   --decorate[=short|full|auto|no]"""

const deferred: array[3, (string, seq[string])] = [
  ("phase 5, with the diff engine", @[
    "-p", "-u", "--patch", "--stat", "--shortstat", "--numstat", "--raw",
    "--name-only", "--name-status", "--full-diff", "--follow", "--graph"]),
  ("phase 5, with the regex engine (plan.md 6.4)", @[
    "--grep", "--author", "--committer", "-i", "--regexp-ignore-case",
    "-E", "--extended-regexp", "-F", "--fixed-strings", "--all-match",
    "--invert-grep"]),
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
        fail(a & " is not implemented in this version\n  it arrives in " & why)

proc cmdLog*(c: Ctx, args: seq[string]): int =
  var opts = PrettyOpts(kind: pkMedium, now: getTime().toUnix())
  var maxCount = -1
  var skip = 0
  var reverse = false
  var noWalk = false
  var decorateMode = "auto"
  var firstParent = false
  var abbrevLen = 0
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
      elif a.len > 1 and a[1] in {'0' .. '9'}:
        maxCount = parseInt(a[1 .. ^1])       # the bare `-5` form
      else:
        fail("unknown option '" & a & "'\n" & usageText)
    else:
      revs.add a
    inc i

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

  # A leading argument that is not a revision is a path -- and everything after
  # it is too, which is what makes `log Makefile` work without a `--`.
  var starts: seq[Oid]
  for r in revs:
    var o: Oid
    var ok = true
    try: o = repo.resolveOid(r)
    except GittleError: ok = false
    if ok and specs.len == 0:
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
  var entries: seq[string]
  var shown = 0
  var skipped = 0
  if noWalk:
    for o in starts:
      entries.add formatOne(repo, o, repo.readCommit(o), opts)
  else:
    for (o, commit) in w.walk:
      if skipped < skip:
        inc skipped
        continue
      if maxCount >= 0 and shown >= maxCount: break
      inc shown
      entries.add formatOne(repo, o, commit, opts)

  if reverse:
    for k in 0 ..< entries.len div 2:
      swap(entries[k], entries[entries.high - k])

  let sep = entrySeparator(opts.kind)
  for k, e in entries:
    if k > 0: stdout.write sep
    stdout.write e
  stdout.flushFile()
  0
