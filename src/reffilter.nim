## The ref listing engine: which refs, in which order, printed how.
##
## git calls this `ref-filter.c`, and it is three thousand lines because one
## engine serves four commands: `for-each-ref`, `branch`, `tag` and
## `ls-remote`.  The same is true here and for the same reason -- a branch
## listing *is* a ref listing with `refs/heads/` assumed, a default format and
## two extra filters -- so it is written once.
##
## ## The atoms v1 understands
##
##   %(refname)              the full name, e.g. refs/heads/main
##   %(refname:short)        the shortest unambiguous form, `main`
##   %(refname:lstrip=<n>)   drop <n> leading components (negative: keep last n)
##   %(refname:rstrip=<n>)   drop <n> trailing components
##   %(objectname)           the object ID the ref names
##   %(objectname:short)     abbreviated to 7 digits
##   %(objectname:short=<n>) abbreviated to <n>
##   %(objecttype)           commit, tree, blob or tag
##   %(objectsize)           the object's size in bytes
##   %(HEAD)                 `*` if this is the checked-out branch, else a space
##   %(symref)               what a symbolic ref points at; empty otherwise
##   %(symref:short)
##   %(upstream)             the configured upstream ref, from branch.<n>.merge
##   %(upstream:short)
##   %(subject)              the first paragraph of the commit or tag message
##   %(contents)             the whole message
##   %(contents:subject)     the same as %(subject)
##   %(contents:body)        everything after the subject
##   %(contents:lines=<n>)   the first <n> lines of the message, which is what
##                           `tag -n<num>` prints
##   %(*objectname) etc.     the same field, but for what an annotated tag
##                           points at -- the `*` prefix is git's spelling
##
## Plus `%%` for a literal per cent and `%xx` for a byte written in hex, which
## is how a format string embeds a tab or a NUL.
##
## Everything else -- dates, `%(align:)`, `%(if:)` -- is refused by name
## rather than silently ignored.  A format atom that expands to nothing when
## the caller expected a date is worse than an error.
##
## ## The four reachability filters
##
## `--contains`, `--merged` and their negations are one question asked in two
## directions: `--contains X` keeps refs that X can be reached *from*, and
## `--merged X` keeps refs that can be reached *from* X.  Both are
## `isAncestor` with the arguments the other way round, which is why they are
## one table row apart below and not two code paths.

import std/[algorithm, sets, strutils, tables]
import commitobj, glob, objects, oid, refname, refs, repository, revwalk, util

const
  deferredAtoms = ["committerdate", "authordate", "taggerdate", "creatordate",
                   "creator", "align", "if", "push", "describe", "raw",
                   "deltabase", "signature", "tree", "parent", "numparent",
                   "worktreepath"]
    ## Real atoms of git's that v1 does not implement.  Naming them lets the
    ## error say "not implemented" rather than "unknown", which is the
    ## difference between a missing feature and a typo.


type
  ObjInfo* = object
    ## What an object is, filled in on demand.  Listing ten thousand tags must
    ## not read ten thousand objects unless the format asks for their type.
    oid*: Oid
    kind*: ObjectType
    size*: int
    loaded*: bool

  RefRow* = object
    ## One ref, plus the object it names and -- for an annotated tag -- the
    ## object that one points at, which is what the `*` atoms report.
    rf*: Ref
    isHead*: bool
    self*: ObjInfo
    peeled*: ObjInfo

# ---------------------------------------------------------------------------
# Field values
# ---------------------------------------------------------------------------

proc load(repo: Repository, i: var ObjInfo) =
  ## Read the object's type, size and headers, once, on first need.
  if i.loaded: return
  i.loaded = true
  if i.oid.isNull: return
  let info = repo.objectInfo(i.oid)
  i.kind = info.kind
  i.size = info.size

proc loadPeel(repo: Repository, r: var RefRow) =
  ## Follow an annotated tag to the object it names.
  ##
  ## `packed-refs` may already record this on a `^` line, which is exactly why
  ## that line exists: it saves reading the tag object at all.
  if r.peeled.loaded: return
  repo.load(r.self)
  if r.rf.hasPeeled:
    r.peeled.oid = r.rf.peeled
  elif r.self.kind == otTag:
    r.peeled.oid = repo.peelTags(r.rf.oid)
  repo.load(r.peeled)

proc refField(repo: Repository, name, modifier, atom: string): string =
  ## Every atom whose value is a *ref name* takes the same modifiers, so they
  ## are implemented once here rather than beside each atom.
  if name.len == 0 or modifier.len == 0: return name
  # `:short` is the DWIM rules run backwards, not a prefix strip: it has to
  # ask what else exists, which is why `refs/remotes/origin/HEAD` shortens to
  # `origin` and not to `origin/HEAD`.
  if modifier == "short": return repo.refs.shortenRef(name)
  if modifier.startsWith("lstrip="):
    return lstripRefname(name, parseInt(modifier["lstrip=".len .. ^1]))
  if modifier.startsWith("rstrip="):
    return rstripRefname(name, parseInt(modifier["rstrip=".len .. ^1]))
  fail("unknown modifier in %(" & atom & ")")

proc oidField(repo: Repository, o: Oid, modifier, atom: string): string =
  ## Likewise for every atom whose value is an object ID.  `:short` is the
  ## repository's own abbreviation length -- ten digits in a repository the
  ## size of git's, seven in a small one -- and it is a *minimum*, lengthened
  ## until it names one object.
  if modifier.len == 0: return $o
  if modifier == "short": return repo.uniqueAbbrev(o, repo.autoAbbrev)
  if modifier.startsWith("short="):
    return repo.uniqueAbbrev(o, parseInt(modifier["short=".len .. ^1]))
  fail("unknown modifier in %(" & atom & ")")

proc fieldValue*(repo: Repository, r: var RefRow, atom: string): string =
  ## Expand one `%(…)` atom.  `atom` is what was between the parentheses:
  ## an optional `*` (meaning "of what this tag points at"), a name, and an
  ## optional `:modifier`.
  var name = atom
  let deref = name.startsWith("*")
  if deref: name = name[1 .. ^1]

  var modifier = ""
  let colon = name.find(':')
  if colon >= 0:
    modifier = name[colon + 1 .. ^1]
    name = name[0 ..< colon]

  for d in deferredAtoms:
    if name == d:
      fail("%(" & atom & ") is not implemented in this version\n" &
           "  date, message and conditional atoms need the revision walk " &
           "(phase 6)")

  if deref:
    repo.loadPeel(r)
    if r.peeled.oid.isNull: return ""

  case name
  of "refname":    repo.refField(r.rf.name, modifier, atom)
  of "symref":     repo.refField(r.rf.symTarget, modifier, atom)
  of "upstream":   repo.refField(repo.upstreamRef(r.rf.name), modifier, atom)
  of "objectname", "objecttype", "objectsize":
    # The three object atoms differ only in which field they report, and the
    # `*` prefix only in which object they report it for.
    var info = if deref: r.peeled else: r.self
    if name != "objectname": repo.load(info)
    if deref: r.peeled = info else: r.self = info
    case name
    of "objectname": repo.oidField(info.oid, modifier, atom)
    of "objecttype": $info.kind
    else: $info.size
  of "HEAD":
    if r.isHead: "*" else: " "
  of "subject", "contents", "body":
    # The message of a commit or of an annotated tag, which for these purposes
    # are the same shape: headers, a blank line, and the text.  A lightweight
    # tag has no message of its own, so the atom reports the *commit's* --
    # which is what makes `tag -n1` print something useful for both kinds.
    var info = if deref: r.peeled else: r.self
    repo.load(info)
    if deref: r.peeled = info else: r.self = info
    if info.kind notin {otCommit, otTag}: return ""
    let data = repo.readObject(info.oid).data
    let blank = data.find("\n\n")
    let whole = if blank < 0: "" else: data[blank + 2 .. ^1]
    # A signed tag keeps its signature in the message.  `%(contents)` reports
    # it -- that is what "contents" means -- and every atom that claims to be
    # the *message* does not (`ref-filter.c:find_subpos` computes both).
    let msg = stripSignature(whole)
    let want = if name == "contents": modifier
               elif name == "body": "body"
               else: "subject"
    if want.len == 0: whole
    elif want == "subject": subject(msg)
    elif want == "body": (if name == "body": body(whole) else: body(msg))
    elif want == "signature": whole[msg.len .. ^1]
    elif want.startsWith("lines="):
      # `%(contents:lines=<n>)`: the first n lines, which is what `tag -n<num>`
      # prints -- and every line after the first arrives indented four spaces,
      # because that is how the listing lines them up under the tag name
      # (`ref-filter.c:append_lines`).
      # A message ending in a newline has no empty last line: git walks the
      # buffer and stops at its end, so a trailing terminator is not a line.
      var body = msg
      if body.endsWith("\n"): body.setLen(body.len - 1)
      var head: seq[string]
      for line in body.splitLines():
        if head.len >= parseInt(want["lines=".len .. ^1]): break
        head.add line
      head.join("\n    ")
    else: fail("unknown modifier in %(" & atom & ")")
  else:
    fail("unknown field name: %(" & atom & ")")

proc expand*(repo: Repository, r: var RefRow, format: string): string =
  ## The format with every `%(atom)` replaced for this ref.
  var row = r
  result = interpolate(format, proc (atom: string): string =
    repo.fieldValue(row, atom))
  r = row

# ---------------------------------------------------------------------------
# Filtering and sorting
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

proc sortRows*(repo: Repository, rows: var seq[RefRow], keys: seq[string]) =
  ## Apply `--sort` keys.
  ##
  ## The *last* key given is the primary one (`git for-each-ref` documents this,
  ## and it is easy to verify with a tag and a branch whose name order and type
  ## order disagree).  With a stable sort that falls out for free: sort by each
  ## key in turn, and the last sort applied is the one that wins, with every
  ## earlier one surviving as a tiebreak.
  for k in 0 .. keys.high:
    var key = keys[k]
    let descending = key.startsWith("-")
    if descending: key = key[1 .. ^1]
    let numeric = key == "objectsize"
    sort(rows, proc (a, b: RefRow): int =
      var ra = a
      var rb = b
      let va = repo.fieldValue(ra, key)
      let vb = repo.fieldValue(rb, key)
      result = if numeric:
                 cmp(parseInt(if va.len == 0: "0" else: va),
                     parseInt(if vb.len == 0: "0" else: vb))
               else: cmp(va, vb)
      if descending: result = -result)



# ---------------------------------------------------------------------------
# Selecting the refs
# ---------------------------------------------------------------------------

type RefFilter* = object
  ## What `for-each-ref`, `branch` and `tag` all narrow a listing with.
  patterns*: seq[string]
  contains*, noContains*: seq[Oid]   ## `--contains` / `--no-contains`
  merged*, noMerged*: seq[Oid]       ## `--merged` / `--no-merged`
  pointsAt*: seq[Oid]                ## `--points-at`
  matchAsPath*: bool                 ## `for-each-ref`'s matching, above
  sortKeys*: seq[string]
  count*: int

# A thousand tags asked "do you contain this commit?" one at a time is a
# thousand walks over the same history.  Both directions are therefore
# answered once for the whole listing, which is what git does too
# (`ref-filter.c` uses `contains_tag_algo` with a shared cache rather than
# `is_descendant_of` per ref, for exactly this reason).

type Contains = ref object
  ## "Does this commit reach any of `wanted`?", memoised over every commit
  ## the search touches.  Two tags that share an ancestor share the answer.
  repo: Repository
  wanted: HashSet[Oid]
  cutoff: int64        ## no commit older than the oldest wanted one can reach it
  memo: Table[Oid, bool]

proc newContains(repo: Repository, wanted: seq[Oid]): Contains =
  ## The state for `--contains`: the wanted tips and the oldest of their
  ## commit dates, below which no walk need go.
  result = Contains(repo: repo, cutoff: high(int64))
  for o in wanted:
    result.wanted.incl o
    result.cutoff = min(result.cutoff, repo.readCommit(o).committer.when0)

proc reachesWanted(c: Contains, tip: Oid): bool =
  ## Depth first with an explicit stack, visiting each commit at most twice --
  ## once to push its parents, once to combine their answers.
  if c.memo.hasKey(tip): return c.memo[tip]
  var stack = @[(tip, false)]
  while stack.len > 0:
    let (o, expanded) = stack.pop()
    if c.memo.hasKey(o): continue
    if o in c.wanted:
      c.memo[o] = true
      continue
    let commit = c.repo.readCommit(o)
    # A commit older than everything we are looking for cannot reach it.  The
    # cutoff is what keeps this from walking to the root for every tag.
    if commit.committer.when0 < c.cutoff:
      c.memo[o] = false
      continue
    if expanded:
      var hit = false
      for p in commit.parents:
        if c.memo.getOrDefault(p): hit = true
      c.memo[o] = hit
    else:
      stack.add (o, true)
      for p in commit.parents:
        if not c.memo.hasKey(p): stack.add (p, false)
  c.memo.getOrDefault(tip)

proc collectRefs*(repo: Repository, prefixes: openArray[string],
                  f: RefFilter): seq[RefRow] =
  ## Every ref under one of `prefixes` that survives the filters, sorted.
  ## `prefixes` is a list because `branch -a` lists two namespaces at once and
  ## must not read the whole of `refs/` to do it.
  let headBranch = repo.headRefName
  let wantsReach = f.contains.len + f.noContains.len +
                   f.merged.len + f.noMerged.len > 0
  let hasCon = if f.contains.len > 0: newContains(repo, f.contains) else: nil
  let noCon = if f.noContains.len > 0: newContains(repo, f.noContains) else: nil
  let merged = if f.merged.len > 0: repo.ancestry(f.merged)
               else: initHashSet[Oid]()
  let noMerged = if f.noMerged.len > 0: repo.ancestry(f.noMerged)
                 else: initHashSet[Oid]()

  for prefix in prefixes:
    for rf in repo.refs.allRefs(prefix):
      if not matchesPattern(rf.name, f.patterns, f.matchAsPath): continue
      # A symbolic ref reports the object at the end of the chain; `%(symref)`
      # is where the target itself shows up.
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
        try:
          peeled = repo.peelTags(peeled)
        except GittleError: discard
        if peeled == oid or peeled notin f.pointsAt: continue
      if wantsReach:
        # A ref that does not lead to a commit -- a tag of a blob -- cannot be
        # an ancestor of anything, so it fails every reachability filter.
        var tip: Oid
        try: tip = repo.peelTo(oid, otCommit).oid
        except GittleError: continue
        if hasCon != nil and not hasCon.reachesWanted(tip): continue
        if noCon != nil and noCon.reachesWanted(tip): continue
        if f.merged.len > 0 and tip notin merged: continue
        if f.noMerged.len > 0 and tip in noMerged: continue
      result.add RefRow(rf: rf, isHead: rf.name == headBranch,
                        self: ObjInfo(oid: oid))
  sortRows(repo, result, if f.sortKeys.len == 0: @["refname"] else: f.sortKeys)
  if f.count > 0 and result.len > f.count: result.setLen(f.count)
