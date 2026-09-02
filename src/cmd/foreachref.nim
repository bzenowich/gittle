## `for-each-ref` -- list refs, filtered, through a format string.
##
## ## What this is, and what it stopped being
##
## git's `ref-filter.c` is around three thousand lines because one engine
## serves `for-each-ref`, `branch`, `tag` and `ls-remote`, with a format
## vocabulary that reaches into commit messages, dates, upstream tracking and
## conditional output.  gittle mirrored that shape in a `reffilter.nim` of its
## own until the second minimisation pass, which deleted it
## (`docs/minimize-2.md` B5).  The evidence: `for-each-ref` is invoked **three
## times** in the two tool-call logs the scope was drawn from, and the only
## `%(…)` atoms that appear anywhere in them are `%(refname)`,
## `%(refname:short)`, `%(objectname)` and `%(upstream:short)`.
##
## So there is no atom grammar here any more -- no `:lstrip=`, no `*`-deref,
## no `%(contents:lines=…)`, no `--sort`.  There is a `case` over the six atom
## spellings that get used, written where they are consumed (R7), and anything
## else fails by name so that a script learns it asked for a cut feature
## rather than silently printing an empty column.
##
##   %(refname)         the full name, `refs/heads/main`
##   %(refname:short)   the shortest unambiguous form, `main`
##   %(objectname)      the object ID the ref names, in full
##   %(objecttype)      commit, tree, blob or tag -- the default format uses it
##   %(upstream)        the configured upstream, from `branch.<n>.merge`
##   %(upstream:short)
##
## `%%` and `%xx` still work: they are `util.interpolate`'s, not an atom's, and
## they are how a format string carries a tab or a NUL through a shell.
##
## ## The reachability filters
##
## `--contains`, `--merged` and their negations are one question asked in two
## directions: `--contains X` keeps refs whose history includes X, and
## `--merged X` keeps refs that X's history includes.  Both are reachability,
## and each direction has its own cheapest answer:
##
## * `--merged X` is a **membership test** -- the set of commits X reaches is
##   one walk for the whole listing, and `revwalk.ancestry` already computes
##   it.  A thousand refs cost one walk.
## * `--contains X` cannot be turned round like that -- there is no one walk
##   that yields "the commits that reach X" -- so it is a walk per ref, over a
##   memo shared by the whole listing (`Reach`, below).
##
## That memo is not an optimisation to be traded away.  Every ref in one
## listing asks the same question about the same X, so a commit proved not to
## reach X for one ref is proved for all of them: with the memo a thousand tags
## cost about one walk over the history, and without it a thousand.  Measured
## on git.git, `--contains v2.30.0 refs/tags` is 1,008 refs and about a second
## with it, and about twenty minutes without.  git keeps exactly this cache and
## for exactly this reason (`ref-filter.c:contains_tag_algo`).
##
## What gittle does *not* keep is git's shape: no `ref-filter.c` object with
## flags per commit, no `is_descendant_of` variants.  Two sets of object IDs
## and a date, which is the content of the cache and nothing else.
##
## The listing selection and the `RefFilter` that carries it are shared with
## `branch` and `tag`, which import this module; the format is not, because
## those two print their own listings and never go through one.

import std/[sets, strutils]
import ../cli, ../glob, ../repository, ../revision, ../revwalk, ../util

const defaultFormat = "%(objectname) %(objecttype)\t%(refname)"
  ## `builtin/for-each-ref.c`.  A script reads this, so it is byte-exact (R1).

type
  RefRow* = object
    ## One ref of a listing, and the object it finally names.  A symbolic ref
    ## reports the object at the end of the chain -- which is what all three
    ## commands print -- while `rf.symTarget` still says what it pointed at.
    rf*: Ref
    oid*: Oid

  RefFilter* = object
    ## What `for-each-ref`, `branch` and `tag` all narrow a listing with.
    patterns*: seq[string]
    contains*, noContains*: seq[Oid]   ## `--contains` / `--no-contains`
    merged*, noMerged*: seq[Oid]       ## `--merged` / `--no-merged`
    pointsAt*: seq[Oid]                ## `--points-at`
    matchAsPath*: bool                 ## `for-each-ref`'s matching, below
    count*: int                        ## `--count`

# ---------------------------------------------------------------------------
# Selecting the refs
# ---------------------------------------------------------------------------

proc matchesPattern*(refname: string, patterns: seq[string],
                     asPath: bool): bool =
  ## The two commands match their patterns against different things, and
  ## nothing in the option names says so (`ref-filter.c:filter_pattern_match`):
  ##
  ## * `for-each-ref` matches the **full** name as a path -- a pattern that is
  ##   a prefix ending at a `/` matches, which is why `for-each-ref refs/heads`
  ##   lists every branch without a `*`, and a glob does not cross a `/`;
  ## * `branch` and `tag` match the **short** name with an ordinary glob, which
  ##   is why `tag -l 'v*'` works and `tag -l 'refs/tags/v*'` does not.
  if patterns.len == 0: return true
  if not asPath:
    var short = refname
    for p in ["refs/tags/", "refs/heads/", "refs/remotes/"]:
      if short.startsWith(p):
        short = short[p.len .. ^1]
        break
    for p in patterns:
      if globMatch(p, short, {}): return true
    return false
  for p in patterns:
    if p.len <= refname.len and refname.startsWith(p) and
       (p.len == refname.len or refname[p.len] == '/' or p[^1] == '/'):
      return true
    if globMatch(p, refname, {gfPathname}):
      return true
  false

type Reach = object
  ## One `--contains <commit>…`, answered for a whole listing.
  ##
  ## `no` is every commit some earlier ref proved cannot reach a wanted one and
  ## `yes` every ref tip that could; both survive from ref to ref, which is the
  ## amortisation.  `cutoff` is the oldest wanted commit's date: nothing older
  ## can reach it, so the walk stops there instead of at the root
  ## (`ref-filter.c:contains_tag_algo` computes the same cutoff the same way).
  ## Clock skew can therefore make gittle and git both answer "no" where a full
  ## walk would say yes; agreeing with git is the point (R8).
  wanted: HashSet[Oid]
  cutoff: int64
  yes, no: HashSet[Oid]

proc newReach(repo: Repository, wanted: seq[Oid]): Reach =
  ## The wanted commits and the oldest of their dates.
  result.cutoff = high(int64)
  for o in wanted:
    result.wanted.incl o
    result.cutoff = min(result.cutoff, repo.readCommit(o).committer.when0)

proc reaches(repo: Repository, r: var Reach, tip: Oid): bool =
  ## Does `tip`'s history include a wanted commit?
  ##
  ## Depth first with an explicit stack, because git.git's history is deeper
  ## than a recursion may go.  Two memo rules, and the second is what makes the
  ## listing cheap:
  ##
  ## * a walk that **finds** one stops at once, and only the tip is recorded --
  ##   the commits it passed through are undecided, since it stopped early;
  ## * a walk that **finishes** without finding one has proved every commit it
  ##   touched cannot reach a wanted commit, so all of them are recorded.
  ##
  ## Refs are listed in name order and release tags are mostly each other's
  ## ancestors, so the `yes` set is usually hit within a few commits of the tip.
  var stack = @[tip]
  var walked: HashSet[Oid]
  while stack.len > 0:
    let o = stack.pop()
    if o in r.no or o in walked: continue
    if o in r.wanted or o in r.yes:
      r.yes.incl tip
      return true
    let c = repo.readCommit(o)
    if c.committer.when0 < r.cutoff: r.no.incl o; continue
    walked.incl o
    for p in c.parents: stack.add p
  for o in walked: r.no.incl o
  false

proc collectRefs*(repo: Repository, prefixes: openArray[string],
                  f: RefFilter): seq[RefRow] =
  ## Every ref under one of `prefixes` that survives the filters, in name
  ## order.
  ##
  ## `prefixes` is a list because `branch -a` lists two namespaces at once and
  ## must not read the whole of `refs/` to do it.  No sort of its own is
  ## needed: `allRefs` returns each prefix sorted, and the only caller with two
  ## passes `refs/heads/` before `refs/remotes/`, which is already their order.
  let wantsReach = f.contains.len + f.noContains.len +
                   f.merged.len + f.noMerged.len > 0
  # One walk each, for the whole listing; see the module comment.
  let merged = if f.merged.len > 0: repo.ancestry(f.merged)
               else: initHashSet[Oid]()
  let noMerged = if f.noMerged.len > 0: repo.ancestry(f.noMerged)
                 else: initHashSet[Oid]()
  var hasCon = if f.contains.len > 0: newReach(repo, f.contains) else: Reach()
  var noCon = if f.noContains.len > 0: newReach(repo, f.noContains) else: Reach()
  for prefix in prefixes:
    for rf in repo.refs.allRefs(prefix):
      if not matchesPattern(rf.name, f.patterns, f.matchAsPath): continue
      var oid = rf.oid
      if rf.isSymbolic:
        let r = repo.refs.resolveRef(rf.name)
        if not r.found: continue
        oid = r.oid
      # `--points-at` matches the ref's own object *or* what it fully peels
      # to, so it finds an annotated tag by the commit it names as well as by
      # the tag object (`ref-filter.c:match_points_at`).
      if f.pointsAt.len > 0 and oid notin f.pointsAt:
        var peeled = oid
        try: peeled = repo.peelTags(peeled)
        except GittleError: discard
        if peeled == oid or peeled notin f.pointsAt: continue
      if wantsReach:
        # A ref that does not lead to a commit -- a tag of a blob -- cannot be
        # an ancestor of anything, so it fails every reachability filter.
        var tip: Oid
        try: tip = repo.peelTo(oid, otCommit).oid
        except GittleError: continue
        if f.contains.len > 0 and not repo.reaches(hasCon, tip): continue
        if f.noContains.len > 0 and repo.reaches(noCon, tip): continue
        if f.merged.len > 0 and tip notin merged: continue
        if f.noMerged.len > 0 and tip in noMerged: continue
      result.add RefRow(rf: rf, oid: oid)
      # `--count` stops the walk rather than trimming afterwards, which is
      # what makes `--count=5 --contains <x>` cheap on a big repository.
      if f.count > 0 and result.len >= f.count: return

# ---------------------------------------------------------------------------
# The format
# ---------------------------------------------------------------------------

proc expandRow(repo: Repository, r: RefRow, format: string): string =
  ## The format with every `%(atom)` replaced for this ref.  Six atoms; see
  ## the module comment for why there are six and not sixty.
  interpolate(format, proc (atom: string): string =
    case atom
    of "refname": r.rf.name
    of "refname:short": repo.refs.shortenRef(r.rf.name)
    of "objectname": $r.oid
    of "objecttype": $repo.objectInfo(r.oid).kind
    of "upstream", "upstream:short":
      # An empty value, not an error, when the branch has no upstream: that is
      # what makes `%(refname:short) -> %(upstream:short)` readable over a
      # mixture of tracked and untracked branches.
      let up = repo.upstreamRef(r.rf.name)
      if up.len == 0: ""
      elif atom == "upstream": up
      else: repo.refs.shortenRef(up)
    else:
      fail("%(" & atom & ") is out of scope for gittle: for-each-ref has " &
           "refname, refname:short, objectname, objecttype, upstream and " &
           "upstream:short (docs/minimize-2.md B5)"))

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

const options = [
  opt("--count", okValue, arg = "<n>", help = "show at most <n> refs"),
  opt("--format", okValue, arg = "<fmt>", help = "print each ref through a format string"),
  # The ref-filter family (`ref-filter.c`): each takes an optional commit,
  # HEAD when none is given.  `branch` has rows of its own for two of them and
  # shares `applyFilterOpts` below.
  opt("--contains", okOptNext, arg = "[<commit>]", help = "only refs containing the commit"),
  opt("--no-contains", okOptNext, arg = "[<commit>]", help = "only refs not containing it"),
  opt("--merged", okOptNext, arg = "[<commit>]", help = "only refs reachable from the commit"),
  opt("--no-merged", okOptNext, arg = "[<commit>]", help = "only refs not reachable from it"),
  opt("--points-at", okOptNext, arg = "[<object>]", help = "only refs pointing at the object"),
  opt("--sort", okRefused,
      help = "trimmed with the atom grammar (docs/minimize-2.md B5); refs come in name order"),
]

proc applyFilterOpts*(c: Ctx, o: Opts, f: var RefFilter) =
  ## The filter half of a parse, for any command whose table includes the
  ## ref-filter rows above (or a subset of them, as `branch`'s does).
  for (k, v) in o.occurrences:
    let at = if v.len == 0: "HEAD" else: v
    case k
    of "contains": f.contains.add c.repo.resolveCommittish(at)
    of "no-contains": f.noContains.add c.repo.resolveCommittish(at)
    of "merged": f.merged.add c.repo.resolveCommittish(at)
    of "no-merged": f.noMerged.add c.repo.resolveCommittish(at)
    of "points-at": f.pointsAt.add c.repo.resolveRevish(at)
    else: discard

proc cmdForEachRef*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, collect the refs through the filter, expand each
  ## through the format.
  let o = parse(options, args, "for-each-ref", "[<options>] [<pattern>…]")
  var f = RefFilter(matchAsPath: true, patterns: o.args)
  applyFilterOpts(c, o, f)
  if o.has "count": f.count = parseInt(o.val "count")
  let format = o.val("format", defaultFormat)
  for row in c.repo.collectRefs([refsPrefix], f):
    stdout.write c.repo.expandRow(row, format), "\n"
  stdout.flushFile()
  0
