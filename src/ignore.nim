## `.gitignore`: deciding whether an untracked path should be seen at all.
##
## plan.md §4 specifies this engine; the interesting half is that it is *five*
## commands' engine, not a flag on one.  `add`, `status`, `clean`, `ls-files`
## and `check-ignore` all ask it the same question, and `status` on a real
## project is unusable without it -- an ordinary working tree would drown in
## build output.
##
## The matching itself is [glob.nim](glob.nim); this module is the adapter in
## front of it, and what it adds is four things git's own `dir.c` adds:
## negation, anchoring, the basename rule, and the precedence between files.
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
## | `*` `?` `[…]` `**` | `globMatch`, in pathname mode |
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
    ## One line, split into the parts the matcher and the reporter each want.
    pat: string       ## `!`, a trailing `/` and an anchoring `/` already gone
    raw: string       ## the line as written, which `check-ignore -v` prints
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
    text*: string     ## as written, `!` and trailing `/` included

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
    if line[i] == '\\':
      inc i
      if i >= line.len: return line
      lastSpace = -1
    elif line[i] == ' ':
      if lastSpace < 0: lastSpace = i
    else: lastSpace = -1
    inc i
  if lastSpace >= 0: line[0 ..< lastSpace] else: line

proc parsePattern(raw: string): Pattern =
  ## One `.gitignore` line into a pattern: the `!`, the trailing `/`, the
  ## anchoring slash, and which of the two matching rules the line asks for.
  ##
  ## Everything the matcher does not want is stripped here rather than on
  ## every comparison, and the line as written is kept beside the result
  ## because `check-ignore -v` has to quote it back.
  result.raw = raw
  var p = raw
  if p.len > 0 and p[0] == '!':
    result.negated = true
    p = p[1 .. ^1]
  if p.len > 0 and p[^1] == '/':
    result.mustBeDir = true
    p = p[0 ..< p.len - 1]
  # NODIR is decided *after* the trailing slash is removed, which is why `sub/`
  # matches a directory called `sub` at any depth rather than only at the root,
  # and *before* the anchoring one is, because `/sub` is anchored to the root.
  result.noDir = not p.contains('/')
  if p.len > 0 and p[0] == '/': p = p[1 .. ^1]
  result.pat = p

proc readPatternList(path, base, src: string): PatternList =
  ## Every pattern in one file, with the directory it is relative to and a
  ## name for `check-ignore -v` to report.
  result.base = base
  result.src = src
  if not fileExists(path): return
  var lineNo = 0
  for rawLine in readWholeFile(path).split('\n'):
    inc lineNo
    var line = rawLine
    if line.endsWith("\r"): line.setLen(line.len - 1)
    if line.len == 0 or line[0] == '#': continue
    line = trimTrailingSpaces(line)
    if line.len == 0: continue
    result.patterns.add parsePattern(line)
    result.patterns[^1].lineNo = lineNo

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

func lastMatchIn(pl: PatternList, path: string, isDir: bool): Decision =
  ## The last matching pattern in one list, scanned backwards so the first hit
  ## found is the last line written -- which is how a later `!pat` overrides an
  ## earlier rule.
  ##
  ## Two shapes of pattern, settled when the line was parsed:
  ##
  ## * no `/` in it -- match the path's **last component**, at any depth, with
  ##   wildcards free to match anything (`dir.c:match_basename`);
  ## * otherwise -- match the path **relative to this file's own directory**,
  ##   with `*` stopping at a `/` (`dir.c:match_pathname`).
  let base = path[path.rfind('/') + 1 .. ^1]
  for i in countdown(pl.patterns.high, 0):
    let p = pl.patterns[i]
    let hit =
      if p.mustBeDir and not isDir: false
      elif p.noDir: globMatch(p.pat, base, {})
      elif path.len > pl.base.len and path.startsWith(pl.base):
        globMatch(p.pat, path[pl.base.len .. ^1], {gfPathname})
      else: false
    if hit:
      return Decision(found: true, ignored: not p.negated, src: pl.src,
                      lineNo: p.lineNo, text: p.raw)

# ---------------------------------------------------------------------------
# The stack
# ---------------------------------------------------------------------------

proc newIgnore*(repo: Repository): Ignore =
  ## The two whole-repository lists, read once.  The per-directory ones are
  ## read lazily and cached, because a query about `a/b/c` needs three of them
  ## and a walk of a large tree would otherwise reread each one per file.
  result = Ignore(workTree: repo.workTree)
  var excludesFile = repo.cfg.get("core.excludesFile")
  if excludesFile.len == 0:
    excludesFile = getEnv("XDG_CONFIG_HOME", getEnv("HOME") / ".config") /
                   "git" / "ignore"
  elif excludesFile.startsWith("~/"):
    excludesFile = getEnv("HOME") / excludesFile[2 .. ^1]
  # `check-ignore -v` prints the file a pattern came from, and git prints it
  # the way a command run at the top of the working tree would spell it --
  # `.git/info/exclude`, not the absolute path it opened.
  let info = repo.commonDir / "info" / "exclude"
  var infoName = info
  if repo.workTree.len > 0 and infoName.startsWith(repo.workTree & "/"):
    infoName = infoName[repo.workTree.len + 1 .. ^1]
  # Order matters: scanned in reverse, so `info/exclude` is consulted before
  # the user's global file, which is the precedence plan.md §4 specifies.
  result.fileLists.add readPatternList(excludesFile, "", excludesFile)
  result.fileLists.add readPatternList(info, "", infoName)

proc newEmptyIgnore*(repo: Repository): Ignore =
  ## An engine with no files behind it at all.  `clean -x` is the one caller:
  ## it says "there are no ignore rules", so the standard files are not read
  ## and only `-e` patterns remain.
  Ignore(workTree: repo.workTree, noFiles: true)

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
  ##
  ## git has one list above all of these -- `clean -e <pattern>` /
  ## `--exclude` -- and gittle has no caller for it: `clean` refuses `-e` by
  ## name (docs/minimize.md §3.5, and `clean -x` means "there are no ignore
  ## files" rather than "delete ignored files too").  It goes with the option
  ## rather than waiting for a second caller that R7 says not to build for.
  if ig == nil: return
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
