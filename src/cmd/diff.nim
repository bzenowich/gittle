## `diff` -- show changes between trees, the index, and the working tree.
##
## The command is thin because everything it does lives in `diffcore.nim`.
## What is left here is the one genuinely command-shaped decision: **which two
## things are being compared**, which the arguments imply rather than state.
##
## | arguments | old side | new side |
## |---|---|---|
## | none | the index | the working tree |
## | `--cached` | `HEAD` | the index |
## | `--cached <commit>` | that commit's tree | the index |
## | `<commit>` | that commit's tree | the working tree |
## | `<commit> <commit>` | the first tree | the second |
## | `--no-index <a> <b>` | a file | a file |
##
## A leading argument that names an object is a revision and anything after it
## is a path, exactly as in `log`; `--` settles it.

import std/strutils
import ../cli, ../color, ../diffcore, ../index, ../pathspec, ../repository,
       ../revision, ../revwalk, ../util


proc noIndexPair(a, b: string): DiffPair =
  ## Two plain files.  Both sides read from the filesystem, and the two names
  ## are kept apart because `diff --no-index x y` says `diff --git a/x b/y`.
  let (aOk, aSt) = statPath(a)
  let (bOk, bSt) = statPath(b)
  failIf(not aOk, "cannot read '" & a & "'")
  failIf(not bOk, "cannot read '" & b & "'")
  DiffPair(oldPath: a, path: b,
           oldMode: modeForFile(aSt), newMode: modeForFile(bSt),
           oldFromWork: true, newFromWork: true)

const
  synopsis = "[<options>] [<commit>] [<commit>] [--] [<path>…]\n--no-index [<options>] <path> <path>"
  options = [
    opt("--cached|--staged", help = "the index against a commit (HEAD by default)"),
    opt("--no-index", help = "two files, outside any repository"),
  ]

proc cmdDiff*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, work out which two of the three things (a tree,
  ## the index, the working tree) are being compared, and render.
  let p = parse(@options & @diffOptions, args, "diff", synopsis)
  var o = defaultDiffOpts()
  o.color = isTty()   # git's `color.ui=auto`; `--color`/`--no-color` below can override
  applyDiffOpts(p, o)
  let cached = p.has "cached"
  let noIndex = p.has "no-index"
  let seenDashDash = p.dashDash
  # Before `--` a word is a revision; after it, a path.
  var revs = if p.dashDashAt >= 0: p.args[0 ..< p.dashDashAt] else: p.args
  var specs = if p.dashDashAt >= 0: p.args[p.dashDashAt .. ^1] else: @[]
  if o.formats.card == 0: o.formats = {dfPatch}
  checkDiffOpts(o)

  if noIndex:
    failIf(revs.len != 2, "--no-index needs exactly two paths")
    let r = renderDiff(nil, @[noIndexPair(revs[0], revs[1])], o)
    stdout.write r.text
    # `--no-index` always reports a difference through its exit status; it is
    # `diff(1)`, not `git diff`, and that is what a script expects of it.
    return if r.changed: 1 else: 0

  let repo = c.repo

  # An argument that is not a revision is a path, and so is everything after
  # it -- which is what makes `gittle diff Makefile` work without a `--`.  When
  # `--` *was* given the question does not arise: everything before it is a
  # revision, which is exactly why scripts should use it.
  #
  # `A..B` is `A B`, and `A...B` is "what B added since they diverged", so it
  # is the merge base against B.  A range spelling is one argument that names
  # two trees, which is the only reason this loop is not a `map`.
  var trees: seq[Oid]
  for r in revs:
    let dots = r.find("..")
    if dots >= 0 and r != ".." and (seenDashDash or specs.len == 0):
      let symmetric = dots + 2 < r.len and r[dots + 2] == '.'
      let lhs = if dots == 0: "HEAD" else: r[0 ..< dots]
      let rhsAt = dots + (if symmetric: 3 else: 2)
      let rhs = if rhsAt >= r.len: "HEAD" else: r[rhsAt .. ^1]
      if repo.looksLikeRev(lhs) and repo.looksLikeRev(rhs):
        let b = repo.resolveCommittish(rhs)
        let a = if not symmetric: repo.resolveCommittish(lhs)
                else: repo.mergeBase(repo.resolveCommittish(lhs), b)
        failIf(symmetric and a.isNull,
               "fatal: " & lhs & " and " & rhs & " have no merge base")
        trees.add repo.peelTo(a, otTree).oid
        trees.add repo.peelTo(b, otTree).oid
        continue
    var t: Oid
    var ok = true
    # A *refusal* is not a "this is not a revision, try it as a path": letting
    # `RevRefused` through here would report `:/one` as a pathspec that matched
    # nothing, naming a mistake the user did not make (docs/minimize-2.md §B3).
    try: t = repo.resolveTree(r)
    except RevRefused: raise
    except GittleError: ok = false
    if ok and (seenDashDash or specs.len == 0): trees.add t
    else:
      failAmbiguous(repo, r)
      specs.add r

  failIf(trees.len > 2, "gittle diff takes at most two commits")
  let ps = parsePathspec(specs, repo.prefix)
  let idx = readIndex(repo.indexPath)

  proc headTree(): Oid =
    ## HEAD's tree, or a clear refusal on an unborn branch.
    let h = repo.refs.resolveRef(headRef)
    failIf(not h.found, "no commits yet on '" & repo.headRefName & "'")
    repo.peelTo(h.oid, otTree).oid

  let pairs =
    if trees.len == 2: pairsTreeTree(repo, trees[0], trees[1], ps)
    elif cached: pairsTreeIndex(repo,
                                (if trees.len == 1: trees[0] else: headTree()), idx, ps)
    elif trees.len == 1: pairsTreeWork(repo, trees[0], idx, ps)
    else: pairsIndexWork(repo, idx, ps)

  let r = renderDiff(repo, pairs, o)
  stdout.write r.text
  stdout.flushFile()
  if o.exitCode and r.changed: 1 else: 0
