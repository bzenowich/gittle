## Pathspecs: the argument type nearly every command's `<path>…` really is.
##
## A pathspec is not a filename and not quite a glob.  Four things happen to
## one before it matches anything:
##
## 1. **It is relative to the current directory**, not the working-tree root.
##    `gittle add doc` inside `src/` means `src/doc`.  Everything downstream
##    works in root-relative paths, so the prefix is applied once, here.
## 2. **Magic may be attached**, either long -- `:(glob,icase)*.c` -- or short:
##    `:/` for `top`, `:!` or `:^` for `exclude`.
## 3. **A bare name matches the directory's whole subtree.**  `gittle add
##    Documentation` stages everything beneath it; no wildcard is involved.
## 4. **Wildcards cross `/` by default.**  `ls-files '*.c'` finds 641 files in
##    the repository next door where `:(glob)*.c` finds 244 -- the glob magic
##    is what makes `*` stop at a directory separator, which is the opposite of
##    what most people expect from the name.
##
## Points 3 and 4 are the whole of what this module adds to
## [glob.nim](glob.nim); the magic words are a table that turns into the
## matcher's two flags, and the subtree rule is a prefix comparison in front of
## it.  So the two `:(…)` words that sound like matcher features --
## `glob` and `icase` -- are `gfPathname` and `gfIgnoreCase`, and nothing else.
##
## Magic gittle implements: `literal`, `glob`, `icase`, `top`, `exclude`.
## `attr` needs gitattributes, which decision 6 cuts.  An unknown magic word is
## refused rather than ignored -- silently matching more than was asked for is
## how a `clean` deletes the wrong thing.
##
## ## Exclusion is not a pattern, it is a filter
##
## `:!pat` does not *match* anything; it removes what other items matched.  So
## a pathspec of nothing but exclusions matches everything else, and one
## positive item plus an exclusion matches the difference.  Writing exclusions
## as ordinary items that happen to be negative gets this wrong in both cases.

import std/[os, strutils]
import glob, util

type
  PathspecItem = object
    raw: string          ## as typed, for `--error-unmatch` and error messages
    pattern: string      ## root-relative, after the prefix and magic are applied
    flags: set[GlobFlag] ## `:(glob)` is `gfPathname`, `:(icase)` is `gfIgnoreCase`
    exclude: bool
    literal: bool        ## no wildcards; the bytes mean themselves
    wildcardAt: int      ## offset of the first wildcard, or the pattern length

  Pathspec* = object
    items: seq[PathspecItem]
    prefix*: string      ## the current directory, root-relative, "" or "sub/"

  PathMatch* = enum
    ## How an item matched, in git's own order: a stronger match on any one
    ## path outranks a weaker one on another (`ce_path_match` keeps the max).
    pmNone, pmRecursive, pmFnmatch, pmExact

const wildcardChars = {'*', '?', '[', '\\'}

func stripSlashes(s: string): string =
  ## `foo/` and `foo` name the same thing to a pathspec, and a leading `/` in a
  ## pathspec is not an anchor the way it is in `.gitignore` -- git strips it.
  s.strip(chars = {'/'})

proc applyPrefix(pattern, prefix: string, top: bool): string =
  ## Resolve a pathspec against the directory it was typed in.
  ##
  ## `..` has to be honored, because `gittle log ../lib` is an ordinary thing
  ## to type; `normalizedPath` does that, and a result that climbs above the
  ## working tree is refused rather than silently matching nothing.
  ##
  ## A `:(top)` item skips all of it and means its bytes.  That is not a
  ## shortcut: git normalises only the items it applies a prefix to, so
  ## `:(top).` is the literal path `.` and matches nothing, where a bare `.`
  ## is the whole tree.  Collapsing both would make `:(top).` list everything.
  if top: return stripSlashes(pattern)
  result = stripSlashes((prefix & pattern).normalizedPath)
  failIf(result == ".." or result.startsWith("../"),
         "'" & pattern & "' is outside the repository")
  if result == ".": result = ""

proc inPrefix*(path, prefix: string): string =
  ## A plain path name, as typed in the directory `prefix`, made root-relative.
  ##
  ## Not everything that takes a path takes a *pathspec*: `mv`, `rm`'s working
  ## tree half and `check-ignore` all name files outright, and they resolve
  ## `..` the same way a pathspec does (`prefix_path`).
  applyPrefix(path, prefix, false)

proc parseItem(spec, prefix: string): PathspecItem =
  ## One pathspec into its parts: the magic (`:(top)`, `:/`, `:!`), the
  ## prefix-relative path, and the literal prefix.
  ##
  ## The literal prefix -- everything before the first wildcard -- is what a
  ## directory walk prunes on, so it is measured once here rather than per
  ## candidate path.  A `:(literal)` item has no wildcards at all, so its whole
  ## pattern is literal prefix.
  result.raw = spec
  var top = false
  var i = 0
  var pattern = spec

  if spec.len > 0 and spec[0] == ':':
    inc i
    if i < spec.len and spec[i] == '(':
      let close = spec.find(')', i)
      failIf(close < 0, "missing ')' at the end of pathspec magic in '" & spec & "'")
      for word in spec[i + 1 ..< close].split(','):
        case word.strip()
        of "": discard
        of "top": top = true
        of "literal": result.literal = true
        of "glob": result.flags.incl gfPathname
        of "icase": result.flags.incl gfIgnoreCase
        of "exclude": result.exclude = true
        else: fail("Invalid pathspec magic '" & word & "' in '" & spec & "'\n" &
                   "  gittle understands top, literal, glob, icase and exclude")
      i = close + 1
    else:
      # The short form: a run of one-character signatures, ending at `:` or at
      # the first character that is not one.
      while i < spec.len and spec[i] in {'/', '!', '^', ':'}:
        let sig = spec[i]
        inc i
        if sig == ':': break
        if sig == '/': top = true else: result.exclude = true
    pattern = spec[i .. ^1]

  failIf(result.literal and gfPathname in result.flags,
         "'literal' and 'glob' are incompatible in '" & spec & "'")
  result.pattern = applyPrefix(pattern, prefix, top)
  let w = result.pattern.find(wildcardChars)
  result.wildcardAt = if result.literal or w < 0: result.pattern.len else: w

proc parsePathspec*(specs: openArray[string], prefix = "",
                    implicitPrefix = false): Pathspec =
  ## `implicitPrefix` is git's `PATHSPEC_PREFER_CWD`: with no pathspec at all,
  ## the current directory becomes one.  It is what makes `ls-files` in a
  ## subdirectory list that subdirectory rather than the whole repository --
  ## and it must stay opt-in, because the commands that took the *other*
  ## choice took it deliberately.  `add -A` with no pathspec has meant the
  ## whole tree since git 2.0, and `log` with no pathspec means no path limit.
  result.prefix = prefix
  if specs.len == 0:
    if implicitPrefix and prefix.len > 0:
      result.items.add parseItem(".", prefix)
    return
  for s in specs: result.items.add parseItem(s, prefix)

# No items: matches everything.
func isEmpty*(ps: Pathspec): bool = ps.items.len == 0

func matchItem(it: PathspecItem, path: string): PathMatch =
  ## One item against one root-relative path, and *how* it matched.
  ##
  ## The subtree rule ("a directory name matches everything under it") applies
  ## to the default and literal forms.  Under `:(glob)` it does not: that magic
  ## exists to say "match exactly this shape", and the subtree rule would
  ## silently widen it again.
  ##
  ## Which of the three kinds it was is not decoration.  `rm` refuses a
  ## directory named without `-r`, and the only thing that distinguishes
  ## `rm dir` from `rm 'dir/*'` -- both of which name the same files -- is
  ## that the first matched them *recursively* and the second by wildcard
  ## (`dir.c:match_pathspec_item`).
  let n = it.pattern.len
  if n == 0: return pmRecursive                 # the whole tree
  let icase = gfIgnoreCase in it.flags
  if (if icase: cmpIgnoreCase(path, it.pattern) == 0 else: path == it.pattern):
    return pmExact
  if gfPathname notin it.flags and path.len > n and path[n] == '/' and
     (if icase: cmpIgnoreCase(path[0 ..< n], it.pattern) == 0
      else: path.startsWith(it.pattern)):
    return pmRecursive
  if it.literal: return pmNone
  if globMatch(it.pattern, path, it.flags): pmFnmatch else: pmNone

func matchesItem(it: PathspecItem, path: string): bool =
  ## Does the item match the path at all (exactly or by prefix)?
  it.matchItem(path) != pmNone

func matchesAny(it: PathspecItem, paths: openArray[string]): bool =
  ## Does the item match any one of these paths?
  for path in paths:
    if it.matchesItem(path): return true

func matches*(ps: Pathspec, path: string): bool =
  ## An empty pathspec matches everything -- that is what makes `gittle add -A`
  ## with no arguments mean the whole tree.
  var sawPositive = false
  var matched = false
  for it in ps.items:
    if it.exclude:
      if it.matchesItem(path): return false
    else:
      sawPositive = true
      if it.matchesItem(path): matched = true
  matched or not sawPositive

func mightMatchDir*(ps: Pathspec, dir: string): bool =
  ## Is it worth walking into this directory?
  ##
  ## Purely an optimisation, and it must never answer `false` for a directory
  ## that could contain a match.  A positive item says yes for any of four
  ## reasons, in the order tested: it matches everything; the directory is the
  ## root; the directory is itself matched; the directory is an ancestor of the
  ## item's literal prefix (`add src/x` must still descend into `src`); or a
  ## wildcard early enough in the item could reach anywhere below here, at
  ## which point there is nothing left to prune on.
  if ps.isEmpty: return true
  for it in ps.items:
    if it.exclude: continue
    if it.pattern.len == 0 or dir.len == 0 or it.matchesItem(dir) or
       it.pattern.startsWith(dir & "/") or
       (it.wildcardAt < it.pattern.len and
        it.pattern[0 ..< it.wildcardAt].count('/') <= dir.count('/') + 1):
      return true
  false

iterator literalPaths*(ps: Pathspec): string =
  ## The items that name a path outright, with no wildcard and no exclusion.
  ## `add` needs these: a path typed in full is checked against the ignore
  ## rules and reported, where one that only a wildcard reached is skipped.
  for it in ps.items:
    if not it.exclude and it.wildcardAt >= it.pattern.len and it.pattern.len > 0:
      yield it.pattern

func firstUnmatched*(ps: Pathspec, paths: openArray[string]): string =
  ## The first item that matched nothing in `paths`, as the user spelled it,
  ## or `""` if they all matched something.
  ##
  ## Three commands need this and each reports it differently -- `add` and
  ## `commit` make it fatal, `ls-files --error-unmatch` makes it exit status 1
  ## -- so the question lives here and the answer is the caller's business.
  ## It is asked per *item*, not per pathspec, because that is what the
  ## message quotes back.
  for it in ps.items:
    if not it.exclude and not it.matchesAny(paths): return it.raw
  ""

func itemCount*(ps: Pathspec): int = ps.items.len
func itemRaw*(ps: Pathspec, i: int): string = ps.items[i].raw

proc matchKinds*(ps: Pathspec, paths: openArray[string]): seq[PathMatch] =
  ## For each item, the strongest way it matched any of `paths`.  `rm` needs
  ## it per item and not per path: the question it asks is "did this argument
  ## name a directory", and only the argument can answer that.
  result = newSeq[PathMatch](ps.items.len)
  for i, it in ps.items:
    if it.exclude: continue
    for path in paths:
      let m = it.matchItem(path)
      if m > result[i]: result[i] = m

proc relativeTo*(path, prefix: string): string =
  ## A root-relative path as the user should see it: relative to the directory
  ## the command was run in.  git prints `../abspath.c` for something above
  ## that directory, and no leading `./` for the common case.
  ##
  ## Free of `Pathspec` because three commands need it without having one to
  ## hand: `status` and `grep` print every path this way by default, and
  ## `diff` prints none of them this way -- a patch is always root-relative,
  ## because it has to apply from the root.
  if prefix.len == 0: return path
  if path.startsWith(prefix): return path[prefix.len .. ^1]
  relativePath(path, prefix.strip(leading = false, chars = {'/'}))

proc displayPath*(ps: Pathspec, path: string): string =
  ## The path as a command should print it: relative to where it was run.
  relativeTo(path, ps.prefix)
