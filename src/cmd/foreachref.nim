## `for-each-ref` -- list refs through a format string.
##
## In scope (docs/05 `for-each-ref-options`): `<pattern>…`, `--count`,
## `--sort`, `--format`, `--contains`, `--no-contains`, `--merged`,
## `--no-merged`, `--points-at`.
##
## ## What this command is for
##
## git's `ref-filter.c` is around three thousand lines because `for-each-ref`
## is the engine behind `git branch`, `git tag` and `git ls-remote` as well as
## itself, and its format vocabulary reaches into commit messages, dates,
## upstream tracking and conditional output.  v1 implements the part that makes
## it useful as *plumbing*: enumerate refs, filter them, and print fields a
## script can parse.
##
## The atoms, the filters and the sort are all in `reffilter.nim`, shared with
## `branch` and `tag`; what is left here is the argument parsing and the
## default format.

import std/strutils
import ../cli, ../reffilter, ../refs, ../repository, ../revision

const
  defaultFormat = "%(objectname) %(objecttype)\t%(refname)"
  filterOptions* = [
    ## The ref-filter family (`ref-filter.c`), shared with `branch`: each
    ## takes an optional commit, HEAD when none is given.
    opt("--contains", okOptNext, arg = "[<commit>]", help = "only refs containing the commit"),
    opt("--no-contains", okOptNext, arg = "[<commit>]", help = "only refs not containing it"),
    opt("--merged", okOptNext, arg = "[<commit>]", help = "only refs reachable from the commit"),
    opt("--no-merged", okOptNext, arg = "[<commit>]", help = "only refs not reachable from it"),
    opt("--points-at", okOptNext, arg = "[<object>]", help = "only refs pointing at the object"),
    opt("--sort", okValue, arg = "<key>", help = "sort by a field; repeatable, last key is primary"),
  ]
  options = [
    opt("--count", okValue, arg = "<n>", help = "show at most <n> refs"),
    opt("--format", okValue, arg = "<fmt>", help = "print each ref through a format string"),
  ]

proc applyFilterOpts*(c: Ctx, o: Opts, f: var RefFilter) =
  ## The filter half of a parse, for any command whose table includes rows
  ## from `filterOptions` (or a subset of them, as `branch`'s does).
  for (k, v) in o.occurrences:
    let at = if v.len == 0: "HEAD" else: v
    case k
    of "contains": f.contains.add c.repo.resolveCommittish(at)
    of "no-contains": f.noContains.add c.repo.resolveCommittish(at)
    of "merged": f.merged.add c.repo.resolveCommittish(at)
    of "no-merged": f.noMerged.add c.repo.resolveCommittish(at)
    of "points-at": f.pointsAt.add c.repo.resolveRevish(at)
    of "sort": f.sortKeys.add v
    else: discard

proc cmdForEachRef*(c: Ctx, args: seq[string]): int =
  ## Entry point: parse, collect the refs through the filter, expand each
  ## through the format.
  let o = parse(@options & @filterOptions, args, "for-each-ref", "[<options>] [<pattern>…]")
  var f = RefFilter(matchAsPath: true, patterns: o.args)
  applyFilterOpts(c, o, f)
  if o.has "count": f.count = parseInt(o.val "count")
  let format = o.val("format", defaultFormat)
  var rows = c.repo.collectRefs([refsPrefix], f)
  for i in 0 ..< rows.len:
    stdout.write c.repo.expand(rows[i], format), "\n"
  stdout.flushFile()
  0
