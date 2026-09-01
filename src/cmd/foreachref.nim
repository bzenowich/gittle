## `for-each-ref` -- list refs through a format string.
##
## In scope (docs/05 `for-each-ref-options`): `<pattern>…`, `--count`,
## `--sort`, `--format`.
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
## ## The atoms v1 understands
##
##   %(refname)              the full name, e.g. refs/heads/main
##   %(refname:short)        the shortest unambiguous-looking form, `main`
##   %(refname:lstrip=<n>)   drop <n> leading components (negative: keep last n)
##   %(refname:rstrip=<n>)   drop <n> trailing components
##   %(objectname)           the object ID the ref names
##   %(objectname:short)     abbreviated to 7 digits
##   %(objectname:short=<n>) abbreviated to <n>
##   %(objecttype)           commit, tree, blob or tag
##   %(objectsize)           the object's size in bytes
##   %(HEAD)                 `*` if this is the checked-out branch, else a space
##   %(symref)               what a symbolic ref points at; empty otherwise
##   %(symref:short)
##   %(upstream)             the configured upstream ref, from branch.<n>.merge
##   %(upstream:short)
##   %(*objectname) etc.     the same field, but for what an annotated tag
##                           points at -- the `*` prefix is git's spelling
##
## Plus `%%` for a literal per cent and `%xx` for a byte written in hex, which
## is how a format string embeds a tab or a NUL.
##
## Everything else -- dates, commit subjects and bodies, `%(align:)`,
## `%(if:)`, `--points-at`, `--merged`, `--contains` -- is refused by name
## rather than silently ignored.  A format atom that expands to nothing when
## the caller expected a date is worse than an error.

import std/[strutils, algorithm]
import ../cli, ../glob, ../objects, ../oid, ../repository, ../util

const
  usageText = """usage: gittle for-each-ref [--count=<n>] [--sort=<key>] [--format=<format>] [<pattern>…]"""
  defaultFormat = "%(objectname) %(objecttype)\t%(refname)"
  defaultAbbrev = 7

  deferredAtoms = ["committerdate", "authordate", "taggerdate", "creatordate",
                   "subject", "contents", "body", "committername",
                   "committeremail", "authorname", "authoremail", "creator",
                   "align", "if", "then", "else", "end", "color", "push",
                   "worktreepath", "ahead-behind", "describe", "raw",
                   "objectsize:disk", "deltabase", "signature", "tree",
                   "parent", "numparent", "upstream:track", "upstream:remotename"]
    ## Real atoms of git's that v1 does not implement.  Naming them lets the
    ## error say "not implemented" rather than "unknown", which is the
    ## difference between a missing feature and a typo.

type
  Row = object
    ## One ref, with everything the format or the sort might ask for.  Object
    ## information is filled in lazily -- listing ten thousand tags should not
    ## read ten thousand objects unless the format actually needs their type.
    rf: Ref
    isHead: bool
    kind: ObjectType
    size: int
    infoLoaded: bool
    peeledOid: Oid
    peeledKind: ObjectType
    peeledSize: int
    peelLoaded: bool

# ---------------------------------------------------------------------------
# Field values
# ---------------------------------------------------------------------------

proc loadInfo(repo: Repository, r: var Row) =
  if r.infoLoaded: return
  r.infoLoaded = true
  if r.rf.oid.isNull: return
  let info = repo.objectInfo(r.rf.oid)
  r.kind = info.kind
  r.size = info.size

proc loadPeel(repo: Repository, r: var Row) =
  ## Follow an annotated tag to the object it names.
  ##
  ## `packed-refs` may already record this on a `^` line, which is exactly why
  ## that line exists: it saves reading the tag object at all.
  if r.peelLoaded: return
  r.peelLoaded = true
  repo.loadInfo(r)
  if r.rf.hasPeeled:
    r.peeledOid = r.rf.peeled
  elif r.kind == otTag:
    var current = r.rf.oid
    for _ in 0 .. 15:
      let obj = repo.readObject(current)
      if obj.kind != otTag: break
      var target = ""
      for line in obj.data.splitLines:
        if line.len == 0: break
        if line.startsWith("object "):
          target = line[7 .. ^1].strip()
          break
      if target.len == 0: return
      current = parseOid(target)
    r.peeledOid = current
  if r.peeledOid.isNull: return
  let info = repo.objectInfo(r.peeledOid)
  r.peeledKind = info.kind
  r.peeledSize = info.size

proc upstreamOf(repo: Repository, refname: string): string =
  ## `branch.<name>.merge` names the ref on the remote; combined with
  ## `branch.<name>.remote` it becomes the local remote-tracking ref, which is
  ## what `%(upstream)` prints.
  if not refname.startsWith("refs/heads/"): return ""
  let branch = refname["refs/heads/".len .. ^1]
  let merge = repo.cfg.get("branch." & branch & ".merge")
  let remote = repo.cfg.get("branch." & branch & ".remote")
  if merge.len == 0 or remote.len == 0: return ""
  if remote == ".": return merge   # an upstream in this same repository
  if not merge.startsWith("refs/heads/"): return ""
  "refs/remotes/" & remote & "/" & merge["refs/heads/".len .. ^1]

proc fieldValue(repo: Repository, r: var Row, atom: string): string =
  ## Expand one `%(…)` atom.  `atom` is what was between the parentheses.
  var name = atom
  var deref = false
  if name.startsWith("*"):
    deref = true
    name = name[1 .. ^1]

  var modifier = ""
  let colon = name.find(':')
  if colon >= 0:
    modifier = name[colon + 1 .. ^1]
    name = name[0 ..< colon]

  for d in deferredAtoms:
    if name == d or atom == d:
      fail("%(" & atom & ") is not implemented in this version\n" &
           "  date, message and conditional atoms need the revision walk " &
           "(phase 6)")

  if deref:
    repo.loadPeel(r)
    if r.peeledOid.isNull: return ""

  case name
  of "refname":
    let full = r.rf.name
    if modifier.len == 0: return full
    if modifier == "short": return shortenRefname(full)
    if modifier.startsWith("lstrip="):
      return lstripRefname(full, parseInt(modifier["lstrip=".len .. ^1]))
    if modifier.startsWith("rstrip="):
      return rstripRefname(full, parseInt(modifier["rstrip=".len .. ^1]))
    fail("unknown modifier in %(" & atom & ")")
  of "objectname":
    let o = if deref: r.peeledOid else: r.rf.oid
    if modifier.len == 0: return $o
    if modifier == "short": return abbrev(o, defaultAbbrev)
    if modifier.startsWith("short="):
      return abbrev(o, parseInt(modifier["short=".len .. ^1]))
    fail("unknown modifier in %(" & atom & ")")
  of "objecttype":
    repo.loadInfo(r)
    return $(if deref: r.peeledKind else: r.kind)
  of "objectsize":
    repo.loadInfo(r)
    return $(if deref: r.peeledSize else: r.size)
  of "HEAD":
    return if r.isHead: "*" else: " "
  of "symref":
    if r.rf.symTarget.len == 0: return ""
    if modifier == "short": return shortenRefname(r.rf.symTarget)
    return r.rf.symTarget
  of "upstream":
    let u = upstreamOf(repo, r.rf.name)
    if u.len == 0: return ""
    if modifier == "short": return shortenRefname(u)
    return u
  else:
    fail("unknown field name: %(" & atom & ")")

proc expand(repo: Repository, r: var Row, format: string): string =
  ## Interpolate a whole format string.
  var i = 0
  while i < format.len:
    if format[i] != '%':
      result.add format[i]
      inc i
      continue
    failIf(i + 1 >= format.len, "unterminated % in format string")
    if format[i+1] == '%':
      result.add '%'
      i += 2
    elif format[i+1] == '(':
      let close = format.find(')', i + 2)
      failIf(close < 0, "unterminated %( in format string")
      result.add repo.fieldValue(r, format[i+2 ..< close])
      i = close + 1
    else:
      # `%0a` and friends: a byte written as two hex digits, which is how a
      # format string carries a tab or a NUL through a shell.
      failIf(i + 2 >= format.len, "unterminated % in format string")
      let hex = format[i+1 .. i+2]
      var v = 0
      for c in hex:
        let d = case c
                of '0'..'9': ord(c) - ord('0')
                of 'a'..'f': ord(c) - ord('a') + 10
                of 'A'..'F': ord(c) - ord('A') + 10
                else: -1
        failIf(d < 0, "bad %-escape '%" & hex & "' in format string")
        v = v * 16 + d
      result.add char(v)
      i += 3

# ---------------------------------------------------------------------------
# Filtering and sorting
# ---------------------------------------------------------------------------

proc matchesPattern(refname: string, patterns: seq[string]): bool =
  ## git's `ref-filter.c:match_name_as_path`: a pattern matches if it is a
  ## prefix of the name ending at a `/` boundary, or if it globs.  The prefix
  ## rule is why `for-each-ref refs/heads` lists every branch without a `*`.
  if patterns.len == 0: return true
  for p in patterns:
    if p.len <= refname.len and refname.startsWith(p) and
       (p.len == refname.len or refname[p.len] == '/' or p[^1] == '/'):
      return true
    if globMatch(p, refname, {gfPathname}):
      return true
  false

proc sortRows(repo: Repository, rows: var seq[Row], keys: seq[string]) =
  ## Apply `--sort` keys.
  ##
  ## The *last* key given is the primary one (`git for-each-ref` documents this,
  ## and it is easy to verify with a tag and a branch whose name order and type
  ## order disagree).  With a stable sort that falls out for free: sort by each
  ## key in turn, and the last sort applied is the one that wins, with every
  ## earlier one surviving as a tiebreak.
  for k in 0 .. keys.high:
    var key = keys[k]
    let descending = key.startsWith("-")
    if descending: key = key[1 .. ^1]
    let numeric = key == "objectsize"
    sort(rows, proc (a, b: Row): int =
      var ra = a
      var rb = b
      let va = repo.fieldValue(ra, key)
      let vb = repo.fieldValue(rb, key)
      result = if numeric:
                 cmp(parseInt(if va.len == 0: "0" else: va),
                     parseInt(if vb.len == 0: "0" else: vb))
               else: cmp(va, vb)
      if descending: result = -result)

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

proc cmdForEachRef*(c: Ctx, args: seq[string]): int =
  var format = defaultFormat
  var count = 0
  var sortKeys: seq[string]
  var patterns: seq[string]
  var i = 0
  var noMoreOpts = false
  while i < args.len:
    let a = args[i]
    if noMoreOpts or a.len == 0 or a[0] != '-':
      patterns.add a
    elif a == "--":
      noMoreOpts = true
    elif a.startsWith("--format="):
      format = a["--format=".len .. ^1]
    elif a == "--format":
      inc i
      failIf(i >= args.len, "option '--format' requires a value")
      format = args[i]
    elif a.startsWith("--count="):
      count = parseInt(a["--count=".len .. ^1])
    elif a == "--count":
      inc i
      failIf(i >= args.len, "option '--count' requires a value")
      count = parseInt(args[i])
    elif a.startsWith("--sort="):
      sortKeys.add a["--sort=".len .. ^1]
    elif a == "--sort":
      inc i
      failIf(i >= args.len, "option '--sort' requires a value")
      sortKeys.add args[i]
    elif a == "-h" or a == "--help":
      echo usageText
      return 0
    elif a in ["--merged", "--no-merged", "--contains", "--no-contains"] or
         a.startsWith("--merged=") or a.startsWith("--no-merged=") or
         a.startsWith("--contains=") or a.startsWith("--no-contains="):
      fail(a.split('=')[0] & " needs reachability, which arrives with the " &
           "revision walk in phase 6")
    else:
      fail("unknown option '" & a & "'\n" & usageText)
    inc i

  let repo = c.repo
  let headBranch = repo.headRefName

  var rows: seq[Row]
  for rf in repo.refs.allRefs():
    if not matchesPattern(rf.name, patterns): continue
    rows.add Row(rf: rf, isHead: rf.name == headBranch)

  if sortKeys.len == 0: sortKeys = @["refname"]
  sortRows(repo, rows, sortKeys)

  var n = 0
  for i in 0 ..< rows.len:
    if count > 0 and n >= count: break
    stdout.write repo.expand(rows[i], format), "\n"
    inc n
  stdout.flushFile()
  0
