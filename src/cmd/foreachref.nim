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
import ../cli, ../reffilter, ../refs, ../repository, ../revision, ../util

const
  usageText = """usage: gittle for-each-ref [<options>] [<pattern>…]

   --count=<n>       show at most <n> refs
   --sort=<key>      sort by a field; repeatable, last key is primary
   --format=<fmt>    print each ref through a format string
   --contains [<commit>], --no-contains [<commit>]
   --merged [<commit>], --no-merged [<commit>]
   --points-at <object>"""
  defaultFormat = "%(objectname) %(objecttype)\t%(refname)"

proc parseFilterOpt*(c: Ctx, f: var RefFilter, a: string,
                     valueFor: proc (a: string, dflt: string): string): bool =
  ## The five selection options `for-each-ref`, `branch` and `tag` share.
  ## Each takes an optional commit that defaults to HEAD, which is why the
  ## value getter has to be handed a default rather than demanding one.
  let name = if a.contains('='): a[0 ..< a.find('=')] else: a
  case name
  of "--contains": f.contains.add c.repo.resolveCommittish(valueFor(a, "HEAD"))
  of "--no-contains": f.noContains.add c.repo.resolveCommittish(valueFor(a, "HEAD"))
  of "--merged": f.merged.add c.repo.resolveCommittish(valueFor(a, "HEAD"))
  of "--no-merged": f.noMerged.add c.repo.resolveCommittish(valueFor(a, "HEAD"))
  of "--points-at": f.pointsAt.add c.repo.resolveRevish(valueFor(a, "HEAD"))
  of "--sort": f.sortKeys.add valueFor(a, "")
  else: return false
  true

proc cmdForEachRef*(c: Ctx, args: seq[string]): int =
  var format = defaultFormat
  var f = RefFilter(matchAsPath: true)
  var i = 0
  var noMoreOpts = false

  optionValue(args, i)

  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-': f.patterns.add a
    elif a == "--": noMoreOpts = true
    elif a.startsWith("--format"): format = valueFor(a, "")
    elif a.startsWith("--count"): f.count = parseInt(valueFor(a, ""))
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif parseFilterOpt(c, f, a, valueFor): discard
    else: fail("unknown option '" & a & "'\n" & usageText)
    inc i

  var rows = c.repo.collectRefs([refsPrefix], f)
  for i in 0 ..< rows.len:
    stdout.write c.repo.expand(rows[i], format), "\n"
  stdout.flushFile()
  0
