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


const
  synopsis = "[<options>] <commit>… [[--] <path>…]"
  options = [
    opt("--oneline", help = "one line per commit: abbreviated ID and subject"),
    opt("--abbrev-commit", help = "abbreviate the commit ID"),
    opt("--no-abbrev-commit"),
    opt("--abbrev", okValue, arg = "<n>", help = "abbreviate object IDs to <n> digits"),
    opt("--date", okValue, arg = "<format>", help = "the date format"),
    opt("--pretty|--format", okOptValue, key = "format", arg = "[=<format>]",
        help = "print commits through a format, not as bare IDs"),
  ]

proc cmdRevList*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, replay the walk options and revisions in order,
  ## then walk and print IDs, counts, or formatted commits.
  if args.len == 0:
    stderr.write usage("rev-list", synopsis, @options & @walkOptions) & "\n"
    return 129
  let repo = c.repo
  let p = parse(@options & @walkOptions, args, "rev-list", synopsis, numeric = true)
  let w = newRevWalk(repo)
  var ri = initRevInput()
  var opts = PrettyOpts(now: dateNow())
  var pretty = false
  var showParents = false
  var abbrevLen = 0
  for (k, v) in p.occurrences:
    if k == "": w.addRevisionArg(ri, v)
    elif k == "--": ri.seenDashDash = true
    elif w.applyWalkOpt(ri, k, v): discard
    else:
      case k
      of "parents": showParents = true
      of "oneline": (pretty = true; opts.kind = pkOneline; opts.abbrevCommit = true)
      of "abbrev-commit": opts.abbrevCommit = true
      of "no-abbrev-commit": opts.abbrevCommit = false
      of "abbrev": abbrevLen = parseInt(v)
      of "date": opts.dateMode = parseDateMode(v)
      of "format": (pretty = true; parsePretty(v, opts))
      else: discard
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
