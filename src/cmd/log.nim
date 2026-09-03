## `log` -- show commit history.
##
## Phase 4 landed the walk and the formatting, phase 5 the diff and the
## limiting patterns, and phase 6 the rest of docs/04 -- which is `rev-list`'s
## whole option surface, parsed by the same code in `revision.nim`.  What is
## left in this file is what `rev-list` does not do: the pretty formats and
## the patch underneath each commit.
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

import std/strutils
import ../cli, ../commitobj, ../diffcore, ../ident, ../oid, ../pretty,
       ../regex, ../repository, ../revision, ../revwalk, ../util


type Limiters = object
  ## `--grep`, `--author` and `--committer`, and how they combine.
  ##
  ## Measured against git rather than read off the manual (R8): patterns of
  ## **different kinds are AND-ed** -- `--author=A --committer=B` selects
  ## commits matching both, and matches nothing when nobody is both -- while
  ## repeated patterns of the *same* kind are OR-ed.  git's two switches over
  ## that rule, `--all-match` (AND the message group too) and `--invert-grep`,
  ## are cut: neither occurs in the tool-call logs of docs/minimize.md §2.2,
  ## and both refuse by name (docs/minimize-2.md §B4).
  grep, author, committer: seq[Regex]

proc anyMatch(pats: seq[Regex], s: string): bool =
  ## Does any pattern match?
  for p in pats:
    if p.matches(s): return true
  false

proc selects(l: Limiters, c: Commit): bool =
  ## The identity a pattern is matched against is `Name <email>`, which is the
  ## `author` header with its timestamp removed (`grep.c:strip_timestamp`).
  if l.author.len > 0 and
     not anyMatch(l.author, c.author.name & " <" & c.author.email & ">"):
    return false
  if l.committer.len > 0 and
     not anyMatch(l.committer, c.committer.name & " <" & c.committer.email & ">"):
    return false
  if l.grep.len > 0 and not anyMatch(l.grep, c.message): return false
  true

const
  synopsis = "[<options>] [<commit>…] [[--] <path>…]"
  options = [
    opt("--full-diff|--follow|--graph|--min-parents|--max-parents|--ancestry-path|--cherry-pick|--cherry-mark|--boundary|--simplify-by-decoration|--simplify-merges|--objects|--walk-reflogs|--author-date-order|--children|--source", okRefused, help = "docs/04, docs/07"),
    opt("--oneline", help = "one line per commit: abbreviated ID and subject"),
    opt("--abbrev-commit|--no-abbrev-commit|--all-match|--invert-grep",
        okRefused, help = "docs/minimize-2.md §B4"),
    opt("--relative-date", okRefused, help = "docs/minimize.md §3"),
    opt("--decorate", okOptValue, arg = "[=short|no|auto]", help = "show the refs at each commit"),
    opt("--no-decorate"),
    opt("--abbrev", okValue, arg = "<n>", help = "abbreviate object IDs to <n> digits"),
    opt("--date", okValue, arg = "<format>", help = "the date format"),
    opt("--pretty|--format", okOptValue, key = "format", arg = "[=<format>]",
        help = "the commit format: oneline, medium, full, fuller, raw, format:<fmt>"),
    opt("--grep", okValue, arg = "<pattern>", help = "commits whose message matches; repeatable"),
    opt("--author", okValue, arg = "<pattern>", help = "commits whose author matches"),
    opt("--committer", okValue, arg = "<pattern>", help = "commits whose committer matches"),
    opt("-i|--regexp-ignore-case", help = "match case-insensitively"),
    opt("-F|--fixed-strings", help = "patterns are literal strings"),
    opt("-E|--extended-regexp", help = "POSIX ERE, which is what gittle always uses (plan.md 6.4)"),
    opt("-G|--basic-regexp|-P|--perl-regexp", okRefused,
        help = "patterns are POSIX extended regular expressions, always (docs/07)"),
  ]

proc cmdLog*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, replay the walk options and revisions in order,
  ## then walk and print each commit that the limiters admit.
  let repo = c.repo
  let p = parse(@options & @walkOptions & @diffOptions, args, "log", synopsis,
                numeric = true)
  let w = newRevWalk(repo)
  var ri = initRevInput()
  var opts = PrettyOpts(kind: pkMedium, now: dateNow())
  var decorateMode = "auto"
  var abbrevLen = 0
  var dopts = defaultDiffOpts()
  dopts.color = isTty()   # git's `color.ui=auto`; `--color`/`--no-color` below can override
  applyDiffOpts(p, dopts)
  var lim = Limiters()
  var greps, authors, committers: seq[string]
  var icase = false
  var fixed = false
  # In order: a revision, a walk option and `--not` all depend on what came
  # before them.
  for (k, v) in p.occurrences:
    if k == "": w.addRevisionArg(ri, v)
    elif k == "--": ri.seenDashDash = true
    elif w.applyWalkOpt(ri, k, v): discard
    else:
      case k
      of "parents": opts.showParents = true
      of "oneline": (opts.kind = pkOneline; opts.abbrevCommit = true)
      of "no-decorate": decorateMode = "no"
      of "decorate": decorateMode = if v.len == 0: "short" else: v
      of "abbrev": abbrevLen = parseInt(v)
      of "date": opts.dateMode = parseDateMode(v)
      of "format": parsePretty(v, opts)
      of "grep": greps.add v
      of "author": authors.add v
      of "committer": committers.add v
      of "regexp-ignore-case": icase = true
      of "fixed-strings": fixed = true
      else: discard
  for g in greps: lim.grep.add compileRegex(g, icase, fixed)
  for g in authors: lim.author.add compileRegex(g, icase, fixed)
  for g in committers: lim.committer.add compileRegex(g, icase, fixed)

  failIf(decorateMode notin ["short", "full", "auto", "no"],
         "invalid --decorate argument: " & decorateMode)
  failIf(decorateMode == "full",
         "--decorate=full is out of scope for gittle v1 (docs/07)")
  opts.decorate = decorateMode == "short" or (decorateMode == "auto" and isTty())

  # An abbreviation is a *minimum* that `uniqueAbbrev` lengthens until it names
  # one object, and the default minimum scales with the repository -- seven in
  # a small one, ten in the git repository next door.
  opts.abbrev = if abbrevLen > 0: abbrevLen else: repo.autoAbbrev
  # git has one `--abbrev`, shared by the commit header and the diff's `index`
  # line, so the value has to reach both option sets.
  if abbrevLen > 0: dopts.abbrev = abbrevLen

  w.finishRevInput(ri)
  let ps = w.paths

  # `--no-walk` shows the named commits and stops; it is how `rev-list` is used
  # to format a list of commits somebody already has.
  # `log` shows no diff unless one was asked for, which is the one place it
  # differs from `show`.  Tracked separately from `-s`, because `-s --stat`
  # *is* a request for a diff.
  let wantDiff = dopts.formats.card > 0
  checkDiffOpts(dopts)
  opts.nulTerminate = dopts.nulTerminate

  proc render(o: Oid, commit: Commit, parents: seq[Oid], left: bool): string =
    ## One commit, and the diff under it if any format was asked for.
    ##
    ## A merge has none: the combined formats are cut (docs/03), so there is
    ## nothing to show against several parents at once.  A root commit is
    ## diffed against the empty tree, which is what the null object ID means
    ## to `pairsTreeTree`.
    # The parents handed in are the *rewritten* ones under a pathspec, so the
    # printed ancestry only names commits that are in the output.
    var c = commit
    c.parents = parents
    # The `<`/`>` mark has a space after it, and sits immediately before the
    # object name (`log-tree.c:put_revision_mark`).
    result = formatOne(repo, o, c, opts,
                       mark = if not ri.leftRight: ""
                              elif left: "< " else: "> ")
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
  for e in w.walk:
    if not lim.selects(e.commit): continue
    if skipped < ri.skip:
      inc skipped
      continue
    if ri.maxCount >= 0 and shown >= ri.maxCount: break
    inc shown
    entries.add render(e.oid, e.commit, e.parents, e.left)

  if ri.reverse:
    for k in 0 ..< entries.len div 2:
      swap(entries[k], entries[entries.high - k])

  let sep = entrySeparator(opts.kind, dopts.nulTerminate)
  for k, e in entries:
    if k > 0: stdout.write sep
    stdout.write e
  stdout.flushFile()
  0
