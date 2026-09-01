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

import std/[os, strutils]
import ../cli, ../diffcore, ../index, ../pathspec, ../repository, ../util

const usageText = """usage: gittle diff [<options>] [<commit>] [<commit>] [--] [<path>…]

   --cached, --staged        diff the index against a commit
   --no-index <a> <b>        diff two files, ignoring the repository
   -p, --patch               a unified patch (the default)
   -s, --no-patch            no output
   --raw                     the machine-readable record
   --stat, --shortstat, --numstat, --name-only, --name-status
   -U<n>, --unified=<n>      lines of context
   --full-index, --abbrev=<n>, --no-prefix, -a/--text, -R, -z
   --diff-filter=[ADMT], -S<string>
   -w, -b, --ignore-space-at-eol, --ignore-cr-at-eol
   --color[=<when>], --no-color, --exit-code, --quiet"""

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

proc cmdDiff*(c: Ctx, args: seq[string]): int =
  var o = defaultDiffOpts()
  var cached = false
  var noIndex = false
  var revs: seq[string]
  var specs: seq[string]
  var i = 0
  var seenDashDash = false

  proc valueFor(a: string): string =
    let eq = a.find('=')
    if eq > 0: return a[eq + 1 .. ^1]
    inc i
    failIf(i >= args.len, "option '" & a & "' requires a value")
    args[i]

  while i < args.len:
    let a = args[i]
    if seenDashDash: specs.add a
    elif a == "--": seenDashDash = true
    elif a.len > 1 and a[0] == '-':
      if a == "--cached" or a == "--staged": cached = true
      elif a == "--no-index": noIndex = true
      elif a == "-h" or a == "--help":
        echo usageText
        return 0
      elif not parseDiffOpt(a, o, valueFor):
        fail("unknown option '" & a & "'\n" & usageText)
    else: revs.add a
    inc i

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
  for r in revs:
    failIf(r.contains("..."),
           "'" & r & "': the A...B form is phase 6, with rev-parse")
    failIf(r.contains(".."),
           "'" & r & "': the A..B form is phase 6, with rev-parse")

  # An argument that is not a revision is a path, and so is everything after
  # it -- which is what makes `gittle diff Makefile` work without a `--`.  When
  # `--` *was* given the question does not arise: everything before it is a
  # revision, which is exactly why scripts should use it.
  var trees: seq[Oid]
  for r in revs:
    var t: Oid
    var ok = true
    try: t = repo.resolveTree(r) except GittleError: ok = false
    if ok and (seenDashDash or specs.len == 0): trees.add t
    else:
      failIf(not fileExists(repo.workTreePath(repo.prefix & r)) and
             not dirExists(repo.workTreePath(repo.prefix & r)),
             "ambiguous argument '" & r & "': unknown revision or path not " &
             "in the working tree\n" &
             "  Use '--' to separate paths from revisions")
      specs.add r

  failIf(trees.len > 2, "gittle diff takes at most two commits")
  let ps = parsePathspec(specs, repo.prefix)
  let idx = readIndex(repo.indexPath)

  proc headTree(): Oid =
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
