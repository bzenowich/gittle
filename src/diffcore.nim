## What gets diffed against what, and how the result is printed.
##
## `diff.nim` compares two blobs.  This is everything on either side of it:
## the option set that eight commands share (docs/03), the four ways of
## producing a list of *file pairs*, and the seven output formats.
##
## ## A diff is a list of pairs, and there are only four sources
##
## `git diff` looks like several commands but is one, parameterised by which
## two of three things it compares:
##
## | invocation | old side | new side |
## |---|---|---|
## | `diff` | the index | the working tree |
## | `diff --cached [<commit>]` | a tree (HEAD by default) | the index |
## | `diff <commit>` | a tree | the working tree |
## | `diff <a> <b>` | a tree | a tree |
## | `diff --no-index <p1> <p2>` | a file | a file |
##
## So each side is a sorted list of `(path, mode, oid)` and the pairing is one
## merge join, written once (R7).  The one asymmetry is the working tree,
## which has no object IDs of its own: an entry whose `stat` still matches the
## index borrows the index's, and one that does not is hashed.
##
## **git records the null OID for a working-tree side** in `--raw`, even
## though `-p` prints the real hash on the `index` line one moment later.  That
## is not an inconsistency to tidy away: `--raw` reports what the *index* knows,
## and a file that has been edited since it was staged genuinely has no
## recorded name.  Both behaviors are reproduced.
##
## ## What is deliberately not here
##
## **Rename and copy detection** (`-M`, `-C`).  plan.md §4 cuts it: it is
## ~2,000 lines of C for a similarity matrix, and git turns it *on by default*
## for `diff` and `log -p`.  A rename therefore shows in gittle as a deletion
## and a creation, and the oracle passes `--no-renames` for the same reason it
## passes `--no-use-mailmap` -- the difference is tested rather than hidden.
##
## **Combined diffs for merge commits** (`-c`, `--cc`).  docs/03 cuts the whole
## family; `log`/`show` print a merge commit with no diff at all, which is what
## `--diff-merges=off` does and what git did by default before 1.5.

import std/[os, posix, strutils, algorithm, unicode]
import cli, diff, index, objects, oid, pathspec, repository, trees, util

type
  DiffFormat* = enum
    dfPatch, dfRaw, dfStat, dfShortstat, dfNumstat, dfNameOnly, dfNameStatus,
    dfNone

  DiffOpts* = object
    formats*: set[DiffFormat]  ## several may be asked for at once
    ctxLen*: int
    ws*: WsMode
    abbrev*: int
    fullIndex*: bool
    noPrefix*: bool
    text*: bool                ## `-a`: never call a file binary
    reverse*: bool             ## `-R`
    nulTerminate*: bool        ## `-z`
    filter*: string            ## `--diff-filter=`, upper-case letters kept
    pickaxe*: string           ## `-S`
    color*: bool
    exitCode*: bool
    quiet*: bool
    statWidth*: int            ## `--stat=<width>`; 0 means the 80-column default

  DiffPair* = object
    ## One path, before and after.  A mode of zero means the path is absent on
    ## that side, which is how creation and deletion are represented.
    path*: string
    oldPath*: string           ## only `--no-index` names the two sides apart
    oldMode*, newMode*: uint32
    oldOid*, newOid*: Oid
    oldValid*, newValid*: bool ## is the recorded OID the real content hash?
    oldFromWork*, newFromWork*: bool  ## read that side from a file, not an object
    unmerged*: bool            ## the index holds stages here, not one entry

func oldName(p: DiffPair): string =
  ## The path on the old side: only `--no-index` names the two apart.
  if p.oldPath.len > 0: p.oldPath else: p.path

func defaultDiffOpts*(): DiffOpts =
  ## The options with nothing given: three lines of context, exact
  ## whitespace, an automatic abbreviation width.
  DiffOpts(ctxLen: 3, ws: wsExact, abbrev: 0)

func status*(p: DiffPair): char =
  ## (An unmerged path is `U` whatever its two sides look like.)
  ## The letter `--raw` and `--name-status` print.  `T` is a type change --
  ## a regular file replaced by a symlink or a gitlink -- and it matters
  ## because a patch renders it as a deletion *and* a creation rather than as
  ## a modification.
  ## The test is on `S_IFMT`, not on the object type: a symlink and a regular
  ## file are both stored as blobs, and replacing one with the other is
  ## exactly the case `T` exists for.
  if p.unmerged: 'U'
  elif p.oldMode == 0: 'A'
  elif p.newMode == 0: 'D'
  elif (p.oldMode and 0o170000'u32) != (p.newMode and 0o170000'u32): 'T'
  else: 'M'

# ---------------------------------------------------------------------------
# Option parsing, shared by diff, log and show
# ---------------------------------------------------------------------------

const diffOptions* = [
  ## docs/03: the `diff-options` family that `diff`, `log` and `show` share.
  ## A command concatenates this with its own table and hands the parse to
  ## `applyDiffOpts`.
  opt("-p|-u|--patch", help = "the patch (the default)"),
  opt("-s|--no-patch", help = "no patch; cancels every format given before it"),
  opt("--raw", help = "the raw format"),
  opt("--stat", okOptValue, arg = "[=<width>]", help = "the diffstat"),
  opt("--numstat", help = "added and deleted line counts per file"),
  opt("--shortstat", help = "the diffstat's last line only"),
  opt("--name-only", help = "changed paths"),
  opt("--name-status", help = "changed paths with their status letter"),
  opt("--full-index", help = "full object IDs on the index line"),
  opt("--no-prefix", help = "no a/ and b/ on the paths"),
  opt("-a|--text", help = "never call a file binary"),
  opt("-R", help = "swap the two sides"),
  opt("-z", help = "NUL after each path"),
  opt("--exit-code", help = "exit 1 when there were differences"),
  opt("--quiet", help = "no output; implies --exit-code"),
  opt("-w|--ignore-all-space", help = "ignore whitespace entirely"),
  opt("-b|--ignore-space-change", help = "ignore changes in the amount of whitespace"),
  opt("--ignore-space-at-eol", help = "ignore whitespace at the end of a line"),
  opt("--ignore-cr-at-eol", help = "ignore a carriage return at the end of a line"),
  opt("-U|--unified", okValue, arg = "<n>", help = "lines of context"),
  opt("--diff-filter", okValue, arg = "<letters>", help = "only these kinds of change: A D M T"),
  opt("-S", okValue, arg = "<string>", help = "changes that add or remove the string"),
  opt("--abbrev", okValue, arg = "<n>", help = "abbreviate object IDs to <n> digits"),
  opt("--color", okOptValue, arg = "[=<when>]", help = "colour: always, never or auto"),
  opt("--no-color"),
  # Everything in docs/03 that gittle does not implement, so each refuses by
  # name instead of being silently ignored.  `--no-renames` is in the list
  # because gittle never detects renames: accepting the flag would imply the
  # other setting exists.
  opt("-M|--find-renames|-C|--find-copies|--find-copies-harder|-B|--break-rewrites|-D|--irreversible-delete|--diff-algorithm|--minimal|--patience|--histogram|--anchored|--indent-heuristic|--no-indent-heuristic|-c|--cc|--dd|--diff-merges|--remerge-diff|--combined-all-paths|--word-diff|--color-words|--word-diff-regex|--color-moved|--dirstat|-X|--cumulative|--compact-summary|--summary|--binary|--check|--ws-error-highlight|--ignore-blank-lines|-I|--ignore-matching-lines|--function-context|-W|--inter-hunk-context|--src-prefix|--dst-prefix|--default-prefix|--relative|--no-relative|--textconv|--no-textconv|--ext-diff|--no-ext-diff|--submodule|--ignore-submodules|-G|--pickaxe-regex|--pickaxe-all|--find-object|-O|--skip-to|--rotate-to|--output|--line-prefix|--ita-invisible-in-index|--no-renames|--rename-empty|-t|--patch-with-raw|--patch-with-stat|--no-stat",
      okRefused, help = "docs/03"),
]

proc checkDiffOpts*(o: DiffOpts) =
  ## The one combination git rejects rather than resolving, checked where git
  ## checks it -- once, after parsing (`diff.c:diff_setup_done`) -- so that
  ## `diff -s --name-only` fails on a clean tree too, where there would
  ## otherwise be no output to notice it in.
  failIf(dfNone in o.formats and
         ({dfNameOnly, dfNameStatus} * o.formats).card > 0,
         "options '--name-only', '--name-status' and '-s' cannot be used together")

proc applyDiffOpts*(p: Opts, o: var DiffOpts) =
  ## Replay the diff options in command-line order.  The order matters for
  ## one pair: `-s` is an *assignment* -- git's
  ## `options->output_format = DIFF_FORMAT_NO_OUTPUT` -- which wipes whatever
  ## came before it, and `-p` after it turns the patch back on
  ## (`enable_patch_output` clears the bit first).  So `--stat -s` prints
  ## nothing and `-s --stat` prints a stat.
  for (k, v) in p.occurrences:
    case k
    of "patch": (o.formats.excl dfNone; o.formats.incl dfPatch)
    of "no-patch": o.formats = {dfNone}
    of "raw": o.formats.incl dfRaw
    of "stat":
      o.formats.incl dfStat
      # `--stat=<width>[,<name-width>[,<count>]]`; only the total width is in
      # scope, and the rest is refused rather than accepted and ignored.
      if v.len > 0:
        let parts = v.split(',')
        failIf(parts.len > 1,
               "--stat=<width>,<name-width> is out of scope for gittle v1")
        o.statWidth = parseInt(parts[0])
    of "numstat": o.formats.incl dfNumstat
    of "shortstat": o.formats.incl dfShortstat
    of "name-only": o.formats.incl dfNameOnly
    of "name-status": o.formats.incl dfNameStatus
    of "full-index": o.fullIndex = true
    of "no-prefix": o.noPrefix = true
    of "text": o.text = true
    of "R": o.reverse = true
    of "z": o.nulTerminate = true
    of "exit-code": o.exitCode = true
    of "quiet":
      o.quiet = true
      o.exitCode = true
      o.formats = {dfNone}
    of "ignore-all-space": o.ws = wsIgnoreAll
    of "ignore-space-change": o.ws = wsIgnoreChange
    of "ignore-space-at-eol": o.ws = wsIgnoreEol
    of "ignore-cr-at-eol": o.ws = wsIgnoreCr
    of "unified":
      # `-U<n>` implies the patch (`diff.c`: `--unified` sets DIFF_FORMAT_PATCH).
      o.ctxLen = parseInt(v)
      o.formats.incl dfPatch
    of "diff-filter":
      o.filter = v.toUpperAscii
      for c in o.filter:
        failIf(c notin {'A', 'D', 'M', 'T', '*'},
               "unsupported --diff-filter character '" & c &
               "'\n  gittle detects no renames or copies, so only A, D, M " &
               "and T can occur")
    of "S": o.pickaxe = v
    of "abbrev": o.abbrev = parseInt(v)
    of "no-color": o.color = false
    of "color":
      o.color = case (if v.len == 0: "always" else: v)
        of "always": true
        of "never": false
        of "auto": isatty(stdout.getFileHandle()) != 0
        else: fail("invalid --color argument: " & v)
    else: discard

# ---------------------------------------------------------------------------
# The four sources of pairs
# ---------------------------------------------------------------------------

type
  FileEntry = object
    path: string
    mode: uint32
    oid: Oid
    valid: bool     ## the OID really is this content's hash
    fromWork: bool
    unmerged: bool  ## a placeholder for a path the index holds in stages

proc listTree(repo: Repository, tree: Oid, ps: Pathspec): seq[FileEntry] =
  ## Every blob in a tree, full paths, in index order.  A null object ID is
  ## the *empty* tree, which is what a root commit's parent side is: it has
  ## none, and every path in it is therefore a creation.
  ##
  ## `walkTree` yields tree order, which sorts a directory's entries as though
  ## each had a trailing `/`.  The index -- and therefore the other side of
  ## every join here -- sorts by raw bytes, and the two disagree exactly when
  ## a file and a directory share a prefix (`foo.txt` against `foo/`), so the
  ## result is re-sorted rather than assumed.
  if tree.isNull: return
  for e in repo.walkTree(tree):
    if e.mode == modeTree: continue
    if not ps.matches(e.name): continue
    result.add FileEntry(path: e.name, mode: canonMode(e.mode), oid: e.oid, valid: true)
  result.sort(proc (x, y: FileEntry): int = cmp(x.path, y.path))

proc listIndex(idx: Index, ps: Pathspec, withUnmerged = false): seq[FileEntry] =
  ## `withUnmerged` adds a zero-mode placeholder for every conflicted path, so
  ## that a tree-to-index diff reports it as `U` rather than as a deletion --
  ## which is what it would look like, the stages having no stage 0 between
  ## them.  The index-to-working-tree diff does not ask for it: git shows a
  ## *combined* diff there, and combined diffs are cut (docs/03).
  var lastUnmerged = ""
  for e in idx.entries:
    if not ps.matches(e.path): continue
    if e.stage != 0:
      if withUnmerged and e.path != lastUnmerged:
        lastUnmerged = e.path
        result.add FileEntry(path: e.path, unmerged: true)
      continue
    result.add FileEntry(path: e.path, mode: canonMode(e.mode), oid: e.oid, valid: true)
  result.sort(proc (x, y: FileEntry): int = cmp(x.path, y.path))

proc listWorkTree(repo: Repository, idx: Index, ps: Pathspec): seq[FileEntry] =
  ## The working tree, seen through the index: `diff` reports changes to
  ## *tracked* files, so an untracked file is not a diff, it is `status`.
  ##
  ## An entry whose `stat` still matches keeps the index's object ID and is
  ## marked valid.  One that does not is left invalid and hashed later, only
  ## if something needs the number -- which is what makes `git diff` on a
  ## freshly checked-out tree cost one `lstat` per file.
  for e in idx.entries:
    if e.stage != 0: continue
    if not ps.matches(e.path): continue
    # A gitlink names a commit in another repository, and the path on disk is
    # that repository's directory.  Submodules are cut, so the entry is carried
    # through unchanged: reporting a type change because a directory is not a
    # regular file would be worse than saying nothing.
    if modeType(e.mode) == otCommit:
      result.add FileEntry(path: e.path, mode: e.mode, oid: e.oid, valid: true)
      continue
    let (ok, st) = statPath(repo.workTreePath(e.path))
    if not ok: continue                        # deleted; absent on this side
    var f = FileEntry(path: e.path, mode: modeForFile(st), fromWork: true)
    if e.statMatches(st) and e.size != 0:
      f.oid = e.oid
      f.valid = true
    result.add f

proc join(old, new: seq[FileEntry]): seq[DiffPair] =
  ## The merge join.  Both sides are sorted by path bytes, so one pass pairs
  ## them and every unmatched entry on either side is a deletion or a creation.
  var i = 0
  var k = 0
  while i < old.len or k < new.len:
    let c = if i >= old.len: 1
            elif k >= new.len: -1
            else: cmp(old[i].path, new[k].path)
    var p: DiffPair
    if c < 0:
      p = DiffPair(path: old[i].path, oldMode: old[i].mode, oldOid: old[i].oid,
                   oldValid: old[i].valid)
      inc i
    elif c > 0:
      p = DiffPair(path: new[k].path, newMode: new[k].mode, newOid: new[k].oid,
                   newValid: new[k].valid, newFromWork: new[k].fromWork,
                   unmerged: new[k].unmerged)
      inc k
    else:
      p = DiffPair(path: old[i].path,
                   oldMode: old[i].mode, oldOid: old[i].oid, oldValid: old[i].valid,
                   newMode: new[k].mode, newOid: new[k].oid, newValid: new[k].valid,
                   newFromWork: new[k].fromWork, unmerged: new[k].unmerged)
      inc i
      inc k
    result.add p

proc pairsTreeTree*(repo: Repository, a, b: Oid, ps: Pathspec): seq[DiffPair] =
  ## The pairs between two trees (`diff A B`).
  join(listTree(repo, a, ps), listTree(repo, b, ps))

proc pairsTreeIndex*(repo: Repository, tree: Oid, idx: Index,
                     ps: Pathspec): seq[DiffPair] =
  ## The pairs between a tree and the index (`diff --cached`).
  join(listTree(repo, tree, ps), listIndex(idx, ps, withUnmerged = true))

proc pairsIndexWork*(repo: Repository, idx: Index, ps: Pathspec): seq[DiffPair] =
  ## The pairs between the index and the working tree (plain `diff`).
  join(listIndex(idx, ps), listWorkTree(repo, idx, ps))

proc pairsTreeWork*(repo: Repository, tree: Oid, idx: Index,
                    ps: Pathspec): seq[DiffPair] =
  ## The pairs between a tree and the working tree (`diff <commit>`).
  join(listTree(repo, tree, ps), listWorkTree(repo, idx, ps))

# ---------------------------------------------------------------------------
# Content, and what counts as binary
# ---------------------------------------------------------------------------

proc fileText(repo: Repository, path: string): string =
  ## A working-tree file, or `--no-index`'s named one.  Absolute paths pass
  ## through `workTreePath` unchanged, which is what `--no-index` relies on.
  let full = if isAbsolute(path) or repo == nil: path
             else: repo.workTreePath(path)
  let (ok, st) = statPath(full)
  if not ok: return ""
  readWorkingFile(full, st)

proc oldText(repo: Repository, p: DiffPair): string =
  ## The old side's content: nothing, a file, or a blob.
  if p.oldMode == 0: ""
  elif p.oldFromWork: repo.fileText(p.oldName)
  else: repo.readObject(p.oldOid).data

proc newText(repo: Repository, p: DiffPair): string =
  ## The new side's content: nothing, a file, or a blob.
  if p.newMode == 0: ""
  elif p.newFromWork: repo.fileText(p.path)
  else: repo.readObject(p.newOid).data

proc fillOid(repo: Repository, p: var DiffPair) =
  ## A working-tree file has no recorded object ID until someone needs one.
  ## `-p` does, for the `index` line; `--raw` deliberately does not.
  if p.newMode != 0 and not p.newValid:
    p.newOid = hashObject(otBlob, repo.newText(p))
    p.newValid = true
  if p.oldMode != 0 and not p.oldValid:
    p.oldOid = hashObject(otBlob, repo.oldText(p))
    p.oldValid = true

proc changed*(repo: Repository, p: DiffPair): bool =
  ## Is this pair a change at all?
  ##
  ## Equal object IDs settle it without reading anything, which is what makes
  ## a tree-to-tree diff cheap.  A working-tree file whose `stat` moved but
  ## whose content did not has no recorded ID, so it has to be hashed -- and
  ## then it is *not* a change, which is why `git diff` prints nothing after a
  ## bare `touch`.
  if p.oldMode != p.newMode: return true
  if p.oldValid and p.newValid: return p.oldOid != p.newOid
  var q = p
  repo.fillOid(q)
  q.oldOid != q.newOid

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

func countOccurrences(hay, needle: string): int =
  ## How many times `needle` occurs in `hay`, for `-S`.
  if needle.len == 0: return 0
  var i = 0
  while true:
    let at = hay.find(needle, i)
    if at < 0: break
    inc result
    i = at + 1        # overlapping matches count, as git's `contains` counts

proc applyFilters(repo: Repository, pairs: seq[DiffPair],
                   o: DiffOpts): seq[DiffPair] =
  ## `-R`, `--diff-filter` and `-S`, in that order.
  for p0 in pairs:
    var p = p0
    if o.reverse:
      p = DiffPair(path: p0.path,
                   oldMode: p0.newMode, oldOid: p0.newOid, oldValid: p0.newValid,
                   newMode: p0.oldMode, newOid: p0.oldOid, newValid: p0.oldValid)
      # Reversing means the working tree becomes the *old* side, and there is
      # nowhere to record that; hash it now so the swap is complete.
      p.oldFromWork = p0.newFromWork
      p.newFromWork = p0.oldFromWork
      p.oldPath = p0.path
      p.path = p0.oldName
    if o.filter.len > 0 and o.filter != "*" and p.status notin o.filter:
      continue
    if o.pickaxe.len > 0 and
       countOccurrences(repo.oldText(p), o.pickaxe) ==
       countOccurrences(repo.newText(p), o.pickaxe):
      continue
    result.add p

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

const
  colReset = "\e[m"
  colMeta = "\e[1m"
  colFrag = "\e[36m"
  colOld = "\e[31m"
  colNew = "\e[32m"
    ## git's defaults (`color.diff.*` in `diff.c:parse_diff_color_slot`).
    ## Configuring them is out of scope (docs/11), so the five are constants.

proc quoteTwo(prefix, path0: string): string =
  ## `a/` and the path quoted as one string when either needs it, which is why
  ## an awkward path appears as `diff --git "a/odd name" "b/odd name"` rather
  ## than as `a/"odd name"` (`quote.c:quote_two_c_style`).
  ##
  ## A leading `/` is dropped first, which only ever happens under
  ## `--no-index` with an absolute path: git writes `a/tmp/x`, not `a//tmp/x`
  ## (`diff.c:builtin_diff`, the `name_a + (*name_a == '/')`).
  let path = if path0.len > 0 and path0[0] == '/': path0[1 .. ^1] else: path0
  if needsQuote(prefix) or needsQuote(path):
    "\"" & quoteBody(prefix) & quoteBody(path) & "\""
  else:
    prefix & path

proc abbrevOf(repo: Repository, o: DiffOpts, id: Oid, valid: bool): string =
  ## Outside a repository -- which is where `--no-index` runs -- there is
  ## nothing to check an abbreviation against, so git truncates to seven
  ## digits and hopes (`diff.c:diff_abbrev_oid`).
  if repo == nil:
    let n = if o.abbrev > 0: o.abbrev else: fallbackAbbrev
    return (if valid and not id.isNull: ($id)[0 ..< n] else: repeat('0', n))
  let n = if o.abbrev > 0: o.abbrev else: repo.autoAbbrev
  if not valid or id.isNull: repeat('0', clamp(n, minAbbrev, OidHexLen))
  else: repo.uniqueAbbrev(id, n)

proc writePatch(repo: Repository, p0: DiffPair, o: DiffOpts, out0: var string) =
  ## One file's patch.  The header is a small grammar and it is written here
  ## in the order git writes it (`diff.c:builtin_diff` and `fill_metainfo`).
  if p0.unmerged:
    # There is no single "after" to show: a combined diff is what git prints
    # here for a path both sides changed, and it is cut (docs/03).
    out0.add "* Unmerged path " & quotePath(p0.path) & "\n"
    return
  var p = p0
  repo.fillOid(p)
  # `-R` swaps the *prefixes* as well as the contents, so a reversed patch
  # reads `diff --git b/x a/x`.  git does the same (`diff.c:builtin_diff`
  # swaps `name_a`/`name_b` together with the two prefixes), and it is what
  # keeps `a/` meaning "the side the patch would apply to".
  let aPre = if o.noPrefix: "" elif o.reverse: "b/" else: "a/"
  let bPre = if o.noPrefix: "" elif o.reverse: "a/" else: "b/"

  template meta(s: string) =
    ## One header line, coloured when colour is on.
    if o.color: out0.add colMeta & s & colReset & "\n" else: out0.add s & "\n"

  meta "diff --git " & quoteTwo(aPre, p.oldName) & " " & quoteTwo(bPre, p.path)

  if p.oldMode != 0 and p.newMode != 0 and p.oldMode != p.newMode:
    meta "old mode " & formatMode(p.oldMode)
    meta "new mode " & formatMode(p.newMode)
  elif p.oldMode == 0:
    meta "new file mode " & formatMode(p.newMode)
  elif p.newMode == 0:
    meta "deleted file mode " & formatMode(p.oldMode)

  let a = repo.oldText(p)
  let b = repo.newText(p)
  if a == b and p.oldMode != p.newMode and p.oldMode != 0 and p.newMode != 0:
    return          # a pure mode change has no index line and no body

  # `--full-index` prints forty digits on both sides, including the forty
  # zeroes of an absent one -- an abbreviated null OID next to a full one
  # would not line up and could not be pasted into `git apply`.
  let hexA = if o.fullIndex: (if p.oldMode != 0: $p.oldOid else: repeat('0', OidHexLen))
             else: repo.abbrevOf(o, p.oldOid, p.oldValid and p.oldMode != 0)
  let hexB = if o.fullIndex: (if p.newMode != 0: $p.newOid else: repeat('0', OidHexLen))
             else: repo.abbrevOf(o, p.newOid, p.newValid and p.newMode != 0)
  var idx = "index " & hexA & ".." & hexB
  if p.oldMode == p.newMode: idx.add " " & formatMode(p.oldMode)
  meta idx

  if not o.text and (isBinary(a) or isBinary(b)):
    # git names the two sides the way it named them above, `/dev/null` and all.
    let an = if p.oldMode == 0: "/dev/null" else: quoteTwo(aPre, p.oldName)
    let bn = if p.newMode == 0: "/dev/null" else: quoteTwo(bPre, p.path)
    out0.add "Binary files " & an & " and " & bn & " differ\n"
    return

  let d = diffText(a, b, o.ctxLen, o.ws)
  if d.hunks.len == 0: return      # an empty creation: header only, no body

  meta "--- " & (if p.oldMode == 0: "/dev/null" else: quoteTwo(aPre, p.oldName))
  meta "+++ " & (if p.newMode == 0: "/dev/null" else: quoteTwo(bPre, p.path))

  for h in d.hunks:
    var hdr = "@@ -" & (if h.c1 == 0: $(h.s1 - 1) else: $h.s1) &
              (if h.c1 == 1: "" else: "," & $h.c1) &
              " +" & (if h.c2 == 0: $(h.s2 - 1) else: $h.s2) &
              (if h.c2 == 1: "" else: "," & $h.c2) & " @@"
    if o.color: out0.add colFrag & hdr & colReset
    else: out0.add hdr
    if h.funcName.len > 0: out0.add " " & h.funcName
    out0.add "\n"
    for l in h.lines:
      let sign = case l.kind
                 of dlContext: " "
                 of dlDelete: "-"
                 of dlAdd: "+"
      if not o.color:
        out0.add sign & l.text
      else:
        # Three shapes, and they are not symmetric (`diff.c:emit_line_0` and
        # `emit_line_ws_markup`).  A context line has no colour at all but
        # still ends in a reset; a deleted line is one red span over the sign
        # and the text together; an added line is *two* green spans, because
        # git splits the marker from the content so that a whitespace error
        # in the content can be repainted without disturbing the `+`.
        case l.kind
        of dlContext:
          out0.add " " & l.text & colReset
        of dlDelete:
          out0.add colOld & "-" & l.text & colReset
        of dlAdd:
          out0.add colNew & "+" & colReset
          if l.text.len > 0: out0.add colNew & l.text & colReset
      out0.add "\n"
      if l.noNewline:
        # git emits this through the *context* colour, which is empty by
        # default -- so under `--color` it is the bare text plus a reset
        # (`diff.c`, `DIFF_SYMBOL_CONTEXT_INCOMPLETE`).
        out0.add "\\ No newline at end of file"
        if o.color: out0.add colReset
        out0.add "\n"

proc splitTypeChange(pairs: seq[DiffPair]): seq[DiffPair] =
  ## A `T` pair becomes a deletion followed by a creation.
  ##
  ## git does this for the *patch* format only: a symlink that became a
  ## regular file has no meaningful line-by-line relationship to its target,
  ## so the two halves are printed as separate files with the same name.
  ## `--raw`, `--stat` and `--name-status` keep the single `T` record.
  for p in pairs:
    if p.status != 'T':
      result.add p
    else:
      result.add DiffPair(path: p.path, oldPath: p.oldPath,
                          oldMode: p.oldMode, oldOid: p.oldOid,
                          oldValid: p.oldValid, oldFromWork: p.oldFromWork)
      result.add DiffPair(path: p.path, oldPath: p.oldPath,
                          newMode: p.newMode, newOid: p.newOid,
                          newValid: p.newValid, newFromWork: p.newFromWork)

func summaryLine(files, insertions, deletions: int): string =
  ## ` N files changed, X insertions(+), Y deletions(-)`, with git's three
  ## rules: the singular forms, `0 files changed` on its own, and a zero count
  ## shown only when the *other* one is also zero
  ## (`diff.c:print_stat_summary_inserts_deletes`).
  if files == 0: return " 0 files changed\n"
  result = " " & $files & (if files == 1: " file changed" else: " files changed")
  if insertions > 0 or deletions == 0:
    result.add ", " & $insertions &
               (if insertions == 1: " insertion(+)" else: " insertions(+)")
  if deletions > 0 or insertions == 0:
    result.add ", " & $deletions &
               (if deletions == 1: " deletion(-)" else: " deletions(-)")
  result.add "\n"

proc writeStat(repo: Repository, pairs: seq[DiffPair], o: DiffOpts,
               out0: var string) =
  ## `--stat`: one line per file -- the name, the number of changed lines,
  ## and a bar of `+` and `-` scaled so the widest fits the line.
  ##
  ## git fits the *name* column too, truncating a long path from the left
  ## to `...`, and lets `--stat=<width>` move the right edge
  ## (`diff.c:show_stats`, and the 5/8 : 3/8 split between name and bar).
  ## That arithmetic went in the minimization pass (docs/minimize.md §3,
  ## tier 3): the count is the information and the bar is a picture of it,
  ## so a long path pushes its bar to the right rather than losing its head.
  ## The scaling rule for the bar is git's (`scale_linear`), so a diff that
  ## fits comes out identical.
  type Row = object
    name: string
    added, deleted: int
    binary, unmerged: bool
  var rows: seq[Row]
  var maxChange, maxLen, numberWidth = 0
  for p in pairs:
    var r = Row(name: quotePath(p.path), unmerged: p.unmerged)
    if not p.unmerged:
      let a = repo.oldText(p)
      let b = repo.newText(p)
      if not o.text and (isBinary(a) or isBinary(b)):
        r.binary = true
        r.deleted = a.len
        r.added = b.len
        numberWidth = 3          # the counts line up under "Bin"
      else:
        (r.added, r.deleted) = diffCounts(a, b, o.ws)
        maxChange = max(maxChange, r.added + r.deleted)
    maxLen = max(maxLen, r.name.runeLen)
    rows.add r
  if rows.len == 0: return
  numberWidth = max(numberWidth, ($maxChange).len)
  let width = if o.statWidth > 0: o.statWidth else: 80
  let graphWidth = max(width - 6 - numberWidth - maxLen, 10)
  var totalAdd, totalDel = 0
  for r in rows:
    out0.add " " & r.name & repeat(' ', maxLen - r.name.runeLen) & " | "
    if r.unmerged:
      out0.add "Unmerged\n"
      continue
    if r.binary:
      out0.add align("Bin", numberWidth)
      if r.added + r.deleted > 0:
        out0.add " " & $r.deleted & " -> " & $r.added & " bytes"
      out0.add "\n"
      continue
    # `scale_linear`: a change that would not fit is scaled to the bar, and
    # one that has both kinds keeps at least one of each.
    var add = r.added
    var del = r.deleted
    if graphWidth < maxChange:
      proc scale(it: int): int =
        ## git's `scale_linear`: a zero stays zero, anything else takes at least
        ## one column.
        if it == 0: 0 else: 1 + (it * (graphWidth - 1) div maxChange)
      var total = max(scale(add + del), (if add > 0 and del > 0: 2 else: 0))
      if add < del: (add = scale(add); del = total - add)
      else: (del = scale(del); add = total - del)
    totalAdd += r.added
    totalDel += r.deleted
    out0.add align($(r.added + r.deleted), numberWidth) &
             (if r.added + r.deleted > 0: " " else: "")
    if o.color:
      if add > 0: out0.add colNew & repeat('+', add) & colReset
      if del > 0: out0.add colOld & repeat('-', del) & colReset
    else:
      out0.add repeat('+', add) & repeat('-', del)
    out0.add "\n"
  out0.add summaryLine(rows.len, totalAdd, totalDel)

func pathField(o: DiffOpts, path: string): string =
  ## How a path is written in a record: quoted and newline-terminated, or
  ## verbatim and NUL-terminated.  `-z` exists precisely so that no quoting is
  ## needed, so the two always travel together.
  if o.nulTerminate: path & "\0" else: quotePath(path) & "\n"

proc writeRaw(repo: Repository, p: DiffPair, o: DiffOpts, out0: var string) =
  ## `:<oldmode> <newmode> <oldsha> <newsha> <status><TAB><path>`
  ## (`diff-format.adoc`).  The object ID of a working-tree side is all zeroes
  ## -- see the module header.
  out0.add ":" & formatMode(p.oldMode) & " " & formatMode(p.newMode) & " " &
           repo.abbrevOf(o, p.oldOid, p.oldValid and p.oldMode != 0) & " " &
           repo.abbrevOf(o, p.newOid, p.newValid and p.newMode != 0) & " " &
           p.status
  out0.add (if o.nulTerminate: "\0" else: "\t")
  out0.add pathField(o, p.path)

proc writeNumstat(repo: Repository, p: DiffPair, o: DiffOpts, out0: var string) =
  ## `--numstat`: added, deleted, path -- `-` for binary, `0 0` for unmerged.
  if p.unmerged:
    out0.add "0\t0\t" & pathField(o, p.path)
    return
  let a = repo.oldText(p)
  let b = repo.newText(p)
  if not o.text and (isBinary(a) or isBinary(b)):
    out0.add "-\t-\t"
  else:
    let c = diffCounts(a, b, o.ws)
    out0.add $c.added & "\t" & $c.deleted & "\t"
  out0.add pathField(o, p.path)

proc writeNames(p: DiffPair, o: DiffOpts, withStatus: bool, out0: var string) =
  ## `--name-only` and `--name-status`: the path, with its letter first
  ## for the latter.
  if withStatus:
    out0.add p.status
    out0.add (if o.nulTerminate: "\0" else: "\t")
  out0.add pathField(o, p.path)

proc shortstat(repo: Repository, pairs: seq[DiffPair], o: DiffOpts): string =
  ## `--shortstat`: the summary line alone.
  var add = 0
  var del = 0
  var files = 0
  for p in pairs:
    if p.unmerged: continue   # counted in neither the files nor the lines
    inc files
    let a = repo.oldText(p)
    let b = repo.newText(p)
    if not o.text and (isBinary(a) or isBinary(b)): continue
    let c = diffCounts(a, b, o.ws)
    add += c.added
    del += c.deleted
  summaryLine(files, add, del)

proc renderDiff*(repo: Repository, pairs0: seq[DiffPair], o: DiffOpts):
    tuple[text: string, changed: bool] =
  ## Render every requested format, and say whether there were any differences
  ## -- which is what `--exit-code` reports and what `log` uses to decide
  ## whether a commit gets a `---` separator before its diff.
  ##
  ## The pairs are filtered for *actual* change first: a tree-to-tree join
  ## produces a pair for every path, and most of them are identical on both
  ## sides.
  var pairs: seq[DiffPair]
  for p in pairs0:
    if repo.changed(p): pairs.add p
  pairs = repo.applyFilters(pairs, o)
  result.changed = pairs.len > 0
  if o.quiet or pairs.len == 0: return

  var out0 = ""
  # Asking for several formats at once is not additive.  `diff_setup_done`
  # clears every other bit as soon as a *name* format is selected, so
  # `--raw --name-only` prints names and nothing else, while
  # `--stat --numstat` prints both.  git's own comment above `diff_flush`
  # states the rule: "raw, stat, summary, patch -- or name/name-status
  # (other bits clear)".
  if dfNameStatus in o.formats:
    for p in pairs: writeNames(p, o, true, out0)
    result.text = out0
    return
  if dfNameOnly in o.formats:
    for p in pairs: writeNames(p, o, false, out0)
    result.text = out0
    return

  if dfRaw in o.formats:
    for p in pairs: repo.writeRaw(p, o, out0)
  if dfNumstat in o.formats:
    for p in pairs: repo.writeNumstat(p, o, out0)
  if dfStat in o.formats:
    repo.writeStat(pairs, o, out0)
  if dfShortstat in o.formats:
    out0.add repo.shortstat(pairs, o)
  if dfPatch in o.formats:
    # A blank line goes between any statistics block and the patch under it
    # (`diff.c:diff_flush`, `DIFF_SYMBOL_STAT_SEP`).  It is the only place
    # where asking for two formats at once changes either of them.
    if out0.len > 0 and
       ({dfStat, dfShortstat, dfNumstat} * o.formats).card > 0:
      out0.add "\n"
    for p in splitTypeChange(pairs): repo.writePatch(p, o, out0)
  result.text = out0

proc summaryLines*(repo: Repository, pairs0: seq[DiffPair]): string =
  ## `--summary`: one line per *structural* change -- a file created, deleted,
  ## or whose mode changed.  Cut as an option (docs/03), but `commit` and
  ## `merge` both print these lines under their statistics, and they are what
  ## tells you a file was created rather than edited.
  for p in pairs0:
    if not repo.changed(p): continue
    if p.oldMode == 0:
      result.add " create mode " & formatMode(p.newMode) & " " &
                 quotePath(p.path) & "\n"
    elif p.newMode == 0:
      result.add " delete mode " & formatMode(p.oldMode) & " " &
                 quotePath(p.path) & "\n"
    elif p.oldMode != p.newMode:
      result.add " mode change " & formatMode(p.oldMode) & " => " &
                 formatMode(p.newMode) & " " & quotePath(p.path) & "\n"

proc commitSummary*(repo: Repository, pairs0: seq[DiffPair]): string =
  ## What `commit` prints under its `[master abc1234] subject` line: the
  ## one-line count and then the summary above it
  ## (`builtin/commit.c:print_summary` asks for `SHORTSTAT | SUMMARY`).
  var pairs: seq[DiffPair]
  for p in pairs0:
    if repo.changed(p): pairs.add p
  repo.shortstat(pairs, defaultDiffOpts()) & repo.summaryLines(pairs)

proc mergeSummary*(repo: Repository, pairs0: seq[DiffPair]): string =
  ## What `merge` prints instead: the histogram rather than the one-liner
  ## (`builtin/merge.c:finish` asks for `DIFFSTAT | SUMMARY`).
  var o = defaultDiffOpts()
  o.formats = {dfStat}
  repo.renderDiff(pairs0, o).text & repo.summaryLines(pairs0)
