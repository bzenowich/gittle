## `.gitignore`: deciding whether an untracked path should be seen at all.
##
## plan.md §4 specifies this engine; the interesting half is that it is *five*
## commands' engine, not a flag on one.  `add`, `status`, `clean`, `ls-files`
## and `check-ignore` all ask it the same question, and `status` on a real
## project is unusable without it -- an ordinary working tree would drown in
## build output.
##
## ## The sources, and how they are consulted
##
## For one path, in this order, and the **first list with any matching pattern
## decides** (`dir.c:last_matching_pattern_from_lists`):
##
## 1. patterns given on the command line (`clean -e`);
## 2. the `.gitignore` in the path's own directory, then its parent's, and so
##    on up to the working-tree root -- *deepest first*;
## 3. `$GIT_COMMON_DIR/info/exclude` -- the *common* directory, so linked
##    worktrees share it;
## 4. the file named by `core.excludesFile`, default `~/.config/git/ignore`.
##
## Within one list the **last** matching pattern decides, so a later `!pat`
## re-includes what an earlier one excluded.  Those are two different rules and
## both matter: the first is about files, the second about lines.
##
## ## The patterns
##
## | Form | Meaning |
## |---|---|
## | blank, or `#…` | nothing; a literal `#` is written `\#` |
## | trailing spaces | dropped unless escaped `\ ` |
## | `!pat` | re-include |
## | `pat/` | directories only |
## | a `/` anywhere but the end | anchored to this file's own directory |
## | no `/` at all | matches a **basename**, at any depth |
## | `*` `?` `[…]` `**` | the phase-2 glob engine, in pathname mode |
##
## The basename rule is the one the documentation hides.  gitignore(5) says a
## pattern is "checked against the pathname relative to the location of the
## .gitignore file", which describes only the anchored case; git's actual test
## is `PATTERN_FLAG_NODIR` plus `match_basename`, and an implementation written
## from the prose excludes far too little.
##
## ## The trap
##
## **You cannot re-include a file whose parent directory is excluded.**  git
## never descends into an excluded directory, so `!sub/keep.txt` after `sub/`
## does nothing at all.  In a traversal that falls out for free -- a pruned
## directory is not entered.  For a path handed to us directly there is no
## traversal, so `isIgnored` tests every ancestor directory itself, top down,
## before it tests the path.  Negation implemented without this rule looks
## correct on small cases and diverges on real repositories.
##
## Ignore rules apply only to **untracked** paths.  A tracked file stays
## tracked whatever any `.gitignore` says; that is the caller's business, and
## why `add` asks this engine about its second pass only.
##
## ## Two things only `clean` and `check-ignore` need
##
## `check-ignore -v` prints *which pattern decided* and where it came from, so
## `decide` returns the pattern rather than a boolean and `isIgnored` is a
## wrapper over it.  And `clean -x` means "there are no ignore files" rather
## than "delete ignored files too" -- `newEmptyIgnore` is that: an engine with
## the `-e` patterns and nothing behind them.

import std/[os, strutils, tables]
import glob, repository, util

type
  Pattern = object
    pat: string       ## with `!` and any trailing `/` already removed
    negated: bool
    mustBeDir: bool
    noDir: bool       ## no `/` in it, so it matches a basename at any depth
    lineNo: int       ## where it was written, for `check-ignore -v`

  PatternList = object
    base: string      ## root-relative directory, "" or ending in `/`
    src: string       ## the file it was read from, as `check-ignore -v` names it
    patterns: seq[Pattern]

  Ignore* = ref object
    workTree: string
    noFiles: bool                 ## `clean -x`: consult no pattern file at all
    cmdline: PatternList          ## `clean -e`, which outranks every file
    fileLists: seq[PatternList]   ## excludesFile, then info/exclude
    dirLists: Table[string, PatternList]

  Decision* = object
    ## What the first list with an opinion said.  `found` and `ignored` are
    ## different questions: "no pattern matched" is not "a `!` matched".
    ##
    ## The three fields after them are the pattern itself, which only
    ## `check-ignore -v` wants -- but it wants the *deciding* one, and by the
    ## time a `bool` has come back out of here that is no longer recoverable.
    found*: bool
    ignored*: bool
    src*: string      ## the pattern file
    lineNo*: int      ## 1-based, counting every line including blanks
    text*: string     ## as written, `!` and trailing `/` restored

# ---------------------------------------------------------------------------
# Reading a pattern file
# ---------------------------------------------------------------------------

func trimTrailingSpaces(line: string): string =
  ## `dir.c:trim_trailing_spaces`.  Spaces at the end are noise from an editor
  ## unless they were escaped, and a backslash protects the character after it
  ## -- including a space, which is the whole reason a file name ending in one
  ## can be listed at all.
  var lastSpace = -1
  var i = 0
  while i < line.len:
    case line[i]
    of ' ':
      if lastSpace < 0: lastSpace = i
    of '\\':
      inc i
      if i >= line.len: return line
      lastSpace = -1
    else: lastSpace = -1
    inc i
  if lastSpace >= 0: line[0 ..< lastSpace] else: line

proc parsePattern(raw: string): Pattern =
  ## One `.gitignore` line into a pattern: the `!`, the trailing `/`, the
  ## anchoring slash, and the escapes.
  var p = raw
  if p.len > 0 and p[0] == '!':
    result.negated = true
    p = p[1 .. ^1]
  if p.len > 0 and p[^1] == '/':
    result.mustBeDir = true
    p = p[0 ..< p.len - 1]
  # NODIR is decided *after* the trailing slash is removed, which is why `sub/`
  # matches a directory called `sub` at any depth rather than only at the root.
  result.noDir = not p.contains('/')
  result.pat = p

proc readPatternList(path, base, src: string): PatternList =
  ## Every pattern in one file, with the directory it is relative to and a
  ## name for `check-ignore -v` to report.
  result.base = base
  result.src = src
  if not fileExists(path): return
  var lineNo = 0
  for rawLine in readWholeFile(path).split('\n'):
    var line = rawLine
    inc lineNo
    if line.endsWith("\r"): line.setLen(line.len - 1)
    if line.len == 0 or line[0] == '#': continue
    line = trimTrailingSpaces(line)
    if line.len == 0: continue
    var p = parsePattern(line)
    p.lineNo = lineNo
    result.patterns.add p

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

func matchPathname(pat, path, base: string): bool =
  ## An anchored pattern: `base` is implicitly in front of it, and `*` stops at
  ## a `/` (`dir.c:match_pathname`).
  var p = pat
  if p.len > 0 and p[0] == '/': p = p[1 .. ^1]
  if not path.startsWith(base): return false
  let name = path[base.len .. ^1]
  name.len > 0 and globMatch(p, name, {gfPathname})

func lastMatchIn(pl: PatternList, path: string, isDir: bool): Decision =
  ## The last matching pattern in one list, scanned backwards so the first hit
  ## is the last line -- which is how a later `!pat` overrides an earlier rule.
  let slash = path.rfind('/')
  let base = if slash < 0: path else: path[slash + 1 .. ^1]
  for i in countdown(pl.patterns.high, 0):
    let p = pl.patterns[i]
    if p.mustBeDir and not isDir: continue
    let hit = if p.noDir: globMatch(p.pat, base, {})
              else: matchPathname(p.pat, path, pl.base)
    if hit:
      return Decision(found: true, ignored: not p.negated,
                      src: pl.src, lineNo: p.lineNo,
                      text: (if p.negated: "!" else: "") & p.pat &
                            (if p.mustBeDir: "/" else: ""))

# ---------------------------------------------------------------------------
# The stack
# ---------------------------------------------------------------------------

proc newIgnore*(repo: Repository): Ignore =
  ## The two whole-repository lists, read once.  The per-directory ones are
  ## read lazily and cached, because a query about `a/b/c` needs three of them
  ## and a walk of a large tree would otherwise reread each one per file.
  result = Ignore(workTree: repo.workTree, dirLists: initTable[string, PatternList]())
  var excludesFile = repo.cfg.get("core.excludesFile")
  if excludesFile.len == 0:
    let xdg = getEnv("XDG_CONFIG_HOME")
    excludesFile = if xdg.len > 0: xdg / "git" / "ignore"
                   else: getEnv("HOME") / ".config" / "git" / "ignore"
  elif excludesFile.startsWith("~/"):
    excludesFile = getEnv("HOME") / excludesFile[2 .. ^1]
  # `check-ignore -v` prints the file a pattern came from, and git prints it
  # the way a command run at the top of the working tree would spell it --
  # `.git/info/exclude`, not the absolute path it opened.
  var infoExclude = repo.commonDir / "info" / "exclude"
  if repo.workTree.len > 0 and infoExclude.startsWith(repo.workTree & "/"):
    infoExclude = infoExclude[repo.workTree.len + 1 .. ^1]
  # Order matters: scanned in reverse, so `info/exclude` is consulted before
  # the user's global file, which is the precedence plan.md §4 specifies.
  result.fileLists.add readPatternList(excludesFile, "", excludesFile)
  result.fileLists.add readPatternList(repo.commonDir / "info" / "exclude", "",
                                       infoExclude)

proc newEmptyIgnore*(repo: Repository): Ignore =
  ## An engine with no files behind it at all.  `clean -x` is the one caller:
  ## it says "there are no ignore rules", so the standard files are not read
  ## and only `-e` patterns remain.
  Ignore(workTree: repo.workTree, noFiles: true,
         dirLists: initTable[string, PatternList]())

proc addCommandLinePatterns*(ig: Ignore, pats: openArray[string]) =
  ## `clean -e <pattern>`: the highest-precedence list, consulted before any
  ## file.  git numbers these `-(i+1)` in `check-ignore -v` output; nothing in
  ## v1 prints them, so they are numbered in order like everything else.
  ig.cmdline.src = "--exclude option"
  for i, raw in pats:
    var p = parsePattern(raw)
    p.lineNo = -(i + 1)
    ig.cmdline.patterns.add p

proc listFor(ig: Ignore, dir: string): PatternList =
  ## The `.gitignore` sitting in `dir` (root-relative, "" or ending in `/`).
  if ig.noFiles: return PatternList(base: dir)
  if not ig.dirLists.hasKey(dir):
    ig.dirLists[dir] = readPatternList(ig.workTree / (dir & ".gitignore"), dir,
                                       dir & ".gitignore")
  ig.dirLists[dir]

proc lastMatch(ig: Ignore, path: string, isDir: bool): Decision =
  ## What the rules say about this path on its own, ignoring its ancestors.
  ## `isIgnored` adds the ancestor rule on top.
  ##
  ## A nil `Ignore` excludes nothing: that is the plumbing default, where
  ## `ls-files -o` without `--exclude-standard` lists build output too.
  ##
  ## Deepest `.gitignore` first, up to the root, then the whole-repository
  ## lists in reverse.  The first list with any opinion wins outright, even if
  ## a shallower list has a more specific pattern -- that is what "deeper files
  ## override shallower ones" means.
  if ig == nil: return
  result = ig.cmdline.lastMatchIn(path, isDir)
  if result.found: return
  var dir = path
  while true:
    let slash = dir.rfind('/')
    dir = if slash < 0: "" else: dir[0 .. slash]     # keeps the trailing '/'
    result = ig.listFor(dir).lastMatchIn(path, isDir)
    if result.found: return
    if dir.len == 0: break
    dir.setLen(dir.len - 1)
  for i in countdown(ig.fileLists.high, 0):
    result = ig.fileLists[i].lastMatchIn(path, isDir)
    if result.found: return

proc decide*(ig: Ignore, path: string, isDir: bool): Decision =
  ## Which pattern settles this path, taking its ancestors into account?
  ##
  ## Top down, because an excluded directory settles every path beneath it and
  ## no `!` in a deeper file can undo that -- git would never have descended
  ## far enough to read it.  An ancestor only decides when it is *excluded*: a
  ## `!` matching a directory says nothing about what is inside it, which is
  ## why `dir.c:prep_exclude` drops a negative match before returning.
  var at = 0
  while true:
    let slash = path.find('/', at)
    if slash < 0: break
    let d = ig.lastMatch(path[0 ..< slash], true)
    if d.ignored: return d
    at = slash + 1
  ig.lastMatch(path, isDir)

proc isIgnored*(ig: Ignore, path: string, isDir: bool): bool =
  ## Is the path ignored?  `decide` says by which pattern.
  ig.decide(path, isDir).ignored
