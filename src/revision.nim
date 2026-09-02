## The revision grammar: turning `HEAD~3`, `v1.0^{}`, `A..B` and `:0:file`
## into object IDs.
##
## `gitrevisions(7)` is one of git's larger grammars and eight commands take
## it.  It is written here once, as three layers, because that is the shape
## git's own `object-name.c` has and the layering is load-bearing rather than
## decorative:
##
## 1. **A name.** A full or abbreviated object ID, a ref through the DWIM
##    rules, `@` for HEAD, or `<ref>@{<n>}` reading the reflog.  This is
##    `resolveOid` in `repository.nim`, extended here with `@{…}`.
## 2. **A `<rev>`.** A name with suffix operators applied right to left:
##    `^<n>` (the n-th parent), `~<n>` (n generations back along first
##    parents), `^{<type>}` (dereference until that type), `^{}` (dereference
##    a tag), and `<tree-ish>:<path>` / `:<n>:<path>` naming a blob or subtree.
## 3. **A revision *argument*.** A `<rev>`, or one of the range spellings that
##    stand for several: `^A` excludes, `A..B` is `^A B`, `A...B` is both tips
##    minus their merge base, `A^@` is A's parents, `A^!` is A without them.
##
## Layer 3 is where a command's *starting points* come from, and it is why
## `rev-list` and `log` never see a range at all: by the time the walk starts,
## every argument has become a list of commits, each marked interesting or
## not.
##
## ## Where the operators bind
##
## git scans a `<rev>` from the **right**, taking the last `^`/`~` followed by
## digits as the operator and everything before it as the thing to apply it to
## (`object-name.c:get_oid_1`).  So `a^b~2` applies `~2` to `a^b`, and a ref
## whose own name contains `^` is still reachable as long as the tail does not
## look like an operator.  Recursion, not a loop, because the left-hand side is
## itself a `<rev>`.
##
## ## What is deliberately not here
##
## Four corners of `gitrevisions(7)` are refused by name rather than
## implemented, each because it is an engine standing behind a single spelling
## -- R6 -- and none of them appears once in the 509 real invocations
## `docs/git-tool-calls-*.md` records:
##
## * `:/<text>` and `^{/<text>}` search every commit message for a pattern.
##   That is a second walk with a second matcher hanging off a two-character
##   prefix.
## * `<ref>@{<date>}` ("`main@{2 weeks ago}`") needs git's approxidate, a
##   parser of English (`date.c:approxidate_careful`).  `--since` and
##   `--until` survive it by taking an ISO-8601 date only; see
##   `parseTimestamp`.
## * `@{-<n>}` ("the branch I was on <n> checkouts ago", and so `checkout -`)
##   is a backwards scan of HEAD's reflog counting `checkout: moving from`
##   messages.  `headDescription` below scans the same log for a different
##   question and is kept, because `status` prints its answer on every run.
## * `@{push}` needs a push refspec, which v1 does not model.
##
## `@{upstream}` needs only `branch.<name>.merge`, which `branch -u` writes
## here, so that one is in -- and it is the one `@{…}` form the logs do use.
## `<ref>@{<n>}` is in too, for a narrower reason: `stash@{2}` is the only way
## to name an entry of the stash stack, and `cmd/stash.nim` resolves it
## through this grammar.

import std/[algorithm, os, sequtils, strutils]
import cli
import ident, index, objects, oid, pathspec, refs, repository, revwalk, util

# ---------------------------------------------------------------------------
# Refusing a syntax, as opposed to failing to resolve one
# ---------------------------------------------------------------------------

type RevRefused* = object of GittleError
  ## "gittle does not implement this spelling", as distinct from "this name
  ## does not resolve".
  ##
  ## The distinction is not decoration; it is what keeps a refusal audible.
  ## `looksLikeRev` below is how every command with both revisions and paths
  ## decides which it was given, and it decides by resolving the argument and
  ## swallowing the failure -- `log Makefile` has to work.  A refusal swallowed
  ## there becomes silence with a wrong explanation: `checkout :/text` would go
  ## on to say `pathspec ':/text' did not match any file(s)`, which names a
  ## mistake the user did not make and hides the one they did.  So a refusal is
  ## re-raised through those two procs and only "does not resolve" means
  ## "then it is a path".

proc refuse(msg: string) {.noreturn.} =
  ## Refuse a revision spelling by name.  Every out-of-scope corner of the
  ## grammar goes through here rather than through `fail`, so that none of
  ## them can be mistaken for a path.
  raise newException(RevRefused, msg)

# ---------------------------------------------------------------------------
# The reflog, read back
# ---------------------------------------------------------------------------

type ReflogEntry* = object
  ## One line of `.git/logs/<ref>`:
  ##
  ##     <old-oid> SP <new-oid> SP <who> TAB <message> LF
  ##
  ## The identity is `Name <email> <seconds> <tz>`, and the message is
  ## optional -- an entry written by a tool that passed none has no tab.
  ## Entries are appended, so the file is oldest first and `@{0}` is the last
  ## line.
  oldOid*, newOid*: Oid
  who*: string      ## the identity, verbatim, with its timestamp
  message*: string

proc readReflog*(s: RefStore, name: string): seq[ReflogEntry] =
  ## Every entry for a ref, oldest first; an empty sequence when it has no log.
  ## Malformed lines are skipped rather than fatal: a reflog is a convenience
  ## file that any tool may have appended to, and one bad line must not make a
  ## ref unreadable.
  let path = s.reflogPath(name)
  if not fileExists(path): return
  for line in readWholeFile(path).splitLines():
    if line.len < 2 * OidHexLen + 2: continue
    var e: ReflogEntry
    if not tryParseOid(line[0 ..< OidHexLen], e.oldOid): continue
    if not tryParseOid(line[OidHexLen + 1 ..< 2 * OidHexLen + 1], e.newOid): continue
    let rest = line[2 * OidHexLen + 2 .. ^1]
    let tab = rest.find('\t')
    if tab < 0: e.who = rest
    else:
      e.who = rest[0 ..< tab]
      e.message = rest[tab + 1 .. ^1]
    result.add e

proc headDescription*(repo: Repository): string =
  ## What `status` and `branch` call a HEAD that is not on a branch.
  ##
  ## Not simply the object ID: git looks in HEAD's reflog for the switch that
  ## detached it, and if that name still resolves to the same commit it uses
  ## the *name* -- so `checkout v1.0` says `HEAD detached at v1.0`, which is
  ## what the user typed and can type again
  ## (`wt-status.c:wt_status_get_detached_from`).  `at` becomes `from` once
  ## HEAD has moved on from where it was detached.
  const marker = "checkout: moving from "
  let head = repo.refs.resolveRef(headRef)
  var name = repo.uniqueAbbrev(head.oid, repo.autoAbbrev)
  var detachedAt = head.oid

  let log = repo.refs.readReflog(headRef)
  for i in countdown(log.high, 0):
    let m = log[i].message
    if not m.startsWith(marker): continue
    let sep = m.find(" to ", marker.len)
    if sep < 0: break
    let target = m[sep + 4 .. ^1]
    detachedAt = log[i].newOid
    let d = repo.refs.dwimRef(target)
    var sameCommit = d.found and d.oid == detachedAt
    if d.found and not sameCommit:
      # A tag names a commit through a tag object, so the reflog's target and
      # the ref's own object ID need not be equal for them to mean the same.
      try: sameCommit = repo.peelTo(d.oid, otCommit).oid == detachedAt
      except GittleError: discard
    if sameCommit:
      # A tag or remote-tracking branch is named without its namespace, the
      # way it would be typed back.
      name = d.full
      for p in ["refs/tags/", "refs/remotes/"]:
        if name.startsWith(p): name = name[p.len .. ^1]
    else:
      name = repo.uniqueAbbrev(detachedAt, repo.autoAbbrev)
    break

  (if head.oid == detachedAt: "HEAD detached at " else: "HEAD detached from ") &
    name

# ---------------------------------------------------------------------------
# Layer 1: a name
# ---------------------------------------------------------------------------

proc resolveName(repo: Repository, name: string): tuple[ok: bool, oid: Oid] =
  ## A name with no suffix operators, plus the `@{…}` forms, which bind to the
  ## whole name rather than to a `<rev>` and so belong here.
  if name == "@":
    let h = repo.refs.resolveRef(headRef)
    return (h.found, h.oid)

  let at = name.rfind("@{")
  if at >= 0 and name.endsWith("}"):
    let head = name[0 ..< at]
    let arg = name[at + 2 .. ^2]

    # `@{-<n>}` is refused rather than resolved.  It is the one `@{…}` form
    # that names a *branch* and not an object ID, and the only record of the
    # answer is a backwards scan of HEAD's reflog counting `checkout: moving
    # from` messages (`refs.c:repo_dwim_log`).  Silence here would be the bad
    # kind: `@{-1}` would fall through and be read as a path.
    if head.len == 0 and arg.len > 0 and arg[0] == '-':
      refuse("'@{" & arg & "}' is out of scope for gittle: the branch you " &
             "were on before is only in HEAD's reflog; name it, or read " &
             "`gittle reflog`")

    let refName = if head.len == 0: repo.headRefName
                  else:
                    let d = repo.refs.dwimRef(head)
                    failIf(not d.found, "unknown revision: " & head)
                    d.full

    if arg == "u" or arg == "upstream":
      let up = repo.upstreamRef(refName)
      failIf(up.len == 0, "no upstream configured for branch '" &
             repo.refs.shortenRef(refName) & "'")
      let r = repo.refs.resolveRef(up)
      failIf(not r.found, "upstream branch '" & up & "' does not exist")
      return (true, r.oid)
    if arg == "push":
      refuse("@{push} is out of scope for gittle v1 (docs/09): no push refspecs")

    # Everything else that could stand here is `@{<date>}`, which is git's
    # approxidate and out of scope; refuse it by name so that a mistyped date
    # cannot be read as an entry number and answer a different question.
    if arg.len == 0 or not arg.allCharsInSet({'0' .. '9'}):
      refuse("'@{" & arg & "}' is not a reflog entry number, and gittle has " &
             "no @{<date>}: give a number, or a date to --since/--until")
    let n = parseInt(arg)
    let log = repo.refs.readReflog(refName)
    let shown = if head.len > 0: head else: repo.refs.shortenRef(refName)
    failIf(log.len == 0, "log for '" & shown & "' is empty")
    failIf(n >= log.len,
           "log for '" & shown & "' only has " & $log.len & " entries")
    # Oldest first in the file, newest first in the syntax: `@{0}` is the
    # value the ref has now, which is the last entry's *new* side.
    return (true, log[log.high - n].newOid)

  if tryParseOid(name, result.oid): return (true, result.oid)
  let d = repo.refs.dwimRef(name)
  if d.found: return (true, d.oid)

  var pre: OidPrefix
  if not tryParsePrefix(name, pre) or pre.nybbles < minAbbrev: return (false, nullOid)
  var found = repo.objectsMatching(pre)
  if found.len == 0: return (false, nullOid)
  if found.len > 1:
    var msg = "short object ID " & name & " is ambiguous; candidates are:"
    sort(found, cmp)
    for o in found: msg.add "\n  " & $o
    fail(msg)
  (true, found[0])

# ---------------------------------------------------------------------------
# Layer 2: a <rev>
# ---------------------------------------------------------------------------

proc tryResolveRev(repo: Repository, spec: string): tuple[ok: bool, oid: Oid]

proc nthParent(repo: Repository, spec: string, n: int): tuple[ok: bool, oid: Oid] =
  ## `<rev>^<n>`.  `^0` is not a parent at all: it is "this, as a commit",
  ## which is how a tag is turned into the commit it names.
  let base = repo.tryResolveRev(spec)
  if not base.ok: return base
  let commit = repo.peelTo(base.oid, otCommit).oid
  if n == 0: return (true, commit)
  let parents = repo.readCommit(commit).parents
  # Asking for a parent that is not there is not fatal: git returns "this
  # name does not resolve", and the caller then reports it as an ambiguous
  # argument, which is what the user sees (`object-name.c:get_parent`).
  if n > parents.len: return (false, nullOid)
  (true, parents[n - 1])

proc nthAncestor(repo: Repository, spec: string, n: int): tuple[ok: bool, oid: Oid] =
  ## `<rev>~<n>`: n steps back, always along the first parent.
  var cur = repo.tryResolveRev(spec)
  if not cur.ok: return cur
  var o = repo.peelTo(cur.oid, otCommit).oid
  for k in 0 ..< n:
    let parents = repo.readCommit(o).parents
    if parents.len == 0: return (false, nullOid)
    o = parents[0]
  (true, o)

const onionTypes = [("commit}", otCommit), ("tree}", otTree),
                    ("blob}", otBlob), ("tag}", otTag)]
  ## `^{<type>}`, as a table: every case differs only in the type wanted.
  ## `^{}` and `^{object}` are the two that are not a type at all -- see below.

proc peelOnion(repo: Repository, spec: string): tuple[ok: bool, oid: Oid] =
  ## `<rev>^{}`, `<rev>^{<type>}` (`object-name.c:peel_onion`).
  ##
  ## `^{}` dereferences tags until something that is not a tag comes out --
  ## it is how `v1.0^{}` names the *commit* a tag object points at, which is
  ## what `packed-refs` records on its `^` lines.  `^{<type>}` dereferences
  ## until that type appears, and `^{object}` only asserts that the name
  ## resolves at all.
  if spec.len < 4 or spec[^1] != '}': return (false, nullOid)
  let open = spec.rfind("^{")
  if open <= 0: return (false, nullOid)
  let inner = spec[open + 2 .. ^2]
  let base = repo.tryResolveRev(spec[0 ..< open])
  if not base.ok: return base

  if inner.len > 0 and inner[0] == '/':
    refuse("^{/<text>} is out of scope for gittle v1 (docs/09): no commit search")
  if inner.len == 0:
    # Dereference tags, and only tags.
    return (true, repo.peelTags(base.oid))
  if inner == "object": return base
  for (suffix, want) in onionTypes:
    if inner & "}" == suffix: return (true, repo.peelTo(base.oid, want).oid)
  (false, nullOid)

proc lookupInTree(repo: Repository, root: Oid,
                  path: string): tuple[ok: bool, oid: Oid] =
  ## `<tree-ish>:<path>`: walk the path components down from a tree.
  ## A path that is not there is *not fatal* here -- it makes the whole
  ## expression fail to resolve, and the command then reports it as an
  ## ambiguous argument, which is git's flow (the specific "does not exist in
  ## 'HEAD'" hint is only produced on the second, diagnostic, pass).
  var cur = repo.peelTo(root, otTree).oid
  if path.len == 0: return (true, cur)
  let parts = path.split('/')
  for k, part in parts:
    var hit = false
    for e in treeEntries(repo.readObject(cur).data):
      if e.name != part: continue
      if k < parts.high and modeType(e.mode) != otTree: return (false, nullOid)
      cur = e.oid
      hit = true
      break
    if not hit: return (false, nullOid)
  (true, cur)

proc fromIndex(repo: Repository, stage: int,
               path: string): tuple[ok: bool, oid: Oid] =
  ## `:<n>:<path>`, and `:<path>` for stage 0.  Reading the index rather than
  ## the working tree is the point of the syntax: `:file` is what `add` staged.
  let idx = readIndex(repo.indexPath)
  let k = idx.find(path, stage)
  if k < 0: return (false, nullOid)
  (true, idx.entries[k].oid)

proc splitColon(spec: string): int =
  ## The `:` that separates a tree-ish from a path, or -1.  A `:` inside
  ## `^{…}` is not one -- `HEAD^{commit}:x` has its separator after the brace
  ## (`object-name.c:get_oid_with_context_1`).
  var depth = 0
  for i, ch in spec:
    if ch == '{': inc depth
    elif ch == '}' and depth > 0: dec depth
    elif ch == ':' and depth == 0: return i
  -1

proc tryResolveRev(repo: Repository, spec: string): tuple[ok: bool, oid: Oid] =
  ## A whole `<rev>`.  The order is git's, and each step is tried on the
  ## *entire* string before the string is taken apart, so that a ref whose
  ## name contains an operator character still wins.
  if spec.len == 0: return (false, nullOid)

  # A trailing run of digits preceded by `^` or `~` is an operator.  Scanning
  # from the right is what makes the operators left-associative.
  var i = spec.len - 1
  while i >= 0 and spec[i] in {'0' .. '9'}: dec i
  if i >= 0 and i < spec.len - 1 and spec[i] in {'^', '~'} and i > 0:
    let n = parseInt(spec[i + 1 .. ^1])
    return (if spec[i] == '^': repo.nthParent(spec[0 ..< i], n)
            else: repo.nthAncestor(spec[0 ..< i], n))
  # The bare forms: `HEAD^` is `HEAD^1`, `HEAD~` is `HEAD~1`.
  if spec.len > 1 and spec[^1] == '^': return repo.nthParent(spec[0 ..< ^1], 1)
  if spec.len > 1 and spec[^1] == '~': return repo.nthAncestor(spec[0 ..< ^1], 1)

  if spec[^1] == '}':
    let peeled = repo.peelOnion(spec)
    if peeled.ok: return peeled

  if spec[0] == ':':
    if spec.len > 2 and spec[1] == '/':
      refuse(":/<text> is out of scope for gittle v1 (docs/09): no commit search")
    var stage = 0
    var path = spec[1 .. ^1]
    if spec.len > 2 and spec[1] in {'0' .. '3'} and spec[2] == ':':
      stage = ord(spec[1]) - ord('0')
      path = spec[3 .. ^1]
    # `:path` is relative to the root of the working tree; only `:./path`
    # means "relative to where I am standing".
    if path.startsWith("./") or path.startsWith("../"):
      path = normalizedPath(repo.prefix & path)
    return repo.fromIndex(stage, path)

  let colon = spec.splitColon()
  if colon > 0:
    let base = repo.tryResolveRev(spec[0 ..< colon])
    if not base.ok: return base
    var path = spec[colon + 1 .. ^1]
    # `./` and `../` are relative to where the command was run; everything
    # else is relative to the root of the working tree.
    if path.startsWith("./") or path.startsWith("../"):
      path = normalizedPath(repo.prefix & path)
    return repo.lookupInTree(base.oid, path)

  repo.resolveName(spec)

proc resolveRevish*(repo: Repository, spec: string): Oid =
  ## A `<rev>`, or a fatal error naming it.  This is `resolveOid`'s
  ## replacement everywhere a command takes a revision from the user.
  let r = repo.tryResolveRev(spec)
  failIf(not r.ok, "not a valid object name: " & spec)
  r.oid

proc resolveCommittish*(repo: Repository, spec: string): Oid =
  ## A `<commit-ish>`: a `<rev>` peeled to the commit it names.
  repo.peelTo(repo.resolveRevish(spec), otCommit).oid

proc resolveTree*(repo: Repository, spec: string): Oid =
  ## A `<tree-ish>` argument: a `<rev>`, peeled to the tree it names.  What
  ## `ls-tree`, `read-tree` and `diff` take.
  repo.peelTo(repo.resolveRevish(spec), otTree).oid

proc looksLikeRev*(repo: Repository, spec: string): bool =
  ## Does this argument name something?  The question every command with both
  ## revisions and paths has to ask, and it must not be fatal -- `log Makefile`
  ## is a path, not an error.
  try: return repo.tryResolveRev(spec).ok
  except RevRefused: raise
  except GittleError: return false

proc looksLikeCommittish(repo: Repository, spec: string): bool =
  ## As above, but for the two parent spellings, which need an actual commit:
  ## `A^!` on a tree is not the shorthand at all and falls through to being
  ## read as a name (`builtin/rev-parse.c:try_parent_shorthands`).  The
  ## *range* forms deliberately do not ask this -- git resolves their sides
  ## without dereferencing, so `v1..main` excludes the tag object itself.
  try:
    let r = repo.tryResolveRev(spec)
    return r.ok and repo.peelTo(r.oid, otCommit).oid != nullOid
  except RevRefused: raise
  except GittleError: return false

# ---------------------------------------------------------------------------
# Layer 3: a revision argument
# ---------------------------------------------------------------------------

type
  RevPoint* = object
    ## One starting (or stopping) point of a walk.
    oid*: Oid
    uninteresting*: bool  ## `^A`: everything reachable from here is excluded
    left*: bool           ## the left side of an `A...B`, for `--left-right`.
                          ## There is no matching `right`: git has one flag,
                          ## `SYMMETRIC_LEFT`, and everything else is `>`.
    name*: string         ## the spelling that produced it, which only
                          ## `rev-parse --symbolic-full-name` needs -- it
                          ## prints the *ref*, so it has to know what was
                          ## typed and not merely what it resolved to.

  RevPseudo* = enum
    ## The pseudo-refs that stand for a whole namespace.  A table because they
    ## differ only in their prefix and in whether HEAD joins them.
    rpAll, rpBranches, rpTags, rpRemotes

const pseudoPrefix*: array[RevPseudo, string] =
  ["refs/", "refs/heads/", "refs/tags/", "refs/remotes/"]

proc addPseudo*(repo: Repository, which: RevPseudo, pattern: string,
                notMode: bool, dest: var seq[RevPoint]) =
  ## `--all`, `--branches[=<glob>]`, `--tags`, `--remotes`.  Only refs that
  ## peel to a commit take part: `--all` on a repository with a tag of a blob
  ## must not fail (`revision.c:handle_one_ref`).
  for r in repo.refs.allRefs(pseudoPrefix[which]):
    let short = r.name[pseudoPrefix[which].len .. ^1]
    if pattern.len > 0 and not short.contains(pattern) and
       not short.startsWith(pattern): continue
    let (found, _, oid) = repo.refs.resolveRef(r.name)
    if not found: continue
    # A ref that does not lead to a commit -- a tag of a blob -- is silently
    # skipped rather than fatal, because `--all` must work on any repository
    # (`revision.c:handle_one_ref`).
    try: discard repo.peelTo(oid, otCommit)
    except GittleError: continue
    dest.add RevPoint(oid: oid, uninteresting: notMode, name: r.name)
  if which == rpAll:
    let h = repo.refs.resolveRef(headRef)
    if h.found: dest.add RevPoint(oid: h.oid, uninteresting: notMode)

proc failAmbiguous*(repo: Repository, arg: string) =
  ## An argument that is neither a revision nor a path that exists: refuse it,
  ## as git does, rather than guess -- because guessing means treating a
  ## mistyped revision as a pathspec and printing a confident empty answer.
  ##
  ## One sentence, not a diagnosis.  git re-reads the argument after it has
  ## failed and works out *which* near miss it was -- `:1:x` when `x` is
  ## staged only at 0, `HEAD:x` when `x` is not in that tree -- in 46 lines
  ## across `object-name.c:diagnose_invalid_index_path` and its sibling.  Each
  ## of those sentences restates the argument the user just typed, and
  ## docs/minimize.md §3 tier 3 settled that gittle's prose is compared for
  ## content and not for bytes; what has to survive is the exit status and the
  ## `--` rule, which is the part that tells the user what to do next.
  if fileExists(repo.workTreePath(repo.prefix & arg)) or
     dirExists(repo.workTreePath(repo.prefix & arg)): return
  fail("ambiguous argument '" & arg & "': unknown revision or path not in " &
       "the working tree.\nUse '--' to separate paths from revisions, like " &
       "this:\n'gittle <command> [<revision>...] -- [<file>...]'")

proc addRevArg*(repo: Repository, arg: string, notMode: bool,
                dest: var seq[RevPoint]): bool =
  ## One non-option argument, as `revision.c:handle_revision_arg` reads it.
  ## Returns false if it names nothing, which is the caller's signal to treat
  ## it as a path.
  ##
  ## `notMode` is `--not`, which flips the sense of everything after it; a
  ## literal `^` prefix flips it again for that one argument.
  var arg = arg

  # A..B and A...B.  Either side may be empty, in which case it is HEAD.
  let dots = arg.find("..")
  if dots >= 0 and arg != "..":
    let symmetric = dots + 2 < arg.len and arg[dots + 2] == '.'
    let lhs = if dots == 0: "HEAD" else: arg[0 ..< dots]
    let rhsAt = dots + (if symmetric: 3 else: 2)
    let rhs = if rhsAt >= arg.len: "HEAD" else: arg[rhsAt .. ^1]
    if repo.looksLikeRev(lhs) and repo.looksLikeRev(rhs):
      # Unpeeled, so that `v1..main` prints the tag's own ID on the `^` side.
      # The merge bases below need commits, and peel for themselves.
      let a = repo.resolveRevish(lhs)
      let b = repo.resolveRevish(rhs)
      # The right-hand side comes first, then the left: that is the order
      # `rev-parse` prints them in (`builtin/rev-parse.c:try_difference`) and
      # the walk does not care.
      dest.add RevPoint(oid: b, uninteresting: notMode, name: rhs)
      if symmetric:
        # Both tips are wanted; what they share is not.  The merge bases are
        # the exclusions, which is what makes `A...B` "everything on either
        # side since they diverged".
        dest.add RevPoint(oid: a, uninteresting: notMode, left: true, name: lhs)
        for m in repo.mergeBases(repo.peelTo(a, otCommit).oid,
                                 [repo.peelTo(b, otCommit).oid]):
          dest.add RevPoint(oid: m, uninteresting: not notMode)
      else:
        dest.add RevPoint(oid: a, uninteresting: not notMode, name: lhs)
      return true

  # `A^@` is A's parents; `A^!` is A without them; `A^-<n>` is A without its
  # n-th parent.  All three are "add some parents, excluded", and the last two
  # then add A itself, which is the fall-through below.
  # `A^@` is A's parents; `A^!` is A without them; `A^-<n>` is A without its
  # n-th parent.  One shape, three rows: which parents, and whether A itself
  # and its parents are wanted or excluded
  # (`builtin/rev-parse.c:try_parent_shorthands`).
  var mark = arg.find("^!")
  var includeRev = mark >= 0
  var includeParents = false
  var only = 0                ## 0 = every parent, n = only the n-th
  if mark < 0:
    mark = arg.find("^@")
    includeParents = mark >= 0
  if mark >= 0 and mark != arg.len - 2:
    mark = -1                 # `A^!x` is not the shorthand at all
  if mark < 0:
    mark = arg.find("^-")
    if mark >= 0:
      let tail = arg[mark + 2 .. ^1]
      if tail.len > 0 and not tail.allCharsInSet({'0' .. '9'}): mark = -1
      else:
        only = if tail.len == 0: 1 else: parseInt(tail)
        includeRev = true
        if only == 0: mark = -1
  if mark > 0 and repo.looksLikeCommittish(arg[0 ..< mark]):
    let base = arg[0 ..< mark]
    let o = repo.resolveCommittish(base)
    let parents = repo.readCommit(o).parents
    # Too high a parent number is not an error: git falls back to reading the
    # whole argument as a name, which then fails to resolve and says so.
    if only <= parents.len:
      if includeRev: dest.add RevPoint(oid: o, uninteresting: notMode, name: base)
      for k, p in parents:
        if only > 0 and k + 1 != only: continue
        dest.add RevPoint(oid: p, uninteresting: includeParents == notMode,
                          name: base & "^" & $(k + 1))
      return true

  var uninteresting = notMode
  if arg.len > 1 and arg[0] == '^':
    uninteresting = not notMode
    arg = arg[1 .. ^1]

  # Not peeled: `rev-parse v1` prints the *tag* object, and `rev-list
  # --objects` has to list it.  Peeling to a commit is the walk's job, not
  # the grammar's.
  let r = repo.tryResolveRev(arg)
  if not r.ok: return false
  dest.add RevPoint(oid: r.oid, uninteresting: uninteresting, name: arg)
  true

# ---------------------------------------------------------------------------
# The shared option surface (docs/04)
# ---------------------------------------------------------------------------
#
# `rev-list` has no options of its own: it *is* this list, and `log` takes the
# same one with formatting bolted on.  Writing it twice would guarantee they
# drift, so it is written once, here, as a single left-to-right pass -- which
# it has to be anyway, because `--not` changes the meaning of every argument
# after it and nothing else in git's option grammar does that.

type RevInput* = object
  ## What one pass over the arguments collects, beyond what it has already
  ## set on the walk itself.
  notMode: bool          ## `--not` is in effect
  pathsStarted: bool     ## the first non-revision has been seen
  points*: seq[RevPoint]
  specs*: seq[string]
  seenDashDash*: bool
  maxCount*, skip*: int
  reverse*, leftRight*, count*, objects*: bool

proc initRevInput*(): RevInput = RevInput(maxCount: -1)

proc parseTimestamp*(s: string): int64 =
  ## `--since` / `--until`: the boundary of a walk, as seconds since the epoch.
  ##
  ## **One date parser, not two.**  `ident.parseDate` already reads the two
  ## spellings v1 accepts anywhere -- git's own `<epoch> <+hhmm>`, and ISO
  ## 8601 with an optional time and zone -- because `GIT_AUTHOR_DATE` is
  ## written in them.  There used to be a second list of formats here, and the
  ## two lists had drifted: `2026-09-01T00:00:00Z` was a date you could commit
  ## with and not a date you could bound a walk by, while `2026/09/01` was the
  ## reverse (docs/minimize.md §7.1).  A date is a date; the difference was an
  ## accident of which file it was typed into.
  ##
  ## Not approxidate.  `--since=2.weeks.ago` is git's `date.c` reading English
  ## -- over a thousand lines behind one option, which is R6's case exactly
  ## (plan.md §3).  Refusing it by name beats accepting it and quietly meaning
  ## something else: a walk bounded by a date nobody chose still prints
  ## commits, and looks like it worked.
  if s.len > 0 and s.allCharsInSet({'0' .. '9'}): return parseBiggestInt(s)
  try: return parseDate(s).when0
  except GittleError:
    fail("invalid date '" & s & "': gittle takes an ISO-8601 date or a raw " &
         "seconds count, not a relative date such as '2 weeks ago'")

const pseudoOpt: array[RevPseudo, string] =
  ["--all", "--branches", "--tags", "--remotes"]
  ## The four spellings that stand for a namespace, as a table: they differ
  ## only in their prefix, which `pseudoPrefix` already holds.

const walkOptions* = [
  ## docs/04: the `rev-list` options `log` and `rev-list` share.  Revisions
  ## interleave with these on the command line and the interleaving means
  ## something (`--not`), so the command replays `occurrences` in order and
  ## hands each option to `applyWalkOpt`.
  opt("--first-parent", help = "follow only the first parent of a merge"),
  opt("--not", help = "negate every revision after it"),
  opt("--merges", help = "merge commits only"),
  opt("--no-merges", help = "no merge commits"),
  opt("--topo-order", help = "children before parents, branches kept together"),
  opt("--date-order", help = "children before parents, by date"),
  opt("--reverse", help = "oldest first"),
  opt("--left-right", help = "mark which side of a symmetric difference each commit is on"),
  opt("--count", help = "print how many commits, not which"),
  opt("--objects", help = "list the trees and blobs reached, too"),
  opt("--stdin", help = "read revisions from standard input as well"),
  opt("--all", help = "every ref"),
  opt("--branches", okOptValue, arg = "[=<glob>]", help = "every branch"),
  opt("--tags", okOptValue, arg = "[=<glob>]", help = "every tag"),
  opt("--remotes", okOptValue, arg = "[=<glob>]", help = "every remote-tracking branch"),
  opt("-n|--max-count", okValue, key = "n", arg = "<n>", help = "stop after <n> commits; -<n> says the same"),
  opt("--skip", okValue, arg = "<n>", help = "leave out the first <n>"),
  opt("--since|--after", okValue, key = "since", arg = "<date>", help = "commits after the date"),
  opt("--until|--before", okValue, key = "until", arg = "<date>", help = "commits before the date"),
  opt("--no-walk", okOptValue, arg = "[=unsorted]", help = "the named commits only, no ancestry"),
  opt("--do-walk"),
  opt("--parents", help = "print each commit's parents too"),
]

proc applyWalkOpt*(w: RevWalk, ri: var RevInput, k, v: string): bool =
  ## One occurrence from a parse against `walkOptions`, by key; false when
  ## the key is not a walk option and the command should take it.
  let repo = w.repo
  result = true
  case k
  of "first-parent": w.firstParent = true
  of "not": ri.notMode = true
  of "merges": w.minParents = 2
  of "no-merges": w.maxParents = 1
  of "topo-order": w.order = roTopo
  of "date-order": w.order = roDate
  of "reverse": ri.reverse = true
  of "left-right": ri.leftRight = true
  of "count": ri.count = true
  of "objects": ri.objects = true
  of "stdin":
    # One revision, or one long option, per line.
    for line in stdin.readAll().splitLines():
      if line.len == 0: continue
      if line.startsWith("--"):
        let eq = line.find('=')
        let key = if eq > 0: line[2 ..< eq] else: line[2 .. ^1]
        if w.applyWalkOpt(ri, key, (if eq > 0: line[eq + 1 .. ^1] else: "")):
          continue
      discard repo.addRevArg(line, ri.notMode, ri.points)
  of "all", "branches", "tags", "remotes":
    for kind, name in pseudoOpt:
      if name == "--" & k: repo.addPseudo(kind, v, ri.notMode, ri.points)
  of "n": ri.maxCount = parseInt(v)
  of "skip": ri.skip = parseInt(v)
  of "since": w.maxAge = parseTimestamp(v)
  of "until": w.minAge = parseTimestamp(v)
  of "no-walk":
    w.noWalk = true
    w.noWalkSorted = v != "unsorted"
  of "do-walk": w.noWalk = false
  of "parents":
    # Both sides want it: the walk rewrites parents, the command prints them.
    w.rewriteParents = true
    result = false
  else: result = false

proc addRevisionArg*(w: RevWalk, ri: var RevInput, arg: string) =
  ## One non-option argument.  A revision until proven otherwise: the first
  ## one that names nothing is a path, and **so is everything after it**,
  ## which is what makes `log Makefile` work without a `--`
  ## (`revision.c:setup_revisions`).
  if ri.seenDashDash or ri.pathsStarted:
    ri.specs.add arg
    return
  if w.repo.addRevArg(arg, ri.notMode, ri.points): return
  failIf(arg.len > 0 and arg[0] == '^', "bad revision '" & arg & "'")
  ri.pathsStarted = true
  failAmbiguous(w.repo, arg)
  ri.specs.add arg

proc finishRevInput*(w: RevWalk, ri: var RevInput, defaultHead = true) =
  ## Seed the walk from what the pass collected.
  ##
  ## `log` with no revision starts at HEAD; `rev-list` does not -- git sets
  ## that default per command (`revs->def`), and `rev-list --objects` with no
  ## revision therefore lists nothing rather than the whole of HEAD.
  if defaultHead and (ri.points.len == 0 or ri.points.allIt(it.uninteresting)):
    let h = w.repo.refs.resolveRef(headRef)
    failIf(not h.found,
           "your current branch '" & w.repo.headRefName &
           "' does not have any commits yet")
    ri.points.insert(RevPoint(oid: h.oid, name: headRef), 0)
  for p in ri.points:
    # Tags are peeled here rather than in the grammar: `rev-list v1.0` walks
    # the commit, and only `--objects` ever wants the tag object itself.
    w.start(w.repo.peelTo(p.oid, otCommit).oid, p.uninteresting, p.left)
  w.paths = parsePathspec(ri.specs, w.repo.prefix)
  w.limiting = not w.paths.isEmpty
