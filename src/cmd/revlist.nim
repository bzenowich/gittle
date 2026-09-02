## `rev-list` -- walk history and list what it reaches.
##
## The most important plumbing command there is: `log` is this with a format
## in front of it, and `pack-objects`, `fetch`, `push` and `gc` all ask this
## same question -- *which objects are on this side and not that one* -- with
## `--objects`.
##
## It has no options of its own.  Everything it takes belongs to the shared
## group in docs/04, parsed in `revision.nim` so that `log` gets the identical
## surface from the identical code, and what is left here is output: an object
## ID a line, with the four decorations below.
##
## ## `--objects`, and the order it prints in
##
## Commits first, all of them, and only then the trees and blobs they reach
## (`list-objects.c:traverse_commit_list`).  Each non-commit is printed with
## the **path it was found at**, which is what lets a packer group objects
## that are likely to delta well against each other -- and why the root tree
## of every commit prints with an empty name.
##
## Exclusions apply to objects too, and that is the whole trick behind a
## fetch: `rev-list --objects HEAD ^origin/main` is exactly the set of objects
## the other side is missing.

import std/[sets, strutils]
import ../cli, ../objects, ../oid, ../pretty, ../repository, ../revision,
       ../revwalk, ../util

const usageText = """usage: gittle rev-list [<options>] <commit>… [[--] <path>…]

   -n <n>, --max-count=<n>   stop after <n> commits
   --skip=<n>                skip the first <n>
   --since=<date>, --until=<date>
   --merges, --no-merges     only, or never, commits with two or more parents
   --first-parent            follow only the first parent of a merge
   --not                     invert `^` for every following argument
   --all, --branches[=<pat>], --tags[=<pat>], --remotes[=<pat>]
   --stdin                   read further arguments from standard input
   --topo-order, --date-order, --reverse, --no-walk[=(sorted|unsorted)]
   --parents                 print each commit's parents after it
   --left-right              mark which side of an A...B a commit came from
   --count                   print how many commits, not which
   --objects                 also print every reachable tree and blob
   --pretty[=<fmt>], --format=<fmt>, --abbrev-commit, --date=<fmt>"""

proc cmdRevList*(c: Ctx, args: seq[string]): int =
  if args.len == 0:
    # git's usage exit for a command given nothing at all.  With any option at
    # all but no revision it is not an error -- there is simply nothing to
    # list, which is what makes `rev-list --objects --stdin` work.
    stderr.write usageText & "\n"
    return 129
  let repo = c.repo
  let w = newRevWalk(repo)
  var ri = initRevInput()
  var opts = PrettyOpts(now: dateNow())
  var pretty = false
  var showParents = false
  var abbrevLen = 0
  var i = 0

  optionValue(args, i)

  while i < args.len:
    let a = args[i]
    if ri.seenDashDash:
      ri.specs.add a
    elif a == "--":
      ri.seenDashDash = true
    elif a.len > 1 and a[0] == '-':
      if w.parseWalkOpt(ri, a, valueFor): discard
      elif a == "--parents": showParents = true
      elif a == "-h" or a == "--help":
        echo usageText
        return 0
      elif a == "--oneline":
        pretty = true
        opts.kind = pkOneline
        opts.abbrevCommit = true
      elif a == "--abbrev-commit": opts.abbrevCommit = true
      elif a == "--no-abbrev-commit": opts.abbrevCommit = false
      elif a.startsWith("--abbrev"): abbrevLen = parseInt(valueFor(a))
      elif a.startsWith("--date"): opts.dateMode = parseDateMode(valueFor(a))
      elif a.startsWith("--pretty") or a.startsWith("--format"):
        pretty = true
        parsePretty((if a.contains('='): a[a.find('=') + 1 .. ^1] else: ""), opts)
      elif a.len > 1 and a[1] in {'0' .. '9'}:
        ri.maxCount = parseInt(a[1 .. ^1])      # the bare `-5` form
      else:
        fail("unknown option '" & a & "'\n" & usageText)
    else:
      w.addRevisionArg(ri, a)
    inc i

  opts.abbrev = if abbrevLen > 0: abbrevLen else: repo.autoAbbrev
  w.finishRevInput(ri, defaultHead = false)

  var seen: HashSet[Oid]     ## objects already listed, or deliberately not

  var lines: seq[string]
  var commits: seq[Oid]
  var shown, skipped, left = 0
  for e in w.walk:
    if skipped < ri.skip:
      inc skipped
      continue
    if ri.maxCount >= 0 and shown >= ri.maxCount: break
    inc shown
    if e.left: inc left
    commits.add e.oid
    if ri.count: continue

    var line = ""
    if ri.leftRight: line.add (if e.left: "<" else: ">")
    if pretty:
      # `rev-list` puts a `commit <oid>` line above a *user* format -- which
      # is the visible difference between `rev-list --format=%s` and
      # `log --format=%s`, and the reason a script has to skip every other
      # line.  The built-in formats print their own header and `oneline`
      # begins with the name, so neither needs one
      # (`builtin/rev-list.c:show_commit`).
      if opts.kind in {pkFormat, pkTFormat}:
        line.add "commit " & repo.headerName(e.oid, opts) & "\n"
      line.add formatOne(repo, e.oid, e.commit, opts)
      if opts.kind notin {pkOneline, pkTFormat}: line.add "\n"
    else:
      line.add repo.headerName(e.oid, opts)
      # The parents are never abbreviated, even under `--abbrev-commit`.
      if showParents:
        for p in e.parents: line.add " " & $p
      line.add "\n"
    lines.add line

  if ri.count:
    # `--left-right --count` is the ahead/behind pair, tab separated, which is
    # what every "N ahead, M behind" display is built on.
    echo (if ri.leftRight: $left & "\t" & $(shown - left) else: $shown)
    return 0
  if ri.reverse:
    for k in 0 ..< lines.len div 2:
      swap(lines[k], lines[lines.high - k])
    for k in 0 ..< commits.len div 2:
      swap(commits[k], commits[commits.high - k])
  for l in lines: stdout.write l
  if ri.objects:
    repo.edgeTrees(w, commits, seen)
    # Tags first, named as the tag object names *itself* rather than as the ref
    # that found it, then every commit's tree in the order the commits came out
    # (`revision.c:prepare_revision_walk` refills `pending` in that order).
    var excludedTips: HashSet[Oid]
    for p in ri.points:
      if p.uninteresting: excludedTips.incl p.oid
    for p in ri.points:
      if p.oid in excludedTips or p.oid in seen: continue
      if repo.objectInfo(p.oid).kind != otTag: continue
      seen.incl p.oid
      echo $p.oid & " " & headerField(repo.readObject(p.oid).data, "tag")
    for o in commits:
      repo.walkObjects(repo.readCommit(o).tree, "", seen,
                       proc (x: Oid, p: string) = echo $x & " " & p)
  stdout.flushFile()
  0
